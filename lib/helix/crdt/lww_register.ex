defmodule Helix.CRDT.LWWRegister do
  @moduledoc """
  Last-Write-Wins Register (LWW-Register) delta-CRDT.
  Resolves concurrent updates using totally ordered Hybrid Logical Clock (HLC) timestamps.
  Deterministic tie-breaking on node identifiers ensures universal consensus without coordination.
  """

  @behaviour Helix.CRDT.Type

  alias Helix.Core.HybridLogicalClock, as: HLC

  defstruct [
    :value,
    :timestamp,
    delta: nil
  ]

  @type timestamp :: HLC.timestamp()
  @type t :: %__MODULE__{
          value: term() | nil,
          timestamp: timestamp() | nil,
          delta: map() | nil
        }

  @doc """
  Initializes a new empty LWW-Register.
  """
  @spec new(term() | nil, timestamp() | nil) :: t()
  def new(initial_val \\ nil, initial_ts \\ nil) do
    %__MODULE__{
      value: initial_val,
      timestamp: initial_ts,
      delta: nil
    }
  end

  @doc """
  Returns the current value of the register.
  """
  @impl true
  @spec value(t()) :: term() | nil
  def value(%__MODULE__{value: v}), do: v

  @doc """
  Writes a new value with the provided HLC timestamp.
  Only applies if timestamp strictly dominates the current register timestamp.
  """
  @spec write(t(), term(), timestamp()) :: t()
  def write(%__MODULE__{} = reg, val, ts) do
    if should_update?(reg.timestamp, ts) do
      delta = %{value: val, timestamp: ts}
      %{reg | value: val, timestamp: ts, delta: delta}
    else
      reg
    end
  end

  @doc """
  Merges two LWWRegisters by selecting the value with the higher timestamp.
  """
  @impl true
  @spec merge(t(), t() | map()) :: t()
  def merge(%__MODULE__{} = r1, %__MODULE__{} = r2) do
    if should_update?(r1.timestamp, r2.timestamp) do
      %{r1 | value: r2.value, timestamp: r2.timestamp, delta: nil}
    else
      %{r1 | delta: nil}
    end
  end

  def merge(%__MODULE__{} = r1, %{value: v2, timestamp: ts2}) do
    if should_update?(r1.timestamp, ts2) do
      %{r1 | value: v2, timestamp: ts2, delta: nil}
    else
      %{r1 | delta: nil}
    end
  end

  @doc """
  Returns buffered delta if present.
  """
  @impl true
  @spec delta(t()) :: map() | nil
  def delta(%__MODULE__{delta: d}), do: d

  @doc """
  Resets the delta buffer.
  """
  @impl true
  @spec reset_delta(t()) :: t()
  def reset_delta(%__MODULE__{} = reg) do
    %{reg | delta: nil}
  end

  defp should_update?(nil, _new_ts), do: true
  defp should_update?(_cur_ts, nil), do: false

  defp should_update?(cur_ts, new_ts) do
    HLC.compare(cur_ts, new_ts) == :lt
  end
end
