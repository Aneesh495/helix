defmodule Helix.CRDT.CausalContext do
  @moduledoc """
  Dot store and causal context representation for delta-CRDTs.
  Tracks observed discrete events (dots) with compact contiguous interval compression.
  """

  defstruct max_dots: %{},
            sparse_dots: MapSet.new()

  @type node_id :: term()
  @type counter :: pos_integer()
  @type dot :: {node_id(), counter()}

  @type t :: %__MODULE__{
          max_dots: %{node_id() => counter()},
          sparse_dots: MapSet.t(dot())
        }

  @doc """
  Initializes an empty causal context.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{max_dots: %{}, sparse_dots: MapSet.new()}
  end

  @doc """
  Generates the next causal dot for a given node.
  """
  @spec next_dot(t(), node_id()) :: {dot(), t()}
  def next_dot(%__MODULE__{} = cc, node_id) do
    cur_max = Map.get(cc.max_dots, node_id, 0)
    next_counter = cur_max + 1
    dot = {node_id, next_counter}
    new_max = Map.put(cc.max_dots, node_id, next_counter)
    {dot, %{cc | max_dots: new_max}}
  end

  @doc """
  Adds an observed dot to the causal context. Compacts contiguous dots automatically.
  """
  @spec add_dot(t(), node_id(), counter()) :: t()
  def add_dot(%__MODULE__{} = cc, node_id, counter) when counter > 0 do
    cur_max = Map.get(cc.max_dots, node_id, 0)

    cond do
      counter <= cur_max ->
        cc

      counter == cur_max + 1 ->
        # Contiguous progression: advance max and check if any sparse dots can be absorbed
        advance_max(cc, node_id, counter)

      true ->
        %{cc | sparse_dots: MapSet.put(cc.sparse_dots, {node_id, counter})}
    end
  end

  @doc """
  Checks if a dot is covered by this causal context.
  """
  @spec member?(t(), node_id(), counter()) :: boolean()
  def member?(%__MODULE__{} = cc, node_id, counter) do
    cur_max = Map.get(cc.max_dots, node_id, 0)

    if counter <= cur_max do
      true
    else
      MapSet.member?(cc.sparse_dots, {node_id, counter})
    end
  end

  @doc """
  Merges two causal contexts by taking the supremum of contiguous frontiers
  and unioning sparse dots.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = cc1, %__MODULE__{} = cc2) do
    all_nodes =
      MapSet.union(MapSet.new(Map.keys(cc1.max_dots)), MapSet.new(Map.keys(cc2.max_dots)))

    merged_max =
      Enum.reduce(all_nodes, %{}, fn node, acc ->
        m1 = Map.get(cc1.max_dots, node, 0)
        m2 = Map.get(cc2.max_dots, node, 0)
        Map.put(acc, node, max(m1, m2))
      end)

    initial_sparse = MapSet.union(cc1.sparse_dots, cc2.sparse_dots)

    # Filter out sparse dots that are now covered by merged_max
    filtered_sparse =
      Enum.reduce(initial_sparse, MapSet.new(), fn {node, cnt}, acc ->
        if cnt > Map.get(merged_max, node, 0) do
          MapSet.put(acc, {node, cnt})
        else
          acc
        end
      end)

    # Fold sparse dots that can now be compacted
    Enum.reduce(
      filtered_sparse,
      %__MODULE__{max_dots: merged_max, sparse_dots: MapSet.new()},
      fn {n, c}, acc_cc ->
        add_dot(acc_cc, n, c)
      end
    )
  end

  defp advance_max(cc, node_id, current_max) do
    next = current_max + 1
    target = {node_id, next}

    if MapSet.member?(cc.sparse_dots, target) do
      new_sparse = MapSet.delete(cc.sparse_dots, target)
      new_cc = %{cc | sparse_dots: new_sparse}
      advance_max(new_cc, node_id, next)
    else
      %{cc | max_dots: Map.put(cc.max_dots, node_id, current_max)}
    end
  end
end
