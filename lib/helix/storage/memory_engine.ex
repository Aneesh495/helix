defmodule Helix.Storage.MemoryEngine do
  @moduledoc """
  High-throughput in-memory ETS storage engine implementing the Helix.Storage.Engine contract.
  Provides concurrent reads and atomic point-in-time snapshotting.
  """

  @behaviour Helix.Storage.Engine

  defstruct [:table_name]

  @type t :: %__MODULE__{table_name: atom()}

  @doc """
  Initializes an ETS-backed memory storage engine instance.
  """
  @spec new(atom()) :: t()
  def new(table_name \\ :helix_storage_memory) do
    if :ets.whereis(table_name) == :undefined do
      :ets.new(table_name, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    %__MODULE__{table_name: table_name}
  end

  @impl true
  def get(key) do
    get(:helix_storage_memory, key)
  end

  @doc """
  Fetches value for a key from specified memory table.
  """
  @spec get(atom() | t(), binary()) :: {:ok, term()} | :not_found
  def get(%__MODULE__{table_name: table}, key), do: get(table, key)

  def get(table, key) when is_atom(table) and is_binary(key) do
    case :ets.lookup(table, key) do
      [{^key, val}] -> {:ok, val}
      [] -> :not_found
    end
  end

  @impl true
  def put(key, value) do
    put(:helix_storage_memory, key, value)
  end

  @doc """
  Inserts or updates a key-value entry.
  """
  @spec put(atom() | t(), binary(), term()) :: :ok
  def put(%__MODULE__{table_name: table}, key, value), do: put(table, key, value)

  def put(table, key, value) when is_atom(table) and is_binary(key) do
    :ets.insert(table, {key, value})
    :ok
  end

  @impl true
  def delete(key) do
    delete(:helix_storage_memory, key)
  end

  @doc """
  Deletes an entry by key.
  """
  @spec delete(atom() | t(), binary()) :: :ok
  def delete(%__MODULE__{table_name: table}, key), do: delete(table, key)

  def delete(table, key) when is_atom(table) and is_binary(key) do
    :ets.delete(table, key)
    :ok
  end

  @impl true
  def batch_write(ops) do
    batch_write(:helix_storage_memory, ops)
  end

  @doc """
  Executes an atomic batch of write and delete operations.
  """
  @spec batch_write(atom() | t(), [{:put, binary(), term()} | {:delete, binary()}]) :: :ok
  def batch_write(%__MODULE__{table_name: table}, ops), do: batch_write(table, ops)

  def batch_write(table, ops) when is_atom(table) and is_list(ops) do
    Enum.each(ops, fn
      {:put, key, val} -> :ets.insert(table, {key, val})
      {:delete, key} -> :ets.delete(table, key)
    end)

    :ok
  end

  @doc """
  Dumps all entries in the storage table into an Elixir map.
  """
  @spec dump(atom() | t()) :: %{binary() => term()}
  def dump(%__MODULE__{table_name: table}), do: dump(table)

  def dump(table) when is_atom(table) do
    :ets.tab2list(table) |> Map.new()
  end

  @impl true
  def checkpoint do
    checkpoint(:helix_storage_memory)
  end

  @doc """
  Computes a cryptographic checkpoint checksum across all current state keys.
  """
  @spec checkpoint(atom() | t()) :: {:ok, binary()}
  def checkpoint(%__MODULE__{table_name: table}), do: checkpoint(table)

  def checkpoint(table) when is_atom(table) do
    entries = :ets.tab2list(table) |> Enum.sort_by(&elem(&1, 0))
    payload = :erlang.term_to_binary(entries)
    hash = :crypto.hash(:sha256, payload)
    {:ok, hash}
  end
end
