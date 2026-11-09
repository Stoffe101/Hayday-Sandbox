#!/usr/bin/env python3
"""Fetch openly licensed UI resources (run once; results are committed).
  * Nunito variable font (SIL Open Font License 1.1) -> assets/ui/fonts/
  * Lucide icons (ISC license) -> assets/ui/icons.json (name -> SVG, stroke=white)
"""
import json, sys, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
ICONS = """mouse-pointer-2 paintbrush eraser pipette map sticky-note hand undo-2 redo-2 save folder-open layout-grid
image-down settings circle-question-mark search star clock rotate-cw trash copy clipboard-paste group ungroup lock
lock-open eye eye-off grid-3x3 layers scan zoom-in zoom-out panel-left panel-right plus x check badge-alert info
sparkles factory house paw-print sprout apple cherry fence footprints droplets flower-2 trees lamp landmark snowflake
mountain map-pin image git-compare wand-sparkles clipboard-check coins gem square-dashed minus pencil download upload
filter arrow-up-down clock-arrow-up crosshair box tag keyboard sun moon file-plus copy-plus ellipsis-vertical maximize-2
square-dashed-mouse-pointer ruler package-open circle-x list-checks spline tent-tree target""".split()
BASE = "https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/"
def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read()
out = {}
for name in ICONS:
    try:
        svg = get(BASE + name + ".svg").decode()
    except Exception as e:
        print("missing icon", name, e, file=sys.stderr); continue
    svg = svg.replace('stroke="currentColor"', 'stroke="#ffffff"')
    svg = "\n".join(l for l in svg.splitlines() if not l.strip().startswith("<!--"))
    out[name] = svg
lic = get("https://raw.githubusercontent.com/lucide-icons/lucide/main/LICENSE").decode()
(ROOT / "assets/ui/icons.json").write_text(json.dumps({"license": "ISC (Lucide Contributors) — see assets/ui/LUCIDE_LICENSE.txt", "icons": out}, indent=0))
(ROOT / "assets/ui/LUCIDE_LICENSE.txt").write_text(lic)
font = get("https://raw.githubusercontent.com/google/fonts/main/ofl/nunito/Nunito%5Bwght%5D.ttf")
(ROOT / "assets/ui/fonts/Nunito-Variable.ttf").write_bytes(font)
(ROOT / "assets/ui/fonts/OFL.txt").write_bytes(get("https://raw.githubusercontent.com/google/fonts/main/ofl/nunito/OFL.txt"))
print(len(out), "icons;", len(font), "font bytes")
