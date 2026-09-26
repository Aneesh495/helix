defmodule Helix.Core.BloomFilter do
  @moduledoc """
  Space-efficient Bloom filter using Kirsch-Mitzenmacher double hashing
  for fast negative membership queries on transaction dependency sets.
  """

  defstruct [
    :size_bits,
    :num_hashes,
    :bitmap
  ]

  @type t :: %__MODULE__{
          size_bits: pos_integer(),
          num_hashes: pos_integer(),
          bitmap: binary()
        }

  @doc """
  Initializes a new Bloom filter with optimal parameters for expected item count
  and target false positive probability.
  """
  @spec new(pos_integer(), float()) :: t()
  def new(expected_items, false_positive_rate \\ 0.01)
      when expected_items > 0 and false_positive_rate > 0 and false_positive_rate < 1 do
    # m = - (n * ln(p)) / (ln(2)^2)
    ln2 = :math.log(2)
    m = -1 * (expected_items * :math.log(false_positive_rate)) / (ln2 * ln2)
    size_bits = max(64, trunc(:math.ceil(m)))
    # k = (m / n) * ln(2)
    k = max(1, round(size_bits / expected_items * ln2))

    size_bytes = div(size_bits + 7, 8)
    bitmap = :binary.copy(<<0>>, size_bytes)

    %__MODULE__{
      size_bits: size_bits,
      num_hashes: k,
      bitmap: bitmap
    }
  end

  @doc """
  Inserts an element into the Bloom filter.
  """
  @spec add(t(), binary()) :: t()
  def add(%__MODULE__{} = filter, item) when is_binary(item) do
    hashes = generate_hashes(item, filter.size_bits, filter.num_hashes)

    new_bitmap =
      Enum.reduce(hashes, filter.bitmap, fn bit_idx, acc_bitmap ->
        set_bit(acc_bitmap, bit_idx)
      end)

    %{filter | bitmap: new_bitmap}
  end

  @doc """
  Checks if an element is probably in the filter, or definitely not in the filter.
  """
  @spec member?(t(), binary()) :: boolean()
  def member?(%__MODULE__{} = filter, item) when is_binary(item) do
    hashes = generate_hashes(item, filter.size_bits, filter.num_hashes)

    Enum.all?(hashes, fn bit_idx ->
      get_bit(filter.bitmap, bit_idx) == 1
    end)
  end

  @doc """
  Performs bitwise union of two identical dimension Bloom filters.
  """
  @spec union(t(), t()) :: t()
  def union(%__MODULE__{size_bits: s, num_hashes: k, bitmap: b1}, %__MODULE__{
        size_bits: s,
        num_hashes: k,
        bitmap: b2
      }) do
    # Bitwise OR across all bytes
    merged =
      :erlang.binary_to_list(b1)
      |> Enum.zip(:erlang.binary_to_list(b2))
      |> Enum.map(fn {byte1, byte2} -> Bitwise.bor(byte1, byte2) end)
      |> :erlang.list_to_binary()

    %__MODULE__{size_bits: s, num_hashes: k, bitmap: merged}
  end

  # Kirsch-Mitzenmacher double hashing: g_i(x) = (h1(x) + i * h2(x)) mod m
  defp generate_hashes(item, m, k) do
    <<h1::64, h2::64, _rest::binary>> = :crypto.hash(:sha256, item)

    Enum.map(0..(k - 1), fn i ->
      rem(h1 + i * h2, m)
    end)
  end

  defp set_bit(bitmap, bit_index) do
    byte_index = div(bit_index, 8)
    bit_offset = 7 - rem(bit_index, 8)
    byte = :binary.at(bitmap, byte_index)
    updated_byte = Bitwise.bor(byte, Bitwise.bsl(1, bit_offset))

    prefix = :binary.part(bitmap, 0, byte_index)
    suffix = :binary.part(bitmap, byte_index + 1, byte_size(bitmap) - byte_index - 1)
    <<prefix::binary, updated_byte::8, suffix::binary>>
  end

  defp get_bit(bitmap, bit_index) do
    byte_index = div(bit_index, 8)
    bit_offset = 7 - rem(bit_index, 8)
    byte = :binary.at(bitmap, byte_index)
    Bitwise.band(Bitwise.bsr(byte, bit_offset), 1)
  end
end
