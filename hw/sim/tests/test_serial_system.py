import re
import zlib
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from hacktools.assembler import assemble
from hacktools.image import build_image
from hacktools.link import (
    BEGIN, CRC, DATA, END, ERASE, HELLO, PAGE_SIZE, PROGRAM, crc_payload, data_payload,
    erase_payload, program_payload,
)

from serial_frames import decode_frames, encode_frame, parse_status
from simrun import iverilog
from test_flash_boot import COPY_ROM, flash_hex, run_boot

HW = Path(__file__).resolve().parents[2]
SOURCES = [
    HW / "sim/tb/tb_serial_system.v",
    HW / "rtl/top/flash_boot_system.v",
    HW / "sim/models/spi_flash_model.v",
    HW / "sim/models/psram_host_model.v",
    HW / "rtl/io/spi_flash_reader.v",
    HW / "rtl/io/spi_flash_writer.v",
    HW / "rtl/io/flash_session.v",
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
CPB = 9

# COPY_ROM copies RAM[16], SCREEN[8191] and RAM[16383] to RAM[17..19], then
# writes all three. The new image also writes 4321 to RAM[20] and is padded
# past one page.
OLD_IMAGE = build_image(assemble(COPY_ROM), "old")
NEW_ROM = assemble(COPY_ROM.replace("(END)", "@4321\nD=A\n@20\nM=D\n(END)") + "@0\n" * 120)
NEW_IMAGE = build_image(NEW_ROM, "new")
SESSION_TIMEOUT = 20000
CLEAR_CYCLES = 24576

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
    result: dict[str, int] = field(default_factory=dict)
    ram: list[int] = field(default_factory=list)
    screen: list[int] = field(default_factory=list)
    s2: list[str] = field(default_factory=list)                         # S2 press lines

    def r1(self):
        return [(c, v) for c, a, v in self.writes if a == 1]


def run(cwd, items, tail=REPLY_CYCLES + 2000, image=IMAGE, timeout=None, **plusargs):
    """items: bytes sent back to back, ("idle", bits) or ("s2", cycles held)."""
    (cwd / "flash.hex").write_text(flash_hex(image))
    lines, idle = [], 0
    for item in items:
        if isinstance(item, tuple) and item[0] == "idle":
            idle += item[1]
        elif isinstance(item, tuple):
            lines.append(f"{idle} s2 {item[1]}")
            idle = 0
        else:
            for b in item:
                lines.append(f"{idle} {b:02x}")
                idle = 0
    (cwd / "rx.txt").write_text("".join(f"{line}\n" for line in lines))
    args = {"TAIL": str(tail)} | {k: str(v) for k, v in plusargs.items()}
    defines = {"SESSION_TIMEOUT": str(timeout)} if timeout else None
    out = iverilog(SOURCES, "tb_serial_system", plusargs=args, defines=defines,
                   cwd=cwd).splitlines()
    assert "DONE" in out and "TIMEOUT" not in out, out[-20:]
    for bad in ("FAIL", "ERROR", "IGNORED", "BUSY", "REJECTED"):
        assert not any(line.startswith(bad) for line in out), [x for x in out if bad in x]
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
        elif word == "S2":
            r.s2.append(line)
        elif word == "RESULT":
            r.result = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}
        elif word == "TXERR":
            pytest.fail(f"uart_tx framing error: {line}")
    if r.result:
        r.ram = [int(w, 16) for w in (cwd / "ram.txt").read_text().split()]
        r.screen = [int(w, 16) for w in (cwd / "screen.txt").read_text().split()]
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


def frame(ptype, payload=b"", idle=0):
    """hacktools sends 0x00 before every frame; idle: bits to wait for the reply."""
    return [b"\x00" + encode_frame(ptype, payload), ("idle", idle)]


def op_bits(nbytes):
    # SPI at 4 clocks a bit, the flash model's busy time, then a 6-byte reply
    return (32 * (4 + nbytes) + 2000) // CPB + 100


def page_frames(image, page):
    chunk = image[page * PAGE_SIZE:(page + 1) * PAGE_SIZE]
    items = []
    for off in range(0, len(chunk), 32):
        items += frame(DATA, data_payload(off, chunk[off:off + 32]))
    return items + frame(PROGRAM, program_payload(page * PAGE_SIZE, len(chunk)),
                         op_bits(len(chunk)))


def pages(image):
    return range((len(image) + PAGE_SIZE - 1) // PAGE_SIZE)


def start_frames():
    # the old program runs to its loop first
    return [("idle", 3000 // CPB)] + frame(HELLO, idle=100) + frame(BEGIN, idle=100) \
        + frame(ERASE, erase_payload(0, False), op_bits(0))


def end_frames(image):
    # END's reply, the clear and the reload, then STATUS
    return frame(CRC, crc_payload(0, len(image)), op_bits(len(image))) \
        + frame(END, idle=(CLEAR_CYCLES + 40 * len(image) + 5000) // CPB) + frame(0x03)


def last_writes(r):
    return {a: v for _, a, v in r.writes}


def test_flash_image_over_link(tmp_path):
    items = start_frames()
    for page in pages(NEW_IMAGE):
        items += page_frames(NEW_IMAGE, page)
    r = run(tmp_path, items + end_frames(NEW_IMAGE), image=OLD_IMAGE, timeout=SESSION_TIMEOUT)
    replies = decode_frames(bytes(r.tx))
    assert len(pages(NEW_IMAGE)) == 2
    assert [t for t, _ in replies] == [0x90, 0x91, 0x92, 0x94, 0x94, 0x95, 0x96, 0x83]
    assert replies[0][1] == b"\x01"
    assert all(p == b"\x00" for t, p in replies[1:7] if t != 0x95)
    assert replies[5][1] == b"\x00" + zlib.crc32(NEW_IMAGE).to_bytes(4, "little")
    s = parse_status(replies[7][1])
    assert s["boot_state"] == RUN
    assert s["prog_name"] == b"new".ljust(16, b"\0")
    assert s["prog_words"] == len(NEW_ROM)
    # both programs ran; the new one found RAM and screen cleared
    assert [v for _, a, v in r.writes if a == 16] == [1234, 1234]
    last = last_writes(r)
    assert [last[17], last[18], last[19], last[20]] == [0, 0, 0, 4321]
    assert r.result["running"] == 1


def test_pc_quiet_mid_write(tmp_path):
    items = start_frames() + page_frames(NEW_IMAGE, 0)
    items += [("idle", (SESSION_TIMEOUT + CLEAR_CYCLES + 40 * len(NEW_IMAGE) + 5000) // CPB)]
    r = run(tmp_path, items + frame(0x03), image=OLD_IMAGE, timeout=SESSION_TIMEOUT)
    replies = decode_frames(bytes(r.tx))
    assert [t for t, _ in replies] == [0x90, 0x91, 0x92, 0x94, 0x83]
    assert parse_status(replies[-1][1])["boot_state"] in (4, 5)
    assert r.result["running"] == 0 and r.result["boot_state"] in (4, 5)
    assert [r.ram[16], r.ram[16383], r.screen[8191]] == [0, 0, 0]


def test_s2_mid_write(tmp_path):
    # S2 goes down while page 0 programs and comes up before page 1.
    items = start_frames() + page_frames(NEW_IMAGE, 0)
    program_wait = items.pop()
    items += [("idle", 5), ("s2", 3000), program_wait]
    for page in list(pages(NEW_IMAGE))[1:]:
        items += page_frames(NEW_IMAGE, page)
    r = run(tmp_path, items + end_frames(NEW_IMAGE), image=OLD_IMAGE, timeout=SESSION_TIMEOUT)
    assert len(r.s2) == 1 and "session=1 fl_busy=1" in r.s2[0], r.s2
    replies = decode_frames(bytes(r.tx))
    assert [t for t, _ in replies] == [0x90, 0x91, 0x92, 0x94, 0x94, 0x95, 0x96, 0x83]
    assert replies[5][1] == b"\x00" + zlib.crc32(NEW_IMAGE).to_bytes(4, "little")
    assert parse_status(replies[7][1])["boot_state"] == RUN
    assert last_writes(r)[20] == 4321
