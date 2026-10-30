from dataclasses import dataclass, field
from pathlib import Path

import pytest
from hacktools.assembler import assemble
from hacktools.image import build_image

from serial_frames import decode_frames, encode_frame, parse_status
from simrun import iverilog
from test_flash_boot import flash_hex, run_boot

HW = Path(__file__).resolve().parents[2]
SOURCES = [
    HW / "sim/tb/tb_serial_system.v",
    HW / "rtl/top/flash_boot_system.v",
    HW / "sim/models/spi_flash_model.v",
    HW / "sim/models/psram_host_model.v",
    HW / "rtl/io/spi_flash_reader.v",
    HW / "rtl/io/boot_loader.v",
    HW / "rtl/io/serial_link.v",
    HW / "rtl/io/uart_rx.v",
    HW / "rtl/io/uart_tx.v",
    HW / "rtl/io/frame_rx.v",
    HW / "rtl/io/frame_tx.v",
    HW / "rtl/debug/hack_stats.v",
    HW / "rtl/progmem/progmem_psram.v",
    HW / "rtl/top/hack_computer.v",
    HW / "rtl/cpu/hack_cpu.v",
    HW / "rtl/cpu/hack_alu.v",
    HW / "rtl/mem/hack_memory.v",
    HW / "rtl/mem/ram16k.v",
    HW / "rtl/mem/screen_mem.v",
]
ROM = assemble("""
(LOOP)
    @KBD
    D=M
    @R1
    M=D
    @LOOP
    0;JMP
""")
IMAGE = build_image(ROM, "KBD")
KBD = 24576
RUN = 2
REPLY_CYCLES = 40 * 10 * 9    # a STATUS reply going out

pytestmark = pytest.mark.requires_iverilog


def key(code):
    return encode_frame(0x01, bytes([code]))


@dataclass
class Run:
    writes: list[tuple[int, int, int]] = field(default_factory=list)   # (cycle, addr, value)
    kbd: list[tuple[int, int]] = field(default_factory=list)           # (cycle, value)
    tx: bytearray = field(default_factory=bytearray)
    resets: list[int] = field(default_factory=list)
    end: int = 0
    press: int = 0

    def r1(self):
        return [(c, v) for c, a, v in self.writes if a == 1]


def run(cwd, items, tail=REPLY_CYCLES + 2000, **plusargs):
    """items: bytes sent back to back, or ("idle", bits)."""
    (cwd / "flash.hex").write_text(flash_hex(IMAGE))
    lines, idle = [], 0
    for item in items:
        if isinstance(item, tuple):
            idle += item[1]
        else:
            for b in item:
                lines.append(f"{idle} {b:02x}")
                idle = 0
    (cwd / "rx.txt").write_text("".join(f"{line}\n" for line in lines))
    args = {"TAIL": str(tail)} | {k: str(v) for k, v in plusargs.items()}
    out = iverilog(SOURCES, "tb_serial_system", plusargs=args, cwd=cwd).splitlines()
    assert "DONE" in out and "TIMEOUT" not in out, out[-20:]
    r = Run()
    for line in out:
        word, *rest = line.split()
        if word == "W":
            r.writes.append((int(rest[0]), int(rest[1]), int(rest[2], 16)))
        elif word == "KBD":
            r.kbd.append((int(rest[0]), int(rest[1], 16)))
        elif word == "TX":
            r.tx.append(int(rest[0], 16))
        elif word == "reset":
            r.resets.append(int(rest[0]))
        elif word == "END":
            r.end = int(rest[0])
        elif word == "PRESS":
            r.press = int(rest[0])
        elif word == "TXERR":
            pytest.fail(f"uart_tx framing error: {line}")
    return r


def test_key_reaches_program(tmp_path):
    r = run(tmp_path, [key(0x41)])
    before = [v for c, v in r.r1() if c < r.end]
    assert before and set(before) == {0}
    first = next(c for c, v in r.r1() if v == 0x41)
    # The key lands a cycle after END, so the program writes it within two
    # loop passes (one pass is 123 cycles; the write came 88 after END).
    loop = r.r1()[1][0] - r.r1()[0][0]
    assert first - r.end < 2 * loop, (first - r.end, loop)
    assert {v for c, v in r.r1() if c > first} == {0x41}


def test_status_from_system(tmp_path):
    r = run(tmp_path, [key(0x41), encode_frame(0x03)])
    replies = decode_frames(bytes(r.tx))
    assert [t for t, _ in replies] == [0x83]
    s = parse_status(replies[0][1])
    assert s["boot_state"] == RUN
    assert s["prog_name"] == b"KBD".ljust(16, b"\0")
    assert s["prog_words"] == len(ROM)
    assert s["keyboard"] == 0x41
    assert s["pc"] < len(ROM)
    assert s["a"] in (0, 1, KBD)
    assert s["d"] == 0x41
    assert s["bad_frames"] == 0


def test_s1_keeps_key(tmp_path):
    r = run(tmp_path, [key(0x41)], PRESS_AT=1000)
    assert len(r.resets) == 1 and r.resets[0] >= r.press
    assert [v for _, v in r.kbd] == [0x41]
    after = [v for c, v in r.r1() if c > r.resets[0]]
    assert after and set(after) == {0x41}


def test_trace_unchanged(tmp_path):
    steps = 200
    (tmp_path / "link").mkdir()
    (tmp_path / "boot").mkdir()
    run(tmp_path / "link", [], tail=10**6, STEPS=steps)
    run_boot(tmp_path / "boot", IMAGE, steps)
    link = (tmp_path / "link/trace.txt").read_text().splitlines()
    boot = (tmp_path / "boot/trace.txt").read_text().splitlines()
    assert len(link) == steps
    assert link == boot
