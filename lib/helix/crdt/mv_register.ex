defmodule Helix.CRDT.MVRegister do
  @moduledoc """
  Multi-Value Register (MV-Register) delta-CRDT.
  Tracks concurrent conflicting writes using causal dots, exposing all concurrent values
  until explicitly resolved by a successor write.
  """

  @behaviour Helix.CRDT.Type

  alias Helix.CRDT.CausalContext

  defstruct values: %{},
            causal_context: nil,
            delta: nil

  @type dot :: {term(), pos_integer()}
  @type t :: %__MODULE__{
          values: %{dot() => term()},
          causal_context: CausalContext.t(),
          delta: map() | nil
        }

  @doc """
  Initializes a new empty Multi-Value Register.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      values: %{},
      causal_context: CausalContext.new(),
      delta: nil
    }
  end

  @doc """
  Returns the list of all concurrent values currently held in the register.
  """
  @impl true
  @spec value(t()) :: [term()]
  def value(%__MODULE__{values: vals}) do
    vals |> Map.values() |> Enum.uniq()
  end

  @doc """
  Writes a new value to the register at the given node.
  Overwrites all previously observed concurrent values.
  """
  @spec write(t(), term(), term()) :: t()
  def write(%__MODULE__{} = reg, val, node_id) do
    {dot, new_cc} = CausalContext.next_dot(reg.causal_context, node_id)

    new_values = %{dot => val}

    delta_cc =
      Enum.reduce(Map.keys(reg.values), CausalContext.new(), fn {n, c}, acc ->
        CausalContext.add_dot(acc, n, c)
      end)
      |> CausalContext.add_dot(elem(dot, 0), elem(dot, 1))

    delta = %{
      values: new_values,
      causal_context: delta_cc
    }

    %{reg | values: new_values, causal_context: new_cc, delta: delta}
  end

  @doc """
  Merges two MVRegisters or an MVRegister and a delta.
  """
  @impl true
  @spec merge(t(), t() | map()) :: t()
  def merge(%__MODULE__{} = r1, %__MODULE__{} = r2) do
    merge_internal(r1, r2.values, r2.causal_context)
  end

  def merge(%__MODULE__{} = r1, %{values: v2, causal_context: cc2}) do
    merge_internal(r1, v2, cc2)
  end

  defp merge_internal(r1, v2, cc2) do
    all_dots = MapSet.union(MapSet.new(Map.keys(r1.values)), MapSet.new(Map.keys(v2)))

    surviving =
      Enum.reduce(all_dots, %{}, fn dot = {n, c}, acc ->
        in_r1 = Map.has_key?(r1.values, dot)
        in_r2 = Map.has_key?(v2, dot)

        cond do
          in_r1 and in_r2 ->
            Map.put(acc, dot, Map.fetch!(r1.values, dot))

          in_r1 and not CausalContext.member?(cc2, n, c) ->
            Map.put(acc, dot, Map.fetch!(r1.values, dot))

          in_r2 and not CausalContext.member?(r1.causal_context, n, c) ->
            Map.put(acc, dot, Map.fetch!(v2, dot))

          true ->
            acc
        end
      end)

    new_cc = CausalContext.merge(r1.causal_context, cc2)
    %{r1 | values: surviving, causal_context: new_cc, delta: nil}
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
  def reset_delta(%__MODULE__{} = reg) do
    %{reg | delta: nil}
  end
end
