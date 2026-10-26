import json
import subprocess
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.requires_iverilog


def test_progmem_rom_reads(tmp_path):
    (tmp_path / "rom16.hex").write_text("".join(f"{0xA000 + i:04x}\n" for i in range(16)))
    out = iverilog(
        [HW / "sim/tb/tb_progmem_rom.v", HW / "rtl/progmem/progmem_rom.v"],
        "tb_progmem_rom",
        defines={"ROM_HEX": '"rom16.hex"'},
        cwd=tmp_path,
    )
    assert "PASS" in out, out


@pytest.mark.requires_yosys
def test_rom_contents_survive_synthesis(tmp_path):
    hex_file = tmp_path / "rom.hex"
    hex_file.write_text("".join(f"{0xA000 + i:04x}\n" for i in range(16)))
    (tmp_path / "rom_path.vh").write_text(f'`define ROM_HEX "{hex_file.as_posix()}"\n')
    netlist = tmp_path / "rom.json"
    result = subprocess.run(
        ["yosys", "-q", "-p",
         f"read_verilog -sv -I{tmp_path.as_posix()} {(HW / 'rtl/progmem/progmem_rom.v').as_posix()}; "
         f"synth_gowin -top progmem_rom -json {netlist.as_posix()}"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    cells = json.loads(netlist.read_text())["modules"]["progmem_rom"]["cells"].values()
    init_rows = [v for c in cells for k, v in c["parameters"].items() if k.startswith("INIT_RAM")]
    assert init_rows, "ROM didn't map to block RAM"
    assert any(set(row) - {"0"} for row in init_rows), "ROM contents were lost in synthesis"


def test_reset_sync_debounce():
    out = iverilog([HW / "sim/tb/tb_reset_sync.v", HW / "rtl/top/reset_sync.v"], "tb_reset_sync")
    assert "PASS" in out, out
