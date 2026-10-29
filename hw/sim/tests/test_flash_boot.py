import re
from dataclasses import dataclass
from pathlib import Path

import pytest
from hacktools.assembler import assemble
from hacktools.emulator import HackMachine
from hacktools.image import build_image

from simrun import iverilog

HW = Path(__file__).resolve().parents[2]
PROGRAMS = HW.parent / "sw" / "tests"
MODEL = HW / "third_party/psram_controller/sim/model"
FLASH_SIZE = 262144  # slots 0 and 1, so reading the wrong slot finds 0xFF
S1, S2 = 1, 2
EXEC, READ, LOAD, IDLE = 0, 1, 2, 3  # what the press waits for after PRESS_AT

pytestmark = pytest.mark.requires_iverilog


def program(name):
    return assemble((PROGRAMS / f"{name}.asm").read_text())


def flash_hex(image):
    flash = bytearray(b"\xff" * FLASH_SIZE)
    flash[:len(image)] = image
    return "".join(f"{b:02x}\n" for b in flash)


@dataclass
class Run:
    result: dict[str, int]
    read_in_flight: bool | None  # at the press
    segments: list[list[tuple[int, int, int, int]]]  # (pc, instr, a, d), split at each CPU reset
    screen: list[int]


def run_boot(tmp_path, image, steps, image2=b"", press=None, real=False):
    """press = (S1 or S2, at, wait_for, delay, length)."""
    (tmp_path / "flash.hex").write_text(flash_hex(image))
    plusargs = {"STEPS": str(steps),
                "LIMIT": str(300 * (len(image) + len(image2)) + 45 * steps + 50_000)}
    if press:
        which, at, wait_for, delay, length = press
        plusargs.update(PRESS=str(which), PRESS_AT=str(at), WAIT_FOR=str(wait_for),
                        PRESS_DELAY=str(delay), PRESS_LEN=str(length))
        (tmp_path / "flash2.hex").write_text(flash_hex(image2))
    sources = [HW / "sim/tb/tb_flash_boot.v", HW / "rtl/top/flash_boot_system.v",
               HW / "sim/models/spi_flash_model.v", HW / "rtl/io/spi_flash_reader.v",
               HW / "rtl/io/boot_loader.v", HW / "rtl/progmem/progmem_psram.v",
               HW / "rtl/top/hack_computer.v", HW / "rtl/cpu/hack_cpu.v",
               HW / "rtl/cpu/hack_alu.v", HW / "rtl/mem/hack_memory.v",
               HW / "rtl/mem/ram16k.v", HW / "rtl/mem/screen_mem.v"]
    if real:
        sources += [HW / "rtl/mem/psram_ctrl.v", MODEL / "w955d8mbya_die.sv",
                    MODEL / "w955d8mbya_model.sv"]
    else:
        sources += [HW / "sim/models/psram_host_model.v"]
    out = iverilog(sources, "tb_flash_boot", plusargs=plusargs,
                   defines={"REAL_CTRL": "1"} if real else None, cwd=tmp_path)
    m = re.search(r"RESULT (.*)", out)
    assert m and "ERROR" not in out and "FAIL" not in out and "TIMEOUT" not in out, out
    result = {k: int(v) for k, v in (f.split("=") for f in m.group(1).split())}
    assert result["errors"] == 0 and result["model_errors"] == 0, out
    segments = [[]]
    for line in (tmp_path / "trace.txt").read_text().splitlines():
        if line == "reset":
            segments.append([])
        else:
            segments[-1].append(tuple(int(f, 16) for f in line.split()))
    screen = [int(w, 16) for w in (tmp_path / "screen.txt").read_text().split()]
    pressed = re.search(r"read_in_flight=(\d)", out)
    return Run(result, pressed and pressed.group(1) == "1", segments, screen)


def loads_for(rom):
    return (len(rom) + 1) // 2


def assert_runs(segment, rom, machine):
    """Every instruction came from rom and matches the emulator."""
    assert [instr for pc, instr, _, _ in segment] == [rom[pc] for pc, *_ in segment]
    assert [(pc, a, d) for pc, _, a, d in segment] == machine.run(len(segment))


def carried(machine, rom):
    """rom started from PC 0 with machine's RAM, A and D, as after a reload."""
    m = HackMachine(rom)
    m.ram, m.a, m.d = machine.ram, machine.a, machine.d
    return m


def test_boots_and_draws(tmp_path):
    rom = program("screen_pattern")
    run = run_boot(tmp_path, build_image(rom, "pattern"), 400_000)
    r = run.result
    assert (r["running"], r["busy"], r["err_header"], r["err_crc"]) == (1, 0, 0, 0)
    assert r["loads"] == loads_for(rom)
    assert len(run.segments) == 1
    m = HackMachine(rom)
    assert_runs(run.segments[0], rom, m)
    assert run.screen == m.screen()


def test_erased_flash(tmp_path):
    r = run_boot(tmp_path, b"", 1).result
    assert (r["running"], r["busy"], r["err_header"], r["err_crc"]) == (0, 0, 1, 0)
    assert (r["fetches"], r["loads"], r["executed"]) == (0, 0, 0)


def test_bad_crc(tmp_path):
    rom = program("screen_pattern")
    image = bytearray(build_image(rom, "bad"))
    image[40] ^= 0x01  # a data byte; the header CRC no longer matches
    r = run_boot(tmp_path, bytes(image), 1).result
    assert (r["running"], r["busy"], r["err_header"], r["err_crc"]) == (0, 0, 0, 1)
    assert r["loads"] == loads_for(rom)
    assert (r["fetches"], r["executed"]) == (0, 0)


@pytest.mark.parametrize("at,wait_for,delay", [
    (1, EXEC, 0),     # line 0 of the old program is in the line buffer
    (500, EXEC, 0),
    (500, IDLE, 0),   # no PSRAM read out
    (500, READ, 0),   # PSRAM read just taken
    (500, READ, 17),
    (500, READ, 34),  # the read's response edge
], ids=["line0", "exec", "idle", "read0", "read17", "read34"])
def test_s2_reloads_mid_run(tmp_path, at, wait_for, delay):
    old, new = program("screen_pattern"), program("fill")
    run = run_boot(tmp_path, build_image(old, "old"), 3000, build_image(new, "new"),
                   press=(S2, at, wait_for, delay, 3))
    r = run.result
    assert run.read_in_flight == (wait_for == READ) or wait_for == EXEC
    assert (r["running"], r["err_header"], r["err_crc"]) == (1, 0, 0)
    assert r["loads"] == loads_for(old) + loads_for(new)
    assert len(run.segments) == 2
    m = HackMachine(old)
    assert_runs(run.segments[0], old, m)
    assert_runs(run.segments[1], new, carried(m, new))


def test_s2_during_load(tmp_path):
    # The first load is cut short; the second image runs as if from power-on
    old, new = program("screen_pattern"), program("fill")
    run = run_boot(tmp_path, build_image(old, "old"), 2000, build_image(new, "new"),
                   press=(S2, 0, LOAD, 10, 3))
    r = run.result
    assert (r["running"], r["err_header"], r["err_crc"]) == (1, 0, 0)
    assert len(run.segments) == 1
    assert_runs(run.segments[0], new, HackMachine(new))


@pytest.mark.parametrize("at,wait_for,delay", [(500, EXEC, 0), (500, IDLE, 0), (500, READ, 10)],
                         ids=["exec", "idle", "read10"])
def test_s1_restarts_without_reload(tmp_path, at, wait_for, delay):
    rom = program("screen_pattern")
    run = run_boot(tmp_path, build_image(rom, "pattern"), 3000,
                   press=(S1, at, wait_for, delay, 3))
    r = run.result
    assert run.read_in_flight == (wait_for == READ) or wait_for == EXEC
    assert (r["running"], r["err_header"], r["err_crc"]) == (1, 0, 0)
    assert r["loads"] == loads_for(rom)
    assert len(run.segments) == 2
    m = HackMachine(rom)
    assert_runs(run.segments[0], rom, m)
    m.reset()
    assert_runs(run.segments[1], rom, m)


def test_boots_on_psram_ctrl(tmp_path):
    rom = program("screen_pattern")
    run = run_boot(tmp_path, build_image(rom, "pattern"), 3000, real=True)
    r = run.result
    assert (r["running"], r["err_header"], r["err_crc"]) == (1, 0, 0)
    assert len(run.segments) == 1
    assert_runs(run.segments[0], rom, HackMachine(rom))
