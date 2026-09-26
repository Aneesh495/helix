defmodule Helix.Core.CRC32C do
  @moduledoc """
  Castagnoli CRC-32C checksum implementation using polynomial 0x82F63B78.
  Provides network wire packet verification and WAL segment integrity checking.
  """

  import Bitwise

  @polynomial 0x82F63B78

  # Generate 256-entry lookup table at compile time
  @table (for i <- 0..255 do
            crc =
              Enum.reduce(0..7, i, fn _bit, acc ->
                if band(acc, 1) == 1 do
                  bxor(bsr(acc, 1), @polynomial)
                else
                  bsr(acc, 1)
                end
              end)

            crc
          end)
         |> List.to_tuple()

  @doc """
  Computes the 32-bit CRC-32C Castagnoli checksum of a binary.
  """
  @spec checksum(binary()) :: non_neg_integer()
  def checksum(binary) when is_binary(binary) do
    crc = do_crc(binary, 0xFFFFFFFF)
    bxor(crc, 0xFFFFFFFF)
  end

  defp do_crc(<<>>, crc), do: crc

  defp do_crc(<<byte::8, rest::binary>>, crc) do
    table_index = band(bxor(crc, byte), 0xFF)
    table_entry = elem(@table, table_index)
    new_crc = bxor(bsr(crc, 8), table_entry)
    do_crc(rest, new_crc)
  end
end
