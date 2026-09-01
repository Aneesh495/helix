defmodule Helix.TUI.Dashboard do
  @moduledoc """
  Interactive terminal dashboard (TUI) with real-time cluster metrics,
  consensus fast-path gauges, latency percentiles, and ASCII topology visualization.
  """

  alias Helix.Telemetry.Metrics

  @doc """
  Starts the interactive live refresh loop.
  """
  def start(metrics \\ nil) do
    m = metrics || Metrics.new()
    render_loop(m)
  end

  @doc """
  Renders a single frame of the dashboard to string or stdout.
  """
  @spec render_frame(Metrics.t(), keyword()) :: String.t()
  def render_frame(%Metrics{} = metrics, opts \\ []) do
    interactive = Keyword.get(opts, :interactive, false)
    p = Metrics.percentiles(metrics)
    fast_ratio = Metrics.fast_path_ratio(metrics)

    schedulers = System.schedulers_online()
    mem_mb = Float.round(:erlang.memory(:total) / (1024 * 1024), 2)
    ets_mb = Float.round(:erlang.memory(:ets) / (1024 * 1024), 2)
    proc_mb = Float.round(:erlang.memory(:processes) / (1024 * 1024), 2)

    sparkline = render_sparkline(metrics.latencies)

    ansi_clear = if interactive, do: "\e[2J\e[H", else: ""

    frame = """
    #{ansi_clear}
    \e[1;36m+=============================================================================+
    |           _    _ ______ _      _______   __   _  ________ _____  _   _ ______ _     |
    |          | |  | |  ____| |    |_   _\\ \\ / /  | |/ /  ____|  __ \\| \\ | |  ____| |    |
    |          | |__| | |__  | |      | |  \\ V /   | ' /| |__  | |__) |  \\| | |__  | |    |
    |          |  __  |  __| | |      | |   > <    |  < |  __| |  _  /| . ` |  __| | |    |
    |          | |  | | |____| |____ _| |_ / . \\   | . \\| |____| | \\ \\| |\\  | |____| |____|
    |          |_|  |_|______|______|_____/_/ \\_\\  |_|\\_\\______|_|  \\_\\_| \\_|______|______|
    |                                                                             |
    |      LEADERLESS DISTRIBUTED TRANSACTION KERNEL // HIGH-CONCURRENCY RUNTIME  |
    +=============================================================================+\e[0m
    \e[1;33m[RUNTIME CLUSTER TELEMETRY]\e[0m
      Schedulers Online : #{schedulers} cores          Total Memory : #{mem_mb} MB
      Process Heaps     : #{proc_mb} MB             ETS Tables   : #{ets_mb} MB
      Node Self         : #{Node.self()}        Active Peers : #{metrics.gauges.cluster_size}

    \e[1;32m[EGALLITARIAN PAXOS CONSENSUS]\e[0m
      Fast-Path Commits : #{metrics.counters.fast_path_commits}                 Slow-Path Commits : #{metrics.counters.slow_path_commits}
      Fast-Path Ratio   : \e[1;32m#{fast_ratio}%\e[0m                 Active Instances  : #{metrics.gauges.active_instances}

    \e[1;35m[BLOCK-STM OPTIMISTIC PARALLEL EXECUTION]\e[0m
      Committed Tx      : #{metrics.counters.stm_commits}                 Speculative Aborts: #{metrics.counters.stm_aborts}
      Contention Rate   : #{if metrics.counters.stm_commits > 0, do: Float.round((metrics.counters.stm_aborts / (metrics.counters.stm_commits + metrics.counters.stm_aborts)) * 100, 2), else: 0.0}%

    \e[1;34m[LATENCY HISTOGRAM (MICROSECONDS)]\e[0m
      p50 : #{p.p50} us    p95 : #{p.p95} us    p99 : #{p.p99} us    p99.9 : #{p.p999} us
      Min : #{p.min} us    Max : #{p.max} us    Avg : #{p.avg} us

    \e[1;37m[THROUGHPUT SPARKLINE]\e[0m
      #{sparkline}
    \e[1;36m+=============================================================================+\e[0m
    """

    frame
  end

  defp render_loop(metrics) do
    frame = render_frame(metrics, interactive: true)
    IO.write(frame)
    Process.sleep(500)
    render_loop(metrics)
  end

  defp render_sparkline([]) do
    "[  -- no active transactions recorded --  ]"
  end

  defp render_sparkline(samples) do
    # Unicode sparkline blocks
    bars = [" ", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    recent = Enum.take(samples, 40) |> Enum.reverse()
    min_v = Enum.min(recent)
    max_v = Enum.max(recent)
    range = max(1, max_v - min_v)

    rendered =
      Enum.map(recent, fn v ->
        idx = min(7, trunc(((v - min_v) / range) * 7))
        Enum.at(bars, idx)
      end)
      |> Enum.join("")

    "\e[1;32m#{rendered}\e[0m (window: #{length(recent)} samples)"
  end
end
