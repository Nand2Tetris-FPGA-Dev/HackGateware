# Contributing

## Setup

You need Git and Python 3.10 or later.

1. Clone the repo:

   ```bash
   git clone https://github.com/Nand2Tetris-FPGA-Dev/HackGateware.git
   cd HackGateware
   ```

2. Run the setup script. It installs [pre-commit](https://pre-commit.com),
   registers the git hooks, and runs every check once.

   - macOS / Linux / WSL: `./setup.sh`
   - Windows (PowerShell): `./setup.ps1`

     If PowerShell refuses to run scripts, use
     `powershell -ExecutionPolicy Bypass -File setup.ps1`.

   If the script can't find `pip`, you can do the same steps by hand:

   ```bash
   python -m pip install --user pre-commit
   python -m pre_commit install
   python -m pre_commit run --all-files
   ```

## Branches

```text
main  <-  dev  <-  feat/<name>
```

- Work on a `feat/<name>` branch made from `dev`.
- Open a pull request into `dev`. It's squash-merged.
- `dev` is merged into `main` for releases.
- The hooks block commits made directly on `main` or `dev`.

## Commits

Each commit message is one line in
[Conventional Commits](https://www.conventionalcommits.org) form:

```text
<type>(<scope>): <summary>
```

For example: `feat(cpu): add hack alu`. Use lowercase, keep it to 72
characters or fewer, and leave off the final period.

## Checks

The pre-commit hooks run on every commit, and
[pre-commit.ci](https://pre-commit.ci) runs them again on each pull request.
They check:

- trailing whitespace and the final newline at the end of each file
- LF line endings
- YAML and TOML syntax
- large files and private keys
- spelling (codespell)

All text files use LF line endings, on every OS. `.gitattributes` and
`.editorconfig` set this up, so you shouldn't have to change anything.

## Code style

- Write plain Verilog-2005 unless a vendored file needs otherwise.
- Indent with 2 spaces, and keep lines to 100 characters or fewer
  (see `.editorconfig`).
