# HackGateware

The nand2tetris Hack computer in Verilog, running on the
[Sipeed Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html).
It's built only with the open-source Gowin toolchain.

Students write Hack programs as usual and load them from the board's external
SPI flash. The computer itself stays in the FPGA's internal flash, so they never
have to rebuild or reflash it.

> **Status:** early development. Nothing here builds yet. The first milestone,
> due 2026-12-01, is the Hack computer booting a program from flash and showing
> the Hack screen over HDMI.

## What it is

- **CPU, ALU, and memory map:** exactly as in the book. That's 32K words of
  program memory, RAM at 0–16383, the screen at 16384–24575, and the keyboard
  at 24576.
- **Program memory:** PSRAM, filled at power-on by a boot loader that copies a
  CRC-checked program image from external flash. If PSRAM doesn't work with
  the open toolchain, the fallback is to run programs straight from flash.
- **Video:** HDMI at 640×480, 60 Hz. The 512×256 Hack screen is centered 1:1.
- **Language:** plain Verilog-2005. The one exception is a vendored PSRAM
  controller in SystemVerilog.

## Toolchain

All of these come in
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build), pinned to the
**2026-08-21** release:

- Yosys, nextpnr-himbaechel, and Apicula (`gowin_pack`), for synthesis,
  place-and-route, and bitstream packing
- openFPGALoader, for flashing the board
- Icarus Verilog, for simulation

The Gowin IDE isn't used.

## Layout

```text
hw/
  rtl/      the computer: cpu/, mem/, progmem/, io/, video/, top/
  sim/      testbenches, simulation models, and the tests that run them
  boards/   pin constraints for each board (tangnano9k/)
  spikes/   small test designs used to check board features (results in RESULTS.md)
  builds.toml  the bitstreams hacktools can build
sw/            Hack test programs and demos
```

The dev tooling (`hacktools`: bitstream builds, board loading, the Hack assembler,
and later the emulator) lives in the private
[DevelopmentTools](https://github.com/Nand2Tetris-FPGA-Dev/DevelopmentTools) repo,
under `tools/hacktools`. The tests here need it installed.

## Getting started

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, branches, and commit rules.

## Build

The FPGA tools from OSS CAD Suite must be on `PATH`. Clone DevelopmentTools next to
this repo, install `hacktools` from it, and run everything from this repo's root:

```bash
python -m pip install -e "../DevelopmentTools/tools/hacktools[dev]"
pytest                                 # simulation tests
hacktools hw build spike_blinky        # writes build/spike_blinky/spike_blinky.fs
hacktools hw load spike_blinky         # into FPGA SRAM: gone after a power-cycle
hacktools hw install spike_blinky      # into internal flash: boots at power-on
```

If the `hacktools` command isn't found, `python -m hacktools ...` does the same thing.

## License

Apache 2.0. See [LICENSE](LICENSE).
