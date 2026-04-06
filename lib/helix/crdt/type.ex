defmodule Helix.CRDT.Type do
  @moduledoc """
  Behaviour definition for Conflict-Free Replicated Data Types (CRDTs).
  Defines join semilattice operations: commutativity, associativity, and idempotence.
  """

  @type state :: term()
  @type delta :: term()

  @callback value(state()) :: term()
  @callback merge(state(), state() | delta()) :: state()
  @callback delta(state()) :: delta() | nil
  @callback reset_delta(state()) :: state()
end
