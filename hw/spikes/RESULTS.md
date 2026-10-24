# Board spike results

What each hardware check found on the real board. Later tasks read their settings from here.

## Toolchain (Task 1, 2026-10-24)

- OS: Windows 11 Home (10.0.26200)
- OSS CAD Suite `20260821`, installed by FPGA Workbench at
  `%LOCALAPPDATA%\FpgaWorkbench\toolchains\oss-cad-suite-20260821`
  - Yosys 0.68+118 (144c707b7)
  - nextpnr-himbaechel 0.11.1-8-g7c0c1c40
  - gowin_pack (Apycula, from the suite)
  - Icarus Verilog 14.0 (devel, s20260301-381-gb5fdf0647)
- Board: `openFPGALoader -b tangnano9k --detect` gives idcode `0x100481b`, Gowin GW1N(R)-9C.
  The USB driver (WinUSB on BL702 interface 0) was already installed.

## Blinky (Task 1)

- Build: 27 DFF, 13 LUT4, 28 ALU, 9 IOB. Fmax 238.8 MHz (needs 27).
- Pins in `hw/boards/tangnano9k/base.cst` match Sipeed's TangNano-9K-example.
- On the board: OK. The LEDs count in binary, and holding S1 inverts them.
- **Button pins:** the button printed **S1 is pin 4** and **S2 is pin 3**. The plan
  and architecture doc had them swapped. The first load proved it: S2 inverted the
  LEDs. `base.cst` now follows the silkscreen.
- The board dropped off USB once (`unable to open ftdi device: -3`). Replugging fixed it.
