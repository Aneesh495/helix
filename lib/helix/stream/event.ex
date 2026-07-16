defmodule Helix.Stream.Event do
  @moduledoc """
  Typed temporal event representation with event timestamps and watermarks.
  """

  defstruct [
    :id,
    :topic,
    :payload,
    timestamp: 0,
    watermark: 0
  ]

  @type t :: %__MODULE__{
          id: binary(),
          topic: binary(),
          payload: term(),
          timestamp: non_neg_integer(),
          watermark: non_neg_integer()
        }

  @doc """
  Constructs a new event with timestamp and watermark.
  """
  @spec new(binary(), binary(), term(), keyword()) :: t()
  def new(id, topic, payload, opts \\ []) do
    ts = Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    wm = Keyword.get(opts, :watermark, ts)

    %__MODULE__{
      id: id,
      topic: topic,
      payload: payload,
      timestamp: ts,
      watermark: wm
    }
  end
end
