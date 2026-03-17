defmodule Helix.Core.MerkleProof do
  @moduledoc """
  Cryptographic inclusion and non-inclusion proof generation and verification
  for the Helix Sparse Merkle Tree.
  """

  alias Helix.Core.SparseMerkleTree, as: SMT

  defstruct [
    :key,
    :value,
    :key_path,
    :value_hash,
    :root_hash,
    :siblings,
    non_membership: false
  ]

  @type t :: %__MODULE__{
          key: binary(),
          value: term() | nil,
          key_path: binary(),
          value_hash: binary() | nil,
          root_hash: binary(),
          siblings: list({:left | :right, binary()}),
          non_membership: boolean()
        }

  @doc """
  Generates a Merkle audit proof for a given key in the SMT.
  If the key exists, generates an inclusion proof.
  If the key does not exist, generates a non-inclusion (exclusion) proof.
  """
  @spec generate(SMT.t(), binary()) :: t()
  def generate(%SMT{} = tree, key) when is_binary(key) do
    key_path = SMT.hash_key(key)
    lookup = SMT.get(tree, key)

    {value, val_hash, non_member} =
      case lookup do
        {:ok, val} -> {val, SMT.hash_value(val), false}
        :not_found -> {nil, nil, true}
      end

    siblings = collect_siblings_down(tree.root, key_path, 0, tree.depth)

    %__MODULE__{
      key: key,
      value: value,
      key_path: key_path,
      value_hash: val_hash,
      root_hash: tree.root_hash,
      siblings: siblings,
      non_membership: non_member
    }
  end

  @doc """
  Verifies a Merkle proof against a trusted root hash.
  Returns {:ok, root_hash} if the proof is valid, or {:error, reason} otherwise.
  """
  @spec verify(t(), binary()) :: {:ok, binary()} | {:error, atom()}
  def verify(%__MODULE__{} = proof, expected_root_hash) do
    target_leaf_hash =
      if proof.non_membership do
        SMT.default_hash(0)
      else
        :crypto.hash(:sha256, <<1::8>> <> proof.key_path <> proof.value_hash)
      end

    # Sibling list was collected from root (depth 0) down to leaves (depth 255).
    # Verification ascends from height 0 up to height 256.
    ascending_siblings = Enum.reverse(proof.siblings)

    computed_root =
      Enum.reduce(ascending_siblings, target_leaf_hash, fn {side, sibling_hash}, current_hash ->
        case side do
          :right ->
            :crypto.hash(:sha256, <<2::8>> <> current_hash <> sibling_hash)

          :left ->
            :crypto.hash(:sha256, <<2::8>> <> sibling_hash <> current_hash)
        end
      end)

    if computed_root == expected_root_hash do
      {:ok, computed_root}
    else
      {:error, :root_hash_mismatch}
    end
  end

  defp collect_siblings_down(_node, _key_path, depth, max_depth) when depth >= max_depth do
    []
  end

  defp collect_siblings_down(:empty, key_path, depth, max_depth) do
    remaining_height = max_depth - 1 - depth
    bit = SMT.get_bit(key_path, depth)
    side = if bit == 0, do: :right, else: :left
    sibling_hash = SMT.default_hash(remaining_height)

    [{side, sibling_hash} | collect_siblings_down(:empty, key_path, depth + 1, max_depth)]
  end

  defp collect_siblings_down({:leaf, path, val_hash}, key_path, depth, max_depth) do
    remaining_height = max_depth - 1 - depth
    bit = SMT.get_bit(key_path, depth)

    if path == key_path do
      side = if bit == 0, do: :right, else: :left
      sibling_hash = SMT.default_hash(remaining_height)
      [{side, sibling_hash} | collect_siblings_down({:leaf, path, val_hash}, key_path, depth + 1, max_depth)]
    else
      # Conflicting leaf in sparse trie
      other_bit = SMT.get_bit(path, depth)

      if other_bit == bit do
        side = if bit == 0, do: :right, else: :left
        sibling_hash = SMT.default_hash(remaining_height)
        [{side, sibling_hash} | collect_siblings_down({:leaf, path, val_hash}, key_path, depth + 1, max_depth)]
      else
        side = if bit == 0, do: :right, else: :left
        sibling_hash = SMT.compute_node_hash({:leaf, path, val_hash}, remaining_height)
        [{side, sibling_hash} | collect_siblings_down(:empty, key_path, depth + 1, max_depth)]
      end
    end
  end

  defp collect_siblings_down({:branch, left, right}, key_path, depth, max_depth) do
    remaining_height = max_depth - 1 - depth
    bit = SMT.get_bit(key_path, depth)

    if bit == 0 do
      sibling_hash = SMT.compute_node_hash(right, remaining_height)
      [{:right, sibling_hash} | collect_siblings_down(left, key_path, depth + 1, max_depth)]
    else
      sibling_hash = SMT.compute_node_hash(left, remaining_height)
      [{:left, sibling_hash} | collect_siblings_down(right, key_path, depth + 1, max_depth)]
    end
  end
end
