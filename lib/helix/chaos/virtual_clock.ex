defmodule Helix.Chaos.VirtualClock do
  @moduledoc """
  Discrete-event simulated virtual clock for deterministic simulation testing.
  Allows reproducible time advancement and discrete tick scheduling without real-world pauses.
  """

  defstruct current_time: 0,
            scheduled_events: []

  @type event_item :: {time :: non_neg_integer(), id :: term(), (-> any())}
  @type t :: %__MODULE__{
          current_time: non_neg_integer(),
          scheduled_events: [event_item()]
        }

  @doc """
  Initializes a new virtual clock starting at time 0.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{current_time: 0, scheduled_events: []}
  end

  @doc """
  Returns the current simulated virtual time.
  """
  @spec now(t()) :: non_neg_integer()
  def now(%__MODULE__{current_time: t}), do: t

  @doc """
  Schedules a callback to be triggered at or after a future virtual timestamp.
  """
  @spec schedule_at(t(), non_neg_integer(), term(), (-> any())) :: t()
  def schedule_at(%__MODULE__{} = clock, timestamp, id, callback) do
    item = {timestamp, id, callback}
    new_events = Enum.sort_by([item | clock.scheduled_events], &elem(&1, 0))
    %{clock | scheduled_events: new_events}
  end

  @doc """
  Advances the virtual clock by `delta_ticks`, executing all pending callbacks
  whose scheduled timestamps have been reached.
  Returns {executed_count, updated_clock}.
  """
  @spec advance(t(), pos_integer()) :: {non_neg_integer(), t()}
  def advance(%__MODULE__{} = clock, delta_ticks) when delta_ticks >= 0 do
    target_time = clock.current_time + delta_ticks

    {ready_events, remaining_events} =
      Enum.split_with(clock.scheduled_events, fn {ts, _id, _cb} -> ts <= target_time end)

    # Execute callbacks in timestamp order
    Enum.each(ready_events, fn {_ts, _id, cb} ->
      cb.()
    end)

    {length(ready_events),
     %{clock | current_time: target_time, scheduled_events: remaining_events}}
  end
end
