defmodule Helix.Consensus.Quorum do
  @moduledoc """
  Quorum calculation and fast-path agreement evaluation for Egalitarian Paxos.
  Supports both classic majority quorums and optimal fast-path quorums.
  """

  @doc """
  Calculates the classic Paxos quorum size for a cluster of N nodes.
  Q_classic = floor(N / 2) + 1
  """
  @spec classic_size(pos_integer()) :: pos_integer()
  def classic_size(n) when is_integer(n) and n > 0 do
    div(n, 2) + 1
  end

  @doc """
  Calculates the fast-path quorum size for a cluster of N nodes.
  F = floor((N - 1) / 2)
  Q_fast = F + floor((F + 1) / 2)
  """
  @spec fast_size(pos_integer()) :: pos_integer()
  def fast_size(n) when is_integer(n) and n > 0 do
    f = div(n - 1, 2)
    f + div(f + 1, 2)
  end

  @doc """
  Evaluates whether a collection of PreAccept replies unanimously agreed
  with the coordinator's proposed sequence number and dependency set.
  """
  @spec fast_path_agreed?(list(map()), non_neg_integer(), MapSet.t()) :: boolean()
  def fast_path_agreed?(replies, initial_seq, initial_deps) when is_list(replies) do
    Enum.all?(replies, fn reply ->
      reply.seq == initial_seq and MapSet.equal?(reply.deps, initial_deps)
    end)
  end
end
