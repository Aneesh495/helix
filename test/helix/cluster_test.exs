defmodule Helix.ClusterTest do
  use ExUnit.Case, async: false

  alias Helix.Core.Types
  alias Helix.Cluster.Node, as: CNode
  alias Helix.Cluster.Gossip
  alias Helix.Cluster.Partitioner
  alias Helix.Cluster.Membership
  alias Helix.Cluster.Router

  describe "Node Descriptor" do
    test "manages status lifecycles and refutation" do
      node = CNode.new("node_1", "127.0.0.1", 8000)
      assert node.status == :alive
      assert node.incarnation == 0

      # Suspicion with same incarnation
      suspect = CNode.mark_suspect(node, 0)
      assert suspect.status == :suspect

      # Refute bumps incarnation and resets to alive
      refuted = CNode.refute(suspect, 0)
      assert refuted.status == :alive
      assert refuted.incarnation == 1
    end
  end

  describe "Gossip Buffer" do
    test "enqueues, advances transmission counts, and evicts expired events" do
      buffer = Gossip.new(max_retransmissions: 2)

      event1 = {:alive, "node_a", 1, nil}
      event2 = {:alive, "node_b", 1, nil}

      buffer =
        buffer
        |> Gossip.add_event("e1", event1)
        |> Gossip.add_event("e2", event2)

      assert Gossip.size(buffer) == 2

      # Round 1: selects both, advances count to 1
      {selected1, buffer} = Gossip.select_and_advance(buffer, 2)
      assert length(selected1) == 2
      assert Gossip.size(buffer) == 2

      # Round 2: selects both, advances count to 2 (reaching max 2) -> evicts!
      {selected2, buffer} = Gossip.select_and_advance(buffer, 2)
      assert length(selected2) == 2
      assert Gossip.size(buffer) == 0
    end
  end

  describe "Consistent Hash Partitioner" do
    test "distributes keys across virtual nodes and returns distinct replicas" do
      partitioner =
        Partitioner.new(vnodes_per_node: 32)
        |> Partitioner.add_node("node_a")
        |> Partitioner.add_node("node_b")
        |> Partitioner.add_node("node_c")

      # Primary lookups are deterministic
      {:ok, primary1} = Partitioner.primary_node(partitioner, "user_account_101")
      {:ok, primary2} = Partitioner.primary_node(partitioner, "user_account_101")
      assert primary1 == primary2
      assert primary1 in ["node_a", "node_b", "node_c"]

      # Distinct replica quorums
      replicas = Partitioner.replica_nodes(partitioner, "user_account_101", 3)
      assert length(replicas) == 3
      assert Enum.uniq(replicas) == replicas
    end
  end

  describe "SWIM Membership" do
    test "exchanges pings and disseminates membership state" do
      transport_fn = fn target, msg ->
        target_pid =
          case target do
            "swim_1" -> Process.whereis(:test_swim_1)
            "swim_2" -> Process.whereis(:test_swim_2)
          end

        if target_pid, do: send(target_pid, {:msg, msg})
      end

      {:ok, s1} =
        Membership.start_link(
          name: :test_swim_1,
          node_id: "swim_1",
          ping_interval_ms: 50,
          transport_fn: transport_fn
        )

      {:ok, _s2} =
        Membership.start_link(
          name: :test_swim_2,
          node_id: "swim_2",
          ping_interval_ms: 50,
          transport_fn: transport_fn
        )

      # Introduce peer to node 1
      n2_desc = CNode.new("swim_2", "127.0.0.1", 9002)
      Membership.join(s1, n2_desc)

      # Wait for gossip dissemination
      Process.sleep(120)

      alive1 = Membership.get_alive_members(s1)
      assert length(alive1) == 2
      alive_ids = Enum.map(alive1, & &1.id) |> Enum.sort()
      assert alive_ids == ["swim_1", "swim_2"]
    end
  end

  describe "Cluster Router" do
    test "routes transactional commands to primary partition leader" do
      router =
        Router.new(replication_factor: 2)
        |> Router.add_node("replica_east")
        |> Router.add_node("replica_west")
        |> Router.add_node("replica_central")

      cmd = Types.make_command("tx_trade", [{:write, "BTC-USD-ORDERBOOK", 65000}])

      assert {:ok, primary, replicas} = Router.route_command(router, cmd)
      assert primary in ["replica_east", "replica_west", "replica_central"]
      assert length(replicas) == 2
      assert primary in replicas
    end
  end
end
