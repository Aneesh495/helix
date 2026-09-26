defmodule Helix.Stream.Window do
  @moduledoc """
  Event-time windowing operators: tumbling, sliding, and session windows
  with watermark-based late event eviction.
  """

  alias Helix.Stream.Event

  @type window_range :: {start_ts :: non_neg_integer(), end_ts :: non_neg_integer()}
  @type windowed_batch :: {window_range(), [Event.t()]}

  @doc """
  Partitions events into fixed, non-overlapping tumbling windows of duration `size_ms`.
  """
  @spec tumbling([Event.t()], pos_integer()) :: [windowed_batch()]
  def tumbling(events, size_ms) when is_list(events) and size_ms > 0 do
    events
    |> Enum.group_by(fn event ->
      window_start = div(event.timestamp, size_ms) * size_ms
      {window_start, window_start + size_ms}
    end)
    |> Enum.sort_by(fn {{start_ts, _}, _} -> start_ts end)
    |> Enum.map(fn {range, evs} ->
      {range, Enum.sort_by(evs, & &1.timestamp)}
    end)
  end

  @doc """
  Partitions events into overlapping sliding windows of duration `size_ms`
  advancing by `slide_ms`.
  """
  @spec sliding([Event.t()], pos_integer(), pos_integer()) :: [windowed_batch()]
  def sliding(events, size_ms, slide_ms) when is_list(events) and size_ms > 0 and slide_ms > 0 do
    if length(events) == 0 do
      []
    else
      min_ts = Enum.map(events, & &1.timestamp) |> Enum.min()
      max_ts = Enum.map(events, & &1.timestamp) |> Enum.max()

      first_window_start = div(min_ts, slide_ms) * slide_ms

      # Generate all window starts
      window_starts =
        Stream.iterate(first_window_start, &(&1 + slide_ms))
        |> Enum.take_while(&(&1 <= max_ts))

      window_starts
      |> Enum.map(fn w_start ->
        w_end = w_start + size_ms

        matching =
          Enum.filter(events, fn e ->
            e.timestamp >= w_start and e.timestamp < w_end
          end)

        {{w_start, w_end}, Enum.sort_by(matching, & &1.timestamp)}
      end)
      |> Enum.reject(fn {_range, evs} -> evs == [] end)
    end
  end

  @doc """
  Partitions events into session windows separated by inactivity gap `gap_ms`.
  """
  @spec session([Event.t()], pos_integer()) :: [windowed_batch()]
  def session([], _gap_ms), do: []

  def session(events, gap_ms) when is_list(events) and gap_ms > 0 do
    sorted = Enum.sort_by(events, & &1.timestamp)
    [first | rest] = sorted

    initial_session = {[first], first.timestamp, first.timestamp}

    {sessions, final_session} =
      Enum.reduce(rest, {[], initial_session}, fn event,
                                                  {acc_sessions, {cur_evs, s_start, s_end}} ->
        if event.timestamp - s_end > gap_ms do
          # Gap exceeded: close current session and start new
          completed = {{s_start, s_end}, Enum.reverse(cur_evs)}
          {[completed | acc_sessions], {[event], event.timestamp, event.timestamp}}
        else
          # Continue current session
          {acc_sessions, {[event | cur_evs], s_start, max(s_end, event.timestamp)}}
        end
      end)

    {last_range, last_evs} =
      case final_session do
        {evs, start_ts, end_ts} -> {{start_ts, end_ts}, Enum.reverse(evs)}
      end

    Enum.reverse([{last_range, last_evs} | sessions])
  end

  @doc """
  Reduces each window using an accumulator function.
  """
  @spec aggregate([windowed_batch()], (Event.t(), term() -> term()), term()) ::
          [{window_range(), term()}]
  def aggregate(window_batches, reduce_fn, initial_acc) do
    Enum.map(window_batches, fn {range, evs} ->
      acc = Enum.reduce(evs, initial_acc, reduce_fn)
      {range, acc}
    end)
  end
end
