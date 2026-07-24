defmodule Helix.Stream.QueryCompiler do
  @moduledoc """
  Compile-time DSL and query builder for declarative CEP patterns and stream transformations.
  """

  alias Helix.Stream.Event
  alias Helix.Stream.Window
  alias Helix.Stream.Pattern

  @doc """
  Compiles a declarative pattern matching definition into a reusable Pattern struct.
  """
  @spec pattern(keyword()) :: Pattern.t()
  def pattern(opts \\ []) do
    Pattern.new(opts)
  end

  @doc """
  Builds a windowing aggregator transformation.
  """
  @spec window_aggregation(:tumbling | :sliding | :session, pos_integer(), keyword()) ::
          ([Event.t()] -> list())
  def window_aggregation(:tumbling, size_ms, _opts) do
    fn events -> Window.tumbling(events, size_ms) end
  end

  def window_aggregation(:sliding, size_ms, opts) do
    slide_ms = Keyword.get(opts, :slide_ms, div(size_ms, 2))
    fn events -> Window.sliding(events, size_ms, slide_ms) end
  end

  def window_aggregation(:session, gap_ms, _opts) do
    fn events -> Window.session(events, gap_ms) end
  end
end
