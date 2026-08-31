defmodule Helix.Telemetry.Metrics do
  @moduledoc """
  High-resolution latency histograms, throughput meters, and cluster gauges.
  Calculates percentiles (p50, p95, p99, p99.9) and fast-path consensus ratios.
  """

  defstruct [
    latencies: [],
    counters: %{
      fast_path_commits: 0,
      slow_path_commits: 0,
      stm_aborts: 0,
      stm_commits: 0,
      gossip_messages: 0
    },
    gauges: %{
      active_instances: 0,
      cluster_size: 1
    }
  ]

  @type t :: %__MODULE__{
          latencies: [non_neg_integer()],
          counters: %{atom() => non_neg_integer()},
          gauges: %{atom() => number()}
        }

  @doc """
  Initializes an empty metrics tracker.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      latencies: [],
      counters: %{
        fast_path_commits: 0,
        slow_path_commits: 0,
        stm_aborts: 0,
        stm_commits: 0,
        gossip_messages: 0
      },
      gauges: %{
        active_instances: 0,
        cluster_size: 1
      }
    }
  end

  @doc """
  Records a latency measurement in microseconds.
  """
  @spec record_latency(t(), non_neg_integer()) :: t()
  def record_latency(%__MODULE__{} = m, duration_us) when duration_us >= 0 do
    # Maintain sliding window of up to 10,000 latency measurements
    updated_latencies = Enum.take([duration_us | m.latencies], 10_000)
    %{m | latencies: updated_latencies}
  end

  @doc """
  Increments a named counter.
  """
  @spec inc(t(), atom(), non_neg_integer()) :: t()
  def inc(%__MODULE__{} = m, counter_name, amount \\ 1) do
    new_counters = Map.update(m.counters, counter_name, amount, &(&1 + amount))
    %{m | counters: new_counters}
  end

  @doc """
  Sets a gauge metric.
  """
  @spec set_gauge(t(), atom(), number()) :: t()
  def set_gauge(%__MODULE__{} = m, gauge_name, value) do
    new_gauges = Map.put(m.gauges, gauge_name, value)
    %{m | gauges: new_gauges}
  end

  @doc """
  Calculates latency percentiles across the sample window.
  Returns %{p50: float, p95: float, p99: float, p999: float, min: integer, max: integer, avg: float}.
  """
  @spec percentiles(t()) :: map()
  def percentiles(%__MODULE__{latencies: []}) do
    %{p50: 0.0, p95: 0.0, p99: 0.0, p999: 0.0, min: 0, max: 0, avg: 0.0}
  end

  def percentiles(%__MODULE__{latencies: list}) do
    sorted = Enum.sort(list)
    len = length(sorted)

    p50_idx = min(len - 1, trunc(len * 0.50))
    p95_idx = min(len - 1, trunc(len * 0.95))
    p99_idx = min(len - 1, trunc(len * 0.99))
    p999_idx = min(len - 1, trunc(len * 0.999))

    sum = Enum.sum(sorted)

    %{
      p50: Enum.at(sorted, p50_idx) * 1.0,
      p95: Enum.at(sorted, p95_idx) * 1.0,
      p99: Enum.at(sorted, p99_idx) * 1.0,
      p999: Enum.at(sorted, p999_idx) * 1.0,
      min: hd(sorted),
      max: List.last(sorted),
      avg: Float.round(sum / len, 2)
    }
  end

  @doc """
  Calculates the EPaxos fast-path ratio as a percentage.
  """
  @spec fast_path_ratio(t()) :: float()
  def fast_path_ratio(%__MODULE__{counters: c}) do
    fast = Map.get(c, :fast_path_commits, 0)
    slow = Map.get(c, :slow_path_commits, 0)
    total = fast + slow

    if total == 0 do
      100.0
    else
      Float.round((fast / total) * 100.0, 2)
    end
  end
end
