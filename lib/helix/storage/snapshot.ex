defmodule Helix.Storage.Snapshot do
  @moduledoc """
  Snapshot serialization, compression, and verification manager for Helix state checkpoints.
  Enables accelerated replica bootstrap and WAL truncation without replaying the entire history.
  """

  alias Helix.Core.CRC32C
  alias Helix.Core.SparseMerkleTree, as: SMT

  @magic <<0x53, 0x4E, 0x41, 0x50>>
  @version 1

  defstruct [
    :snapshot_id,
    :seq,
    :state_map,
    :smt_root,
    timestamp: 0
  ]

  @type t :: %__MODULE__{
          snapshot_id: binary(),
          seq: non_neg_integer(),
          state_map: %{binary() => term()},
          smt_root: binary(),
          timestamp: non_neg_integer()
        }

  @doc """
  Creates a new snapshot data structure from current state and SMT root.
  """
  @spec create(binary(), non_neg_integer(), %{binary() => term()}, SMT.t()) :: t()
  def create(id, seq, state_map, %SMT{} = smt) do
    %__MODULE__{
      snapshot_id: id,
      seq: seq,
      state_map: state_map,
      smt_root: SMT.root_hash(smt),
      timestamp: System.system_time(:microsecond)
    }
  end

  @doc """
  Encodes a snapshot into a verified binary format.
  Format: Magic (4B) | Version (2B) | SMTRoot (32B) | Seq (8B) | CRC32C (4B) | PayloadLen (4B) | Payload
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = snap) do
    payload =
      :erlang.term_to_binary(%{
        id: snap.snapshot_id,
        seq: snap.seq,
        state: snap.state_map,
        timestamp: snap.timestamp
      })

    payload_len = byte_size(payload)
    crc = CRC32C.checksum(payload)

    <<@magic::binary, @version::16, snap.smt_root::binary-size(32), snap.seq::64, crc::32, payload_len::32,
      payload::binary>>
  end

  @doc """
  Deserializes and validates a binary snapshot.
  Verifies both Castagnoli CRC-32C payload integrity and SMT root hash commitments.
  """
  @spec deserialize(binary()) :: {:ok, t()} | {:error, term()}
  def deserialize(
        <<@magic::binary, @version::16, smt_root::binary-size(32), seq::64, crc::32, payload_len::32,
          payload::binary-size(payload_len)>>
      ) do
    actual_crc = CRC32C.checksum(payload)

    if actual_crc == crc do
      data = :erlang.binary_to_term(payload)

      # Verify SMT matches materialized state
      test_smt =
        Enum.reduce(data.state, SMT.new(), fn {k, v}, acc ->
          SMT.put(acc, k, v)
        end)

      if SMT.root_hash(test_smt) == smt_root do
        snap = %__MODULE__{
          snapshot_id: data.id,
          seq: seq,
          state_map: data.state,
          smt_root: smt_root,
          timestamp: data.timestamp
        }

        {:ok, snap}
      else
        {:error, :smt_root_mismatch}
      end
    else
      {:error, :crc_mismatch}
    end
  end

  def deserialize(_invalid_binary) do
    {:error, :invalid_snapshot_format}
  end
end
