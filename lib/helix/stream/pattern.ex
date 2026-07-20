defmodule Helix.Stream.Pattern do
  @moduledoc """
  Finite State Automaton (FSA) pattern matching engine for Complex Event Processing (CEP).
  Detects temporal event correlations (e.g., A followed by B followed by C within duration).
  """

  alias Helix.Stream.Event

  defstruct [
    stages: [],
    within_ms: nil
  ]

  @type stage :: %{
          name: atom(),
          predicate: (Event.t() -> boolean()),
          quantifier: :one | :zero_or_more
        }

  @type t :: %__MODULE__{
          stages: [stage()],
          within_ms: pos_integer() | nil
        }

  @doc """
  Initializes a new pattern definition.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    within = Keyword.get(opts, :within_ms, nil)
    %__MODULE__{stages: [], within_ms: within}
  end

  @doc """
  Appends a mandatory single event stage to the pattern sequence.
  """
  @spec where(t(), atom(), (Event.t() -> boolean())) :: t()
  def where(%__MODULE__{} = pattern, name, predicate) when is_function(predicate, 1) do
    stage = %{name: name, predicate: predicate, quantifier: :one}
    %{pattern | stages: pattern.stages ++ [stage]}
  end

  @doc """
  Matches an incoming stream of events against the pattern.
  Returns a list of matched sequence bindings: [%{stage_name => Event.t()}].
  """
  @spec match(t(), [Event.t()]) :: [map()]
  def match(%__MODULE__{stages: stages, within_ms: within}, events) when is_list(events) do
    sorted_events = Enum.sort_by(events, & &1.timestamp)
    do_match(stages, sorted_events, within, [])
  end

  defp do_match([], _events, _within, _current_bindings), do: []

  defp do_match(stages, events, within, acc_matches) do
    # Search for all starting points matching stage 1
    [first_stage | remaining_stages] = stages

    candidate_starts =
      Enum.filter(events, fn e -> first_stage.predicate.(e) end)

    Enum.reduce(candidate_starts, acc_matches, fn start_event, matches ->
      bindings = %{first_stage.name => start_event}
      subsequent_events = Enum.filter(events, &(&1.timestamp > start_event.timestamp))

      completed = find_subsequent_stages(remaining_stages, subsequent_events, start_event.timestamp, within, bindings)
      matches ++ completed
    end)
  end

  defp find_subsequent_stages([], _events, _start_ts, _within, bindings) do
    [bindings]
  end

  defp find_subsequent_stages([stage | rest_stages], events, start_ts, within, bindings) do
    # Filter candidate events that satisfy time window
    valid_time_events =
      Enum.filter(events, fn e ->
        if within do
          e.timestamp - start_ts <= within
        else
          true
        end
      end)

    candidate = Enum.find(valid_time_events, fn e -> stage.predicate.(e) end)

    case candidate do
      nil ->
        []

      event ->
        new_bindings = Map.put(bindings, stage.name, event)
        remaining = Enum.filter(events, &(&1.timestamp > event.timestamp))
        find_subsequent_stages(rest_stages, remaining, start_ts, within, new_bindings)
    end
  end
end
