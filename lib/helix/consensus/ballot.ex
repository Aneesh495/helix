defmodule Helix.Consensus.Ballot do
  @moduledoc """
  Ballot number abstraction for Egalitarian Paxos recovery and leader arbitration.
  Ballots are ordered lexicographically: (epoch, counter, replica_id).
  """

  @type epoch :: non_neg_integer()
  @type counter :: non_neg_integer()
  @type replica_id :: term()

  @type t :: {epoch(), counter(), replica_id()}

  @doc """
  Creates a default initial ballot for a replica.
  """
  @spec initial(replica_id()) :: t()
  def initial(replica_id) do
    {0, 0, replica_id}
  end

  @doc """
  Generates the next ballot number for a replica, incrementing the counter.
  """
  @spec next_ballot(t(), replica_id()) :: t()
  def next_ballot({epoch, counter, _prev_replica}, replica_id) do
    {epoch, counter + 1, replica_id}
  end

  @doc """
  Increments the epoch for reconfiguration or leader election.
  """
  @spec next_epoch(t(), replica_id()) :: t()
  def next_epoch({epoch, _counter, _prev_replica}, replica_id) do
    {epoch + 1, 0, replica_id}
  end

  @doc """
  Compares two ballot numbers for total ordering.
  Returns :lt, :eq, or :gt.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare({e1, c1, r1}, {e2, c2, r2}) do
    cond do
      e1 < e2 -> :lt
      e1 > e2 -> :gt
      c1 < c2 -> :lt
      c1 > c2 -> :gt
      r1 < r2 -> :lt
      r1 > r2 -> :gt
      true -> :eq
    end
  end

  @doc """
  Checks if ballot b1 is greater than or equal to ballot b2.
  """
  @spec dominates?(t(), t()) :: boolean()
  def dominates?(b1, b2) do
    case compare(b1, b2) do
      :gt -> true
      :eq -> true
      :lt -> false
    end
  end
end
