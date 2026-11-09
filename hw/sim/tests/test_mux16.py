import random
import itertools
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_mux16_sampled_inputs(tmp_path: Path):
  num_vectors = 65536

  vectors = []
  while len(vectors) < num_vectors:
    a = random.randint(0, 0xFFFF)
    b = random.randint(0, 0xFFFF)
    sel = random.randint(0, 1)
    vectors.append((a, b, sel))

  (tmp_path / "mux16_vectors.hex").write_text("".join(f"{a:04x}{b:04x}{sel:01x}\n" for (a, b, sel) in vectors))

  out = iverilog(
    [HW / "sim/tb/tb_mux16.v", HW / "rtl/gates/hack_mux16.v", HW / "rtl/gates/hack_mux.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_nand.v"],
    "tb_mux16",
    plusargs={"N": str(len(vectors))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(vectors)]

  for (a, b, sel), line in zip(vectors, lines, strict=True):
    want = b if sel else a
    assert line == f"{want:016b}", (f"{a:016b}", f"{b:016b}", sel)
