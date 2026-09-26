defmodule Helix.Cluster.Partitioner do
  @moduledoc """
  Consistent hashing ring with virtual nodes (vnodes) for uniform key partitioning
  and replica quorum placement.
  """

  defstruct vnodes_per_node: 64,
            ring: [],
            nodes: MapSet.new()

  @type token :: non_neg_integer()
  @type node_id :: binary()
  @type ring_entry :: {token(), node_id()}

  @type t :: %__MODULE__{
          vnodes_per_node: pos_integer(),
          ring: [ring_entry()],
          nodes: MapSet.t(node_id())
        }

  @doc """
  Initializes a new empty consistent hash partitioner.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    vnodes = Keyword.get(opts, :vnodes_per_node, 64)
    %__MODULE__{vnodes_per_node: vnodes, ring: [], nodes: MapSet.new()}
  end

  @doc """
  Adds a physical node to the hash ring by generating its virtual nodes.
  """
  @spec add_node(t(), node_id()) :: t()
  def add_node(%__MODULE__{} = partitioner, node_id) do
    if MapSet.member?(partitioner.nodes, node_id) do
      partitioner
    else
      vnode_entries =
        for i <- 0..(partitioner.vnodes_per_node - 1) do
          token = hash_token("#{node_id}:vn:#{i}")
          {token, node_id}
        end

      new_ring = Enum.sort_by(partitioner.ring ++ vnode_entries, &elem(&1, 0))
      new_nodes = MapSet.put(partitioner.nodes, node_id)

      %{partitioner | ring: new_ring, nodes: new_nodes}
    end
  end

  @doc """
  Removes a physical node and all its virtual nodes from the ring.
  """
  @spec remove_node(t(), node_id()) :: t()
  def remove_node(%__MODULE__{} = partitioner, node_id) do
    new_ring = Enum.reject(partitioner.ring, fn {_token, nid} -> nid == node_id end)
    new_nodes = MapSet.delete(partitioner.nodes, node_id)
    %{partitioner | ring: new_ring, nodes: new_nodes}
  end

  @doc """
  Locates the primary node responsible for the given key.
  """
  @spec primary_node(t(), binary()) :: {:ok, node_id()} | {:error, :empty_ring}
  def primary_node(%__MODULE__{ring: []}, _key), do: {:error, :empty_ring}

  def primary_node(%__MODULE__{} = partitioner, key) when is_binary(key) do
    key_token = hash_token(key)

    entry =
      Enum.find(partitioner.ring, fn {token, _nid} -> token >= key_token end) ||
        hd(partitioner.ring)

    {:ok, elem(entry, 1)}
  end

  @doc """
  Returns N distinct replica nodes for a key, maintaining replication diversity.
  """
  @spec replica_nodes(t(), binary(), pos_integer()) :: [node_id()]
  def replica_nodes(%__MODULE__{ring: []}, _key, _count), do: []

  def replica_nodes(%__MODULE__{} = partitioner, key, count) when is_binary(key) and count > 0 do
    key_token = hash_token(key)

    # Find starting position on ring
    {after_ring, before_ring} =
      Enum.split_with(partitioner.ring, fn {token, _nid} -> token >= key_token end)

    ordered_ring = after_ring ++ before_ring

    ordered_ring
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.take(min(count, MapSet.size(partitioner.nodes)))
  end

  defp hash_token(input) when is_binary(input) do
    <<token::256>> = :crypto.hash(:sha256, input)
    token
  end
end
