defmodule Helix.TelemetryTest do
  use ExUnit.Case, async: true

  alias Helix.Telemetry.Metrics
  alias Helix.TUI.Dashboard
  alias Helix.Benchmark

  describe "Metrics & Percentiles" do
    test "records latency measurements and calculates exact percentiles" do
      m = Metrics.new()

      # Add 100 measurements: 1 to 100 us
      m =
        Enum.reduce(1..100, m, fn i, acc ->
          Metrics.record_latency(acc, i)
        end)

      p = Metrics.percentiles(m)
      assert p.min == 1
      assert p.max == 100
      assert p.p50 == 51.0
      assert p.p95 == 96.0
      assert p.p99 == 100.0
      assert p.avg == 50.5
    end

    test "computes fast-path consensus ratio" do
      m =
        Metrics.new()
        |> Metrics.inc(:fast_path_commits, 80)
        |> Metrics.inc(:slow_path_commits, 20)

      assert Metrics.fast_path_ratio(m) == 80.0
    end
  end

  describe "Terminal TUI Dashboard" do
    test "renders dashboard frame string with sparklines" do
      m =
        Metrics.new()
        |> Metrics.record_latency(150)
        |> Metrics.record_latency(200)
        |> Metrics.inc(:fast_path_commits, 10)
        |> Metrics.set_gauge(:cluster_size, 3)

      frame = Dashboard.render_frame(m, interactive: false)
      assert is_binary(frame)
      assert String.contains?(frame, "LEADERLESS DISTRIBUTED TRANSACTION KERNEL")
      assert String.contains?(frame, "EGALLITARIAN PAXOS CONSENSUS")
      assert String.contains?(frame, "BLOCK-STM OPTIMISTIC PARALLEL EXECUTION")
    end
  end

  describe "Benchmark Suite" do
    test "runs benchmark benchmarks without crashing" do
      assert :ok = Benchmark.run()
    end
  end
end
