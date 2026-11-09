import random
import itertools
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_and16_sampled_inputs(tmp_path: Path):
  num_vectors = 65536

  # Include critical boundary cases (0, max, walks of 1s and 0s)
  boundary_values = [0, 0xFFFF, 0xAAAA, 0x5555, 0x00FF, 0xFF00]
  for i in range(16):
    boundary_values.append(1 << i)
    boundary_values.append(0xFFFF ^ (1 << i))

  vectors = list(itertools.product(boundary_values, repeat=2))
  while len(vectors) < num_vectors:
    a = random.randint(0, 0xFFFF)
    b = random.randint(0, 0xFFFF)
    vectors.append((a, b))

  (tmp_path / "and16_vectors.hex").write_text("".join(f"{a:04x}{b:04x}\n" for (a, b) in vectors))

  out = iverilog(
    [HW / "sim/tb/tb_and16.v", HW / "rtl/gates/hack_and16.v", HW / "rtl/gates/hack_and.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_nand.v"],
    "tb_and16",
    plusargs={"N": str(len(vectors))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(vectors)]

  for (a, b), line in zip(vectors, lines, strict=True):
    want = a & b
    assert line == f"{want:016b}", (f"{a:016b}", f"{b:016b}")
