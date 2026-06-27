#!/usr/bin/env python3
"""Generate Nimbus VTT menu bar icons — waveform motif (matches brand icon).

Three states, drawn on a 36x36 @2x canvas for an 18pt menu bar slot:
  - idle:         calm waveform bars (template, adapts to light/dark menu bar)
  - recording:    waveform bars in red (non-template, stays colored)
  - transcribing: flowing sine wave (template)

The Dock icon carries the cloud-mic brand; menu bar icons stay minimal.
"""

import sys
from pathlib import Path

SIZE = 36


def _bars(draw, s, color):
    """Vertical rounded bars of varying height — a voice waveform."""
    heights = [8, 16, 24, 14, 22, 12, 7]
    bw = 3
    gap = 2
    total = len(heights) * bw + (len(heights) - 1) * gap
    x = (s - total) // 2
    cy = s // 2
    for h in heights:
        top = cy - h // 2
        draw.rounded_rectangle([x, top, x + bw, top + h], radius=bw // 2, fill=color)
        x += bw + gap


def _draw_idle(draw, s):
    _bars(draw, s, (0, 0, 0, 255))


def _draw_recording(draw, s):
    _bars(draw, s, (220, 50, 47, 255))


def _draw_transcribing(draw, s):
    """A continuous sine wave — reads as 'processing speech'."""
    import math

    ink = (0, 0, 0, 255)
    cy = s // 2
    amp = 8
    pts = []
    for x in range(5, s - 4):
        t = (x - 5) / float(s - 9)
        y = cy - int(amp * math.sin(t * 2 * math.pi * 1.5))
        pts.append((x, y))
    draw.line(pts, fill=ink, width=3, joint="curve")


def generate(output_dir: str):
    from PIL import Image, ImageDraw

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    specs = [
        ("MenuBarIdle", _draw_idle),
        ("MenuBarRecording", _draw_recording),
        ("MenuBarTranscribing", _draw_transcribing),
    ]

    for name, fn in specs:
        img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        fn(draw, SIZE)
        path = out / f"{name}.png"
        img.save(path, "PNG")
        is_template = name != "MenuBarRecording"
        print(f"Generated {path} template={is_template}")


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "icons"
    generate(output)
