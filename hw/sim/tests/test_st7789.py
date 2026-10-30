import re
from pathlib import Path

import pytest

from lcdtext import read_frame
from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
SOURCES = [
    HW / "sim/tb/tb_st7789.v",
    HW / "sim/models/st7789_model.v",
    HW / "rtl/debug/st7789_driver.v",
]

# SLPOUT, then Sipeed's list (TangNano-9K-example 61adac1, spi_lcd/src/top.v)
INIT = ["C11"] + (
    "C36 D70 C3A D05 CB2 D0C D0C D00 D33 D33 CB7 D35 CBB D19 CC0 D2C CC2 D01 "
    "CC3 D12 CC4 D20 CC6 D0F CD0 DA4 DA1 CE0 DD0 D04 D0D D11 D13 D2B D3F D54 "
    "D4C D18 D0D D0B D1F D23 CE1 DD0 D04 D0C D11 D13 D2C D3F D44 D51 D2F D1F "
    "D1F D20 D23 C21 C29 C2A D00 D28 D01 D17 C2B D00 D35 D00 DBB"
).split()


def _run(cwd, **plusargs):
    args = {k: str(v) for k, v in plusargs.items()}
    return iverilog(SOURCES, "tb_st7789", plusargs=args, cwd=cwd)


def _times(out):
    m = re.search(r"TIMES (.*)", out)
    assert m, out
    return {k: int(v) for k, v in (f.split("=") for f in m.group(1).split())}


@pytest.fixture(scope="module")
def two_frames(tmp_path_factory):
    work = tmp_path_factory.mktemp("st7789")
    return work, _run(work, FRAMES=2)


@pytest.mark.requires_iverilog
def test_init_sequence(two_frames):
    work, out = two_frames
    log = (work / "lcd_log.txt").read_text().split()
    assert log[:len(INIT) + 1] == INIT + ["C2C"]
    assert not re.search(r"^ERROR ", out, re.M), out


@pytest.mark.requires_iverilog
def test_reset_and_sleep_timing(two_frames):
    t = _times(two_frames[1])
    assert t["resetn"] - t["rst"] >= 50
    assert t["c11_first"] - t["resetn"] >= 70
    assert t["c36_first"] - t["c11_last"] >= 90


@pytest.mark.requires_iverilog
def test_rst_again_restarts_init(tmp_path):
    out = _run(tmp_path, RERESET=1)
    log = (tmp_path / "lcd_log.txt").read_text().split()
    second = [i for i, b in enumerate(log) if b == "C11"][1]
    assert log[second:second + len(INIT) + 1] == INIT + ["C2C"]
    assert not re.search(r"^ERROR ", out, re.M), out


@pytest.mark.requires_iverilog
def test_pattern_frames(two_frames):
    work, out = two_frames
    assert "FRAME 2" in out and "TIMEOUT" not in out, out
    frame = read_frame(work / "frame.hex")
    assert len(frame) == 135 and all(len(row) == 240 for row in frame)
    bad = [(x, y) for y in range(135) for x in range(240) if frame[y][x] != (x << 8) | y]
    assert not bad, f"{len(bad)} wrong pixels, first {bad[:5]}"


@pytest.mark.requires_iverilog
def test_waits_for_frame_ready(tmp_path):
    out = _run(tmp_path, FRAMES=0, READY_DELAY=1000)
    m = re.search(r"READY_WAIT (\d+)", out)
    assert m, out
    assert int(m.group(1)) >= 1000


@pytest.mark.requires_iverilog
def test_spi_timing_clean(two_frames):
    out = two_frames[1]
    assert "ERRORS 0" in out, out
