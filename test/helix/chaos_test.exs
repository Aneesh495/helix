defmodule Helix.ChaosTest do
  use ExUnit.Case, async: false

  alias Helix.Chaos.VirtualClock
  alias Helix.Chaos.SimulatedNetwork
  alias Helix.Chaos.FaultInjector
  alias Helix.Chaos.LinearizabilityChecker
  alias Helix.Chaos.ScenarioRunner
  alias Helix.Core.CRC32C

  describe "Virtual Clock" do
    test "advances time and fires scheduled discrete events" do
      clock = VirtualClock.new()
      assert VirtualClock.now(clock) == 0

      test_pid = self()

      clock =
        clock
        |> VirtualClock.schedule_at(100, :event_1, fn -> send(test_pid, :fired_100) end)
        |> VirtualClock.schedule_at(250, :event_2, fn -> send(test_pid, :fired_250) end)

      # Advance by 50 ticks (reaches 50, neither fires)
      {count, clock} = VirtualClock.advance(clock, 50)
      assert count == 0
      refute_receive :fired_100, 10

      # Advance by 60 ticks (reaches 110, event 1 fires)
      {count, clock} = VirtualClock.advance(clock, 60)
      assert count == 1
      assert_receive :fired_100, 10
      refute_receive :fired_250, 10

      # Advance by 200 ticks (reaches 310, event 2 fires)
      {count, _clock} = VirtualClock.advance(clock, 200)
      assert count == 1
      assert_receive :fired_250, 10
    end
  end

  describe "Simulated Network" do
    test "enforces network partitions and heals" do
      net =
        SimulatedNetwork.new()
        |> SimulatedNetwork.partition(["n1", "n2"], ["n3"])

      assert SimulatedNetwork.route_packet(net, "n1", "n3") == :dropped
      assert SimulatedNetwork.route_packet(net, "n3", "n1") == :dropped
      assert {:deliver, _, _} = SimulatedNetwork.route_packet(net, "n1", "n2")

      healed = SimulatedNetwork.heal(net)
      assert {:deliver, _, _} = SimulatedNetwork.route_packet(healed, "n1", "n3")
    end
  end

  describe "Fault Injector" do
    test "flips bits and invalidates CRC-32C checksums" do
      original = "cryptographically-verified-payload"
      crc = CRC32C.checksum(original)

      corrupted = FaultInjector.flip_bit(original, 12)
      assert corrupted != original
      assert CRC32C.checksum(corrupted) != crc
    end
  end

  describe "Linearizability Checker" do
    test "verifies valid histories and detects stale read violations" do
      # Valid history
      history = [
        %{id: 1, type: :write, key: "x", value: "v1", invoke_time: 10, ok_time: 20},
        %{id: 2, type: :write, key: "x", value: "v2", invoke_time: 25, ok_time: 35},
        %{id: 3, type: :read, key: "x", value: "v2", invoke_time: 40, ok_time: 50}
      ]

      assert {:ok, _} = LinearizabilityChecker.check_register(history)

      # Stale read violation: read occurs strictly after v2 write, but returns stale v1!
      stale_history = [
        %{id: 1, type: :write, key: "x", value: "v1", invoke_time: 10, ok_time: 20},
        %{id: 2, type: :write, key: "x", value: "v2", invoke_time: 25, ok_time: 35},
        %{id: 3, type: :read, key: "x", value: "v1", invoke_time: 40, ok_time: 50}
      ]

      assert {:error, :non_linearizable} = LinearizabilityChecker.check_register(stale_history)
    end
  end

  describe "Scenario Runner" do
    test "executes all chaos scenarios without error" do
      assert :ok = ScenarioRunner.run_all()
    end
  end
end
