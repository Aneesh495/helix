defmodule Helix do
  @moduledoc """
  Helix: A leaderless distributed transaction kernel in pure Elixir.

  Features:
  - Egalitarian Paxos (EPaxos) consensus with 1-RTT fast path
  - Block-STM optimistic parallel execution engine with dynamic dependency tracking
  - Authenticated Sparse Merkle Trees (SMT) with 256-bit cryptographic state proofs
  - Delta-state Conflict-Free Replicated Data Types (CRDTs)
  - SWIM cluster membership gossip with suspicion failure detector
  - Reactive Complex Event Processing (CEP) temporal streaming
  - Deterministic discrete-event simulation and Jepsen-style chaos verification
  """

  @version "0.1.0"

  @doc """
  Returns the current Helix release version string.
  """
  def version, do: @version
end
