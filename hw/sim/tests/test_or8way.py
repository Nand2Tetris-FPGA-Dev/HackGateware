from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_or8way_all_inputs(tmp_path: Path):
  vectors = tuple(range(256))

  (tmp_path / "or8way_vectors.hex").write_text("".join(f"{x:02x}\n" for x in vectors))

  out = iverilog(
    [HW / "sim/tb/tb_or8way.v", HW / "rtl/gates/hack_or8way.v", HW / "rtl/gates/hack_or.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_nand.v"],
    "tb_or8way",
    plusargs={"N": str(len(vectors))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(vectors)]

  for x, line in zip(vectors, lines, strict=True):
    want = int(x != 0)
    assert line == f"{want}", f"{x:08b}"
