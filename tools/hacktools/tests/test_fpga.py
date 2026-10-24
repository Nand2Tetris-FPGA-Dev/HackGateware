from pathlib import Path

import pytest

from hacktools.fpga import BuildSpec, ToolError, build, build_commands, load_builds


def test_build_commands_for_tangnano9k(tmp_path):
    spec = BuildSpec("t", top="top", sources=[Path("a.v")], cst=[Path("b.cst")])
    y, n, g = build_commands(spec, tmp_path)
    assert y[0] == "yosys" and "synth_gowin -top top -json" in " ".join(y)
    assert n[0] == "nextpnr-himbaechel" and n[n.index("--device") + 1] == "GW1NR-LV9QN88PC6/I5"
    assert "family=GW1N-9C" in n and f"cst={tmp_path / 't.cst'}" in n and "--report" in n
    assert g[:3] == ["gowin_pack", "-d", "GW1N-9C"] and g[-1].endswith("pnr.json")


def test_defines_includes_and_pack_flags(tmp_path):
    spec = BuildSpec(
        "t", "top", [Path("a.v")], [Path("b.cst")], defines={"FOO": "1"}, pack_flags=["--x"]
    )
    y, _, g = build_commands(spec, tmp_path, include_dirs=[tmp_path])
    # Paths inside the yosys script are written with forward slashes (see fpga.py).
    assert "-DFOO=1" in " ".join(y) and f"-I{tmp_path.as_posix()}" in " ".join(y)
    assert "--x" in g


def test_load_builds(tmp_path):
    p = tmp_path / "b.toml"
    p.write_text('[x]\ntop="top"\nsources=["a.v"]\ncst=["b.cst","c.cst"]\n')
    assert load_builds(p)["x"].cst == [Path("b.cst"), Path("c.cst")]


def test_build_raises_toolerror_when_tool_missing(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", "")
    with pytest.raises(ToolError) as e:
        build(BuildSpec("t", "top", [Path("a.v")], [Path("b.cst")]), tmp_path)
    assert e.value.tool == "yosys"
