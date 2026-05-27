defmodule Helix.STM.Transaction do
  @moduledoc """
  Transaction descriptor and execution context for Block-STM parallel execution.
  Maintains speculative read-sets, write-sets, and incarnation counters.
  """

  alias Helix.Core.Types

  defstruct [
    :id,
    :index,
    :command,
    :exec_fn,
    incarnation: 0,
    status: :pending,
    read_set: %{},
    write_set: %{},
    result: nil
  ]

  @type tx_index :: non_neg_integer()
  @type incarnation :: non_neg_integer()
  @type status :: :pending | :executing | :executed | :aborted | :committed

  @type t :: %__MODULE__{
          id: binary(),
          index: tx_index(),
          command: Types.command() | nil,
          exec_fn: ((term()) -> term()) | nil,
          incarnation: incarnation(),
          status: status(),
          read_set: %{Types.key() => {integer(), incarnation(), term()}},
          write_set: %{Types.key() => term()},
          result: term()
        }

  @doc """
  Initializes a new transaction for block scheduling.
  """
  @spec new(binary(), tx_index(), Types.command() | nil, ((term()) -> term()) | nil) :: t()
  def new(id, index, command \\ nil, exec_fn \\ nil) do
    %__MODULE__{
      id: id,
      index: index,
      command: command,
      exec_fn: exec_fn,
      incarnation: 0,
      status: :pending,
      read_set: %{},
      write_set: %{},
      result: nil
    }
  end

  @doc """
  Increments transaction incarnation upon conflict abort.
  """
  @spec increment_incarnation(t()) :: t()
  def increment_incarnation(%__MODULE__{} = tx) do
    %{tx | incarnation: tx.incarnation + 1, status: :pending, read_set: %{}, write_set: %{}}
  end
end
