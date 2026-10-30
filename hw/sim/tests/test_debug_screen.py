import re
from pathlib import Path

import pytest

from lcdtext import read_font, read_frame, frame_text, status_lines
from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
FONT = HW / "rtl/debug/font8x8.hex"
SOURCES = [
    HW / "sim/tb/tb_debug_screen.v",
    HW / "sim/models/st7789_model.v",
    HW / "rtl/debug/st7789_driver.v",
    HW / "rtl/debug/debug_screen.v",
]

PONG = dict(state=2, slot=0, name="Pong demo", words=29149, pc=12345,
            instr=0b1110110000010000, a=-32768, d=32767, sp=261, sp_max=290, heap_hi=2310)
EDGE = dict(state=2, slot=31, name="ABCDEFGHIJKLMNOP", words=32768, pc=32767,
            instr=0xFFFF, a=-32768, d=-1, sp=65535, sp_max=0, heap_hi=16383)
OTHER = dict(state=3, slot=7, name="Other prog", words=123, pc=9, instr=0x1234,
             a=-5, d=40000 - 65536, sp=300, sp_max=301, heap_hi=0)

ARGS = {"state": "STATE", "slot": "SLOT", "words": "WORDS", "pc": "PC", "instr": "INSTR",
        "a": "A", "d": "D", "sp": "SP", "sp_max": "SPMAX", "heap_hi": "HEAP"}


def _plusargs(v, suffix=""):
    out = {ARGS[k] + suffix: str(v[k] & 0xFFFF) for k in ARGS}
    out["NAME" + suffix] = v["name"].encode("ascii").ljust(16, b"\x00").hex()
    return out


def _run(cwd, values, frames=1, **extra):
    plusargs = _plusargs(values) | {"FRAMES": str(frames)}
    plusargs |= {k: str(x) for k, x in extra.items()}
    out = iverilog(SOURCES, "tb_debug_screen", plusargs=plusargs,
                   defines={"FONT_HEX": f'"{FONT.as_posix()}"'}, cwd=cwd)
    assert "ERRORS 0" in out and "TIMEOUT" not in out, out
    return out


def _text(cwd, n=1):
    return frame_text(read_frame(cwd / f"frame{n}.hex"), FONT)


@pytest.fixture(scope="module")
def pong_run(tmp_path_factory):
    work = tmp_path_factory.mktemp("debug_screen")
    _run(work, PONG)
    return work


def test_font_glyphs_unique():
    font = read_font(FONT)
    glyphs = [tuple(font[c]) for c in range(0x20, 0x7F)]
    assert len(set(glyphs)) == len(glyphs)


@pytest.mark.requires_iverilog
def test_screen_run_state(pong_run):
    assert _text(pong_run) == status_lines(**PONG)


@pytest.mark.requires_iverilog
def test_screen_edge_values(tmp_path):
    _run(tmp_path, EDGE)
    assert _text(tmp_path) == status_lines(**EDGE)


@pytest.mark.requires_iverilog
@pytest.mark.parametrize("state", range(6))
def test_each_state_text(tmp_path, state):
    values = PONG | {"state": state}
    _run(tmp_path, values)
    lines = _text(tmp_path)
    expected = status_lines(**values)
    assert lines[0] == expected[0]
    assert (lines[1].strip() == "") == (state not in (2, 3))
    assert lines == expected


@pytest.mark.requires_iverilog
def test_name_zero_bytes_are_spaces(tmp_path):
    values = PONG | {"name": "PONG"}
    _run(tmp_path, values)
    assert _text(tmp_path)[1] == "PONG" + " " * 13 + "29149 words  "


# Text row 1 is drawn 61440-122880 cycles after RAMWR (8 pixel rows of 240
# pixels, 32 cycles each), so the change lands while frame 1 draws the name.
@pytest.mark.requires_iverilog
def test_snapshot_is_coherent(tmp_path):
    change_at = 100000
    out = _run(tmp_path, PONG, frames=2, CHANGE_AT=change_at, **_plusargs(OTHER, "2"))
    ramwr = int(re.search(r"RAMWR (\d+)", out).group(1))
    assert ramwr + 61440 < change_at < ramwr + 122880
    assert _text(tmp_path, 1) == status_lines(**PONG)
    assert _text(tmp_path, 2) == status_lines(**OTHER)


@pytest.mark.requires_iverilog
def test_bottom_rows_black(pong_run):
    frame = read_frame(pong_run / "frame1.hex")
    assert all(p == 0 for row in frame[128:] for p in row)
