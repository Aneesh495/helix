defmodule Helix.Cluster.Router do
  @moduledoc """
  Transaction router directing incoming requests to partition leaders and consensus quorums
  based on consistent hashing ring topology.
  """

  alias Helix.Core.Types
  alias Helix.Cluster.Partitioner

  defstruct partitioner: nil,
            replication_factor: 3

  @type t :: %__MODULE__{
          partitioner: Partitioner.t(),
          replication_factor: pos_integer()
        }

  @doc """
  Initializes a new router instance.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    rf = Keyword.get(opts, :replication_factor, 3)
    p = Partitioner.new(opts)
    %__MODULE__{partitioner: p, replication_factor: rf}
  end

  @doc """
  Registers a cluster node with the router's partition ring.
  """
  @spec add_node(t(), binary()) :: t()
  def add_node(%__MODULE__{} = router, node_id) do
    %{router | partitioner: Partitioner.add_node(router.partitioner, node_id)}
  end

  @doc """
  Removes a cluster node upon failure or decommissioning.
  """
  @spec remove_node(t(), binary()) :: t()
  def remove_node(%__MODULE__{} = router, node_id) do
    %{router | partitioner: Partitioner.remove_node(router.partitioner, node_id)}
  end

  @doc """
  Finds the designated coordinator replica for a command based on its primary write or read key.
  """
  @spec route_command(t(), Types.command()) ::
          {:ok, binary(), [binary()]} | {:error, :no_keys | :empty_ring}
  def route_command(%__MODULE__{} = router, %{write_keys: [primary_key | _]}) do
    resolve_key_route(router, primary_key)
  end

  def route_command(%__MODULE__{} = router, %{read_keys: [primary_key | _]}) do
    resolve_key_route(router, primary_key)
  end

  def route_command(_router, _cmd) do
    {:error, :no_keys}
  end

  defp resolve_key_route(router, key) do
    case Partitioner.primary_node(router.partitioner, key) do
      {:ok, primary} ->
        replicas = Partitioner.replica_nodes(router.partitioner, key, router.replication_factor)
        {:ok, primary, replicas}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
