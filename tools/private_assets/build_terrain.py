#!/usr/bin/env python3
"""Build the PRIVATE terrain of the "hayday_original" asset pack (format hayday-sandbox-terrain, schema 1).

PERSONAL USE ONLY. The output is derived from the user's own client files (the user states that Supercell support
authorised personal use on condition that nothing is redistributed). So, like build_pack.py:
  * this tool contains no art and no game numbers (export names, anchors, colours and clip ids all come from the
    private inputs below);
  * it refuses to write inside a git work tree; output goes to the private root and, with --install-dir, into an
    installed pack folder (user://asset_packs/<id>/terrain/);
  * nothing is uploaded anywhere. Never commit, zip for others or share the output.

Inputs (all private):
  <client>/sc/<sc>.sc (+ textures)  the client's background art (default <root>/raw/apk_extracted/<newest>/assets)
  <client>/data/themes.csv          theme -> export-name postfix (the season variants and the themes table)
  <client>/data/game_config.csv     BackgroundColor (the clear colour)
  --placement JSON                  where each background export goes: the terrain research's
                                    terrain_manifest.json ({"seasons": {"default": [{export, z, anchor_tile_game,
                                    confidence, evidence}]}}) or {"pieces": [{export, z, anchor_tile, ...}]}
                                    (default <root>/research/terrain/terrain_manifest.json)
  --world world.json                build_world.py's world: tile_types[].art names the ground-tile exports
                                    (default <root>/packs/hayday_original_world/world/world.json)

Output (<out>/terrain/, default <out> = <root>/packs/hayday_original_terrain):
  terrain.json                 manifest (docs/TERRAIN_PACKS.md): base "color", background colour, atlases, tiles,
                               themes, default pieces + one piece list per season variant, clips, extents
  atlas/<sc>_<i>.png           the client atlases the meshes use (straight alpha, colour bled under transparency)
  meshes/<export>.mesh.json    "mesh replay": every draw command of the export as triangles (world px relative to
                               its registration point, uvs, colour multipliers, add terms); stays sharp at any zoom
                               and needs no giant raster. Degenerate-uv draws (one texel = a solid fill, e.g. a
                               water body) keep their uvs, so they draw as the solid colour the client draws.
  tiles/<export>.png           one image per ground-tile export (+ season variants by the postfix rule); separate
                               images, so far-zoom mipmaps never bleed between atlas neighbours
  clips.json                   nested animated clips found inside the exports (e.g. water glints): shapes + per-frame
                               affine matrices and colour multipliers; their instances sit on the pieces
  raster/<export>.png          only with --raster EXPORT: that export as one image rendered by extract_from_apk.py's
                               fixed renderer (2 px per world px) instead of a mesh
  hashes.json, build_report.json   sha256 of every output (leak guard) and the build log/timings

Modes:
  python3 tools/private_assets/build_terrain.py                       # build into <root>/packs/hayday_original_terrain
  python3 tools/private_assets/build_terrain.py --install-dir ~/.local/share/HaydaySandbox/asset_packs/hayday_original
        # ... and add it to an installed pack: backup first (<root>/archive/installed_<version>/), copy terrain/,
        # pack.json "terrain" + a "-t<digest>" version suffix, hashes.json outputs
  python3 tools/private_assets/build_terrain.py --validate [terrain.json]   # tools/ci/check_terrain_pack.gd on it
  python3 tools/private_assets/build_terrain.py --self-test            # synthetic client data in a temp folder

Requires Python 3.10+, Pillow and numpy; reads the .sc files with tools/private_assets/extract_from_apk.py.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
	import numpy as np
	from PIL import Image
except ImportError:  # pragma: no cover
	sys.exit("Pillow and numpy are required: pip install pillow numpy")

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parents[1]
sys.path.insert(0, str(TOOLS_DIR))
import extract_from_apk as X  # noqa: E402

Image.MAX_IMAGE_PIXELS = 200_000_000
DEFAULT_ROOT = Path(os.environ.get("HAYDAY_PRIVATE_ASSETS", "/root/hayday-sandbox-private-assets"))
OUT_DIR_NAME = "hayday_original_terrain"
WORLD_DIR_NAME = "hayday_original_world"
TOOL_VERSION = "1.0"
FORMAT = "hayday-sandbox-terrain"
SCHEMA_VERSION = 1
# Frame conversion (not a game fact): one tile is 128 x 64 SC units in client exports and 64 x 32 world px in the app.
WORLD_PX_PER_SC = 0.5
RASTER_SCALE = 1.0                 # --raster: px per SC unit (= 2 px per world px, the art's native density)
TEXELS_PER_WORLD_PX = 2.0          # default "pixels_per_world_px" of the manifest (image pieces)
IDENT = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
CT_IDENT = ((255.0, 255.0, 255.0, 255.0), (0.0, 0.0, 0.0))


# ------------------------------------------------------------------------------------------------ utilities
def now_iso() -> str:
	return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def log(msg: str) -> None:
	print(msg, flush=True)


def inside_git_worktree(p: Path) -> Path | None:
	p = p.resolve()
	for parent in [p, *p.parents]:
		if (parent / ".git").exists():
			return parent
	return None


def ensure_private(p: Path, what: str) -> Path:
	p = Path(p).expanduser().resolve()
	wt = inside_git_worktree(p)
	if wt is not None or p == REPO_ROOT or REPO_ROOT in p.parents:
		raise SystemExit(f"refusing to write {what} inside a git work tree ({wt or REPO_ROOT}): game-derived data must stay private")
	return p


def read_json(p: Path, default=None):
	try:
		with open(p, encoding="utf-8") as f:
			return json.load(f)
	except (OSError, ValueError):
		return default


def write_json(p: Path, data, compact: bool = False) -> None:
	p.parent.mkdir(parents=True, exist_ok=True)
	tmp = p.with_name(p.name + ".tmp")
	with open(tmp, "w", encoding="utf-8") as f:
		if compact:
			json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
		else:
			json.dump(data, f, ensure_ascii=False, indent=1)
	os.replace(tmp, p)


def sha256_file(p: Path) -> str:
	h = hashlib.sha256()
	with open(p, "rb") as f:
		for chunk in iter(lambda: f.read(1 << 20), b""):
			h.update(chunk)
	return h.hexdigest()


def _version_tuple(v: str):
	return tuple(int(x) if x.isdigit() else 0 for x in re.split(r"[.\-_]", v))


def read_csv_rows(p: Path) -> list[dict]:
	"""Supercell CSV: header row, type row, data rows -> list of dicts (missing file -> [])."""
	if not p.is_file():
		return []
	with open(p, encoding="utf-8-sig", newline="") as f:
		rows = list(csv.reader(f))
	if len(rows) < 2:
		return []
	hdr = rows[0]
	return [dict(zip(hdr, r)) for r in rows[2:] if any(c.strip() for c in r)]


def config_value(rows: list[dict], name: str) -> str | None:
	"""game_config.csv: the first non-empty value column of the row called ``name``."""
	for r in rows:
		vals = list(r.values())
		if vals and vals[0] == name:
			for v in vals[1:]:
				if v and v.strip():
					return v.strip()
	return None


def argb_to_html(v: str | None) -> str | None:
	"""'FFrrggbb' / '#rrggbb' / 'rrggbb' -> '#rrggbb' (None when unreadable)."""
	if not v:
		return None
	s = v.strip().lstrip("#")
	if re.fullmatch(r"[0-9A-Fa-f]{8}", s):
		s = s[2:]
	if re.fullmatch(r"[0-9A-Fa-f]{6}", s):
		return "#" + s.lower()
	return None


def bleed(img: Image.Image) -> Image.Image:
	"""Straight-alpha RGBA with colour pushed under every transparent texel (push-pull pyramid), so filtering and
	mipmaps never pull in black fringes. Visible texels are unchanged."""
	arr = np.asarray(img.convert("RGBA"), np.float32)
	rgb = arr[..., :3]
	w = (arr[..., 3] > 0).astype(np.float32)
	if w.all() or not w.any():
		return img.convert("RGBA")
	pyr = []
	c, ww = rgb * w[..., None], w
	while True:
		pyr.append((c, ww))
		h, wd = ww.shape
		if h == 1 and wd == 1:
			break
		ph, pw = h % 2, wd % 2
		c2 = np.pad(c, ((0, ph), (0, pw), (0, 0)))
		w2 = np.pad(ww, ((0, ph), (0, pw)))
		c = c2.reshape(c2.shape[0] // 2, 2, c2.shape[1] // 2, 2, 3).sum((1, 3))
		ww = w2.reshape(w2.shape[0] // 2, 2, w2.shape[1] // 2, 2).sum((1, 3))
	col = pyr[-1][0] / max(float(pyr[-1][1].max()), 1e-6)
	for c, ww in reversed(pyr[:-1]):
		up = np.repeat(np.repeat(col, 2, 0), 2, 1)[:ww.shape[0], :ww.shape[1]]
		col = np.where(ww[..., None] > 0, c / np.maximum(ww, 1e-6)[..., None], up)
	out = arr.copy()
	out[..., :3] = np.where(w[..., None] > 0, rgb, col)
	return Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGBA")


# ------------------------------------------------------------------------------------------------ inputs
def default_client_dir(root: Path) -> Path | None:
	base = root / "raw" / "apk_extracted"
	vers = sorted((p for p in base.glob("*") if (p / "assets" / "sc").is_dir()), key=lambda p: _version_tuple(p.name))
	return vers[-1] / "assets" if vers else None


def load_swf(client: Path, sc: str):
	"""The .sc file with decoded textures (extract_from_apk.py), or SystemExit."""
	sc_dir = client / "sc"
	p = sc_dir / f"{sc}.sc"
	if not p.is_file():
		raise SystemExit(f"no {p} (extract the client with extract_from_apk.py first)")
	raw = p.read_bytes()
	if X.is_sc2(raw):
		swf = X.parse_sc2(raw, sc)
	else:
		body, _ = X.decompress_sc(raw, sc)
		swf = X.parse_sc(body, sc, is_tex=False)
		if swf.flags.get("external_texture"):
			tb, _ = X.decompress_sc((sc_dir / f"{sc}_tex.sc").read_bytes(), sc)
			X.parse_sc(tb, sc, is_tex=True, swf=swf)

	def ext(n):
		q = sc_dir / n
		return q.read_bytes() if q.exists() else None
	warns = X.load_textures(swf, "auto", ext)
	for w in warns:
		log(f"texture warning: {w}")
	return swf


def load_placement(path: Path) -> list[dict]:
	"""Normalised base placement [{export, anchor_tile, z, confidence, evidence}] in draw order."""
	d = read_json(path)
	if not isinstance(d, dict):
		raise SystemExit(f"placement file {path} is missing or not a JSON object")
	rows = None
	if isinstance(d.get("pieces"), list):
		rows = d["pieces"]
	elif isinstance(d.get("seasons"), dict) and isinstance(d["seasons"].get("default"), list):
		rows = d["seasons"]["default"]
	if not rows:
		raise SystemExit(f"placement file {path} has no 'pieces' list or 'seasons.default' list")
	out = []
	for i, r in enumerate(rows):
		if not isinstance(r, dict) or not r.get("export"):
			raise SystemExit(f"placement row {i} has no export name")
		at = r.get("anchor_tile", r.get("anchor_tile_game"))
		if not (isinstance(at, list) and len(at) == 2 and all(isinstance(v, (int, float)) for v in at)):
			raise SystemExit(f"placement row {i} ({r['export']}) has no anchor_tile [x, y]")
		out.append({"export": str(r["export"]), "anchor_tile": [float(at[0]), float(at[1])],
			"z": float(r.get("z", i)), "confidence": r.get("confidence"), "evidence": r.get("evidence"),
			"kind": r.get("kind")})
	out.sort(key=lambda r: r["z"])
	return out


def theme_postfixes(rows: list[dict]) -> list[tuple[str, str]]:
	"""[(theme name, postfix)] from themes.csv (postfix '' = the default art)."""
	return [(r.get("Name", "").strip(), (r.get("ExportNamePostfix") or "").strip()) for r in rows if r.get("Name", "").strip()]


def world_art_keys(world: dict | None) -> list[str]:
	"""Every tile art key the world's tile types use (their own and their unlocked look)."""
	keys = []
	tt = (world or {}).get("tile_types") or {}
	for e in tt.values():
		if isinstance(e, dict) and isinstance(e.get("art"), str) and e["art"]:
			keys.append(e["art"])
	return sorted(set(keys))


# ------------------------------------------------------------------------------------------------ geometry
def kind_of(export: str) -> str:
	"""A free diagnostic label for a piece (docs/TERRAIN_PACKS.md: 'kind')."""
	n = export.lower()
	for word in ("deco", "forest", "tile", "edge"):
		if word in n:
			return {"tile": "edge"}.get(word, word)
	return "background"


class Flattener:
	"""Flattens an export at frame 0 into draw ops ("draw", cmd, matrix, colour transform, blend) - like
	extract_from_apk.Renderer.display_list - but stops at nested clips with more than one frame: those are animations
	(their instances are returned instead of being baked into the static mesh)."""

	def __init__(self, swf, rend):
		self.swf = swf
		self.rend = rend

	def flatten(self, oid: int) -> tuple[list, list, list[str]]:
		ops, anims, warns = [], [], []
		self._walk(oid, IDENT, CT_IDENT, 0, ops, anims, warns, 0, True)
		return ops, anims, warns

	def _walk(self, oid, m, ct, blend, ops, anims, warns, depth, root):
		swf = self.swf
		if depth > 64:
			warns.append("max nesting depth reached")
			return
		if oid in swf.shapes:
			for cmd in swf.shapes[oid].commands:
				if self.rend.is_runtime_placeholder(cmd):
					continue
				ops.append(("draw", cmd, m, ct, blend))
			return
		if oid in swf.modifiers:
			if "masks are not supported (drawn unmasked)" not in warns:
				warns.append("masks are not supported (drawn unmasked)")
			return
		if oid in swf.textfields:
			return
		clip = swf.clips.get(oid)
		if clip is None or not clip.frames:
			return
		if not root and len(clip.frames) > 1:
			anims.append({"clip": oid, "m": m, "ct": ct})
			return
		if root and len(clip.frames) > 1:
			warns.append(f"export has {len(clip.frames)} frames; frame 0 is used")
		count = clip.frames[0][0]
		bank = swf.banks[clip.bank] if clip.bank < len(swf.banks) else swf.banks[0]
		for ci, mi, ki in clip.elements[:count]:
			if ci >= len(clip.children):
				continue
			cm = bank["m"][mi] if mi != 0xFFFF and mi < len(bank["m"]) else IDENT
			cc = bank["c"][ki] if ki != 0xFFFF and ki < len(bank["c"]) else CT_IDENT
			b = clip.blends[ci] if ci < len(clip.blends) else 0
			self._walk(clip.children[ci], X.mat_mul(m, cm), X.ct_mul(ct, cc), b if b not in (0, 1) else blend,
				ops, anims, warns, depth + 1, False)


def mesh_of(swf, ops) -> tuple[list[dict], list[str]]:
	"""Mesh replay: one mesh dict per atlas used (in first-use order)."""
	meshes: dict[int, dict] = {}
	warns = []
	for op in ops:
		_, cmd, m, ct = op[:4]
		blend = op[4] if len(op) > 4 else 0
		tex = swf.textures[cmd.tex] if cmd.tex < len(swf.textures) else None
		if tex is None or tex.image is None or len(cmd.xy) < 3 or len(cmd.uv) != len(cmd.xy):
			continue
		me = meshes.setdefault(cmd.tex, {"tex": cmd.tex, "positions": [], "uvs": [], "colors": [], "indices": [],
			"add_ops": [], "blend_ops": []})
		w = X._world(cmd.xy, m)
		uv = X.Renderer._uv_px(cmd, tex)
		(rm, gm, bm, am), (ra, ga, ba) = ct
		base = len(me["positions"]) // 2
		for (x, y), (u, v) in zip(w, uv):
			me["positions"] += [round(x * WORLD_PX_PER_SC, 2), round(y * WORLD_PX_PER_SC, 2)]
			me["uvs"] += [round(u / tex.w, 6), round(v / tex.h, 6)]
			me["colors"] += [round(rm / 255, 4), round(gm / 255, 4), round(bm / 255, 4), round(am / 255, 4)]
		n = len(w)
		first = len(me["indices"])
		for k in range(1, n - 1):
			me["indices"] += [base, base + k, base + k + 1]
		cnt = len(me["indices"]) - first
		if (ra, ga, ba) != (0, 0, 0):
			me["add_ops"].append({"first_index": first, "index_count": cnt, "add_rgb": [round(ra / 255, 4), round(ga / 255, 4), round(ba / 255, 4)]})
		if blend not in (0, 1):
			me["blend_ops"].append({"first_index": first, "index_count": cnt, "mode": int(blend)})
			if "non-normal blend modes (blend_ops; a mesh with one mode throughout gets the piece 'blend', else drawn normal)" not in warns:
				warns.append("non-normal blend modes (blend_ops; a mesh with one mode throughout gets the piece 'blend', else drawn normal)")
	out = []
	for me in meshes.values():
		pos = me["positions"]
		xs, ys = pos[0::2], pos[1::2]
		me["bbox_world"] = [min(xs), min(ys), max(xs), max(ys)] if xs else [0, 0, 0, 0]
		me["vertex_count"] = len(pos) // 2
		me["triangle_count"] = len(me["indices"]) // 3
		if not me["blend_ops"]:
			del me["blend_ops"]
		out.append(me)
	return out, warns


def clip_frames(swf, rend, cid: int, shapes: dict, shape_key) -> dict:
	"""An animated clip: per frame the shape commands it shows with a world-px affine and a colour multiplier
	(nested clips inside the frame are flattened at their frame 0)."""
	c = swf.clips[cid]
	bank = swf.banks[c.bank] if c.bank < len(swf.banks) else swf.banks[0]
	frames, st = [], 0
	add_seen = False
	for n, _label in c.frames:
		els = []
		for ci, mi, ki in c.elements[st:st + n]:
			cm = bank["m"][mi] if mi != 0xFFFF and mi < len(bank["m"]) else IDENT
			cc = bank["c"][ki] if ki != 0xFFFF and ki < len(bank["c"]) else CT_IDENT
			sub = Flattener(swf, rend)
			ops: list = []
			anims: list = []
			sub._walk(c.children[ci], cm, cc, 0, ops, anims, [], 1, True)
			for op in ops:
				_, cmd, m, ct = op[:4]
				key = shape_key(cmd)
				if key is None:
					continue
				el = {"shape": key, "m": [round(v, 4) for v in m[:4]] + [round(m[4] * WORLD_PX_PER_SC, 3), round(m[5] * WORLD_PX_PER_SC, 3)],
					"mul": [round(v / 255, 3) for v in ct[0]]}
				if ct[1] != (0.0, 0.0, 0.0) and any(ct[1]):
					add_seen = True
					el["add"] = [round(v / 255, 4) for v in ct[1]]  # colour-add term (rgb), drawn by the app's add pass
				els.append(el)
		st += n
		frames.append(els)
	out = {"fps": c.fps or 30, "frame_count": len(frames), "frames": frames}
	if add_seen:
		out["note"] = "some frames carry a colour add term ('add')"
	return out


# ------------------------------------------------------------------------------------------------ builder
class TerrainBuilder:
	def __init__(self, swf, sc: str, data_dir: Path, placement: list[dict], world: dict | None, out: Path,
			raster: set[str] | None = None, source: dict | None = None):
		self.swf, self.sc, self.data_dir, self.placement, self.world = swf, sc, data_dir, placement, world
		self.out = out
		self.tdir = out / "terrain"
		self.raster = set(raster or ())
		self.source = source or {}
		self.rend = X.Renderer(swf)
		self.flat = Flattener(swf, self.rend)
		self.exports = {n: i for i, n in swf.exports}
		self.warnings: list[str] = []
		self.timings: dict[str, float] = {}
		self.atlases_used: set[int] = set()
		self.shapes: dict = {}
		self.clips: dict = {}
		self._cmd_keys: dict[int, str] = {}
		for sid, sh in swf.shapes.items():
			for k, cmd in enumerate(sh.commands):
				self._cmd_keys[id(cmd)] = f"shape_{sid}" + (f"_{k}" if len(sh.commands) > 1 else "")
		self._piece_cache: dict[str, dict] = {}

	def warn(self, msg: str) -> None:
		if msg not in self.warnings:
			self.warnings.append(msg)
			log("warning: " + msg)

	# --- variants / themes
	def variants(self) -> tuple[dict[str, str], dict[str, str]]:
		"""({variant: postfix} for variants with art, {theme (lower case): variant})."""
		rows = theme_postfixes(read_csv_rows(self.data_dir / "themes.csv"))
		bases = {r["export"] for r in self.placement} | set(world_art_keys(self.world))
		var: dict[str, str] = {}
		themes: dict[str, str] = {}
		for name, pf in rows:
			if not pf:
				themes[name.lower()] = "default"
				continue
			v = re.sub(r"[^a-z0-9_]", "", pf.lstrip("_").lower())
			if not v or v == "default":
				continue
			if any(b + pf in self.exports for b in bases):
				var[v] = pf
				themes[name.lower()] = v
			else:
				themes[name.lower()] = "default"   # e.g. a postfix without background art: the client falls back
		return var, themes

	def resolve(self, export: str, postfix: str) -> str:
		return export + postfix if postfix and export + postfix in self.exports else export

	# --- pieces
	def build_piece_files(self, export: str) -> dict:
		"""Mesh (or raster) files + clip instances of one export (cached)."""
		if export in self._piece_cache:
			return self._piece_cache[export]
		oid = self.exports[export]
		ops, anims, warns = self.flat.flatten(oid)
		for w in warns:
			self.warn(f"{export}: {w}")
		entry: dict = {"parts": [], "clips": [], "bbox": None}
		if export in self.raster:
			img, origin = self.rend.render(ops, RASTER_SCALE, max_pixels=200_000_000)
			if img is None:
				self.warn(f"{export}: nothing to rasterise")
			else:
				rel = f"raster/{export}.png"
				p = self.tdir / rel
				p.parent.mkdir(parents=True, exist_ok=True)
				bleed(img).save(p, optimize=False, compress_level=6)
				sc = 1.0 / (RASTER_SCALE / WORLD_PX_PER_SC)
				entry["parts"].append({"file": rel, "origin": [round(origin[0], 3), round(origin[1], 3)], "scale": sc})
				x0, y0 = -origin[0] * sc, -origin[1] * sc
				entry["bbox"] = [round(x0, 2), round(y0, 2), round(x0 + img.width * sc, 2), round(y0 + img.height * sc, 2)]
		else:
			meshes, mw = mesh_of(self.swf, ops)
			for w in mw:
				self.warn(f"{export}: {w}")
			for i, me in enumerate(meshes):
				self.atlases_used.add(me["tex"])
				rel = f"meshes/{export}.mesh.json" if i == 0 else f"meshes/{export}.{i}.mesh.json"
				doc = {"atlas": f"{self.sc}_{me['tex']}", "vertex_count": me["vertex_count"], "triangle_count": me["triangle_count"],
					"bbox_world": me["bbox_world"], "positions": me["positions"], "uvs": me["uvs"], "colors": me["colors"],
					"indices": me["indices"], "add_ops": me["add_ops"]}
				if me.get("blend_ops"):
					doc["blend_ops"] = me["blend_ops"]
				write_json(self.tdir / rel, doc, compact=True)
				part = {"mesh": rel, "vertices": me["vertex_count"]}
				ub = uniform_blend(me)
				if ub is not None:
					part["blend"] = ub
				entry["parts"].append(part)
				b = me["bbox_world"]
				entry["bbox"] = b if entry["bbox"] is None else [min(entry["bbox"][0], b[0]), min(entry["bbox"][1], b[1]),
					max(entry["bbox"][2], b[2]), max(entry["bbox"][3], b[3])]
			if len(meshes) > 1:
				self.warn(f"{export}: draws from {len(meshes)} atlases; split into {len(meshes)} pieces (draw order between them is approximate)")
		for a in anims:
			cid, m = a["clip"], a["m"]
			name = f"{self.sc}_clip_{cid}"
			if name not in self.clips:
				self.clips[name] = clip_frames(self.swf, self.rend, cid, self.shapes, self._shape_key)
			inst = {"clip": name, "x_axis": [round(m[0], 4), round(m[1], 4)], "y_axis": [round(m[2], 4), round(m[3], 4)],
				"origin_world": [round(m[4] * WORLD_PX_PER_SC, 2), round(m[5] * WORLD_PX_PER_SC, 2)]}
			if a["ct"] != CT_IDENT:
				inst["mul"] = [round(v / 255, 3) for v in a["ct"][0]]
				if any(a["ct"][1]):
					inst["add"] = [round(v / 255, 4) for v in a["ct"][1]]
				self.warn(f"{export}: some clip instances carry a colour transform (recorded as 'mul' / 'add')")
			entry["clips"].append(inst)
		self._piece_cache[export] = entry
		return entry

	def _shape_key(self, cmd) -> str | None:
		key = self._cmd_keys.get(id(cmd))
		if key is None:
			return None
		if key not in self.shapes:
			tex = self.swf.textures[cmd.tex] if cmd.tex < len(self.swf.textures) else None
			if tex is None or tex.image is None:
				return None
			uv = X.Renderer._uv_px(cmd, tex)
			self.atlases_used.add(cmd.tex)
			self.shapes[key] = {"atlas": f"{self.sc}_{cmd.tex}",
				"polygon_world": [[round(x * WORLD_PX_PER_SC, 3), round(y * WORLD_PX_PER_SC, 3)] for x, y in cmd.xy],
				"uv": [[round(u / tex.w, 6), round(v / tex.h, 6)] for u, v in uv]}
		return key

	def piece_list(self, postfix: str) -> list[dict]:
		out = []
		count: dict[str, int] = {}
		for r in self.placement:
			if r["export"] not in self.exports:
				self.warn(f"placement export '{r['export']}' is not in {self.sc}.sc (skipped)")
				continue
			ex = self.resolve(r["export"], postfix)
			files = self.build_piece_files(ex)
			for k, part in enumerate(files["parts"]):
				n = count.get(ex, 0)
				count[ex] = n + 1
				p = {"id": f"{ex}#{n}", "kind": r.get("kind") or kind_of(r["export"]), "z": r["z"] + k * 0.001,
					"anchor_tile": r["anchor_tile"]}
				if "mesh" in part:
					p["mesh"] = part["mesh"]
					if "blend" in part:
						p["blend"] = part["blend"]
				else:
					p.update({"type": "image", "file": part["file"], "origin": part["origin"], "scale": part["scale"]})
				if k == 0 and files["clips"]:
					p["clips"] = files["clips"]
				if files["bbox"]:
					p["bbox_world"] = files["bbox"]
				if r.get("confidence"):
					p["confidence"] = r["confidence"]
				if r.get("evidence") and postfix == "":
					p["evidence"] = r["evidence"]
				out.append(p)
		return out

	@staticmethod
	def extent(pieces: list[dict]) -> list[float] | None:
		box = None
		for p in pieces:
			b = p.get("bbox_world")
			if not b:
				continue
			ax, ay = p["anchor_tile"]
			wx, wy = (ax - ay) * 32.0, (ax + ay) * 16.0
			q = [b[0] + wx, b[1] + wy, b[2] + wx, b[3] + wy]
			box = q if box is None else [min(box[0], q[0]), min(box[1], q[1]), max(box[2], q[2]), max(box[3], q[3])]
		return [round(v, 1) for v in box] if box else None

	# --- tiles
	def tile_image(self, export: str) -> Image.Image | None:
		oid = self.exports[export]
		ops, _anims, _w = self.flat.flatten(oid)
		draws = [op for op in ops if op[0] == "draw"]
		if len(draws) == 1:
			_, cmd, m, ct = draws[0][:4]
			tex = self.swf.textures[cmd.tex]
			xy = X._world(cmd.xy, m)
			uv = X.Renderer._uv_px(cmd, tex)
			A = X._affine_from(xy[:3], uv[:3]) if len(xy) >= 3 else None
			xs, ys = [p[0] for p in xy], [p[1] for p in xy]
			us, vs = [p[0] for p in uv], [p[1] for p in uv]
			if A and abs(A[1]) < 1e-6 and abs(A[3]) < 1e-6 and A[0] > 0 and A[4] > 0 and ct == CT_IDENT \
					and abs((max(xs) - min(xs)) - (max(ys) - min(ys))) < 1e-3:
				box = (round(min(us)), round(min(vs)), round(max(us)), round(max(vs)))
				if box[2] > box[0] and box[3] > box[1]:
					return tex.image.convert("RGBA").crop(box)
		# anything else (rotated, several commands, colour transform): render the square as drawn
		img, _ = self.rend.render(ops, 1.0, pad=0)
		if img is None:
			return None
		self.warn(f"tile {export}: not a plain atlas rectangle; rendered")
		return img

	def build_tiles(self, var: dict[str, str]) -> dict:
		tiles = {}
		keys = world_art_keys(self.world)
		if not keys:
			self.warn("no world tile art keys (no --world, or its tile_types have no 'art'): no ground tiles written")
		for k in keys:
			for v, pf in [("", "")] + sorted(var.items()):
				ex = k + pf
				if ex not in self.exports:
					if not pf:
						self.warn(f"tile art '{k}' is not an export of {self.sc}.sc (the app draws that ground itself)")
					continue
				img = self.tile_image(ex)
				if img is None:
					self.warn(f"tile {ex}: empty")
					continue
				rel = f"tiles/{ex}.png"
				(self.tdir / rel).parent.mkdir(parents=True, exist_ok=True)
				img.save(self.tdir / rel, compress_level=6)
				tiles[k if not pf else f"{k}_{v}"] = {"file": rel, "size": list(img.size)}
		return tiles

	# --- main
	def build(self) -> dict:
		t0 = time.time()
		if self.tdir.exists():
			shutil.rmtree(self.tdir)
		self.tdir.mkdir(parents=True)
		var, themes = self.variants()
		gc = read_csv_rows(self.data_dir / "game_config.csv")
		bg = argb_to_html(config_value(gc, "BackgroundColor"))
		if bg is None:
			self.warn("game_config.csv has no readable BackgroundColor (the app's neutral green is used)")
		self.timings["inputs"] = round(time.time() - t0, 2)
		t = time.time()
		default_pieces = self.piece_list("")
		variants = {}
		for v, pf in sorted(var.items()):
			pl = self.piece_list(pf)
			variants[v] = {"pieces": pl}
			ext = self.extent(pl)
			if ext:
				variants[v]["extent_world"] = ext
		self.timings["pieces"] = round(time.time() - t, 2)
		t = time.time()
		tiles = self.build_tiles(var)
		self.timings["tiles"] = round(time.time() - t, 2)
		t = time.time()
		atlases = {}
		for i in sorted(self.atlases_used):
			tex = self.swf.textures[i]
			rel = f"atlas/{self.sc}_{i}.png"
			(self.tdir / rel).parent.mkdir(parents=True, exist_ok=True)
			bleed(tex.image).save(self.tdir / rel, compress_level=6)
			atlases[f"{self.sc}_{i}"] = {"file": rel, "size": [tex.w, tex.h]}
		self.timings["atlases"] = round(time.time() - t, 2)
		man = {"format": FORMAT, "schema_version": SCHEMA_VERSION, "id": f"{self.sc}_terrain",
			"name": "Main farm terrain (private, from the client's own files)",
			"PRIVATE": "Derived from the user's own game client files for personal use. Never commit or share.",
			"frame": "game_tile", "base": "color", "scatter": False, "land_edge": False, "alpha_bleed": True,
			"pixels_per_world_px": TEXELS_PER_WORLD_PX}
		if bg:
			man["background_color"] = bg
		man["atlases"] = atlases
		man["tiles"] = tiles
		man["themes"] = dict(sorted(themes.items()))
		man["pieces"] = default_pieces
		ext = self.extent(default_pieces)
		if ext:
			man["extent_world"] = ext
		man["variants"] = variants
		if self.clips:
			write_json(self.tdir / "clips.json", {"shapes": self.shapes, "clips": self.clips,
				"note": "m = affine (a, b, c, d, tx, ty) in world px: x' = a*x + c*y + tx, y' = b*x + d*y + ty; "
					"mul = colour multiplier; frames can be empty (an animation that starts invisible)"}, compact=True)
			man["clips"] = "clips.json"
		man["provenance"] = {"tool": f"tools/private_assets/build_terrain.py {TOOL_VERSION}", "generated": now_iso(),
			**self.source, "variants": {v: pf for v, pf in sorted(var.items())},
			"note": "placement (anchors, draw order, confidence) comes from the private placement file; everything "
				"else is read from the client files"}
		write_json(self.tdir / "terrain.json", man)
		files = sorted(p for p in self.tdir.rglob("*") if p.is_file())
		hashes = {"generated": now_iso(), "note": "sha256 of every terrain output (PRIVATE; leak guard)",
			"outputs": {str(p.relative_to(self.out)): sha256_file(p) for p in files}}
		write_json(self.out / "hashes.json", hashes)
		self.timings["total"] = round(time.time() - t0, 2)
		size = sum(p.stat().st_size for p in files)
		report = {"generated": now_iso(), "timings_s": self.timings, "files": len(files), "bytes": size,
			"variants": sorted(var), "themes": themes, "pieces": {"default": len(default_pieces), **{v: len(e["pieces"]) for v, e in variants.items()}},
			"tiles": len(tiles), "atlases": len(atlases), "clips": len(self.clips),
			"clip_instances": sum(len(p.get("clips", [])) for p in default_pieces),
			"vertices_default": sum(e["vertices"] for ex in {p["id"].split("#")[0] for p in default_pieces}
				for e in self._piece_cache.get(ex, {"parts": []})["parts"] if "vertices" in e),
			"warnings": self.warnings, **self.source}
		write_json(self.out / "build_report.json", report)
		log(f"terrain: {len(files)} files, {size / 1e6:.1f} MB, {len(default_pieces)} default pieces, variants "
			f"{sorted(var)}, {len(tiles)} tile textures, {len(self.clips)} clips, {len(self.warnings)} warnings, "
			f"{self.timings['total']} s -> {self.tdir}")
		return report


# ------------------------------------------------------------------------------------------------ install / validate
def terrain_digest(tdir: Path) -> str:
	h = hashlib.sha256()
	for p in sorted(q for q in tdir.rglob("*") if q.is_file()):
		h.update(str(p.relative_to(tdir)).encode())
		h.update(sha256_file(p).encode())
	return h.hexdigest()[:8]


def install_terrain(out: Path, install: Path, root: Path, backup_dir: Path | None = None) -> dict:
	"""Add <out>/terrain to an installed pack: back the pack up first (unless a backup of this version exists),
	swap terrain/ in atomically, declare it in pack.json with a version suffix, list the files in hashes.json."""
	src = out / "terrain"
	if not (src / "terrain.json").is_file():
		raise SystemExit(f"no built terrain at {src} (run the build first)")
	install = ensure_private(install, "the installed pack")
	pj = install / "pack.json"
	pack = read_json(pj)
	if not isinstance(pack, dict) or not isinstance(pack.get("sprites"), dict):
		raise SystemExit(f"{pj} is not an asset pack manifest")
	version = str(pack.get("version", "0"))
	bdir = backup_dir or (root / "archive" / f"installed_{version}")
	bdir = ensure_private(bdir, "the pack backup")
	if not bdir.exists():
		shutil.copytree(install, bdir)
		log(f"backup: {install} -> {bdir}")
	else:
		log(f"backup: {bdir} exists (kept)")
	tmp = install / ".terrain.installing"
	old = install / ".terrain.old"
	for d in (tmp, old):
		if d.exists():
			shutil.rmtree(d)
	shutil.copytree(src, tmp)
	if (install / "terrain").exists():
		os.replace(install / "terrain", old)
	os.replace(tmp, install / "terrain")
	if old.exists():
		shutil.rmtree(old)
	digest = terrain_digest(install / "terrain")
	base = re.sub(r"-t[0-9a-f]{8}$", "", version)
	pack["version"] = f"{base}-t{digest}"
	pack["terrain"] = "terrain/terrain.json"
	rep = read_json(out / "build_report.json", {}) or {}
	pack["terrain_provenance"] = {"tool": f"tools/private_assets/build_terrain.py {TOOL_VERSION}",
		"generated": rep.get("generated"), "client": rep.get("client"), "placement": rep.get("placement_name")}
	write_json(pj, pack)
	hj = install / "hashes.json"
	hashes = read_json(hj, {}) or {}
	outs = {k: v for k, v in (hashes.get("outputs") or {}).items() if not k.startswith("terrain/")}
	for p in sorted((install / "terrain").rglob("*")):
		if p.is_file():
			outs[str(p.relative_to(install))] = sha256_file(p)
	outs["pack.json"] = sha256_file(pj)
	hashes["outputs"] = outs
	write_json(hj, hashes)
	n = sum(1 for p in (install / "terrain").rglob("*") if p.is_file())
	log(f"installed terrain ({n} files) into {install}; pack version {version} -> {pack['version']}")
	return {"version_before": version, "version": pack["version"], "files": n, "backup": str(bdir)}


def godot_bin() -> str | None:
	g = os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
	return g


def validate(terrain_json: Path) -> int:
	g = godot_bin()
	if not g:
		log("validate: no Godot found ($GODOT or godot on PATH)")
		return 2
	cmd = [g, "--headless", "--path", str(REPO_ROOT), "--script", "res://tools/ci/check_terrain_pack.gd", "--",
		str(terrain_json.resolve())]
	r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
	lines = [ln for ln in (r.stdout + r.stderr).splitlines() if ln.strip().startswith(("terrain pack", "variants",
		"ERROR", "warning", "MISSING", "TERRAIN PACK"))]
	for ln in lines:
		log("  " + ln.strip())
	return 0 if r.returncode == 0 and any("TERRAIN PACK OK" in ln for ln in lines) else 1


# ------------------------------------------------------------------------------------------------ self-test
def _synthetic_swf():
	"""A tiny in-memory client file: 2 textures, 2 edge exports (+ a _winter variant), an animated nested clip, a
	solid degenerate-uv fill, a colour add term and 3 ground-tile exports. All values are made up."""
	swf = X.Swf("synthetic")

	def texture(w, h, fill):
		t = X.Texture(1, 0, w, h)
		a = np.zeros((h, w, 4), np.uint8)
		fill(a)
		t.image = Image.fromarray(a, "RGBA").convert("RGBa")
		return t

	def atlas0(a):
		a[0:16, 0:16] = (200, 40, 40, 255)      # red block
		a[0:16, 16:32] = (40, 200, 40, 128)     # half-transparent green
		a[20:24, 20:24] = (10, 20, 220, 255)    # solid blue texel area (degenerate fill)

	def atlas1(a):                              # three 8x8 ground tiles stacked vertically, 2 px gap
		for i, col in enumerate([(90, 160, 60), (150, 120, 70), (240, 240, 250)]):
			a[i * 10:i * 10 + 8, 0:8] = (*col, 255)
		a[0:8, 0:4, 2] = 0                        # left half (u < 4) of tile 0 has no blue: orientation check
	swf.textures = [texture(32, 32, atlas0), texture(8, 30, atlas1)]

	def uvq(tex, pts):
		return [(round(u * 65535 / tex.w), round(v * 65535 / tex.h)) for u, v in pts]
	t0, t1 = swf.textures

	def shape(sid, cmds):
		s = X.Shape(sid)
		s.commands = cmds
		swf.shapes[sid] = s
	quad = [(0.0, 0.0), (64.0, 0.0), (64.0, 64.0), (0.0, 64.0)]
	shape(1, [X.Command(22, 0, quad, uvq(t0, [(0, 0), (16, 0), (16, 16), (0, 16)]))])
	shape(2, [X.Command(22, 0, [(0.0, 0.0), (128.0, 0.0), (128.0, 32.0), (0.0, 32.0)], uvq(t0, [(22, 22)] * 4))])
	shape(3, [X.Command(22, 0, quad, uvq(t0, [(16, 0), (32, 0), (32, 16), (16, 16)]))])
	for i, sid in enumerate((10, 11, 12)):
		y = i * 10
		shape(sid, [X.Command(22, 1, [(0.0, 0.0), (0.0, 90.0), (90.0, 90.0), (90.0, 0.0)], uvq(t1, [(0, y), (0, y + 8), (8, y + 8), (8, y)]))])
	swf.banks = [{"m": [(1.0, 0.0, 0.0, 1.0, 100.0, 50.0), (0.5, 0.0, 0.0, 0.5, -40.0, 0.0), (1.0, 0.0, 0.0, 1.0, 10.0, 0.0)],
		"c": [((255.0, 255.0, 255.0, 128.0), (0.0, 0.0, 0.0)), ((255.0, 255.0, 255.0, 255.0), (20.0, 40.0, 60.0))]}]

	def clip(cid, children, frames, fps=30):
		c = X.Clip(cid)
		c.children = children
		c.blends = [0] * len(children)
		c.fps = fps
		c.frames = [(len(f), None) for f in frames]
		c.elements = [e for f in frames for e in f]
		swf.clips[cid] = c
	clip(30, [3], [[], [(0, 0xFFFF, 0)], [(0, 2, 0xFFFF)], [(0, 2, 1)]])   # animated: frame 0 empty, then the green quad (+ add)
	clip(40, [1, 2, 30], [[(0, 0xFFFF, 0xFFFF), (1, 0, 1), (2, 1, 0xFFFF)]])            # edge_a
	clip(41, [2], [[(0, 0xFFFF, 0xFFFF)]])                                              # edge_a_winter (fill only)
	clip(42, [1], [[(0, 1, 0xFFFF)]])                                                   # edge_b (no winter art)
	for cid, sid in ((50, 10), (51, 11), (52, 12)):
		clip(cid, [sid], [[(0, 0xFFFF, 0xFFFF)]])
	swf.exports = [(40, "edge_a"), (41, "edge_a_winter"), (42, "edge_b"), (50, "tile_grass"), (51, "tile_road"),
		(52, "tile_grass_winter")]
	return swf


def uniform_blend(me: dict) -> int | None:
	"""The piece-level blend of a mesh: one supported non-normal mode (3 multiply, 4 screen, 8 add) over every
	triangle, else None (normal, or mixed modes: those stay in blend_ops and draw normal)."""
	bo = me.get("blend_ops") or []
	if bo and len({o["mode"] for o in bo}) == 1 and sum(o["index_count"] for o in bo) == len(me["indices"]) \
			and bo[0]["mode"] in (3, 4, 8):
		return int(bo[0]["mode"])
	return None


def self_test(run_godot: bool = True) -> int:
	fails: list[str] = []
	tmp = Path(tempfile.mkdtemp(prefix="build-terrain-selftest-"))
	try:
		data = tmp / "client" / "data"
		data.mkdir(parents=True)
		(data / "themes.csv").write_text("Name,LevelLimit,ExportNamePostfix\nString,int,String\nSnowy,1,_winter\n"
			"Plain,1,\nSunny,1,_sunny\n")
		(data / "game_config.csv").write_text("Name,Int,String\nString,int,String\nOther,3,\nBackgroundColor,,FF102030\n")
		place = [{"export": "edge_a", "anchor_tile": [0, 0], "z": 0, "confidence": "made-up"},
			{"export": "edge_b", "anchor_tile": [2, 1], "z": 1}, {"export": "missing_export", "anchor_tile": [0, 0], "z": 2}]
		(tmp / "placement.json").write_text(json.dumps({"pieces": place}))
		world = {"tile_types": {"0": {"art": "tile_grass"}, "2": {"art": "tile_road"}, "7": {"art": "tile_nope", "unlocked_type": 0}}}
		out = tmp / "out"
		b = TerrainBuilder(_synthetic_swf(), "syn", data, load_placement(tmp / "placement.json"), world, out,
			raster={"edge_b"}, source={"client": "synthetic"})
		rep = b.build()
		man = read_json(out / "terrain" / "terrain.json")
		if not man or man.get("format") != FORMAT or man.get("schema_version") != 1:
			fails.append("terrain.json missing or wrong format")
			raise RuntimeError
		if man.get("background_color") != "#102030":
			fails.append(f"background colour from game_config: {man.get('background_color')}")
		if man.get("themes") != {"plain": "default", "snowy": "winter", "sunny": "default"}:
			fails.append(f"themes table: {man.get('themes')}")
		if sorted(man.get("variants", {})) != ["winter"]:
			fails.append(f"variants: {list(man.get('variants', {}))}")
		dp = man["pieces"]
		for me, want in (({"indices": [0, 1, 2, 0, 2, 3], "blend_ops": [{"first_index": 0, "index_count": 6, "mode": 8}]}, 8),
				({"indices": [0, 1, 2, 0, 2, 3], "blend_ops": [{"first_index": 0, "index_count": 3, "mode": 8}]}, None),
				({"indices": [0, 1, 2], "blend_ops": [{"first_index": 0, "index_count": 3, "mode": 13}]}, None),
				({"indices": [0, 1, 2]}, None)):
			if uniform_blend(me) != want:
				fails.append(f"uniform_blend({me}) != {want}")
		if [p["id"] for p in dp] != ["edge_a#0", "edge_b#0"]:
			fails.append(f"default pieces: {[p['id'] for p in dp]}")
		wp = man["variants"]["winter"]["pieces"]
		if [p["id"] for p in wp] != ["edge_a_winter#0", "edge_b#0"]:
			fails.append(f"winter pieces (base fallback for edge_b): {[p['id'] for p in wp]}")
		if not any("missing_export" in w for w in rep["warnings"]):
			fails.append("a placement export that is not in the file must be reported")
		mesh = read_json(out / "terrain" / dp[0]["mesh"])
		# edge_a: shape 1 (identity, 4 verts) + shape 2 (degenerate fill at matrix 0 with an add term) = 8 verts;
		# the animated clip 30 is not baked in
		if not mesh or mesh["vertex_count"] != 8 or mesh["triangle_count"] != 4:
			fails.append(f"mesh replay vertex/triangle count: {mesh and (mesh['vertex_count'], mesh['triangle_count'])}")
		else:
			if mesh["positions"][:8] != [0, 0, 32, 0, 32, 32, 0, 32]:
				fails.append(f"world px = SC units / 2: {mesh['positions'][:8]}")
			if mesh["positions"][8:10] != [50, 25]:
				fails.append(f"child matrix translation: {mesh['positions'][8:10]}")
			u = mesh["uvs"][8:16]
			if len(set(zip(u[0::2], u[1::2]))) != 1:
				fails.append("a degenerate-uv fill must keep its single uv")
			if mesh["colors"][16:20] != [1.0, 1.0, 1.0, 1.0]:
				fails.append(f"colour multiplier: {mesh['colors'][16:20]}")
			if mesh["add_ops"] != [{"first_index": 6, "index_count": 6, "add_rgb": [round(20 / 255, 4), round(40 / 255, 4), round(60 / 255, 4)]}]:
				fails.append(f"add ops: {mesh['add_ops']}")
		clips = read_json(out / "terrain" / "clips.json")
		inst = dp[0].get("clips") or []
		if not clips or len(inst) != 1 or inst[0]["clip"] not in clips["clips"]:
			fails.append(f"animated nested clip instance: {inst}")
		else:
			c = clips["clips"][inst[0]["clip"]]
			if c["frame_count"] != 4 or c["frames"][0] != [] or len(c["frames"][1]) != 1:
				fails.append(f"clip frames: {c}")
			elif c["frames"][2][0]["m"][4] != 5.0 or c["frames"][1][0]["mul"][3] != 0.502:
				fails.append(f"clip frame matrix / colour: {c['frames'][1:]}")
			elif "add" in c["frames"][1][0] or c["frames"][3][0].get("add") != [round(20 / 255, 4), round(40 / 255, 4), round(60 / 255, 4)]:
				fails.append(f"clip frame colour-add term: {c['frames'][1:]}")
			if inst[0]["x_axis"] != [0.5, 0.0] or inst[0]["origin_world"] != [-20.0, 0.0]:
				fails.append(f"clip instance transform: {inst[0]}")
		eb = dp[1]
		if eb.get("type") != "image" or not (out / "terrain" / eb.get("file", "-")).is_file():
			fails.append(f"--raster piece: {eb}")
		tiles = man.get("tiles", {})
		if sorted(tiles) != ["tile_grass", "tile_grass_winter", "tile_road"]:
			fails.append(f"tiles: {sorted(tiles)}")
		else:
			im = Image.open(out / "terrain" / tiles["tile_grass"]["file"]).convert("RGBA")
			if im.size != (8, 8) or im.getpixel((1, 4))[2] != 0 or im.getpixel((6, 4))[2] != 60:
				fails.append(f"tile crop/orientation: size {im.size} px {im.getpixel((1, 4))} {im.getpixel((6, 4))}")
		if not any("tile_nope" in w for w in rep["warnings"]):
			fails.append("a tile art key without an export must be reported")
		at = Image.open(out / "terrain" / "atlas" / "syn_0.png").convert("RGBA")
		if at.getpixel((30, 30))[3] != 0 or at.getpixel((30, 30))[:3] == (0, 0, 0):
			fails.append(f"atlas colour bleeding under transparent texels: {at.getpixel((30, 30))}")
		hashes = read_json(out / "hashes.json")
		if not hashes or "terrain/terrain.json" not in hashes.get("outputs", {}):
			fails.append("hashes.json outputs")
		# install into a fake pack (backup + version suffix + hashes)
		inst_dir = tmp / "user" / "hayday_original"
		inst_dir.mkdir(parents=True)
		(inst_dir / "pack.json").write_text(json.dumps({"format": "hayday-sandbox-asset-pack", "id": "hayday_original",
			"version": "1.0-abc", "sprites": {}}))
		r1 = install_terrain(out, inst_dir, tmp, tmp / "backup")
		pk = read_json(inst_dir / "pack.json")
		if pk.get("terrain") != "terrain/terrain.json" or not re.fullmatch(r"1\.0-abc-t[0-9a-f]{8}", pk.get("version", "")):
			fails.append(f"install: pack.json {pk.get('terrain')} {pk.get('version')}")
		if not (tmp / "backup" / "pack.json").is_file():
			fails.append("install must back the pack up first")
		r2 = install_terrain(out, inst_dir, tmp, tmp / "backup")
		if r2["version"] != r1["version"]:
			fails.append(f"re-installing the same terrain must keep the version: {r1['version']} {r2['version']}")
		if "terrain/terrain.json" not in (read_json(inst_dir / "hashes.json", {}) or {}).get("outputs", {}):
			fails.append("install must list the terrain files in hashes.json")
		try:
			ensure_private(REPO_ROOT / "tmp_terrain_out", "x")
			fails.append("writing inside the repository must be refused")
		except SystemExit:
			pass
		if run_godot and godot_bin():
			rc = validate(out / "terrain" / "terrain.json")
			if rc != 0:
				fails.append(f"check_terrain_pack.gd on the synthetic build: rc={rc}")
		elif run_godot:
			log("self-test: Godot not found, check_terrain_pack.gd skipped")
	except RuntimeError:
		pass
	finally:
		shutil.rmtree(tmp, ignore_errors=True)
	for f in fails:
		print("SELF-TEST FAIL:", f)
	print(f"build_terrain self-test: {'OK' if not fails else f'{len(fails)} failure(s)'}")
	return 1 if fails else 0


# ------------------------------------------------------------------------------------------------ main
def main(argv=None) -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--root", type=Path, default=DEFAULT_ROOT, help=f"private root (default {DEFAULT_ROOT})")
	ap.add_argument("--client", type=Path, default=None, help="extracted client assets folder with sc/ and data/ "
		"(default <root>/raw/apk_extracted/<newest>/assets)")
	ap.add_argument("--sc", default="background", help="the .sc file with the terrain art (default background)")
	ap.add_argument("--placement", type=Path, default=None,
		help="private placement JSON (default <root>/research/terrain/terrain_manifest.json)")
	ap.add_argument("--world", type=Path, default=None,
		help=f"world.json with tile_types[].art (default <root>/packs/{WORLD_DIR_NAME}/world/world.json)")
	ap.add_argument("--out", type=Path, default=None, help=f"output folder (default <root>/packs/{OUT_DIR_NAME})")
	ap.add_argument("--raster", action="append", default=[], metavar="EXPORT",
		help="draw this export as one raster image (fixed extractor renderer) instead of a mesh; repeatable")
	ap.add_argument("--install-dir", type=Path, default=None, help="also add the terrain to this installed pack folder")
	ap.add_argument("--backup-dir", type=Path, default=None,
		help="pack backup folder for --install-dir (default <root>/archive/installed_<version>)")
	ap.add_argument("--no-build", action="store_true", help="skip the build (install / validate an existing build)")
	ap.add_argument("--validate", nargs="?", const="", default=None, metavar="TERRAIN_JSON",
		help="run tools/ci/check_terrain_pack.gd on the build (or the given terrain.json)")
	ap.add_argument("--self-test", action="store_true", help="synthetic client data in a temporary folder")
	ap.add_argument("--self-test-no-godot", action="store_true", help=argparse.SUPPRESS)
	args = ap.parse_args(argv)
	if args.self_test or args.self_test_no_godot:
		return self_test(run_godot=not args.self_test_no_godot)
	root = Path(args.root).expanduser().resolve()
	out = ensure_private(args.out or root / "packs" / OUT_DIR_NAME, "the terrain output")
	if not args.no_build:
		client = args.client or default_client_dir(root)
		if client is None or not client.is_dir():
			raise SystemExit(f"no extracted client under {root}/raw/apk_extracted (use --client)")
		placement_p = args.placement or root / "research" / "terrain" / "terrain_manifest.json"
		world_p = args.world or root / "packs" / WORLD_DIR_NAME / "world" / "world.json"
		world = read_json(world_p)
		if world is None:
			log(f"warning: no world at {world_p}: no ground tiles")
		t = time.time()
		swf = load_swf(client, args.sc)
		log(f"loaded {args.sc}.sc in {time.time() - t:.1f} s ({len(swf.exports)} exports, {len(swf.textures)} textures)")
		version = client.parent.name if client.name == "assets" else client.name
		b = TerrainBuilder(swf, args.sc, client / "data", load_placement(placement_p), world, out, set(args.raster),
			source={"client": version, "sc": f"sc/{args.sc}.sc", "placement_name": placement_p.name,
				"world_name": world_p.name if world else None, "load_s": round(time.time() - t, 2)})
		b.build()
	if args.install_dir:
		install_terrain(out, Path(args.install_dir), root, args.backup_dir)
	if args.validate is not None:
		return validate(Path(args.validate) if args.validate else out / "terrain" / "terrain.json")
	return 0


if __name__ == "__main__":
	sys.exit(main())
