defmodule Helix.Core.Varint do
  @moduledoc """
  LEB128 variable-length integer codec for compact binary wire framing.
  Supports unsigned 64-bit integers and ZigZag-encoded signed integers.
  """

  import Bitwise

  @doc """
  Encodes an unsigned integer into an LEB128 binary sequence.
  """
  @spec encode_unsigned(non_neg_integer()) :: binary()
  def encode_unsigned(val) when is_integer(val) and val >= 0 do
    do_encode_u(val, <<>>)
  end

  defp do_encode_u(val, acc) when val < 128 do
    <<acc::binary, val::8>>
  end

  defp do_encode_u(val, acc) do
    byte = bor(band(val, 0x7F), 0x80)
    do_encode_u(bsr(val, 7), <<acc::binary, byte::8>>)
  end

  @doc """
  Decodes an unsigned LEB128 binary sequence.
  Returns {:ok, value, rest} or {:error, :incomplete}.
  """
  @spec decode_unsigned(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, :incomplete}
  def decode_unsigned(bin) when is_binary(bin) do
    do_decode_u(bin, 0, 0)
  end

  defp do_decode_u(<<>>, _shift, _acc), do: {:error, :incomplete}

  defp do_decode_u(<<byte::8, rest::binary>>, shift, acc) do
    val = band(byte, 0x7F)
    new_acc = acc + bsl(val, shift)

    if band(byte, 0x80) == 0 do
      {:ok, new_acc, rest}
    else
      do_decode_u(rest, shift + 7, new_acc)
    end
  end

  @doc """
  Encodes a signed integer using ZigZag encoding into an LEB128 binary.
  """
  @spec encode_signed(integer()) :: binary()
  def encode_signed(val) when is_integer(val) do
    zigzag =
      if val >= 0 do
        val * 2
      else
        -val * 2 - 1
      end

    encode_unsigned(zigzag)
  end

  @doc """
  Decodes a ZigZag-encoded signed integer from an LEB128 binary.
  """
  @spec decode_signed(binary()) :: {:ok, integer(), binary()} | {:error, :incomplete}
  def decode_signed(bin) when is_binary(bin) do
    case decode_unsigned(bin) do
      {:ok, zigzag, rest} ->
        val =
          if rem(zigzag, 2) == 0 do
            div(zigzag, 2)
          else
            -div(zigzag + 1, 2)
          end

        {:ok, val, rest}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
