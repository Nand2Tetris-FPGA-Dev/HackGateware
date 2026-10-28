from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]


@pytest.mark.requires_iverilog
def test_reads_with_backpressure(tmp_path):
    (tmp_path / "flash.hex").write_text("".join(f"{(a * 7 + 3) & 0xFF:02x}\n" for a in range(262144)))
    out = iverilog(
        [
            HW / "sim/tb/tb_spi_flash_reader.v",
            HW / "sim/models/spi_flash_model.v",
            HW / "rtl/io/spi_flash_reader.v",
        ],
        "tb_spi_flash_reader",
        cwd=tmp_path,
    )
    assert "PASS" in out and "ERROR" not in out, out


def _spike(tmp_path, pattern, press=False):
    image = bytearray(b"\xff" * 262144)
    image[0x20000:0x20000 + len(pattern)] = pattern
    (tmp_path / "flash.hex").write_text("".join(f"{b:02x}\n" for b in image))
    return iverilog(
        [
            HW / "sim/tb/tb_flash_spike.v",
            HW / "sim/models/spi_flash_model.v",
            HW / "spikes/flash_read/top.v",
            HW / "rtl/io/spi_flash_reader.v",
            HW / "rtl/top/reset_sync.v",
        ],
        "tb_flash_spike",
        plusargs={"PRESS": "1"} if press else None,
        cwd=tmp_path,
    )


@pytest.mark.requires_iverilog
def test_flash_spike_matches(tmp_path):
    out = _spike(tmp_path, bytes(0xA0 + i for i in range(16)))
    assert "LEDS match=1 done=1 mismatch=0" in out, out


@pytest.mark.requires_iverilog
def test_flash_spike_s1_rereads(tmp_path):
    out = _spike(tmp_path, bytes(0xA0 + i for i in range(16)), press=True)
    assert "FIRST match=1 done=1 mismatch=0" in out, out
    assert "LEDS match=0 done=1 mismatch=1" in out, out


@pytest.mark.requires_iverilog
def test_flash_spike_mismatch(tmp_path):
    out = _spike(tmp_path, bytes(0xA0 + i for i in range(15)) + b"\x00")
    assert "LEDS match=0 done=1 mismatch=1" in out, out
