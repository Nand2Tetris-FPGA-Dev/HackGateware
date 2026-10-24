"""Run Icarus Verilog simulations from Python tests."""

import subprocess
import tempfile
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
    """Compile `sources` with `top` as the root module, run it, and return stdout."""
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
