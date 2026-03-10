defmodule Helix.Core.HybridLogicalClock do
  @moduledoc """
  Hybrid Logical Clock (HLC) implementation based on Kulkarni et al.
  Combines physical wall clock monotonicity with logical counters to provide
  strictly causal, totally ordered timestamps without requiring synchronized wall clocks.
  """

  @type node_id :: term()

  defstruct [
    :node_id,
    :physical,
    :logical,
    max_drift: 60_000_000
  ]

  @type t :: %__MODULE__{
          node_id: node_id(),
          physical: non_neg_integer(),
          logical: non_neg_integer(),
          max_drift: non_neg_integer()
        }

  @type timestamp :: %{
          physical: non_neg_integer(),
          logical: non_neg_integer(),
          node_id: node_id()
        }

  @doc """
  Initializes a new Hybrid Logical Clock for the given node.
  """
  @spec new(node_id(), keyword()) :: t()
  def new(node_id, opts \\ []) do
    max_drift = Keyword.get(opts, :max_drift, 60_000_000)
    pt = get_physical_time()

    %__MODULE__{
      node_id: node_id,
      physical: pt,
      logical: 0,
      max_drift: max_drift
    }
  end

  @doc """
  Advances the clock for a local send or event.
  """
  @spec send_event(t(), non_neg_integer() | nil) :: {timestamp(), t()}
  def send_event(%__MODULE__{} = hlc, pt \\ nil) do
    pt_now = pt || get_physical_time()
    l_old = hlc.physical
    c_old = hlc.logical

    l_new = max(l_old, pt_now)

    c_new =
      if l_new == l_old do
        c_old + 1
      else
        0
      end

    new_hlc = %{hlc | physical: l_new, logical: c_new}
    ts = to_timestamp(new_hlc)
    {ts, new_hlc}
  end

  @doc """
  Advances the clock upon receiving a message timestamp from a peer.
  Detects and errors if incoming timestamp exceeds maximum allowable drift.
  """
  @spec recv_event(t(), timestamp(), non_neg_integer() | nil) ::
          {:ok, timestamp(), t()} | {:error, :clock_drift_exceeded}
  def recv_event(%__MODULE__{} = hlc, %{physical: m_l, logical: m_c}, pt \\ nil) do
    pt_now = pt || get_physical_time()

    if m_l - pt_now > hlc.max_drift do
      {:error, :clock_drift_exceeded}
    else
      l_old = hlc.physical
      c_old = hlc.logical

      l_new = max(max(l_old, pt_now), m_l)

      c_new =
        cond do
          l_new == l_old and l_new == m_l -> max(c_old, m_c) + 1
          l_new == l_old -> c_old + 1
          l_new == m_l -> m_c + 1
          true -> 0
        end

      new_hlc = %{hlc | physical: l_new, logical: c_new}
      ts = to_timestamp(new_hlc)
      {:ok, ts, new_hlc}
    end
  end

  @doc """
  Compares two HLC timestamps for total ordering.
  Orders by physical time, then logical counter, then node_id lexicographically.
  """
  @spec compare(timestamp(), timestamp()) :: :lt | :eq | :gt
  def compare(ts1, ts2) do
    cond do
      ts1.physical < ts2.physical -> :lt
      ts1.physical > ts2.physical -> :gt
      ts1.logical < ts2.logical -> :lt
      ts1.logical > ts2.logical -> :gt
      ts1.node_id < ts2.node_id -> :lt
      ts1.node_id > ts2.node_id -> :gt
      true -> :eq
    end
  end

  @doc """
  Converts an HLC struct to a serializable timestamp map.
  """
  @spec to_timestamp(t()) :: timestamp()
  def to_timestamp(%__MODULE__{node_id: id, physical: p, logical: l}) do
    %{node_id: id, physical: p, logical: l}
  end

  defp get_physical_time do
    System.system_time(:microsecond)
  end
end
