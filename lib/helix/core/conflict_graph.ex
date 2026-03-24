defmodule Helix.Core.ConflictGraph do
  @moduledoc """
  Directed dependency graph for tracking EPaxos instances and resolving execution orders.
  Applies Tarjan's strongly connected components algorithm and sequence number tie-breaking
  to linearize concurrent distributed transactions.
  """

  alias Helix.Core.TarjanSCC

  defstruct nodes: %{},
            edges: %{},
            in_edges: %{}

  @type node_id :: term()
  @type t :: %__MODULE__{
          nodes: %{node_id() => term()},
          edges: %{node_id() => MapSet.t(node_id())},
          in_edges: %{node_id() => MapSet.t(node_id())}
        }

  @doc """
  Creates a new empty conflict graph.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{nodes: %{}, edges: %{}, in_edges: %{}}
  end

  @doc """
  Adds a node (transaction instance) with associated metadata to the graph.
  """
  @spec add_node(t(), node_id(), term()) :: t()
  def add_node(%__MODULE__{} = graph, id, metadata \\ %{}) do
    nodes = Map.put(graph.nodes, id, metadata)
    edges = Map.put_new(graph.edges, id, MapSet.new())
    in_edges = Map.put_new(graph.in_edges, id, MapSet.new())
    %{graph | nodes: nodes, edges: edges, in_edges: in_edges}
  end

  @doc """
  Adds a directed edge from instance A to instance B, meaning A depends on B.
  """
  @spec add_edge(t(), node_id(), node_id()) :: t()
  def add_edge(%__MODULE__{} = graph, from_id, to_id) do
    if from_id == to_id do
      graph
    else
      graph =
        graph
        |> ensure_node(from_id)
        |> ensure_node(to_id)

      current_out = Map.get(graph.edges, from_id, MapSet.new())
      current_in = Map.get(graph.in_edges, to_id, MapSet.new())

      new_edges = Map.put(graph.edges, from_id, MapSet.put(current_out, to_id))
      new_in_edges = Map.put(graph.in_edges, to_id, MapSet.put(current_in, from_id))

      %{graph | edges: new_edges, in_edges: new_in_edges}
    end
  end

  @doc """
  Adds multiple dependencies for a node.
  """
  @spec add_dependencies(t(), node_id(), Enumerable.t()) :: t()
  def add_dependencies(%__MODULE__{} = graph, from_id, deps) do
    Enum.reduce(deps, graph, fn to_id, g ->
      add_edge(g, from_id, to_id)
    end)
  end

  @doc """
  Removes a node and its adjacent edges after execution.
  """
  @spec remove_node(t(), node_id()) :: t()
  def remove_node(%__MODULE__{} = graph, id) do
    nodes = Map.delete(graph.nodes, id)
    out_targets = Map.get(graph.edges, id, MapSet.new())
    in_sources = Map.get(graph.in_edges, id, MapSet.new())

    new_edges = Map.delete(graph.edges, id)
    new_in_edges = Map.delete(graph.in_edges, id)

    # Clean up back-references
    new_edges =
      Enum.reduce(in_sources, new_edges, fn src, acc ->
        Map.update(acc, src, MapSet.new(), &MapSet.delete(&1, id))
      end)

    new_in_edges =
      Enum.reduce(out_targets, new_in_edges, fn tgt, acc ->
        Map.update(acc, tgt, MapSet.new(), &MapSet.delete(&1, id))
      end)

    %{graph | nodes: nodes, edges: new_edges, in_edges: new_in_edges}
  end

  @doc """
  Resolves the graph into a deterministic list of execution batches.
  Uses Tarjan SCC to identify mutual dependency cycles, then sorts within cycles
  by sequence number ascending, breaking ties by node identifier.
  """
  @spec resolve_execution_order(t()) :: [node_id()]
  def resolve_execution_order(%__MODULE__{} = graph) do
    # Convert edge map to list adjacency map for Tarjan
    adj_map =
      Map.new(graph.edges, fn {k, set} ->
        {k, MapSet.to_list(set)}
      end)

    components = TarjanSCC.scc(adj_map)

    # Within each component, sort deterministically
    components
    |> Enum.flat_map(fn component ->
      sort_component(component, graph.nodes)
    end)
  end

  defp sort_component([single], _nodes), do: [single]

  defp sort_component(members, nodes) do
    Enum.sort_by(members, fn member ->
      meta = Map.get(nodes, member, %{})
      seq = Map.get(meta, :seq, 0)
      {seq, member}
    end)
  end

  defp ensure_node(graph, id) do
    if Map.has_key?(graph.nodes, id) do
      graph
    else
      add_node(graph, id, %{})
    end
  end
end
