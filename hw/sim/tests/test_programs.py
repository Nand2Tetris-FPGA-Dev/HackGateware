import os
from pathlib import Path

import pytest
from hacktools.assembler import assemble
from hacktools.emulator import HackMachine
from hacktools.pipeline import build_program, compiler_command

SW = Path(__file__).resolve().parents[3] / "sw"
PROGRAMS = SW / "tests"


def machine(name: str) -> HackMachine:
    return HackMachine(assemble((PROGRAMS / f"{name}.asm").read_text()))


def checkerboard() -> list[int]:
    return [0xFFFF if (i // 32 // 16 + i % 32) % 2 == 0 else 0 for i in range(8192)]


def test_add():
    m = machine("add")
    m.run(6)
    assert m.ram[0] == 5


def test_max():
    for r0, r1 in [(3, 9), (9, 3), (5, 5), (0x8000, 1)]:
        m = machine("max")
        m.ram[0:2] = [r0, r1]
        m.run(50)
        expected = r0 if (r0 - r1) & 0xFFFF and not (r0 - r1) & 0x8000 else r1
        assert m.ram[2] == expected, (r0, r1)


def test_rect():
    m = machine("rect")
    m.ram[0] = 4
    m.run(500)
    assert [m.screen()[r * 32] for r in range(5)] == [0xFFFF] * 4 + [0]
    assert m.screen()[1] == 0


def test_screen_pattern():
    m = machine("screen_pattern")
    m.run(400_000)
    assert m.screen() == checkerboard()


def test_fill_follows_the_keyboard():
    m = machine("fill")
    m.run(300_000, keyboard=[(0, 65)])
    assert m.screen() == [0xFFFF] * 8192
    m.run(300_000, keyboard=[(0, 0)])
    assert m.screen() == [0] * 8192


@pytest.mark.requires_env("N2T_OS_DIR", "N2T_JACK_COMPILER")
def test_math_demo():
    words = build_program(
        SW / "demo" / "MathDemo",
        Path(os.environ["N2T_OS_DIR"]),
        compiler_command(os.environ["N2T_JACK_COMPILER"]),
    )
    assert len(words) < 32768
    m = HackMachine(words)
    # OS boot alone is ~8.9M instructions
    for _ in range(30):
        m.run(500_000)
        if m.ram[16006] == 1:
            break
    assert m.ram[16006] == 1
    assert m.ram[16000:16006] == [5535, 142, 12, 17, 0xEA61, 5040]
    assert any(m.screen()[: 11 * 32]), "first text line is blank"
