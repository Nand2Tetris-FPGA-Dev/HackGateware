import random
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_mux4way16_sampled_inputs(tmp_path: Path):
  num_vectors = 65536

  vectors = []
  while len(vectors) < num_vectors:
    data = tuple(random.randint(0, 0xFFFF) for _ in range(4))
    sel = random.randint(0, 3)
    vectors.append((data, sel))

  (tmp_path / "mux4way16_vectors.hex").write_text("".join("".join(f"{x:04x}" for x in data) + f"{sel:01x}\n" for (data, sel) in vectors))

  out = iverilog(
    [HW / "sim/tb/tb_mux4way16.v", HW / "rtl/gates/hack_mux4way16.v", HW / "rtl/gates/hack_mux16.v", HW / "rtl/gates/hack_mux.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_nand.v"],
    "tb_mux4way16",
    plusargs={"N": str(len(vectors))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(vectors)]

  for (data, sel), line in zip(vectors, lines, strict=True):
    want = data[sel]
    assert line == f"{want:016b}", ([f"{x:016b}" for x in data], sel)
