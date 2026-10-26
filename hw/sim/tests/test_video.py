import random
from pathlib import Path

import pytest

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.requires_iverilog

CONTROL_TOKENS = {0: 0b1101010100, 1: 0b0010101011, 2: 0b0101010100, 3: 0b1010101011}


def tmds_ref(d: int, de: int, c: int, disparity: int) -> tuple[int, int]:
    """DVI 1.0 TMDS encoder (DDWG DVI 1.0 spec, section 3.2). Returns (symbol, new disparity)."""
    if not de:
        return CONTROL_TOKENS[c], 0

    bits = [(d >> i) & 1 for i in range(8)]
    ones = sum(bits)
    use_xnor = ones > 4 or (ones == 4 and bits[0] == 0)
    q_m = [bits[0]]
    for i in range(1, 8):
        q_m.append(1 - (q_m[i - 1] ^ bits[i]) if use_xnor else q_m[i - 1] ^ bits[i])
    q_m8 = 0 if use_xnor else 1
    n1 = sum(q_m)
    n0 = 8 - n1

    def word(invert: bool, bit9: int) -> int:
        low = sum((b ^ invert) << i for i, b in enumerate(q_m))
        return low | q_m8 << 8 | bit9 << 9

    if disparity == 0 or n1 == n0:
        if q_m8:
            return word(False, 0), disparity + (n1 - n0)
        return word(True, 1), disparity + (n0 - n1)
    if (disparity > 0 and n1 > n0) or (disparity < 0 and n0 > n1):
        return word(True, 1), disparity + 2 * q_m8 + (n0 - n1)
    return word(False, 0), disparity - 2 * (1 - q_m8) + (n1 - n0)


def tmds_decode(q: int) -> int:
    low = q & 0xFF
    if q >> 9 & 1:
        low ^= 0xFF
    bits = [(low >> i) & 1 for i in range(8)]
    out = [bits[0]]
    for i in range(1, 8):
        x = bits[i] ^ bits[i - 1]
        out.append(x if q >> 8 & 1 else 1 - x)
    return sum(b << i for i, b in enumerate(out))


def test_reference_round_trips():
    disparity = 0
    for d in list(range(256)) * 3:
        q, disparity = tmds_ref(d, 1, 0, disparity)
        assert tmds_decode(q) == d
    assert tmds_ref(0x00, 1, 0, 0)[0] == 0x100


def test_video_timing():
    out = iverilog(
        [HW / "sim/tb/tb_video_timing.v", HW / "rtl/video/video_timing_640x480.v"],
        "tb_video_timing",
    )
    assert "de=614400 hs_pulses=1050 bad_width=0 vs_low=3200 errors=0" in out, out


def test_tmds_matches_reference(tmp_path):
    rng = random.Random(7)
    vectors = [(1, 0, rng.randrange(256)) for _ in range(10_000)]
    vectors += [(0, c, 0) for c in range(4)]
    vectors += [(1, 0, d) for d in (0x00, 0xFF, 0x10, 0xEF, 0x55, 0xAA)] * 4
    (tmp_path / "tmds_vectors.hex").write_text(
        "".join(f"{de << 10 | c << 8 | d:03x}\n" for de, c, d in vectors)
    )
    out = iverilog(
        [HW / "sim/tb/tb_tmds.v", HW / "rtl/video/tmds_encoder.v"],
        "tb_tmds",
        plusargs={"N": str(len(vectors))},
        cwd=tmp_path,
    )
    got = [int(line, 16) for line in out.split()[: len(vectors)]]

    disparity = 0
    for i, (de, c, d) in enumerate(vectors):
        want, disparity = tmds_ref(d, de, c, disparity)
        assert -10 <= disparity <= 10
        assert got[i] == want, f"vector {i} (de={de} c={c} d={d:02x}): {got[i]:03x} != {want:03x}"
