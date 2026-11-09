import itertools
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_dmux4way_all_inputs(tmp_path: Path):
  vectors = tuple(itertools.product((0, 1), range(4)))

  (tmp_path / "dmux4way_vectors.hex").write_text("".join(f"{x:01x}{sel:01x}\n" for (x, sel) in vectors))

  out = iverilog(
    [HW / "sim/tb/tb_dmux4way.v", HW / "rtl/gates/hack_dmux4way.v", HW / "rtl/gates/hack_dmux.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_and.v", HW / "rtl/gates/hack_nand.v"],
    "tb_dmux4way",
    plusargs={"N": str(len(vectors))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(vectors)]

  for (x, sel), line in zip(vectors, lines, strict=True):
    want = [x if i == sel else 0 for i in range(4)]
    assert line.split() == [f"{w}" for w in want], (x, sel)
