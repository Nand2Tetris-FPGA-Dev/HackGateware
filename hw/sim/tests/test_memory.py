import re
import subprocess
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
MEM_SOURCES = [HW / "rtl/mem/ram16k.v", HW / "rtl/mem/screen_mem.v", HW / "rtl/mem/hack_memory.v"]


@pytest.fixture(scope="module")
def sim_output():
    return iverilog([HW / "sim/tb/tb_memory.v", *MEM_SOURCES], "tb_memory")


@pytest.mark.requires_iverilog
def test_ram_and_screen(sim_output):
    assert "PASS ram_and_screen" in sim_output, sim_output


@pytest.mark.requires_iverilog
def test_keyboard_read(sim_output):
    assert "PASS keyboard" in sim_output, sim_output


@pytest.mark.requires_iverilog
def test_unmapped_writes_ignored(sim_output):
    assert "PASS unmapped" in sim_output, sim_output


@pytest.mark.requires_yosys
def test_memory_infers_bsram():
    files = " ".join(p.as_posix() for p in MEM_SOURCES)
    result = subprocess.run(
        ["yosys", "-p", f"read_verilog {files}; synth_gowin -top hack_memory; stat"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    stats = result.stdout.split("Printing statistics")[-1]
    cells = {name: int(n) for n, name in re.findall(r"^\s+(\d+)\s+(\S+)\s*$", stats, re.M)}
    bsram = sum(n for name, n in cells.items() if name in {"SP", "SPX9", "SDPB", "DPB", "DPX9B"})
    assert bsram >= 24, cells
    assert not any(name.startswith("RAM16S") for name in cells), cells
