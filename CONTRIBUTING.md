# Contributing

## Setup

You need Git, Python 3.11+, and OSS CAD Suite 2026-08-21.

```bash
git clone https://github.com/Nand2Tetris-FPGA-Dev/HackGateware.git
git clone https://github.com/Nand2Tetris-FPGA-Dev/DevelopmentTools.git
python -m pip install -e "DevelopmentTools/tools/hacktools[dev]"
cd HackGateware
./setup.sh        # or ./setup.ps1 on Windows
```

The setup script installs pre-commit and the git hooks. If PowerShell won't run
it, use `powershell -ExecutionPolicy Bypass -File setup.ps1`, or do it by hand:

```bash
python -m pip install --user pre-commit
python -m pre_commit install
```

## Branches

`main` <- `dev` <- `feat/<name>`

Branch off `dev` and open a PR back into it (squash merge). `dev` gets merged
into `main` for releases. The hooks won't let you commit directly to `main` or
`dev`.

## Commits

One line, [Conventional Commits](https://www.conventionalcommits.org) style,
lowercase, no trailing period:

```text
feat(cpu): add hack alu
```

## Style

Verilog-2005, 2 space indent, 100 column lines. Everything uses LF line endings
(`.gitattributes` handles this).
