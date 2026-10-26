import re
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


def expected_frame() -> list[str]:
    words = [(i * 0x9E37) & 0xFFFF for i in range(8192)]
    rows = []
    for y in range(480):
        row = []
        for x in range(640):
            if 64 <= x < 576 and 112 <= y < 368:
                word = words[(y - 112) * 32 + (x - 64) // 16]
                row.append(str(word >> ((x - 64) % 16) & 1))
            else:
                row.append("B")
        rows.append("".join(row))
    return rows


@pytest.mark.requires_iverilog
def test_frame_matches(tmp_path):
    out = iverilog(
        [
            HW / "sim/tb/tb_fb_reader.v",
            HW / "rtl/video/hack_fb_reader.v",
            HW / "rtl/video/video_timing_640x480.v",
            HW / "rtl/mem/screen_mem.v",
        ],
        "tb_fb_reader",
        cwd=tmp_path,
    )
    stats = dict(re.findall(r"(\w+)=(-?\d+)", out))
    assert stats["short_lines"] == "0", out
    assert stats["in_gap"] == stats["out_gap"] != "-1", out

    frame = (tmp_path / "frame.txt").read_text().splitlines()
    want = expected_frame()
    assert len(frame) == 480
    for y, (got, row) in enumerate(zip(frame, want)):
        assert got == row, f"line {y} differs at x={next(i for i, (a, b) in enumerate(zip(got, row)) if a != b)}"
