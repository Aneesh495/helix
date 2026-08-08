defmodule Helix.Client do
  @moduledoc """
  Official client driver for the Helix distributed transaction kernel.
  Provides connection management, binary wire framing, request pipelining,
  and client-side cryptographic state proof verification.
  """

  alias Helix.Net.Codec
  alias Helix.Core.MerkleProof

  defstruct [
    :socket,
    :host,
    :port,
    correlation_counter: 1
  ]

  @type t :: %__MODULE__{
          socket: :gen_tcp.socket(),
          host: binary(),
          port: non_neg_integer(),
          correlation_counter: pos_integer()
        }

  @doc """
  Connects to a Helix cluster node over TCP.
  """
  @spec connect(binary(), non_neg_integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(host \\ "127.0.0.1", port \\ 9000, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    charlist_host = if is_binary(host), do: String.to_charlist(host), else: host

    tcp_options = [
      :binary,
      packet: :raw,
      active: false,
      nodelay: true
    ]

    case :gen_tcp.connect(charlist_host, port, tcp_options, timeout) do
      {:ok, socket} ->
        {:ok,
         %__MODULE__{
           socket: socket,
           host: host,
           port: port,
           correlation_counter: 1
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a heartbeat ping to verify connection liveness.
  """
  @spec ping(t()) :: {:ok, map()} | {:error, term()}
  def ping(%__MODULE__{} = client) do
    send_request(client, :ping, nil)
  end

  @doc """
  Fetches the current value of a key.
  """
  @spec get(t(), binary()) :: {:ok, term()} | :not_found | {:error, term()}
  def get(%__MODULE__{} = client, key) when is_binary(key) do
    case send_request(client, :get_key, %{key: key}) do
      {:ok, %{found: true, value: val}} -> {:ok, val}
      {:ok, %{found: false}} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Proposes a transactional command to the cluster.
  """
  @spec propose(t(), map()) :: {:ok, map()} | {:error, term()}
  def propose(%__MODULE__{} = client, command) do
    send_request(client, :propose_tx, command)
  end

  @doc """
  Fetches a cryptographic Sparse Merkle Tree proof for a key and verifies it against expected root hash.
  """
  @spec get_verified_proof(t(), binary(), binary()) ::
          {:ok, MerkleProof.t()} | {:error, :invalid_proof | term()}
  def get_verified_proof(%__MODULE__{} = client, key, expected_root_hash) do
    case send_request(client, :get_smt_proof, %{key: key}) do
      {:ok, %MerkleProof{} = proof} ->
        case MerkleProof.verify(proof, expected_root_hash) do
          {:ok, _root} -> {:ok, proof}
          {:error, _reason} -> {:error, :invalid_proof}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Closes the client TCP connection.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket}) do
    :gen_tcp.close(socket)
  end

  defp send_request(%__MODULE__{socket: socket} = client, op, payload) do
    corr_id = client.correlation_counter
    frame = Codec.encode(op, corr_id, payload)

    case :gen_tcp.send(socket, frame) do
      :ok ->
        recv_response(socket, <<>>)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_response(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, chunk} ->
        full_buffer = buffer <> chunk

        case Codec.decode(full_buffer) do
          {:ok, _op, _corr_id, payload, _remaining} ->
            {:ok, payload}

          {:error, :incomplete} ->
            recv_response(socket, full_buffer)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
