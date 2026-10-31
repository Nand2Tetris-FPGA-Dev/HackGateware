from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
SIZE = 262144
BUF = bytes((i * 13 + 7) & 0xFF for i in range(256))


def _run(tmp_path, ops, fill, dump, plusargs=None):
    (tmp_path / "flash.hex").write_text("".join(f"{b:02x}\n" for b in fill))
    (tmp_path / "buf.hex").write_text("".join(f"{b:02x}\n" for b in BUF))
    (tmp_path / "ops.txt").write_text("".join(f"{o} {a:06x} {n}\n" for o, a, n in ops))
    args = {"DUMP": f"{dump[0]:x},{dump[1]:x}"}
    args.update(plusargs or {})
    out = iverilog(
        [
            HW / "sim/tb/tb_spi_flash_writer.v",
            HW / "sim/models/spi_flash_model.v",
            HW / "rtl/io/spi_flash_writer.v",
        ],
        "tb_spi_flash_writer",
        plusargs=args,
        cwd=tmp_path,
    )
    mem = {}
    for line in out.splitlines():
        if line.startswith("DUMP "):
            _, a, data = line.split()
            for i, b in enumerate(bytes.fromhex(data)):
                mem[int(a, 16) + i] = b
    assert len(mem) == dump[1], out
    return out, mem


def _check(mem, expect, lo, n):
    bad = [a for a in range(lo, lo + n) if mem[a] != expect[a]]
    assert not bad, f"{len(bad)} bytes differ, first at {bad[0]:06x}: {mem[bad[0]]:02x}"


@pytest.mark.requires_iverilog
def test_model_ignores_write_without_wren(tmp_path):
    fill = bytes([0xFF]) * SIZE
    out, mem = _run(tmp_path, [(9, 0x100, 4)], fill, (0x100, 4))
    assert "IGNORED 02" in out and "PASS" in out, out
    assert all(mem[0x100 + i] == 0xFF for i in range(4)), out


@pytest.mark.requires_iverilog
def test_erase_4k(tmp_path):
    fill = bytes(SIZE)
    out, mem = _run(tmp_path, [(0, 0x1000, 0)], fill, (0x0FFF, 0x1002))
    assert "PASS" in out and "IGNORED" not in out, out
    expect = bytearray(fill)
    expect[0x1000:0x2000] = b"\xff" * 0x1000
    _check(mem, expect, 0x0FFF, 0x1002)


@pytest.mark.requires_iverilog
def test_erase_any_address_in_sector(tmp_path):
    # P25Q32H s10.28: any address inside the sector selects it
    fill = bytes(SIZE)
    out, mem = _run(tmp_path, [(0, 0x1234, 0)], fill, (0x0FFF, 0x1002))
    assert "PASS" in out and "IGNORED" not in out, out
    expect = bytearray(fill)
    expect[0x1000:0x2000] = b"\xff" * 0x1000
    _check(mem, expect, 0x0FFF, 0x1002)


@pytest.mark.requires_iverilog
def test_erase_64k(tmp_path):
    fill = bytes(SIZE)
    out, mem = _run(tmp_path, [(1, 0x20000, 0)], fill, (0x1FFFF, 0x10002))
    assert "PASS" in out and "IGNORED" not in out, out
    expect = bytearray(fill)
    expect[0x20000:0x30000] = b"\xff" * 0x10000
    _check(mem, expect, 0x1FFFF, 0x10002)


@pytest.mark.requires_iverilog
def test_program_page(tmp_path):
    fill = bytes([0xFF]) * SIZE
    out, mem = _run(tmp_path, [(2, 0x20100, 256)], fill, (0x200FF, 258))
    assert "PASS" in out and "IGNORED" not in out, out
    expect = bytearray(fill)
    expect[0x20100:0x20200] = BUF
    _check(mem, expect, 0x200FF, 258)


@pytest.mark.requires_iverilog
def test_program_partial(tmp_path):
    fill = bytes([0xFF]) * SIZE
    out, mem = _run(tmp_path, [(2, 0x200E0, 32)], fill, (0x20000, 0x200))
    assert "PASS" in out and "IGNORED" not in out, out
    expect = bytearray(fill)
    expect[0x200E0:0x20100] = BUF[:32]
    _check(mem, expect, 0x20000, 0x200)


@pytest.mark.requires_iverilog
def test_done_waits_for_wip(tmp_path):
    fill = bytes(SIZE)
    out, _ = _run(tmp_path, [(0, 0x1000, 0)], fill, (0x1000, 1), {"ERASE_US": "300"})
    assert "PASS" in out, out
    polls = int(out.split("rdsr=")[1].split()[0])
    # one poll takes about 2.5 us, so 300 us of WIP needs many
    assert polls > 10, out


@pytest.mark.requires_iverilog
def test_wren_before_each_op(tmp_path):
    fill = bytes(SIZE)
    ops = [(0, 0x1000, 0), (2, 0x1000, 256), (2, 0x1100, 32)]
    out, mem = _run(tmp_path, ops, fill, (0x1000, 0x1000))
    assert "PASS" in out and "IGNORED" not in out and "BUSY" not in out, out
    expect = bytearray(fill)
    expect[0x1000:0x2000] = b"\xff" * 0x1000
    expect[0x1000:0x1100] = BUF
    expect[0x1100:0x1120] = BUF[:32]
    _check(mem, expect, 0x1000, 0x1000)
