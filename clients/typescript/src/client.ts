import * as net from "net";

export const MAGIC = Buffer.from([0x48, 0x4C, 0x58, 0x31]); // "HLX1"
export const VERSION = 1;
export const HEADER_LEN = 23;

export enum Opcode {
  Ping = 0x0001,
  Pong = 0x0002,
  ProposeTx = 0x0010,
  TxCommitted = 0x0011,
  TxAborted = 0x0012,
  GetKey = 0x0020,
  KeyValue = 0x0021,
  GetSmtProof = 0x0030,
  SmtProofResponse = 0x0031,
  Error = 0x00FF
}

// Castagnoli CRC-32C Table
const CRC32C_POLYNOMIAL = 0x82F63B78;
const crcTable = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let crc = i;
  for (let j = 0; j < 8; j++) {
    if (crc & 1) {
      crc = (crc >>> 1) ^ CRC32C_POLYNOMIAL;
    } else {
      crc >>>= 1;
    }
  }
  crcTable[i] = crc >>> 0;
}

export function crc32c(data: Buffer): number {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < data.length; i++) {
    const tableIdx = (crc ^ data[i]) & 0xFF;
    crc = (crc >>> 8) ^ crcTable[tableIdx];
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

export class HelixClient {
  private socket: net.Socket | null = null;
  private corrId = 1;

  constructor(
    public readonly host: string = "127.0.0.1",
    public readonly port: number = 9000,
    public readonly timeoutMs: number = 5000
  ) {}

  public async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.socket = new net.Socket();
      this.socket.setTimeout(this.timeoutMs);
      this.socket.setNoDelay(true);

      this.socket.connect(this.port, this.host, () => {
        resolve();
      });

      this.socket.on("error", (err) => {
        reject(err);
      });
    });
  }

  public close(): void {
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
  }

  public async ping(): Promise<boolean> {
    const res = await this.sendRequest(Opcode.Ping, Buffer.alloc(0));
    return res.opcode === Opcode.Pong;
  }

  private async sendRequest(opcode: Opcode, payload: Buffer): Promise<{ opcode: number; payload: Buffer }> {
    if (!this.socket) {
      throw new Error("Client is not connected");
    }

    const corr = BigInt(this.corrId++);
    const crc = crc32c(payload);

    // Frame: Magic(4) | Version(1) | Opcode(2) | CorrID(8) | PayloadLen(4) | CRC(4)
    const header = Buffer.alloc(HEADER_LEN);
    MAGIC.copy(header, 0);
    header.writeUInt8(VERSION, 4);
    header.writeUInt16BE(opcode, 5);
    header.writeBigUInt64BE(corr, 7);
    header.writeUInt32BE(payload.length, 15);
    header.writeUInt32BE(crc, 19);

    const frame = Buffer.concat([header, payload]);
    this.socket.write(frame);

    return this.readResponse();
  }

  private async readResponse(): Promise<{ opcode: number; payload: Buffer }> {
    return new Promise((resolve, reject) => {
      let buffer = Buffer.alloc(0);

      const onData = (chunk: Buffer) => {
        buffer = Buffer.concat([buffer, chunk]);
        if (buffer.length >= HEADER_LEN) {
          const respLen = buffer.readUInt32BE(15);
          const totalExpected = HEADER_LEN + respLen;

          if (buffer.length >= totalExpected) {
            this.socket?.off("data", onData);
            const opcode = buffer.readUInt16BE(5);
            const crcExpected = buffer.readUInt32BE(19);
            const respPayload = buffer.subarray(HEADER_LEN, totalExpected);

            if (crc32c(respPayload) !== crcExpected) {
              reject(new Error("Response CRC-32C mismatch"));
              return;
            }

            resolve({ opcode, payload: respPayload });
          }
        }
      };

      this.socket?.on("data", onData);
    });
  }
}
