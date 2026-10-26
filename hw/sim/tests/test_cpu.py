import random
from pathlib import Path

import pytest
from hacktools.emulator import alu

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
EDGES = [0, 1, 2, 0x7FFF, 0x8000, 0x8001, 0xFFFF, 0xFFFE, 0x5555, 0xAAAA]


@pytest.mark.requires_iverilog
def test_alu_all_controls(tmp_path):
    rng = random.Random(1)
    pairs = [(x, y) for x in EDGES for y in EDGES]
    pairs += [(rng.randrange(0x10000), rng.randrange(0x10000)) for _ in range(200 - len(pairs))]
    vectors = [(x, y, ctrl) for ctrl in range(64) for x, y in pairs]
    (tmp_path / "alu_vectors.hex").write_text(
        "".join(f"{x:04x}{y:04x}{ctrl:04x}\n" for x, y, ctrl in vectors)
    )

    out = iverilog(
        [HW / "sim/tb/tb_alu.v", HW / "rtl/cpu/hack_alu.v"],
        "tb_alu",
        plusargs={"N": str(len(vectors))},
        cwd=tmp_path,
    )
    lines = out.split("\n")[: len(vectors)]
    for (x, y, ctrl), line in zip(vectors, lines, strict=True):
        want = alu(x, y, ctrl)
        assert line.split() == [f"{want:04x}", str(int(want == 0)), str(want >> 15)], (x, y, ctrl)


@pytest.mark.requires_iverilog
def test_cpu_directed():
    out = iverilog(
        [HW / "sim/tb/tb_cpu.v", HW / "rtl/cpu/hack_cpu.v", HW / "rtl/cpu/hack_alu.v"],
        "tb_cpu",
    )
    assert "PASS" in out, out
