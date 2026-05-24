defmodule Helix.ConsensusTest do
  use ExUnit.Case, async: false

  alias Helix.Core.Types
  alias Helix.Consensus.Ballot
  alias Helix.Consensus.Quorum
  alias Helix.Consensus.ConflictDetector
  alias Helix.Consensus.Replica
  alias Helix.Consensus.ExecutionQueue
  alias Helix.Consensus.Recovery

  describe "Ballot & Quorum" do
    test "ballots strictly order lexicographically" do
      b1 = Ballot.initial("node1")
      b2 = Ballot.next_ballot(b1, "node1")
      b3 = Ballot.next_epoch(b2, "node1")

      assert Ballot.compare(b1, b2) == :lt
      assert Ballot.compare(b2, b3) == :lt
      assert Ballot.dominates?(b3, b2) == true
      assert Ballot.dominates?(b2, b3) == false
    end

    test "quorums match theoretical bounds" do
      # N = 3: classic = 2, fast = 2
      assert Quorum.classic_size(3) == 2
      assert Quorum.fast_size(3) == 2

      # N = 5: classic = 3, fast = 3
      assert Quorum.classic_size(5) == 3
      assert Quorum.fast_size(5) == 3
    end
  end

  describe "Conflict Detector" do
    test "tracks key readers and writers to determine dependencies" do
      detector = ConflictDetector.new()
      cmd1 = Types.make_command("tx1", [{:write, "account_a", 100}])
      id1 = {"node1", 1}

      {deps1, seq1} = ConflictDetector.find_conflicts(detector, cmd1, id1)
      assert MapSet.size(deps1) == 0
      assert seq1 == 1

      detector = ConflictDetector.record(detector, id1, cmd1, seq1)

      # Command 2 writes same key
      cmd2 = Types.make_command("tx2", [{:write, "account_a", 200}])
      id2 = {"node2", 1}

      {deps2, seq2} = ConflictDetector.find_conflicts(detector, cmd2, id2)
      assert MapSet.member?(deps2, id1) == true
      assert seq2 == 2
    end
  end

  describe "Single-Node Replica" do
    test "commits transactions immediately" do
      {:ok, queue} = ExecutionQueue.start_link()
      {:ok, replica} = Replica.start_link(replica_id: "node1", peers: [], execution_queue: queue)

      cmd = Types.make_command("tx1", [{:write, "foo", "bar"}])
      assert {:ok, {"node1", 1}, :committed} = Replica.propose(replica, cmd)

      inst = Replica.get_instance(replica, {"node1", 1})
      assert inst.status == :committed

      # Verify delivered to execution queue
      assert ExecutionQueue.get_execution_order(queue) == [{"node1", 1}]
    end
  end

  describe "Multi-Node Cluster (3 Replicas)" do
    test "executes 1-RTT fast path on independent keys" do
      {:ok, q1} = ExecutionQueue.start_link()
      {:ok, q2} = ExecutionQueue.start_link()
      {:ok, q3} = ExecutionQueue.start_link()

      # Direct in-process delivery via transport_fn

      transport_fn = fn target, msg ->
        target_pid =
          case target do
            "n1" -> Process.whereis(:test_r1)
            "n2" -> Process.whereis(:test_r2)
            "n3" -> Process.whereis(:test_r3)
            pid when is_pid(pid) -> pid
          end

        if target_pid, do: send(target_pid, {:msg, msg})
      end

      {:ok, r1} =
        Replica.start_link(
          name: :test_r1,
          replica_id: "n1",
          peers: ["n2", "n3"],
          execution_queue: q1,
          transport_fn: transport_fn
        )

      {:ok, r2} =
        Replica.start_link(
          name: :test_r2,
          replica_id: "n2",
          peers: ["n1", "n3"],
          execution_queue: q2,
          transport_fn: transport_fn
        )

      {:ok, r3} =
        Replica.start_link(
          name: :test_r3,
          replica_id: "n3",
          peers: ["n1", "n2"],
          execution_queue: q3,
          transport_fn: transport_fn
        )

      cmd1 = Types.make_command("tx1", [{:write, "alpha", 1}])
      assert {:ok, {"n1", 1}, :committed} = Replica.propose(r1, cmd1)

      # Verify all 3 replicas learned the commit
      Process.sleep(20)
      assert Replica.get_instance(r1, {"n1", 1}).status == :committed
      assert Replica.get_instance(r2, {"n1", 1}).status == :committed
      assert Replica.get_instance(r3, {"n1", 1}).status == :committed
    end

    test "handles conflicting concurrent proposals via slow path" do
      transport_fn = fn target, msg ->
        target_pid =
          case target do
            "s1" -> Process.whereis(:test_s1)
            "s2" -> Process.whereis(:test_s2)
            "s3" -> Process.whereis(:test_s3)
          end

        if target_pid, do: send(target_pid, {:msg, msg})
      end

      {:ok, s1} =
        Replica.start_link(
          name: :test_s1,
          replica_id: "s1",
          peers: ["s2", "s3"],
          transport_fn: transport_fn
        )

      {:ok, s2} =
        Replica.start_link(
          name: :test_s2,
          replica_id: "s2",
          peers: ["s1", "s3"],
          transport_fn: transport_fn
        )

      {:ok, _s3} =
        Replica.start_link(
          name: :test_s3,
          replica_id: "s3",
          peers: ["s1", "s2"],
          transport_fn: transport_fn
        )

      cmd_a = Types.make_command("tx_a", [{:write, "shared_key", 100}])
      cmd_b = Types.make_command("tx_b", [{:write, "shared_key", 200}])

      # Propose concurrently from two different replicas
      task_a = Task.async(fn -> Replica.propose(s1, cmd_a) end)
      task_b = Task.async(fn -> Replica.propose(s2, cmd_b) end)

      assert {:ok, {"s1", 1}, :committed} = Task.await(task_a)
      assert {:ok, {"s2", 1}, :committed} = Task.await(task_b)

      # Both transactions committed successfully
      Process.sleep(20)
      assert Replica.get_instance(s1, {"s1", 1}).status == :committed
      assert Replica.get_instance(s2, {"s2", 1}).status == :committed
    end
  end

  describe "Execution Queue" do
    test "delivers committed instances in deterministic dependency order" do
      test_pid = self()
      {:ok, queue} = ExecutionQueue.start_link(subscriber: test_pid)

      id1 = {"n1", 1}
      id2 = {"n2", 1}
      id3 = {"n1", 2}

      cmd1 = Types.make_command("tx1", [{:write, "k1", 1}])
      cmd2 = Types.make_command("tx2", [{:write, "k1", 2}])
      cmd3 = Types.make_command("tx3", [{:write, "k1", 3}])

      # id3 depends on id2, id2 depends on id1
      ExecutionQueue.enqueue_committed(queue, id3, cmd3, 3, MapSet.new([id2]))
      ExecutionQueue.enqueue_committed(queue, id2, cmd2, 2, MapSet.new([id1]))
      ExecutionQueue.enqueue_committed(queue, id1, cmd1, 1, MapSet.new())

      # Wait for execution drainage
      ExecutionQueue.drain(queue)

      order = ExecutionQueue.get_execution_order(queue)
      assert order == [id1, id2, id3]
    end
  end

  describe "Recovery Logic" do
    test "adopts committed instance during recovery" do
      cmd = Types.make_command("tx", [{:write, "k", 1}])

      replies = [
        %{status: :preaccepted, cmd: cmd, seq: 1, deps: MapSet.new()},
        %{status: :committed, cmd: cmd, seq: 1, deps: MapSet.new()}
      ]

      assert {:commit, ^cmd, 1, _} = Recovery.decide_recovery_state(replies, 3)
    end

    test "decides noop if no replica observed instance" do
      replies = []
      assert {:noop} = Recovery.decide_recovery_state(replies, 3)
    end
  end
end
