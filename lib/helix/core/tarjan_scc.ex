defmodule Helix.Core.TarjanSCC do
  @moduledoc """
  Tarjan's Strongly Connected Components (SCC) algorithm for EPaxos dependency graphs.
  Finds maximal strongly connected components in linear time O(V + E) and yields
  a deterministic condensation DAG for linearizable transaction execution ordering.
  """

  @type node_id :: term()
  @type adjacency_map :: %{node_id() => [node_id()]}
  @type component :: [node_id()]

  defmodule State do
    @moduledoc false
    defstruct index: 0,
              stack: [],
              on_stack: MapSet.new(),
              indices: %{},
              lowlinks: %{},
              sccs: []
  end

  @doc """
  Computes strongly connected components of a directed graph.
  Returns a list of components, where each component is a list of node IDs.
  Components are ordered in reverse topological order (dependencies execute first).
  """
  @spec scc(adjacency_map()) :: [component()]
  def scc(adj_map) when is_map(adj_map) do
    all_nodes =
      Map.keys(adj_map)
      |> Enum.concat(List.flatten(Map.values(adj_map)))
      |> Enum.uniq()

    state =
      Enum.reduce(all_nodes, %State{}, fn node, s ->
        if Map.has_key?(s.indices, node) do
          s
        else
          strongconnect(node, adj_map, s)
        end
      end)

    Enum.reverse(state.sccs)
  end

  defp strongconnect(v, adj_map, %State{} = state) do
    # Set index and lowlink of v to current index
    idx = state.index
    indices = Map.put(state.indices, v, idx)
    lowlinks = Map.put(state.lowlinks, v, idx)
    stack = [v | state.stack]
    on_stack = MapSet.put(state.on_stack, v)

    state = %State{
      state
      | index: idx + 1,
        indices: indices,
        lowlinks: lowlinks,
        stack: stack,
        on_stack: on_stack
    }

    # Consider successors of v
    neighbors = Map.get(adj_map, v, [])

    state =
      Enum.reduce(neighbors, state, fn w, s ->
        cond do
          not Map.has_key?(s.indices, w) ->
            # Successor w has not yet been visited; recurse on it
            s = strongconnect(w, adj_map, s)
            low_v = min(Map.fetch!(s.lowlinks, v), Map.fetch!(s.lowlinks, w))
            %{s | lowlinks: Map.put(s.lowlinks, v, low_v)}

          MapSet.member?(s.on_stack, w) ->
            # Successor w is in stack and hence in the current SCC
            low_v = min(Map.fetch!(s.lowlinks, v), Map.fetch!(s.indices, w))
            %{s | lowlinks: Map.put(s.lowlinks, v, low_v)}

          true ->
            s
        end
      end)

    # If v is a root node, pop the stack and generate an SCC
    if Map.fetch!(state.lowlinks, v) == Map.fetch!(state.indices, v) do
      {scc_members, new_stack, new_on_stack} = pop_until(v, state.stack, state.on_stack, [])

      %{
        state
        | stack: new_stack,
          on_stack: new_on_stack,
          sccs: [scc_members | state.sccs]
      }
    else
      state
    end
  end

  defp pop_until(target, [top | rest], on_stack, acc) do
    new_on_stack = MapSet.delete(on_stack, top)
    new_acc = [top | acc]

    if top == target do
      {new_acc, rest, new_on_stack}
    else
      pop_until(target, rest, new_on_stack, new_acc)
    end
  end
end
