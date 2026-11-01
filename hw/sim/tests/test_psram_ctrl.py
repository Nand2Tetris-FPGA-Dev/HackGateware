import math
import random
import re
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
MODEL = HW / "third_party/psram_controller/sim/model"
CTRL = [HW / "rtl/mem/psram_ctrl.v", MODEL / "w955d8mbya_die.sv", MODEL / "w955d8mbya_model.sv"]
READ, WRITE, ABORT, BURST, BURST_ABORT = 0, 1, 2, 3, 4
LAST = 0x7FFFFC
GROUP = 16  # 32-bit words per wrapped burst: 32 bytes per die (W955D8MBYA CR0[1:0] default)

pytestmark = pytest.mark.requires_iverilog


def _latency(we, clk_hz):
    # psram_controller docs/integration.md: 34 + R (read), 33 + R (write), R = tRWR in cycles
    r = math.ceil(36e-9 * clk_hz)
    return (33 if we else 34) + r


def _burst_latency(clk_hz):
    """(word strobe lats, rsp_valid lat). Each word is handed over when its high half is
    sampled, 3 cycles before a single read's rsp_valid; one 32-bit word per CK = 2 cycles."""
    first = _latency(False, clk_hz) - 3
    return [first + 2 * k for k in range(GROUP)], _latency(False, clk_hz) + 2 * (GROUP - 1)


def _group(addr):
    """Byte addresses of a wrapped burst from addr, in arrival order."""
    base, start = addr & ~(4 * GROUP - 1), (addr >> 2) % GROUP
    return [base + 4 * ((start + k) % GROUP) for k in range(GROUP)]


def _run(tmp_path, ops, clk_hz=27_000_000, pipe=False, host_model=False):
    lines = [f"{op:01x}{addr:06x}{data:08x}{strb:01x}" for op, addr, data, strb in ops]
    (tmp_path / "ops.hex").write_text("\n".join(lines + ["f" + "0" * 15]) + "\n")
    defines = {"CLK_HZ": str(clk_hz)}
    if host_model:
        defines["HOST_MODEL"] = "1"
        sources = [HW / "sim/tb/tb_psram_ctrl.v", HW / "sim/models/psram_host_model.v"]
    else:
        sources = [HW / "sim/tb/tb_psram_ctrl.v", *CTRL]
    out = iverilog(
        sources,
        "tb_psram_ctrl",
        plusargs={"PIPE": "1"} if pipe else None,
        defines=defines,
        cwd=tmp_path,
    )
    m = re.search(r"RESULT (.*)", out)
    assert m and "ERROR" not in out and "FAIL" not in out, out
    result = dict(f.split("=") for f in m.group(1).split())
    assert result["errors"] == "0" and result["model_errors"] == "0", out
    rsps = re.findall(r"RSP req=(\d+) we=(\d) burst=(\d) addr=(\w+) data=(\w+) lat=(\d+)", out)
    words = re.findall(r"WORD req=(\d+) k=(\d+) addr=(\w+) data=(\w+) lat=(\d+)", out)
    accs = [int(c) for c in re.findall(r"ACC cycle=(\d+)", out)]
    init = int(re.search(r"INIT cycles=(\d+)", out).group(1))
    _check(ops, rsps, words, clk_hz, out)
    assert int(result["acc"]) == len(ops) and int(result["rsp"]) == len(rsps), out
    return accs, [int(r[-1]) for r in rsps], init, words


def _check(ops, rsps, words, clk_hz, out):
    """Responses come in request order (aborted requests get none) and match a reference
    memory. A burst gives GROUP words in wrap order, then its response."""
    mem = {}
    by_req = {}
    for req, k, addr, data, lat in words:
        by_req.setdefault(int(req), []).append((int(k), int(addr, 16), data, int(lat)))
    word_lats, burst_lat = _burst_latency(clk_hz)
    n_rsp = 0
    for n, (op, addr, data, strb) in enumerate(ops):
        if op == WRITE:
            mask = sum(0xFF << (8 * b) for b in range(4) if strb >> b & 1)
            assert mask == 0xFFFFFFFF or addr in mem, "partial write to an unwritten word"
            mem[addr] = (mem.get(addr, 0) & ~mask | data & mask) & 0xFFFFFFFF
        got = by_req.get(n, [])
        if op in (BURST, BURST_ABORT):
            if op == BURST:
                assert len(got) == GROUP, out
            for (k, waddr, wdata, lat), want_addr in zip(got, _group(addr)):
                assert waddr == want_addr, out
                if want_addr in mem:
                    want = f"{mem[want_addr]:08x}"
                    assert wdata == want, f"burst {addr:#08x} word {k}: got {wdata}, want {want}"
                assert lat == word_lats[k], out
        else:
            assert not got, out
        if op in (ABORT, BURST_ABORT):
            continue
        req, we, burst, raddr, rdata, lat = rsps[n_rsp]
        n_rsp += 1
        assert int(req) == n and int(we) == (op == WRITE) and int(burst) == (op == BURST), out
        assert int(raddr, 16) == addr, out
        if op == READ:
            want = f"{mem[addr]:08x}"
            assert rdata == want, f"read {addr:#08x}: got {rdata}, want {want}"
        assert int(lat) == (burst_lat if op == BURST else _latency(op == WRITE, clk_hz)), out
    assert n_rsp == len(rsps), out


def _w(addr, data, strb=0xF):
    return (WRITE, addr, data, strb)


def _r(addr):
    return (READ, addr, 0, 0)


def _b(addr):
    return (BURST, addr, 0, 0)


def test_init(tmp_path):
    _, _, init, _ = _run(tmp_path, [_w(0, 0x12345678), _r(0)])
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
    accs, lats, _, _ = _run(tmp_path, ops, pipe=True)
    # each held request is accepted in the response cycle of the one before
    assert [b - a for a, b in zip(accs, accs[1:])] == lats[:-1]


def test_handshake(tmp_path):
    # first request held through init; inputs scrambled after every accept
    ops = [_w(0x4000, 0xAAAA5555), _r(0x4000), _w(0x4004, 0x12345678), _r(0x4004), _r(0x4000)]
    accs, _, init, _ = _run(tmp_path, ops)
    assert accs[0] >= init


@pytest.mark.parametrize("clk_hz", [27_000_000, 18_000_000])
def test_latency(tmp_path, clk_hz):
    _, lats, _, _ = _run(tmp_path, [_w(0x6000, 0x01020304), _r(0x6000)], clk_hz=clk_hz)
    assert lats == [34, 35]


GROUP_BASE = 0x8000
GROUP_DATA = [0xA5000000 + 0x010101 * k for k in range(GROUP)]


def _fill_group(base=GROUP_BASE, data=GROUP_DATA):
    return [_w(base + 4 * k, d) for k, d in enumerate(data)]


def test_burst_wrap_order(tmp_path):
    # Wrapped burst, W955D8MBYA sec. 9.4.1: requested word first, wraps in the 32-byte group
    ops = _fill_group() + [_b(GROUP_BASE + 4 * s) for s in range(GROUP)]
    _, _, _, words = _run(tmp_path, ops)
    assert len(words) == GROUP * GROUP


@pytest.mark.parametrize("clk_hz", [27_000_000, 18_000_000])
def test_burst_latency(tmp_path, clk_hz):
    _, lats, _, words = _run(tmp_path, _fill_group() + [_b(GROUP_BASE + 20)], clk_hz=clk_hz)
    assert [int(w[-1]) for w in words] == [32 + 2 * k for k in range(GROUP)]
    assert lats[-1] == 65


def test_burst_mixed(tmp_path):
    ops = _fill_group() + [
        _b(GROUP_BASE + 8), _w(GROUP_BASE + 12, 0x12121212), _b(GROUP_BASE + 60),
        _w(GROUP_BASE + 60, 0x0000FFFF, 0x3), _r(GROUP_BASE + 60), _b(GROUP_BASE),
    ]
    accs, lats, _, _ = _run(tmp_path, ops, pipe=True)
    assert [b - a for a, b in zip(accs, accs[1:])] == lats[:-1]


def test_burst_top_group(tmp_path):
    top = 0x800000 - 4 * GROUP
    data = [0x5A000000 + k for k in range(GROUP)]
    _, _, _, words = _run(tmp_path, _fill_group(top, data) + [_b(LAST)])
    assert [int(w[2], 16) for w in words] == [LAST] + [top + 4 * k for k in range(GROUP - 1)]


@pytest.mark.parametrize("abort_at", [20, 45])
def test_reset_during_burst(tmp_path, abort_at):
    ops = _fill_group() + [
        (BURST_ABORT, GROUP_BASE + 16, abort_at, 0),
        _w(GROUP_BASE + 16, 0x77777777), _b(GROUP_BASE + 4),
    ]
    _run(tmp_path, ops)


def test_host_model_matches_ctrl(tmp_path):
    ops = _fill_group() + [
        _r(GROUP_BASE + 4), _b(GROUP_BASE), _b(GROUP_BASE + 36),
        _w(GROUP_BASE + 44, 0xCAFE0000, 0xC), _b(GROUP_BASE + 60), _r(GROUP_BASE + 44),
    ]
    (tmp_path / "ctrl").mkdir()
    (tmp_path / "model").mkdir()
    _, lats_c, _, words_c = _run(tmp_path / "ctrl", ops)
    _, lats_m, _, words_m = _run(tmp_path / "model", ops, host_model=True)
    assert lats_m == lats_c
    assert words_m == words_c


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
