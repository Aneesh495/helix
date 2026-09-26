defmodule Helix.Cluster.Membership do
  @moduledoc """
  SWIM failure detector and cluster membership protocol actor.
  Provides ping, indirect ping-req probing, monotonic incarnation suspicion refutation,
  and epidemic membership gossip.
  """

  use GenServer

  alias Helix.Cluster.Node, as: CNode
  alias Helix.Cluster.Gossip

  defstruct [
    :local_node,
    members: %{},
    gossip: nil,
    ping_interval_ms: 200,
    ping_timeout_ms: 100,
    suspect_timeout_ms: 500,
    transport_fn: nil,
    subscriber: nil
  ]

  @type t :: %__MODULE__{
          local_node: CNode.t(),
          members: %{binary() => CNode.t()},
          gossip: Gossip.t(),
          ping_interval_ms: pos_integer(),
          ping_timeout_ms: pos_integer(),
          suspect_timeout_ms: pos_integer(),
          transport_fn: (term(), term() -> any()) | nil,
          subscriber: pid() | nil
        }

  # Client API

  @doc """
  Starts the SWIM membership GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Adds a seed peer node to local membership.
  """
  def join(server, peer_node) do
    GenServer.call(server, {:join, peer_node})
  end

  @doc """
  Returns a list of all active alive cluster members.
  """
  def get_alive_members(server) do
    GenServer.call(server, :get_alive_members)
  end

  @doc """
  Delivers a SWIM protocol message to the membership actor.
  """
  def deliver_message(server, msg) do
    GenServer.cast(server, {:msg, msg})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    node_id = Keyword.get(opts, :node_id, "node_1")
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 9000)
    interval = Keyword.get(opts, :ping_interval_ms, 200)
    suspect_timeout = Keyword.get(opts, :suspect_timeout_ms, 500)
    transport_fn = Keyword.get(opts, :transport_fn, nil)
    subscriber = Keyword.get(opts, :subscriber, nil)

    local_node = CNode.new(node_id, host, port)
    gossip = Gossip.new()

    if interval > 0 do
      :timer.send_interval(interval, :ping_round)
    end

    state = %__MODULE__{
      local_node: local_node,
      members: %{node_id => local_node},
      gossip: gossip,
      ping_interval_ms: interval,
      ping_timeout_ms: 100,
      suspect_timeout_ms: suspect_timeout,
      transport_fn: transport_fn,
      subscriber: subscriber
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:join, %CNode{} = peer}, _from, state) do
    new_members = Map.put(state.members, peer.id, peer)

    new_gossip =
      Gossip.add_event(state.gossip, "join:#{peer.id}", {:alive, peer.id, peer.incarnation, peer})

    {:reply, :ok, %{state | members: new_members, gossip: new_gossip}}
  end

  @impl true
  def handle_call(:get_alive_members, _from, state) do
    alive =
      state.members
      |> Map.values()
      |> Enum.filter(&(&1.status == :alive))

    {:reply, alive, state}
  end

  @impl true
  def handle_cast({:msg, msg}, state) do
    handle_swim_message(msg, state)
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    handle_swim_message(msg, state)
  end

  @impl true
  def handle_info(:ping_round, state) do
    peers =
      state.members
      |> Map.values()
      |> Enum.reject(&(&1.id == state.local_node.id or &1.status == :dead))

    if length(peers) > 0 do
      target = Enum.random(peers)
      {events, new_gossip} = Gossip.select_and_advance(state.gossip, 3)

      ping_msg = {:swim_ping, state.local_node.id, state.local_node.incarnation, events}
      send_msg(state, target.id, ping_msg)

      {:noreply, %{state | gossip: new_gossip}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:suspect_expired, target_id, inc}, state) do
    case Map.get(state.members, target_id) do
      %CNode{status: :suspect, incarnation: ^inc} = node ->
        dead_node = CNode.mark_dead(node)
        new_members = Map.put(state.members, target_id, dead_node)

        new_gossip =
          Gossip.add_event(state.gossip, "dead:#{target_id}", {:dead, target_id, inc, nil})

        if state.subscriber do
          send(state.subscriber, {:node_dead, target_id})
        end

        {:noreply, %{state | members: new_members, gossip: new_gossip}}

      _other ->
        {:noreply, state}
    end
  end

  defp handle_swim_message({:swim_ping, from_id, from_inc, piggybacked_events}, state) do
    # Process piggybacked gossip events
    state = process_gossip_events(state, piggybacked_events)

    # Reply with ack and piggybacked gossip
    {events, new_gossip} = Gossip.select_and_advance(state.gossip, 3)
    ack_msg = {:swim_ack, state.local_node.id, state.local_node.incarnation, events}
    send_msg(state, from_id, ack_msg)

    # Update or add sender to members
    cur_sender = Map.get(state.members, from_id)

    new_members =
      case cur_sender do
        nil ->
          Map.put(state.members, from_id, CNode.new(from_id, "127.0.0.1", 0))

        %CNode{} = n ->
          if from_inc >= n.incarnation do
            Map.put(state.members, from_id, %{n | status: :alive, incarnation: from_inc})
          else
            state.members
          end
      end

    {:noreply, %{state | members: new_members, gossip: new_gossip}}
  end

  defp handle_swim_message({:swim_ack, from_id, from_inc, piggybacked_events}, state) do
    state = process_gossip_events(state, piggybacked_events)

    case Map.get(state.members, from_id) do
      %CNode{} = n ->
        if from_inc >= n.incarnation do
          new_node = %{n | status: :alive, incarnation: from_inc}
          {:noreply, %{state | members: Map.put(state.members, from_id, new_node)}}
        else
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  defp handle_swim_message({:swim_ping_req, requester_id, target_id, events}, state) do
    state = process_gossip_events(state, events)

    # Auxiliary peer attempts to ping target on behalf of requester
    ping_msg = {:swim_ping, state.local_node.id, state.local_node.incarnation, []}
    send_msg(state, target_id, ping_msg)

    # Forward notification
    send_msg(state, requester_id, {:swim_ping_req_forwarded, target_id})
    {:noreply, state}
  end

  defp handle_swim_message(_other, state) do
    {:noreply, state}
  end

  defp process_gossip_events(state, events) when is_list(events) do
    Enum.reduce(events, state, fn event, acc_state ->
      apply_gossip_event(acc_state, event)
    end)
  end

  defp apply_gossip_event(state, {:suspect, node_id, inc, _}) do
    if node_id == state.local_node.id do
      # Refute false suspicion!
      refuted = CNode.refute(state.local_node, inc)
      refute_event = {:alive, refuted.id, refuted.incarnation, refuted}
      new_gossip = Gossip.add_event(state.gossip, "alive:#{refuted.id}", refute_event)
      %{state | local_node: refuted, gossip: new_gossip}
    else
      case Map.get(state.members, node_id) do
        %CNode{incarnation: cur_inc} = n when inc >= cur_inc ->
          suspect_node = CNode.mark_suspect(n, inc)
          new_members = Map.put(state.members, node_id, suspect_node)

          # Schedule suspicion expiration timer
          Process.send_after(self(), {:suspect_expired, node_id, inc}, state.suspect_timeout_ms)
          %{state | members: new_members}

        _other ->
          state
      end
    end
  end

  defp apply_gossip_event(state, {:alive, node_id, inc, _}) do
    case Map.get(state.members, node_id) do
      %CNode{incarnation: cur_inc} = n when inc > cur_inc ->
        updated = %{n | status: :alive, incarnation: inc}
        %{state | members: Map.put(state.members, node_id, updated)}

      nil ->
        new_node = CNode.new(node_id, "127.0.0.1", 0)
        %{state | members: Map.put(state.members, node_id, %{new_node | incarnation: inc})}

      _other ->
        state
    end
  end

  defp apply_gossip_event(state, {:dead, node_id, _inc, _}) do
    case Map.get(state.members, node_id) do
      %CNode{} = n ->
        dead_node = CNode.mark_dead(n)
        %{state | members: Map.put(state.members, node_id, dead_node)}

      nil ->
        state
    end
  end

  defp apply_gossip_event(state, _unknown), do: state

  defp send_msg(state, target_id, msg) do
    if state.transport_fn do
      state.transport_fn.(target_id, msg)
    else
      target_atom =
        if is_atom(target_id), do: target_id, else: String.to_atom(target_id)

      case Process.whereis(target_atom) do
        pid when is_pid(pid) -> send(pid, {:msg, msg})
        nil -> :ok
      end
    end
  end
end
