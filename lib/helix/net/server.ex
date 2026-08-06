defmodule Helix.Net.Server do
  @moduledoc """
  Non-blocking TCP server for the Helix binary wire protocol.
  Accepts concurrent client connections, decodes wire frames, and routes requests
  to consensus and storage subsystems.
  """

  use GenServer

  alias Helix.Net.Codec
  alias Helix.Storage.MemoryEngine
  alias Helix.Core.SparseMerkleTree, as: SMT
  alias Helix.Core.MerkleProof

  defstruct [
    :listen_socket,
    :port,
    :replica,
    :storage,
    smt: nil
  ]

  @type t :: %__MODULE__{
          listen_socket: :gen_tcp.socket() | nil,
          port: non_neg_integer(),
          replica: pid() | atom() | nil,
          storage: atom() | nil,
          smt: SMT.t() | nil
        }

  # Client API

  @doc """
  Starts the TCP wire server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Returns the bound listening port.
  """
  def get_port(server) do
    GenServer.call(server, :get_port)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 0)
    replica = Keyword.get(opts, :replica, nil)
    storage = Keyword.get(opts, :storage, :helix_storage_memory)
    smt = Keyword.get(opts, :smt, SMT.new())

    tcp_options = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      nodelay: true,
      backlog: 128
    ]

    case :gen_tcp.listen(port, tcp_options) do
      {:ok, listen_socket} ->
        {:ok, bound_port} = :inet.port(listen_socket)

        state = %__MODULE__{
          listen_socket: listen_socket,
          port: bound_port,
          replica: replica,
          storage: storage,
          smt: smt
        }

        # Spawn background acceptor loop
        spawn_link(fn -> accept_loop(state) end)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.port, state}
  end

  defp accept_loop(%__MODULE__{listen_socket: socket} = state) do
    case :gen_tcp.accept(socket) do
      {:ok, client_socket} ->
        spawn(fn -> handle_connection(client_socket, state, <<>>) end)
        accept_loop(state)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(state)
    end
  end

  defp handle_connection(socket, state, buffer) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, chunk} ->
        full_buffer = buffer <> chunk
        process_buffer(socket, state, full_buffer)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        handle_connection(socket, state, buffer)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp process_buffer(socket, state, buffer) do
    case Codec.decode(buffer) do
      {:ok, op, corr_id, payload, remaining} ->
        response_frame = dispatch_command(op, corr_id, payload, state)
        :gen_tcp.send(socket, response_frame)
        process_buffer(socket, state, remaining)

      {:error, :incomplete} ->
        # Wait for more bytes
        handle_connection(socket, state, buffer)

      {:error, reason} ->
        # Protocol error, send error frame and close
        err_frame = Codec.encode(:error, 0, %{reason: reason})
        :gen_tcp.send(socket, err_frame)
        :gen_tcp.close(socket)
    end
  end

  defp dispatch_command(:ping, corr_id, _payload, _state) do
    Codec.encode(:pong, corr_id, %{status: :ok})
  end

  defp dispatch_command(:get_key, corr_id, %{key: key}, state) do
    case MemoryEngine.get(state.storage, key) do
      {:ok, val} -> Codec.encode(:key_value, corr_id, %{key: key, value: val, found: true})
      :not_found -> Codec.encode(:key_value, corr_id, %{key: key, value: nil, found: false})
    end
  end

  defp dispatch_command(:get_smt_proof, corr_id, %{key: key}, state) do
    tree = state.smt || SMT.new()
    proof = MerkleProof.generate(tree, key)
    Codec.encode(:smt_proof_response, corr_id, proof)
  end

  defp dispatch_command(:propose_tx, corr_id, command, state) do
    if state.replica do
      case Helix.Consensus.Replica.propose(state.replica, command) do
        {:ok, inst_id, :committed} ->
          Codec.encode(:tx_committed, corr_id, %{instance_id: inst_id})

        other ->
          Codec.encode(:tx_aborted, corr_id, %{reason: other})
      end
    else
      # Direct storage commit if replica not configured
      Enum.each(command.ops, fn
        {:write, k, v} -> MemoryEngine.put(state.storage, k, v)
        {:delete, k} -> MemoryEngine.delete(state.storage, k)
        _other -> :ok
      end)

      Codec.encode(:tx_committed, corr_id, %{instance_id: {"local", 1}})
    end
  end

  defp dispatch_command(unknown_op, corr_id, _payload, _state) do
    Codec.encode(:error, corr_id, %{error: :unsupported_opcode, op: unknown_op})
  end
end
