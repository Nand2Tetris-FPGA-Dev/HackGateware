import os
import random
from pathlib import Path

import pytest
from hacktools.assembler import assemble
from hacktools.emulator import HackMachine
from hacktools.vmtranslator import translate

from simrun import long_loop, run_computer

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
    # The emulator resets where the RTL did: instructions can run during reset_delay
    trace, ram, screen = golden(rom, steps, kwargs.get("ram_init"), kwargs.get("keyboard") or (),
                                sim.reset_executed)
    if kwargs.get("reset_at") is not None:
        assert sim.reset_executed >= kwargs["reset_at"]
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


def test_computer_with_psram_model():
    sim = assert_matches(program("screen_pattern"), 400_000, progmem="psram")
    cpi = sim.cycles / 400_000
    print(f"screen_pattern on psram: {cpi:.2f} cycles per instruction")
    assert cpi < 2.2  # buffered hits take 2 cycles; the loop fits in the buffer


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


def test_short_reset_during_fetch():
    # Reset pulses for one cycle while a slow fetch is in flight; that fetch's
    # instruction must be thrown away, not run at PC 0
    rom = program("screen_pattern")
    sim = run_computer(rom, 3000, reset_at=500, reset_delay=3, reset_len=1, pm_latency=37)
    assert sim.trace[500:] == HackMachine(rom).run(2500)


@pytest.mark.parametrize("at,delay,length", [
    (512, 3, 1),    # waiting for word 0 of block 16: that fetch is waited out, dropped
    (512, 10, 1),
    (512, 30, 2),
    (513, 0, 40),   # mid-burst, held past its end
    (512, 45, 1),   # mid-burst, CPU running from the filling block
    (512, 60, 2),
])
def test_reset_during_psram_fetch(at, delay, length):
    # S1 resets the CPU alone. Mid-burst, the burst still fills its slot and PC 0
    # misses behind it (block 0 was evicted).
    sim = assert_matches(long_loop(), 3000, reset_at=at, reset_delay=delay, reset_len=length,
                         progmem="psram")
    assert sim.read_in_flight


def test_long_loop_cosim_psram():
    # 40 blocks through BLOCKS slots: round-robin evicts blocks still in use
    assert_matches(long_loop(), 6000, progmem="psram")


def test_long_loop_shape():
    rom = long_loop()
    assert len(rom) == 1278
    m = HackMachine(rom)
    m.run(1278)
    assert (m.pc, m.ram[16]) == (0, 318)


def test_short_reset_during_execute():
    rom = program("screen_pattern")
    sim = run_computer(rom, 3000, reset_at=500, reset_delay=2, reset_len=1)
    assert sim.trace[500:] == HackMachine(rom).run(2500)


@pytest.mark.requires_env("N2T_PROJECTS")
def test_book_pong_asm():
    pong = Path(os.environ["N2T_PROJECTS"]) / "6" / "pong" / "Pong.asm"
    assert_matches(assemble(pong.read_text()), 200_000)


@pytest.mark.requires_env("N2T_PROJECTS")
def test_pong_slice_cpi_psram():
    pong = Path(os.environ["N2T_PROJECTS"]) / "6" / "pong" / "Pong.asm"
    sim = assert_matches(assemble(pong.read_text()), 200_000, progmem="psram")
    cpi = sim.cycles / 200_000
    print(f"Pong on psram: {cpi:.2f} cycles per instruction")
    assert cpi < 2.8  # misses cost a 33-cycle burst; fetch model gives 2.54


# The book's projects/8/FunctionCalls/FibonacciElement, computing fib(10)
FIB_VM = {
    "Sys": """
function Sys.init 0
push constant 10
call Main.fibonacci 1
pop temp 0
label END
goto END
""",
    "Main": """
function Main.fibonacci 0
push argument 0
push constant 2
lt
if-goto N_LT_2
goto N_GE_2
label N_LT_2
push argument 0
return
label N_GE_2
push argument 0
push constant 2
sub
call Main.fibonacci 1
push argument 0
push constant 1
sub
call Main.fibonacci 1
add
return
""",
}


def test_vm_fib_cosim():
    # fib(10) finishes after ~30.1K instructions
    sim = assert_matches(assemble(translate(FIB_VM)), 31_000)
    assert sim.ram[5] == 55


CLEAR_ROM = """
@5
M=-1
@16383
M=-1
@SCREEN
M=-1
@24575
M=-1
(END)
@END
0;JMP
"""


def test_clear_zeroes_ram_and_screen():
    rom = assemble(CLEAR_ROM)
    ram_init = {0: 7, 100: 8, 9999: 9}
    kept = run_computer(rom, 8, ram_init=ram_init, trace=False)
    assert [kept.ram[a] for a in (0, 5, 100, 9999, 16383)] == [7, 0xFFFF, 8, 9, 0xFFFF]
    assert kept.screen[0] == kept.screen[8191] == 0xFFFF
    sim = run_computer(rom, 8, ram_init=ram_init, trace=False, clear=True)
    assert not any(sim.ram) and not any(sim.screen)
    # one write per cycle, 24576 words
    assert 24576 <= sim.clear_cycles <= 24580


def test_paused_runs_match_emulator():
    rng = random.Random(1)
    points = sorted(rng.sample(range(1, 20_000), 30))
    debug = [("pause", at, rng.randint(1, 200)) for at in points]
    for progmem in ("sim", "rom", "psram"):
        sim = assert_matches(program("screen_pattern"), 20_000, debug=debug, progmem=progmem)
        assert sim.cycles >= 2 * 20_000 + sum(p[2] for p in debug)


def test_debug_reads_match_emulator():
    rom = assemble(translate(FIB_VM))
    points = [1 + 3000 * k for k in range(10)]
    debug = []
    for at in points:
        debug += [("pause", at, 400), ("mread", at, 0, 64), ("pread", at, 0, 64)]
    sim = assert_matches(rom, 31_000, debug=debug)
    m, done, want = HackMachine(rom), 0, []
    for at in points:
        m.run(at - done)
        done = at
        want += [(at, "m", 0, m.ram[:64]), (at, "p", 0, rom[:64])]
    assert sorted(sim.reads) == sorted(want)


def test_debug_reads_cross_regions():
    rom = assemble(CLEAR_ROM)
    rom += [i & 0x7FFF for i in range(len(rom), 32768)]
    debug = [("pause", 8, 300), ("mread", 8, 16380, 8), ("mread", 8, 24570, 8),
             ("pread", 8, 32704, 64)]
    sim = run_computer(rom, 10, ram_init={16380: 1, 16381: 2, 16382: 3},
                       keyboard=[(0, 77)], debug=debug)
    assert sim.reads == [
        (8, "m", 16380, [1, 2, 3, 0xFFFF, 0xFFFF, 0, 0, 0]),
        (8, "m", 24570, [0] * 5 + [0xFFFF, 77, 0]),
        (8, "p", 32704, list(range(32704, 32768))),
    ]


INM_ROM = """
(LOOP)
@0
D=M
@1
M=D+M
@1
D=M
@0
M=D+1
@LOOP
0;JMP
"""


@pytest.mark.parametrize("latency", [1, 3])
def test_reads_never_disturb_inm(latency):
    # Every instruction pauses for one cycle and queues a read of RAM[100..101],
    # so a read is waiting in every fetch and execute cycle
    debug = []
    for at in range(1, 2000):
        debug += [("pause", at, 1), ("mread", at, 100, 2)]
    ram_init = {0: 3, 1: 5, 100: 0x5555, 101: 0x2AAA}
    sim = assert_matches(assemble(INM_ROM), 2000, ram_init=ram_init, pm_latency=latency,
                         debug=debug)
    assert len(sim.reads) == 1999
    assert all(words == [0x5555, 0x2AAA] for _, _, _, words in sim.reads)


def test_pread_psram_evicts_but_matches():
    # Short pauses, so reads overlap running and misses race the CPU's fetches
    rom = long_loop()
    rng = random.Random(2)
    debug = []
    for at in sorted(rng.sample(range(1, 6000), 40)):
        addr = rng.randrange(0, len(rom) - 64)
        debug += [("pause", at, rng.choice([1, 20, 300])), ("pread", at, addr, 64)]
    sim = assert_matches(rom, 6000, progmem="psram", debug=debug)
    assert len(sim.reads) == 40
    assert all(words == rom[addr:addr + 64] for _, _, addr, words in sim.reads)


def test_gap_spaces_fetch_starts():
    sim = assert_matches(program("screen_pattern"), 2000, gap=50)
    assert len(sim.starts) == 2000
    assert {b - a for a, b in zip(sim.starts, sim.starts[1:])} == {50}
