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
    # OS boot alone is ~6.7M instructions
    for _ in range(30):
        m.run(500_000)
        if m.ram[16006] == 1:
            break
    assert m.ram[16006] == 1
    assert m.ram[16000:16006] == [5535, 142, 12, 17, 0xEA61, 5040]
    assert any(m.screen()[: 11 * 32]), "first text line is blank"


def box(m: HackMachine) -> list[int]:
    return [m.screen()[r * 32 + w] for r in range(64) for w in range(4)]


def text_area(m: HackMachine) -> list[int]:
    return [m.screen()[r * 32 + w] for r in range(64) for w in range(4, 32)]


def text_cells(m: HackMachine, cols: range) -> list[int]:
    """Pixels of text row 1 (y 11-21) at these Output columns (8 px each)."""
    s = m.screen()
    return [(s[y * 32 + c // 2] >> 8 * (c % 2)) & 0xFF for c in cols for y in range(11, 22)]


@pytest.mark.requires_env("N2T_OS_DIR", "N2T_JACK_COMPILER")
def test_key_test():
    words = build_program(
        SW / "demo" / "KeyTest",
        Path(os.environ["N2T_OS_DIR"]),
        compiler_command(os.environ["N2T_JACK_COMPILER"]),
    )
    assert len(words) < 32768
    m = HackMachine(words)
    for _ in range(30):
        m.run(500_000)
        if any(text_area(m)):
            break
    # one redraw is ~320k instructions; let the boot text finish
    m.run(1_000_000)
    idle = text_area(m)
    assert any(idle), "no text after boot"
    assert box(m) == [0] * 256

    char, count = range(20, 21), range(30, 35)
    idle_count = text_cells(m, count)
    assert not any(text_cells(m, char))

    m.run(500_000, keyboard=[(0, 65)])
    assert box(m) == [0xFFFF] * 256
    pressed_a = text_area(m)
    assert pressed_a != idle
    char_a, count_1 = text_cells(m, char), text_cells(m, count)
    assert any(char_a)
    assert count_1 != idle_count

    m.run(500_000, keyboard=[(0, 0)])
    assert box(m) == [0] * 256
    released = text_area(m)
    assert released != pressed_a
    assert not any(text_cells(m, char))
    assert text_cells(m, count) == count_1, "release counted as a press"

    m.run(500_000, keyboard=[(0, 66)])
    pressed_b = text_area(m)
    assert box(m) == [0xFFFF] * 256
    assert pressed_b not in (released, pressed_a)
    assert text_cells(m, char) not in ([0] * 11, char_a)
    assert text_cells(m, count) not in (idle_count, count_1)
    m.run(500_000)  # 66 still held
    assert text_area(m) == pressed_b, "holding a key counted as another press"
