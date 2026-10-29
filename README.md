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
sw/tests/     Hack test programs
sw/demo/      Jack demo programs
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

The Jack tests skip unless `N2T_OS_DIR` and `N2T_JACK_COMPILER` are set (see below).

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

## Jack programs

Jack programs are compiled with the nand2tetris JackCompiler (it needs Java) and
linked with the nand2tetris OS. Both come with the
[nand2tetris software suite](https://www.nand2tetris.org/software):

```bash
export N2T_OS_DIR=/path/to/nand2tetris/tools/OS
export N2T_JACK_COMPILER=/path/to/nand2tetris/tools/JackCompiler.sh   # .bat on Windows
hacktools emulate sw/demo/MathDemo --steps 12000000 --screen math.pbm
hacktools prog flash sw/demo/MathDemo --slot 0
```

`prog flash`, `prog build` and `emulate` take a `.hack`, `.asm` or `.vm` file, or a
folder of `.jack` or `.vm` files. The OS plus a program must fit in the 32K word
ROM; the book's Pong builds to 29149 words.

MathDemo prints six results from the OS `Math` class. The OS runs about 7M
instructions before `Main.main` (mostly `Output.init`), so the first line shows about
5.5 s after the program starts.

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and branch rules.

## License

Apache 2.0
