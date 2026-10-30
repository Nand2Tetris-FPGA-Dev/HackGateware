import random
import struct

import pytest

from serial_frames import (
    cobs_decode,
    cobs_encode,
    crc8,
    decode_frames,
    encode_frame,
    parse_status,
)

PINNED = [
    ((0x01, b"\x41"), "04 01 41 D5 00"),
    ((0x01, b"\x00"), "02 01 02 15 00"),
    ((0x03, b""), "03 03 09 00"),
    ((0x02, b"\x00\x01\x02\x00"), "02 02 03 01 02 02 85 00"),
    ((0x82, b"\x00\x01\x02\x00"), "02 82 03 01 02 02 12 00"),
]


def test_crc8_check_value():
    assert crc8(b"123456789") == 0xF4
    assert crc8(b"") == 0


@pytest.mark.parametrize("packet, wire", PINNED)
def test_pinned_vectors(packet, wire):
    assert encode_frame(*packet) == bytes.fromhex(wire)
    assert decode_frames(bytes.fromhex(wire)) == [packet]


def test_cobs_known():
    assert cobs_encode(b"") == b"\x01"
    assert cobs_encode(b"\x00") == b"\x01\x01"
    assert cobs_encode(b"\x11\x22\x00\x33") == b"\x03\x11\x22\x02\x33"
    assert cobs_encode(bytes(range(1, 255))) == b"\xff" + bytes(range(1, 255))
    assert cobs_decode(b"\xff" + bytes(range(1, 255)) + b"\x01") == bytes(range(1, 255))


def test_cobs_round_trip():
    rng = random.Random(2)
    for _ in range(500):
        data = bytes(rng.choice([0, rng.randrange(256)]) for _ in range(rng.randrange(65)))
        enc = cobs_encode(data)
        assert 0 not in enc
        assert cobs_decode(enc) == data
    for n in (253, 254, 255, 509):
        data = bytes(i % 255 + 1 for i in range(n))
        assert cobs_decode(cobs_encode(data)) == data
        assert cobs_decode(cobs_encode(b"\x00" + data)) == b"\x00" + data


@pytest.mark.parametrize("bad", [b"", b"\x00", b"\x03\x11", b"\x02\x11\x00"])
def test_cobs_decode_malformed(bad):
    with pytest.raises(ValueError):
        cobs_decode(bad)


def test_decode_frames_resyncs():
    first = bytearray(encode_frame(0x01, b"\x41"))
    first[2] ^= 0x01
    stream = b"\x00\x00" + bytes(first) + encode_frame(0x03) + encode_frame(0x02, b"\x05")
    assert decode_frames(stream) == [(0x03, b""), (0x02, b"\x05")]


def test_decode_frames_drops_short_and_unfinished():
    one_byte = cobs_encode(b"\x00") + b"\x00"   # crc only, no type
    unfinished = encode_frame(0x01, b"\x41")[:-1]
    assert decode_frames(one_byte + encode_frame(0x03) + unfinished) == [(0x03, b"")]


def status_payload():
    name = b"MathDemo".ljust(16, b"\x00")
    head = struct.pack("<BHHHHHHHHH", 2, 0x1234, 0xEC10, 0xFFFF, 7, 261, 300, 2100, 65, 512)
    return head + name + struct.pack("<H", 65535)


def test_parse_status():
    payload = status_payload()
    assert len(payload) == 37
    expected = {
        "boot_state": 2, "pc": 0x1234, "instr": 0xEC10, "a": 0xFFFF, "d": 7, "sp": 261,
        "sp_max": 300, "heap_hi": 2100, "keyboard": 65, "prog_words": 512,
        "prog_name": b"MathDemo".ljust(16, b"\x00"), "bad_frames": 65535,
    }
    assert parse_status(payload) == expected
    assert parse_status(payload + b"\x99\x98") == expected


def test_parse_status_short():
    with pytest.raises(ValueError):
        parse_status(status_payload()[:36])
