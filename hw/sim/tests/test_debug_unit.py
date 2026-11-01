import re
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from hacktools.assembler import assemble
from hacktools.emulator import HackMachine
from hacktools.vmtranslator import translate
from test_computer import FIB_VM

from simrun import HW, SimError, iverilog

pytestmark = pytest.mark.requires_iverilog

SOURCES = [
    HW / "sim/tb/tb_debug_unit.v",
    HW / "rtl/debug/debug_unit.v",
    HW / "rtl/top/hack_computer.v",
    HW / "rtl/progmem/progmem_sim.v",
    HW / "rtl/cpu/hack_cpu.v",
    HW / "rtl/cpu/hack_alu.v",
    HW / "rtl/mem/hack_memory.v",
    HW / "rtl/mem/ram16k.v",
    HW / "rtl/mem/screen_mem.v",
]

RUN, PAUSE, STEP, RESET, SPEED = range(5)
FIB = assemble(translate(FIB_VM))


def cmd(op, at=0, seq=0, gap=0):
    return (0, at, op, seq, gap)


def read(rom, addr, count, at=0):
    return (2 if rom else 1, at, addr, count, 0)


def hold(level, at=0):
    return (3, at, int(level), 0, 0)


def go_run(level, at=0):
    return (4, at, int(level), 0, 0)


def wait_words(n):
    return (5, 0, n, 0, 0)


def delay(n):
    return (6, 0, n, 0, 0)


@dataclass
class Done:
    op: int
    seq: int
    issued: int  # cycle cmd was high
    cycle: int
    executed: int
    next_pc: int
    paused: int
    step_seq: int
    gap: int
    idle: int


@dataclass
class Read:
    rom: bool
    addr: int
    count: int
    issued: int
    executed: int
    words: list[int] = field(default_factory=list)
    refused: bool | None = None
    end: int | None = None
    end_executed: int | None = None


@dataclass
class Run:
    trace: list[tuple[int, int, int]]
    dones: list[Done]
    reads: list[Read]
    starts: list[int]
    executed: int
    next_pc: int
    paused: int
    gap: int
    step_seq: int
    left: int  # items never taken, or a command or read still going at the end

    def starts_between(self, lo, hi=1 << 40):
        return [s for s in self.starts if lo <= s < hi]


def run_unit(rom, cycles, items=(), latency=1) -> Run:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / "rom.hex").write_text("".join(f"{w:04x}\n" for w in rom))
        (work / "items.txt").write_text("".join(" ".join(map(str, it)) + "\n" for it in items))
        plusargs = {"CYCLES": str(cycles), "ROM_WORDS": str(len(rom)), "ITEMS": str(len(items))}
        out = iverilog(SOURCES, "tb_debug_unit", plusargs=plusargs,
                       defines={"PM_LATENCY": str(latency)}, cwd=work)
        final = re.search(r"FINAL" + r" (\d+)" * 8, out)
        if not final or "FAIL" in out:
            raise SimError(out)
        cmds = [tuple(map(int, c)) for c in re.findall(r"CMD (\d+) (\d+) (\d+)", out)]
        done_lines = re.findall(r"DONE (-?\d+)" + r" (\d+)" * 7, out)
        dones = [Done(op, seq, issued, *map(int, d[1:]))
                 for (op, seq, issued), d in zip(cmds, done_lines)]
        reads = {}
        for line in out.splitlines():
            f = line.split()
            if not f:
                continue
            if f[0] == "RD":
                reads[int(f[1])] = Read(f[2] == "1", *map(int, f[3:7]))
            elif f[0] == "WORD":
                reads[int(f[1])].words.append(int(f[2], 16))
            elif f[0] == "END":
                r = reads[int(f[1])]
                r.refused, r.end, r.end_executed = f[2] == "1", int(f[3]), int(f[4])
        trace = [tuple(int(v, 16) for v in line.split())
                 for line in (work / "trace.txt").read_text().splitlines()]
        _, executed, next_pc, paused, gap, step_seq, left, busy = map(int, final.groups())
        return Run(trace, dones, [reads[n] for n in sorted(reads)],
                   [int(c) for c in re.findall(r"START (\d+)", out)],
                   executed, next_pc, paused, gap, step_seq, left + busy)


def machine(rom, n):
    m = HackMachine(rom)
    m.run(n)
    return m


def assert_trace(rom, run):
    assert run.trace == HackMachine(rom).run(len(run.trace))
    assert run.executed == len(run.trace)


def gaps(starts):
    return {b - a for a, b in zip(starts, starts[1:])}


@pytest.mark.parametrize("latency", [1, 4])
def test_pause_stops_between_instructions(latency):
    items = []
    for k in range(10):
        items += [cmd(PAUSE, at=2000 + 1000 * k + k), cmd(RUN, at=2500 + 1000 * k)]
    run = run_unit(FIB, 13_000, items, latency)
    assert run.left == 0
    pauses = [d for d in run.dones if d.op == PAUSE]
    runs = [d for d in run.dones if d.op == RUN]
    assert len(pauses) == len(runs) == 10
    for p, r in zip(pauses, runs):
        assert p.idle and p.paused and p.cycle > p.issued
        assert p.next_pc == machine(FIB, p.executed).pc
        assert run.starts_between(p.cycle, r.issued) == []
        assert r.executed == p.executed
    assert_trace(FIB, run)


def test_step_runs_one():
    items = [cmd(PAUSE, at=3000)] + [cmd(STEP, seq=s) for s in range(1, 6)]
    run = run_unit(FIB, 5000, items, latency=3)
    assert run.left == 0
    pause, steps = run.dones[0], run.dones[1:]
    for k, d in enumerate(steps, 1):
        assert d.executed == pause.executed + k  # done after the exec, not the fetch
        assert d.paused and d.step_seq == k
        assert d.next_pc == machine(FIB, d.executed).pc
    assert run.executed == pause.executed + 5 and run.step_seq == 5 and run.paused
    assert_trace(FIB, run)


def test_step_same_seq_ignored():
    items = [cmd(PAUSE, at=3000), cmd(STEP, seq=3), cmd(STEP, seq=3)]
    run = run_unit(FIB, 5000, items)
    assert run.left == 0 and len(run.dones) == 3
    pause, first, again = run.dones
    assert first.executed == pause.executed + 1
    assert again.cycle == again.issued + 1 and again.executed == first.executed
    assert run.executed == pause.executed + 1 and run.step_seq == 3
    assert_trace(FIB, run)


def test_step_while_running_ignored():
    items = [cmd(STEP, at=2000, seq=1), cmd(PAUSE, at=4000)]
    run = run_unit(FIB, 6000, items)
    assert run.left == 0
    step, pause = run.dones
    assert step.cycle == step.issued + 1 and step.step_seq == 0 and not step.paused
    assert run.executed == pause.executed and run.step_seq == 0
    assert_trace(FIB, run)


def test_step_while_held_replies_and_never_runs():
    items = [cmd(PAUSE, at=2000), hold(1, at=2500), cmd(STEP, seq=1), cmd(PAUSE),
             hold(0, at=3000)]
    run = run_unit(FIB, 5000, items)
    assert run.left == 0
    pause, step, pause2 = run.dones
    assert step.cycle == step.issued + 1 and step.step_seq == 0
    assert pause2.cycle == pause2.issued + 1
    assert run.executed == pause.executed and run.paused and run.next_pc == 0
    assert run.starts_between(pause.cycle) == []


def test_hold_cuts_step_off():
    items = [cmd(PAUSE, at=2000), cmd(STEP, seq=1), delay(5), hold(1), delay(10), hold(0)]
    run = run_unit(FIB, 4000, items, latency=20)
    assert run.left == 0
    pause, step = run.dones
    assert step.executed == pause.executed and step.step_seq == 1
    assert run.executed == pause.executed and run.paused and run.next_pc == 0
    assert len(run.starts_between(pause.cycle)) == 1


def test_reset_keeps_pause():
    items = [cmd(PAUSE, at=3000), cmd(RESET), cmd(STEP, seq=1), cmd(STEP, seq=2)]
    run = run_unit(FIB, 5000, items)
    assert run.left == 0
    pause, reset, _, _ = run.dones
    assert reset.paused and reset.next_pc == 0 and reset.executed == pause.executed
    m = machine(FIB, pause.executed)
    m.reset()
    assert run.trace[pause.executed:] == m.run(2)
    assert run.trace[pause.executed][0] == 0
    assert run.paused and run.executed == pause.executed + 2


def test_speed_spacing():
    base = run_unit(FIB, 12_000)
    zero = run_unit(FIB, 12_000, [cmd(SPEED, at=10, gap=0)])
    assert zero.starts == base.starts and zero.trace == base.trace
    items = [cmd(SPEED, at=2000, gap=100), cmd(SPEED, at=8000, gap=0)]
    run = run_unit(FIB, 12_000, items)
    slow, full = run.dones
    assert slow.gap == 100 and full.gap == 0 and run.gap == 0
    assert gaps(run.starts_between(slow.cycle, full.issued)) == {100}
    assert gaps(run.starts_between(full.cycle)) == gaps(base.starts)
    assert_trace(FIB, run)


def test_speed_while_paused_stays_paused():
    items = [cmd(PAUSE, at=2000), cmd(SPEED, gap=50), cmd(RUN, at=4000)]
    run = run_unit(FIB, 8000, items)
    assert run.left == 0
    pause, speed, go = run.dones
    assert speed.paused and speed.gap == 50
    assert run.starts_between(pause.cycle, go.issued) == []
    assert gaps(run.starts_between(go.issued)) == {50}
    assert_trace(FIB, run)


def test_reads_while_paused():
    items = [cmd(PAUSE, at=20_000), read(False, 0, 64), read(False, 256, 64),
             read(True, 0, 64), read(True, len(FIB) - 64, 64), cmd(RUN, at=22_000)]
    run = run_unit(FIB, 25_000, items, latency=3)
    assert run.left == 0
    pause, go = run.dones
    m = machine(FIB, pause.executed)
    assert [(r.refused, r.executed, r.words) for r in run.reads] == [
        (False, pause.executed, m.ram[0:64]),
        (False, pause.executed, m.ram[256:320]),
        (False, pause.executed, FIB[:64]),
        (False, pause.executed, FIB[-64:]),
    ]
    assert run.starts_between(pause.cycle, go.issued) == []
    assert_trace(FIB, run)


def test_reads_while_slowed_keep_trace():
    items = [cmd(SPEED, at=10, gap=200)]
    for k in range(1, 21):
        # 37 * k moves each read against the 200-cycle fetch phase; some straddle a fetch
        addr = (97 * k) % (len(FIB) - 64)
        items.append(read(k % 2 == 0, addr if k % 2 == 0 else 256, 64, at=1037 * k))
    run = run_unit(FIB, 22_000, items, latency=3)
    assert run.left == 0
    speed = run.dones[0]
    assert min(gaps(run.starts_between(speed.cycle))) >= 200
    checked = 0
    for r in run.reads:
        assert not r.refused and len(r.words) == 64
        if r.rom:
            assert r.words == FIB[r.addr:r.addr + 64]
        elif r.executed == r.end_executed:
            assert r.words == machine(FIB, r.executed).ram[256:320]
            checked += 1
    assert checked >= 5
    assert_trace(FIB, run)


def test_read_refused_at_full_speed():
    run = run_unit(FIB, 3000, [read(False, 0, 64, at=1000), read(True, 0, 64)])
    assert run.left == 0
    for r in run.reads:
        assert r.refused and r.words == [] and r.end == r.issued + 1
    assert_trace(FIB, run)


def test_go_run_mid_read_refuses():
    items = [cmd(SPEED, at=10, gap=500), read(True, 0, 64, at=1000), wait_words(10),
             go_run(1), delay(20), go_run(0), read(True, 0, 64), read(False, 0, 8)]
    run = run_unit(FIB, 6000, items, latency=6)
    assert run.left == 0
    cut, rom, ram = run.reads
    assert cut.refused and 10 <= len(cut.words) < 64 and cut.words == FIB[:len(cut.words)]
    assert rom.refused and rom.words == [] and ram.refused and ram.words == []
    assert run.gap == 0 and not run.paused
    assert max(gaps(run.starts_between(rom.issued))) < 20
    assert_trace(FIB, run)


def test_go_run_clears_pause():
    items = [cmd(SPEED, at=10, gap=100), cmd(PAUSE, at=2000), cmd(STEP, seq=4),
             go_run(1, at=3000), delay(5), go_run(0)]
    run = run_unit(FIB, 6000, items)
    assert run.left == 0
    assert not run.paused and run.gap == 0 and run.step_seq == 4
    base = run_unit(FIB, 6000)
    assert gaps(run.starts_between(3010)) == gaps(base.starts)
    assert_trace(FIB, run)


def test_go_run_during_pause_still_replies():
    # The fetch in flight would end the pause; go_run lands first and the reply
    # still comes
    items = [cmd(PAUSE, at=2000), go_run(1), delay(3), go_run(0)]
    run = run_unit(FIB, 3000, items, latency=20)
    assert run.left == 0
    assert len(run.dones) == 1 and not run.paused
    assert_trace(FIB, run)
