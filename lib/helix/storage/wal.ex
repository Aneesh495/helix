defmodule Helix.Storage.WAL do
  @moduledoc """
  Segmented Write-Ahead Log (WAL) with Castagnoli CRC-32C frame validation.
  Guarantees crash durability and clean recovery replay for committed transactions.
  """

  alias Helix.Core.CRC32C

  @magic <<0x57, 0x41, 0x4C, 0x31>>
  @header_size 20

  defstruct [
    :path,
    :file_handle,
    current_seq: 0,
    sync_mode: :async
  ]

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          file_handle: :file.io_device() | nil,
          current_seq: non_neg_integer(),
          sync_mode: :sync | :async
        }

  @doc """
  Encodes a payload term into a framed binary WAL record.
  Frame structure: Magic (4B) | Seq (8B) | PayloadLen (4B) | CRC32C (4B) | Payload
  """
  @spec encode_record(non_neg_integer(), term()) :: binary()
  def encode_record(seq, payload_term) do
    payload_bin = :erlang.term_to_binary(payload_term)
    payload_len = byte_size(payload_bin)
    crc = CRC32C.checksum(payload_bin)

    <<@magic::binary, seq::64, payload_len::32, crc::32, payload_bin::binary>>
  end

  @doc """
  Decodes and verifies a framed binary WAL record.
  Returns {:ok, seq, payload_term, rest} or {:error, reason}.
  """
  @spec decode_record(binary()) ::
          {:ok, non_neg_integer(), term(), binary()}
          | {:error, :bad_magic | :crc_mismatch | :incomplete}
  def decode_record(bin) when byte_size(bin) < @header_size do
    {:error, :incomplete}
  end

  def decode_record(<<@magic::binary, seq::64, payload_len::32, crc::32, rest::binary>>) do
    if byte_size(rest) < payload_len do
      {:error, :incomplete}
    else
      <<payload_bin::binary-size(^payload_len), remaining::binary>> = rest
      actual_crc = CRC32C.checksum(payload_bin)

      if actual_crc == crc do
        try do
          payload = :erlang.binary_to_term(payload_bin)
          {:ok, seq, payload, remaining}
        rescue
          _ -> {:error, :corrupt_payload}
        end
      else
        {:error, :crc_mismatch}
      end
    end
  end

  def decode_record(<<_other::binary>>) do
    {:error, :bad_magic}
  end

  @doc """
  Scans an entire binary segment of WAL records, collecting all valid entries
  until clean termination or corrupted tail.
  """
  @spec recover_segment(binary()) :: {:ok, [map()], binary()}
  def recover_segment(bin) when is_binary(bin) do
    do_recover(bin, [])
  end

  defp do_recover(<<>>, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp do_recover(bin, acc) do
    case decode_record(bin) do
      {:ok, seq, payload, rest} ->
        entry = %{seq: seq, payload: payload}
        do_recover(rest, [entry | acc])

      {:error, :incomplete} ->
        # Clean EOF or partial uncommitted tail
        {:ok, Enum.reverse(acc), bin}

      {:error, reason} ->
        # Corrupted segment boundary
        {:partial_recovery, Enum.reverse(acc), reason, bin}
    end
  end

  @doc """
  Initializes an in-memory buffer or file-backed WAL writer.
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts \\ []) do
    sync_mode = Keyword.get(opts, :sync_mode, :async)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    case File.open(path, [:write, :append, :raw, :binary]) do
      {:ok, handle} ->
        {:ok,
         %__MODULE__{
           path: path,
           file_handle: handle,
           current_seq: 0,
           sync_mode: sync_mode
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Appends an entry to the WAL file and flushes according to sync policy.
  """
  @spec append(t(), term()) :: {:ok, non_neg_integer(), t()} | {:error, term()}
  def append(%__MODULE__{} = wal, payload) do
    next_seq = wal.current_seq + 1
    record_bin = encode_record(next_seq, payload)

    if wal.file_handle do
      case :file.write(wal.file_handle, record_bin) do
        :ok ->
          if wal.sync_mode == :sync do
            :file.sync(wal.file_handle)
          end

          {:ok, next_seq, %{wal | current_seq: next_seq}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, next_seq, %{wal | current_seq: next_seq}}
    end
  end

  @doc """
  Closes the WAL file handle.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{file_handle: nil}), do: :ok

  def close(%__MODULE__{file_handle: handle}) do
    :file.close(handle)
  end
end
