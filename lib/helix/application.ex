defmodule Helix.Application do
  @moduledoc """
  Root OTP application supervision tree for Helix.
  Initializes local ETS tables, dynamic supervisors, and subsystems.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure root ETS tables exist for local instance and storage state
    ensure_tables()

    children = [
      {Registry, keys: :unique, name: Helix.ProcessRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Helix.DynamicSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Helix.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_tables do
    tables = [
      :helix_instances,
      :helix_conflicts,
      :helix_storage_memory,
      :helix_crdt_store,
      :helix_telemetry
    ]

    Enum.each(tables, fn name ->
      if :ets.whereis(name) == :undefined do
        :ets.new(name, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
      end
    end)
  end
end
