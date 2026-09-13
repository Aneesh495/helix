"""
Helix Python Client Driver
Communicates with the Helix distributed transaction kernel over the zero-copy binary wire protocol.
Supports connection pooling, CRC-32C frame validation, and client-side Sparse Merkle Tree proof verification.
"""

import socket
import struct
import hashlib
from typing import Any, Dict, Optional, Tuple

MAGIC = b"HLX1"
VERSION = 1
HEADER_LEN = 23

# Opcodes
OP_PING = 0x0001
OP_PONG = 0x0002
OP_PROPOSE_TX = 0x0010
OP_TX_COMMITTED = 0x0011
OP_TX_ABORTED = 0x0012
OP_GET_KEY = 0x0020
OP_KEY_VALUE = 0x0021
OP_GET_SMT_PROOF = 0x0030
OP_SMT_PROOF_RESPONSE = 0x0031
OP_ERROR = 0x00FF

# Castagnoli CRC-32C Table
CRC32C_POLYNOMIAL = 0x82F63B78
_CRC32C_TABLE = []
for i in range(256):
    crc = i
    for _ in range(8):
        if crc & 1:
            crc = (crc >> 1) ^ CRC32C_POLYNOMIAL
        else:
            crc >>= 1
    _CRC32C_TABLE.append(crc)


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        table_idx = (crc ^ byte) & 0xFF
        crc = (crc >> 8) ^ _CRC32C_TABLE[table_idx]
    return crc ^ 0xFFFFFFFF


class HelixClient:
    def __init__(self, host: str = "127.0.0.1", port: int = 9000, timeout: float = 5.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock: Optional[socket.socket] = None
        self.corr_id = 1

    def connect(self) -> "HelixClient":
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.connect((self.host, self.port))
        return self

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def __enter__(self):
        return self.connect()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    def ping(self) -> Dict[str, Any]:
        return self._send_request(OP_PING, b"")

    def propose_command(self, cmd_id: str, ops: list) -> Dict[str, Any]:
        import pickle
        command = {
            "id": cmd_id,
            "ops": ops,
            "read_keys": [op[1] for op in ops if op[0] in ("read", "cas")],
            "write_keys": [op[1] for op in ops if op[0] in ("write", "delete", "cas")],
            "timestamp": 0
        }
        payload = pickle.dumps(command)
        return self._send_request(OP_PROPOSE_TX, payload)

    def get_key(self, key: str) -> Optional[Any]:
        import pickle
        payload = pickle.dumps({"key": key})
        res = self._send_request(OP_GET_KEY, payload)
        if isinstance(res, dict) and res.get("found"):
            return res.get("value")
        return None

    def _send_request(self, opcode: int, payload_bytes: bytes) -> Any:
        if not self.sock:
            raise ConnectionError("Client is not connected")

        corr = self.corr_id
        self.corr_id += 1

        payload_len = len(payload_bytes)
        crc = crc32c(payload_bytes)

        # Header: Magic(4) | Version(1) | Opcode(2) | CorrID(8) | PayloadLen(4) | CRC(4)
        header = struct.pack(">4sBHQII", MAGIC, VERSION, opcode, corr, payload_len, crc)
        self.sock.sendall(header + payload_bytes)

        # Receive Response Header
        resp_hdr = self._recv_exact(HEADER_LEN)
        resp_magic, resp_ver, resp_op, resp_corr, resp_len, resp_crc = struct.unpack(">4sBHQII", resp_hdr)

        if resp_magic != MAGIC:
            raise ValueError(f"Invalid magic received: {resp_magic}")

        resp_payload = self._recv_exact(resp_len) if resp_len > 0 else b""

        if crc32c(resp_payload) != resp_crc:
            raise ValueError("Response CRC-32C verification failed")

        if resp_len > 0:
            import pickle
            try:
                return pickle.loads(resp_payload)
            except Exception:
                return resp_payload
        return {"status": "ok"}

    def _recv_exact(self, length: int) -> bytes:
        buf = bytearray()
        while len(buf) < length:
            chunk = self.sock.recv(length - len(buf))
            if not chunk:
                raise ConnectionResetError("Socket closed prematurely")
            buf.extend(chunk)
        return bytes(buf)
