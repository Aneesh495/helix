defmodule Helix.Consensus.ConflictDetector do
  @moduledoc """
  In-memory index for fast transaction dependency discovery and sequence number derivation.
  Maps keys to historical reader and writer instance IDs.
  """

  alias Helix.Core.Types

  defstruct key_writers: %{},
            key_readers: %{},
            instance_seqs: %{}

  @type instance_id :: Types.instance_id()
  @type t :: %__MODULE__{
          key_writers: %{Types.key() => [instance_id()]},
          key_readers: %{Types.key() => [instance_id()]},
          instance_seqs: %{instance_id() => non_neg_integer()}
        }

  @doc """
  Initializes an empty conflict detector.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      key_writers: %{},
      key_readers: %{},
      instance_seqs: %{}
    }
  end

  @doc """
  Finds all conflicting instances for a proposed command, returning the dependency set
  and the minimum valid sequence number (1 + max(seq of conflicting instances)).
  """
  @spec find_conflicts(t(), Types.command(), instance_id()) :: {MapSet.t(instance_id()), non_neg_integer()}
  def find_conflicts(%__MODULE__{} = detector, %{read_keys: reads, write_keys: writes}, current_id) do
    # Conflicts for reads: any prior writer to this key
    read_conflicts =
      Enum.flat_map(reads, fn key ->
        Map.get(detector.key_writers, key, [])
      end)

    # Conflicts for writes: any prior reader or writer to this key
    write_conflicts =
      Enum.flat_map(writes, fn key ->
        writers = Map.get(detector.key_writers, key, [])
        readers = Map.get(detector.key_readers, key, [])
        writers ++ readers
      end)

    # Remove self and deduplicate into MapSet
    deps =
      (read_conflicts ++ write_conflicts)
      |> Enum.reject(&(&1 == current_id))
      |> MapSet.new()

    # Calculate sequence number: 1 + max(deps.seq)
    max_dep_seq =
      Enum.reduce(deps, 0, fn dep_id, max_s ->
        seq = Map.get(detector.instance_seqs, dep_id, 0)
        max(max_s, seq)
      end)

    {deps, max_dep_seq + 1}
  end

  @doc """
  Records an instance and updates the key indices.
  """
  @spec record(t(), instance_id(), Types.command() | nil, non_neg_integer()) :: t()
  def record(%__MODULE__{} = detector, _id, nil, _seq), do: detector

  def record(%__MODULE__{} = detector, id, %{read_keys: reads, write_keys: writes}, seq) do
    new_writers =
      Enum.reduce(writes, detector.key_writers, fn key, acc ->
        Map.update(acc, key, [id], &[id | &1])
      end)

    new_readers =
      Enum.reduce(reads, detector.key_readers, fn key, acc ->
        Map.update(acc, key, [id], &[id | &1])
      end)

    new_seqs = Map.put(detector.instance_seqs, id, seq)

    %{detector | key_writers: new_writers, key_readers: new_readers, instance_seqs: new_seqs}
  end

  @doc """
  Prunes executed instances from the conflict index to keep memory bounded.
  """
  @spec prune(t(), instance_id(), Types.command() | nil) :: t()
  def prune(%__MODULE__{} = detector, _id, nil), do: detector

  def prune(%__MODULE__{} = detector, id, %{read_keys: reads, write_keys: writes}) do
    new_writers =
      Enum.reduce(writes, detector.key_writers, fn key, acc ->
        Map.update(acc, key, [], &List.delete(&1, id))
      end)

    new_readers =
      Enum.reduce(reads, detector.key_readers, fn key, acc ->
        Map.update(acc, key, [], &List.delete(&1, id))
      end)

    new_seqs = Map.delete(detector.instance_seqs, id)

    %{detector | key_writers: new_writers, key_readers: new_readers, instance_seqs: new_seqs}
  end
end
