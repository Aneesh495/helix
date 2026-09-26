defmodule Helix.Storage.MVCCStore do
  @moduledoc """
  Multi-Version Concurrency Control (MVCC) store supporting historical time-travel queries,
  point-in-time snapshot isolation, and horizon-based version vacuuming.
  """

  alias Helix.Core.Types

  defstruct records: %{}

  @type timestamp :: non_neg_integer()
  @type version_entry :: {timestamp(), term()}

  @type t :: %__MODULE__{
          records: %{Types.key() => [version_entry()]}
        }

  @doc """
  Initializes an empty MVCC store.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{records: %{}}
  end

  @doc """
  Writes a new version of key at the specified timestamp.
  Versions are maintained in reverse chronological order (newest first).
  """
  @spec put(t(), Types.key(), term(), timestamp()) :: t()
  def put(%__MODULE__{} = store, key, value, timestamp) do
    versions = Map.get(store.records, key, [])
    # Insert preserving reverse chronological order
    updated_versions = insert_sorted(versions, {timestamp, value})
    %{store | records: Map.put(store.records, key, updated_versions)}
  end

  @doc """
  Reads the active version of a key at or immediately preceding target timestamp.
  Returns {:ok, value, version_timestamp} or :not_found.
  """
  @spec read_as_of(t(), Types.key(), timestamp()) ::
          {:ok, term(), timestamp()} | :not_found
  def read_as_of(%__MODULE__{} = store, key, target_ts) do
    case Map.get(store.records, key) do
      nil ->
        :not_found

      versions ->
        case Enum.find(versions, fn {ts, _val} -> ts <= target_ts end) do
          {ts, val} -> {:ok, val, ts}
          nil -> :not_found
        end
    end
  end

  @doc """
  Returns the complete version history for a given key.
  """
  @spec history(t(), Types.key()) :: [version_entry()]
  def history(%__MODULE__{} = store, key) do
    Map.get(store.records, key, [])
  end

  @doc """
  Vacuums obsolete versions older than the retention horizon timestamp.
  Retains the most recent version prior to the horizon to preserve current baseline.
  """
  @spec vacuum(t(), timestamp()) :: t()
  def vacuum(%__MODULE__{} = store, horizon_ts) do
    new_records =
      Enum.reduce(store.records, %{}, fn {key, versions}, acc ->
        # Split into versions newer than horizon and versions older than horizon
        {newer, older} = Enum.split_with(versions, fn {ts, _} -> ts > horizon_ts end)

        # Retain at most the single newest version from older to serve as baseline
        retained_older =
          case older do
            [first | _] -> [first]
            [] -> []
          end

        compacted = newer ++ retained_older

        if length(compacted) > 0 do
          Map.put(acc, key, compacted)
        else
          acc
        end
      end)

    %{store | records: new_records}
  end

  defp insert_sorted([], entry), do: [entry]

  defp insert_sorted([{ts, _} = head | tail], {new_ts, _} = entry) do
    if new_ts >= ts do
      [entry, head | tail]
    else
      [head | insert_sorted(tail, entry)]
    end
  end
end
