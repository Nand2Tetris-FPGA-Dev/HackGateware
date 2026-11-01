import random
import re
from collections import namedtuple
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
MODEL = HW / "third_party/psram_controller/sim/model"
WRITE_LAT = 34
MISS = 33  # word 0 of the burst is sampled at 32, then answered from the buffer
IDLE = 40  # a burst ends 65 cycles after its request, so after a miss this lets it finish
RTL = (HW / "rtl/progmem/progmem_psram.v").read_text()
BLOCKS = int(re.search(r"parameter BLOCKS = (\d+)", RTL).group(1))

pytestmark = pytest.mark.requires_iverilog

Fetch = namedtuple("Fetch", "addr data lat at")
Load = namedtuple("Load", "addr lat word")
Req = namedtuple("Req", "at we burst addr")
Run = namedtuple("Run", "fetches loads order reqs rsps")


def _op(op, delay=0, faddr=0, laddr=0, data=0, strb=0):
    return f"{op:x}{delay:02x}{faddr:04x}{laddr:04x}{data:08x}{strb:x}"


def fetch(addr):
    return _op(0, faddr=addr)


def load(addr, data, strb=0xF):
    return _op(1, laddr=addr, data=data, strb=strb)


def load_with_fetch(addr, data, faddr, delay):
    return _op(2, delay, faddr, addr, data, 0xF)


def fetch_then_reset(addr, delay):
    return _op(3, delay, faddr=addr)


def idle(cycles):
    return _op(4, faddr=cycles)


def load_in_reset(addr, data, delay):
    return _op(5, delay, laddr=addr, data=data, strb=0xF)


def fetch_then_load(faddr, addr, data, delay):
    return _op(6, delay, faddr, addr, data, 0xF)


def load_words(words, base=0):
    """Loads as boot_loader makes them: two words per load, strobe 0011 for an odd last word."""
    ops = []
    for k in range(0, len(words), 2):
        if k + 1 < len(words):
            ops.append(load(base + k, words[k + 1] << 16 | words[k]))
        else:
            ops.append(load(base + k, words[k], 0x3))
    return ops


def _run(tmp_path, ops, real=False, blocks=BLOCKS):
    (tmp_path / "ops.hex").write_text("\n".join(ops + ["f" + "0" * 19]) + "\n")
    sources = [HW / "sim/tb/tb_progmem_psram.v", HW / "rtl/progmem/progmem_psram.v"]
    if real:
        sources += [HW / "rtl/mem/psram_ctrl.v", MODEL / "w955d8mbya_die.sv",
                    MODEL / "w955d8mbya_model.sv"]
    else:
        sources += [HW / "sim/models/psram_host_model.v"]
    defines = {"BLOCKS": str(blocks)} | ({"REAL_CTRL": "1"} if real else {})
    out = iverilog(sources, "tb_progmem_psram", defines=defines, cwd=tmp_path)
    m = re.search(r"RESULT (.*)", out)
    assert m and "ERROR" not in out and "TIMEOUT" not in out and "FAIL" not in out, out
    result = {k: int(v) for k, v in (f.split("=") for f in m.group(1).split())}
    assert result["model_errors"] == 0, out
    assert result["readies"] == result["fetches"], out  # one fetch_ready pulse per fetch
    fetches = [Fetch(int(a, 16), int(d, 16), int(lat), int(at)) for a, d, lat, at
               in re.findall(r"FETCH addr=(\w+) data=(\w+) lat=(\d+) at=(\d+)", out)]
    loads = [Load(int(a, 16), int(lat), int(w, 16) if w else None)
             for a, lat, w in re.findall(r"LOAD addr=(\w+) lat=(\d+)(?: word=(\w+))?", out)]
    order = [(int(f), int(lo)) for f, lo in re.findall(r"ORDER fetch=(\d+) load=(\d+)", out)]
    reqs = [Req(int(at), int(we), int(b), int(a, 16)) for at, we, b, a
            in re.findall(r"REQ at=(\d+) we=(\d) burst=(\d) addr=(\w+)", out)]
    rsps = [int(at) for at in re.findall(r"RSP at=(\d+)", out)]
    return Run(fetches, loads, order, reqs, rsps)


def _reads(run):
    return [r for r in run.reqs if not r.we]


def _rsp_after(run, at):
    return min(t for t in run.rsps if t > at)


def _words(n, seed=1):
    rng = random.Random(seed)
    return [rng.randrange(0x10000) for _ in range(n)]


@pytest.mark.parametrize("real", [False, True], ids=["model", "psram_ctrl"])
def test_load_then_fetch(tmp_path, real):
    words = _words(64)
    order = list(range(64)) + random.Random(2).sample(range(64), 64)
    run = _run(tmp_path, load_words(words) + [fetch(a) for a in order], real)
    assert [(f.addr, f.data) for f in run.fetches] == [(a, words[a]) for a in order]
    # psram_ctrl and the model agree on the costs
    assert run.fetches[0].lat == MISS
    assert run.loads[-1].lat == WRITE_LAT
    assert all(r.burst for r in _reads(run))


def test_hit_is_same_cycle(tmp_path):
    words = _words(32)
    ops = load_words(words) + [fetch(4), idle(IDLE), fetch(5), fetch(4), fetch(6), fetch(31)]
    run = _run(tmp_path, ops)
    assert [f.lat for f in run.fetches] == [MISS, 0, 0, 0, 0]
    assert [f.data for f in run.fetches] == [words[a] for a in (4, 5, 4, 6, 31)]
    assert len(_reads(run)) == 1


@pytest.mark.parametrize("real", [False, True], ids=["model", "psram_ctrl"])
def test_stream_follows_burst(tmp_path, real):
    # Word 5 comes first, then 6..15, 0..4, one every 2 cycles. Each fetch is
    # answered as soon as its word is in, never before.
    words = _words(32, seed=9)
    order = [10] + list(range(11, 32)) + list(range(10))
    run = _run(tmp_path, load_words(words) + [fetch(a) for a in order], real)
    assert [(f.addr, f.data) for f in run.fetches] == [(a, words[a]) for a in order]
    t0 = run.fetches[0].at
    want = t0
    for f in run.fetches[1:]:
        want = max(want + 1, t0 + 2 * ((f.addr // 2 - 5) % 16))
        assert f.at == want, f
    assert len(_reads(run)) == 1


def test_word_not_yet_arrived(tmp_path):
    # Word 4 is last in the wrap order from word 5: the fetch waits for it
    words = _words(32, seed=10)
    run = _run(tmp_path, load_words(words) + [fetch(10), fetch(8)])
    assert [(f.addr, f.data) for f in run.fetches] == [(10, words[10]), (8, words[8])]
    assert run.fetches[1].at == run.fetches[0].at + 30
    assert len(_reads(run)) == 1


@pytest.mark.parametrize("real", [False, True], ids=["model", "psram_ctrl"])
def test_hit_other_slot_during_fill(tmp_path, real):
    # Block 0 is in. Hits to it while block 1 fills are still same-cycle.
    a, b = _words(32, seed=21), _words(32, seed=22)
    ops = load_words(a) + load_words(b, base=32)
    ops += [fetch(0), idle(IDLE), fetch(40), fetch(1), fetch(31), fetch(42), idle(IDLE)]
    run = _run(tmp_path, ops, real)
    assert [(f.addr, f.data) for f in run.fetches] == [
        (0, a[0]), (40, b[8]), (1, a[1]), (31, a[31]), (42, b[10])]
    assert [f.lat for f in run.fetches[2:4]] == [0, 0]
    second = _reads(run)[1]
    assert run.fetches[3].at < _rsp_after(run, second.at)
    assert len(_reads(run)) == 2


def test_miss_during_fill_waits_for_burst(tmp_path):
    a, b = _words(32, seed=11), _words(32, seed=12)
    run = _run(tmp_path, load_words(a) + load_words(b, base=96) + [fetch(10), fetch(100)])
    assert [(f.addr, f.data) for f in run.fetches] == [(10, a[10]), (100, b[4])]
    first, second = _reads(run)
    assert second.at > _rsp_after(run, first.at)
    assert run.fetches[1].at == second.at + MISS


@pytest.mark.parametrize("n", sorted({BLOCKS, 16}))
def test_all_blocks_then_round_robin(tmp_path, n):
    data = [0x1000 + b for b in range(n + 1)]
    ops = [load(32 * b, data[b]) for b in range(n + 1)]
    for b in range(n):
        ops += [fetch(32 * b), idle(IDLE)]
    ops += [fetch(32 * b) for b in range(n)]
    ops += [fetch(32 * n), idle(IDLE), fetch(32), fetch(0), idle(IDLE), fetch(32)]
    run = _run(tmp_path, ops, blocks=n)
    blocks = list(range(n)) * 2 + [n, 1, 0, 1]
    assert [(f.addr, f.data) for f in run.fetches] == [(32 * b, data[b]) for b in blocks]
    # Block n evicts slot 0 (block 0), and block 0 then evicts slot 1 (block 1)
    assert [f.lat for f in run.fetches] == [MISS] * n + [0] * n + [MISS, 0, MISS, MISS]


# Five tag bits per run, so base, its five far blocks and the top block fit in 8 slots
@pytest.mark.parametrize("bits", [range(5, 10), range(10, 15)], ids=["bits5-9", "bits10-14"])
def test_block_tag_uses_every_address_bit(tmp_path, bits):
    base = 0b010_1010_1010_1010
    near = [base ^ (1 << b) for b in range(5)]      # same block as base
    far = [base ^ (1 << b) for b in bits]           # one other block per tag bit
    words = _words(32, seed=13)
    top = _words(32, seed=14)                       # 32736-32767: every tag bit set
    ops = load_words(words, base & ~31) + load_words(top, 32736)
    for k, a in enumerate(far):
        ops.append(load(a & ~1, 0x9000 + k << 16 | 0x8000 + k))
    ops += [fetch(base), idle(IDLE)]
    for a in far:
        ops += [fetch(a), idle(IDLE)]
    ops += [fetch(a) for a in near]
    ops += [fetch(32767), idle(IDLE), fetch(32736), fetch(base)]
    run = _run(tmp_path, ops)
    want = [(base, words[base & 31])]
    want += [(a, 0x8000 + k) for k, a in enumerate(far)]
    want += [(a, words[a & 31]) for a in near]
    want += [(32767, top[31]), (32736, top[0]), (base, words[base & 31])]
    assert [(f.addr, f.data) for f in run.fetches] == want
    assert [f.lat for f in run.fetches] == [MISS] * (1 + len(far)) + [0] * 5 + [MISS, 0, 0]


def test_load_invalidates_all_blocks(tmp_path):
    old = _words(6, seed=3)
    ops = load_words(old[0:2]) + load_words(old[2:4], 32) + load_words(old[4:6], 64)
    for a in (0, 32, 64):
        ops += [fetch(a), idle(IDLE)]
    ops += [fetch(a) for a in (0, 32, 64)]
    ops.append(load(64, 0x0000BEEF, 0x3))
    for a in (0, 32, 64):
        ops += [fetch(a), idle(IDLE)]
    run = _run(tmp_path, ops)
    assert [f.data for f in run.fetches] == [old[0], old[2], old[4]] * 2 + [old[0], old[2], 0xBEEF]
    assert [f.lat for f in run.fetches] == [MISS] * 3 + [0] * 3 + [MISS] * 3


@pytest.mark.parametrize("real", [False, True], ids=["model", "psram_ctrl"])
def test_load_waits_for_burst(tmp_path, real):
    # The load comes 10 cycles into the burst for its own block. It waits for
    # the burst to end, and the block is read again after it.
    words = _words(32, seed=15)
    ops = load_words(words) + [fetch_then_load(10, 12, 0x12345678, 10), fetch(12), fetch(13)]
    run = _run(tmp_path, ops, real)
    assert [(f.addr, f.data) for f in run.fetches] == [(10, words[10]), (12, 0x5678),
                                                       (13, 0x1234)]
    assert [f.lat for f in run.fetches] == [MISS, MISS, 0]
    burst = _reads(run)[0]
    write, = [r for r in run.reqs if r.we and r.at > burst.at]
    assert write.at > _rsp_after(run, burst.at)


def test_hit_and_load_in_same_cycle(tmp_path):
    # The hit answers in its cycle and the load goes out a cycle later
    old = _words(4, seed=8)
    ops = load_words(old, base=20) + [fetch(20), idle(IDLE),
                                      load_with_fetch(22, 0x55556666, 21, 0), fetch(22)]
    run = _run(tmp_path, ops)
    assert [(f.addr, f.data, f.lat) for f in run.fetches] == [
        (20, old[0], MISS), (21, old[1], 0), (22, 0x6666, MISS)]
    assert run.loads[-1][1:] == (WRITE_LAT + 1, 0x55556666)


def test_load_ready_means_written(tmp_path):
    # Strobe 0011 writes the low word only
    ops = [load(6, 0xAAAA5555), load(6, 0x1234BEEF, 0x3), load(32766, 0xCAFEF00D)]
    run = _run(tmp_path, ops)
    assert [(lo.addr, lo.word) for lo in run.loads] == [
        (6, 0xAAAA5555), (6, 0xAAAABEEF), (32766, 0xCAFEF00D)]


def test_fetch_goes_before_load(tmp_path):
    # Load and fetch raised in the same cycle: the fetch reads first and gets the old word
    old = _words(2, seed=5)
    ops = load_words(old, base=20) + [load_with_fetch(20, 0x11112222, 21, 0)]
    run = _run(tmp_path, ops)
    assert [(f.addr, f.data, f.lat) for f in run.fetches] == [(21, old[1], MISS)]
    (t_fetch, t_load), = run.order
    assert t_fetch < t_load
    assert run.loads[-1].word == 0x11112222


def test_fetch_waits_behind_write_in_flight(tmp_path):
    # The write is already with the controller: the fetch waits and sees it
    old = _words(2, seed=6)
    ops = load_words(old, base=20) + [fetch(20), idle(IDLE),
                                      load_with_fetch(20, 0x33334444, 21, 2)]
    run = _run(tmp_path, ops)
    assert run.fetches[-1][:2] == (21, 0x3333)
    (t_fetch, t_load), = run.order
    assert t_fetch > t_load


def test_no_request_during_reset(tmp_path):
    # A load raised while progmem_psram is in reset waits for it to end
    run = _run(tmp_path, [idle(150), load_in_reset(8, 0x77778888, 4)])
    assert run.loads == [(8, 4 + WRITE_LAT, 0x77778888)]


@pytest.mark.parametrize("gap", [0, 100])
@pytest.mark.parametrize("reset_at", [10, 40, 50], ids=["word0", "burst40", "burst50"])
def test_reset_mid_read_drops_response(tmp_path, reset_at, gap):
    # The stale response must not answer the next fetch, and the dropped fetch
    # must not be read again. The reset clears the buffer, so the next fetch misses.
    words = _words(4, seed=7)
    ops = load_words(words) + [fetch_then_reset(0, reset_at), idle(gap), fetch(3), fetch(2)]
    run = _run(tmp_path, ops)
    assert [(f.addr, f.data) for f in run.fetches] == [(3, words[3]), (2, words[2])]
    assert run.fetches[0].lat >= MISS
