import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


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
        compile_argv = ["iverilog", "-g2012", "-s", top, "-o", str(vvp_file)]
        compile_argv += [f"-D{k}={v}" for k, v in (defines or {}).items()]
        compile_argv += [str(s) for s in sources]
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
) -> SimResult:
    """Run the RTL computer for `steps` instructions. keyboard takes at most one
    (step, value) pair, applied before that step. progmem is "sim" (progmem_sim
    with pm_latency), "rom" (the board's progmem_rom) or "psram" (progmem_psram
    on psram_host_model, loaded through its load port). cycles counts from the
    end of loading to the last instruction."""
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
        if not done:
            raise SimError(out)
        lines = (work / "trace.txt").read_text().splitlines() if trace else []
        return SimResult(
            trace=[tuple(int(f, 16) for f in line.split()) for line in lines],
            ram=_read_words(work / "ram.txt"),
            screen=_read_words(work / "screen.txt"),
            cycles=int(done.group(1)),
        )
