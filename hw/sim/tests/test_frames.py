import random
from pathlib import Path

import pytest

from serial_frames import cobs_encode, crc8, decode_frames, encode_frame
from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
SOURCES = [HW / "sim/tb/tb_frames.v", HW / "rtl/io/frame_rx.v", HW / "rtl/io/frame_tx.v"]
PINNED = [
    "04 01 41 D5 00",
    "02 01 02 15 00",
    "03 03 09 00",
    "02 02 03 01 02 02 85 00",
    "02 82 03 01 02 02 12 00",
]

pytestmark = pytest.mark.requires_iverilog


def run_rx(tmp_path, items, **plusargs):
    """items: bytes, ints or "ERR". Returns OK packets as bytes and BAD as None, in order."""
    lines = []
    for item in items:
        if isinstance(item, (bytes, bytearray)):
            lines += [f"{b:02x}" for b in item]
        elif isinstance(item, int):
            lines.append(f"{item:02x}")
        else:
            lines.append(item)
    (tmp_path / "in.hex").write_text("".join(f"{line}\n" for line in lines))
    out = iverilog(SOURCES, "tb_frames", plusargs={k: str(v) for k, v in plusargs.items()},
                   cwd=tmp_path).splitlines()
    assert "DONE" in out, out
    results = []
    for line in out:
        if line == "BAD":
            results.append(None)
        elif line.startswith("OK "):
            n, *data = line.split()[1:]
            assert int(n) == len(data)
            results.append(bytes(int(d, 16) for d in data))
    return results


def packet(ptype, payload=b""):
    return bytes([ptype]) + payload


def random_packets(rng, count):
    return [packet(rng.randrange(256), rng.randbytes(rng.randrange(17))) for _ in range(count)]


def test_rx_pinned_vectors(tmp_path):
    stream = b"".join(bytes.fromhex(v) for v in PINNED)
    expected = [packet(t, p) for t, p in decode_frames(stream)]
    assert len(expected) == len(PINNED)
    assert run_rx(tmp_path, [stream]) == expected


def test_rx_random_frames(tmp_path):
    packets = random_packets(random.Random(3), 50)
    stream = b"".join(encode_frame(p[0], p[1:]) for p in packets)
    assert run_rx(tmp_path, [stream], GAP=0) == packets


def test_rx_bad_crc(tmp_path):
    bad = bytearray(encode_frame(0x01, b"\x41"))
    bad[2] ^= 0x01
    assert run_rx(tmp_path, [bytes(bad), encode_frame(0x03)]) == [None, b"\x03"]


def test_rx_truncated(tmp_path):
    half = encode_frame(0x02, b"\x10\x20\x30")[:3]
    assert run_rx(tmp_path, [half, 0x00, encode_frame(0x03)]) == [None, b"\x03"]
    cut = bytes.fromhex("05 03 09 00")     # block claims 4 bytes; the 2 that came have a good crc
    assert decode_frames(cut) == []
    assert run_rx(tmp_path, [cut, encode_frame(0x03)]) == [None, b"\x03"]


def test_rx_overflow(tmp_path):
    big = encode_frame(0x02, bytes(range(1, 71)))   # good CRC and COBS, 72 bytes decoded
    junk = bytes([0x41] * 100) + b"\x00"
    ok = encode_frame(0x01, b"\x41")
    assert run_rx(tmp_path, [big, ok, junk, ok]) == [None, b"\x01\x41", None, b"\x01\x41"]


def test_rx_max_len(tmp_path):
    body = packet(0x02, bytes(range(1, 63)))         # 63 bytes + crc = 64
    assert run_rx(tmp_path, [encode_frame(body[0], body[1:])]) == [body]


def test_rx_uart_error(tmp_path):
    frame = encode_frame(0x01, b"\x41")
    ok = encode_frame(0x03)
    assert run_rx(tmp_path, [frame[:2], "ERR", frame[2:], ok]) == [None, b"\x03"]
    assert run_rx(tmp_path, [ok, "ERR", 0x00, ok]) == [b"\x03", None, b"\x03"]


def test_rx_empty_frames(tmp_path):
    assert run_rx(tmp_path, [b"\x00\x00\x00", encode_frame(0x03)]) == [b"\x03"]


def test_rx_one_byte(tmp_path):
    assert run_rx(tmp_path, [cobs_encode(b"\x00"), 0x00, encode_frame(0x03)]) == [None, b"\x03"]


def test_rx_buffer_held(tmp_path):
    packets = random_packets(random.Random(4), 10)
    stream = b"".join(encode_frame(p[0], p[1:]) for p in packets) + b"\x05"
    assert run_rx(tmp_path, [stream], LATE=1) == packets


def test_tx_matches_reference(tmp_path):
    rng = random.Random(5)
    packets = random_packets(rng, 30)
    packets += [
        packet(0x83, rng.randbytes(37)),
        packet(0x83, bytes(37)),
        packet(0x82, b"\x00\x01\x02\x00"),
        packet(0x00),
        packet(0x01, b"\x00"),
        packet(0x02, bytes(range(1, 63))),
    ]
    packets.append(next(p for p in (packet(1, bytes([b])) for b in range(256)) if crc8(p) == 0))
    (tmp_path / "src.hex").write_text(
        "".join(f"{len(p):x} {' '.join(f'{b:02x}' for b in p)}\n" for p in packets))
    out = iverilog(SOURCES, "tb_frames", plusargs={"TX": "1"}, cwd=tmp_path).splitlines()
    assert "DONE" in out, out
    sent = bytes(int(line.split()[1], 16) for line in out if line.startswith("TX "))
    assert sent == b"".join(encode_frame(p[0], p[1:]) for p in packets)
