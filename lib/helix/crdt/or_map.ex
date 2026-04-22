defmodule Helix.CRDT.ORMap do
  @moduledoc """
  Observed-Remove Map (OR-Map) delta-CRDT.
  Manages key lifecycles using an underlying Add-Wins Set while holding nested
  arbitrary CRDTs (counters, sets, registers) as values.
  """

  @behaviour Helix.CRDT.Type

  alias Helix.CRDT.AWSet

  defstruct keyset: nil,
            entries: %{},
            delta: nil

  @type key :: term()
  @type crdt_entry :: {module(), term()}
  @type t :: %__MODULE__{
          keyset: AWSet.t(),
          entries: %{key() => crdt_entry()},
          delta: map() | nil
        }

  @doc """
  Initializes an empty Observed-Remove Map.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      keyset: AWSet.new(),
      entries: %{},
      delta: nil
    }
  end

  @doc """
  Returns a plain Elixir map of all active keys mapped to their evaluated CRDT values.
  """
  @impl true
  @spec value(t()) :: %{key() => term()}
  def value(%__MODULE__{keyset: ks, entries: entries}) do
    active_keys = AWSet.value(ks)

    Enum.reduce(active_keys, %{}, fn k, acc ->
      case Map.get(entries, k) do
        {mod, state} -> Map.put(acc, k, mod.value(state))
        nil -> acc
      end
    end)
  end

  @doc """
  Fetches the raw nested CRDT state and its module for a key.
  """
  @spec get_crdt(t(), key()) :: {:ok, module(), term()} | :not_found
  def get_crdt(%__MODULE__{keyset: ks, entries: entries}, key) do
    if AWSet.member?(ks, key) do
      case Map.get(entries, key) do
        {mod, state} -> {:ok, mod, state}
        nil -> :not_found
      end
    else
      :not_found
    end
  end

  @doc """
  Puts or initializes a nested CRDT at the specified key.
  """
  @spec put_crdt(t(), key(), module(), term(), term()) :: t()
  def put_crdt(%__MODULE__{} = map, key, crdt_module, crdt_state, node_id) do
    new_keyset = AWSet.add(map.keyset, key, node_id)
    new_entries = Map.put(map.entries, key, {crdt_module, crdt_state})

    delta = %{
      keyset: AWSet.delta(new_keyset),
      entries: %{key => {crdt_module, crdt_state}}
    }

    %{map | keyset: new_keyset, entries: new_entries, delta: delta}
  end

  @doc """
  Updates an existing nested CRDT value using the provided transformation function.
  """
  @spec update_crdt(t(), key(), (term() -> term()), term()) :: t()
  def update_crdt(%__MODULE__{} = map, key, update_fn, node_id) do
    case get_crdt(map, key) do
      {:ok, mod, state} ->
        updated_state = update_fn.(state)
        put_crdt(map, key, mod, updated_state, node_id)

      :not_found ->
        map
    end
  end

  @doc """
  Removes a key and evicts its nested CRDT.
  """
  @spec remove(t(), key()) :: t()
  def remove(%__MODULE__{} = map, key) do
    if AWSet.member?(map.keyset, key) do
      new_keyset = AWSet.remove(map.keyset, key)
      new_entries = Map.delete(map.entries, key)

      delta = %{
        keyset: AWSet.delta(new_keyset),
        entries: %{}
      }

      %{map | keyset: new_keyset, entries: new_entries, delta: delta}
    else
      map
    end
  end

  @doc """
  Merges two ORMaps or an ORMap and a delta.
  """
  @impl true
  @spec merge(t(), t() | map()) :: t()
  def merge(%__MODULE__{} = m1, %__MODULE__{} = m2) do
    merge_internal(m1, m2.keyset, m2.entries)
  end

  def merge(%__MODULE__{} = m1, %{keyset: ks2, entries: entries2}) do
    merge_internal(m1, ks2, entries2)
  end

  defp merge_internal(m1, ks2, entries2) do
    new_keyset = AWSet.merge(m1.keyset, ks2)
    active_keys = MapSet.new(AWSet.value(new_keyset))

    all_keys = MapSet.union(MapSet.new(Map.keys(m1.entries)), MapSet.new(Map.keys(entries2)))

    new_entries =
      Enum.reduce(all_keys, %{}, fn k, acc ->
        if MapSet.member?(active_keys, k) do
          e1 = Map.get(m1.entries, k)
          e2 = Map.get(entries2, k)

          merged_entry =
            case {e1, e2} do
              {{mod, s1}, {mod, s2}} -> {mod, mod.merge(s1, s2)}
              {{mod, s1}, nil} -> {mod, s1}
              {nil, {mod, s2}} -> {mod, s2}
              _other -> nil
            end

          if merged_entry, do: Map.put(acc, k, merged_entry), else: acc
        else
          acc
        end
      end)

    %{m1 | keyset: new_keyset, entries: new_entries, delta: nil}
  end

  @doc """
  Returns buffered delta if present.
  """
  @impl true
  @spec delta(t()) :: map() | nil
  def delta(%__MODULE__{delta: d}), do: d

  @doc """
  Resets the delta buffer.
  """
  @impl true
  @spec reset_delta(t()) :: t()
  def reset_delta(%__MODULE__{} = map) do
    %{map | delta: nil}
  end
end
