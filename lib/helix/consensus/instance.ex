defmodule Helix.Consensus.Instance do
  @moduledoc """
  State container and lifecycle transition logic for an Egalitarian Paxos instance.
  Tracks consensus progression through preaccept, accept, commit, and execution phases.
  """

  alias Helix.Core.Types
  alias Helix.Consensus.Ballot

  defstruct [
    :id,
    :command,
    :ballot,
    :leader,
    :caller,
    seq: 0,
    deps: MapSet.new(),
    status: :preaccepted,
    preaccept_replies: [],
    accept_replies: MapSet.new()
  ]

  @type instance_id :: Types.instance_id()
  @type t :: %__MODULE__{
          id: instance_id(),
          command: Types.command() | nil,
          seq: non_neg_integer(),
          deps: MapSet.t(instance_id()),
          status: Types.instance_status(),
          ballot: Ballot.t(),
          leader: Types.replica_id(),
          caller: GenServer.from() | nil,
          preaccept_replies: [map()],
          accept_replies: MapSet.t(Types.replica_id())
        }

  @doc """
  Initializes a new instance in preaccepted state.
  """
  @spec new(
          instance_id(),
          Types.command() | nil,
          Ballot.t(),
          Types.replica_id(),
          GenServer.from() | nil
        ) :: t()
  def new(id, command, ballot, leader, caller \\ nil) do
    %__MODULE__{
      id: id,
      command: command,
      ballot: ballot,
      leader: leader,
      caller: caller,
      seq: 0,
      deps: MapSet.new(),
      status: :preaccepted,
      preaccept_replies: [],
      accept_replies: MapSet.new()
    }
  end

  @doc """
  Records a preaccept vote and replies.
  """
  @spec record_preaccept_reply(t(), map()) :: t()
  def record_preaccept_reply(%__MODULE__{} = inst, reply) do
    %{inst | preaccept_replies: [reply | inst.preaccept_replies]}
  end

  @doc """
  Transitions an instance to accepted status with merged sequence and dependency sets.
  """
  @spec transition_to_accepted(t(), non_neg_integer(), MapSet.t()) :: t()
  def transition_to_accepted(%__MODULE__{} = inst, seq, deps) do
    %{inst | status: :accepted, seq: seq, deps: deps, accept_replies: MapSet.new()}
  end

  @doc """
  Records an accept vote from a replica.
  """
  @spec record_accept_reply(t(), Types.replica_id()) :: t()
  def record_accept_reply(%__MODULE__{} = inst, replica_id) do
    %{inst | accept_replies: MapSet.put(inst.accept_replies, replica_id)}
  end

  @doc """
  Transitions an instance to committed status.
  """
  @spec transition_to_committed(t(), non_neg_integer(), MapSet.t()) :: t()
  def transition_to_committed(%__MODULE__{} = inst, seq, deps) do
    %{inst | status: :committed, seq: seq, deps: deps}
  end

  @doc """
  Transitions an instance to executed status.
  """
  @spec transition_to_executed(t()) :: t()
  def transition_to_executed(%__MODULE__{} = inst) do
    %{inst | status: :executed}
  end
end
