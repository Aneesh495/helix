defmodule Helix.Chaos.LinearizabilityChecker do
  @moduledoc """
  Jepsen-style linearizability checker implementing the Wing & Gong (WGL) algorithm.
  Verifies whether concurrent execution histories of distributed register operations
  can be linearized into a legal sequential execution satisfying real-time precedence.
  """

  defstruct [
    history: []
  ]

  @type op_type :: :read | :write
  @type operation :: %{
          id: term(),
          type: op_type(),
          key: binary(),
          value: term(),
          invoke_time: non_neg_integer(),
          ok_time: non_neg_integer()
        }

  @doc """
  Verifies whether an operation history on a single register/key is linearizable.
  Returns {:ok, linearized_history} or {:error, :non_linearizable}.
  """
  @spec check_register([operation()], term()) :: {:ok, [operation()]} | {:error, :non_linearizable}
  def check_register(operations, initial_state \\ nil) when is_list(operations) do
    # Sort operations by invocation time
    sorted_ops = Enum.sort_by(operations, & &1.invoke_time)
    do_wgl_search(sorted_ops, [], initial_state, MapSet.new())
  end

  # Wing-Gong Recursive Backtracking Search
  defp do_wgl_search([], linearized_acc, _state, _visited_ids) do
    {:ok, Enum.reverse(linearized_acc)}
  end

  defp do_wgl_search(remaining_ops, linearized_acc, current_state, visited_ids) do
    # Find operations that are currently eligible for linearization:
    # An operation is eligible if no other unvisited operation must strictly precede it in real-time.
    # An unvisited operation P must precede C if P.ok_time < C.invoke_time.
    candidates =
      Enum.filter(remaining_ops, fn candidate ->
        not Enum.any?(remaining_ops, fn other ->
          other.id != candidate.id and other.ok_time < candidate.invoke_time
        end)
      end)

    # Search among candidates for one that is sequentially legal
    search_candidates(candidates, remaining_ops, linearized_acc, current_state, visited_ids)
  end

  defp search_candidates([], _remaining_ops, _linearized_acc, _current_state, _visited_ids) do
    {:error, :non_linearizable}
  end

  defp search_candidates([candidate | rest_candidates], remaining_ops, linearized_acc, current_state, visited_ids) do
    case apply_op(candidate, current_state) do
      {:ok, next_state} ->
        new_remaining = Enum.reject(remaining_ops, &(&1.id == candidate.id))
        new_linearized = [candidate | linearized_acc]
        new_visited = MapSet.put(visited_ids, candidate.id)

        case do_wgl_search(new_remaining, new_linearized, next_state, new_visited) do
          {:ok, result} ->
            {:ok, result}

          {:error, :non_linearizable} ->
            search_candidates(rest_candidates, remaining_ops, linearized_acc, current_state, visited_ids)
        end

      :illegal ->
        search_candidates(rest_candidates, remaining_ops, linearized_acc, current_state, visited_ids)
    end
  end

  defp apply_op(%{type: :write, value: val}, _state) do
    {:ok, val}
  end

  defp apply_op(%{type: :read, value: expected_val}, current_state) do
    if expected_val == current_state do
      {:ok, current_state}
    else
      :illegal
    end
  end
end
