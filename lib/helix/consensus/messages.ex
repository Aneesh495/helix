defmodule Helix.Consensus.Messages do
  @moduledoc """
  Typed message protocols and payload builders for Egalitarian Paxos consensus.
  """

  alias Helix.Core.Types
  alias Helix.Consensus.Ballot

  @type message ::
          {:preaccept, from :: Types.replica_id(), inst_id :: Types.instance_id(),
           ballot :: Ballot.t(), cmd :: Types.command(), seq :: non_neg_integer(),
           deps :: MapSet.t(Types.instance_id())}
          | {:preaccept_ok, from :: Types.replica_id(), inst_id :: Types.instance_id(),
             seq :: non_neg_integer(), deps :: MapSet.t(Types.instance_id())}
          | {:preaccept_reject, from :: Types.replica_id(), inst_id :: Types.instance_id(),
             higher_ballot :: Ballot.t()}
          | {:accept, from :: Types.replica_id(), inst_id :: Types.instance_id(),
             ballot :: Ballot.t(), cmd :: Types.command(), seq :: non_neg_integer(),
             deps :: MapSet.t(Types.instance_id())}
          | {:accept_ok, from :: Types.replica_id(), inst_id :: Types.instance_id()}
          | {:accept_reject, from :: Types.replica_id(), inst_id :: Types.instance_id(),
             higher_ballot :: Ballot.t()}
          | {:commit, from :: Types.replica_id(), inst_id :: Types.instance_id(),
             cmd :: Types.command(), seq :: non_neg_integer(),
             deps :: MapSet.t(Types.instance_id())}
          | {:prepare, from :: Types.replica_id(), inst_id :: Types.instance_id(),
             ballot :: Ballot.t()}
          | {:prepare_ok, from :: Types.replica_id(), inst_id :: Types.instance_id(),
             ballot :: Ballot.t(), status :: Types.instance_status(),
             cmd :: Types.command() | nil, seq :: non_neg_integer(),
             deps :: MapSet.t(Types.instance_id())}
          | {:prepare_reject, from :: Types.replica_id(), inst_id :: Types.instance_id(),
             higher_ballot :: Ballot.t()}
end
