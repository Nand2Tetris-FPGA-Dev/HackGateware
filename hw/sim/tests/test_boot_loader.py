import random
import re
from pathlib import Path

import pytest

from hacktools.image import build_image
from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
SLOT = 0x20000


def _load(tmp_path, image, reset_at=None):
    flash = bytearray(b"\xff" * 262144)
    flash[SLOT:SLOT + len(image)] = image
    (tmp_path / "flash.hex").write_text("".join(f"{b:02x}\n" for b in flash))
    out = iverilog(
        [
            HW / "sim/tb/tb_boot_loader.v",
            HW / "sim/models/spi_flash_model.v",
            HW / "rtl/io/spi_flash_reader.v",
            HW / "rtl/io/boot_loader.v",
        ],
        "tb_boot_loader",
        plusargs={"RESET_AT": str(reset_at)} if reset_at else None,
        cwd=tmp_path,
    )
    m = re.search(r"RESULT (.*)", out)
    assert m and "ERROR" not in out, out
    result = {k: v for k, v in (f.split("=") for f in m.group(1).split())}
    assert result["errors"] == "0", out
    lines = [line for line in (tmp_path / "captured.hex").read_text().splitlines() if not line.startswith("//")]
    captured = [None if "x" in line else int(line, 16) for line in lines]
    return result, captured


def _words(n, seed=1):
    rng = random.Random(seed)
    return [rng.randrange(0x10000) for _ in range(n)]


def _with_header(image, version=None, count=None):
    image = bytearray(image)
    if version is not None:
        image[4] = version
    if count is not None:
        image[6:8] = count.to_bytes(2, "big")
    return bytes(image)


@pytest.mark.requires_iverilog
def test_loader_good_image(tmp_path):
    words = _words(1000)
    r, mem = _load(tmp_path, build_image(words, "good"))
    assert (r["done"], r["err_header"], r["err_crc"], r["busy"]) == ("1", "0", "0", "0")
    assert r["count"] == "1000"
    assert r["writes"] == "500"
    assert mem[:1000] == words
    assert mem[1000] is None


@pytest.mark.requires_iverilog
def test_loader_odd_count(tmp_path):
    words = [0x1234, 0xABCD, 0xBEEF]
    r, mem = _load(tmp_path, build_image(words, "odd"))
    assert (r["done"], r["err_header"], r["err_crc"]) == ("1", "0", "0")
    assert r["writes"] == "2"
    assert r["last_strb"] == "0011"
    assert mem[:3] == words
    assert mem[3] is None


@pytest.mark.requires_iverilog
def test_loader_erased_flash(tmp_path):
    r, mem = _load(tmp_path, b"")
    assert (r["done"], r["err_header"], r["err_crc"]) == ("0", "1", "0")
    assert r["writes"] == "0"


@pytest.mark.requires_iverilog
@pytest.mark.parametrize("count", [0, 32769, 40000])
def test_loader_rejects_bad_count(tmp_path, count):
    r, _ = _load(tmp_path, _with_header(build_image(_words(4), "n"), count=count))
    assert (r["done"], r["err_header"], r["err_crc"]) == ("0", "1", "0")
    assert r["writes"] == "0"


@pytest.mark.requires_iverilog
def test_loader_max_count(tmp_path):
    words = _words(32768)
    r, mem = _load(tmp_path, build_image(words, "max"))
    assert (r["done"], r["err_header"], r["err_crc"], r["busy"]) == ("1", "0", "0", "0")
    assert r["count"] == "32768"
    assert r["writes"] == "16384"
    assert r["last_strb"] == "1111"
    assert mem == words


@pytest.mark.requires_iverilog
def test_loader_restarts_after_reset(tmp_path):
    words = _words(301, seed=2)
    r, mem = _load(tmp_path, build_image(words, "again"), reset_at=3000)
    assert (r["done"], r["err_header"], r["err_crc"]) == ("1", "0", "0")
    assert r["writes"] == "151"
    assert r["last_strb"] == "0011"
    assert mem[:301] == words
    assert mem[301] is None


@pytest.mark.requires_iverilog
def test_loader_bad_version(tmp_path):
    r, _ = _load(tmp_path, _with_header(build_image(_words(4), "v"), version=2))
    assert (r["done"], r["err_header"], r["err_crc"]) == ("0", "1", "0")
    assert r["writes"] == "0"


@pytest.mark.requires_iverilog
def test_loader_bad_magic(tmp_path):
    image = bytearray(build_image(_words(4), "m"))
    image[3] = ord("C")
    r, _ = _load(tmp_path, bytes(image))
    assert (r["done"], r["err_header"], r["err_crc"]) == ("0", "1", "0")
    assert r["writes"] == "0"


@pytest.mark.requires_iverilog
def test_loader_bad_crc(tmp_path):
    image = bytearray(build_image(_words(1000), "crc"))
    image[32 + 777] ^= 0x01
    r, _ = _load(tmp_path, bytes(image))
    assert (r["done"], r["err_header"], r["err_crc"], r["busy"]) == ("0", "0", "1", "0")
