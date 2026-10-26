import os
import shutil

import pytest

TOOL_MARKERS = {"requires_iverilog": "iverilog", "requires_yosys": "yosys"}


def pytest_runtest_setup(item):
    for marker, tool in TOOL_MARKERS.items():
        if item.get_closest_marker(marker) and shutil.which(tool) is None:
            pytest.skip(f"{tool} not on PATH")
    env = item.get_closest_marker("requires_env")
    if env:
        missing = [name for name in env.args if not os.environ.get(name)]
        if missing:
            pytest.skip(f"environment variable(s) not set: {', '.join(missing)}")
