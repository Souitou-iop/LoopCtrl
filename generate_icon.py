#!/usr/bin/env python3
"""Write the PNG icons derived from the LoopCtrl app icon.

The app icon itself is LoopCtrlApp/AppIcon.icon, an Icon Composer document
(Xcode 26+ compiles it into Assets.car, including the fallback images for
older iOS). Edit it in Icon Composer, then export the iOS "Default" rendition
at 1024 px over Config/AppIcon-iOS-1024.png and run this script.

The export carries the rounded-square mask as alpha. iOS composites a
transparent icon on black and applies its own mask, so the export is
flattened onto white (the icon's own fill) first. Writes:

  - Config/RunnerIcon/*.png (via Scripts/make-runner-icons.py), the XCTest
    Runner's home-screen icons
  - LoopCtrlKit/RemoteIcon.swift (the 180x180 runner icon, base64-inlined for
    the /remote web app)
  - LoopCtrlApp/Assets.xcassets/AppIconDisplay.imageset (the export as is, mask
    included, at 512 px: the home screen shows the icon at 112 pt, and the
    compiled app icon only hands out its 120 px fallback)

    python3 generate_icon.py   # needs Pillow
"""
import base64
import runpy
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent
EXPORT = REPO / "Config/AppIcon-iOS-1024.png"
FLAT = REPO / "Config/AppIcon-1024.png"
BACKGROUND = (255, 255, 255)
DISPLAY_DIR = REPO / "LoopCtrlApp/Assets.xcassets/AppIconDisplay.imageset"
DISPLAY_SIZE = 512
DISPLAY_CONTENTS = """\
{
  "images" : [
    {
      "filename" : "AppIconDisplay.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
RUNNER_ICONS = REPO / "Scripts/make-runner-icons.py"
REMOTE_ICON_PNG = REPO / "Config/RunnerIcon/AppIcon60x60@3x.png"
REMOTE_ICON_SWIFT = REPO / "LoopCtrlKit/RemoteIcon.swift"
REMOTE_ICON_TEMPLATE = """\
import Foundation

/// Home Screen icon for the /remote page (GET /remote/icon.png): the runner's
/// own 180×180 icon, Config/RunnerIcon/AppIcon60x60@3x.png, inlined like the
/// page itself so the server needs no bundle resources.
enum RemoteIcon {
    static let png: Data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()

    private static let base64 = \"\"\"
%s
\"\"\"
}
"""


def main() -> None:
    rgba = Image.open(EXPORT).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    flat = Image.new("RGB", rgba.size, BACKGROUND)
    flat.paste(rgba, mask=rgba.split()[3])
    flat.save(FLAT, "PNG", optimize=True)
    print(f"✅ {FLAT.relative_to(REPO)}")

    DISPLAY_DIR.mkdir(exist_ok=True)
    rgba.resize((DISPLAY_SIZE, DISPLAY_SIZE), Image.LANCZOS).save(
        DISPLAY_DIR / "AppIconDisplay.png", "PNG", optimize=True)
    (DISPLAY_DIR / "Contents.json").write_text(DISPLAY_CONTENTS)
    print(f"✅ {DISPLAY_DIR.relative_to(REPO)}")

    runpy.run_path(str(RUNNER_ICONS), run_name="__main__")

    b64 = base64.b64encode(REMOTE_ICON_PNG.read_bytes()).decode()
    lines = "\n".join(b64[i:i + 100] for i in range(0, len(b64), 100))
    REMOTE_ICON_SWIFT.write_text(REMOTE_ICON_TEMPLATE % lines)
    print(f"✅ {REMOTE_ICON_SWIFT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
