import random
import itertools
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_not16_sampled_inputs(tmp_path: Path):
  num_inputs = 65536

  # Include critical boundary cases (0, max, walks of 1s and 0s)
  boundary_values = [0, 0xFFFF, 0xAAAA, 0x5555, 0x00FF, 0xFF00]
  for i in range(16):
    boundary_values.append(1 << i)
    boundary_values.append(0xFFFF ^ (1 << i))

  inputs = boundary_values
  while len(inputs) < num_inputs:
    x = random.randint(0, 0xFFFF)
    inputs.append(x)

  (tmp_path / "not16_inputs.hex").write_text("".join(f"{x:04x}\n" for x in inputs))

  out = iverilog(
    [HW / "sim/tb/tb_not16.v", HW / "rtl/gates/hack_not16.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_nand.v"],
    "tb_not16",
    plusargs={"N": str(len(inputs))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(inputs)]

  for x, line in zip(inputs, lines, strict=True):
    want = x ^ 0xFFFF
    assert line == f"{want:016b}", f"{x:016b}"
