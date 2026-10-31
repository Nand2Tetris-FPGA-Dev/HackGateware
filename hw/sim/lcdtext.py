from pathlib import Path

WIDTH, HEIGHT = 240, 135


def read_frame(path: Path) -> list[list[int]]:
    """frame.hex from st7789_model: 135 rows of 240 RGB565 pixels."""
    words = [int(w, 16) for w in Path(path).read_text().split()]
    if len(words) != WIDTH * HEIGHT:
        raise ValueError(f"{path}: {len(words)} pixels, expected {WIDTH * HEIGHT}")
    return [words[y * WIDTH:(y + 1) * WIDTH] for y in range(HEIGHT)]


COLS, ROWS = 30, 16
STATES = {0: "WAIT", 1: "LOAD", 2: "RUN", 3: "RESET", 4: "NO IMG", 5: "BADCRC", 6: "WRITE"}


def read_font(path: Path) -> list[list[int]]:
    """font8x8.hex: 128 glyphs of 8 row bytes, bit 0 leftmost."""
    lines = [s for s in Path(path).read_text().split("\n") if s and not s.startswith("//")]
    data = [int(s, 16) for s in lines]
    return [data[c * 8:(c + 1) * 8] for c in range(128)]


def frame_text(frame: list[list[int]], font_path: Path) -> list[str]:
    """Decode a frame into 16 lines of 30 characters. Only white-on-black
    cells that match a glyph from 0x20-0x7E decode; anything else is ?."""
    font = read_font(font_path)
    glyphs = {tuple(font[c]): chr(c) for c in range(0x20, 0x7F)}
    lines = []
    for row in range(ROWS):
        line = ""
        for col in range(COLS):
            cell = []
            ok = True
            for r in range(8):
                bits = 0
                for c in range(8):
                    p = frame[row * 8 + r][col * 8 + c]
                    if p == 0xFFFF:
                        bits |= 1 << c
                    elif p != 0:
                        ok = False
                cell.append(bits)
            line += glyphs.get(tuple(cell), "?") if ok else "?"
        lines.append(line)
    return lines


def status_lines(state, slot, name, words, pc, instr, a, d, sp, sp_max, heap_hi) -> list[str]:
    """The 16 lines debug_screen should show."""
    rows = [[" "] * COLS for _ in range(ROWS)]

    def put(r, col, text):
        rows[r][col:col + len(text)] = text

    put(0, 0, "HACK")
    put(0, 6, "slot")
    put(0, 11, f"{slot:>2}")
    put(0, 24, STATES[state])
    if state in (2, 3):
        put(1, 0, f"{name:<16}")
        put(1, 17, f"{words:>5}")
        put(1, 23, "words")
    put(3, 0, "PC")
    put(3, 4, f"{pc:>6}")
    put(3, 11, "IR")
    put(3, 14, f"{instr:016b}")
    put(4, 0, "A")
    put(4, 4, f"{a:>6}")
    put(4, 11, "D")
    put(4, 15, f"{d:>6}")
    put(5, 0, "SP")
    put(5, 4, f"{sp:>6}")
    put(5, 11, "max")
    put(5, 15, f"{sp_max:>6}")
    put(6, 0, "heap")
    put(6, 4, f"{heap_hi:>6}")
    return ["".join(r) for r in rows]
