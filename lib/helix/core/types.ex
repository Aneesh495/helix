defmodule Helix.Core.Types do
  @moduledoc """
  Fundamental types and domain records for the Helix distributed kernel.
  """

  @type replica_id :: non_neg_integer() | binary()
  @type instance_seq :: non_neg_integer()
  @type instance_id :: {replica_id(), instance_seq()}

  @type ballot :: {epoch :: non_neg_integer(), num :: non_neg_integer(), replica_id :: replica_id()}

  @type key :: binary()
  @type value :: binary() | term()

  @type command_op ::
          {:read, key()}
          | {:write, key(), value()}
          | {:delete, key()}
          | {:cas, key(), expected :: value(), new :: value()}
          | {:noop}

  @type command :: %{
          id: binary(),
          ops: [command_op()],
          read_keys: [key()],
          write_keys: [key()],
          timestamp: non_neg_integer()
        }

  @type instance_status :: :preaccepted | :accepted | :committed | :executed

  @type deps :: MapSet.t(instance_id())

  @type instance :: %{
          id: instance_id(),
          command: command() | nil,
          seq: non_neg_integer(),
          deps: deps(),
          status: instance_status(),
          ballot: ballot(),
          leader: replica_id(),
          preaccept_votes: MapSet.t(replica_id()),
          accept_votes: MapSet.t(replica_id())
        }

  @type hlc_timestamp :: %{
          physical: non_neg_integer(),
          logical: non_neg_integer(),
          node_id: replica_id()
        }

  @doc """
  Constructs a standard command record from a list of operations.
  Extracts read and write keys automatically for dependency conflict detection.
  """
  @spec make_command(binary(), [command_op()]) :: command()
  def make_command(id, ops) when is_binary(id) and is_list(ops) do
    {reads, writes} =
      Enum.reduce(ops, {MapSet.new(), MapSet.new()}, fn op, {r, w} ->
        case op do
          {:read, key} -> {MapSet.put(r, key), w}
          {:write, key, _val} -> {r, MapSet.put(w, key)}
          {:delete, key} -> {r, MapSet.put(w, key)}
          {:cas, key, _expected, _new} -> {MapSet.put(r, key), MapSet.put(w, key)}
          {:noop} -> {r, w}
        end
      end)

    %{
      id: id,
      ops: ops,
      read_keys: MapSet.to_list(reads),
      write_keys: MapSet.to_list(writes),
      timestamp: System.system_time(:microsecond)
    }
  end

  @doc """
  Checks if two commands conflict. Two commands conflict if their key sets
  intersect and at least one command contains a write on that key.
  """
  @spec conflicts?(command(), command()) :: boolean()
  def conflicts?(cmd1, cmd2) do
    w1 = MapSet.new(cmd1.write_keys)
    w2 = MapSet.new(cmd2.write_keys)
    r1 = MapSet.new(cmd1.read_keys)
    r2 = MapSet.new(cmd2.read_keys)

    # Conflict if W1 intersects (W2 union R2) or W2 intersects R1
    all_keys2 = MapSet.union(w2, r2)
    has_w1_conflict = not MapSet.disjoint?(w1, all_keys2)
    has_w2_conflict = not MapSet.disjoint?(w2, r1)

    has_w1_conflict or has_w2_conflict
  end
end
