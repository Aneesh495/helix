defmodule Helix.STMTest do
  use ExUnit.Case, async: true

  alias Helix.Core.Types
  alias Helix.Core.SparseMerkleTree, as: SMT
  alias Helix.Core.MerkleProof
  alias Helix.STM.MVMemory
  alias Helix.STM.DependencyTracker
  alias Helix.STM.Validator
  alias Helix.STM.Transaction
  alias Helix.STM.Engine

  describe "MVMemory" do
    test "reads highest predecessor write and falls back to base state" do
      mem = MVMemory.new(%{"acc_1" => 100, "acc_2" => 50})

      # tx 0 writes acc_1 = 120
      mem = MVMemory.write(mem, 0, 0, %{"acc_1" => 120})
      # tx 2 writes acc_1 = 150
      mem = MVMemory.write(mem, 2, 0, %{"acc_1" => 150})

      # tx 1 reads acc_1: should observe tx 0 (120), NOT tx 2 (150)
      assert {:ok, 0, 0, 120} = MVMemory.read(mem, 1, "acc_1")

      # tx 3 reads acc_1: should observe tx 2 (150)
      assert {:ok, 2, 0, 150} = MVMemory.read(mem, 3, "acc_1")

      # tx 1 reads acc_2: should observe base state (-1, 50)
      assert {:ok, -1, 0, 50} = MVMemory.read(mem, 1, "acc_2")

      # Rollback tx 0
      mem = MVMemory.rollback(mem, 0)
      assert {:ok, -1, 0, 100} = MVMemory.read(mem, 1, "acc_1")
    end
  end

  describe "Dependency Tracker" do
    test "tracks and clears downstream read dependencies" do
      tracker = DependencyTracker.new()

      # Reader 2 read from Writer 0
      tracker = DependencyTracker.record_read(tracker, 2, 0)
      # Reader 3 read from Writer 0
      tracker = DependencyTracker.record_read(tracker, 3, 0)

      dependents = DependencyTracker.dependents_of(tracker, 0)
      assert MapSet.equal?(dependents, MapSet.new([2, 3]))

      # Clear reader 2
      tracker = DependencyTracker.clear_reader(tracker, 2)
      assert MapSet.equal?(DependencyTracker.dependents_of(tracker, 0), MapSet.new([3]))
    end
  end

  describe "Validator" do
    test "validates consistent read sets and flags stale reads" do
      mem = MVMemory.new(%{"k1" => "initial"})
      tx = Transaction.new("tx1", 1)
      # Recorded reading k1 from base state (-1, incarnation 0)
      tx = %{tx | read_set: %{"k1" => {-1, 0, "initial"}}}

      assert Validator.validate(tx, mem) == :valid

      # Intervening tx 0 writes to k1
      mem_updated = MVMemory.write(mem, 0, 0, %{"k1" => "updated_by_0"})
      assert {:invalid, "k1", -1, 0} = Validator.validate(tx, mem_updated)
    end
  end

  describe "Block-STM Parallel Execution Engine" do
    test "executes independent transactions speculatively with zero aborts" do
      commands =
        for i <- 0..9 do
          Types.make_command("tx_#{i}", [{:write, "key_#{i}", i * 10}])
        end

      {:ok, final_state, smt, stats} = Engine.execute_block(commands)

      assert stats.transactions_committed == 10
      assert stats.aborts == 0

      for i <- 0..9 do
        assert Map.get(final_state, "key_#{i}") == i * 10
        assert {:ok, i * 10} == SMT.get(smt, "key_#{i}")
      end
    end

    test "resolves read-write dependencies with speculative aborts and convergence" do
      # tx 0: writes "counter" = 10
      # tx 1: reads "counter", writes "counter" = val + 5 (15)
      # tx 2: reads "counter", writes "counter" = val + 20 (35)
      # tx 3: writes independent "other" = 99
      tx0 = Types.make_command("tx0", [{:write, "counter", 10}])
      tx1 = Types.make_command("tx1", [{:read, "counter"}, {:write, "counter", 15}])
      tx2 = Types.make_command("tx2", [{:read, "counter"}, {:write, "counter", 35}])
      tx3 = Types.make_command("tx3", [{:write, "other", 99}])

      {:ok, final_state, _smt, stats} = Engine.execute_block([tx0, tx1, tx2, tx3])

      assert stats.transactions_committed == 4
      assert Map.get(final_state, "counter") == 35
      assert Map.get(final_state, "other") == 99
    end

    test "executes custom functional transactions conserving total balance" do
      # Bank accounts: A = 1000, B = 500, C = 200 (Total = 1700)
      base = %{"A" => 1000, "B" => 500, "C" => 200}

      # Transfer 1: A -> B (200)
      t1 =
        {"transfer_1",
         fn ctx ->
           a = ctx.read.("A")
           b = ctx.read.("B")
           ctx.write.("A", a - 200)
           ctx.write.("B", b + 200)
         end}

      # Transfer 2: B -> C (150)
      t2 =
        {"transfer_2",
         fn ctx ->
           b = ctx.read.("B")
           c = ctx.read.("C")
           ctx.write.("B", b - 150)
           ctx.write.("C", c + 150)
         end}

      # Transfer 3: C -> A (50)
      t3 =
        {"transfer_3",
         fn ctx ->
           c = ctx.read.("C")
           a = ctx.read.("A")
           ctx.write.("C", c - 50)
           ctx.write.("A", a + 50)
         end}

      {:ok, final_state, smt, _stats} = Engine.execute_block([t1, t2, t3], base)

      # Invariant: total money must be conserved (1700)
      total = Map.get(final_state, "A") + Map.get(final_state, "B") + Map.get(final_state, "C")
      assert total == 1700

      # Expected individual balances:
      # A: 1000 - 200 + 50 = 850
      # B: 500 + 200 - 150 = 550
      # C: 200 + 150 - 50 = 300
      assert Map.get(final_state, "A") == 850
      assert Map.get(final_state, "B") == 550
      assert Map.get(final_state, "C") == 300

      # SMT cryptographic proof check
      root_hash = SMT.root_hash(smt)
      proof = MerkleProof.generate(smt, "A")
      assert {:ok, ^root_hash} = MerkleProof.verify(proof, root_hash)
    end
  end
end
