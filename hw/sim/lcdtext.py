from pathlib import Path

WIDTH, HEIGHT = 240, 135


def read_frame(path: Path) -> list[list[int]]:
    """frame.hex from st7789_model: 135 rows of 240 RGB565 pixels."""
    words = [int(w, 16) for w in Path(path).read_text().split()]
    if len(words) != WIDTH * HEIGHT:
        raise ValueError(f"{path}: {len(words)} pixels, expected {WIDTH * HEIGHT}")
    return [words[y * WIDTH:(y + 1) * WIDTH] for y in range(HEIGHT)]
