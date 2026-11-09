from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_not_all_inputs(tmp_path: Path):
  inputs = (0, 1)

  (tmp_path / "not_inputs.hex").write_text("".join(f"{x:01x}\n" for x in inputs))

  out = iverilog(
    [HW / "sim/tb/tb_not.v", HW / "rtl/gates/hack_not.v", HW / "rtl/gates/hack_nand.v"],
    "tb_not",
    plusargs={"N": str(len(inputs))},
    cwd=tmp_path,
  )

  lines = out.split("\n")[:len(inputs)]

  for x, line in zip(inputs, lines, strict=True):
    want = ~x & 1
    assert line == f"{want}", x
