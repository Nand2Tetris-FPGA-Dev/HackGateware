import random
import re
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
MODEL = HW / "third_party/psram_controller/sim/model"
READ_LAT, WRITE_LAT = 35, 34
MISS = READ_LAT + 1  # the read, then the fetch_ready register

pytestmark = pytest.mark.requires_iverilog


def fetch(addr):
    return f"00{addr:04x}{0:04x}{0:08x}0"


def load(addr, data, strb=0xF):
    return f"10{0:04x}{addr:04x}{data:08x}{strb:x}"


def load_with_fetch(addr, data, faddr, delay):
    return f"2{delay:x}{faddr:04x}{addr:04x}{data:08x}f"


def fetch_then_reset(addr, delay):
    return f"3{delay:x}{addr:04x}{0:04x}{0:08x}0"


def load_in_reset(addr, data, delay):
    return f"5{delay:x}{0:04x}{addr:04x}{data:08x}f"


def idle(cycles):
    return f"40{cycles:04x}{0:04x}{0:08x}0"


def load_words(words, base=0):
    """Loads as boot_loader makes them: two words per load, strobe 0011 for an odd last word."""
    ops = []
    for k in range(0, len(words), 2):
        if k + 1 < len(words):
            ops.append(load(base + k, words[k + 1] << 16 | words[k]))
        else:
            ops.append(load(base + k, words[k], 0x3))
    return ops


def _run(tmp_path, ops, real=False):
    (tmp_path / "ops.hex").write_text("\n".join(ops + ["f" + "0" * 18]) + "\n")
    sources = [HW / "sim/tb/tb_progmem_psram.v", HW / "rtl/progmem/progmem_psram.v"]
    if real:
        sources += [HW / "rtl/mem/psram_ctrl.v", MODEL / "w955d8mbya_die.sv",
                    MODEL / "w955d8mbya_model.sv"]
    else:
        sources += [HW / "sim/models/psram_host_model.v"]
    out = iverilog(sources, "tb_progmem_psram", defines={"REAL_CTRL": "1"} if real else None,
                   cwd=tmp_path)
    m = re.search(r"RESULT (.*)", out)
    assert m and "ERROR" not in out and "TIMEOUT" not in out and "FAIL" not in out, out
    result = {k: int(v) for k, v in (f.split("=") for f in m.group(1).split())}
    assert result["model_errors"] == 0, out
    assert result["readies"] == result["fetches"], out  # one fetch_ready pulse per fetch
    fetches = [(int(a, 16), int(d, 16), int(lat))
               for a, d, lat in re.findall(r"FETCH addr=(\w+) data=(\w+) lat=(\d+)", out)]
    loads = [(int(a, 16), int(lat), int(w, 16) if w else None)
             for a, lat, w in re.findall(r"LOAD addr=(\w+) lat=(\d+)(?: word=(\w+))?", out)]
    order = [(int(f), int(lo)) for f, lo in re.findall(r"ORDER fetch=(\d+) load=(\d+)", out)]
    return fetches, loads, order


def _words(n, seed=1):
    rng = random.Random(seed)
    return [rng.randrange(0x10000) for _ in range(n)]


@pytest.mark.parametrize("real", [False, True], ids=["model", "psram_ctrl"])
def test_load_then_fetch(tmp_path, real):
    words = _words(64)
    order = list(range(64)) + random.Random(2).sample(range(64), 64)
    fetches, loads, _ = _run(tmp_path, load_words(words) + [fetch(a) for a in order], real)
    assert [(a, d) for a, d, _ in fetches] == [(a, words[a]) for a in order]
    # psram_ctrl and the model agree on the costs
    assert fetches[0][2] == MISS
    assert loads[-1][1] == WRITE_LAT


def test_line_buffer_hit_is_fast(tmp_path):
    words = _words(8)
    fetches, _, _ = _run(tmp_path, load_words(words) + [fetch(4), fetch(5), fetch(4), fetch(6)])
    assert [lat for *_, lat in fetches] == [MISS, 1, 1, MISS]
    assert [d for _, d, _ in fetches] == [words[4], words[5], words[4], words[6]]


def test_buffer_tag_uses_every_address_bit(tmp_path):
    base = 0b010_1010_1010_1010
    others = [base ^ (1 << b) for b in range(1, 15)]
    ops = load_words([0x1111, 0x2222], base & ~1)
    for k, a in enumerate(others):
        ops.append(load(a & ~1, 0x9000 + k << 16 | 0x8000 + k))
    for a in others:
        ops += [fetch(base), fetch(a)]
    fetches, _, _ = _run(tmp_path, ops)
    want = []
    for k, a in enumerate(others):
        want += [(base, 0x1111), (a, (0x9000 if a & 1 else 0x8000) + k)]
    assert [(a, d) for a, d, _ in fetches] == want
    assert all(lat == MISS for *_, lat in fetches[1:])


def test_load_invalidates_buffer(tmp_path):
    old, new = _words(2, seed=3), _words(2, seed=4)
    ops = load_words(old, base=10) + [fetch(10), fetch(11)]
    ops += load_words(new, base=10) + [fetch(11), fetch(10)]
    fetches, _, _ = _run(tmp_path, ops)
    assert [d for _, d, _ in fetches] == [old[0], old[1], new[1], new[0]]
    assert [lat for *_, lat in fetches] == [MISS, 1, MISS, 1]


def test_load_ready_means_written(tmp_path):
    # Strobe 0011 writes the low word only
    ops = [load(6, 0xAAAA5555), load(6, 0x1234BEEF, 0x3), load(32766, 0xCAFEF00D)]
    _, loads, _ = _run(tmp_path, ops)
    assert [(a, w) for a, _, w in loads] == [(6, 0xAAAA5555), (6, 0xAAAABEEF), (32766, 0xCAFEF00D)]


def test_fetch_goes_before_load(tmp_path):
    # Load and fetch raised in the same cycle: the fetch reads first and gets the old word
    old = _words(2, seed=5)
    ops = load_words(old, base=20) + [load_with_fetch(20, 0x11112222, 21, 0)]
    fetches, loads, order = _run(tmp_path, ops)
    assert fetches == [(21, old[1], MISS)]
    (t_fetch, t_load), = order
    assert t_fetch < t_load
    assert loads[-1][2] == 0x11112222


def test_hit_and_load_in_same_cycle(tmp_path):
    # The hit answers from the buffer and the load goes out a cycle later
    old = _words(2, seed=8)
    ops = load_words(old, base=20) + [fetch(20), load_with_fetch(22, 0x55556666, 21, 0)]
    fetches, loads, _ = _run(tmp_path, ops)
    assert fetches[-1] == (21, old[1], 1)
    assert loads[-1][1:] == (WRITE_LAT + 1, 0x55556666)


def test_fetch_waits_behind_write_in_flight(tmp_path):
    # The write is already with the controller: the fetch waits and sees it
    old = _words(2, seed=6)
    ops = load_words(old, base=20) + [fetch(20), load_with_fetch(20, 0x33334444, 21, 2)]
    fetches, _, order = _run(tmp_path, ops)
    assert fetches[-1][:2] == (21, 0x3333)
    (t_fetch, t_load), = order
    assert t_fetch > t_load


def test_no_request_during_reset(tmp_path):
    # A load raised while progmem_psram is in reset waits for it to end
    _, loads, _ = _run(tmp_path, [idle(150), load_in_reset(8, 0x77778888, 4)])
    assert loads == [(8, 4 + WRITE_LAT, 0x77778888)]


@pytest.mark.parametrize("gap", [0, 100])
def test_reset_mid_read_drops_response(tmp_path, gap):
    # The stale response must not answer the next fetch, and the dropped fetch
    # must not be read again once the controller is free
    words = _words(4, seed=7)
    ops = load_words(words) + [fetch_then_reset(0, 10), idle(gap), fetch(3), fetch(2)]
    fetches, _, _ = _run(tmp_path, ops)
    assert [(a, d) for a, d, _ in fetches] == [(3, words[3]), (2, words[2])]
