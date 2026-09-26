defmodule Helix.Cluster.Gossip do
  @moduledoc """
  Epidemic gossip dissemination buffer with bounded retransmissions.
  Disseminates membership events and state digests across the cluster mesh in O(log N) periods.
  """

  defstruct events: %{},
            max_retransmissions: 5

  @type event_type :: :alive | :suspect | :dead | :crdt_delta
  @type event_item :: {event_type(), binary(), non_neg_integer(), term()}

  @type t :: %__MODULE__{
          events: %{binary() => {event_item(), non_neg_integer()}},
          max_retransmissions: pos_integer()
        }

  @doc """
  Initializes an empty gossip buffer.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_tx = Keyword.get(opts, :max_retransmissions, 5)
    %__MODULE__{events: %{}, max_retransmissions: max_tx}
  end

  @doc """
  Enqueues an event to be piggybacked on upcoming messages.
  """
  @spec add_event(t(), binary(), event_item()) :: t()
  def add_event(%__MODULE__{} = buffer, event_id, item) do
    new_events = Map.put(buffer.events, event_id, {item, 0})
    %{buffer | events: new_events}
  end

  @doc """
  Selects up to `count` events to piggyback on an outgoing message,
  incrementing their transmission counts and evicting expired events.
  """
  @spec select_and_advance(t(), pos_integer()) :: {[event_item()], t()}
  def select_and_advance(%__MODULE__{} = buffer, count \\ 3) do
    candidates = Enum.take(buffer.events, count)

    selected_items = Enum.map(candidates, fn {_id, {item, _c}} -> item end)

    new_events =
      Enum.reduce(candidates, buffer.events, fn {id, {item, c}}, acc ->
        new_count = c + 1

        if new_count >= buffer.max_retransmissions do
          Map.delete(acc, id)
        else
          Map.put(acc, id, {item, new_count})
        end
      end)

    {selected_items, %{buffer | events: new_events}}
  end

  @doc """
  Returns the count of active gossip events pending in the buffer.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{events: evs}), do: map_size(evs)
end
