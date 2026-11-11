#!/usr/bin/env python3
"""Ambient animation sheets and glow (additive) layers for the PRIVATE "hayday_original" pack.

PERSONAL USE ONLY. Everything this module reads or writes is proprietary Supercell art (see build_pack.py). It
contains no art and no game data; it only knows how to replay the client's own clips. Used by build_pack.py
(``--anims`` / ``--no-anims``, ``--no-glow``); runnable on its own for a few exports to inspect the result:

  python3 tools/private_assets/build_anims.py --sc <sc base> --export <export name> [--frame N] [--out DIR]

What it makes, per pack image that comes from ONE client export (base sprite, variant, connection piece, mirror):

* **Glow.** Draw ops under add (8), screen (4) or multiply (3) blending (Flash numbering) are composited exactly by
  extract_from_apk.Renderer.render_layers(): the image becomes "what normal alpha can carry" plus an additive
  remainder, written as a second image ``glow`` = {"file", "blend": "add"} with the same size and anchor. Add is
  exact over any opaque backdrop; screen / multiply over pixels the art does not cover use the mean transmittance.
* **Animation.** Map objects keep their ambient motion in NESTED clips (the root holds a state machine at its idle
  frame). Every nested clip plays its own timeline: clip frame = (static frame + floor(t * clip fps)) mod length,
  i.e. Flash/SC playback of instances placed at frame 0. Clips that code controls are HELD at the static frame:
  clips with frame labels (named states), clips shorter than MIN_CLIP_FRAMES (toggles) and HUD children. Of the
  playing clips, the ones with the largest moving area are kept while the common loop (least common multiple of
  their periods) stays <= MAX_LOOP_S; the rest are held. Frames are sampled at the client's frame rate (30 fps),
  halved or thirded only to fit MAX_LOOP_FRAMES / MAX_SHEET_PX.
  The sheet holds only the rectangle that changes ("rect", static-image pixels): each frame is a full re-render of
  that rectangle (static parts included), so the app REPLACES that rectangle of the static image with the frame;
  nothing is drawn twice and the static image itself (thumbnails, ghosts, exports, Off) is frame 0 exactly.
  Cells are separated by CELL_PADDING px of edge extrusion (no filtering bleed between frames).
* **Registration.** The static image is re-rendered by the same pass (same renderer, scale, crop and resampling)
  so frame 0 equals it; build records the frame-0 difference (``frame0_max_diff``) as a check.

Results are cached under <root>/raw/apk_anims/<build>/<sc>/<export>/<hash>/ (keyed by every input that changes the
output, incl. RENDER_REV and ANIM_REV), so a rebuild only renders what changed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import sys
import time
from fractions import Fraction
from pathlib import Path

ANIM_REV = "2026-11-10.1"
MIN_CLIP_FRAMES = 3          # shorter nested clips are toggles / states set by code: held
MAX_LOOP_S = Fraction(12)    # longest common loop (seconds) a sheet may hold
MAX_LOOP_FRAMES = 120        # frames per sheet
MAX_SHEET_PX = 1_200_000     # pack pixels per sheet (incl. padding): ~4.8 MB RGBA, ~6.4 MB with mipmaps
MAX_SHEET_SIDE = 4096
FRAME_STEPS = (1, 2, 3)      # 30 / 15 / 10 fps for 30 fps clips
DEFAULT_FPS = 30
PATCH_MARGIN = 3             # pack px of unchanged pixels around the changing rectangle
CELL_PADDING = 2             # px of edge extrusion around every cell
ANIM_PPW = 2.0               # sheet resolution (px per world px; static images are 2-3): as sharp as the screen up to
                             # 200 % zoom, and about half the memory of full-resolution frames
MAX_CLIP_SAMPLES = 24        # frames sampled per clip to find what it moves
A_TRIM = 2
HUD_INSTANCE_RE = re.compile(r"^(UI[A-Z].*|silo_capacity)$")
WEBP_QUALITY = 92
THUMB_MAX = 128


def log(msg: str) -> None:
	print(f"[build_anims] {msg}", flush=True)


def _X():
	sys.path.insert(0, str(Path(__file__).resolve().parent))
	import extract_from_apk as X  # noqa: PLC0415
	return X


def _lcm(a: Fraction, b: Fraction) -> Fraction:
	a, b = Fraction(a), Fraction(b)
	num = a.numerator * b.numerator // math.gcd(a.numerator, b.numerator)
	return Fraction(num, math.gcd(a.denominator, b.denominator))


def holds(name: str | None, clip) -> bool:
	"""True when a nested clip is code-controlled (held at the static frame) rather than an ambient loop."""
	if len(clip.frames) < MIN_CLIP_FRAMES:
		return True
	if any(lab for _, lab in clip.frames):
		return True
	return bool(name and HUD_INSTANCE_RE.match(name))


ROOT = -1                    # pseudo clip id of the root's idle loop


def root_idle_loop(clip, frame: int):
	"""(start, length) of the root clip's idle loop when the static frame is its IdleStart and an IdleEnd label
	follows (frames IdleStart..IdleEnd, inclusive), else None."""
	labs = {lab: i for i, (_, lab) in enumerate(clip.frames) if lab}
	s, e = labs.get("IdleStart"), labs.get("IdleEnd")
	if s is None or e is None or s != frame or e - s + 1 < MIN_CLIP_FRAMES:
		return None
	return s, e - s + 1


class Player:
	"""Display lists of one export at time t: playing clips advance, everything else holds the static frame.
	Clip id ROOT is the root's idle loop (root_idle_loop), when it has one."""

	def __init__(self, X, swf, oid: int, root_frame: int, base: int, hidden=()):
		self.X, self.swf, self.oid, self.root_frame, self.base = X, swf, oid, root_frame, base
		self.playing: set[int] = set()
		self.t = Fraction(0)
		self.seen: dict[int, tuple] = {}      # clip id -> (frames, fps, held)
		self.rend = X.Renderer(swf, clip_frame=self._frame, hidden_names=hidden)
		root = swf.clips.get(oid)
		self.root_loop = root_idle_loop(root, root_frame) if root is not None else None
		if self.root_loop:
			self.seen[ROOT] = (self.root_loop[1], root.fps or DEFAULT_FPS, False)

	def _frame(self, cid, name, clip):
		n = len(clip.frames)
		fps = clip.fps or DEFAULT_FPS
		held = holds(name, clip)
		prev = self.seen.get(cid)
		self.seen[cid] = (n, fps, held or (prev[2] if prev else False))
		if held or cid not in self.playing:
			return self.base
		return self.base + math.floor(self.t * fps + Fraction(1, 10**6))

	def ops(self, t=Fraction(0)):
		self.t = Fraction(t)
		frame = self.root_frame
		if self.root_loop and ROOT in self.playing:
			s, n = self.root_loop
			frame = s + math.floor(self.t * self.seen[ROOT][1] + Fraction(1, 10**6)) % n
		ops, _ = self.rend.display_list(self.oid, frame)
		return ops


def _op_key(op):
	if op[0] != "draw":
		return (op[0],)
	m = tuple(round(v, 3) for v in op[2])
	ct = (tuple(op[3][0]), tuple(op[3][1]))
	return (id(op[1]), m, ct, op[4] if len(op) > 4 else 0)


def changed_bounds(rend, ops0, ops1, scale: float):
	"""Bounds (output px at `scale`) of the draw ops that differ between two display lists, or None."""
	from collections import Counter
	k0 = Counter(_op_key(o) for o in ops0)
	k1 = Counter(_op_key(o) for o in ops1)
	diff = (k0 - k1) + (k1 - k0)
	if not diff:
		return None
	sel = [o for o in list(ops0) + list(ops1) if o[0] == "draw" and _op_key(o) in diff]
	return rend.bounds(sel, scale) if sel else None


def _union(a, b):
	if a is None:
		return b
	if b is None:
		return a
	return (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


def plan_anim(P: Player, scale: float, cost_px) -> dict | None:
	"""Choose the clips to play, the loop and the frame step. cost_px(bounds_src, frames) -> sheet px.
	Returns {"playing", "held", "loop_s", "step", "frames", "times", "dirty"} or None (nothing moves)."""
	ops0 = P.ops(0)
	cands = {cid: v for cid, v in P.seen.items() if not v[2]}
	if not cands:
		return None
	area, far = {}, []
	cv = P.rend.canvas(ops0, scale)
	limit = None
	if cv is not None:   # a clip may move at most half the static canvas beyond it
		hw, hh = (cv[2] - cv[0]) / 2, (cv[3] - cv[1]) / 2
		limit = (cv[0] - hw, cv[1] - hh, cv[2] + hw, cv[3] + hh)
	for cid, (n, fps, _) in cands.items():
		P.playing = {cid}
		period = Fraction(n, fps)
		k = min(n, MAX_CLIP_SAMPLES)
		bb = None
		for j in range(1, k):
			bb = _union(bb, changed_bounds(P.rend, ops0, P.ops(period * j / k), scale))
		if bb is not None and limit is not None and (bb[0] < limit[0] or bb[1] < limit[1] or bb[2] > limit[2]
				or bb[3] > limit[3]):
			far.append(cid)   # moves far outside the object (e.g. a sprite flying across the screen): held
			continue
		if bb is not None:
			area[cid] = (bb[2] - bb[0]) * (bb[3] - bb[1])
	P.playing = set()
	if not area:
		return None
	# largest moving area per second of loop first: short loops (blades, water, flames) before slow decorations
	order = sorted(area, key=lambda c: (-area[c] / (1 + float(Fraction(cands[c][0], cands[c][1]))), c))
	chosen, loop = [], Fraction(0)
	for cid in order:
		n, fps, _ = cands[cid]
		cand = _lcm(loop, Fraction(n, fps)) if loop else Fraction(n, fps)
		if cand <= MAX_LOOP_S:
			chosen.append(cid)
			loop = cand
	while chosen:
		P.playing = set(chosen)
		for step in FRAME_STEPS:
			rate = Fraction(DEFAULT_FPS, step)
			nf = loop * rate
			if nf.denominator != 1 or nf > MAX_LOOP_FRAMES or nf < 2:
				continue
			nf = int(nf)
			times = [Fraction(k) / rate for k in range(nf)]
			dirty = None
			for t in times[1:]:
				dirty = _union(dirty, changed_bounds(P.rend, ops0, P.ops(t), scale))
			if dirty is None:
				break
			if cost_px(dirty, nf) <= MAX_SHEET_PX:
				held = sorted(c for c in P.seen if c not in chosen)
				return {"playing": list(chosen), "held": held, "loop_s": loop, "step": step, "fps": float(rate),
					"frames": nf, "times": times, "dirty": dirty}
		# too big even at the lowest rate: drop the clip that moves the least
		chosen.pop()
		loop = Fraction(0)
		for cid in chosen:
			n, fps, _ = cands[cid]
			loop = _lcm(loop, Fraction(n, fps)) if loop else Fraction(n, fps)
	P.playing = set()
	return None


def _resize(img, size, box, premul=True):
	from PIL import Image
	if premul:
		return img.convert("RGBa").resize(size, Image.Resampling.LANCZOS, box=box).convert("RGBA")
	return img.resize(size, Image.Resampling.LANCZOS, box=box)


def _extrude(cell, pad: int):
	"""Cell image with `pad` px of its own edge pixels repeated around it."""
	from PIL import Image
	import numpy as np
	a = np.asarray(cell)
	a = np.pad(a, ((pad, pad), (pad, pad), (0, 0)), mode="edge")
	return Image.fromarray(a, "RGBA")


def _bake_glow(normal, glow):
	"""Fallback for places that cannot blend additively (thumbnails): P + E with alpha = max(A, brightest channel)."""
	import numpy as np
	from PIL import Image
	n = np.asarray(normal, np.float32) / 255.0
	g = np.asarray(glow, np.float32) / 255.0
	a = n[..., 3:4]
	c = n[..., :3] * a + g[..., :3] * g[..., 3:4]
	c = np.clip(c, 0, 1)
	A = np.maximum(a, c.max(axis=-1, keepdims=True))
	rgb = np.where(A > 1e-6, c / np.maximum(A, 1e-6), 0)
	return Image.fromarray((np.concatenate([rgb, A], -1) * 255 + 0.5).astype(np.uint8), "RGBA")


def _sha(p: Path) -> str:
	h = hashlib.sha256()
	with open(p, "rb") as f:
		for chunk in iter(lambda: f.read(1 << 20), b""):
			h.update(chunk)
	return h.hexdigest()


def needs_work(X, swf, spec: dict) -> dict:
	"""Cheap check (no textures): {"blend": bool, "clips": bool} for the export's static frame."""
	ids = {n: i for i, n in swf.exports}
	oid = ids.get(spec["export"])
	if oid is None:
		return {"blend": False, "clips": False}
	P = Player(X, swf, oid, int(spec.get("frame") or 0), int(spec.get("nested_frame") or 0), spec.get("hidden") or ())
	ops = P.ops(0)
	blend = any(o[0] == "draw" and len(o) > 4 and o[4] in (3, 4, 8) for o in ops)
	clips = any(not v[2] for v in P.seen.values())
	return {"blend": blend, "clips": clips}


def process(X, swf, spec: dict, job: dict, out_dir: Path, anims: bool = True, glow: bool = True) -> dict | None:
	"""Render the static image (+ glow, + animation sheet) of one export into out_dir. None = nothing to do
	(no blend ops, no animation): the plain pipeline (build_pack.render_job) handles the image.

	spec: {"sc", "export", "frame", "nested_frame", "hidden", "origin", "scale"} (origin = registration point in the
	plain export render's pixels); job: build_pack job (anchor in that render's pixels, ppw, max_ppw, mirror)."""
	from PIL import Image, ImageOps
	import numpy as np
	sys.path.insert(0, str(Path(__file__).resolve().parent))
	import build_pack as B  # noqa: PLC0415 - shared bleed_rgb
	ids = {n: i for i, n in swf.exports}
	oid = ids.get(spec["export"])
	if oid is None:
		return None
	scale = float(spec.get("scale") or 1.5)
	base = int(spec.get("nested_frame") or 0)
	P = Player(X, swf, oid, int(spec.get("frame") or 0), base, spec.get("hidden") or ())
	ops0 = P.ops(0)
	has_blend = glow and any(o[0] == "draw" and len(o) > 4 and o[4] in (3, 4, 8) for o in ops0)
	canvas = P.rend.canvas(ops0, scale)
	if canvas is None:
		return None
	ppw = float(job["ppw"])
	f = min(1.0, float(job.get("max_ppw", ppw)) / ppw) if ppw > 0 else 1.0

	sa = min(1.0, ANIM_PPW / (ppw * f))     # sheet px per static px

	def cost(dirty, nf):
		w = ((dirty[2] - dirty[0]) * f + 2 * PATCH_MARGIN + 2) * sa + 2 * CELL_PADDING
		h = ((dirty[3] - dirty[1]) * f + 2 * PATCH_MARGIN + 2) * sa + 2 * CELL_PADDING
		return w * h * nf

	plan = plan_anim(P, scale, cost) if anims else None
	if plan is None and not has_blend:
		return None
	P.playing = set(plan["playing"]) if plan else set()
	if plan and not has_blend and glow:
		# a blend op may only appear in later frames (e.g. a flame): check the sampled frames
		has_blend = any(o[0] == "draw" and len(o) > 4 and o[4] in (3, 4, 8) for t in plan["times"][1:] for o in P.ops(t))
	win = canvas if not plan else _union(canvas, (plan["dirty"][0] - 2, plan["dirty"][1] - 2, plan["dirty"][2] + 2,
		plan["dirty"][3] + 2))
	normal, glow_img, origin = P.rend.render_layers(P.ops(0), scale, window=win)
	if not has_blend:
		glow_img = None
	# crop: visible static (+ glow) and the changing rectangle
	alpha = np.asarray(normal)[..., 3] > A_TRIM
	if glow_img is not None:
		alpha |= np.asarray(glow_img)[..., 3] > A_TRIM
	ys, xs = np.nonzero(alpha)
	if len(xs) == 0 and plan is None:
		return None
	crop = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1) if len(xs) else None
	if plan:
		d = plan["dirty"]
		dd = (d[0] - win[0], d[1] - win[1], d[2] - win[0], d[3] - win[1])
		crop = _union(crop, (max(0, dd[0]), max(0, dd[1]), min(normal.width, dd[2]), min(normal.height, dd[3])))
	w0, h0 = crop[2] - crop[0], crop[3] - crop[1]
	if f < 0.999:
		nw, nh = max(1, round(w0 * f)), max(1, round(h0 * f))
	else:
		nw, nh = w0, h0
	fx, fy = nw / w0, nh / h0
	static = _resize(normal, (nw, nh), crop)
	gstatic = _resize(glow_img, (nw, nh), crop) if glow_img is not None else None
	# anchor: job anchor is in the plain render's pixels (registration point at spec origin)
	ox, oy = spec["origin"]
	ax = (job["anchor"][0] - ox + origin[0] - crop[0]) * fx
	ay = (job["anchor"][1] - oy + origin[1] - crop[1]) * fy
	out_ppw = ppw * (fx + fy) / 2
	res = {"anchor": [round(ax, 2), round(ay, 2)], "ppw": round(out_ppw, 5), "size": [nw, nh]}
	sheet = gsheet = None
	if plan:
		d = plan["dirty"]
		rx0 = max(0, math.floor((d[0] - win[0] - crop[0]) * fx) - PATCH_MARGIN)
		ry0 = max(0, math.floor((d[1] - win[1] - crop[1]) * fy) - PATCH_MARGIN)
		rx1 = min(nw, math.ceil((d[2] - win[0] - crop[0]) * fx) + PATCH_MARGIN)
		ry1 = min(nh, math.ceil((d[3] - win[1] - crop[1]) * fy) + PATCH_MARGIN)
		rw, rh = rx1 - rx0, ry1 - ry0
		# source box (window px) of the rectangle, and a render window around it with room for the filter
		bx0, by0 = crop[0] + rx0 / fx, crop[1] + ry0 / fy
		bx1, by1 = crop[0] + rx1 / fx, crop[1] + ry1 / fy
		sup = math.ceil(3 / (min(fx, fy) * sa)) + 2   # Lanczos support (3 lobes) at the cell scale, + slack
		wx0, wy0 = math.floor(bx0) - sup, math.floor(by0) - sup
		wx1, wy1 = math.ceil(bx1) + sup, math.ceil(by1) + sup
		pw = (wx0 + win[0], wy0 + win[1], wx1 + win[0], wy1 + win[1])
		box = (bx0 - wx0, by0 - wy0, bx1 - wx0, by1 - wy0)
		cw_i, ch_i = max(1, round(rw * sa)), max(1, round(rh * sa))
		cells, gcells, diffs = [], [], []
		# frame 0 must reproduce the static image's rectangle (same pixels, other render window)
		ref = np.asarray(_resize(normal, (cw_i, ch_i), (bx0, by0, bx1, by1)), np.int16)
		for k, t in enumerate(plan["times"]):
			n_k, g_k, _ = P.rend.render_layers(P.ops(t), scale, window=pw)
			cell = _resize(n_k, (cw_i, ch_i), box)
			if k == 0:
				c0 = np.asarray(cell, np.int16)
				vis = (ref[..., 3] > 8) | (c0[..., 3] > 8)
				dd_ = np.abs(c0 - ref)
				diffs = [int(dd_[..., 3].max()), int(dd_[vis][:, :3].max()) if vis.any() else 0,
					round(float(dd_.mean()), 3)]
			cells.append(B.bleed_rgb(cell))
			if has_blend:
				gcells.append(_resize(g_k, (cw_i, ch_i), box) if g_k is not None else
					Image.new("RGBA", (cw_i, ch_i), (0, 0, 0, 0)))
		cw, ch = cw_i + 2 * CELL_PADDING, ch_i + 2 * CELL_PADDING
		nf = len(cells)
		cols = max(1, min(nf, MAX_SHEET_SIDE // cw, math.ceil(math.sqrt(nf * ch / cw))))
		rows = math.ceil(nf / cols)
		sheet = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0))
		gsheet = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0)) if gcells else None
		for k, c in enumerate(cells):
			x, y = (k % cols) * cw, (k // cols) * ch
			sheet.paste(_extrude(c, CELL_PADDING), (x, y))
			if gsheet is not None:
				gsheet.paste(_extrude(gcells[k], CELL_PADDING), (x, y))
		if gsheet is not None and np.asarray(gsheet)[..., 3].max() <= A_TRIM:
			gsheet = None
		res["anim"] = {"frames": nf, "columns": cols, "fps": plan["fps"], "mode": "replace",
			"rect": [rx0, ry0, rw, rh], "cell": [cw_i, ch_i], "cell_padding": CELL_PADDING, "source_fps": DEFAULT_FPS,
			"frame_step": plan["step"], "loop_s": round(float(plan["loop_s"]), 4),
			"clips_played": len(plan["playing"]), "clips_held": len(plan["held"])}
		res["frame0_diff"] = {"alpha_max": diffs[0], "rgb_max_visible": diffs[1], "mean": diffs[2]}
	if job.get("mirror"):
		static = ImageOps.mirror(static)
		gstatic = ImageOps.mirror(gstatic) if gstatic is not None else None
		res["anchor"][0] = round(nw - ax, 2)
		if sheet is not None:
			cw, ch = cw_i + 2 * CELL_PADDING, ch_i + 2 * CELL_PADDING
			for sh in (sheet, gsheet):
				if sh is None:
					continue
				for k in range(res["anim"]["frames"]):
					x, y = (k % res["anim"]["columns"]) * cw, (k // res["anim"]["columns"]) * ch
					sh.paste(ImageOps.mirror(sh.crop((x, y, x + cw, y + ch))), (x, y))
			r = res["anim"]["rect"]
			r[0] = nw - r[0] - r[2]
	out_dir.mkdir(parents=True, exist_ok=True)
	B.bleed_rgb(static).save(out_dir / "static.webp", "WEBP", quality=WEBP_QUALITY, method=4, exact=True)
	t = (_bake_glow(static, gstatic) if gstatic is not None else static).convert("RGBa")
	t.thumbnail((THUMB_MAX, THUMB_MAX), Image.Resampling.LANCZOS)
	B.bleed_rgb(t.convert("RGBA"), 6).save(out_dir / "thumb.webp", "WEBP", quality=85, method=4, exact=True)
	if gstatic is not None:
		B.bleed_rgb(gstatic).save(out_dir / "glow.webp", "WEBP", quality=WEBP_QUALITY, method=4, exact=True)
		res["glow"] = {"blend": "add"}
	if sheet is not None:
		sheet.save(out_dir / "sheet.webp", "WEBP", quality=WEBP_QUALITY, method=4, exact=True)
		res["anim"]["sheet_size"] = list(sheet.size)
		if gsheet is not None:
			B.bleed_rgb(gsheet).save(out_dir / "glow_sheet.webp", "WEBP", quality=WEBP_QUALITY, method=4, exact=True)
			res["anim"]["glow_sheet"] = True
	(out_dir / "meta.json").write_text(json.dumps(res, indent=1))
	return res


def cache_key(spec: dict, job: dict, anims: bool, glow: bool) -> str:
	X = _X()
	k = {"rev": ANIM_REV, "render_rev": X.RENDER_REV, "spec": spec, "anchor": job["anchor"], "ppw": job["ppw"],
		"max_ppw": job.get("max_ppw"), "mirror": bool(job.get("mirror")), "anims": anims, "glow": glow,
		"limits": [str(MAX_LOOP_S), MAX_LOOP_FRAMES, MAX_SHEET_PX, MIN_CLIP_FRAMES, PATCH_MARGIN, CELL_PADDING, ANIM_PPW]}
	return hashlib.sha256(json.dumps(k, sort_keys=True, default=str).encode()).hexdigest()[:12]


# ------------------------------------------------------------------------------------------------- batch (pool)
_W: dict = {}


def _worker_job(task: dict) -> dict:
	"""One job in a worker: cached result, or render (the parsed .sc is kept per worker)."""
	try:
		cdir = Path(task["cache_dir"])
		meta = cdir / "meta.json"
		if meta.exists():
			return {"id": task["id"], "dir": str(cdir), "meta": json.loads(meta.read_text()), "cached": True}
		X = _X()
		sys.path.insert(0, str(Path(__file__).resolve().parent))
		import build_pack as B  # noqa: PLC0415
		key = (task["sc_dir"], task["spec"]["sc"])
		if _W.get("key") != key:
			_W.clear()
			_W["key"] = key
			_W["swf"] = B.ScCache(X, Path(task["sc_dir"])).get(task["spec"]["sc"])
		swf = _W["swf"]
		if swf is None:
			return {"id": task["id"], "error": "sc file missing"}
		tmp = cdir.with_name(cdir.name + ".tmp")
		shutil.rmtree(tmp, ignore_errors=True)
		t0 = time.time()
		res = process(X, swf, task["spec"], task["job"], tmp, task["anims"], task["glow"])
		if res is None:
			shutil.rmtree(tmp, ignore_errors=True)
			cdir.mkdir(parents=True, exist_ok=True)
			meta.write_text(json.dumps({"none": True}))
			return {"id": task["id"], "dir": str(cdir), "meta": {"none": True}}
		res["render_s"] = round(time.time() - t0, 2)
		(tmp / "meta.json").write_text(json.dumps(res, indent=1))
		shutil.rmtree(cdir, ignore_errors=True)
		tmp.rename(cdir)
		return {"id": task["id"], "dir": str(cdir), "meta": res}
	except Exception as ex:  # noqa: BLE001 - one bad export must not stop the build
		import traceback
		return {"id": task["id"], "error": f"{type(ex).__name__}: {ex}", "trace": traceback.format_exc()[-800:]}


def run(root: Path, jobs: list[dict], workers: int = 4, anims: bool = True, glow: bool = True) -> dict:
	"""jobs: build_pack jobs with "sc_spec". Returns {job id: {"dir", "meta"}} for jobs that got a glow or an anim
	(images in dir: static.webp, thumb.webp, glow.webp?, sheet.webp?, glow_sheet.webp?)."""
	import multiprocessing as mp
	sys.path.insert(0, str(Path(__file__).resolve().parent))
	import build_pack as B  # noqa: PLC0415
	X = _X()
	tasks = []
	todo = {}
	for j in jobs:
		s = j["sc_spec"]
		todo.setdefault((s["build"], s["sc"]), []).append(j)
	n_skip = 0
	for (build, sc), js in sorted(todo.items()):
		sc_dir = root / "raw" / "apk_extracted" / build / "assets" / "sc"
		pending = []
		for j in js:
			cdir = root / "raw" / "apk_anims" / build / sc / re.sub(r"[^A-Za-z0-9_.-]+", "_", j["sc_spec"]["export"]) / \
				cache_key(j["sc_spec"], j, anims, glow)
			if (cdir / "meta.json").exists():
				tasks.append({"id": j["id"], "cache_dir": str(cdir), "sc_dir": str(sc_dir), "spec": j["sc_spec"], "job": j,
					"anims": anims, "glow": glow})
				continue
			pending.append((j, cdir))
		if not pending:
			continue
		swf = B.ScCache(X, sc_dir).get(sc, textures=False)
		if swf is None:
			continue
		for j, cdir in pending:
			nw = needs_work(X, swf, j["sc_spec"])
			if not ((anims and nw["clips"]) or (glow and nw["blend"])):
				cdir.mkdir(parents=True, exist_ok=True)
				(cdir / "meta.json").write_text(json.dumps({"none": True}))
				n_skip += 1
				continue
			tasks.append({"id": j["id"], "cache_dir": str(cdir), "sc_dir": str(sc_dir), "spec": j["sc_spec"], "job": j,
				"anims": anims, "glow": glow})
	log(f"{len(jobs)} client images: {len(tasks)} to check/render ({n_skip} static without blending)")
	out, errors = {}, {}
	t0 = time.time()
	with mp.get_context("fork").Pool(max(1, workers), maxtasksperchild=200) as pool:
		for i, r in enumerate(pool.imap(_worker_job, tasks, chunksize=1), 1):
			if "error" in r:
				errors[r["id"]] = r["error"]
			elif not r["meta"].get("none"):
				out[r["id"]] = r
			if i % 100 == 0:
				log(f"  {i}/{len(tasks)} ({time.time() - t0:.0f}s)")
	log(f"done in {time.time() - t0:.0f}s: {sum(1 for r in out.values() if 'anim' in r['meta'])} animations, "
		f"{sum(1 for r in out.values() if 'glow' in r['meta'])} glow layers, {len(errors)} errors")
	for k, v in list(errors.items())[:10]:
		log(f"  error {k}: {v}")
	return {"results": out, "errors": errors}


def main(argv=None) -> int:
	ap = argparse.ArgumentParser(description="Render one export's static + glow + animation sheet (inspection).")
	ap.add_argument("--root", type=Path, default=Path("/root/hayday-sandbox-private-assets"))
	ap.add_argument("--build", default="1.73.89")
	ap.add_argument("--sc", required=True)
	ap.add_argument("--export", required=True)
	ap.add_argument("--frame", type=int, default=None, help="root frame (default: the idle label, as the extractor)")
	ap.add_argument("--out", type=Path, required=True)
	ap.add_argument("--ppw", type=float, default=3.0)
	ap.add_argument("--max-ppw", type=float, default=3.0)
	a = ap.parse_args(argv)
	X = _X()
	sys.path.insert(0, str(Path(__file__).resolve().parent))
	import build_pack as B  # noqa: PLC0415
	swf = B.ScCache(X, a.root / "raw" / "apk_extracted" / a.build / "assets" / "sc").get(a.sc)
	ids = {n: i for i, n in swf.exports}
	oid = ids[a.export]
	frame = a.frame if a.frame is not None else B._label_frame(swf, oid, ("IdleStart", "Idle", "idle"))
	ops, _ = X.Renderer(swf).display_list(oid, frame)
	bb = X.Renderer(swf).canvas(ops, 1.5)
	spec = {"sc": a.sc, "export": a.export, "frame": frame, "nested_frame": None, "hidden": [], "origin": [-bb[0], -bb[1]],
		"scale": 1.5}
	job = {"anchor": [-bb[0], -bb[1]], "ppw": a.ppw, "max_ppw": a.max_ppw, "mirror": False}
	t0 = time.time()
	res = process(X, swf, spec, job, a.out)
	print(json.dumps(res, indent=1), f"{time.time() - t0:.1f}s")
	return 0


if __name__ == "__main__":
	sys.exit(main())
