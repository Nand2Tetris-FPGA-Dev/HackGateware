import random
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from hacktools.link import (
    BEGIN, CRC, DATA, END, ERASE, HELLO, PROGRAM, crc_payload, data_payload, erase_payload,
    program_payload,
)

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
    fl: list[tuple[int, int, int, int]] = field(default_factory=list)  # (op, addr, len, cycle)
    pb: list[tuple[int, int, int]] = field(default_factory=list)       # (addr, data, cycle)
    ends: list[int] = field(default_factory=list)               # last SENT of each bytes item
    end: int = 0

    def replies(self):
        return decode_frames(bytes(b for b, _ in self.tx))


def run(tmp_path, items, tail=5000, bad_max=None, flip=False, clks=CLKS_PER_BIT,
        fl_wait=0, fl_status=0, fl_crc=0):
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
    plusargs |= {"FL_WAIT": str(fl_wait), "FL_STATUS": f"{fl_status:x}", "FL_CRC": f"{fl_crc:x}"}
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
        elif word == "FLREQ":
            r.fl.append((int(rest[0]), int(rest[1], 16), int(rest[2]), int(rest[3])))
        elif word == "PB":
            r.pb.append((int(rest[0], 16), int(rest[1], 16), int(rest[2])))
        elif word in ("TXERR", "FLREQBUSY"):
            pytest.fail(f"testbench error: {line}")
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


def flash_ops(r):
    return [(op, addr, length) for op, addr, length, _ in r.fl]


def test_hello_reply(tmp_path):
    r = run(tmp_path, [encode_frame(HELLO), ("idle", REPLY_BITS)])
    assert bytes(b for b, _ in r.tx) == bytes.fromhex("04 90 01 E6 00")
    assert r.fl == []


def test_data_to_page_buffer(tmp_path):
    chunk = bytes((i * 37) & 0xFF for i in range(32))       # has a zero for COBS
    longest = bytes((i * 11 + 3) & 0xFF for i in range(61))
    r = run(tmp_path, [encode_frame(DATA, data_payload(32, chunk)),
                       encode_frame(DATA, data_payload(195, longest)),
                       STATUS_REQ, ("idle", REPLY_BITS)])
    assert [(a, d) for a, d, _ in r.pb] == (list(zip(range(32, 64), chunk))
                                            + list(zip(range(195, 256), longest)))
    assert r.pb[-1][2] <= r.ends[1] + 70
    assert r.fl == []
    assert [t for t, _ in r.replies()] == [0x83]
    assert status_of(r)["bad_frames"] == 0


def test_flash_request_and_reply(tmp_path):
    r = run(tmp_path, [encode_frame(PROGRAM, program_payload(0x020100, 256)),
                       ("idle", REPLY_BITS)], fl_wait=100, fl_status=3)
    assert flash_ops(r) == [(4, 0x020100, 256)]
    assert r.fl[0][3] <= r.ends[0] + 10
    assert r.replies() == [(0x94, b"\x03")]


def test_flash_request_fields(tmp_path):
    frames = [
        encode_frame(BEGIN),
        encode_frame(ERASE, erase_payload(0x3F0000, True)),
        encode_frame(ERASE, erase_payload(0x001000, False)),
        encode_frame(CRC, crc_payload(0x012345, 0x0ABCDE)),
        encode_frame(END),
    ]
    items = []
    for f in frames:
        items += [f, ("idle", REPLY_BITS)]
    r = run(tmp_path, items, fl_crc=0xDEADBEEF)
    assert flash_ops(r) == [(1, 0, 0), (2, 0x3F0000, 1), (2, 0x001000, 0),
                            (5, 0x012345, 0x0ABCDE), (6, 0, 0)]
    crc = bytes([0]) + (0xDEADBEEF).to_bytes(4, "little")
    assert r.replies() == [(0x91, b"\x00"), (0x92, b"\x00"), (0x92, b"\x00"),
                           (0x95, crc), (0x96, b"\x00")]


def test_key_while_flash_pending(tmp_path):
    r = run(tmp_path, [encode_frame(PROGRAM, program_payload(0, 256)), key(65),
                       ("idle", REPLY_BITS)], fl_wait=3000)
    assert [v for _, v in r.kbd] == [65]
    assert r.kbd[0][0] <= r.ends[1] + 3
    assert r.kbd[0][0] < r.tx[0][1]
    assert [t for t, _ in r.replies()] == [0x94]


def test_bad_flash_lengths(tmp_path):
    bad = [
        encode_frame(ERASE, b"\x00\x10\x00"),
        encode_frame(DATA, b"\x05"),
        encode_frame(END, b"\x00"),
        encode_frame(HELLO, b"\x01"),
        encode_frame(BEGIN, b"\x00"),
        encode_frame(PROGRAM, b"\x00\x00\x00\x10"),
        encode_frame(CRC, b"\x00\x00\x00\x10\x00"),
    ]
    r = run(tmp_path, bad + [STATUS_REQ, ("idle", REPLY_BITS)])
    assert r.fl == [] and r.pb == []
    assert [t for t, _ in r.replies()] == [0x83]
    assert status_of(r)["bad_frames"] == len(bad)


def test_flash_request_while_busy(tmp_path):
    crc = encode_frame(CRC, crc_payload(0, 16))
    data = encode_frame(DATA, data_payload(0, bytes(range(1, 9))))
    program = encode_frame(PROGRAM, program_payload(0, 16))
    r = run(tmp_path, [program, crc, encode_frame(HELLO), data,
                       ("idle", 3000 // CLKS_PER_BIT + REPLY_BITS), crc, ("idle", REPLY_BITS),
                       STATUS_REQ, ("idle", REPLY_BITS)], fl_wait=3000)
    assert flash_ops(r) == [(4, 0, 16), (5, 0, 16)]
    assert r.pb == []       # the page buffer may be in use
    assert [t for t, _ in r.replies()] == [0x94, 0x95, 0x83]
    assert status_of(r)["bad_frames"] == 0


def test_flash_request_while_reply_waits(tmp_path):
    # BEGIN's reply waits behind the ECHO reply; CRC comes in meanwhile.
    echo = encode_frame(0x02, bytes(range(1, 17)))
    r = run(tmp_path, [echo, encode_frame(BEGIN), encode_frame(CRC, crc_payload(0, 16)),
                       ("idle", 2 * REPLY_BITS)])
    assert flash_ops(r) == [(1, 0, 0)]
    assert [t for t, _ in r.replies()] == [0x82, 0x91]
    assert r.fl[0][3] < r.tx[0][1] + 20 * 10 * CLKS_PER_BIT


def test_flash_request_while_reply_goes_out(tmp_path):
    # BEGIN lands while CRC's 8-byte reply is on the wire; it must not change that reply.
    r = run(tmp_path, [encode_frame(CRC, crc_payload(0, 16)), encode_frame(BEGIN),
                       ("idle", REPLY_BITS)], fl_crc=0x12345678)
    assert r.fl[0][3] < r.ends[1] < r.tx[-1][1]
    assert flash_ops(r) == [(5, 0, 16)]
    assert r.replies() == [(0x95, bytes([0]) + (0x12345678).to_bytes(4, "little"))]


def test_flash_frames_feed_watchdog(tmp_path):
    gap = 15000 // CLKS_PER_BIT
    items = [key(0x41)]
    for _ in range(40000 // 15000):
        items += [("idle", gap), encode_frame(HELLO)]
    r = run(tmp_path, items)
    assert r.end - r.ends[0] >= 30000
    assert [v for _, v in r.kbd] == [0x41]
