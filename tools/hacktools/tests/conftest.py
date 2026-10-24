import json
import sys
from pathlib import Path

import pytest

FAKE_LOADER = """
import json, os, sys
with open(os.environ["FAKE_LOADER_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
sys.stderr.write("fake loader stderr\\n")
sys.exit(int(os.environ.get("FAKE_LOADER_EXIT", "0")))
"""


class FakeLoader:
    """Stands in for openFPGALoader: records each argv and exits with a chosen code."""

    def __init__(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
        script = tmp_path / "fake_loader.py"
        script.write_text(FAKE_LOADER)
        self.log = tmp_path / "loader_calls.log"
        self.cmd = (sys.executable, str(script))
        self._monkeypatch = monkeypatch
        monkeypatch.setenv("FAKE_LOADER_LOG", str(self.log))
        self.exit = 0

    @property
    def exit(self) -> int:
        return self._exit

    @exit.setter
    def exit(self, code: int) -> None:
        self._exit = code
        self._monkeypatch.setenv("FAKE_LOADER_EXIT", str(code))

    @property
    def calls(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]


@pytest.fixture
def fake_loader(tmp_path, monkeypatch):
    return FakeLoader(tmp_path, monkeypatch)
