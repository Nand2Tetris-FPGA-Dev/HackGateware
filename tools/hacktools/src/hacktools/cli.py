"""hacktools command line. Errors print `error: <message>` and exit 1."""

import argparse
import sys
from pathlib import Path

from hacktools import board, fpga

BUILDS_FILE = Path("hw/builds.toml")


class CliError(Exception):
    pass


def _spec(name: str) -> fpga.BuildSpec:
    if not BUILDS_FILE.exists():
        raise CliError(f"{BUILDS_FILE} not found; run hacktools from the repo root")
    builds = fpga.load_builds(BUILDS_FILE)
    if name not in builds:
        raise CliError(f"unknown build '{name}'; known: {', '.join(sorted(builds))}")
    return builds[name]


def _bitstream(name: str, out: Path) -> Path:
    fs = out / name / f"{name}.fs"
    if not fs.exists():
        raise CliError(f"{fs} not found; run `hacktools hw build {name}` first")
    return fs


def _hw_build(args) -> None:
    fs = fpga.build(_spec(args.name), args.out / args.name)
    print(f"built {fs}")


def _hw_load(args) -> None:
    board.load_sram(_bitstream(args.name, args.out))
    print(f"loaded {args.name} into SRAM (lost at power-off)")


def _hw_install(args) -> None:
    board.install(_bitstream(args.name, args.out))
    print(f"installed {args.name} to internal flash")


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="hacktools", description=__doc__)
    sub = p.add_subparsers(dest="group", required=True)
    hw = sub.add_parser("hw", help="build and load bitstreams").add_subparsers(dest="cmd", required=True)
    for cmd, func, help_text in [
        ("build", _hw_build, "build a bitstream listed in hw/builds.toml"),
        ("load", _hw_load, "load a built bitstream into SRAM (volatile)"),
        ("install", _hw_install, "write a built bitstream to internal flash"),
    ]:
        c = hw.add_parser(cmd, help=help_text)
        c.add_argument("name")
        c.add_argument("--out", type=Path, default=Path("build"))
        c.set_defaults(func=func)
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        args.func(args)
    except (CliError, fpga.ToolError, board.BoardError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
