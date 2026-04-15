defmodule Helix.CRDT.AWSet do
  @moduledoc """
  Add-Wins Observed-Remove Set (AWSet / OR-Set) delta-CRDT.
  Uses causal dots to resolve concurrent adds and removes without persistent tombstones.
  An add concurrently with a remove wins.
  """

  @behaviour Helix.CRDT.Type

  alias Helix.CRDT.CausalContext

  defstruct elements: %{},
            causal_context: nil,
            delta: nil

  @type dot :: {term(), pos_integer()}
  @type element :: term()

  @type t :: %__MODULE__{
          elements: %{element() => MapSet.t(dot())},
          causal_context: CausalContext.t(),
          delta: map() | nil
        }

  @doc """
  Initializes a new empty Add-Wins Set.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      elements: %{},
      causal_context: CausalContext.new(),
      delta: nil
    }
  end

  @doc """
  Returns a list of all active elements in the set.
  """
  @impl true
  @spec value(t()) :: [element()]
  def value(%__MODULE__{elements: elems}) do
    Map.keys(elems)
  end

  @doc """
  Checks if an element is currently in the set.
  """
  @spec member?(t(), element()) :: boolean()
  def member?(%__MODULE__{elements: elems}, element) do
    case Map.get(elems, element) do
      nil -> false
      set -> MapSet.size(set) > 0
    end
  end

  @doc """
  Adds an element to the set, tagged with a fresh causal dot.
  """
  @spec add(t(), element(), term()) :: t()
  def add(%__MODULE__{} = set, element, node_id) do
    {dot, new_cc} = CausalContext.next_dot(set.causal_context, node_id)

    # Any prior dots for this element are overwritten by the new dot
    new_dots = MapSet.new([dot])
    new_elements = Map.put(set.elements, element, new_dots)

    delta = %{
      elements: %{element => new_dots},
      causal_context: CausalContext.add_dot(CausalContext.new(), elem(dot, 0), elem(dot, 1))
    }

    %{set | elements: new_elements, causal_context: new_cc, delta: delta}
  end

  @doc """
  Removes an element from the set.
  Observed dots for the element are removed from the element map,
  while remaining in the causal context to prevent older remote adds from resurrecting it.
  """
  @spec remove(t(), element()) :: t()
  def remove(%__MODULE__{} = set, element) do
    if Map.has_key?(set.elements, element) do
      dots = Map.fetch!(set.elements, element)
      new_elements = Map.delete(set.elements, element)

      delta_cc =
        Enum.reduce(dots, CausalContext.new(), fn {n, c}, acc ->
          CausalContext.add_dot(acc, n, c)
        end)

      delta = %{
        elements: %{},
        causal_context: delta_cc
      }

      %{set | elements: new_elements, delta: delta}
    else
      set
    end
  end

  @doc """
  Merges another AWSet or delta into this set.
  Preserves dots that:
  1. Are present in both sets
  2. Are in set 1 but have not been observed by set 2
  3. Are in set 2 but have not been observed by set 1
  """
  @impl true
  @spec merge(t(), t() | map()) :: t()
  def merge(%__MODULE__{} = s1, %__MODULE__{} = s2) do
    merge_internal(s1, s2.elements, s2.causal_context)
  end

  def merge(%__MODULE__{} = s1, %{elements: e2, causal_context: cc2}) do
    merge_internal(s1, e2, cc2)
  end

  defp merge_internal(s1, e2, cc2) do
    all_keys = MapSet.union(MapSet.new(Map.keys(s1.elements)), MapSet.new(Map.keys(e2)))

    new_elements =
      Enum.reduce(all_keys, %{}, fn key, acc ->
        dots1 = Map.get(s1.elements, key, MapSet.new())
        dots2 = Map.get(e2, key, MapSet.new())

        # Keep dots in dots1 not covered by cc2
        surviving1 =
          Enum.filter(dots1, fn {n, c} ->
            not CausalContext.member?(cc2, n, c)
          end)
          |> MapSet.new()

        # Keep dots in dots2 not covered by s1.causal_context
        surviving2 =
          Enum.filter(dots2, fn {n, c} ->
            not CausalContext.member?(s1.causal_context, n, c)
          end)
          |> MapSet.new()

        # Both present
        common = MapSet.intersection(dots1, dots2)

        surviving = MapSet.union(common, MapSet.union(surviving1, surviving2))

        if MapSet.size(surviving) > 0 do
          Map.put(acc, key, surviving)
        else
          acc
        end
      end)

    new_cc = CausalContext.merge(s1.causal_context, cc2)
    %{s1 | elements: new_elements, causal_context: new_cc, delta: nil}
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
  def reset_delta(%__MODULE__{} = set) do
    %{set | delta: nil}
  end
end
