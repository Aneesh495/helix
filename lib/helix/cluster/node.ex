defmodule Helix.Cluster.Node do
  @moduledoc """
  Cluster node descriptor tracking address, status, incarnation number, and datacenter locality.
  """

  defstruct [
    :id,
    :host,
    :port,
    status: :alive,
    incarnation: 0,
    datacenter: "default",
    rack: "default",
    last_seen_at: 0
  ]

  @type node_status :: :alive | :suspect | :dead
  @type t :: %__MODULE__{
          id: binary(),
          host: binary(),
          port: non_neg_integer(),
          status: node_status(),
          incarnation: non_neg_integer(),
          datacenter: binary(),
          rack: binary(),
          last_seen_at: non_neg_integer()
        }

  @doc """
  Creates a new node descriptor.
  """
  @spec new(binary(), binary(), non_neg_integer(), keyword()) :: t()
  def new(id, host, port, opts \\ []) do
    %__MODULE__{
      id: id,
      host: host,
      port: port,
      status: :alive,
      incarnation: 0,
      datacenter: Keyword.get(opts, :datacenter, "default"),
      rack: Keyword.get(opts, :rack, "default"),
      last_seen_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Refutes a suspicion by incrementing incarnation number and setting status to :alive.
  """
  @spec refute(t(), non_neg_integer()) :: t()
  def refute(%__MODULE__{} = node, suspect_incarnation) do
    new_inc = max(node.incarnation, suspect_incarnation) + 1
    %{node | status: :alive, incarnation: new_inc, last_seen_at: System.system_time(:millisecond)}
  end

  @doc """
  Transitions node to suspect state with the given incarnation.
  """
  @spec mark_suspect(t(), non_neg_integer()) :: t()
  def mark_suspect(%__MODULE__{} = node, inc) do
    if inc >= node.incarnation do
      %{node | status: :suspect, incarnation: inc, last_seen_at: System.system_time(:millisecond)}
    else
      node
    end
  end

  @doc """
  Transitions node to dead state.
  """
  @spec mark_dead(t()) :: t()
  def mark_dead(%__MODULE__{} = node) do
    %{node | status: :dead, last_seen_at: System.system_time(:millisecond)}
  end
end
