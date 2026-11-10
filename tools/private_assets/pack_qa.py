#!/usr/bin/env python3
"""Read-only QA of the installed private asset pack: report + contact sheets.

PERSONAL USE ONLY. The report and the sheets show / name files of the private pack, so they go only to the private root
(default <root>/qa/<YYYY-MM-DD>/). The tool refuses an output folder inside a git work tree. It contains no art and
no game data itself.

What it does
  1. Finds the installed pack (Windows %APPDATA%\\HaydaySandbox\\asset_packs\\hayday_original, Linux
     $XDG_DATA_HOME or ~/.local/share/HaydaySandbox/..., or --pack-dir) and the private root.
  2. Runs tools/private_assets/pack_qa.gd headless with a fresh, empty temporary user-data folder (APPDATA /
     XDG_DATA_HOME), so the app's own settings, layouts and the installed pack are never written. The pack is only
     read in place.
  3. Draws contact sheets from pack_qa.json with Pillow (skipped with a note when Pillow is missing): every flagged
     sprite, all landmarks, connection pieces per group, hand-drawn mirrors next to the app's flip, and a sample per
     category. Each cell shows the sprite at a known world scale, the footprint diamond with its tile grid around
     the anchor and the anchor itself (red cross = the ground centre the app places on the footprint).

Usage
  python3 tools/private_assets/pack_qa.py [--root R] [--pack-dir D] [--out O] [--godot G] [--no-sheets]
  Windows:  py tools\\private_assets\\pack_qa.py      (Godot from --godot, $env:GODOT or PATH)
  Sheets only from an existing report:  --sheets-only <report folder>
Exit code: 0 report written, 1 bad input / refused output / Godot failed.
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
PACK_ID = "hayday_original"


def private_root(explicit: str | None) -> Path | None:
	if explicit:
		return Path(explicit)
	env = os.environ.get("HAYDAY_PRIVATE_ASSETS")
	if env:
		return Path(env)
	home = Path(os.environ.get("USERPROFILE") or Path.home()) if os.name == "nt" else Path.home()
	for c in (home / "hayday-sandbox-private-assets", Path("/root/hayday-sandbox-private-assets")):
		if c.is_dir():
			return c
	return None


def installed_pack_dir(pack_id: str = PACK_ID) -> Path:
	"""Where the app installs packs for THIS user (read before the run isolates APPDATA / XDG_DATA_HOME)."""
	if os.name == "nt":
		base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
	elif sys.platform == "darwin":
		base = Path.home() / "Library" / "Application Support"
	else:
		base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
	return base / "HaydaySandbox" / "asset_packs" / pack_id


def git_tree_of(p: Path) -> Path | None:
	p = p.resolve()
	for d in [p, *p.parents]:
		if (d / ".git").exists():
			return d
	return None


def find_godot(explicit: str | None) -> str | None:
	for c in (explicit, os.environ.get("GODOT"), shutil.which("godot"), shutil.which("godot.exe")):
		if c and (Path(c).exists() or shutil.which(c)):
			return c
	return None


def run_qa(godot: str, pack_dir: Path, out: Path) -> int:
	tmp = Path(tempfile.mkdtemp(prefix="hds_pack_qa_"))
	env = dict(os.environ)
	env["XDG_DATA_HOME"] = str(tmp)   # Linux user:// -> empty temp folder
	env["APPDATA"] = str(tmp)         # Windows user:// -> empty temp folder
	cmd = [godot, "--headless", "--path", str(REPO), "--script", "res://tools/private_assets/pack_qa.gd", "--",
		"--pack-dir", str(pack_dir), "--out", str(out)]
	try:
		r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=3600)
	finally:
		shutil.rmtree(tmp, ignore_errors=True)
	for line in (r.stdout or "").splitlines():
		if line.startswith("PACK-QA") or "ERROR" in line:
			print(line)
	if r.returncode != 0:
		sys.stderr.write((r.stderr or "")[-4000:])
	return r.returncode


# --- contact sheets ---------------------------------------------------------------

CELL = 210
LABEL_H = 30
COLS = 6


def _font(size: int = 11):
	from PIL import ImageFont
	try:
		return ImageFont.load_default(size=size)
	except TypeError:
		return ImageFont.load_default()


def _diamond(fx: int, fy: int) -> dict:
	"""Corners of the footprint diamond relative to its ground centre, world px (one tile = 64 x 32)."""
	def iso(x: float, y: float) -> tuple[float, float]:
		return ((x - y) * 32.0, (x + y) * 16.0)
	return {"top": iso(-fx / 2, -fy / 2), "right": iso(fx / 2, -fy / 2), "bottom": iso(fx / 2, fy / 2), "left": iso(-fx / 2, fy / 2), "iso": iso}


def draw_cell(sheet, x0: int, y0: int, c: dict, font, size: int = CELL) -> None:
	from PIL import Image, ImageDraw, ImageOps
	d = ImageDraw.Draw(sheet)
	# light checker so transparent art and shadows stay visible
	for yy in range(0, size, 15):
		for xx in range(0, size, 15):
			if (xx // 15 + yy // 15) % 2 == 0:
				d.rectangle([x0 + xx, y0 + yy, x0 + min(size, xx + 15) - 1, y0 + min(size, yy + 15) - 1], fill=(226, 230, 222))
	d.rectangle([x0, y0, x0 + size - 1, y0 + size + LABEL_H - 1], outline=(150, 150, 150))
	try:
		img = Image.open(c["path"]).convert("RGBA")
	except Exception as ex:  # noqa: BLE001 - shown in the cell
		d.text((x0 + 4, y0 + 4), f"cannot open: {ex}"[:60], fill=(200, 0, 0), font=font)
		return
	ppw = float(c.get("ppw") or 1.0)
	ax, ay = (float(c["anchor"][0]), float(c["anchor"][1]))
	if c.get("flip"):
		img = ImageOps.mirror(img)
		ax = img.width - ax
	fx, fy = int(c["fp"][0]), int(c["fp"][1])
	dm = _diamond(fx, fy)
	# world-px bounds of sprite + diamond around the anchor (anchor = 0, 0)
	sx0, sy0 = -ax / ppw, -ay / ppw
	sx1, sy1 = sx0 + img.width / ppw, sy0 + img.height / ppw
	bx0 = min(sx0, dm["left"][0]); bx1 = max(sx1, dm["right"][0])
	by0 = min(sy0, dm["top"][1]); by1 = max(sy1, dm["bottom"][1])
	z = min(2.0, (size - 12) / max(1.0, bx1 - bx0), (size - 12) / max(1.0, by1 - by0))   # sheet px per world px
	ox = x0 + size / 2 - (bx0 + bx1) / 2 * z
	oy = y0 + size / 2 - (by0 + by1) / 2 * z
	w = max(1, round(img.width / ppw * z)); h = max(1, round(img.height / ppw * z))
	small = img.resize((w, h), Image.LANCZOS)
	sheet.alpha_composite(small, (round(ox + sx0 * z), round(oy + sy0 * z)))
	P = lambda p: (ox + p[0] * z, oy + p[1] * z)   # noqa: E731
	# tile grid inside the footprint, then its outline
	iso = dm["iso"]
	for i in range(1, fx):
		d.line([P(iso(-fx / 2 + i, -fy / 2)), P(iso(-fx / 2 + i, fy / 2))], fill=(40, 120, 255), width=1)
	for j in range(1, fy):
		d.line([P(iso(-fx / 2, -fy / 2 + j)), P(iso(fx / 2, -fy / 2 + j))], fill=(40, 120, 255), width=1)
	d.polygon([P(dm["top"]), P(dm["right"]), P(dm["bottom"]), P(dm["left"])], outline=(0, 90, 255))
	cx, cy = P((0, 0))
	d.line([(cx - 6, cy), (cx + 6, cy)], fill=(230, 0, 0), width=2)
	d.line([(cx, cy - 6), (cx, cy + 6)], fill=(230, 0, 0), width=2)
	label = str(c.get("label", ""))
	flags = c.get("flags") or []
	d.rectangle([x0 + 1, y0 + size, x0 + size - 2, y0 + size + LABEL_H - 2], fill=(255, 255, 255))
	d.text((x0 + 3, y0 + size + 1), f"{label[:34]}  {fx}x{fy} z{z:.2f}", fill=(0, 0, 0), font=font)
	if flags:
		d.text((x0 + 3, y0 + size + 14), "; ".join(flags)[:40], fill=(190, 0, 0), font=font)


def sheet_pages(cells: list, title: str, out: Path, stem: str, cols: int = COLS, rows: int = 6) -> list[Path]:
	from PIL import Image, ImageDraw
	font = _font()
	written = []
	per = cols * rows
	for pg in range(math.ceil(len(cells) / per) if cells else 0):
		part = cells[pg * per:(pg + 1) * per]
		nrows = math.ceil(len(part) / cols)
		sheet = Image.new("RGBA", (cols * CELL, 24 + nrows * (CELL + LABEL_H)), (250, 250, 248, 255))
		ImageDraw.Draw(sheet).text((6, 5), f"{title}  (page {pg + 1}; PRIVATE - personal use only)", fill=(0, 0, 0), font=_font(13))
		for i, c in enumerate(part):
			draw_cell(sheet, (i % cols) * CELL, 24 + (i // cols) * (CELL + LABEL_H), c, font)
		p = out / f"{stem}_{pg + 1:02d}.png"
		sheet.convert("RGB").save(p)
		written.append(p)
	return written


def make_sheets(out: Path) -> list[Path]:
	try:
		import PIL  # noqa: F401
	except ImportError:
		print("Pillow is not installed: no contact sheets (pip install pillow)")
		return []
	rep = json.loads((out / "pack_qa.json").read_text(encoding="utf-8"))
	plan = rep.get("sheets", {})
	sd = out / "sheets"
	if sd.is_dir():   # sheets of an earlier run of the same day
		for old in sd.glob("*.png"):
			old.unlink()
	sd.mkdir(exist_ok=True)
	written = []
	written += sheet_pages(plan.get("flagged", []), "Flagged sprites", sd, "flagged")
	written += sheet_pages(plan.get("landmarks", []), "Landmarks (lm_*)", sd, "landmarks")
	conn = []
	for g in plan.get("connections", []):
		conn += g["cells"][:16] + [None] * (16 - len(g["cells"][:16]))
	written += sheet_pages([c for c in conn if c], "Connection pieces (one item per row, masks 0-15)", sd, "connections", cols=8, rows=8)
	pairs = []
	for pr in plan.get("mirrors", []):
		pairs += pr
	written += sheet_pages(pairs, "Mirrors: app flip | client mirror art", sd, "mirrors", cols=6, rows=6)
	for cat, cells in sorted(plan.get("categories", {}).items()):
		written += sheet_pages(cells, f"Category sample: {cat}", sd, f"cat_{cat}", cols=6, rows=4)
	return written


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
	ap.add_argument("--root", default=None, help="private root (default $HAYDAY_PRIVATE_ASSETS or ~/hayday-sandbox-private-assets)")
	ap.add_argument("--pack-dir", default=None, help=f"installed pack folder (default the app's user folder / {PACK_ID})")
	ap.add_argument("--out", default=None, help="report folder (default <root>/qa/<YYYY-MM-DD>)")
	ap.add_argument("--godot", default=None, help="Godot 4.7.2 executable (default $GODOT or godot on PATH)")
	ap.add_argument("--no-sheets", action="store_true", help="report only")
	ap.add_argument("--sheets-only", default=None, help="draw the sheets of an existing report folder and exit")
	a = ap.parse_args()
	if a.sheets_only:
		out = Path(a.sheets_only)
		if git_tree_of(out):
			print(f"refusing to write inside the git work tree {git_tree_of(out)}")
			return 1
		print(f"{len(make_sheets(out))} sheet(s) in {out / 'sheets'}")
		return 0
	root = private_root(a.root)
	pack_dir = Path(a.pack_dir) if a.pack_dir else installed_pack_dir()
	if not (pack_dir / "pack.json").is_file():
		print(f"no installed pack at {pack_dir} (use --pack-dir)")
		return 1
	if a.out:
		out = Path(a.out)
	elif root is not None:
		out = root / "qa" / dt.date.today().isoformat()
	else:
		print("no private root found: pass --root or --out")
		return 1
	g = git_tree_of(out.parent if not out.exists() else out)
	if g is not None:
		print(f"refusing to write the private QA report inside the git work tree {g}")
		return 1
	out.mkdir(parents=True, exist_ok=True)
	godot = find_godot(a.godot)
	if godot is None:
		print("Godot not found: pass --godot or set GODOT")
		return 1
	rc = run_qa(godot, pack_dir, out)
	if rc != 0 or not (out / "pack_qa.json").is_file():
		print(f"pack_qa.gd failed (exit {rc})")
		return 1
	if not a.no_sheets:
		sheets = make_sheets(out)
		print(f"{len(sheets)} sheet(s) in {out / 'sheets'}")
	print(f"report: {out / 'pack_qa.md'}")
	return 0


if __name__ == "__main__":
	sys.exit(main())
