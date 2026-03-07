defmodule Helix.Core.VectorClock do
  @moduledoc """
  Vector clock implementation providing causal ordering, concurrency detection,
  and dot-based causality tracking across distributed nodes.
  """

  @type node_id :: term()
  @type counter :: non_neg_integer()
  @type t :: %{optional(node_id()) => counter()}

  @doc """
  Creates a new empty vector clock.
  """
  @spec new() :: t()
  def new, do: %{}

  @doc """
  Creates a vector clock initialized with a map of node counters.
  """
  @spec from_map(%{optional(node_id()) => counter()}) :: t()
  def from_map(map) when is_map(map), do: map

  @doc """
  Increments the counter for the specified node in the vector clock.
  """
  @spec increment(t(), node_id()) :: t()
  def increment(clock, node_id) when is_map(clock) do
    Map.update(clock, node_id, 1, &(&1 + 1))
  end

  @doc """
  Returns the counter for a given node in the clock.
  """
  @spec get(t(), node_id()) :: counter()
  def get(clock, node_id) when is_map(clock) do
    Map.get(clock, node_id, 0)
  end

  @doc """
  Merges two vector clocks by computing the component-wise supremum (maximum).
  """
  @spec merge(t(), t()) :: t()
  def merge(clock1, clock2) when is_map(clock1) and is_map(clock2) do
    Map.merge(clock1, clock2, fn _k, v1, v2 -> max(v1, v2) end)
  end

  @doc """
  Compares two vector clocks causally.
  Returns:
  - :equal if both clocks are identical
  - :before if clock1 strictly precedes clock2 causally
  - :after if clock1 strictly succeeds clock2 causally
  - :concurrent if neither dominates the other
  """
  @spec compare(t(), t()) :: :equal | :before | :after | :concurrent
  def compare(clock1, clock2) when is_map(clock1) and is_map(clock2) do
    all_keys = MapSet.union(MapSet.new(Map.keys(clock1)), MapSet.new(Map.keys(clock2)))

    {less, greater} =
      Enum.reduce(all_keys, {false, false}, fn k, {has_less, has_greater} ->
        v1 = Map.get(clock1, k, 0)
        v2 = Map.get(clock2, k, 0)

        cond do
          v1 < v2 -> {true, has_greater}
          v1 > v2 -> {has_less, true}
          true -> {has_less, has_greater}
        end
      end)

    case {less, greater} do
      {false, false} -> :equal
      {true, false} -> :before
      {false, true} -> :after
      {true, true} -> :concurrent
    end
  end

  @doc """
  Returns true if clock1 happens-before or equals clock2 causally.
  """
  @spec dominates?(t(), t()) :: boolean()
  def dominates?(clock1, clock2) do
    case compare(clock1, clock2) do
      :after -> true
      :equal -> true
      _ -> false
    end
  end

  @doc """
  Returns true if two clocks are concurrent.
  """
  @spec concurrent?(t(), t()) :: boolean()
  def concurrent?(clock1, clock2) do
    compare(clock1, clock2) == :concurrent
  end
end
