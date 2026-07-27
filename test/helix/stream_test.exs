defmodule Helix.StreamTest do
  use ExUnit.Case, async: true

  alias Helix.Stream.Event
  alias Helix.Stream.Window
  alias Helix.Stream.Pattern
  alias Helix.Stream.Pipeline
  alias Helix.Stream.QueryCompiler

  describe "Temporal Events" do
    test "instantiates events with timestamps and default watermarks" do
      ev = Event.new("ev_1", "market:trades", %{price: 100}, timestamp: 1000)
      assert ev.id == "ev_1"
      assert ev.topic == "market:trades"
      assert ev.timestamp == 1000
      assert ev.watermark == 1000
    end
  end

  describe "Windowing Operators" do
    test "partitions events into tumbling windows" do
      events = [
        Event.new("1", "t", %{v: 1}, timestamp: 100),
        Event.new("2", "t", %{v: 2}, timestamp: 400),
        Event.new("3", "t", %{v: 3}, timestamp: 600),
        Event.new("4", "t", %{v: 4}, timestamp: 1100)
      ]

      # 500ms tumbling windows: [0, 500) and [500, 1000) and [1000, 1500)
      windows = Window.tumbling(events, 500)
      assert length(windows) == 3

      assert elem(Enum.at(windows, 0), 0) == {0, 500}
      assert length(elem(Enum.at(windows, 0), 1)) == 2

      assert elem(Enum.at(windows, 1), 0) == {500, 1000}
      assert length(elem(Enum.at(windows, 1), 1)) == 1

      assert elem(Enum.at(windows, 2), 0) == {1000, 1500}
      assert length(elem(Enum.at(windows, 2), 1)) == 1
    end

    test "partitions events into sliding windows" do
      events = [
        Event.new("1", "t", %{v: 1}, timestamp: 100),
        Event.new("2", "t", %{v: 2}, timestamp: 250),
        Event.new("3", "t", %{v: 3}, timestamp: 450)
      ]

      # 300ms window, 100ms slide
      windows = Window.sliding(events, 300, 100)
      assert length(windows) >= 3
    end

    test "partitions events into session windows based on inactivity gaps" do
      events = [
        Event.new("1", "t", %{v: 1}, timestamp: 100),
        Event.new("2", "t", %{v: 2}, timestamp: 200),
        # Gap of 400ms (> 300ms gap)
        Event.new("3", "t", %{v: 3}, timestamp: 600),
        Event.new("4", "t", %{v: 4}, timestamp: 700)
      ]

      sessions = Window.session(events, 300)
      assert length(sessions) == 2
      assert length(elem(Enum.at(sessions, 0), 1)) == 2
      assert length(elem(Enum.at(sessions, 1), 1)) == 2
    end

    test "aggregates window values" do
      events = [
        Event.new("1", "t", %{amount: 10}, timestamp: 100),
        Event.new("2", "t", %{amount: 25}, timestamp: 200)
      ]

      windows = Window.tumbling(events, 1000)

      aggregated =
        Window.aggregate(windows, fn event, acc -> acc + event.payload.amount end, 0)

      assert elem(hd(aggregated), 1) == 35
    end
  end

  describe "Complex Event Processing (Pattern Matching)" do
    test "matches temporal sequence A -> B -> C within timeout" do
      events = [
        Event.new("1", "auth", %{action: :login, user: "alice"}, timestamp: 1000),
        Event.new("2", "security", %{action: :ip_change, user: "alice"}, timestamp: 1500),
        Event.new("3", "finance", %{action: :large_transfer, user: "alice"}, timestamp: 2200),
        Event.new("4", "finance", %{action: :large_transfer, user: "bob"}, timestamp: 2500)
      ]

      # Fraud alert pattern: login -> ip_change -> large_transfer within 2000ms
      pattern =
        QueryCompiler.pattern(within_ms: 2000)
        |> Pattern.where(:login, fn e -> e.payload.action == :login end)
        |> Pattern.where(:ip_change, fn e -> e.payload.action == :ip_change end)
        |> Pattern.where(:transfer, fn e -> e.payload.action == :large_transfer end)

      matches = Pattern.match(pattern, events)
      assert length(matches) == 1

      match = hd(matches)
      assert match.login.id == "1"
      assert match.ip_change.id == "2"
      assert match.transfer.id == "3"
    end
  end

  describe "Streaming Pipeline" do
    test "processes events with demand-driven backpressure" do
      test_pid = self()
      {:ok, pipeline} = Pipeline.start_link(subscriber: test_pid)

      # Add filter (keep amount > 50) and map (double amount)
      :ok = Pipeline.filter(pipeline, fn e -> e.payload.amount > 50 end)

      :ok =
        Pipeline.map(pipeline, fn e ->
          %{e | payload: %{amount: e.payload.amount * 2}}
        end)

      # Push 3 events
      Pipeline.push(pipeline, Event.new("1", "t", %{amount: 20}))
      Pipeline.push(pipeline, Event.new("2", "t", %{amount: 60}))
      Pipeline.push(pipeline, Event.new("3", "t", %{amount: 80}))

      # Request demand 1
      Pipeline.request_demand(pipeline, 1)

      assert_receive {:stream_event, ev1}, 500
      assert ev1.id == "2"
      assert ev1.payload.amount == 120

      # Request demand 1 again
      Pipeline.request_demand(pipeline, 1)

      assert_receive {:stream_event, ev2}, 500
      assert ev2.id == "3"
      assert ev2.payload.amount == 160

      # No further demand, buffer should be empty
      refute_receive {:stream_event, _}, 100
    end
  end
end
