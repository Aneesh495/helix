defmodule Helix.Consensus.Replica do
  @moduledoc """
  Core Egalitarian Paxos (EPaxos) replica actor.
  Orchestrates decentralized leaderless consensus with 1-RTT fast path,
  classic 2-RTT slow path fallbacks, and recovery handling.
  """

  use GenServer

  alias Helix.Core.Types
  alias Helix.Consensus.Ballot
  alias Helix.Consensus.Instance
  alias Helix.Consensus.Quorum
  alias Helix.Consensus.ConflictDetector

  defstruct [
    :replica_id,
    :peers,
    :execution_queue,
    instance_counter: 1,
    instances: %{},
    conflict_detector: nil,
    ballot: nil,
    transport_fn: nil
  ]

  @type t :: %__MODULE__{
          replica_id: Types.replica_id(),
          peers: [Types.replica_id() | pid()],
          execution_queue: pid() | atom() | nil,
          instance_counter: pos_integer(),
          instances: %{Types.instance_id() => Instance.t()},
          conflict_detector: ConflictDetector.t(),
          ballot: Ballot.t(),
          transport_fn: ((term(), term()) -> any()) | nil
        }

  # Client API

  @doc """
  Starts an EPaxos replica GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Proposes a new transactional command to this replica.
  Waits until the command achieves consensus (fast or slow path) and commits.
  """
  def propose(server, command, timeout \\ 5000) do
    GenServer.call(server, {:propose, command}, timeout)
  end

  @doc """
  Fetches an instance state by instance_id.
  """
  def get_instance(server, instance_id) do
    GenServer.call(server, {:get_instance, instance_id})
  end

  @doc """
  Delivers a consensus message to the replica.
  """
  def deliver_message(server, msg) do
    GenServer.cast(server, {:msg, msg})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    replica_id = Keyword.get(opts, :replica_id, "node1")
    peers = Keyword.get(opts, :peers, [])
    exec_queue = Keyword.get(opts, :execution_queue, nil)
    transport_fn = Keyword.get(opts, :transport_fn, nil)

    state = %__MODULE__{
      replica_id: replica_id,
      peers: peers,
      execution_queue: exec_queue,
      instance_counter: 1,
      instances: %{},
      conflict_detector: ConflictDetector.new(),
      ballot: Ballot.initial(replica_id),
      transport_fn: transport_fn
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:propose, command}, from, state) do
    inst_id = {state.replica_id, state.instance_counter}
    {deps, seq} = ConflictDetector.find_conflicts(state.conflict_detector, command, inst_id)

    # Record local conflict
    new_detector = ConflictDetector.record(state.conflict_detector, inst_id, command, seq)

    inst = Instance.new(inst_id, command, state.ballot, state.replica_id, from)
    inst = %{inst | seq: seq, deps: deps}

    cluster_size = length(state.peers) + 1

    if cluster_size == 1 do
      # Single-node cluster: commit immediately
      committed_inst = Instance.transition_to_committed(inst, seq, deps)
      notify_execution_queue(state.execution_queue, inst_id, command, seq, deps)
      GenServer.reply(from, {:ok, inst_id, :committed})

      new_instances = Map.put(state.instances, inst_id, committed_inst)

      {:noreply,
       %{
         state
         | instance_counter: state.instance_counter + 1,
           instances: new_instances,
           conflict_detector: new_detector
       }}
    else
      # Multi-node cluster: initiate PreAccept fast-path broadcast
      new_instances = Map.put(state.instances, inst_id, inst)

      preaccept_msg = {:preaccept, state.replica_id, inst_id, state.ballot, command, seq, deps}
      broadcast_to_peers(state, preaccept_msg)

      # Record self as having voted for fast path
      self_reply = %{from: state.replica_id, seq: seq, deps: deps}
      updated_inst = Instance.record_preaccept_reply(inst, self_reply)
      final_instances = Map.put(new_instances, inst_id, updated_inst)

      {:noreply,
       %{
         state
         | instance_counter: state.instance_counter + 1,
           instances: final_instances,
           conflict_detector: new_detector
       }}
    end
  end

  @impl true
  def handle_call({:get_instance, instance_id}, _from, state) do
    {:reply, Map.get(state.instances, instance_id), state}
  end

  @impl true
  def handle_cast({:msg, msg}, state) do
    handle_consensus_message(msg, state)
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    handle_consensus_message(msg, state)
  end

  # Consensus Protocol Message Dispatcher

  defp handle_consensus_message({:preaccept, from, inst_id, ballot, cmd, seq, deps}, state) do
    local_inst = Map.get(state.instances, inst_id)

    if local_inst == nil or Ballot.dominates?(ballot, local_inst.ballot) do
      # Peer calculates its local conflicts
      {local_deps, local_seq} = ConflictDetector.find_conflicts(state.conflict_detector, cmd, inst_id)
      merged_deps = MapSet.union(deps, local_deps)
      merged_seq = max(seq, local_seq)

      new_detector = ConflictDetector.record(state.conflict_detector, inst_id, cmd, merged_seq)

      inst =
        case local_inst do
          nil -> Instance.new(inst_id, cmd, ballot, from)
          existing -> %{existing | ballot: ballot, command: cmd}
        end

      inst = %{inst | seq: merged_seq, deps: merged_deps, status: :preaccepted}
      new_instances = Map.put(state.instances, inst_id, inst)

      # Send PreAcceptOK back to coordinator
      reply_msg = {:preaccept_ok, state.replica_id, inst_id, merged_seq, merged_deps}
      send_to_peer(state, from, reply_msg)

      {:noreply, %{state | instances: new_instances, conflict_detector: new_detector}}
    else
      # Ballot rejection
      reject_msg = {:preaccept_reject, state.replica_id, inst_id, local_inst.ballot}
      send_to_peer(state, from, reject_msg)
      {:noreply, state}
    end
  end

  defp handle_consensus_message({:preaccept_ok, from, inst_id, seq, deps}, state) do
    case Map.get(state.instances, inst_id) do
      %Instance{status: :preaccepted} = inst ->
        reply_record = %{from: from, seq: seq, deps: deps}
        updated_inst = Instance.record_preaccept_reply(inst, reply_record)

        cluster_size = length(state.peers) + 1
        fast_q_size = Quorum.fast_size(cluster_size)

        if length(updated_inst.preaccept_replies) >= fast_q_size do
          # Check if all replies agree on initial sequence and dependencies
          if Quorum.fast_path_agreed?(updated_inst.preaccept_replies, inst.seq, inst.deps) do
            # FAST PATH SUCCESS (1 RTT)
            committed_inst = Instance.transition_to_committed(updated_inst, inst.seq, inst.deps)
            commit_msg = {:commit, state.replica_id, inst_id, inst.command, inst.seq, inst.deps}
            broadcast_to_peers(state, commit_msg)
            notify_execution_queue(state.execution_queue, inst_id, inst.command, inst.seq, inst.deps)

            if inst.caller, do: GenServer.reply(inst.caller, {:ok, inst_id, :committed})

            new_instances = Map.put(state.instances, inst_id, %{committed_inst | caller: nil})
            {:noreply, %{state | instances: new_instances}}
          else
            # SLOW PATH FALLBACK (2 RTT)
            final_seq =
              Enum.reduce(updated_inst.preaccept_replies, inst.seq, fn r, acc ->
                max(acc, r.seq)
              end)

            final_deps =
              Enum.reduce(updated_inst.preaccept_replies, inst.deps, fn r, acc ->
                MapSet.union(acc, r.deps)
              end)

            accepted_inst = Instance.transition_to_accepted(updated_inst, final_seq, final_deps)
            # Record self accept
            accepted_inst = Instance.record_accept_reply(accepted_inst, state.replica_id)

            accept_msg = {:accept, state.replica_id, inst_id, state.ballot, inst.command, final_seq, final_deps}
            broadcast_to_peers(state, accept_msg)

            new_instances = Map.put(state.instances, inst_id, accepted_inst)
            {:noreply, %{state | instances: new_instances}}
          end
        else
          new_instances = Map.put(state.instances, inst_id, updated_inst)
          {:noreply, %{state | instances: new_instances}}
        end

      _other ->
        {:noreply, state}
    end
  end

  defp handle_consensus_message({:accept, from, inst_id, ballot, cmd, seq, deps}, state) do
    local_inst = Map.get(state.instances, inst_id)

    if local_inst == nil or Ballot.dominates?(ballot, local_inst.ballot) do
      new_detector = ConflictDetector.record(state.conflict_detector, inst_id, cmd, seq)

      inst =
        case local_inst do
          nil -> Instance.new(inst_id, cmd, ballot, from)
          existing -> %{existing | ballot: ballot, command: cmd}
        end

      accepted_inst = Instance.transition_to_accepted(inst, seq, deps)
      new_instances = Map.put(state.instances, inst_id, accepted_inst)

      send_to_peer(state, from, {:accept_ok, state.replica_id, inst_id})
      {:noreply, %{state | instances: new_instances, conflict_detector: new_detector}}
    else
      send_to_peer(state, from, {:accept_reject, state.replica_id, inst_id, local_inst.ballot})
      {:noreply, state}
    end
  end

  defp handle_consensus_message({:accept_ok, from, inst_id}, state) do
    case Map.get(state.instances, inst_id) do
      %Instance{status: :accepted} = inst ->
        updated_inst = Instance.record_accept_reply(inst, from)
        cluster_size = length(state.peers) + 1
        classic_q_size = Quorum.classic_size(cluster_size)

        if MapSet.size(updated_inst.accept_replies) >= classic_q_size do
          # SLOW PATH COMMIT (Majority accepted)
          committed_inst = Instance.transition_to_committed(updated_inst, inst.seq, inst.deps)
          commit_msg = {:commit, state.replica_id, inst_id, inst.command, inst.seq, inst.deps}
          broadcast_to_peers(state, commit_msg)
          notify_execution_queue(state.execution_queue, inst_id, inst.command, inst.seq, inst.deps)

          if inst.caller, do: GenServer.reply(inst.caller, {:ok, inst_id, :committed})

          new_instances = Map.put(state.instances, inst_id, %{committed_inst | caller: nil})
          {:noreply, %{state | instances: new_instances}}
        else
          new_instances = Map.put(state.instances, inst_id, updated_inst)
          {:noreply, %{state | instances: new_instances}}
        end

      _other ->
        {:noreply, state}
    end
  end

  defp handle_consensus_message({:commit, _from, inst_id, cmd, seq, deps}, state) do
    local_inst = Map.get(state.instances, inst_id)

    new_detector = ConflictDetector.record(state.conflict_detector, inst_id, cmd, seq)

    inst =
      case local_inst do
        nil -> Instance.new(inst_id, cmd, state.ballot, elem(inst_id, 0))
        existing -> %{existing | command: cmd}
      end

    committed_inst = Instance.transition_to_committed(inst, seq, deps)
    new_instances = Map.put(state.instances, inst_id, committed_inst)

    notify_execution_queue(state.execution_queue, inst_id, cmd, seq, deps)

    {:noreply, %{state | instances: new_instances, conflict_detector: new_detector}}
  end

  defp handle_consensus_message(_msg, state) do
    {:noreply, state}
  end

  # Helper Functions

  defp broadcast_to_peers(state, msg) do
    Enum.each(state.peers, fn peer ->
      send_to_peer(state, peer, msg)
    end)
  end

  defp send_to_peer(state, peer, msg) do
    if state.transport_fn do
      state.transport_fn.(peer, msg)
    else
      cond do
        is_pid(peer) ->
          send(peer, {:msg, msg})

        is_atom(peer) or is_binary(peer) ->
          case Process.whereis(peer_to_atom(peer)) do
            pid when is_pid(pid) -> send(pid, {:msg, msg})
            nil -> :ok
          end

        true ->
          :ok
      end
    end
  end

  defp peer_to_atom(peer) when is_atom(peer), do: peer
  defp peer_to_atom(peer) when is_binary(peer), do: String.to_atom(peer)

  defp notify_execution_queue(nil, _id, _cmd, _seq, _deps), do: :ok

  defp notify_execution_queue(queue, id, cmd, seq, deps) do
    if is_pid(queue) do
      send(queue, {:enqueue_committed, id, cmd, seq, deps})
    else
      case Process.whereis(queue) do
        pid when is_pid(pid) -> send(pid, {:enqueue_committed, id, cmd, seq, deps})
        nil -> :ok
      end
    end
  end
end
