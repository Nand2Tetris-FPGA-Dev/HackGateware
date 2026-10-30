from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.requires_iverilog


def write(addr, value):
    return (0, 1, addr, value)


def read(addr, value=0x1234):
    return (0, 0, addr, value)


CLEAR = (1, 0, 0, 0)


def run_stats(tmp_path, cycles):
    """cycles: (clear, we, addr, wdata) per cycle.

    Returns (sp, sp_max, heap_hi) after each.
    """
    stim = "".join(f"{c:x} {w:x} {a:x} {d:x}\n" for c, w, a, d in cycles)
    (tmp_path / "stim.txt").write_text(stim)
    out = iverilog([HW / "sim/tb/tb_hack_stats.v", HW / "rtl/debug/hack_stats.v"],
                   "tb_hack_stats", cwd=tmp_path)
    assert "DONE" in out, out
    lines = (tmp_path / "out.txt").read_text().splitlines()
    return [tuple(int(v) for v in line.split()) for line in lines]


def test_stats_sp_and_max(tmp_path):
    out = run_stats(tmp_path, [CLEAR] + [write(0, v) for v in (256, 261, 290, 261)])
    assert [(sp, mx) for sp, mx, _ in out[1:]] == [(256, 256), (261, 261), (290, 290), (261, 290)]


def test_stats_max_is_unsigned(tmp_path):
    out = run_stats(tmp_path, [CLEAR] + [write(0, v) for v in (290, 65535, 300)])
    assert out[-1] == (300, 65535, 0)


def test_stats_heap_range(tmp_path):
    out = run_stats(tmp_path, [CLEAR] + [write(a, 7) for a in (2047, 2048, 16383, 16384, 3000)])
    assert [h for _, _, h in out[1:]] == [0, 2048, 16383, 16383, 16383]
    out = run_stats(tmp_path, [CLEAR] + [write(a, 7) for a in (2047, 16384, 24576)])
    assert [h for _, _, h in out[1:]] == [0, 0, 0]


def test_stats_ignore_reads(tmp_path):
    out = run_stats(
        tmp_path, [CLEAR, write(0, 300), write(2500, 1), read(0), read(5000), read(0, 999)]
    )
    assert out[2:] == [(300, 300, 2500)] * 4


def test_stats_clear(tmp_path):
    out = run_stats(tmp_path, [CLEAR, write(0, 290), write(4000, 1), CLEAR, CLEAR,
                               write(0, 270), write(2100, 1)])
    assert out[2] == (290, 290, 4000)
    assert out[3] == out[4] == (0, 0, 0)
    assert out[6] == (270, 270, 2100)
