"""Build a bitstream for the Tang Nano 9K: yosys -> nextpnr -> gowin_pack.

Builds are listed in hw/builds.toml. Paths there are relative to the repo root,
and the tools run from the repo root.
"""

import shutil
import subprocess
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEVICE = "GW1NR-LV9QN88PC6/I5"
FAMILY = "GW1N-9C"
CLOCK_MHZ = "27"


class ToolError(Exception):
    """A build tool is missing or failed. `log` holds its output."""

    def __init__(self, tool: str, log: Path, message: str | None = None):
        self.tool = tool
        self.log = log
        super().__init__(message or f"{tool} failed; see {log}")


@dataclass
class BuildSpec:
    name: str
    top: str
    sources: list[Path]
    cst: list[Path]
    defines: dict[str, str] = field(default_factory=dict)
    pack_flags: list[str] = field(default_factory=list)


def load_builds(path: Path = Path("hw/builds.toml")) -> dict[str, BuildSpec]:
    data = tomllib.loads(path.read_text())
    return {
        name: BuildSpec(
            name=name,
            top=entry["top"],
            sources=[Path(s) for s in entry["sources"]],
            cst=[Path(c) for c in entry["cst"]],
            defines=dict(entry.get("defines", {})),
            pack_flags=list(entry.get("pack_flags", [])),
        )
        for name, entry in data.items()
    }


def build_commands(
    spec: BuildSpec, out_dir: Path, include_dirs: list[Path] = []
) -> list[list[str]]:
    # The yosys script is parsed by yosys itself, so its paths use forward slashes.
    read = ["read_verilog", "-sv"]
    read += [f"-D{k}={v}" for k, v in spec.defines.items()]
    read += [f"-I{d.as_posix()}" for d in include_dirs]
    read += [s.as_posix() for s in spec.sources]
    script = f"{' '.join(read)}; synth_gowin -top {spec.top} -json {(out_dir / 'synth.json').as_posix()}"
    # Each tool's output goes to <out>/<tool>.log (see build()).
    yosys = ["yosys", "-p", script]
    nextpnr = [
        "nextpnr-himbaechel",
        "--json", str(out_dir / "synth.json"),
        "--write", str(out_dir / "pnr.json"),
        "--device", DEVICE,
        "--vopt", f"family={FAMILY}",
        "--vopt", f"cst={out_dir / f'{spec.name}.cst'}",
        "--freq", CLOCK_MHZ,
        "--report", str(out_dir / "report.json"),
    ]
    pack = [
        "gowin_pack", "-d", FAMILY, *spec.pack_flags,
        "-o", str(out_dir / f"{spec.name}.fs"), str(out_dir / "pnr.json"),
    ]
    return [yosys, nextpnr, pack]


def build(spec: BuildSpec, out_dir: Path) -> Path:
    """Run the three tools and return the path of the .fs bitstream."""
    commands = build_commands(spec, out_dir)
    for argv in commands:
        if shutil.which(argv[0]) is None:
            raise ToolError(argv[0], out_dir, f"{argv[0]} not found on PATH (is OSS CAD Suite set up?)")

    out_dir.mkdir(parents=True, exist_ok=True)
    # nextpnr takes one constraints file, so join the board's .cst pieces.
    (out_dir / f"{spec.name}.cst").write_text("".join(c.read_text() for c in spec.cst))

    for argv in commands:
        log = out_dir / f"{argv[0]}.log"
        with log.open("w") as f:
            result = subprocess.run(argv, stdout=f, stderr=subprocess.STDOUT)
        if result.returncode != 0:
            raise ToolError(argv[0], log)
    return out_dir / f"{spec.name}.fs"
