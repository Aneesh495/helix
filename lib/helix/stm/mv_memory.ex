defmodule Helix.STM.MVMemory do
  @moduledoc """
  Multi-Version In-Memory State Store (MVMemory) for Block-STM.
  Stores versioned key-value entries across speculative transaction indices.
  """

  alias Helix.Core.Types

  defstruct [
    base_state: %{},
    versions: %{}
  ]

  @type tx_index :: integer()
  @type incarnation :: non_neg_integer()
  @type version_entry :: {incarnation(), term()}

  @type t :: %__MODULE__{
          base_state: %{Types.key() => term()},
          versions: %{Types.key() => %{tx_index() => version_entry()}}
        }

  @doc """
  Initializes a new MVMemory with an optional base state.
  """
  @spec new(%{Types.key() => term()}) :: t()
  def new(base_state \\ %{}) do
    %__MODULE__{
      base_state: base_state,
      versions: %{}
    }
  end

  @doc """
  Reads a key from MVMemory from the perspective of transaction `tx_index`.
  Finds the highest predecessor writer j < tx_index.
  Returns {:ok, writer_index, incarnation, value}.
  """
  @spec read(t(), non_neg_integer(), Types.key()) ::
          {:ok, integer(), incarnation(), term()}
  def read(%__MODULE__{} = mem, tx_index, key) do
    key_versions = Map.get(mem.versions, key, %{})

    # Find highest predecessor writer index < tx_index
    predecessors =
      Enum.filter(key_versions, fn {writer_idx, _entry} ->
        writer_idx < tx_index
      end)

    if length(predecessors) > 0 do
      {best_writer_idx, {inc, val}} =
        Enum.max_by(predecessors, fn {writer_idx, _} -> writer_idx end)

      {:ok, best_writer_idx, inc, val}
    else
      # Fall back to base state (-1)
      val = Map.get(mem.base_state, key, nil)
      {:ok, -1, 0, val}
    end
  end

  @doc """
  Records the writes produced by a transaction at given incarnation.
  """
  @spec write(t(), non_neg_integer(), incarnation(), %{Types.key() => term()}) :: t()
  def write(%__MODULE__{} = mem, tx_index, incarnation, write_set) when is_map(write_set) do
    new_versions =
      Enum.reduce(write_set, mem.versions, fn {key, val}, acc ->
        key_map = Map.get(acc, key, %{})
        updated_key_map = Map.put(key_map, tx_index, {incarnation, val})
        Map.put(acc, key, updated_key_map)
      end)

    %{mem | versions: new_versions}
  end

  @doc """
  Rolls back writes made by an aborted transaction index.
  """
  @spec rollback(t(), non_neg_integer()) :: t()
  def rollback(%__MODULE__{} = mem, tx_index) do
    new_versions =
      Enum.reduce(mem.versions, %{}, fn {key, key_map}, acc ->
        updated_map = Map.delete(key_map, tx_index)

        if map_size(updated_map) > 0 do
          Map.put(acc, key, updated_map)
        else
          acc
        end
      end)

    %{mem | versions: new_versions}
  end

  @doc """
  Materializes the final state after all block transactions have committed.
  Applies writes sequentially from index 0 to max_index.
  """
  @spec materialize(t(), non_neg_integer()) :: %{Types.key() => term()}
  def materialize(%__MODULE__{} = mem, total_txs) do
    Enum.reduce(0..(total_txs - 1), mem.base_state, fn idx, acc_state ->
      Enum.reduce(mem.versions, acc_state, fn {key, key_map}, inner_acc ->
        case Map.get(key_map, idx) do
          {_inc, val} -> Map.put(inner_acc, key, val)
          nil -> inner_acc
        end
      end)
    end)
  end
end
