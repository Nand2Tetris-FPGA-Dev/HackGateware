import itertools
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_mux_all_inputs(tmp_path: Path):
  inputs = (0, 1)
  n = 3
  vectors = tuple(itertools.product(inputs, repeat=n))

  (tmp_path / "mux_vectors.hex").write_text("".join(f"{a:01x}{b:01x}{sel:01x}\n" for (a, b, sel) in vectors))

  out = iverilog(
    [HW / "sim/tb/tb_mux.v", HW / "rtl/gates/hack_mux.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_nand.v"],
    "tb_mux",
    plusargs={"N": str(len(vectors))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(vectors)]

  for (a, b, sel), line in zip(vectors, lines, strict=True):
    want = b if sel else a
    assert line == f"{want}", (a, b, sel)
