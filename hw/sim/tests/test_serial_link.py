import random
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from serial_frames import decode_frames, encode_frame, parse_status
from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
SOURCES = [
    HW / "sim/tb/tb_serial_link.v",
    HW / "rtl/io/serial_link.v",
    HW / "rtl/io/uart_rx.v",
    HW / "rtl/io/uart_tx.v",
    HW / "rtl/io/frame_rx.v",
    HW / "rtl/io/frame_tx.v",
]
CLKS_PER_BIT = 9
WATCHDOG = 20000
NAME = b"KeyTest\x00" + bytes(range(0xF0, 0xF8))
STATUS = {
    "boot_state": 5, "pc": 0x1234, "instr": 0xEC10, "a": 0x5A3C, "d": 0xBEEF,
    "sp": 0x0107, "sp_max": 0x01F2, "heap_hi": 0x3A5B, "prog_words": 0x2345,
}
STATUS_ARGS = {
    "BOOT": "boot_state", "PC": "pc", "INSTR": "instr", "A": "a", "D": "d", "SP": "sp",
    "SPMAX": "sp_max", "HEAP": "heap_hi", "WORDS": "prog_words",
}
REPLY_BITS = 450        # idle bits that cover the longest reply going out

STATUS_REQ = encode_frame(0x03)

pytestmark = pytest.mark.requires_iverilog


def key(code):
    return encode_frame(0x01, bytes([code]))


@dataclass
class Run:
    tx: list[tuple[int, int]] = field(default_factory=list)     # (byte, cycle)
    kbd: list[tuple[int, int]] = field(default_factory=list)    # (cycle, value)
    sent: list[int] = field(default_factory=list)
    ends: list[int] = field(default_factory=list)               # last SENT of each bytes item
    end: int = 0

    def replies(self):
        return decode_frames(bytes(b for b, _ in self.tx))


def run(tmp_path, items, tail=5000, bad_max=None, flip=False, clks=CLKS_PER_BIT):
    """items: bytes (sent back to back), ("idle", bits) or ("brk", bits)."""
    lines, last_index, idle, count = [], [], 0, 0
    for item in items:
        if isinstance(item, tuple) and item[0] == "idle":
            idle += item[1]
        elif isinstance(item, tuple) and item[0] == "brk":
            lines.append(f"{idle} brk {item[1]}")
            idle = 0
        else:
            for b in item:
                lines.append(f"{idle} {b:02x}")
                idle = 0
            count += len(item)
            last_index.append(count - 1)
    (tmp_path / "rx.txt").write_text("".join(f"{line}\n" for line in lines))
    plusargs = {k: f"{STATUS[v]:x}" for k, v in STATUS_ARGS.items()}
    plusargs["NAME"] = NAME.hex()
    plusargs["TAIL"] = str(tail)
    if flip:
        plusargs["FLIP"] = "1"
    defines = {"CLKS_PER_BIT": str(clks), "WATCHDOG": str(WATCHDOG)}
    if bad_max is not None:
        defines["BAD_MAX"] = str(bad_max)
    out = iverilog(SOURCES, "tb_serial_link", plusargs=plusargs, defines=defines,
                   cwd=tmp_path).splitlines()
    assert "DONE" in out, out
    r = Run()
    for line in out:
        word, *rest = line.split()
        if word == "TX":
            r.tx.append((int(rest[0], 16), int(rest[1])))
        elif word == "KBD":
            r.kbd.append((int(rest[0]), int(rest[1], 16)))
        elif word == "SENT":
            r.sent.append(int(rest[0]))
        elif word == "END":
            r.end = int(rest[0])
        elif word == "TXERR":
            pytest.fail(f"uart_tx framing error: {line}")
    r.ends = [r.sent[i] for i in last_index]
    return r


def status_of(r, index=0):
    statuses = [p for t, p in r.replies() if t == 0x83]
    return parse_status(statuses[index])


def test_key_sets_register(tmp_path):
    r = run(tmp_path, [key(0x41), ("idle", 20), key(0)])
    assert [v for _, v in r.kbd] == [0x41, 0]
    assert r.kbd[0][0] <= r.ends[0] + 3
    assert r.kbd[1][0] <= r.ends[1] + 3


def test_hdmi_build_rate(tmp_path):
    # The other tests run at 9 clocks a bit to keep the sims short.
    echo = encode_frame(0x02, bytes([0, 1, 2, 0]))
    r = run(tmp_path, [key(0x41), STATUS_REQ, ("idle", REPLY_BITS), echo,
                       ("idle", REPLY_BITS)], tail=10000, clks=18)
    assert r.ends[0] >= len(key(0x41)) * 10 * 18
    assert [v for _, v in r.kbd] == [0x41]
    assert [t for t, _ in r.replies()] == [0x83, 0x82]
    assert status_of(r)["keyboard"] == 0x41
    assert r.replies()[1][1] == bytes([0, 1, 2, 0])


def test_echo_reply(tmp_path):
    payloads = [b"", b"\x00", bytes([0, 1, 2, 0]), bytes([0, 7, 0, 0, 9, 0xFF, 1, 0] * 2)]
    items = []
    for p in payloads:
        items += [encode_frame(0x02, p), ("idle", REPLY_BITS)]
    r = run(tmp_path, items)
    assert bytes(b for b, _ in r.tx) == b"".join(encode_frame(0x82, p) for p in payloads)
    assert encode_frame(0x82, bytes([0, 1, 2, 0])) == bytes.fromhex("02 82 03 01 02 02 12 00")


def test_status_reply(tmp_path):
    r = run(tmp_path, [key(0x41), STATUS_REQ, ("idle", REPLY_BITS)], flip=True)
    assert len(r.replies()) == 1
    s = status_of(r)
    for name, value in STATUS.items():
        assert s[name] == value, name
    assert s["prog_name"] == NAME
    assert s["keyboard"] == 0x41
    assert s["bad_frames"] == 0


def test_bad_frames_counted(tmp_path):
    bad_crc = bytearray(key(0x41))
    bad_crc[2] ^= 0x01
    bad = [
        bytes(bad_crc),
        encode_frame(0x05),
        encode_frame(0x01, b"\x41\x42"),
        encode_frame(0x03, b"\x00"),
        encode_frame(0x02, bytes(range(1, 18))),     # ECHO takes at most 16
        encode_frame(0x01),
        encode_frame(0x82, b"\x01"),
    ]
    r = run(tmp_path, bad + [STATUS_REQ, ("idle", REPLY_BITS)])
    assert r.kbd == []
    assert len(r.replies()) == 1
    assert status_of(r)["bad_frames"] == len(bad)


def test_bad_count_saturates(tmp_path):
    r = run(tmp_path, [encode_frame(0x05)] * 5 + [STATUS_REQ, ("idle", REPLY_BITS)], bad_max=3)
    assert status_of(r)["bad_frames"] == 3


def test_garbage_then_key(tmp_path):
    garbage = random.Random(9).randbytes(200)
    assert all(t != 0x01 for t, _ in decode_frames(garbage))
    r = run(tmp_path, [garbage, ("brk", 40), ("idle", 2), b"\x00", key(0x41)])
    assert [v for _, v in r.kbd] == [0x41]
    assert r.kbd[0][0] <= r.ends[-1] + 3


def test_leading_zero(tmp_path):
    # HackLink sends 0x00 before each frame; the empty frames it makes are not bad.
    r = run(tmp_path, [b"\x00" + key(0x41), ("brk", 40), ("idle", 2),
                       b"\x00" + STATUS_REQ, ("idle", REPLY_BITS)])
    assert [v for _, v in r.kbd] == [0x41]
    assert status_of(r)["bad_frames"] == 1    # the break


def test_key_during_reply(tmp_path):
    r = run(tmp_path, [STATUS_REQ, key(0x41), ("idle", REPLY_BITS)])
    assert len(r.replies()) == 1
    assert status_of(r)["keyboard"] == 0
    assert [v for _, v in r.kbd] == [0x41]
    assert r.kbd[0][0] <= r.ends[1] + 3
    assert r.kbd[0][0] < r.tx[-1][1]


def test_request_during_reply(tmp_path):
    # The status inputs flip after each snapshot, so a second one would spoil the reply.
    r = run(tmp_path, [
        STATUS_REQ, STATUS_REQ, encode_frame(0x02, b"\x11"),
        ("idle", REPLY_BITS), STATUS_REQ, ("idle", REPLY_BITS),
    ], flip=True)
    replies = r.replies()
    assert [t for t, _ in replies] == [0x83, 0x83]
    assert status_of(r, 1)["bad_frames"] == 0
    assert bytes(b for b, _ in r.tx) == b"".join(encode_frame(t, p) for t, p in replies)


def test_watchdog_clears_key(tmp_path):
    r = run(tmp_path, [key(0x41)], tail=WATCHDOG + 2000)
    assert [v for _, v in r.kbd] == [0x41, 0]
    assert abs(r.kbd[1][0] - r.end - WATCHDOG) <= 100


def test_watchdog_kept_alive(tmp_path):
    gap = 15000 // CLKS_PER_BIT
    items = [key(0x41)]
    for _ in range(100000 // 15000):
        items += [("idle", gap), STATUS_REQ]
    r = run(tmp_path, items)
    assert r.end - r.ends[0] >= 90000
    assert [v for _, v in r.kbd] == [0x41]
    assert all(s["keyboard"] == 0x41 for s in map(parse_status, (p for _, p in r.replies())))


def test_bad_frames_do_not_feed_watchdog(tmp_path):
    gap = 15000 // CLKS_PER_BIT
    items = [key(0x41)]
    for _ in range(40000 // 15000):
        items += [("idle", gap), encode_frame(0x05), ("idle", gap), encode_frame(0x82, b"\x01")]
    r = run(tmp_path, items, tail=WATCHDOG)
    assert [v for _, v in r.kbd] == [0x41, 0]
    assert abs(r.kbd[1][0] - r.ends[0] - WATCHDOG) <= 100


def test_silent_without_requests(tmp_path):
    r = run(tmp_path, [key(0x41), key(0x42), ("idle", 30), key(0)])
    assert [v for _, v in r.kbd] == [0x41, 0x42, 0]
    assert r.tx == []
