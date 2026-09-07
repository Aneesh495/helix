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

    siblings = collect_siblings(tree.root, key_path, 0)

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
  """
  @spec verify(t(), binary()) :: {:ok, binary()} | {:error, atom()}
  def verify(%__MODULE__{} = proof, expected_root_hash) do
    target_leaf_hash =
      if proof.non_membership do
        SMT.empty_hash()
      else
        SMT.compute_leaf_hash(proof.key_path, proof.value_hash)
      end

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

  defp collect_siblings(:empty, _key_path, _depth), do: []

  defp collect_siblings({:leaf, h, path, _val_hash}, key_path, depth) do
    if path == key_path do
      []
    else
      bit = SMT.get_bit(key_path, depth)
      side = if bit == 0, do: :right, else: :left
      [{side, h}]
    end
  end

  defp collect_siblings({:branch, _h, left, right}, key_path, depth) do
    bit = SMT.get_bit(key_path, depth)

    if bit == 0 do
      sibling_hash = SMT.node_hash(right)
      [{:right, sibling_hash} | collect_siblings(left, key_path, depth + 1)]
    else
      sibling_hash = SMT.node_hash(left)
      [{:left, sibling_hash} | collect_siblings(right, key_path, depth + 1)]
    end
  end
end
