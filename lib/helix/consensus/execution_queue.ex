defmodule Helix.Consensus.ExecutionQueue do
  @moduledoc """
  Background transaction linearization queue for Egalitarian Paxos.
  Ingests committed instances, resolves the distributed conflict dependency graph
  using Tarjan SCC and sequence number ordering, and dispatches linearizable batches.
  """

  use GenServer

  alias Helix.Core.Types
  alias Helix.Core.ConflictGraph

  defstruct [
    :subscriber,
    graph: nil,
    committed: %{},
    executed_ids: MapSet.new(),
    execution_order: []
  ]

  @type t :: %__MODULE__{
          subscriber: pid() | nil,
          graph: ConflictGraph.t(),
          committed: %{
            Types.instance_id() =>
              {Types.command(), non_neg_integer(), MapSet.t(Types.instance_id())}
          },
          executed_ids: MapSet.t(Types.instance_id()),
          execution_order: [Types.instance_id()]
        }

  # Client API

  @doc """
  Starts the execution queue GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Enqueues a committed instance for dependency resolution and execution.
  """
  def enqueue_committed(queue, instance_id, command, seq, deps) do
    GenServer.cast(queue, {:enqueue_committed, instance_id, command, seq, deps})
  end

  @doc """
  Returns the chronological list of all executed instance IDs in strict order.
  """
  def get_execution_order(queue) do
    GenServer.call(queue, :get_execution_order)
  end

  @doc """
  Forces an immediate execution drainage pass.
  """
  def drain(queue) do
    GenServer.call(queue, :drain)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    subscriber = Keyword.get(opts, :subscriber)

    state = %__MODULE__{
      subscriber: subscriber,
      graph: ConflictGraph.new(),
      committed: %{},
      executed_ids: MapSet.new(),
      execution_order: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_execution_order, _from, state) do
    {:reply, state.execution_order, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    new_state = process_execution_graph(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:enqueue_committed, id, cmd, seq, deps}, state) do
    # Filter out already executed dependencies
    pending_deps =
      Enum.reject(deps, fn dep_id ->
        MapSet.member?(state.executed_ids, dep_id)
      end)
      |> MapSet.new()

    new_committed = Map.put(state.committed, id, {cmd, seq, pending_deps})

    # Add to graph
    g =
      state.graph
      |> ConflictGraph.add_node(id, %{seq: seq, cmd: cmd})
      |> ConflictGraph.add_dependencies(id, pending_deps)

    updated_state = %{state | graph: g, committed: new_committed}
    final_state = process_execution_graph(updated_state)

    {:noreply, final_state}
  end

  @impl true
  def handle_info({:enqueue_committed, id, cmd, seq, deps}, state) do
    handle_cast({:enqueue_committed, id, cmd, seq, deps}, state)
  end

  defp process_execution_graph(state) do
    candidate_order = ConflictGraph.resolve_execution_order(state.graph)

    # Walk candidate order and execute instances whose dependencies are either executed
    # or part of the same mutual SCC batch
    {executed_now, remaining_graph, remaining_committed, updated_executed_set} =
      Enum.reduce(
        candidate_order,
        {[], state.graph, state.committed, state.executed_ids},
        fn inst_id, {exec_acc, g, committed_acc, executed_set} ->
          case Map.get(committed_acc, inst_id) do
            {cmd, _seq, deps} ->
              # Verify all dependencies are satisfied in executed_set or are already in exec_acc
              all_deps_satisfied =
                Enum.all?(deps, fn dep_id ->
                  MapSet.member?(executed_set, dep_id) or Enum.member?(exec_acc, dep_id)
                end)

              if all_deps_satisfied do
                new_exec_acc = exec_acc ++ [inst_id]
                new_executed_set = MapSet.put(executed_set, inst_id)
                new_g = ConflictGraph.remove_node(g, inst_id)
                new_committed = Map.delete(committed_acc, inst_id)

                if state.subscriber do
                  send(state.subscriber, {:instance_executed, inst_id, cmd})
                end

                {new_exec_acc, new_g, new_committed, new_executed_set}
              else
                {exec_acc, g, committed_acc, executed_set}
              end

            nil ->
              {exec_acc, g, committed_acc, executed_set}
          end
        end
      )

    %{
      state
      | graph: remaining_graph,
        committed: remaining_committed,
        executed_ids: updated_executed_set,
        execution_order: state.execution_order ++ executed_now
    }
  end
end
