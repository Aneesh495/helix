defmodule Helix.Stream.Pipeline do
  @moduledoc """
  Reactive backpressured streaming pipeline actor.
  Enforces demand-driven flow control, dynamic transformations, and buffered windowing.
  """

  use GenServer

  alias Helix.Stream.Event

  defstruct [
    :subscriber,
    buffer: [],
    demand: 0,
    max_buffer_size: 10_000,
    filters: [],
    mappers: []
  ]

  @type t :: %__MODULE__{
          subscriber: pid() | nil,
          buffer: [Event.t()],
          demand: non_neg_integer(),
          max_buffer_size: pos_integer(),
          filters: [(Event.t() -> boolean())],
          mappers: [(Event.t() -> Event.t())]
        }

  # Client API

  @doc """
  Starts a streaming pipeline GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Pushes an event into the pipeline.
  """
  def push(pipeline, %Event{} = event) do
    GenServer.cast(pipeline, {:push, event})
  end

  @doc """
  Subscribes a consumer process to receive processed stream events.
  """
  def subscribe(pipeline, subscriber_pid) do
    GenServer.call(pipeline, {:subscribe, subscriber_pid})
  end

  @doc """
  Signals demand for N events from downstream consumer.
  """
  def request_demand(pipeline, n) when is_integer(n) and n > 0 do
    GenServer.cast(pipeline, {:request_demand, n})
  end

  @doc """
  Adds a filter stage to the pipeline.
  """
  def filter(pipeline, predicate) when is_function(predicate, 1) do
    GenServer.call(pipeline, {:add_filter, predicate})
  end

  @doc """
  Adds a map transformation stage to the pipeline.
  """
  def map(pipeline, mapper) when is_function(mapper, 1) do
    GenServer.call(pipeline, {:add_mapper, mapper})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    subscriber = Keyword.get(opts, :subscriber)
    max_buf = Keyword.get(opts, :max_buffer_size, 10_000)

    state = %__MODULE__{
      subscriber: subscriber,
      buffer: [],
      demand: 0,
      max_buffer_size: max_buf,
      filters: [],
      mappers: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid}}
  end

  @impl true
  def handle_call({:add_filter, pred}, _from, state) do
    {:reply, :ok, %{state | filters: state.filters ++ [pred]}}
  end

  @impl true
  def handle_call({:add_mapper, mapper}, _from, state) do
    {:reply, :ok, %{state | mappers: state.mappers ++ [mapper]}}
  end

  @impl true
  def handle_cast({:push, %Event{} = event}, state) do
    # Pass through filters
    passed = Enum.all?(state.filters, fn f -> f.(event) end)

    if passed do
      # Pass through mappers
      transformed = Enum.reduce(state.mappers, event, fn m, e -> m.(e) end)
      new_buffer = state.buffer ++ [transformed]

      # Enforce buffer capacity limit
      bounded_buffer =
        if length(new_buffer) > state.max_buffer_size do
          Enum.drop(new_buffer, length(new_buffer) - state.max_buffer_size)
        else
          new_buffer
        end

      new_state = dispatch_demand(%{state | buffer: bounded_buffer})
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:request_demand, n}, state) do
    new_state = %{state | demand: state.demand + n}
    final_state = dispatch_demand(new_state)
    {:noreply, final_state}
  end

  defp dispatch_demand(%{demand: 0} = state), do: state
  defp dispatch_demand(%{buffer: []} = state), do: state
  defp dispatch_demand(%{subscriber: nil} = state), do: state

  defp dispatch_demand(state) do
    to_emit_count = min(state.demand, length(state.buffer))
    {emitted, remaining_buffer} = Enum.split(state.buffer, to_emit_count)

    Enum.each(emitted, fn ev ->
      send(state.subscriber, {:stream_event, ev})
    end)

    %{state | buffer: remaining_buffer, demand: state.demand - to_emit_count}
  end
end
