import os
from pathlib import Path

import pytest
from hacktools.assembler import assemble
from hacktools.emulator import HackMachine

from simrun import run_computer

PROGRAMS = Path(__file__).resolve().parents[3] / "sw" / "tests"

pytestmark = pytest.mark.requires_iverilog


def program(name: str) -> list[int]:
    return assemble((PROGRAMS / f"{name}.asm").read_text())


def golden(rom, steps, ram_init=None, keyboard=(), reset_at=None):
    m = HackMachine(rom)
    for addr, value in (ram_init or {}).items():
        m.ram[addr] = value
    if reset_at is None:
        trace = m.run(steps, keyboard=keyboard)
    else:
        trace = m.run(reset_at, keyboard=keyboard)
        m.reset()
        trace += m.run(steps - reset_at)
    return trace, m.ram[:16384], m.screen()


def assert_matches(rom, steps, **kwargs):
    sim = run_computer(rom, steps, **kwargs)
    trace, ram, screen = golden(rom, steps, kwargs.get("ram_init"), kwargs.get("keyboard") or (),
                                kwargs.get("reset_at"))
    assert len(sim.trace) == steps
    for i, (got, want) in enumerate(zip(sim.trace, trace)):
        assert got == want, f"step {i}: rtl {got} != emulator {want}"
    assert sim.ram == ram
    assert sim.screen == screen
    return sim


def test_add():
    sim = assert_matches(program("add"), 20)
    assert sim.ram[0] == 5


def test_max():
    sim = assert_matches(program("max"), 50, ram_init={0: 3, 1: 9})
    assert sim.ram[2] == 9


def test_rect():
    assert_matches(program("rect"), 500, ram_init={0: 4})


def test_fill():
    # Fill only checks the keyboard between full passes (~123K instructions each)
    sim = assert_matches(program("fill"), 300_000, keyboard=[(2000, 65)])
    assert sim.screen == [0xFFFF] * 8192


def test_screen_pattern():
    assert_matches(program("screen_pattern"), 400_000)


def test_runs_from_board_rom():
    sim = run_computer(program("screen_pattern"), 400_000, progmem="rom")
    _, ram, screen = golden(program("screen_pattern"), 400_000)
    assert sim.screen == screen and sim.ram == ram


def test_latency_independent():
    rom = program("screen_pattern")
    fast = run_computer(rom, 20_000, pm_latency=1)
    slow = run_computer(rom, 20_000, pm_latency=37)
    assert fast.trace == slow.trace and fast.ram == slow.ram


def test_reset_midrun_restarts():
    rom = program("screen_pattern")
    sim = assert_matches(rom, 3000, reset_at=500)
    fresh = HackMachine(rom).run(2500)
    assert sim.trace[500:] == fresh


@pytest.mark.requires_env("N2T_PROJECTS")
def test_book_pong_asm():
    pong = Path(os.environ["N2T_PROJECTS"]) / "6" / "pong" / "Pong.asm"
    assert_matches(assemble(pong.read_text()), 200_000)
