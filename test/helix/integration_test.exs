defmodule Helix.IntegrationTest do
  use ExUnit.Case, async: false

  alias Helix.Core.Types
  alias Helix.Core.SparseMerkleTree, as: SMT
  alias Helix.Core.MerkleProof
  alias Helix.Consensus.Replica
  alias Helix.Consensus.ExecutionQueue
  alias Helix.STM.Engine
  alias Helix.Chaos.SimulatedNetwork

  describe "End-to-End Distributed Cluster Lifecycle" do
    test "executes full EPaxos, parallel Block-STM, and SMT state authentication" do
      # 1. Cluster network transport
      table_name = :integration_net_table

      if :ets.whereis(table_name) == :undefined do
        :ets.new(table_name, [:named_table, :public, :set])
      end

      net = SimulatedNetwork.new()
      :ets.insert(table_name, {:net, net})

      transport_fn = fn target, msg ->
        [{:net, current_net}] = :ets.lookup(table_name, :net)
        from_node = elem(msg, 1)

        case SimulatedNetwork.route_packet(current_net, from_node, target) do
          {:deliver, _delay, _dup?} ->
            target_atom = if is_atom(target), do: target, else: String.to_atom(target)

            case Process.whereis(target_atom) do
              pid when is_pid(pid) -> send(pid, {:msg, msg})
              nil -> :ok
            end

          :dropped ->
            :ok
        end
      end

      # 2. Start Execution Queues and Replicas for 3 nodes
      {:ok, q1} = ExecutionQueue.start_link()
      {:ok, q2} = ExecutionQueue.start_link()
      {:ok, q3} = ExecutionQueue.start_link()

      {:ok, r1} =
        Replica.start_link(
          name: :integ_r1,
          replica_id: "integ_r1",
          peers: ["integ_r2", "integ_r3"],
          execution_queue: q1,
          transport_fn: transport_fn
        )

      {:ok, r2} =
        Replica.start_link(
          name: :integ_r2,
          replica_id: "integ_r2",
          peers: ["integ_r1", "integ_r3"],
          execution_queue: q2,
          transport_fn: transport_fn
        )

      {:ok, r3} =
        Replica.start_link(
          name: :integ_r3,
          replica_id: "integ_r3",
          peers: ["integ_r1", "integ_r2"],
          execution_queue: q3,
          transport_fn: transport_fn
        )

      # 3. Submit concurrent transactions across different nodes
      cmd1 = Types.make_command("tx_fund_1", [{:write, "wallet:alice", 1000}])
      cmd2 = Types.make_command("tx_fund_2", [{:write, "wallet:bob", 500}])

      cmd3 =
        Types.make_command("tx_transfer", [
          {:read, "wallet:alice"},
          {:write, "wallet:alice", 800},
          {:write, "wallet:bob", 700}
        ])

      # Propose concurrently from node 1, 2, and 3
      task1 = Task.async(fn -> Replica.propose(r1, cmd1) end)
      task2 = Task.async(fn -> Replica.propose(r2, cmd2) end)
      assert {:ok, _, :committed} = Task.await(task1)
      assert {:ok, _, :committed} = Task.await(task2)

      # Dependent transfer transaction
      assert {:ok, _, :committed} = Replica.propose(r3, cmd3)

      # 4. Drain execution queues
      ExecutionQueue.drain(q1)
      ExecutionQueue.drain(q2)
      ExecutionQueue.drain(q3)

      # 5. Process committed state through Block-STM parallel executor
      {:ok, final_state, smt, stats} = Engine.execute_block([cmd1, cmd2, cmd3])
      assert stats.transactions_committed == 3
      assert Map.get(final_state, "wallet:alice") == 800
      assert Map.get(final_state, "wallet:bob") == 700

      # 6. Verify cryptographic state proof commitments
      root_hash = SMT.root_hash(smt)
      proof_alice = MerkleProof.generate(smt, "wallet:alice")
      assert {:ok, ^root_hash} = MerkleProof.verify(proof_alice, root_hash)

      # Non-inclusion proof check
      proof_missing = MerkleProof.generate(smt, "wallet:charlie")
      assert proof_missing.non_membership == true
      assert {:ok, ^root_hash} = MerkleProof.verify(proof_missing, root_hash)

      # Clean shutdown
      for p <- [r1, r2, r3, q1, q2, q3] do
        Process.unlink(p)
        Process.exit(p, :shutdown)
      end
    end
  end
end
