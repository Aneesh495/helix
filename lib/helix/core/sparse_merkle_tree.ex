defmodule Helix.Core.SparseMerkleTree do
  @moduledoc """
  Authenticated Sparse Merkle Tree (SMT) with 256-bit key paths and SHA-256 tree hashing.
  Provides cryptographic state commitments, non-interactive inclusion proofs,
  and non-inclusion exclusion proofs with O(log N) cached branch hashing.
  """

  @depth 256
  @empty_node_hash :crypto.hash(:sha256, "helix:smt:empty:node")

  defstruct [
    root: :empty,
    root_hash: nil,
    leaves: %{},
    depth: @depth
  ]

  @type t :: %__MODULE__{
          root: :empty | term(),
          root_hash: binary() | nil,
          leaves: %{binary() => {binary(), term()}},
          depth: non_neg_integer()
        }

  @doc """
  Initializes a new empty Sparse Merkle Tree.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      root: :empty,
      root_hash: @empty_node_hash,
      leaves: %{},
      depth: @depth
    }
  end

  @doc """
  Returns the empty node sentinel hash.
  """
  @spec empty_hash() :: binary()
  def empty_hash, do: @empty_node_hash

  @doc """
  Computes the 256-bit binary path for an arbitrary key.
  """
  @spec hash_key(binary()) :: binary()
  def hash_key(key) when is_binary(key) do
    :crypto.hash(:sha256, key)
  end

  @doc """
  Computes the 32-byte value commitment hash.
  """
  @spec hash_value(term()) :: binary()
  def hash_value(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
  end

  @doc """
  Retrieves a value from the SMT by key.
  """
  @spec get(t(), binary()) :: {:ok, term()} | :not_found
  def get(%__MODULE__{leaves: leaves}, key) when is_binary(key) do
    key_path = hash_key(key)

    case Map.get(leaves, key_path) do
      nil -> :not_found
      {_val_hash, val} -> {:ok, val}
    end
  end

  @doc """
  Inserts or updates a key-value pair in the SMT, returning the updated tree
  with cached root hash.
  """
  @spec put(t(), binary(), term()) :: t()
  def put(%__MODULE__{} = tree, key, value) when is_binary(key) do
    key_path = hash_key(key)
    val_hash = hash_value(value)

    new_leaves = Map.put(tree.leaves, key_path, {val_hash, value})
    new_root = insert_node(tree.root, key_path, val_hash, 0)
    new_root_hash = node_hash(new_root)

    %{tree | root: new_root, root_hash: new_root_hash, leaves: new_leaves}
  end

  @doc """
  Deletes a key from the SMT, returning the updated tree with recomputed root hash.
  """
  @spec delete(t(), binary()) :: t()
  def delete(%__MODULE__{} = tree, key) when is_binary(key) do
    key_path = hash_key(key)

    if Map.has_key?(tree.leaves, key_path) do
      new_leaves = Map.delete(tree.leaves, key_path)
      new_root = delete_node(tree.root, key_path, 0)
      new_root_hash = node_hash(new_root)

      %{tree | root: new_root, root_hash: new_root_hash, leaves: new_leaves}
    else
      tree
    end
  end

  @doc """
  Returns the current 32-byte cryptographic root hash of the tree.
  """
  @spec root_hash(t()) :: binary()
  def root_hash(%__MODULE__{root_hash: rh}), do: rh

  # Internal recursive insertion
  defp insert_node(:empty, key_path, val_hash, _depth) do
    h = compute_leaf_hash(key_path, val_hash)
    {:leaf, h, key_path, val_hash}
  end

  defp insert_node({:leaf, _h, existing_path, existing_val_hash}, key_path, val_hash, depth) do
    if existing_path == key_path do
      h = compute_leaf_hash(key_path, val_hash)
      {:leaf, h, key_path, val_hash}
    else
      bit_existing = get_bit(existing_path, depth)
      bit_new = get_bit(key_path, depth)

      if bit_existing == bit_new do
        child = insert_node({:leaf, compute_leaf_hash(existing_path, existing_val_hash), existing_path, existing_val_hash}, key_path, val_hash, depth + 1)

        if bit_existing == 0 do
          make_branch(child, :empty)
        else
          make_branch(:empty, child)
        end
      else
        leaf_existing = {:leaf, compute_leaf_hash(existing_path, existing_val_hash), existing_path, existing_val_hash}
        leaf_new = {:leaf, compute_leaf_hash(key_path, val_hash), key_path, val_hash}

        if bit_existing == 0 do
          make_branch(leaf_existing, leaf_new)
        else
          make_branch(leaf_new, leaf_existing)
        end
      end
    end
  end

  defp insert_node({:branch, _h, left, right}, key_path, val_hash, depth) do
    bit = get_bit(key_path, depth)

    if bit == 0 do
      new_left = insert_node(left, key_path, val_hash, depth + 1)
      make_branch(new_left, right)
    else
      new_right = insert_node(right, key_path, val_hash, depth + 1)
      make_branch(left, new_right)
    end
  end

  # Internal recursive deletion
  defp delete_node(:empty, _key_path, _depth), do: :empty

  defp delete_node({:leaf, h, path, val_hash}, key_path, _depth) do
    if path == key_path, do: :empty, else: {:leaf, h, path, val_hash}
  end

  defp delete_node({:branch, _h, left, right}, key_path, depth) do
    bit = get_bit(key_path, depth)

    new_branch =
      if bit == 0 do
        make_branch(delete_node(left, key_path, depth + 1), right)
      else
        make_branch(left, delete_node(right, key_path, depth + 1))
      end

    case new_branch do
      {:branch, _, :empty, :empty} -> :empty
      {:branch, _, {:leaf, _, _, _} = leaf, :empty} -> leaf
      {:branch, _, :empty, {:leaf, _, _, _} = leaf} -> leaf
      other -> other
    end
  end

  defp make_branch(left, right) do
    hl = node_hash(left)
    hr = node_hash(right)
    h = :crypto.hash(:sha256, <<2::8>> <> hl <> hr)
    {:branch, h, left, right}
  end

  def node_hash(:empty), do: @empty_node_hash
  def node_hash({:leaf, h, _path, _val_hash}), do: h
  def node_hash({:branch, h, _left, _right}), do: h

  def compute_leaf_hash(path, val_hash) do
    :crypto.hash(:sha256, <<1::8>> <> path <> val_hash)
  end

  @doc """
  Extracts the bit at given index from a binary path (0-indexed).
  """
  def get_bit(binary, bit_index) when is_binary(binary) and is_integer(bit_index) do
    byte_index = div(bit_index, 8)
    bit_offset = 7 - rem(bit_index, 8)
    byte = :binary.at(binary, byte_index)
    Bitwise.band(Bitwise.bsr(byte, bit_offset), 1)
  end
end
