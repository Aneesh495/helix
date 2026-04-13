defmodule Helix.CRDT.PNCounter do
  @moduledoc """
  Positive-Negative Counter (PN-Counter) delta-CRDT.
  Supports concurrent increments and decrements across arbitrary replicas
  with commutative join-semilattice merges.
  """

  @behaviour Helix.CRDT.Type

  defstruct pos: %{},
            neg: %{},
            delta: nil

  @type node_id :: term()
  @type t :: %__MODULE__{
          pos: %{node_id() => non_neg_integer()},
          neg: %{node_id() => non_neg_integer()},
          delta: map() | nil
        }

  @doc """
  Initializes a new PN-Counter.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{pos: %{}, neg: %{}, delta: nil}
  end

  @doc """
  Computes the current net value of the counter.
  """
  @impl true
  @spec value(t()) :: integer()
  def value(%__MODULE__{pos: p, neg: n}) do
    sum_p = Enum.reduce(Map.values(p), 0, &+/2)
    sum_n = Enum.reduce(Map.values(n), 0, &+/2)
    sum_p - sum_n
  end

  @doc """
  Increments the counter for the given node.
  """
  @spec increment(t(), node_id(), pos_integer()) :: t()
  def increment(%__MODULE__{} = counter, node_id, amount \\ 1) when amount > 0 do
    current = Map.get(counter.pos, node_id, 0)
    updated = current + amount
    new_pos = Map.put(counter.pos, node_id, updated)

    delta = %{
      pos: %{node_id => updated},
      neg: %{}
    }

    %{counter | pos: new_pos, delta: delta}
  end

  @doc """
  Decrements the counter for the given node.
  """
  @spec decrement(t(), node_id(), pos_integer()) :: t()
  def decrement(%__MODULE__{} = counter, node_id, amount \\ 1) when amount > 0 do
    current = Map.get(counter.neg, node_id, 0)
    updated = current + amount
    new_neg = Map.put(counter.neg, node_id, updated)

    delta = %{
      pos: %{},
      neg: %{node_id => updated}
    }

    %{counter | neg: new_neg, delta: delta}
  end

  @doc """
  Merges another counter or delta into this counter.
  """
  @impl true
  @spec merge(t(), t() | map()) :: t()
  def merge(%__MODULE__{} = c1, %__MODULE__{} = c2) do
    new_pos = Map.merge(c1.pos, c2.pos, fn _k, v1, v2 -> max(v1, v2) end)
    new_neg = Map.merge(c1.neg, c2.neg, fn _k, v1, v2 -> max(v1, v2) end)
    %{c1 | pos: new_pos, neg: new_neg, delta: nil}
  end

  def merge(%__MODULE__{} = c, %{pos: p2, neg: n2}) do
    new_pos = Map.merge(c.pos, p2, fn _k, v1, v2 -> max(v1, v2) end)
    new_neg = Map.merge(c.neg, n2, fn _k, v1, v2 -> max(v1, v2) end)
    %{c | pos: new_pos, neg: new_neg, delta: nil}
  end

  @doc """
  Returns the buffered delta mutation if present.
  """
  @impl true
  @spec delta(t()) :: map() | nil
  def delta(%__MODULE__{delta: d}), do: d

  @doc """
  Clears the delta buffer after transmission.
  """
  @impl true
  @spec reset_delta(t()) :: t()
  def reset_delta(%__MODULE__{} = counter) do
    %{counter | delta: nil}
  end
end
