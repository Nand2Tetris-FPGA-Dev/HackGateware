import zlib
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
SIZE = 262144
DATA = bytes((i * 13 + 7) & 0xFF for i in range(512)) + bytes(range(256)) * 14
BEGIN, ERASE, DATA_OP, PROGRAM, CRC, END, IDLE = 1, 2, 3, 4, 5, 6, 7
OK, NO_SESSION, BAD_ARG, DATA_COUNT = 0, 1, 2, 3


def _run(tmp_path, cmds, fill=None, dump=None, plusargs=None, timeout=None):
    fill = fill if fill is not None else bytes([0xFF]) * SIZE
    (tmp_path / "flash.hex").write_text("".join(f"{b:02x}\n" for b in fill))
    (tmp_path / "data.hex").write_text("".join(f"{b:02x}\n" for b in DATA))
    (tmp_path / "cmds.txt").write_text("".join(f"{o} {a:x} {n}\n" for o, a, n in cmds))
    args = dict(plusargs or {})
    if dump:
        args["DUMP"] = f"{dump[0]:x},{dump[1]:x}"
    out = iverilog(
        [
            HW / "sim/tb/tb_flash_session.v",
            HW / "sim/models/spi_flash_model.v",
            HW / "rtl/io/flash_session.v",
            HW / "rtl/io/spi_flash_writer.v",
            HW / "rtl/io/spi_flash_reader.v",
        ],
        "tb_flash_session",
        plusargs=args,
        defines={"TIMEOUT": str(timeout)} if timeout else None,
        cwd=tmp_path,
    )
    assert "PASS" in out, out
    for bad in ("NORSP", "IGNORED", "BUSY", "REJECTED", "ERROR"):
        assert bad not in out, out
    mem = {}
    for line in out.splitlines():
        if line.startswith("DUMP "):
            _, a, data = line.split()
            for i, b in enumerate(bytes.fromhex(data)):
                mem[int(a, 16) + i] = b
    return out, mem


def _rsps(out):
    """[(op, status, crc, cycle, session)] in order."""
    rows = []
    for line in out.splitlines():
        if line.startswith("RSP "):
            op, st, crc, cyc, ses = line.split()[1:]
            rows.append((int(op), int(st), int(crc, 16), int(cyc), int(ses)))
    return rows


def _lines(out, prefix):
    return [line for line in out.splitlines() if line.startswith(prefix)]


def _ends(out):
    return [int(line.split()[1]) for line in _lines(out, "SESSION_END ")]


@pytest.mark.requires_iverilog
def test_outside_session_refused(tmp_path):
    fill = bytes(range(256)) * (SIZE // 256)
    cmds = [
        (ERASE, 0x20000, 1),
        (DATA_OP, 0, 256),
        (PROGRAM, 0x20000, 256),
        (CRC, 0x20000, 256),
        (END, 0, 0),
    ]
    out, mem = _run(tmp_path, cmds, fill, dump=(0x20000, 0x100))
    assert [r[:2] for r in _rsps(out)] == [(op, NO_SESSION) for op in (2, 4, 5, 6)], out
    assert not _lines(out, "WR ") and not _lines(out, "RD ") and not _ends(out), out
    assert bytes(mem[0x20000 + i] for i in range(256)) == fill[0x20000:0x20100]


@pytest.mark.requires_iverilog
def test_begin_erase_program_crc(tmp_path):
    fill = bytes(SIZE)
    cmds = [
        (BEGIN, 0, 0),
        (ERASE, 0x20000, 1),
        (DATA_OP, 0, 256),
        (PROGRAM, 0x20000, 256),
        (DATA_OP, 0x100, 256),
        (PROGRAM, 0x20100, 256),
        (CRC, 0x20000, 0x300),
    ]
    out, mem = _run(tmp_path, cmds, fill, dump=(0x1FFFF, 0x302))
    rsps = _rsps(out)
    assert [r[:2] for r in rsps] == [(1, OK), (2, OK), (4, OK), (4, OK), (5, OK)], out
    assert all(r[4] == 1 for r in rsps), out
    assert _lines(out, "WR ") == ["WR 1 020000 0", "WR 2 020000 256", "WR 2 020100 256"]
    expect = DATA[:512] + b"\xff" * 0x100
    assert rsps[-1][2] == zlib.crc32(expect), out
    assert bytes(mem[0x20000 + i] for i in range(0x300)) == expect
    assert mem[0x1FFFF] == 0 and mem[0x20300] == 0xFF


@pytest.mark.requires_iverilog
def test_crc_partial_range(tmp_path):
    fill = bytes((i * 7) & 0xFF for i in range(SIZE))
    out, _ = _run(tmp_path, [(BEGIN, 0, 0), (CRC, 0x123, 5)], fill)
    rsps = _rsps(out)
    assert rsps[-1][:2] == (5, OK) and rsps[-1][2] == zlib.crc32(fill[0x123:0x128]), out
    assert _lines(out, "RD ") == ["RD 000123"], out


@pytest.mark.requires_iverilog
def test_program_count_mismatch(tmp_path):
    cmds = [
        (BEGIN, 0, 0),
        (DATA_OP, 0, 224),
        (PROGRAM, 0x20000, 256),
        (DATA_OP, 0, 256),
        (PROGRAM, 0x20000, 256),
        (CRC, 0x20000, 256),
    ]
    out, mem = _run(tmp_path, cmds, dump=(0x20000, 0x100))
    rsps = _rsps(out)
    assert [r[:2] for r in rsps] == [(1, OK), (4, DATA_COUNT), (4, OK), (5, OK)], out
    assert _lines(out, "WR ") == ["WR 2 020000 256"], out
    assert rsps[-1][2] == zlib.crc32(DATA[:256]), out


@pytest.mark.requires_iverilog
def test_bad_args(tmp_path):
    fill = bytes(range(256)) * (SIZE // 256)
    cmds = [
        (BEGIN, 0, 0),
        (ERASE, 0x1800, 0),  # not 4 KB aligned
        (ERASE, 0x8000, 1),  # not 64 KB aligned
        (ERASE, 0x10000, 2),  # no such size
        (ERASE, 0x400000, 1),  # past the 4 MB flash
        (PROGRAM, 0x20000, 0),
        (DATA_OP, 0, 256),
        (DATA_OP, 0, 1),
        (PROGRAM, 0x20000, 257),
        (DATA_OP, 0, 256),
        (PROGRAM, 0x20080, 256),  # crosses a page
        (DATA_OP, 0, 1),
        (PROGRAM, 0x400000, 1),  # past the 4 MB flash
        (CRC, 0x20000, 0),
        (CRC, 0x3FFFFF, 2),  # past the 4 MB flash
        # the edges that are allowed
        (CRC, 0x3FFFFF, 1),
        (DATA_OP, 0xFF, 1),
        (PROGRAM, 0x200FF, 1),
    ]
    out, _ = _run(tmp_path, cmds, fill)
    sts = [r[:2] for r in _rsps(out)]
    assert sts == [(1, OK)] + [(2, BAD_ARG)] * 4 + [(4, BAD_ARG)] * 4 + [(5, BAD_ARG)] * 2 + [
        (5, OK),
        (4, OK),
    ], out
    assert _lines(out, "WR ") == ["WR 2 0200ff 1"], out


@pytest.mark.requires_iverilog
def test_end_pulses_session_end(tmp_path):
    out, _ = _run(tmp_path, [(BEGIN, 0, 0), (END, 0, 0), (IDLE, 100, 0), (END, 0, 0)])
    rsps = _rsps(out)
    assert [r[:2] for r in rsps] == [(1, OK), (6, OK), (6, NO_SESSION)], out
    ends = _ends(out)
    assert len(ends) == 1 and rsps[1][3] - 1 <= ends[0] <= rsps[1][3] + 2, out


@pytest.mark.requires_iverilog
def test_begin_stops_the_reader(tmp_path):
    # In a session the reader's inputs come from here, so the loader's own stop
    # can't end a read it left running; BEGIN has to.
    out, _ = _run(tmp_path, [(IDLE, 0x10, 0), (BEGIN, 0, 0), (IDLE, 0x10, 0)])
    stops = [int(line.split()[1]) for line in _lines(out, "RD_STOP ")]
    assert stops == [_rsps(out)[0][3] + 1], out


@pytest.mark.requires_iverilog
def test_timeout_ends_session(tmp_path):
    out, _ = _run(tmp_path, [(BEGIN, 0, 0), (IDLE, 0x2710, 0)], timeout=5000)
    begin = _rsps(out)[0][3]
    ends = _ends(out)
    assert len(ends) == 1 and 4990 <= ends[0] - begin <= 5010, out


@pytest.mark.requires_iverilog
def test_timeout_restarts_on_data(tmp_path):
    cmds = [(BEGIN, 0, 0), (IDLE, 0xFA0, 0), (DATA_OP, 0, 1), (IDLE, 0xFA0, 0)]
    out, _ = _run(tmp_path, cmds, timeout=5000)
    assert not _ends(out), out


@pytest.mark.requires_iverilog
def test_timeout_paused_while_busy(tmp_path):
    # 800 us of WIP is about 21600 cycles, far past the 5000-cycle timeout
    cmds = [(BEGIN, 0, 0), (ERASE, 0x20000, 0), (IDLE, 0x2710, 0)]
    out, _ = _run(tmp_path, cmds, plusargs={"ERASE_US": "800"}, timeout=5000)
    rsps = _rsps(out)
    assert [r[:2] for r in rsps] == [(1, OK), (2, OK)] and rsps[1][4] == 1, out
    assert rsps[1][3] - rsps[0][3] > 20000, out
    ends = _ends(out)
    assert len(ends) == 1 and 4990 <= ends[0] - rsps[1][3] <= 5010, out
