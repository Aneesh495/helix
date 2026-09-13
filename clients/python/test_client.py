"""
Unit and integration tests for the Helix Python client.
"""

import unittest
from helix_client import crc32c, MAGIC, VERSION, OP_PING


class TestHelixClient(unittest.TestCase):
    def test_crc32c_castagnoli(self):
        # Known standard test vectors for CRC-32C
        self.assertEqual(crc32c(b"123456789"), 0xE3069283)
        self.assertEqual(crc32c(b""), 0x00000000)
        self.assertIsInstance(crc32c(b"helix-distributed-kernel"), int)

    def test_protocol_constants(self):
        self.assertEqual(MAGIC, b"HLX1")
        self.assertEqual(VERSION, 1)
        self.assertEqual(OP_PING, 0x0001)


if __name__ == "__main__":
    unittest.main()
