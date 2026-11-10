#!/usr/bin/env python3
"""PRIVATE calibration sheets: the real app with the installed original-art pack, a tile grid with coordinates,
footprint outlines, ground centres and landmark registration points, at several zoom levels.

PERSONAL USE ONLY. The pictures show original Hay Day art, so they are written only to the private root (default
<root>/screens/calibration/<YYYY-MM-DD>/); the tool refuses a folder inside a git work tree. It contains no art and no
game data: target positions are read at run time from the installed pack's world.json and the QA layout.

How it works
  1. Builds an isolated user-data folder (temp): the installed pack is linked read-only (symlinks; copies where links
     are not allowed), nothing else. The user's layouts, settings and autosaves are never opened.
  2. Runs the real app under Xvfb (Linux; on Windows a normal off-screen run) with tests/visual/capture.gd:
     `--capture --real-art --open=<layout> --scenarios=at_<x>_<y>_<zoom>,... --dump-objects --hide-panels`.
     capture.gd writes <shot>.png plus <shot>.objects.json (screen geometry of objects and landmarks, the tile ->
     image transform; no pixels).
  3. Annotates every shot (grid lines on tile edges, "x,y" labels, blue object footprints, red landmark footprints,
     yellow ground-centre crosses, magenta registration points = where the client puts the export's registration
     point) and builds one sheet per target with the zoom levels side by side.

Usage
  python3 tools/private_assets/calibration_sheet.py [--layout L] [--targets farmhouse,truck,...] [--zooms 0.5,1,2]
      [--out O] [--pack-dir D] [--size 1920x1080] [--godot G] [--annotate-only O]
Targets: landmark ids (farmhouse, mine, roadside_shop, truck, order_board, riverboat_dock, ...), catalogue item ids
present in the layout (barn, silo, sugar_mill, fence, ...), "road" (the road edge by the roadside shop), "deco1x1",
"deco2x2" (first 1x1 / 2x2 decoration of the layout), or "x,y" tile coordinates.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pack_qa import find_godot, git_tree_of, installed_pack_dir, private_root  # noqa: E402

DEFAULT_TARGETS = ("farmhouse,mine,roadside_shop,truck,order_board,riverboat_dock,road,fence,barn,silo,sugar_mill,"
	"deco1x1,deco2x2")
DECO_CATS = ("decoration", "seasonal", "furniture", "structures", "nature", "flowers")


def isolated_data_dir(pack_dir: Path) -> Path:
	"""Temp user-data folder holding only a read-only view of the pack (dirs linked, json files copied)."""
	tmp = Path(tempfile.mkdtemp(prefix="hds_calib_"))
	dst = tmp / "HaydaySandbox" / "asset_packs" / pack_dir.name
	dst.mkdir(parents=True)
	for p in pack_dir.iterdir():
		if p.is_dir():
			try:
				os.symlink(p, dst / p.name, target_is_directory=True)
			except OSError:
				shutil.copytree(p, dst / p.name)
		else:
			shutil.copy2(p, dst / p.name)
	return tmp


def item_categories() -> dict:
	cats = {}
	for f in sorted((REPO / "data" / "items").glob("*.json")):
		if f.name == "categories.json":
			continue
		for it in json.loads(f.read_text(encoding="utf-8")).get("items", []):
			cats[it["id"]] = it.get("category", "")
	return cats


def resolve_targets(names: list[str], world: dict, layout: dict) -> list[dict]:
	"""-> [{name, tile: [x, y] (centre tile), what}] in the order given; unknown names are reported and skipped."""
	lms = {lm["id"]: lm for lm in world.get("landmarks", [])}
	objs = layout.get("objects", [])
	cats = item_categories()
	out = []
	for n in names:
		n = n.strip()
		if not n:
			continue
		if "," in n or n.replace("-", "").replace(":", "").isdigit():
			x, y = (int(v) for v in n.replace(":", ",").split(","))
			out.append({"name": f"tile_{x}_{y}", "tile": [x, y], "what": "tile"})
		elif n in lms:
			lm = lms[n]
			cx = lm["origin"][0] + lm["footprint"][0] // 2
			cy = lm["origin"][1] + lm["footprint"][1] // 2
			out.append({"name": n, "tile": [cx, cy], "what": "landmark"})
		elif n == "road":
			rs = lms.get("roadside_shop")
			if rs:
				out.append({"name": "road_edge", "tile": [rs["origin"][0] + 8, rs["origin"][1] - 1], "what": "road edge"})
		elif n in ("deco1x1", "deco2x2"):
			want = [1, 1] if n == "deco1x1" else [2, 2]
			o = next((o for o in objs if [o.get("w"), o.get("h")] == want and cats.get(o["item"]) in DECO_CATS), None)
			if o:
				out.append({"name": f"{n}_{o['item']}", "tile": [o["x"] + o["w"] // 2, o["y"] + o["h"] // 2], "what": "decoration"})
		else:
			o = next((o for o in objs if o["item"] == n), None)
			if o is None:
				print(f"target {n}: not a landmark and not in the layout (skipped)")
				continue
			out.append({"name": n, "tile": [o["x"] + o["w"] // 2, o["y"] + o["h"] // 2], "what": "object"})
	return out


def run_capture(godot: str, data_dir: Path, layout: Path, out: Path, scenarios: list[str], size: str) -> str:
	env = dict(os.environ)
	env["XDG_DATA_HOME"] = str(data_dir)
	env["APPDATA"] = str(data_dir)
	args = ["--path", str(REPO), "--rendering-driver", "opengl3", "--audio-driver", "Dummy", "--",
		"--capture", "--real-art", f"--open={layout}", f"--out={out}", "--scale=1", f"--scenarios={','.join(scenarios)}",
		"--tag=calib_", "--dump-objects", "--hide-panels"]
	if os.name == "nt":
		cmd = [godot] + args[:6] + [f"--window-size={size}"] + args[6:]
	else:
		if shutil.which("xvfb-run") is None:
			raise SystemExit("xvfb-run is needed for real renders on Linux")
		cmd = ["xvfb-run", "-a", "-s", f"-screen 0 {size}x24", godot] + args
	r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=3600)
	return (r.stdout or "") + (r.stderr or "")


# --- annotation -------------------------------------------------------------------

def _font(size: int):
	from PIL import ImageFont
	for name in ("DejaVuSans-Bold.ttf", "arialbd.ttf", "Arial Bold.ttf"):
		try:
			return ImageFont.truetype(name, size)
		except OSError:
			pass
	try:
		return ImageFont.load_default(size=size)
	except TypeError:
		return ImageFont.load_default()


def annotate(png: Path) -> Path | None:
	from PIL import Image, ImageDraw
	meta_p = png.parent / (png.stem + ".objects.json")
	if not meta_p.exists():
		return None
	meta = json.loads(meta_p.read_text(encoding="utf-8"))
	t = meta.get("tile_to_image")
	img = Image.open(png).convert("RGBA")
	over = Image.new("RGBA", img.size, (0, 0, 0, 0))
	d = ImageDraw.Draw(over)
	f_small, f_lab = _font(11), _font(13)
	W, H = img.size
	if t:
		o, ex, ey = t["o"], t["ex"], t["ey"]
		P = lambda x, y: (o[0] + x * ex[0] + y * ey[0], o[1] + x * ex[1] + y * ey[1])   # noqa: E731
		det = ex[0] * ey[1] - ex[1] * ey[0]

		def inv(px: float, py: float) -> tuple[float, float]:
			qx, qy = px - o[0], py - o[1]
			return ((qx * ey[1] - qy * ey[0]) / det, (ex[0] * qy - ex[1] * qx) / det)
		cs = [inv(0, 0), inv(W, 0), inv(0, H), inv(W, H)]
		x0, x1 = math.floor(min(c[0] for c in cs)) - 1, math.ceil(max(c[0] for c in cs)) + 1
		y0, y1 = math.floor(min(c[1] for c in cs)) - 1, math.ceil(max(c[1] for c in cs)) + 1
		tile_px = math.hypot(ex[0], ex[1])
		for x in range(x0, x1 + 1):
			d.line([P(x, y0), P(x, y1)], fill=(255, 255, 255, 70 if x % 5 else 140), width=1)
		for y in range(y0, y1 + 1):
			d.line([P(x0, y), P(x1, y)], fill=(255, 255, 255, 70 if y % 5 else 140), width=1)
		step = 1 if tile_px >= 60 else (2 if tile_px >= 30 else 5)
		for x in range(x0, x1 + 1):
			for y in range(y0, y1 + 1):
				if x % step or y % step:
					continue
				cx, cy = P(x + 0.5, y + 0.5)
				if 0 <= cx < W and 0 <= cy < H:
					lab = f"{x},{y}"
					d.text((cx - 3.2 * len(lab), cy - 6), lab, fill=(255, 255, 255, 200), font=f_small,
						stroke_width=2, stroke_fill=(0, 0, 0, 160))
	for ob in meta.get("objects", []):
		pts = [tuple(p) for p in ob["footprint"]]
		d.line(pts + [pts[0]], fill=(40, 140, 255, 220), width=2)
		cx, cy = ob["center"]
		d.line([(cx - 5, cy), (cx + 5, cy)], fill=(255, 230, 0, 255), width=2)
		d.line([(cx, cy - 5), (cx, cy + 5)], fill=(255, 230, 0, 255), width=2)
	for lm in meta.get("landmarks", []):
		pts = [tuple(p) for p in lm["footprint"]]
		d.line(pts + [pts[0]], fill=(255, 40, 40, 240), width=3)
		cx, cy = lm["center"]
		d.line([(cx - 7, cy), (cx + 7, cy)], fill=(255, 230, 0, 255), width=3)
		d.line([(cx, cy - 7), (cx, cy + 7)], fill=(255, 230, 0, 255), width=3)
		lab = f"{lm['id']} ({lm['origin'][0]},{lm['origin'][1]}) {lm['size'][0]}x{lm['size'][1]} {lm.get('draw_anchor', '')}"
		if lm.get("registration_point"):
			rx, ry = lm["registration_point"]
			d.ellipse([rx - 6, ry - 6, rx + 6, ry + 6], outline=(255, 0, 255, 255), width=3)
			lab += f" reg {lm['client_registration'][0]},{lm['client_registration'][1]}"
		d.text((cx - 4 * len(lab), cy + 10), lab, fill=(255, 255, 255, 255), font=f_lab, stroke_width=3, stroke_fill=(150, 0, 0, 255))
	img.alpha_composite(over)
	z = meta.get("zoom", 0)
	ImageDraw.Draw(img).text((10, H - 24), f"zoom {z}  |  red = landmark footprint, blue = object footprint, yellow + = ground "
		"centre (sprite anchor), magenta o = client registration point  |  PRIVATE", fill=(255, 255, 255, 255), font=f_lab,
		stroke_width=3, stroke_fill=(0, 0, 0, 255))
	outp = png.parent / (png.stem + ".annot.png")
	img.convert("RGB").save(outp)
	return outp


def sheet_for(target: dict, shots: list[Path], out: Path) -> Path | None:
	from PIL import Image, ImageDraw
	panels = []
	for p in shots:
		if p and p.exists():
			im = Image.open(p)
			cw, ch = min(im.width, 900), min(im.height, 760)
			l, t = (im.width - cw) // 2, (im.height - ch) // 2
			panels.append(im.crop((l, t, l + cw, t + ch)))
	if not panels:
		return None
	W = sum(p.width for p in panels) + 10 * (len(panels) - 1)
	H = max(p.height for p in panels) + 34
	sh = Image.new("RGB", (W, H), (30, 30, 30))
	x = 0
	for p in panels:
		sh.paste(p, (x, 34))
		x += p.width + 10
	ImageDraw.Draw(sh).text((8, 8), f"Calibration: {target['name']} ({target['what']}, centre tile {target['tile'][0]},{target['tile'][1]}) "
		"- zoom levels left to right - PRIVATE, personal use only", fill=(255, 255, 255), font=_font(16))
	op = out / f"sheet_{target['name']}.png"
	sh.save(op)
	return op


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
	ap.add_argument("--root", default=None)
	ap.add_argument("--pack-dir", default=None, help="pack folder to show (default the installed hayday_original)")
	ap.add_argument("--layout", default=None, help="QA layout (default <root>/layouts/q1_calibration.hdlayout, else real_art_test)")
	ap.add_argument("--targets", default=DEFAULT_TARGETS)
	ap.add_argument("--zooms", default="0.5,1,2")
	ap.add_argument("--size", default="1920x1080")
	ap.add_argument("--out", default=None, help="output folder (default <root>/screens/calibration/<date>)")
	ap.add_argument("--godot", default=None)
	ap.add_argument("--annotate-only", default=None, help="annotate the shots of an existing folder and exit")
	a = ap.parse_args()
	if a.annotate_only:
		folder = Path(a.annotate_only)
		meta = json.loads((folder / "targets.json").read_text(encoding="utf-8")) if (folder / "targets.json").exists() else None
		for p in sorted(folder.glob("calib_*.png")):
			if not p.name.endswith(".annot.png"):
				annotate(p)
		if meta:
			for t in meta["targets"]:
				ann = [next(iter(folder.glob(f"calib_*_at_{t['tile'][0]}_{t['tile'][1]}_{z}.annot.png")), None) for z in meta["zooms"]]
				sheet_for(t, [x for x in ann if x], folder)
		return 0
	root = private_root(a.root)
	if root is None:
		print("no private root: pass --root")
		return 1
	pack_dir = Path(a.pack_dir) if a.pack_dir else installed_pack_dir()
	if not (pack_dir / "pack.json").is_file():
		print(f"no pack at {pack_dir}")
		return 1
	out = Path(a.out) if a.out else root / "screens" / "calibration" / dt.date.today().isoformat()
	if git_tree_of(out if out.exists() else out.parent):
		print("refusing to write private screenshots inside a git work tree")
		return 1
	out.mkdir(parents=True, exist_ok=True)
	layout = Path(a.layout) if a.layout else next((p for p in (root / "layouts" / "q1_calibration.hdlayout",
		root / "layouts" / "real_art_test.hdlayout") if p.exists()), None)
	if layout is None or not layout.exists():
		print("no QA layout: make one with tools/private_assets/make_test_layout.gd (--out=...)")
		return 1
	world = json.loads((pack_dir / "world" / "world.json").read_text(encoding="utf-8")) if (pack_dir / "world" / "world.json").exists() else {}
	targets = resolve_targets(a.targets.split(";") if ";" in a.targets else a.targets.split(","), world,
		json.loads(layout.read_text(encoding="utf-8")))
	zooms = [z.strip() for z in a.zooms.split(",") if z.strip()]
	scen = [f"at_{t['tile'][0]}_{t['tile'][1]}_{z}" for t in targets for z in zooms]
	godot = find_godot(a.godot)
	if godot is None:
		print("Godot not found")
		return 1
	data = isolated_data_dir(pack_dir)
	try:
		log = run_capture(godot, data, layout, out, scen, a.size)
	finally:
		shutil.rmtree(data, ignore_errors=True)
	(out / "capture.log").write_text(log, encoding="utf-8")
	(out / "targets.json").write_text(json.dumps({"targets": targets, "zooms": zooms, "layout": str(layout),
		"pack_dir": str(pack_dir), "PRIVATE": True}, indent=1), encoding="utf-8")
	shots = {}
	for line in log.splitlines():
		if line.startswith(("SHOT ", "FAIL ")):
			p = Path(line.split(" ")[1])
			if "_at_" in p.stem:
				shots[p.stem[p.stem.index("_at_") + 1:]] = p
			if line.startswith("FAIL"):
				print(line)
	sheets = []
	for t in targets:
		ann = []
		for z in zooms:
			p = shots.get(f"at_{t['tile'][0]}_{t['tile'][1]}_{z}")
			ann.append(annotate(p) if p else None)
		s = sheet_for(t, [x for x in ann if x], out)
		if s:
			sheets.append(s)
	print(f"{len(shots)} shots, {len(sheets)} sheets in {out}")
	return 0 if sheets else 1


if __name__ == "__main__":
	sys.exit(main())
