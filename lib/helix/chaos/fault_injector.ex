defmodule Helix.Chaos.FaultInjector do
  @moduledoc """
  Fault injection utility for process crash simulation, clock skewing, and bit-level corruption.
  """

  @doc """
  Ungracefully terminates a target process with an exit signal.
  """
  @spec crash_process(pid() | atom()) :: :ok
  def crash_process(target) do
    pid = if is_atom(target), do: Process.whereis(target), else: target

    if pid && Process.alive?(pid) do
      Process.exit(pid, :kill)
      :ok
    else
      :ok
    end
  end

  @doc """
  Injects synthetic clock skew into an HLC timestamp.
  """
  @spec skew_timestamp(map(), integer()) :: map()
  def skew_timestamp(%{physical: p} = ts, skew_microseconds) do
    %{ts | physical: max(0, p + skew_microseconds)}
  end

  @doc """
  Flips a single random bit in a binary payload to test checksum and CRC validation.
  """
  def flip_bit(binary, bit_position \\ nil)

  def flip_bit(<<>>, _pos), do: <<>>

  def flip_bit(binary, bit_position) when is_binary(binary) do
    total_bits = byte_size(binary) * 8
    target_bit = bit_position || :rand.uniform(total_bits) - 1

    byte_index = div(target_bit, 8)
    bit_offset = 7 - rem(target_bit, 8)

    byte = :binary.at(binary, byte_index)
    corrupted_byte = Bitwise.bxor(byte, Bitwise.bsl(1, bit_offset))

    prefix = :binary.part(binary, 0, byte_index)
    suffix = :binary.part(binary, byte_index + 1, byte_size(binary) - byte_index - 1)
    <<prefix::binary, corrupted_byte::8, suffix::binary>>
  end
end
