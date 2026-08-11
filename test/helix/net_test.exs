defmodule Helix.NetTest do
  use ExUnit.Case, async: false

  alias Helix.Core.Types
  alias Helix.Core.SparseMerkleTree, as: SMT
  alias Helix.Net.Codec
  alias Helix.Net.Server
  alias Helix.Client

  describe "Protocol & Codec" do
    test "encodes and decodes binary wire frames with CRC verification" do
      payload = %{key: "order:100", amount: 500}
      encoded = Codec.encode(:propose_tx, 42, payload)

      assert {:ok, :propose_tx, 42, decoded_payload, <<>>} = Codec.decode(encoded)
      assert decoded_payload == payload
    end

    test "detects frame corruption and partial streams" do
      encoded = Codec.encode(:ping, 1, nil)
      <<header::binary-size(10), _rest::binary>> = encoded

      # Partial header
      assert {:error, :incomplete} = Codec.decode(header)

      # Tamper with payload byte
      tampered = encoded <> "corrupted"
      assert {:ok, :ping, 1, nil, "corrupted"} = Codec.decode(tampered)
    end
  end

  describe "Server and Client SDK End-to-End" do
    test "connects, pings, proposes transactions, and verifies SMT state proofs" do
      # Prepare initial SMT with sample key
      smt = SMT.new() |> SMT.put("verified_key", "crypto_secure_value")
      expected_root = SMT.root_hash(smt)

      {:ok, server} = Server.start_link(port: 0, smt: smt)
      port = Server.get_port(server)

      # Connect client
      {:ok, client} = Client.connect("127.0.0.1", port)

      # Ping
      assert {:ok, %{status: :ok}} = Client.ping(client)

      # Propose transaction
      cmd = Types.make_command("tx_net", [{:write, "verified_key", "crypto_secure_value"}])
      assert {:ok, %{instance_id: _}} = Client.propose(client, cmd)

      # Get key
      assert {:ok, "crypto_secure_value"} = Client.get(client, "verified_key")

      # Fetch and verify cryptographic proof
      assert {:ok, proof} = Client.get_verified_proof(client, "verified_key", expected_root)
      assert proof.key == "verified_key"
      assert proof.non_membership == false

      # Clean shutdown
      Client.close(client)
    end
  end
end
