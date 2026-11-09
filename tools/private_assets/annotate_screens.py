#!/usr/bin/env python3
"""Annotate PRIVATE QA screenshots of the real app with footprint diamonds, ground centres and labels.

Reads <shot>.png + <shot>.objects.json written by `tests/visual/capture.gd --dump-objects` and writes
<shot>.annot.png next to it. Screenshots that show original Hay Day art must stay in the private root
(default /root/hayday-sandbox-private-assets/screens); this tool refuses to write inside a git work tree.
It contains no art.

  python3 tools/private_assets/annotate_screens.py /root/hayday-sandbox-private-assets/screens/r2/*.png
  python3 tools/private_assets/annotate_screens.py --labels-only ...   # no diamonds, only labels
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def in_git_tree(p: Path) -> bool:
	try:
		r = subprocess.run(["git", "-C", str(p if p.is_dir() else p.parent), "rev-parse", "--is-inside-work-tree"],
			capture_output=True, text=True, timeout=10)
		return r.returncode == 0 and r.stdout.strip() == "true"
	except (OSError, subprocess.SubprocessError):
		return False


def annotate(png: Path, labels_only: bool, tile: tuple[int, int] | None = None, follow: tuple[int, int] | None = None) -> Path | None:
	meta = png.with_suffix("").with_suffix(".objects.json") if png.name.endswith(".png") else None
	meta = png.parent / (png.stem + ".objects.json")
	if not meta.exists():
		return None
	data = json.loads(meta.read_text())
	img = Image.open(png).convert("RGBA")
	over = Image.new("RGBA", img.size, (0, 0, 0, 0))
	d = ImageDraw.Draw(over)
	try:
		font = ImageFont.truetype("DejaVuSans-Bold.ttf", 13)
	except OSError:
		font = ImageFont.load_default()
	seen_labels = set()
	for o in sorted(data["objects"], key=lambda o: o["order"]):
		pts = [tuple(p) for p in o["footprint"]]
		col = (255, 40, 40, 230) if o.get("pack") == "hayday_original" else (40, 120, 255, 230)
		if not labels_only:
			d.line(pts + [pts[0]], fill=col, width=2)
			cx, cy = o["center"]
			d.line([(cx - 5, cy), (cx + 5, cy)], fill=(255, 255, 0, 255), width=2)
			d.line([(cx, cy - 5), (cx, cy + 5)], fill=(255, 255, 0, 255), width=2)
		# one label per item id and footprint position cluster
		key = (o["item"], round(o["center"][0] / 120), round(o["center"][1] / 120))
		if key in seen_labels or o["size"] == [1, 1] and o["item"].endswith(("fence", "path", "hedge", "wall")):
			continue
		seen_labels.add(key)
		label = o["item"] + (f"[{o['variant']}]" if o.get("variant") else "") + (" (planned)" if o.get("planned") else "")
		x, y = o["center"][0], o["center"][1] + 6
		tw = d.textlength(label, font=font)
		d.rectangle([x - tw / 2 - 3, y - 1, x + tw / 2 + 3, y + 16], fill=(0, 0, 0, 170))
		d.text((x - tw / 2, y), label, fill=(255, 255, 255, 255), font=font)
	img.alpha_composite(over)
	out = png.parent / (png.stem + ".annot.png")
	img.convert("RGB").save(out)
	if follow:
		# windows that follow the objects (iso layouts run diagonally across an export)
		fw, fh = follow
		cs = sorted((o["center"][0], o["center"][1]) for o in data["objects"])
		k = 0
		x = max(0, int(cs[0][0]) - 150) if cs else 0
		while cs and x < img.width:
			ys = [c[1] for c in cs if x <= c[0] < x + fw]
			if ys:
				ys.sort()
				cy = ys[len(ys) // 2]
				y0 = int(min(max(0, cy - fh * 0.55), max(0, img.height - fh)))
				img.crop((x, y0, min(x + fw, img.width), min(y0 + fh, img.height))).convert("RGB").save(
					png.parent / f"{png.stem}.annot_f{k:02d}.png")
				k += 1
			x += int(fw * 0.85)
	if tile:
		tw, th = tile
		for r in range(0, img.height, th):
			for c in range(0, img.width, tw):
				n = sum(1 for o in data["objects"] if c <= o["center"][0] < c + tw and r <= o["center"][1] < r + th)
				if n == 0:
					continue   # skip crops without any object
				img.crop((c, r, min(c + tw, img.width), min(r + th, img.height))).convert("RGB").save(
					png.parent / f"{png.stem}.annot_r{r // th}c{c // tw}.png")
	return out


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("shots", nargs="+", type=Path)
	ap.add_argument("--labels-only", action="store_true")
	ap.add_argument("--tile", default="", help="also write crops of WxH px (e.g. 1600x1000)")
	ap.add_argument("--follow", default="", help="also write WxH crops that follow the objects")
	a = ap.parse_args()
	n = 0
	for png in a.shots:
		if ".annot" in png.name or not png.exists():
			continue
		if in_git_tree(png.resolve()):
			print(f"refusing: {png} is inside a git work tree (private screenshots belong in the private root)")
			return 2
		tile = tuple(int(v) for v in a.tile.split("x")) if a.tile else None
		follow = tuple(int(v) for v in a.follow.split("x")) if a.follow else None
		out = annotate(png, a.labels_only, tile, follow)
		if out:
			n += 1
			print(f"ANNOT {out}")
	return 0 if n else 1


if __name__ == "__main__":
	sys.exit(main())
