import math
import random
import re
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
MODEL = HW / "third_party/psram_controller/sim/model"
CTRL = [HW / "rtl/mem/psram_ctrl.v", MODEL / "w955d8mbya_die.sv", MODEL / "w955d8mbya_model.sv"]
READ, WRITE, ABORT = 0, 1, 2
LAST = 0x7FFFFC

pytestmark = pytest.mark.requires_iverilog


def _latency(we, clk_hz):
    # psram_controller docs/integration.md: 34 + R (read), 33 + R (write), R = tRWR in cycles
    r = math.ceil(36e-9 * clk_hz)
    return (33 if we else 34) + r


def _run(tmp_path, ops, clk_hz=27_000_000, pipe=False):
    lines = [f"{op:01x}{addr:06x}{data:08x}{strb:01x}" for op, addr, data, strb in ops]
    (tmp_path / "ops.hex").write_text("\n".join(lines + ["f" + "0" * 15]) + "\n")
    out = iverilog(
        [HW / "sim/tb/tb_psram_ctrl.v", *CTRL],
        "tb_psram_ctrl",
        plusargs={"PIPE": "1"} if pipe else None,
        defines={"CLK_HZ": str(clk_hz)},
        cwd=tmp_path,
    )
    m = re.search(r"RESULT (.*)", out)
    assert m and "ERROR" not in out and "FAIL" not in out, out
    result = dict(f.split("=") for f in m.group(1).split())
    assert result["errors"] == "0" and result["model_errors"] == "0", out
    rsps = re.findall(r"RSP we=(\d) addr=(\w+) data=(\w+) lat=(\d+)", out)
    accs = [int(c) for c in re.findall(r"ACC cycle=(\d+)", out)]
    init = int(re.search(r"INIT cycles=(\d+)", out).group(1))
    _check(ops, rsps, clk_hz, out)
    assert int(result["acc"]) == len(ops) and int(result["rsp"]) == len(rsps), out
    return accs, [int(lat) for *_, lat in rsps], init


def _check(ops, rsps, clk_hz, out):
    """Responses come in request order (aborted reads get none) and match a reference memory."""
    mem = {}
    expected = []
    for op, addr, data, strb in ops:
        if op == ABORT:
            continue
        if op == WRITE:
            mask = sum(0xFF << (8 * b) for b in range(4) if strb >> b & 1)
            assert mask == 0xFFFFFFFF or addr in mem, "partial write to an unwritten word"
            mem[addr] = (mem.get(addr, 0) & ~mask | data & mask) & 0xFFFFFFFF
        expected.append((op, addr, mem[addr] if op == READ else None))
    assert len(rsps) == len(expected), out
    for (op, addr, data), (we, raddr, rdata, lat) in zip(expected, rsps):
        assert int(we) == op and int(raddr, 16) == addr, out
        if data is not None:
            assert rdata == f"{data:08x}", f"read {addr:#08x}: got {rdata}, want {data:08x}"
        assert int(lat) == _latency(op == WRITE, clk_hz), out


def _w(addr, data, strb=0xF):
    return (WRITE, addr, data, strb)


def _r(addr):
    return (READ, addr, 0, 0)


def test_init(tmp_path):
    _, _, init = _run(tmp_path, [_w(0, 0x12345678), _r(0)])
    # W955D8MBYA tVCS >= 150 us before the first access
    assert 150e-6 <= init / 27e6 < 300e-6, init


def test_write_read_patterns(tmp_path):
    rng = random.Random(3)
    walk = [0] + [4 << k for k in range(21)] + [LAST]
    neighbors = [0x1000 + 4 * i for i in range(8)]
    rand = sorted({rng.randrange(0, 1 << 23, 4) for _ in range(256)} - set(walk) - set(neighbors))
    addrs = walk + neighbors + rand
    data = {a: rng.randrange(1 << 32) for a in addrs}
    _run(tmp_path, [_w(a, data[a]) for a in addrs] + [_r(a) for a in addrs])


def test_write_strobes(tmp_path):
    ops = []
    for s in range(16):
        a = 0x2000 + 4 * s
        ops += [_w(a, 0x11223344), _w(a, 0xAABBCCDD, s), _r(a)]
    _run(tmp_path, ops)


def test_back_to_back(tmp_path):
    ops = []
    for i in range(8):
        a = 0x3000 + 4 * i
        ops += [_w(a, 0x0F0F0000 + i), _r(a), _w(a, 0xF0F00000 + i), _r(a)]
    accs, lats, _ = _run(tmp_path, ops, pipe=True)
    # each held request is accepted in the response cycle of the one before
    assert [b - a for a, b in zip(accs, accs[1:])] == lats[:-1]


def test_handshake(tmp_path):
    # first request held through init; inputs scrambled after every accept
    ops = [_w(0x4000, 0xAAAA5555), _r(0x4000), _w(0x4004, 0x12345678), _r(0x4004), _r(0x4000)]
    accs, _, init = _run(tmp_path, ops)
    assert accs[0] >= init


@pytest.mark.parametrize("clk_hz", [27_000_000, 18_000_000])
def test_latency(tmp_path, clk_hz):
    _, lats, _ = _run(tmp_path, [_w(0x6000, 0x01020304), _r(0x6000)], clk_hz=clk_hz)
    assert lats == [34, 35]


@pytest.mark.parametrize("abort_at", [10, 30])
def test_reset_during_access(tmp_path, abort_at):
    ops = [_w(0x4000, 0x11111111), (ABORT, 0x4000, abort_at, 0), _w(0x4008, 0x33333333), _r(0x4008)]
    _run(tmp_path, ops)


def _spike(tmp_path, corrupt=False):
    out = iverilog(
        [HW / "sim/tb/tb_psram_spike.v", HW / "spikes/psram_test/top.v", HW / "rtl/top/reset_sync.v", *CTRL],
        "tb_psram_spike",
        plusargs={"CORRUPT": "1"} if corrupt else None,
        cwd=tmp_path,
    )
    assert "ERROR" not in out and "TIMEOUT" not in out and "MODEL errors=0" in out, out
    return out


def test_psram_spike_passes(tmp_path):
    out = _spike(tmp_path)
    assert "LEDS pass=1 done=1 fail=0" in out and "LATENCY 35" in out, out


def test_psram_spike_reports_mismatch(tmp_path):
    out = _spike(tmp_path, corrupt=True)
    assert "LEDS pass=0 done=1 fail=1" in out, out
