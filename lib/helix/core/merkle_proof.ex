defmodule Helix.Core.MerkleProof do
  @moduledoc """
  Cryptographic inclusion and non-inclusion proof generation and verification
  for the Helix Sparse Merkle Tree.
  Supports both empty-slot non-membership and conflicting-leaf exclusion proofs.
  """

  alias Helix.Core.SparseMerkleTree, as: SMT

  defstruct [
    :key,
    :value,
    :key_path,
    :value_hash,
    :root_hash,
    :siblings,
    :conflicting_path,
    :conflicting_val_hash,
    non_membership: false
  ]

  @type t :: %__MODULE__{
          key: binary(),
          value: term() | nil,
          key_path: binary(),
          value_hash: binary() | nil,
          root_hash: binary(),
          siblings: list({:left | :right, binary()}),
          conflicting_path: binary() | nil,
          conflicting_val_hash: binary() | nil,
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

    {siblings, conflict_info} = collect_proof_path(tree.root, key_path, 0)

    {conf_path, conf_val_hash} =
      case conflict_info do
        {:conflict, cp, cvh} -> {cp, cvh}
        _ -> {nil, nil}
      end

    %__MODULE__{
      key: key,
      value: value,
      key_path: key_path,
      value_hash: val_hash,
      root_hash: tree.root_hash,
      siblings: siblings,
      conflicting_path: conf_path,
      conflicting_val_hash: conf_val_hash,
      non_membership: non_member
    }
  end

  @doc """
  Verifies a Merkle proof against a trusted root hash.
  """
  @spec verify(t(), binary()) :: {:ok, binary()} | {:error, atom()}
  def verify(%__MODULE__{} = proof, expected_root_hash) do
    target_start_hash =
      cond do
        proof.non_membership and proof.conflicting_path != nil ->
          if proof.conflicting_path == proof.key_path do
            :invalid_exclusion
          else
            SMT.compute_leaf_hash(proof.conflicting_path, proof.conflicting_val_hash)
          end

        proof.non_membership ->
          SMT.empty_hash()

        true ->
          SMT.compute_leaf_hash(proof.key_path, proof.value_hash)
      end

    if target_start_hash == :invalid_exclusion do
      {:error, :invalid_exclusion_proof}
    else
      ascending_siblings = Enum.reverse(proof.siblings)

      computed_root =
        Enum.reduce(ascending_siblings, target_start_hash, fn {side, sibling_hash},
                                                              current_hash ->
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
  end

  defp collect_proof_path(:empty, _key_path, _depth) do
    {[], :empty}
  end

  defp collect_proof_path({:leaf, _h, path, val_hash}, key_path, _depth) do
    if path == key_path do
      {[], :exact}
    else
      {[], {:conflict, path, val_hash}}
    end
  end

  defp collect_proof_path({:branch, _h, left, right}, key_path, depth) do
    bit = SMT.get_bit(key_path, depth)

    if bit == 0 do
      sibling_hash = SMT.node_hash(right)
      {sub_siblings, outcome} = collect_proof_path(left, key_path, depth + 1)
      {[{:right, sibling_hash} | sub_siblings], outcome}
    else
      sibling_hash = SMT.node_hash(left)
      {sub_siblings, outcome} = collect_proof_path(right, key_path, depth + 1)
      {[{:left, sibling_hash} | sub_siblings], outcome}
    end
  end
end
