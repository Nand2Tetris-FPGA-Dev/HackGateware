from pathlib import Path

import pytest
from hacktools.assembler import assemble
from hacktools.image import build_image

from lcdtext import frame_text, read_frame, status_lines
from simrun import iverilog
from test_flash_boot import bad_crc_image, flash_hex, program, run_boot

HW = Path(__file__).resolve().parents[2]
FONT = HW / "rtl/debug/font8x8.hex"
SOURCES = [
    HW / "sim/tb/tb_debug_system.v",
    HW / "rtl/top/flash_boot_system.v",
    HW / "sim/models/spi_flash_model.v",
    HW / "sim/models/psram_host_model.v",
    HW / "sim/models/st7789_model.v",
    HW / "rtl/io/spi_flash_reader.v",
    HW / "rtl/io/boot_loader.v",
    HW / "rtl/debug/hack_stats.v",
    HW / "rtl/debug/debug_screen.v",
    HW / "rtl/debug/st7789_driver.v",
    HW / "rtl/progmem/progmem_psram.v",
    HW / "rtl/top/hack_computer.v",
    HW / "rtl/cpu/hack_cpu.v",
    HW / "rtl/cpu/hack_alu.v",
    HW / "rtl/mem/hack_memory.v",
    HW / "rtl/mem/ram16k.v",
    HW / "rtl/mem/screen_mem.v",
]
RUN, RESET, NO_IMG, BAD_CRC = 2, 3, 4, 5

PROGRAM = """
    @261
    D=A
    @SP
    M=D
    @290
    D=A
    @SP
    M=D
    @261
    D=A
    @SP
    M=D
    @2100
    M=1
    @2310
    D=A
    M=D
(END)
    @END
    0;JMP
"""
ROM = assemble(PROGRAM)
END = len(ROM) - 2
IMAGE = build_image(ROM, "STATS")
ZEROS = dict(slot=0, name="", words=0, pc=0, instr=0, a=0, d=0, sp=0, sp_max=0, heap_hi=0)

pytestmark = pytest.mark.requires_iverilog


def run_screen(cwd, image, frames=2, **plusargs):
    """Each frame's 16 text lines, last frame first, and the CPU trace
    without reset marks."""
    (cwd / "flash.hex").write_text(flash_hex(image))
    args = {"FRAMES": str(frames)} | {k: str(v) for k, v in plusargs.items()}
    out = iverilog(SOURCES, "tb_debug_system", plusargs=args,
                   defines={"FONT_HEX": f'"{FONT.as_posix()}"'}, cwd=cwd)
    assert "ERRORS 0" in out and "TIMEOUT" not in out, out
    texts = [frame_text(read_frame(cwd / f"frame{n}.hex"), FONT) for n in range(frames, 0, -1)]
    trace = [line for line in (cwd / "trace.txt").read_text().splitlines() if line != "reset"]
    return texts, trace


@pytest.fixture(scope="module")
def stats_run(tmp_path_factory):
    return run_screen(tmp_path_factory.mktemp("debug_system"), IMAGE)


def test_screen_shows_program(stats_run):
    # Frame 2 starts with the CPU in the END loop: A = END, D = 2310, and PC
    # is END or END+1 with that address's instruction in IR
    text = stats_run[0][0]
    expected = [status_lines(RUN, 0, "STATS", len(ROM), pc, ROM[pc], END, 2310, 261, 290, 2310)
                for pc in (END, END + 1)]
    assert text in expected


def test_screen_erased_flash(tmp_path):
    text = run_screen(tmp_path, b"")[0][0]
    assert text == status_lines(NO_IMG, **ZEROS)


def test_screen_bad_crc(tmp_path):
    text = run_screen(tmp_path, bad_crc_image(program("screen_pattern")))[0][0]
    assert text == status_lines(BAD_CRC, **ZEROS)


def test_screen_after_s1(tmp_path):
    # Frame 2 shows the program's stats, then S1 is held across frame 3's start
    (text, before, _), _ = run_screen(tmp_path, IMAGE, frames=3, S1_FRAME=3)
    ran = status_lines(RUN, **ZEROS | dict(sp=261, sp_max=290, heap_hi=2310))
    assert [before[r] for r in (0, 5, 6)] == [ran[r] for r in (0, 5, 6)]
    held = status_lines(RESET, **ZEROS | dict(name="STATS", words=len(ROM)))
    assert [text[r] for r in (0, 1, 5, 6)] == [held[r] for r in (0, 1, 5, 6)]


def test_trace_unchanged_with_screen(tmp_path, stats_run):
    _, trace = stats_run
    steps = 200
    run_boot(tmp_path, IMAGE, steps)
    assert trace[:steps] == (tmp_path / "trace.txt").read_text().splitlines()
