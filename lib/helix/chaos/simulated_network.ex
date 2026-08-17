defmodule Helix.Chaos.SimulatedNetwork do
  @moduledoc """
  Adversarial network simulation mesh for injecting partitions, packet loss,
  jitter delay, and duplicate message delivery.
  """

  defstruct [
    partitions: MapSet.new(),
    drop_rate: 0.0,
    duplicate_rate: 0.0,
    min_delay_ticks: 0,
    max_delay_ticks: 0,
    seed: 42
  ]

  @type node_id :: term()
  @type t :: %__MODULE__{
          partitions: MapSet.t({node_id(), node_id()}),
          drop_rate: float(),
          duplicate_rate: float(),
          min_delay_ticks: non_neg_integer(),
          max_delay_ticks: non_neg_integer(),
          seed: integer()
        }

  @doc """
  Initializes a simulated network with chaos parameters.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      partitions: MapSet.new(),
      drop_rate: Keyword.get(opts, :drop_rate, 0.0),
      duplicate_rate: Keyword.get(opts, :duplicate_rate, 0.0),
      min_delay_ticks: Keyword.get(opts, :min_delay_ticks, 0),
      max_delay_ticks: Keyword.get(opts, :max_delay_ticks, 0),
      seed: Keyword.get(opts, :seed, 42)
    }
  end

  @doc """
  Partitions the network into two mutually disconnected groups of nodes.
  """
  @spec partition(t(), [node_id()], [node_id()]) :: t()
  def partition(%__MODULE__{} = net, group_a, group_b) do
    cuts =
      for a <- group_a, b <- group_b do
        [{a, b}, {b, a}]
      end
      |> List.flatten()
      |> MapSet.new()

    %{net | partitions: MapSet.union(net.partitions, cuts)}
  end

  @doc """
  Creates an asymmetric network cut from source nodes to target nodes.
  """
  @spec asymmetric_cut(t(), [node_id()], [node_id()]) :: t()
  def asymmetric_cut(%__MODULE__{} = net, sources, targets) do
    cuts =
      for s <- sources, t <- targets do
        {s, t}
      end
      |> MapSet.new()

    %{net | partitions: MapSet.union(net.partitions, cuts)}
  end

  @doc """
  Heals all network partitions.
  """
  @spec heal(t()) :: t()
  def heal(%__MODULE__{} = net) do
    %{net | partitions: MapSet.new()}
  end

  @doc """
  Determines whether a message from `from_node` to `to_node` can traverse the network.
  Returns {:deliver, delay_ticks, duplicate?} or :dropped.
  """
  @spec route_packet(t(), node_id(), node_id(), float()) ::
          {:deliver, non_neg_integer(), boolean()} | :dropped
  def route_packet(%__MODULE__{} = net, from_node, to_node, rand_val \\ nil) do
    r = rand_val || :rand.uniform()

    if MapSet.member?(net.partitions, {from_node, to_node}) do
      :dropped
    else
      if r < net.drop_rate do
        :dropped
      else
        dup? = :rand.uniform() < net.duplicate_rate
        delay =
          if net.max_delay_ticks > net.min_delay_ticks do
            net.min_delay_ticks + :rand.uniform(net.max_delay_ticks - net.min_delay_ticks)
          else
            net.min_delay_ticks
          end

        {:deliver, delay, dup?}
      end
    end
  end
end
