#!/usr/bin/env python3
"""Build the Nimbus VTT dock icon (.icns) from the committed brand asset.

Source of truth: ../assets/AppIconSource.png (the cropped Nimbus VTT squircle).
We resize it into a full iconset and run iconutil to emit the .icns.
"""

import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(SCRIPT_DIR, "..", "assets", "AppIconSource.png")


def generate_icon(output_path: str):
    from PIL import Image

    if not os.path.exists(SOURCE):
        print(f"ERROR: brand asset not found: {SOURCE}", file=sys.stderr)
        sys.exit(1)

    img = Image.open(SOURCE).convert("RGBA")
    if img.size != (1024, 1024):
        img = img.resize((1024, 1024), Image.LANCZOS)

    iconset_path = output_path.replace(".icns", ".iconset")
    os.makedirs(iconset_path, exist_ok=True)

    iconset_files = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    for filename, size in iconset_files.items():
        img.resize((size, size), Image.LANCZOS).save(
            os.path.join(iconset_path, filename), "PNG"
        )

    result = subprocess.run(
        ["iconutil", "-c", "icns", iconset_path, "-o", output_path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"iconutil error: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    import shutil

    shutil.rmtree(iconset_path)
    print(f"Generated icon: {output_path}")


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns"
    generate_icon(output)
