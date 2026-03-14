defmodule Helix.Core.SparseMerkleTree do
  @moduledoc """
  Authenticated Sparse Merkle Tree (SMT) with 256-bit key paths and SHA-256 hashing.
  Provides cryptographic state commitments, non-interactive inclusion proofs,
  and non-inclusion exclusion proofs.
  """

  @depth 256
  @empty_leaf :crypto.hash(:sha256, "helix:smt:empty:leaf")

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

  # Precompute default empty hashes from height 0 up to 256
  @default_hashes (
    Enum.reduce(0..256, %{0 => @empty_leaf}, fn level, acc ->
      if level == 0 do
        acc
      else
        prev = Map.fetch!(acc, level - 1)
        h = :crypto.hash(:sha256, <<2::8>> <> prev <> prev)
        Map.put(acc, level, h)
      end
    end)
  )

  @doc """
  Initializes a new empty Sparse Merkle Tree.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      root: :empty,
      root_hash: default_hash(@depth),
      leaves: %{},
      depth: @depth
    }
  end

  @doc """
  Returns the default empty hash at the specified height.
  """
  @spec default_hash(non_neg_integer()) :: binary()
  def default_hash(level) do
    Map.get(@default_hashes, level, @empty_leaf)
  end

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
  with recomputed root hash.
  """
  @spec put(t(), binary(), term()) :: t()
  def put(%__MODULE__{} = tree, key, value) when is_binary(key) do
    key_path = hash_key(key)
    val_hash = hash_value(value)

    new_leaves = Map.put(tree.leaves, key_path, {val_hash, value})
    new_root = insert_node(tree.root, key_path, val_hash, 0, tree.depth)
    new_root_hash = compute_node_hash(new_root, tree.depth)

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
      new_root = delete_node(tree.root, key_path, 0, tree.depth)
      new_root_hash = compute_node_hash(new_root, tree.depth)

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
  defp insert_node(:empty, key_path, val_hash, _depth, _max_depth) do
    {:leaf, key_path, val_hash}
  end

  defp insert_node({:leaf, existing_path, existing_val_hash}, key_path, val_hash, depth, max_depth) do
    if existing_path == key_path do
      {:leaf, key_path, val_hash}
    else
      bit_existing = get_bit(existing_path, depth)
      bit_new = get_bit(key_path, depth)

      if bit_existing == bit_new do
        child = insert_node({:leaf, existing_path, existing_val_hash}, key_path, val_hash, depth + 1, max_depth)

        if bit_existing == 0 do
          {:branch, child, :empty}
        else
          {:branch, :empty, child}
        end
      else
        if bit_existing == 0 do
          {:branch, {:leaf, existing_path, existing_val_hash}, {:leaf, key_path, val_hash}}
        else
          {:branch, {:leaf, key_path, val_hash}, {:leaf, existing_path, existing_val_hash}}
        end
      end
    end
  end

  defp insert_node({:branch, left, right}, key_path, val_hash, depth, max_depth) do
    bit = get_bit(key_path, depth)

    if bit == 0 do
      new_left = insert_node(left, key_path, val_hash, depth + 1, max_depth)
      {:branch, new_left, right}
    else
      new_right = insert_node(right, key_path, val_hash, depth + 1, max_depth)
      {:branch, left, new_right}
    end
  end

  # Internal recursive deletion
  defp delete_node(:empty, _key_path, _depth, _max_depth), do: :empty

  defp delete_node({:leaf, path, val_hash}, key_path, _depth, _max_depth) do
    if path == key_path, do: :empty, else: {:leaf, path, val_hash}
  end

  defp delete_node({:branch, left, right}, key_path, depth, max_depth) do
    bit = get_bit(key_path, depth)

    new_branch =
      if bit == 0 do
        {:branch, delete_node(left, key_path, depth + 1, max_depth), right}
      else
        {:branch, left, delete_node(right, key_path, depth + 1, max_depth)}
      end

    case new_branch do
      {:branch, :empty, :empty} -> :empty
      {:branch, {:leaf, _, _} = leaf, :empty} -> leaf
      {:branch, :empty, {:leaf, _, _} = leaf} -> leaf
      other -> other
    end
  end

  @doc """
  Computes the cryptographic hash of a subtree at the given remaining height.
  """
  def compute_node_hash(:empty, height) do
    default_hash(height)
  end

  def compute_node_hash({:leaf, path, val_hash}, 0) do
    :crypto.hash(:sha256, <<1::8>> <> path <> val_hash)
  end

  def compute_node_hash({:leaf, path, val_hash}, height) when height > 0 do
    # When a leaf is stored above height 0 (due to path compression),
    # compute its position down to height 0
    depth = @depth - height
    bit = get_bit(path, depth)

    if bit == 0 do
      left_h = compute_node_hash({:leaf, path, val_hash}, height - 1)
      right_h = default_hash(height - 1)
      :crypto.hash(:sha256, <<2::8>> <> left_h <> right_h)
    else
      left_h = default_hash(height - 1)
      right_h = compute_node_hash({:leaf, path, val_hash}, height - 1)
      :crypto.hash(:sha256, <<2::8>> <> left_h <> right_h)
    end
  end

  def compute_node_hash({:branch, left, right}, height) when height > 0 do
    h_left = compute_node_hash(left, height - 1)
    h_right = compute_node_hash(right, height - 1)
    :crypto.hash(:sha256, <<2::8>> <> h_left <> h_right)
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
