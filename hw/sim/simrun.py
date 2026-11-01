import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from hacktools.assembler import assemble


class SimError(Exception):
    pass


def iverilog(
    sources: list[Path],
    top: str,
    plusargs: dict[str, str] | None = None,
    defines: dict[str, str] | None = None,
    cwd: Path | None = None,
) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        vvp_file = Path(tmp) / f"{top}.vvp"
        # -grelative-include: `include finds files next to the source, as yosys does.
        # It needs forward slashes in the source paths on Windows.
        compile_argv = ["iverilog", "-g2012", "-grelative-include", "-s", top, "-o", str(vvp_file)]
        compile_argv += [f"-D{k}={v}" for k, v in (defines or {}).items()]
        compile_argv += [Path(s).as_posix() for s in sources]
        c = subprocess.run(compile_argv, capture_output=True, text=True, cwd=cwd)
        if c.returncode != 0:
            raise SimError(f"iverilog failed:\n{c.stderr}")

        run_argv = ["vvp", "-n", str(vvp_file)]
        run_argv += [f"+{k}={v}" for k, v in (plusargs or {}).items()]
        r = subprocess.run(run_argv, capture_output=True, text=True, cwd=cwd)
        if r.returncode != 0:
            raise SimError(f"vvp failed (exit {r.returncode}):\n{r.stdout}\n{r.stderr}")
        return r.stdout


HW = Path(__file__).resolve().parents[1]
COMPUTER_SOURCES = [
    HW / "sim/tb/tb_computer.v",
    HW / "rtl/top/hack_computer.v",
    HW / "rtl/progmem/progmem_sim.v",
    HW / "rtl/progmem/progmem_rom.v",
    HW / "rtl/progmem/progmem_psram.v",
    HW / "sim/models/psram_host_model.v",
    HW / "rtl/cpu/hack_cpu.v",
    HW / "rtl/cpu/hack_alu.v",
    HW / "rtl/mem/hack_memory.v",
    HW / "rtl/mem/ram16k.v",
    HW / "rtl/mem/screen_mem.v",
]


@dataclass
class SimResult:
    trace: list[tuple[int, int, int]]
    ram: list[int]
    screen: list[int]
    cycles: int
    clear_cycles: int | None = None
    reset_executed: int | None = None  # instructions run before the reset
    read_in_flight: bool | None = None  # at the reset, psram only
    reads: list[tuple[int, str, int, list[int]]] = field(default_factory=list)
    starts: list[int] = field(default_factory=list)  # fetch_start cycles, with gap only


def long_loop(blocks: int = 40) -> list[int]:
    """A loop of blocks * 32 - 2 instructions with one jump at the end, so every
    pass fetches every block. Each pass leaves blocks * 8 - 2 in RAM[16]."""
    body = "".join(f"@{k}\nD=A\n@16\nM=D\n" for k in range(blocks * 8 - 1))
    return assemble(f"(LOOP)\n{body}@LOOP\n0;JMP\n")


def _read_words(path: Path) -> list[int]:
    return [int(line, 16) for line in path.read_text().split()]


def run_computer(
    rom: list[int],
    steps: int,
    ram_init: dict[int, int] | None = None,
    keyboard: list[tuple[int, int]] | None = None,
    reset_at: int | None = None,
    pm_latency: int = 1,
    trace: bool = True,
    progmem: str = "sim",
    reset_delay: int = 0,
    reset_len: int = 2,
    clear: bool = False,
    debug: list[tuple] | None = None,
    gap: int = 0,
) -> SimResult:
    """Run the RTL computer for `steps` instructions. keyboard takes at most one
    (step, value) pair, applied before that step. progmem is "sim" (progmem_sim
    with pm_latency), "rom" (the board's progmem_rom) or "psram" (progmem_psram
    on psram_host_model, loaded through its load port). cycles counts from the
    end of loading to the last instruction.

    debug items are ("pause", at, cycles), ("mread", at, addr, count) or
    ("pread", at, addr, count). After instruction `at` the testbench holds
    fetch_en low for `cycles` and queues the reads, which run one at a time
    through the debug ports, overlapping the run if they outlast the pause.
    gap is a minimum spacing between fetch_starts, as debug_unit's speed."""
    if keyboard and len(keyboard) > 1:
        raise ValueError("run_computer supports one keyboard change")
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / "rom.hex").write_text("".join(f"{w:04x}\n" for w in rom))
        plusargs = {"STEPS": str(steps), "ROM_WORDS": str(len(rom))}
        if ram_init:
            (work / "ram_init.hex").write_text(
                "".join(f"@{a:x}\n{v:04x}\n" for a, v in sorted(ram_init.items()))
            )
            plusargs["RAMINIT"] = "1"
        if keyboard:
            plusargs["KBD_AT"], plusargs["KBD_VAL"] = (str(x) for x in keyboard[0])
        if reset_at is not None:
            plusargs["RESET_AT"] = str(reset_at)
            plusargs["RESET_DELAY"] = str(reset_delay)
            plusargs["RESET_LEN"] = str(reset_len)
        if trace:
            plusargs["TRACE"] = "1"
        if clear:
            plusargs["CLEAR"] = "1"
        if debug:
            kinds = {"pause": 0, "mread": 1, "pread": 2}
            items = sorted(debug, key=lambda d: d[1])
            (work / "debug.txt").write_text(
                "".join(f"{kinds[d[0]]} {d[1]} {d[2]} {d[3] if len(d) > 3 else 0}\n"
                        for d in items)
            )
            plusargs["DEBUG_ITEMS"] = str(len(items))
            pauses = sum(d[2] for d in items if d[0] == "pause")
            words = sum(d[3] for d in items if d[0] != "pause")
            plusargs["EXTRA_CYCLES"] = str(pauses + 120 * words)
        if gap:
            plusargs["GAP"] = str(gap)
            plusargs["EXTRA_CYCLES"] = str(int(plusargs.get("EXTRA_CYCLES", 0)) + gap * steps)
        defines = {"PM_LATENCY": str(pm_latency)}
        if progmem == "rom":
            defines.update({"PROGMEM_ROM": "1", "ROM_HEX": '"rom.hex"'})
        elif progmem == "psram":
            defines["USE_PSRAM_MODEL"] = "1"
        elif progmem != "sim":
            raise ValueError(f"unknown progmem {progmem!r}")
        out = iverilog(COMPUTER_SOURCES, "tb_computer", plusargs=plusargs,
                       defines=defines, cwd=work)
        done = re.search(r"DONE \d+ instructions in (\d+) cycles", out)
        if not done or "FAIL" in out:
            raise SimError(out)
        cleared = re.search(r"CLEARED (\d+)", out)
        pressed = re.search(r"RESET executed=(\d+)(?: read_in_flight=(\d))?", out)
        reads: dict[int, tuple[int, str, int, list[int]]] = {}
        for n, kind, at, addr, word in re.findall(
                r"READ (\d+) ([mp]) (\d+) (\d+) ([0-9a-f]{4})", out):
            reads.setdefault(int(n), (int(at), kind, int(addr), []))[3].append(int(word, 16))
        lines = (work / "trace.txt").read_text().splitlines() if trace else []
        return SimResult(
            trace=[tuple(int(f, 16) for f in line.split()) for line in lines],
            ram=_read_words(work / "ram.txt"),
            screen=_read_words(work / "screen.txt"),
            cycles=int(done.group(1)),
            clear_cycles=int(cleared.group(1)) if cleared else None,
            reset_executed=int(pressed.group(1)) if pressed else None,
            read_in_flight=pressed.group(2) == "1" if pressed and pressed.group(2) else None,
            reads=[reads[n] for n in sorted(reads)],
            starts=[int(c) for c in re.findall(r"START (\d+)", out)],
        )
