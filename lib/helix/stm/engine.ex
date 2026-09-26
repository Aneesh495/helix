defmodule Helix.STM.Engine do
  @moduledoc """
  High-performance Block-STM parallel execution engine.
  Executes transactions speculatively across available CPU cores, tracking dynamic
  read-write dependencies and resolving conflicts with deterministic validation.
  """

  alias Helix.Core.SparseMerkleTree, as: SMT
  alias Helix.STM.Transaction
  alias Helix.STM.MVMemory
  alias Helix.STM.DependencyTracker
  alias Helix.STM.Validator

  defmodule Context do
    @moduledoc """
    Execution context passed to transaction functions for reading and writing keys.
    """
    defstruct [:tx_index, :read_fn, :write_fn, read_set: %{}, write_set: %{}]
  end

  @doc """
  Executes a block of transactions in parallel using Block-STM.
  Returns {:ok, final_state, updated_smt, stats}.
  """
  @spec execute_block([Transaction.t() | map()], %{binary() => term()}, SMT.t(), keyword()) ::
          {:ok, %{binary() => term()}, SMT.t(), map()}
  def execute_block(transactions, base_state \\ %{}, smt \\ nil, opts \\ []) do
    tree = smt || SMT.new()
    max_retries = Keyword.get(opts, :max_retries, 100)

    # Wrap raw commands into Transaction structs if necessary
    tx_list =
      Enum.with_index(transactions)
      |> Enum.map(fn {item, idx} ->
        case item do
          %Transaction{} = tx -> %{tx | index: idx}
          %{id: id, ops: _} = cmd -> Transaction.new(id, idx, cmd)
          {id, func} when is_function(func) -> Transaction.new(id, idx, nil, func)
        end
      end)

    total_txs = length(tx_list)
    mem = MVMemory.new(base_state)
    tracker = DependencyTracker.new()

    {final_mem, final_txs, stats} =
      run_stm_loop(tx_list, mem, tracker, 0, max_retries, %{aborts: 0, waves: 0})

    final_state = MVMemory.materialize(final_mem, total_txs)

    # Commit state changes to Sparse Merkle Tree
    updated_tree =
      Enum.reduce(final_state, tree, fn {key, val}, acc_tree ->
        SMT.put(acc_tree, key, val)
      end)

    {:ok, final_state, updated_tree, Map.put(stats, :transactions_committed, length(final_txs))}
  end

  defp run_stm_loop(txs, mem, tracker, wave, max_retries, stats) do
    if wave >= max_retries do
      # Fallback to sequential execution if extreme livelock occurs
      sequential_fallback(txs, mem, stats)
    else
      # 1. Speculatively execute all transactions marked as pending
      pending_txs = Enum.filter(txs, &(&1.status == :pending))

      if length(pending_txs) == 0 do
        # All transactions executed; run full validation sweep
        case validate_all(txs, mem) do
          :all_valid ->
            {mem, txs, Map.put(stats, :waves, wave)}

          {:invalid, invalid_idx} ->
            {new_txs, new_mem, new_tracker} = abort_and_rollback(txs, invalid_idx, mem, tracker)
            new_stats = Map.update!(stats, :aborts, &(&1 + 1))
            run_stm_loop(new_txs, new_mem, new_tracker, wave + 1, max_retries, new_stats)
        end
      else
        # Parallel speculative execution of pending transactions
        executed_results =
          pending_txs
          |> Task.async_stream(
            fn tx ->
              execute_single_tx(tx, mem)
            end,
            max_concurrency: System.schedulers_online()
          )
          |> Enum.map(fn {:ok, res} -> res end)

        # Merge execution writes into memory and tracker
        {new_mem, new_tracker, updated_tx_map} =
          Enum.reduce(executed_results, {mem, tracker, %{}}, fn updated_tx, {m, trk, tx_map} ->
            m = MVMemory.write(m, updated_tx.index, updated_tx.incarnation, updated_tx.write_set)

            trk =
              Enum.reduce(updated_tx.read_set, trk, fn {_k, {writer_idx, _inc, _val}}, acc_trk ->
                DependencyTracker.record_read(acc_trk, updated_tx.index, writer_idx)
              end)

            {m, trk, Map.put(tx_map, updated_tx.index, updated_tx)}
          end)

        new_txs =
          Enum.map(txs, fn tx ->
            Map.get(updated_tx_map, tx.index, tx)
          end)

        # Run validation sweep
        case validate_all(new_txs, new_mem) do
          :all_valid ->
            {new_mem, new_txs, Map.put(stats, :waves, wave + 1)}

          {:invalid, invalid_idx} ->
            {invalidated_txs, rolled_back_mem, rolled_back_tracker} =
              abort_and_rollback(new_txs, invalid_idx, new_mem, new_tracker)

            new_stats = Map.update!(stats, :aborts, &(&1 + 1))

            run_stm_loop(
              invalidated_txs,
              rolled_back_mem,
              rolled_back_tracker,
              wave + 1,
              max_retries,
              new_stats
            )
        end
      end
    end
  end

  defp execute_single_tx(%Transaction{} = tx, mem) do
    cond do
      tx.exec_fn != nil ->
        # Execute custom user function
        run_custom_function(tx, mem)

      tx.command != nil ->
        # Execute standard command ops
        run_command_ops(tx, mem)

      true ->
        %{tx | status: :executed}
    end
  end

  defp run_command_ops(tx, mem) do
    {read_set, write_set} =
      Enum.reduce(tx.command.ops, {%{}, %{}}, fn op, {reads, writes} ->
        case op do
          {:read, key} ->
            {:ok, writer_idx, inc, val} = MVMemory.read(mem, tx.index, key)
            # Local write overrides memory read
            actual_val = Map.get(writes, key, val)
            {Map.put(reads, key, {writer_idx, inc, actual_val}), writes}

          {:write, key, val} ->
            {reads, Map.put(writes, key, val)}

          {:cas, key, expected, new_val} ->
            {:ok, writer_idx, inc, val} = MVMemory.read(mem, tx.index, key)
            current = Map.get(writes, key, val)

            reads = Map.put(reads, key, {writer_idx, inc, current})

            if current == expected do
              {reads, Map.put(writes, key, new_val)}
            else
              {reads, writes}
            end

          {:delete, key} ->
            {reads, Map.put(writes, key, nil)}

          {:noop} ->
            {reads, writes}
        end
      end)

    %{tx | read_set: read_set, write_set: write_set, status: :executed}
  end

  defp run_custom_function(tx, mem) do
    # State accumulator for custom transaction closures
    # We use agent/process-local or reduction for read/write capture
    reads_writes =
      try do
        reads_box = :ets.new(:stm_reads, [:set, :private])
        writes_box = :ets.new(:stm_writes, [:set, :private])

        read_fn = fn key ->
          case :ets.lookup(writes_box, key) do
            [{^key, local_val}] ->
              local_val

            [] ->
              {:ok, writer_idx, inc, val} = MVMemory.read(mem, tx.index, key)
              :ets.insert(reads_box, {key, {writer_idx, inc, val}})
              val
          end
        end

        write_fn = fn key, val ->
          :ets.insert(writes_box, {key, val})
          val
        end

        result = tx.exec_fn.(%{read: read_fn, write: write_fn})

        reads = Map.new(:ets.tab2list(reads_box))
        writes = Map.new(:ets.tab2list(writes_box))

        :ets.delete(reads_box)
        :ets.delete(writes_box)

        {reads, writes, result}
      rescue
        _e ->
          {%{}, %{}, :error}
      end

    case reads_writes do
      {reads, writes, result} ->
        %{tx | read_set: reads, write_set: writes, result: result, status: :executed}
    end
  end

  defp validate_all(txs, mem) do
    sorted = Enum.sort_by(txs, & &1.index)

    Enum.reduce_while(sorted, :all_valid, fn tx, _acc ->
      if tx.status == :executed do
        case Validator.validate(tx, mem) do
          :valid -> {:cont, :all_valid}
          {:invalid, _k, _exp, _act} -> {:halt, {:invalid, tx.index}}
        end
      else
        {:cont, :all_valid}
      end
    end)
  end

  defp abort_and_rollback(txs, invalid_idx, mem, tracker) do
    # Abort the conflicting transaction
    mem = MVMemory.rollback(mem, invalid_idx)
    tracker = DependencyTracker.clear_reader(tracker, invalid_idx)

    # Find downstream readers that must also be aborted
    dependents = DependencyTracker.dependents_of(tracker, invalid_idx)
    all_aborts = MapSet.put(dependents, invalid_idx)

    # Roll back all affected transactions
    {new_mem, new_tracker} =
      Enum.reduce(all_aborts, {mem, tracker}, fn idx, {m, trk} ->
        {MVMemory.rollback(m, idx), DependencyTracker.clear_reader(trk, idx)}
      end)

    new_txs =
      Enum.map(txs, fn tx ->
        if MapSet.member?(all_aborts, tx.index) do
          Transaction.increment_incarnation(tx)
        else
          tx
        end
      end)

    {new_txs, new_mem, new_tracker}
  end

  defp sequential_fallback(txs, mem, stats) do
    # Fallback guarantees termination under extreme synthetic pathological contention
    sorted = Enum.sort_by(txs, & &1.index)

    {final_mem, final_txs} =
      Enum.reduce(sorted, {mem, []}, fn tx, {m, acc_txs} ->
        executed = execute_single_tx(tx, m)
        m = MVMemory.write(m, executed.index, executed.incarnation, executed.write_set)
        {m, [executed | acc_txs]}
      end)

    {final_mem, Enum.reverse(final_txs), Map.put(stats, :sequential_fallback, true)}
  end
end
