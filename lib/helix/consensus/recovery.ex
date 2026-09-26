defmodule Helix.Consensus.Recovery do
  @moduledoc """
  Explicit recovery protocol for Egalitarian Paxos instances.
  Enforces safety during coordinator failover by querying classic quorums
  with incremented ballots and completing committed, accepted, or preaccepted states.
  """

  alias Helix.Core.Types
  alias Helix.Consensus.Ballot

  @doc """
  Decides the recovery action based on PrepareOK replies from a classic quorum.
  Returns {:commit, cmd, seq, deps}, {:accept, cmd, seq, deps}, or {:noop}.
  """
  @spec decide_recovery_state(list(map()), pos_integer()) ::
          {:commit, Types.command(), non_neg_integer(), MapSet.t()}
          | {:accept, Types.command(), non_neg_integer(), MapSet.t()}
          | {:noop}
  def decide_recovery_state(replies, cluster_size) when is_list(replies) do
    # 1. If any replica had already committed, commit that state immediately
    committed_reply = Enum.find(replies, fn r -> r.status == :committed end)

    if committed_reply do
      {:commit, committed_reply.cmd, committed_reply.seq, committed_reply.deps}
    else
      # 2. Check for accepted replies
      accepted_replies = Enum.filter(replies, fn r -> r.status == :accepted end)

      if length(accepted_replies) > 0 do
        # Select the accepted reply with the highest ballot
        highest =
          Enum.max_by(
            accepted_replies,
            fn r ->
              r.ballot
            end,
            fn b1, b2 -> Ballot.compare(b1, b2) != :gt end
          )

        {:accept, highest.cmd, highest.seq, highest.deps}
      else
        # 3. Check preaccepted replies
        preaccepted_replies = Enum.filter(replies, fn r -> r.status == :preaccepted end)
        f = div(cluster_size - 1, 2)

        if length(preaccepted_replies) >= f and f > 0 do
          first = hd(preaccepted_replies)

          all_match =
            Enum.all?(preaccepted_replies, fn r ->
              r.seq == first.seq and MapSet.equal?(r.deps, first.deps)
            end)

          if all_match do
            {:accept, first.cmd, first.seq, first.deps}
          else
            # Differing preaccepts: take union of deps and max seq
            max_seq = Enum.map(preaccepted_replies, & &1.seq) |> Enum.max()

            merged_deps =
              Enum.reduce(preaccepted_replies, MapSet.new(), &MapSet.union(&2, &1.deps))

            {:accept, first.cmd, max_seq, merged_deps}
          end
        else
          # No replica had seen this instance, safe to commit a no-op
          {:noop}
        end
      end
    end
  end
end
