defmodule Helix.Net.Codec do
  @moduledoc """
  High-performance binary frame encoder and decoder with CRC-32C payload validation.
  """

  alias Helix.Core.CRC32C
  alias Helix.Net.Protocol

  @magic Protocol.magic()
  @version Protocol.version()
  @header_len Protocol.header_length()

  @doc """
  Encodes a protocol message into a binary frame.
  """
  @spec encode(atom() | non_neg_integer(), non_neg_integer(), term()) :: binary()
  def encode(opcode_spec, correlation_id, payload_term) do
    opcode = if is_atom(opcode_spec), do: Protocol.op(opcode_spec), else: opcode_spec

    payload_bin =
      case payload_term do
        bin when is_binary(bin) -> bin
        nil -> <<>>
        other -> :erlang.term_to_binary(other)
      end

    payload_len = byte_size(payload_bin)
    crc = CRC32C.checksum(payload_bin)

    <<@magic::binary, @version::8, opcode::16, correlation_id::64, payload_len::32, crc::32,
      payload_bin::binary>>
  end

  @doc """
  Decodes a protocol message from a binary frame.
  Returns {:ok, opcode_name, correlation_id, payload, rest} or {:error, reason}.
  """
  @spec decode(binary()) ::
          {:ok, atom(), non_neg_integer(), term(), binary()}
          | {:error, :incomplete | :bad_magic | :crc_mismatch | :unsupported_version}
  def decode(bin) when byte_size(bin) < @header_len do
    {:error, :incomplete}
  end

  def decode(<<@magic::binary, version::8, opcode::16, correlation_id::64, payload_len::32, crc::32, rest::binary>>) do
    if version != @version do
      {:error, :unsupported_version}
    else
      if byte_size(rest) < payload_len do
        {:error, :incomplete}
      else
        <<payload_bin::binary-size(^payload_len), remaining::binary>> = rest
        actual_crc = CRC32C.checksum(payload_bin)

        if actual_crc == crc do
          payload =
            if payload_len == 0 do
              nil
            else
              try do
                :erlang.binary_to_term(payload_bin)
              rescue
                _ -> payload_bin
              end
            end

          {:ok, Protocol.op_name(opcode), correlation_id, payload, remaining}
        else
          {:error, :crc_mismatch}
        end
      end
    end
  end

  def decode(<<_other::binary>>) do
    {:error, :bad_magic}
  end
end
