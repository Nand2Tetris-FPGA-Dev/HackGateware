import os
import shutil

import pytest

TOOL_MARKERS = {"requires_iverilog": "iverilog", "requires_yosys": "yosys"}

# OSS CAD Suite tools load MinGW DLLs from <suite>/lib via PATH. If Git Bash's mingw64/bin
# or a conda env comes first, Windows loads their mismatched libstdc++ etc. and the tool dies
# silently with 0xC0000139. Put the suite's dirs first, as its environment.bat does.
for _tool in TOOL_MARKERS.values():
    _exe = shutil.which(_tool)
    if _exe:
        _bin = os.path.dirname(_exe)
        _lib = os.path.join(os.path.dirname(_bin), "lib")
        os.environ["PATH"] = os.pathsep.join([_bin, _lib, os.environ["PATH"]])


def pytest_runtest_setup(item):
    for marker, tool in TOOL_MARKERS.items():
        if item.get_closest_marker(marker) and shutil.which(tool) is None:
            pytest.skip(f"{tool} not on PATH")
    env = item.get_closest_marker("requires_env")
    if env:
        missing = [name for name in env.args if not os.environ.get(name)]
        if missing:
            pytest.skip(f"environment variable(s) not set: {', '.join(missing)}")
