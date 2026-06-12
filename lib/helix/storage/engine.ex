defmodule Helix.Storage.Engine do
  @moduledoc """
  Storage behaviour definition for state persistence, batching, and point-in-time snapshots.
  """

  @type key :: binary()
  @type value :: term()

  @callback get(key()) :: {:ok, value()} | :not_found
  @callback put(key(), value()) :: :ok
  @callback delete(key()) :: :ok
  @callback batch_write([{:put, key(), value()} | {:delete, key()}]) :: :ok
  @callback checkpoint() :: {:ok, binary()} | {:error, term()}
end
