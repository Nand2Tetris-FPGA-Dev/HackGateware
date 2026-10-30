"""Serial link frames: COBS(type, payload..., crc8) then 0x00.

CRC-8/SMBUS (poly 0x07, init 0, no reflection, no final xor) over type and
payload. Reference for the testbenches and for the PC side's test vectors.
"""

import struct

STATUS_FIELDS = (
    "boot_state", "pc", "instr", "a", "d", "sp", "sp_max", "heap_hi", "keyboard", "prog_words",
)
STATUS_LEN = 37


def crc8(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def cobs_encode(data: bytes) -> bytes:
    out = bytearray()
    block = bytearray()
    full_block_last = False     # data ended on a 0xFF block: no final block follows
    for byte in data:
        full_block_last = False
        if byte == 0:
            out += bytes([len(block) + 1]) + block
            block.clear()
        else:
            block.append(byte)
            if len(block) == 254:
                out += b"\xff" + block
                block.clear()
                full_block_last = True
    if not full_block_last:
        out += bytes([len(block) + 1]) + block
    return bytes(out)


def cobs_decode(data: bytes) -> bytes:
    if not data:
        raise ValueError("empty COBS block")
    out = bytearray()
    i = 0
    while i < len(data):
        code = data[i]
        if code == 0 or i + code > len(data):
            raise ValueError(f"bad COBS code {code} at {i}")
        block = data[i + 1:i + code]
        if 0 in block:
            raise ValueError(f"zero inside COBS block at {i}")
        out += block
        i += code
        if code != 0xFF and i < len(data):
            out.append(0)
    return bytes(out)


def encode_frame(ptype: int, payload: bytes = b"") -> bytes:
    body = bytes([ptype]) + payload
    return cobs_encode(body + bytes([crc8(body)])) + b"\x00"


def decode_frames(stream: bytes) -> list[tuple[int, bytes]]:
    """Good frames only, in order. Bytes after the last 0x00 are not a frame yet."""
    frames = []
    for chunk in stream.split(b"\x00")[:-1]:
        if not chunk:
            continue
        try:
            body = cobs_decode(chunk)
        except ValueError:
            continue
        if len(body) >= 2 and crc8(body) == 0:
            frames.append((body[0], body[1:-1]))
    return frames


def parse_status(payload: bytes) -> dict[str, int | bytes]:
    if len(payload) < STATUS_LEN:
        raise ValueError(f"status payload is {len(payload)} bytes, need {STATUS_LEN}")
    status: dict[str, int | bytes] = dict(zip(STATUS_FIELDS, struct.unpack_from("<B9H", payload)))
    status["prog_name"] = payload[19:35]
    status["bad_frames"] = struct.unpack_from("<H", payload, 35)[0]
    return status
