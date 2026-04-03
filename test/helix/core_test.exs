defmodule Helix.CoreTest do
  use ExUnit.Case, async: true

  alias Helix.Core.Types
  alias Helix.Core.VectorClock
  alias Helix.Core.HybridLogicalClock, as: HLC
  alias Helix.Core.SparseMerkleTree, as: SMT
  alias Helix.Core.MerkleProof
  alias Helix.Core.BloomFilter
  alias Helix.Core.TarjanSCC
  alias Helix.Core.ConflictGraph
  alias Helix.Core.Varint
  alias Helix.Core.CRC32C
  alias Helix.Core.Bitset

  describe "Types & Command Conflicts" do
    test "correctly detects write-write and read-write conflicts" do
      cmd1 = Types.make_command("tx1", [{:write, "key_a", 100}, {:read, "key_b"}])
      cmd2 = Types.make_command("tx2", [{:read, "key_a"}])
      cmd3 = Types.make_command("tx3", [{:read, "key_b"}])
      cmd4 = Types.make_command("tx4", [{:write, "key_c", 200}])

      assert Types.conflicts?(cmd1, cmd2) == true
      # Both reading key_b is not a conflict
      assert Types.conflicts?(cmd1, cmd3) == false
      # Disjoint keys
      assert Types.conflicts?(cmd1, cmd4) == false
    end
  end

  describe "Vector Clock" do
    test "maintains causal relations" do
      vc1 = VectorClock.new() |> VectorClock.increment("node1")
      vc2 = VectorClock.new() |> VectorClock.increment("node2")

      assert VectorClock.compare(vc1, vc2) == :concurrent
      assert VectorClock.concurrent?(vc1, vc2) == true

      vc3 = VectorClock.merge(vc1, vc2) |> VectorClock.increment("node1")
      assert VectorClock.compare(vc1, vc3) == :before
      assert VectorClock.compare(vc3, vc1) == :after
      assert VectorClock.dominates?(vc3, vc1) == true
    end
  end

  describe "Hybrid Logical Clock" do
    test "advances monotonically and orders causally" do
      hlc_a = HLC.new("node_a")
      hlc_b = HLC.new("node_b")

      {ts_a1, _updated_a} = HLC.send_event(hlc_a)
      {:ok, ts_b1, _hlc_b} = HLC.recv_event(hlc_b, ts_a1)

      assert HLC.compare(ts_a1, ts_b1) == :lt
    end

    test "detects excessive clock drift" do
      hlc = HLC.new("node_a", max_drift: 1_000_000)
      future_ts = %{node_id: "node_b", physical: System.system_time(:microsecond) + 5_000_000, logical: 0}

      assert {:error, :clock_drift_exceeded} = HLC.recv_event(hlc, future_ts)
    end
  end

  describe "Sparse Merkle Tree & Proofs" do
    test "inserts, updates, retrieves, and validates inclusion proofs" do
      tree = SMT.new()
      assert SMT.get(tree, "alpha") == :not_found

      tree = SMT.put(tree, "alpha", %{value: 42})
      assert {:ok, %{value: 42}} = SMT.get(tree, "alpha")

      root1 = SMT.root_hash(tree)
      assert is_binary(root1) and byte_size(root1) == 32

      # Generate and verify inclusion proof
      proof = MerkleProof.generate(tree, "alpha")
      assert proof.non_membership == false
      assert {:ok, ^root1} = MerkleProof.verify(proof, root1)

      # Tampered root should fail verification
      bogus_root = :crypto.hash(:sha256, "bogus")
      assert {:error, :root_hash_mismatch} = MerkleProof.verify(proof, bogus_root)

      # Update value
      tree = SMT.put(tree, "alpha", %{value: 99})
      root2 = SMT.root_hash(tree)
      assert root1 != root2
      assert {:ok, %{value: 99}} = SMT.get(tree, "alpha")

      # Delete key
      tree = SMT.delete(tree, "alpha")
      assert SMT.get(tree, "alpha") == :not_found
    end

    test "verifies non-inclusion proofs for absent keys" do
      tree = SMT.new()
      proof = MerkleProof.generate(tree, "missing_key")
      assert proof.non_membership == true
      assert {:ok, _root} = MerkleProof.verify(proof, tree.root_hash)
    end
  end

  describe "Bloom Filter" do
    test "accurately tests membership with negligible false positives" do
      filter = BloomFilter.new(100, 0.01)

      filter =
        Enum.reduce(1..50, filter, fn i, acc ->
          BloomFilter.add(acc, "item_#{i}")
        end)

      Enum.each(1..50, fn i ->
        assert BloomFilter.member?(filter, "item_#{i}") == true
      end)

      # Test absent items
      false_positives =
        Enum.count(51..150, fn i ->
          BloomFilter.member?(filter, "item_#{i}")
        end)

      # With 1% FPR, false positives in 100 queries should be very low (<= 5)
      assert false_positives <= 5
    end
  end

  describe "Tarjan SCC & Conflict Graph" do
    test "resolves cyclic dependencies into deterministic execution order" do
      # Create cycle: A -> B -> C -> A
      adj_map = %{
        :a => [:b],
        :b => [:c],
        :c => [:a],
        :d => [:a]
      }

      sccs = TarjanSCC.scc(adj_map)
      cycle_scc = Enum.find(sccs, fn component -> Enum.sort(component) == [:a, :b, :c] end)
      assert cycle_scc != nil

      # Conflict graph resolving with tie breaking
      graph =
        ConflictGraph.new()
        |> ConflictGraph.add_node(:a, %{seq: 2})
        |> ConflictGraph.add_node(:b, %{seq: 1})
        |> ConflictGraph.add_node(:c, %{seq: 3})
        |> ConflictGraph.add_edge(:a, :b)
        |> ConflictGraph.add_edge(:b, :c)
        |> ConflictGraph.add_edge(:c, :a)

      order = ConflictGraph.resolve_execution_order(graph)
      assert length(order) == 3
      assert order == [:b, :a, :c]
    end
  end

  describe "Varint & CRC-32C Codecs" do
    test "encodes and decodes unsigned and signed integers" do
      for val <- [0, 1, 127, 128, 300, 16384, 1_000_000, 18_446_744_073_709_551_615] do
        encoded = Varint.encode_unsigned(val)
        assert {:ok, ^val, <<>>} = Varint.decode_unsigned(encoded)
      end

      for val <- [-1_000_000, -129, -1, 0, 1, 128, 1_000_000] do
        encoded = Varint.encode_signed(val)
        assert {:ok, ^val, <<>>} = Varint.decode_signed(encoded)
      end
    end

    test "computes accurate Castagnoli CRC-32C" do
      c1 = CRC32C.checksum("123456789")
      # Standard CRC-32C of ASCII "123456789" is 0xE3069283
      assert c1 == 0xE3069283

      c2 = CRC32C.checksum("helix-distributed-kernel")
      assert c2 > 0
    end
  end

  describe "Bitset" do
    test "supports set, unset, popcount, union, and intersection" do
      b1 = Bitset.from_list([0, 2, 5])
      assert Bitset.count(b1) == 3
      assert Bitset.member?(b1, 2) == true
      assert Bitset.member?(b1, 3) == false

      b2 = Bitset.from_list([2, 3, 5, 7])
      inter = Bitset.intersection(b1, b2)
      assert Bitset.to_list(inter) == [2, 5]

      union_b = Bitset.union(b1, b2)
      assert Bitset.to_list(union_b) == [0, 2, 3, 5, 7]
    end
  end
end
