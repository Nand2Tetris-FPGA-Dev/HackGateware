import itertools
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_dmux_all_inputs(tmp_path: Path):
  inputs = (0, 1)
  n = 2
  vectors = tuple(itertools.product(inputs, repeat=n))

  (tmp_path / "dmux_vectors.hex").write_text("".join(f"{x:01x}{sel:01x}\n" for (x, sel) in vectors))

  out = iverilog(
    [HW / "sim/tb/tb_dmux.v", HW / "rtl/gates/hack_dmux.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_and.v", HW / "rtl/gates/hack_nand.v"],
    "tb_dmux",
    plusargs={"N": str(len(vectors))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(vectors)]

  for (x, sel), line in zip(vectors, lines, strict=True):
    want = (0, x) if sel else (x, 0)
    assert line.split() == [f"{want[0]}", f"{want[1]}"], (x, sel)
