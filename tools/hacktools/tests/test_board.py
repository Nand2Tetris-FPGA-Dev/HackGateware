import pytest

from hacktools.board import BoardError, install, run_loader


def test_install_argv(fake_loader, tmp_path):
    install(tmp_path / "x.fs", loader=fake_loader.cmd)
    assert fake_loader.calls[0][-2:] == ["-f", str(tmp_path / "x.fs")]
    assert fake_loader.calls[0][:2] == ["-b", "tangnano9k"]


def test_loader_missing():
    with pytest.raises(BoardError, match="openFPGALoader not found"):
        run_loader(["--detect"], loader=("no-such-tool",))


def test_loader_failure(fake_loader):
    fake_loader.exit = 1
    with pytest.raises(BoardError, match="fake loader stderr"):
        run_loader(["--detect"], loader=fake_loader.cmd)
