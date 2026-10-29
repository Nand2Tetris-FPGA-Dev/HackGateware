# HackGateware

The nand2tetris Hack computer in Verilog for the
[Sipeed Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html),
built with the open source Gowin toolchain.

The computer lives in the FPGA's internal flash. Student programs are loaded
from the board's external SPI flash, so they never have to rebuild the computer.

Work in progress. The first milestone (Dec 2026) is booting a program from flash
and showing the Hack screen over HDMI.

## Design

- Book CPU, ALU and memory map: 32K word ROM, RAM at 0-16383, screen at
  16384-24575, keyboard at 24576.
- Program memory is PSRAM, loaded at power-on from external flash slot 0
  with a CRC check. A small buffer holds the last two instructions read.
- HDMI output at 640x480, with the 512x256 Hack screen centered.
- Verilog-2005. The PSRAM chip model used in tests is SystemVerilog.

## Layout

```text
hw/rtl/       the computer
hw/sim/       testbenches and pytest tests
hw/boards/    pin constraints
hw/spikes/    small designs for checking board features
hw/builds.toml
sw/           Hack test programs
```

## Building

You need [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) 2026-08-21
on `PATH`, and `hacktools` from the DevelopmentTools repo (private) cloned next to
this one:

```bash
python -m pip install -e "../DevelopmentTools/tools/hacktools[dev]"
pytest
hacktools hw build spike_blinky
hacktools hw load spike_blinky      # SRAM, lost on power-off
hacktools hw install spike_blinky   # internal flash
```

## Running a program

Install the computer once, then write programs to the external flash:

```bash
hacktools hw build hdmi
hacktools hw install hdmi
hacktools prog flash sw/tests/screen_pattern.asm --slot 0
```

The board loads slot 0 at power-on. S1 restarts the program, S2 loads it
from flash again. LEDs: 0 loading, 1 running, 2 no valid program in slot 0,
3 CRC error, 4 PSRAM ready, 5 heartbeat.

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and branch rules.

## License

Apache 2.0
