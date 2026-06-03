defmodule Helix.STM.Validator do
  @moduledoc """
  Read-set validator for Block-STM parallel execution.
  Verifies that speculative reads remain consistent with multi-version state.
  """

  alias Helix.STM.Transaction
  alias Helix.STM.MVMemory

  @doc """
  Validates whether the read-set of an executed transaction is still valid
  against the current multi-version memory state.
  Returns :valid or {:invalid, key, expected_writer, actual_writer}.
  """
  @spec validate(Transaction.t(), MVMemory.t()) ::
          :valid | {:invalid, term(), integer(), integer()}
  def validate(%Transaction{read_set: reads, index: idx}, %MVMemory{} = mem) do
    result =
      Enum.reduce_while(reads, :valid, fn {key, {expected_writer, expected_inc, _val}}, _acc ->
        {:ok, actual_writer, actual_inc, _actual_val} = MVMemory.read(mem, idx, key)

        if actual_writer == expected_writer and actual_inc == expected_inc do
          {:cont, :valid}
        else
          {:halt, {:invalid, key, expected_writer, actual_writer}}
        end
      end)

    result
  end
end
