defmodule Helix.CRDTTest do
  use ExUnit.Case, async: true

  alias Helix.CRDT.PNCounter
  alias Helix.CRDT.AWSet
  alias Helix.CRDT.MVRegister
  alias Helix.CRDT.LWWRegister
  alias Helix.CRDT.ORMap
  alias Helix.CRDT.ReplicationEngine
  alias Helix.Core.HybridLogicalClock, as: HLC

  describe "PN-Counter" do
    test "converges under concurrent increments and decrements" do
      c1 = PNCounter.new() |> PNCounter.increment("node1", 10)
      c2 = PNCounter.new() |> PNCounter.decrement("node2", 4)

      # Merge c1 and c2
      merged = PNCounter.merge(c1, c2)
      assert PNCounter.value(merged) == 6

      # Delta merge
      c1_delta = PNCounter.delta(c1)
      c2_updated = PNCounter.merge(c2, c1_delta)
      assert PNCounter.value(c2_updated) == 6
    end
  end

  describe "AWSet (Add-Wins Set)" do
    test "add wins over concurrent remove" do
      # Start with common element "item_x"
      base = AWSet.new() |> AWSet.add("item_x", "node1")

      # Node 1 removes "item_x"
      s1 = AWSet.remove(base, "item_x")
      assert AWSet.member?(s1, "item_x") == false

      # Concurrently, Node 2 re-adds "item_x"
      s2 = AWSet.add(base, "item_x", "node2")
      assert AWSet.member?(s2, "item_x") == true

      # Merge: since node 2 add generated a fresh dot not covered by node 1 remove, Add wins!
      merged = AWSet.merge(s1, s2)
      assert AWSet.member?(merged, "item_x") == true

      # Idempotence & Commutativity
      merged_rev = AWSet.merge(s2, s1)
      assert AWSet.value(merged) == AWSet.value(merged_rev)
    end
  end

  describe "MVRegister (Multi-Value Register)" do
    test "retains concurrent values and collapses on sequential write" do
      r1 = MVRegister.new() |> MVRegister.write("value_a", "node1")
      r2 = MVRegister.new() |> MVRegister.write("value_b", "node2")

      # Merge reveals concurrent conflict
      merged = MVRegister.merge(r1, r2)
      concurrent_vals = Enum.sort(MVRegister.value(merged))
      assert concurrent_vals == ["value_a", "value_b"]

      # Node 1 writes successor value, resolving conflict
      r_resolved = MVRegister.write(merged, "value_c", "node1")
      assert MVRegister.value(r_resolved) == ["value_c"]
    end
  end

  describe "LWWRegister (Last-Write-Wins Register)" do
    test "deterministically resolves concurrent writes via HLC timestamps" do
      hlc1 = HLC.new("node1")
      hlc2 = HLC.new("node2")

      {ts1, _} = HLC.send_event(hlc1, 100_000)
      {ts2, _} = HLC.send_event(hlc2, 200_000)

      reg1 = LWWRegister.new() |> LWWRegister.write("older", ts1)
      reg2 = LWWRegister.new() |> LWWRegister.write("newer", ts2)

      merged = LWWRegister.merge(reg1, reg2)
      assert LWWRegister.value(merged) == "newer"

      merged_rev = LWWRegister.merge(reg2, reg1)
      assert LWWRegister.value(merged_rev) == "newer"
    end
  end

  describe "ORMap (Observed-Remove Map)" do
    test "supports nested CRDTs with key addition and removal" do
      map1 =
        ORMap.new()
        |> ORMap.put_crdt("counter_key", PNCounter, PNCounter.new() |> PNCounter.increment("n1", 5), "n1")

      map2 =
        ORMap.new()
        |> ORMap.put_crdt("counter_key", PNCounter, PNCounter.new() |> PNCounter.increment("n2", 7), "n2")

      merged = ORMap.merge(map1, map2)
      assert ORMap.value(merged) == %{"counter_key" => 12}

      # Evict key on one replica
      evicted = ORMap.remove(merged, "counter_key")
      assert ORMap.value(evicted) == %{}
    end
  end

  describe "Replication Engine" do
    test "synchronizes delta mutations between two peer engines" do
      # Peer 2 inbox for deltas
      test_pid = self()

      {:ok, engine1} =
        ReplicationEngine.start_link(
          node_id: "node_1",
          broadcast_fn: fn id, delta ->
            send(test_pid, {:delta_from_1, id, delta})
          end
        )

      {:ok, engine2} =
        ReplicationEngine.start_link(node_id: "node_2")

      # Register counter on engine1 and engine2
      ReplicationEngine.register_crdt(engine1, :hits, PNCounter, PNCounter.new())
      ReplicationEngine.register_crdt(engine2, :hits, PNCounter, PNCounter.new())

      # Update on engine1
      {:ok, 42} = ReplicationEngine.update_crdt(engine1, :hits, fn c -> PNCounter.increment(c, "node_1", 42) end)

      # Trigger sync broadcast
      ReplicationEngine.sync_now(engine1)

      # Receive broadcast and feed to engine2
      assert_receive {:delta_from_1, :hits, delta}, 1000
      ReplicationEngine.apply_delta(engine2, "node_1", :hits, delta)

      # Engine 2 should now have the synced value
      assert {:ok, 42} = ReplicationEngine.read_crdt(engine2, :hits)
    end
  end
end
