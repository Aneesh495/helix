defmodule Helix.CRDT.ReplicationEngine do
  @moduledoc """
  Anti-entropy delta replication engine for distributed CRDT state synchronization.
  Periodically extracts and broadcasts buffered delta mutations, applies incoming
  remote deltas, and tracks causal stability frontiers for state compaction.
  """

  use GenServer

  alias Helix.Core.VectorClock

  defstruct [
    :node_id,
    :peers,
    crdts: %{},
    peer_frontiers: %{},
    sync_interval_ms: 100,
    broadcast_fn: nil
  ]

  @type t :: %__MODULE__{
          node_id: term(),
          peers: [term()],
          crdts: %{term() => {module(), term()}},
          peer_frontiers: %{term() => VectorClock.t()},
          sync_interval_ms: pos_integer(),
          broadcast_fn: ((term(), term()) -> any()) | nil
        }

  # Client API

  @doc """
  Starts the CRDT replication engine.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Registers a CRDT instance under a given key.
  """
  def register_crdt(server, crdt_id, module, initial_state) do
    GenServer.call(server, {:register, crdt_id, module, initial_state})
  end

  @doc """
  Updates a registered CRDT using a modifier function.
  """
  def update_crdt(server, crdt_id, update_fn) do
    GenServer.call(server, {:update, crdt_id, update_fn})
  end

  @doc """
  Reads the current evaluated value of a registered CRDT.
  """
  def read_crdt(server, crdt_id) do
    GenServer.call(server, {:read, crdt_id})
  end

  @doc """
  Applies an incoming delta received from a remote peer.
  """
  def apply_delta(server, from_peer, crdt_id, delta) do
    GenServer.cast(server, {:apply_delta, from_peer, crdt_id, delta})
  end

  @doc """
  Forces an immediate anti-entropy sync pass across all registered CRDTs.
  """
  def sync_now(server) do
    GenServer.call(server, :sync_now)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    node_id = Keyword.get(opts, :node_id, Node.self())
    peers = Keyword.get(opts, :peers, [])
    interval = Keyword.get(opts, :sync_interval_ms, 100)
    broadcast_fn = Keyword.get(opts, :broadcast_fn, nil)

    if interval > 0 do
      :timer.send_interval(interval, :trigger_sync)
    end

    state = %__MODULE__{
      node_id: node_id,
      peers: peers,
      crdts: %{},
      peer_frontiers: %{},
      sync_interval_ms: interval,
      broadcast_fn: broadcast_fn
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, crdt_id, module, initial_state}, _from, state) do
    new_crdts = Map.put(state.crdts, crdt_id, {module, initial_state})
    {:reply, :ok, %{state | crdts: new_crdts}}
  end

  @impl true
  def handle_call({:update, crdt_id, update_fn}, _from, state) do
    case Map.get(state.crdts, crdt_id) do
      {mod, crdt_state} ->
        updated_state = update_fn.(crdt_state)
        new_crdts = Map.put(state.crdts, crdt_id, {mod, updated_state})
        {:reply, {:ok, mod.value(updated_state)}, %{state | crdts: new_crdts}}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:read, crdt_id}, _from, state) do
    case Map.get(state.crdts, crdt_id) do
      {mod, crdt_state} ->
        {:reply, {:ok, mod.value(crdt_state)}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    new_state = perform_delta_broadcast(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:apply_delta, from_peer, crdt_id, delta}, state) do
    new_crdts =
      case Map.get(state.crdts, crdt_id) do
        {mod, current_state} ->
          merged = mod.merge(current_state, delta)
          Map.put(state.crdts, crdt_id, {mod, merged})

        nil ->
          state.crdts
      end

    # Update peer causal frontier
    cur_clock = Map.get(state.peer_frontiers, from_peer, VectorClock.new())
    updated_clock = VectorClock.increment(cur_clock, from_peer)
    new_frontiers = Map.put(state.peer_frontiers, from_peer, updated_clock)

    {:noreply, %{state | crdts: new_crdts, peer_frontiers: new_frontiers}}
  end

  @impl true
  def handle_info(:trigger_sync, state) do
    new_state = perform_delta_broadcast(state)
    {:noreply, new_state}
  end

  defp perform_delta_broadcast(state) do
    # Extract pending deltas
    {updated_crdts, deltas_to_send} =
      Enum.reduce(state.crdts, {%{}, []}, fn {id, {mod, crdt_state}}, {crdt_acc, delta_acc} ->
        case mod.delta(crdt_state) do
          nil ->
            {Map.put(crdt_acc, id, {mod, crdt_state}), delta_acc}

          d ->
            cleared_state = mod.reset_delta(crdt_state)
            {Map.put(crdt_acc, id, {mod, cleared_state}), [{id, d} | delta_acc]}
        end
      end)

    if state.broadcast_fn && length(deltas_to_send) > 0 do
      Enum.each(deltas_to_send, fn {id, d} ->
        state.broadcast_fn.(id, d)
      end)
    end

    %{state | crdts: updated_crdts}
  end
end
