defmodule Helix.Net.Protocol do
  @moduledoc """
  Binary wire protocol definition and opcode enumerations for Helix network communications.
  Header specification: Magic (4B) | Version (1B) | Opcode (2B) | CorrelationID (8B) | PayloadLen (4B) | CRC32C (4B)
  """

  @magic <<0x48, 0x4C, 0x58, 0x31>>
  @version 1
  @header_len 23

  # Opcodes
  @op_ping 0x0001
  @op_pong 0x0002
  @op_propose_tx 0x0010
  @op_tx_committed 0x0011
  @op_tx_aborted 0x0012
  @op_get_key 0x0020
  @op_key_value 0x0021
  @op_get_smt_proof 0x0030
  @op_smt_proof_response 0x0031
  @op_crdt_delta 0x0040
  @op_crdt_delta_ack 0x0041
  @op_cluster_info 0x0050
  @op_cluster_topology 0x0051
  @op_error 0x00FF

  def magic, do: @magic
  def version, do: @version
  def header_length, do: @header_len

  def op(:ping), do: @op_ping
  def op(:pong), do: @op_pong
  def op(:propose_tx), do: @op_propose_tx
  def op(:tx_committed), do: @op_tx_committed
  def op(:tx_aborted), do: @op_tx_aborted
  def op(:get_key), do: @op_get_key
  def op(:key_value), do: @op_key_value
  def op(:get_smt_proof), do: @op_get_smt_proof
  def op(:smt_proof_response), do: @op_smt_proof_response
  def op(:crdt_delta), do: @op_crdt_delta
  def op(:crdt_delta_ack), do: @op_crdt_delta_ack
  def op(:cluster_info), do: @op_cluster_info
  def op(:cluster_topology), do: @op_cluster_topology
  def op(:error), do: @op_error

  def op_name(@op_ping), do: :ping
  def op_name(@op_pong), do: :pong
  def op_name(@op_propose_tx), do: :propose_tx
  def op_name(@op_tx_committed), do: :tx_committed
  def op_name(@op_tx_aborted), do: :tx_aborted
  def op_name(@op_get_key), do: :get_key
  def op_name(@op_key_value), do: :key_value
  def op_name(@op_get_smt_proof), do: :get_smt_proof
  def op_name(@op_smt_proof_response), do: :smt_proof_response
  def op_name(@op_crdt_delta), do: :crdt_delta
  def op_name(@op_crdt_delta_ack), do: :crdt_delta_ack
  def op_name(@op_cluster_info), do: :cluster_info
  def op_name(@op_cluster_topology), do: :cluster_topology
  def op_name(@op_error), do: :error
  def op_name(_other), do: :unknown
end
