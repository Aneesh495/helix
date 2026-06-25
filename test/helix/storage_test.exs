defmodule Helix.StorageTest do
  use ExUnit.Case, async: true

  alias Helix.Core.SparseMerkleTree, as: SMT
  alias Helix.Storage.MemoryEngine
  alias Helix.Storage.WAL
  alias Helix.Storage.Snapshot
  alias Helix.Storage.MVCCStore

  describe "Memory Engine" do
    test "provides atomic get, put, delete, and batch writes" do
      table_name = :test_storage_mem
      engine = MemoryEngine.new(table_name)

      assert MemoryEngine.get(engine, "missing") == :not_found

      :ok = MemoryEngine.put(engine, "user:1", %{name: "Alice"})
      assert {:ok, %{name: "Alice"}} = MemoryEngine.get(engine, "user:1")

      :ok =
        MemoryEngine.batch_write(engine, [
          {:put, "user:2", %{name: "Bob"}},
          {:delete, "user:1"}
        ])

      assert MemoryEngine.get(engine, "user:1") == :not_found
      assert {:ok, %{name: "Bob"}} = MemoryEngine.get(engine, "user:2")

      {:ok, chk} = MemoryEngine.checkpoint(engine)
      assert is_binary(chk) and byte_size(chk) == 32
    end
  end

  describe "Write-Ahead Log (WAL)" do
    test "encodes, decodes, and validates CRC-32C integrity" do
      entry1 = %{tx_id: "tx1", writes: %{"a" => 1}}
      entry2 = %{tx_id: "tx2", writes: %{"b" => 2}}

      bin1 = WAL.encode_record(1, entry1)
      bin2 = WAL.encode_record(2, entry2)
      stream = bin1 <> bin2

      {:ok, recovered, <<>>} = WAL.recover_segment(stream)
      assert length(recovered) == 2
      assert hd(recovered).seq == 1
      assert hd(recovered).payload == entry1
      assert Enum.at(recovered, 1).seq == 2
      assert Enum.at(recovered, 1).payload == entry2
    end

    test "handles corrupted tails cleanly during recovery" do
      bin = WAL.encode_record(1, "valid_payload")
      # Append truncated garbage
      corrupted_stream = bin <> <<0x57, 0x41, 0x4C, 0x31, 1, 2, 3>>

      {:ok, recovered, partial_tail} = WAL.recover_segment(corrupted_stream)
      assert length(recovered) == 1
      assert byte_size(partial_tail) > 0
    end
  end

  describe "Snapshot Manager" do
    test "creates, serializes, and deserializes verified state snapshots" do
      state = %{"balance:alice" => 500, "balance:bob" => 300}

      smt =
        Enum.reduce(state, SMT.new(), fn {k, v}, acc ->
          SMT.put(acc, k, v)
        end)

      snap = Snapshot.create("snap_001", 42, state, smt)
      serialized = Snapshot.serialize(snap)
      assert is_binary(serialized)

      {:ok, loaded} = Snapshot.deserialize(serialized)
      assert loaded.snapshot_id == "snap_001"
      assert loaded.seq == 42
      assert loaded.state_map == state
      assert loaded.smt_root == SMT.root_hash(smt)
    end
  end

  describe "MVCC Store" do
    test "supports point-in-time snapshot reads and time-travel queries" do
      store =
        MVCCStore.new()
        |> MVCCStore.put("price", 100, 1000)
        |> MVCCStore.put("price", 105, 2000)
        |> MVCCStore.put("price", 110, 3000)

      # At t = 500: not found
      assert MVCCStore.read_as_of(store, "price", 500) == :not_found

      # At t = 1500: price is 100
      assert {:ok, 100, 1000} = MVCCStore.read_as_of(store, "price", 1500)

      # At t = 2500: price is 105
      assert {:ok, 105, 2000} = MVCCStore.read_as_of(store, "price", 2500)

      # At t = 4000: price is 110
      assert {:ok, 110, 3000} = MVCCStore.read_as_of(store, "price", 4000)

      # Vacuum older than horizon 2500
      # Retains version 3000 (newer) and version 2000 (baseline for horizon)
      vacuumed = MVCCStore.vacuum(store, 2500)
      history = MVCCStore.history(vacuumed, "price")
      assert Enum.map(history, &elem(&1, 0)) == [3000, 2000]
    end
  end
end
