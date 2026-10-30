import random
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
SOURCES = [HW / "sim/tb/tb_uart.v", HW / "rtl/io/uart_rx.v", HW / "rtl/io/uart_tx.v"]
BYTES = [0x00, 0xFF, 0x55, 0xAA, 0x01, 0x80, 0x41, 0xD5]
BIT_3M = 333333
CLK_PS = 37037      # 27 MHz, as in tb_uart.v

pytestmark = pytest.mark.requires_iverilog


def run_uart(tmp_path, items=(), clks=9, **plusargs):
    """items: (byte, stop) pairs. Returns the tb's output lines (RX/ERR/LB)."""
    (tmp_path / "rx.hex").write_text("".join(f"{b:02x} {s}\n" for b, s in items))
    out = iverilog(SOURCES, "tb_uart", plusargs={k: str(v) for k, v in plusargs.items()},
                   defines={"CLKS_PER_BIT": str(clks)}, cwd=tmp_path)
    assert "DONE" in out, out
    return out.splitlines()


def received(lines, tag="RX"):
    return [int(line.split()[1], 16) for line in lines if line.startswith(tag + " ")]


def good(values):
    return [(b, 1) for b in values]


def test_rx_bytes_at_3m(tmp_path):
    lines = run_uart(tmp_path, good(BYTES), BIT_PS=BIT_3M)
    assert received(lines) == BYTES
    assert "ERR" not in lines


# 18 is the hdmi build's rate (1.5 Mbaud).
@pytest.mark.parametrize("clks", [9, 18])
@pytest.mark.parametrize("ppm", [-20000, 20000])
def test_rx_rate_mismatch(tmp_path, ppm, clks):
    bit_ps = round(CLK_PS * clks * (1 + ppm / 1e6))
    lines = run_uart(tmp_path, good(BYTES), clks=clks, BIT_PS=bit_ps)
    assert received(lines) == BYTES
    assert "ERR" not in lines


def test_rx_back_to_back(tmp_path):
    values = random.Random(1).choices(range(256), k=64)
    lines = run_uart(tmp_path, good(values), BIT_PS=BIT_3M, GAP_BITS=0)
    assert received(lines) == values
    assert "ERR" not in lines


def test_rx_bad_stop_bit(tmp_path):
    lines = run_uart(tmp_path, [(0x41, 0), (0x42, 1)], BIT_PS=BIT_3M)
    assert lines.count("ERR") == 1
    assert received(lines) == [0x42]


def test_rx_break_recovers(tmp_path):
    lines = run_uart(tmp_path, good(BYTES), BIT_PS=BIT_3M, BREAK_BITS=40)
    assert lines.count("ERR") == 1
    assert received(lines) == BYTES


@pytest.mark.parametrize("clks", [9, 18])
def test_tx_loopback(tmp_path, clks):
    lines = run_uart(tmp_path, clks=clks, LOOP=1)
    assert received(lines, "LB") == list(range(256))
    assert "LBERR" not in lines
    assert "IDLE 1" in lines


def test_slow_rate(tmp_path):
    lines = run_uart(tmp_path, good(BYTES), clks=234, BIT_PS=8680556)
    assert received(lines) == BYTES
    assert "ERR" not in lines
