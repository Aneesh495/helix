defmodule Helix.Core.Bitset do
  @moduledoc """
  Compact integer-backed bitset for fast quorum calculation, replica vote tracking,
  and membership bitmasks.
  """

  import Bitwise

  defstruct mask: 0

  @type t :: %__MODULE__{mask: non_neg_integer()}

  @doc """
  Creates a new empty bitset.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{mask: 0}

  @doc """
  Creates a bitset initialized from a list of integer indices.
  """
  @spec from_list([non_neg_integer()]) :: t()
  def from_list(indices) when is_list(indices) do
    Enum.reduce(indices, new(), fn idx, acc -> set(acc, idx) end)
  end

  @doc """
  Sets the bit at the given index.
  """
  @spec set(t(), non_neg_integer()) :: t()
  def set(%__MODULE__{mask: m}, index) when is_integer(index) and index >= 0 do
    %__MODULE__{mask: bor(m, bsl(1, index))}
  end

  @doc """
  Clears the bit at the given index.
  """
  @spec unset(t(), non_neg_integer()) :: t()
  def unset(%__MODULE__{mask: m}, index) when is_integer(index) and index >= 0 do
    %__MODULE__{mask: band(m, bnot(bsl(1, index)))}
  end

  @doc """
  Checks if the bit at the given index is set.
  """
  @spec member?(t(), non_neg_integer()) :: boolean()
  def member?(%__MODULE__{mask: m}, index) when is_integer(index) and index >= 0 do
    band(m, bsl(1, index)) != 0
  end

  @doc """
  Returns the number of set bits (population count / Hamming weight).
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{mask: m}) do
    popcount(m, 0)
  end

  defp popcount(0, acc), do: acc

  defp popcount(n, acc) do
    # Brian Kernighan algorithm: clears lowest set bit
    popcount(band(n, n - 1), acc + 1)
  end

  @doc """
  Computes the bitwise union of two bitsets.
  """
  @spec union(t(), t()) :: t()
  def union(%__MODULE__{mask: m1}, %__MODULE__{mask: m2}) do
    %__MODULE__{mask: bor(m1, m2)}
  end

  @doc """
  Computes the bitwise intersection of two bitsets.
  """
  @spec intersection(t(), t()) :: t()
  def intersection(%__MODULE__{mask: m1}, %__MODULE__{mask: m2}) do
    %__MODULE__{mask: band(m1, m2)}
  end

  @doc """
  Converts the set bits into a list of indices.
  """
  @spec to_list(t()) :: [non_neg_integer()]
  def to_list(%__MODULE__{mask: m}) do
    do_to_list(m, 0, [])
  end

  defp do_to_list(0, _idx, acc), do: Enum.reverse(acc)

  defp do_to_list(n, idx, acc) do
    if band(n, 1) == 1 do
      do_to_list(bsr(n, 1), idx + 1, [idx | acc])
    else
      do_to_list(bsr(n, 1), idx + 1, acc)
    end
  end
end
