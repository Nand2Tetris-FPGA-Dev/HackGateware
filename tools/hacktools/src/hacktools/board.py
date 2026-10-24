"""Talk to the Tang Nano 9K through openFPGALoader."""

import subprocess
from pathlib import Path
from typing import Sequence

LOADER = ("openFPGALoader",)
BOARD = "tangnano9k"


class BoardError(RuntimeError):
    pass


def run_loader(args: list[str], loader: Sequence[str] = LOADER) -> None:
    argv = [*loader, "-b", BOARD, *[str(a) for a in args]]
    try:
        result = subprocess.run(argv, capture_output=True, text=True)
    except FileNotFoundError:
        raise BoardError(
            f"openFPGALoader not found (tried '{loader[0]}'; is OSS CAD Suite on PATH?)"
        ) from None
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise BoardError(f"openFPGALoader failed (is the board plugged in?): {detail}")


def load_sram(fs: Path, loader: Sequence[str] = LOADER) -> None:
    """Load a bitstream into FPGA SRAM. It's gone after a power-cycle."""
    run_loader([str(fs)], loader)


def install(fs: Path, loader: Sequence[str] = LOADER) -> None:
    """Write a bitstream to the FPGA's internal flash, so it boots at power-on."""
    run_loader(["-f", str(fs)], loader)
