#!/usr/bin/env python3
"""Render the LoopCtrl app icon from AppIcon.svg.

AppIcon.svg is the source art: a loop-arrow (the phone looping back to itself
over 10.7.0.1) around a pointer tapping the screen (the phone controlling
itself). It is a full-bleed square; iOS applies the corner mask.

Rasterises with rsvg-convert (brew install librsvg), falling back to cairosvg,
then flattens to RGB with Pillow since App Store icons must not carry alpha.
Afterwards regenerate the runner icons:

    python3 generate_icon.py && python3 Scripts/make-runner-icons.py
"""
import io
import shutil
import subprocess
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent
SOURCE = REPO / "AppIcon.svg"
OUTPUT = REPO / "LoopCtrlApp/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"
SIZE = 1024


def render_svg(path: Path, size: int) -> bytes:
    rsvg = shutil.which("rsvg-convert")
    if rsvg:
        return subprocess.run(
            [rsvg, "-w", str(size), "-h", str(size), "-f", "png", str(path)],
            check=True, capture_output=True,
        ).stdout
    try:
        import cairosvg
    except ImportError:
        raise SystemExit("Need rsvg-convert (brew install librsvg) or cairosvg (pip install cairosvg)")
    return cairosvg.svg2png(url=str(path), output_width=size, output_height=size)


def main() -> None:
    rgba = Image.open(io.BytesIO(render_svg(SOURCE, SIZE))).convert("RGBA")
    flat = Image.new("RGB", rgba.size, rgba.getpixel((0, 0))[:3])
    flat.paste(rgba, mask=rgba.split()[3])
    flat.save(OUTPUT, "PNG", optimize=True)
    print(f"✅ Icon saved to {OUTPUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
