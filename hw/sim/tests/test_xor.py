import itertools
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_xor_all_inputs(tmp_path: Path):
  inputs = (0, 1)
  n = 2
  vectors = tuple(itertools.product(inputs, repeat=n))

  (tmp_path / "xor_vectors.hex").write_text("".join(f"{a:01x}{b:01x}\n" for (a, b) in vectors))

  out = iverilog(
    [HW / "sim/tb/tb_xor.v", HW / "rtl/gates/hack_xor.v", HW / "rtl/gates/hack_nand.v"],
    "tb_xor",
    plusargs={"N": str(len(vectors))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(vectors)]

  for (a, b), line in zip(vectors, lines, strict=True):
    want = (a & 1) ^ (b & 1)
    assert line == f"{want}", (a, b)
