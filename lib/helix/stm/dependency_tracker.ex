defmodule Helix.STM.DependencyTracker do
  @moduledoc """
  Dynamic read-write dependency tracker for Block-STM.
  Maintains dependency edges between speculative transactions to identify
  which successor transactions require re-validation when an earlier writer aborts.
  """

  defstruct tx_readers: %{},
            tx_writers: %{}

  @type tx_index :: integer()
  @type t :: %__MODULE__{
          tx_readers: %{tx_index() => MapSet.t(tx_index())},
          tx_writers: %{tx_index() => MapSet.t(tx_index())}
        }

  @doc """
  Initializes an empty dependency tracker.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{tx_readers: %{}, tx_writers: %{}}
  end

  @doc """
  Records that reader_idx read a version produced by writer_idx.
  """
  @spec record_read(t(), tx_index(), tx_index()) :: t()
  def record_read(%__MODULE__{} = tracker, reader_idx, writer_idx) do
    if writer_idx >= 0 and reader_idx != writer_idx do
      current_readers = Map.get(tracker.tx_readers, writer_idx, MapSet.new())

      new_readers =
        Map.put(tracker.tx_readers, writer_idx, MapSet.put(current_readers, reader_idx))

      current_writers = Map.get(tracker.tx_writers, reader_idx, MapSet.new())

      new_writers =
        Map.put(tracker.tx_writers, reader_idx, MapSet.put(current_writers, writer_idx))

      %{tracker | tx_readers: new_readers, tx_writers: new_writers}
    else
      tracker
    end
  end

  @doc """
  Clears historical dependencies for a reader that is being re-executed.
  """
  @spec clear_reader(t(), tx_index()) :: t()
  def clear_reader(%__MODULE__{} = tracker, reader_idx) do
    observed_writers = Map.get(tracker.tx_writers, reader_idx, MapSet.new())

    new_readers =
      Enum.reduce(observed_writers, tracker.tx_readers, fn w, acc ->
        Map.update(acc, w, MapSet.new(), &MapSet.delete(&1, reader_idx))
      end)

    new_writers = Map.delete(tracker.tx_writers, reader_idx)
    %{tracker | tx_readers: new_readers, tx_writers: new_writers}
  end

  @doc """
  Returns all downstream readers that depend on writes from writer_idx.
  """
  @spec dependents_of(t(), tx_index()) :: MapSet.t(tx_index())
  def dependents_of(%__MODULE__{} = tracker, writer_idx) do
    Map.get(tracker.tx_readers, writer_idx, MapSet.new())
  end
end
