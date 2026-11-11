#!/usr/bin/env python3
"""Build the PRIVATE world data of the "hayday_original" pack from the user's own Hay Day client files.

PERSONAL USE ONLY. The outputs are derived from Supercell's client data (tile map, expansion plots, landmark
positions, seed objects, skin tables, footprints) and art. They go ONLY to the private root (default
/root/hayday-sandbox-private-assets or $HAYDAY_PRIVATE_ASSETS) and into the installed private pack; the tool refuses
to write inside a git work tree. This file is public code: it contains no coordinates, sizes, costs or ids decoded
from the client - everything numeric is read from the client tables at run time. See docs/PRIVATE_ASSETS.md.

Inputs
  <root>/raw/apk_extracted/<build>/assets/{data,localization,sc}   client tables + .sc files (extract_from_apk.py)
  <root>/mapping/mapping.json                                       build_pack.py decisions (client object -> item)
  data/items/*.json, data/research/expansions_research.json         public catalogue + public wiki plot tables

Outputs (default <root>/packs/hayday_original_world/; build_pack.py copies them into the pack)
  world/world.json            map v2 (format "hayday-sandbox-map", schema_version 2, frame "game"): regions (start
                              land, roads, blocked areas, every expansion plot with its canonical id, aliases
                              exp_<game id>, costs, client lock, exclusive decorations), sections, ground RLE +
                              tile types, landmarks (all SpecialObjects), initial objects mapped to catalogue ids
  world/landmark_sprites.json pack sprite entries "lm_<id>" (variants "<state>", "skin_<preset>", "<base>__<theme>")
  world/sprites/*.webp, world/thumbs/*.webp   landmark art at the pack's pixels per world px
  catalog_overrides.json      footprints / unlock levels the client tables state (format
                              "hayday-sandbox-catalog-overrides" version 1)
  build_report.json           counts, unmapped objects, cross-checks against the private research files

Usage
  python3 tools/private_assets/build_world.py                      # everything (world, overrides, sprites)
  python3 tools/private_assets/build_world.py --no-sprites         # data only (fast)
  python3 tools/private_assets/build_world.py --validate <world.json>
  python3 tools/private_assets/build_world.py --self-test          # synthetic fixtures, no client data needed
  python3 tools/private_assets/build_world.py --sheet              # private contact sheet of the landmark sprites

Coordinate frame (docs: overhaul design s1): app tile == game tile. x = TileMap column (along the road), y = TileMap
row (cliff -> road); objects' (x, y) is the top (north) corner tile of the footprint; footprint [x, y] =
[TileWidth, TileHeight]; screen = ((x - y) * 32, (x + y) * 16) world px. Negative tiles (river, cliff) are valid draw
positions outside the placement grid.

Requires Python 3.10+; Pillow + numpy (+ the extractor's zstandard / texture2ddecoder) for sprites only.
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import hashlib
import itertools
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parents[1]
DEFAULT_ROOT = Path(os.environ.get("HAYDAY_PRIVATE_ASSETS", "/root/hayday-sandbox-private-assets"))
PACK_ID = "hayday_original"
WORLD_DIR_NAME = "hayday_original_world"
TOOL_VERSION = "1.0"
MAP_FORMAT = "hayday-sandbox-map"
MAP_SCHEMA = 2
MAP_ID = "hayday_farm"
OVERRIDES_FORMAT = "hayday-sandbox-catalog-overrides"
WIKI_RESEARCH = REPO_ROOT / "data" / "research" / "expansions_research.json"
PPW = 3.0                       # landmark pixels per world px (= the client renders' 1.5 px per SC unit; build_pack.MAX_PPW)
SC_UNITS_PER_WORLD_PX = 2.0     # 1 tile = 128 x 64 SC units = 64 x 32 world px
HALF_W, HALF_H = 32.0, 16.0     # world px of half a tile
WORLD_MARGIN = 12               # tiles of scenery around the data extent (camera / placeholder scenery)
EDGE_MARGIN = 2                 # tiles around the edge-art extent (edge_art_extent)
CONFIDENCE = ("verified-in-data", "strong", "plausible", "approximate", "unknown")
AREAS = ("farm_side", "road_verge", "across_road", "river", "cliff")
REGION_KINDS = ("void", "buildable", "plot", "road", "water", "blocked", "scenery")
SCENERY_KINDS = ("river", "cliff", "forest", "edge")
FRAME_LABELS = ("IdleStart", "Idle", "idle")
PRIVATE_NOTE = ("PRIVATE: derived from the user's own Hay Day client data for personal use. Never commit, share or "
	"redistribute.")


def log(msg: str) -> None:
	print(msg, flush=True)


def now_iso() -> str:
	return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def read_json(p: Path, default=None):
	try:
		return json.loads(Path(p).read_text(encoding="utf-8"))
	except (OSError, ValueError):
		return default


def write_stable(p: Path, data: dict, stamp: tuple, indent: int | None = 1) -> None:
	"""write_json, but keep the previous timestamp at data[stamp...] when nothing else changed (the pack version is
	a content digest, so an unchanged rebuild must produce identical bytes)."""
	prev = read_json(p)
	if isinstance(prev, dict):
		def get(d):
			for k in stamp:
				d = d.get(k) if isinstance(d, dict) else None
			return d

		def put(d, v):
			for k in stamp[:-1]:
				d = d[k]
			d[stamp[-1]] = v
		old = get(prev)
		trial = json.loads(json.dumps(data))
		if old is not None and get(trial) is not None:
			put(trial, old)
			if trial == prev:
				put(data, old)
	write_json(p, data, indent)


def write_json(p: Path, data, indent: int | None = 1) -> None:
	p.parent.mkdir(parents=True, exist_ok=True)
	tmp = p.with_name(p.name + ".tmp")
	tmp.write_text(json.dumps(data, indent=indent, ensure_ascii=False), encoding="utf-8")
	tmp.replace(p)


def inside_git_worktree(p: Path) -> Path | None:
	p = p.expanduser().resolve()
	for parent in [p, *p.parents]:
		if (parent / ".git").exists():
			return parent
	return None


def ensure_private(p: Path, what: str) -> Path:
	p = Path(p).expanduser().resolve()
	g = inside_git_worktree(p)
	if g is not None:
		raise SystemExit(f"refusing to write {what} inside the git work tree {g}: private data never enters git")
	return p


def slug(s: str) -> str:
	return re.sub(r"[^a-z0-9]+", "_", (s or "").lower()).strip("_")


def _int(v, default=None):
	try:
		return int(str(v).strip())
	except (TypeError, ValueError):
		return default


# =====================================================================================================================
# Client tables
# =====================================================================================================================

def read_rows(path: Path) -> list[list[str]]:
	with open(path, newline="", encoding="utf-8", errors="replace") as f:
		return list(csv.reader(f))


class Table:
	"""A Supercell CSV: header row, types row, data rows. A row with a Name starts an entry; following rows with an
	empty Name are its continuation rows (levels, tints, extra parts)."""

	def __init__(self, path: Path):
		rows = read_rows(path)
		self.name = path.stem
		self.header = rows[0] if rows else []
		self.entries: list[dict] = []
		self.by_name: dict[str, dict] = {}
		cur = None
		for i, r in enumerate(rows[2:], start=3):
			d = {h: (r[j] if j < len(r) else "") for j, h in enumerate(self.header)}
			d["_line"] = i
			nm = d.get("Name", "")
			if nm:
				cur = {"Name": nm, "line": i, "rows": [d]}
				self.entries.append(cur)
				self.by_name.setdefault(nm, cur)
			elif cur is not None:
				cur["rows"].append(d)

	def first(self, name: str) -> dict | None:
		e = self.by_name.get(name)
		return e["rows"][0] if e else None

	def footprint(self, name: str) -> list[int] | None:
		r = self.first(name)
		if not r:
			return None
		w, h = _int(r.get("TileWidth")), _int(r.get("TileHeight"))
		return [w, h] if w and h else None


def load_texts(loc_dir: Path) -> dict[str, str]:
	t: dict[str, str] = {}
	for fn in ("texts.csv", "texts_patch.csv"):
		p = loc_dir / fn
		if not p.exists():
			continue
		for r in read_rows(p)[2:]:
			if len(r) > 1 and r[0] and r[1]:
				t[r[0]] = r[1].replace("<TODO:>", "").strip()
	return t


def parse_level(path: Path) -> dict:
	"""Multi-section level CSV: a row whose column 0 is non-empty starts a section (TileMap, SpecialObjects, Objects,
	Objects1..n, Sounds, WaterDecoZones). TileMap: labels row, types row, one row per y (column 0 empty, x = column - 1).
	Objects*: nested blocks (object name in column 1, then X/Y/Mirrored rows in columns 2..4). Others: header row
	(columns 1..), types row, data rows."""
	rows = read_rows(path)
	starts = [(r[0], i) for i, r in enumerate(rows) if r and r[0] != ""]
	out: dict = {"sections": [s for s, _ in starts]}
	for si, (name, start) in enumerate(starts):
		end = starts[si + 1][1] if si + 1 < len(starts) else len(rows)
		body = rows[start + 1:end]
		if name == "TileMap":
			labels = body[0][1:] if body else []
			ncol = len(labels)
			while ncol and labels[ncol - 1] == "":
				ncol -= 1
			grid = []
			for r in body[2:]:
				vals = r[1:1 + ncol]
				vals += [""] * (ncol - len(vals))
				grid.append([0 if v.strip() == "" else int(v) for v in vals])
			out["tilemap"] = {"labels": labels[:ncol], "grid": grid}
		elif name.startswith("Objects"):
			objs, cur = [], None
			for r in body:
				r = r + [""] * 8
				if r[1] != "":
					cur = r[1]
					continue
				if r[2] in ("X", "int") or cur is None or r[2] == "":
					continue
				objs.append({"name": cur, "x": int(r[2]), "y": _int(r[3], 0), "mirrored": r[4].strip().lower() == "true"})
			out[name] = objs
		else:
			hdr = list(body[0][1:]) if body else []
			while hdr and hdr[-1] == "":
				hdr.pop()
			recs = []
			for r in body[2:]:
				vals = r[1:1 + len(hdr)] + [""] * len(hdr)
				if all(c == "" for c in vals[:len(hdr)]):
					continue
				recs.append({h: vals[i] for i, h in enumerate(hdr)})
			out[name] = recs
	return out


def group_index(section_name: str) -> int:
	m = re.fullmatch(r"Objects(\d*)", section_name)
	return int(m.group(1) or 0) if m else -1


class Client:
	"""Lazy access to one client build's tables: <assets>/data/*.csv, <assets>/localization/*.csv, <assets>/sc."""

	def __init__(self, assets: Path, version: str | None = None):
		self.assets = Path(assets)
		self.data = self.assets / "data"
		self.loc = self.assets / "localization"
		self.sc = self.assets / "sc"
		self._tables: dict[str, Table | None] = {}
		self._texts = None
		self._level = None
		self._size_index = None
		fp = read_json(self.assets / "fingerprint.json", {}) or {}
		self.version = version or str(fp.get("version") or self.assets.parent.name)

	def table(self, name: str) -> Table | None:
		if name not in self._tables:
			p = self.data / f"{name}.csv"
			self._tables[name] = Table(p) if p.exists() else None
		return self._tables[name]

	@property
	def texts(self) -> dict[str, str]:
		if self._texts is None:
			self._texts = load_texts(self.loc)
		return self._texts

	def text(self, tid: str | None) -> str | None:
		return self.texts.get(tid or "") or None

	@property
	def level(self) -> dict:
		if self._level is None:
			self._level = parse_level(self.data / "level_0.csv")
		return self._level

	def size_index(self) -> dict[str, list[tuple[str, dict]]]:
		"""Name -> [(table, entry)] over every table with TileWidth/TileHeight (seed objects, special objects)."""
		if self._size_index is None:
			idx: dict[str, list] = collections.defaultdict(list)
			for p in sorted(self.data.glob("*.csv")):
				if p.stem.startswith("level_"):
					continue
				try:
					head = read_rows(p)[:1]
				except OSError:
					continue
				if not head or "Name" not in head[0] or "TileWidth" not in head[0]:
					continue
				t = self.table(p.stem)
				for e in t.entries:
					idx[e["Name"]].append((t.name, e))
			self._size_index = idx
		return self._size_index


# =====================================================================================================================
# Geometry helpers
# =====================================================================================================================

def rle(row: list[int]) -> list[list[int]]:
	out: list[list[int]] = []
	for v in row:
		if out and out[-1][0] == v:
			out[-1][1] += 1
		else:
			out.append([v, 1])
	return out


def unrle(rows: list) -> list[list[int]]:
	return [[v for v, n in r for _ in range(n)] for r in rows]


def rects_of(cells) -> list[list[int]]:
	"""Exact decomposition of a tile set into [x, y, w, h] rects (row runs, merged downwards while identical)."""
	cells = set(cells)
	rows = collections.defaultdict(list)
	for x, y in cells:
		rows[y].append(x)
	open_r: dict = {}
	out = []
	for y in sorted(rows):
		xs = sorted(rows[y])
		runs = []
		for x in xs:
			if runs and runs[-1][1] == x - 1:
				runs[-1][1] = x
			else:
				runs.append([x, x])
		new_open = {}
		for a, b in runs:
			r = (a, b)
			if r in open_r and open_r[r][1] + open_r[r][3] == y:
				x0, y0, w, h = open_r[r]
				new_open[r] = (x0, y0, w, h + 1)
			else:
				new_open[r] = (a, y, b - a + 1, 1)
		for r, rect in open_r.items():
			if new_open.get(r) is None or new_open[r][1] != rect[1]:
				out.append(list(rect))
		open_r = new_open
	out.extend(list(r) for r in open_r.values())
	assert sum(w * h for _, _, w, h in out) == len(cells)
	return sorted(out, key=lambda r: (r[1], r[0]))


def cells_of_rects(rects) -> set:
	return {(x, y) for rx, ry, w, h in rects for y in range(ry, ry + h) for x in range(rx, rx + w)}


def bbox_of(cells) -> list[int]:
	xs = [c[0] for c in cells]
	ys = [c[1] for c in cells]
	return [min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1]


def centroid(cells) -> tuple[float, float]:
	n = len(cells)
	return (sum(c[0] + 0.5 for c in cells) / n, sum(c[1] + 0.5 for c in cells) / n)


def clip_rect(r, w: int, h: int):
	x0, y0 = max(0, r[0]), max(0, r[1])
	x1, y1 = min(w, r[0] + r[2]), min(h, r[1] + r[3])
	return [x0, y0, x1 - x0, y1 - y0] if x1 > x0 and y1 > y0 else None


# =====================================================================================================================
# Farm model (tile map + expansions)
# =====================================================================================================================

class Farm:
	def __init__(self, client: Client):
		self.client = client
		L = client.level
		if "tilemap" not in L:
			raise SystemExit("level_0.csv has no TileMap section")
		self.grid: list[list[int]] = L["tilemap"]["grid"]
		self.H = len(self.grid)
		self.W = max(len(r) for r in self.grid)
		for r in self.grid:
			r += [0] * (self.W - len(r))
		self.labels = L["tilemap"]["labels"]
		tt = read_rows(client.data / "tiles.csv")
		self.tile_hdr = tt[0]
		self.tiles = {i: {h: (r[j] if j < len(r) else "") for j, h in enumerate(tt[0])} for i, r in enumerate(tt[2:])}
		self.exp_cells: dict[int, list] = collections.defaultdict(list)
		for y, row in enumerate(self.grid):
			for x, v in enumerate(row):
				if v >= 100:
					self.exp_cells[v // 100].append((x, y))
		et = client.table("expansions")
		self.exp_entries = et.entries if et else []

	# tile types --------------------------------------------------------------------------------------------------
	def ttype(self, x: int, y: int) -> int:
		v = self.grid[y][x]
		return v % 100 if v >= 100 else v

	def tinfo(self, t: int) -> dict:
		return self.tiles.get(t, {})

	def is_road_type(self, t: int) -> bool:
		return self.tinfo(t).get("Name", "").startswith("Road")

	def blocks(self, t: int) -> bool:
		return self.tinfo(t).get("BlocksBuilding", "").upper() == "TRUE"

	def in_grid(self, x: int, y: int) -> bool:
		return 0 <= x < self.W and 0 <= y < self.H

	def expansion_at(self, x: int, y: int) -> int:
		if not self.in_grid(x, y):
			return 0
		v = self.grid[y][x]
		return v // 100 if v >= 100 else 0

	# expansions --------------------------------------------------------------------------------------------------
	def exp_row(self, gid: int) -> dict | None:
		return self.exp_entries[gid - 1] if 0 < gid <= len(self.exp_entries) else None

	def exp_cost(self, gid: int) -> dict:
		e = self.exp_row(gid)
		cost = {"land_deed": None, "mallet": None, "marker_stake": None}
		permit = 0
		locked, tid = False, ""
		if e:
			for r in e["rows"]:
				tool, amt = r.get("CollectionTool", ""), _int(r.get("CollectionToolAmount"))
				key = {"Land Deed": "land_deed", "Mallet": "mallet", "Marker Stake": "marker_stake"}.get(tool)
				if key:
					cost[key] = amt
				if r.get("LimitedCollectionTool") and _int(r.get("LimitedCollectionToolAmount")):
					permit += _int(r.get("LimitedCollectionToolAmount"))
			r0 = e["rows"][0]
			locked = r0.get("Locked", "").upper() == "TRUE"
			tid = r0.get("LockedTextTID", "")
		if permit:
			cost["expansion_permit"] = permit
		return {"cost": cost, "locked": locked, "locked_tid": tid}

	# areas -------------------------------------------------------------------------------------------------------
	def main_road_rows(self) -> tuple[int, int]:
		"""The block of full-width rows made only of road tiles (the main road corridor): (first y, last y)."""
		full = [y for y in range(self.H) if all(self.is_road_type(self.ttype(x, y)) and self.grid[y][x] < 100
			for x in range(self.W))]
		if not full:
			raise SystemExit("no full-width road rows in the TileMap: cannot find the main road")
		# the longest contiguous block
		best, cur = [], []
		for y in full:
			if cur and y == cur[-1] + 1:
				cur.append(y)
			else:
				cur = [y]
			if len(cur) > len(best):
				best = list(cur)
		return best[0], best[-1]


# =====================================================================================================================
# Wiki correspondence (public wiki plot tables in data/research/expansions_research.json)
# =====================================================================================================================

# canonical plot-id prefix per public wiki section id (design s2); new client strips get "new_<maj>_<min>_<side>"
SECTION_CANON = {
	"main": "main",
	"main_upper_2021": "upper_2021",
	"across_road_regular_2015": "regular_2015",
	"across_road_regular_2018": "regular_2018",
	"special_2017": "special_2017",
	"special_2018": "special_2018",
	"special_lower_2019_2021": "lower",
	"special_spring_2023": "spring_2023",
}


def wiki_cost_key(p: dict) -> tuple:
	c = p.get("cost") or {}
	return (c.get("land_deed"), c.get("expansion_permit") or 0)


def game_cost_key(cost: dict) -> tuple:
	return (cost.get("land_deed"), cost.get("expansion_permit") or 0)


def solve_adjacency(wiki_plots: list[dict], gids: list[int], gcost: dict, gadj: dict, limit: int = 2) -> list[dict]:
	"""All bijections wiki plot number -> game id (up to ``limit``) with equal (land deeds, permits) whose adjacency
	agrees completely with the wiki's adjacent_plots (made symmetric)."""
	nums = [p["number"] for p in wiki_plots]
	wadj = {n: set() for n in nums}
	for p in wiki_plots:
		for m in p.get("adjacent_plots") or []:
			if m in wadj and m != p["number"]:
				wadj[p["number"]].add(m)
				wadj[m].add(p["number"])
	wkey = {p["number"]: wiki_cost_key(p) for p in wiki_plots}
	cands = {n: [g for g in gids if game_cost_key(gcost[g]) == wkey[n]] for n in nums}
	order = sorted(nums, key=lambda n: (len(cands[n]), n))
	sols: list[dict] = []
	assign: dict = {}
	used: set = set()

	def bt(i: int):
		if len(sols) >= limit:
			return
		if i == len(order):
			sols.append(dict(assign))
			return
		n = order[i]
		for g in cands[n]:
			if g in used:
				continue
			if all((m in wadj[n]) == (assign[m] in gadj.get(g, ())) for m in assign):
				assign[n] = g
				used.add(g)
				bt(i + 1)
				del assign[n]
				used.discard(g)

	if len(nums) == len(gids):
		bt(0)
	return sols


def match_by_cost(wiki_plots: list[dict], gids: list[int], gcost: dict, gadj: dict, gcent: dict) -> dict | None:
	"""Wiki number -> (game id, how, confidence) by unique (land deeds, permits) pairs; plots that share a pair are
	resolved by neighbour-number continuity: the assignment that makes the most consecutive wiki numbers adjacent
	plots, then the shortest total centroid distance between consecutive numbers."""
	wk = collections.defaultdict(list)
	for p in wiki_plots:
		wk[wiki_cost_key(p)].append(p["number"])
	gk = collections.defaultdict(list)
	for g in gids:
		gk[game_cost_key(gcost[g])].append(g)
	if sorted((k, len(v)) for k, v in wk.items()) != sorted((k, len(v)) for k, v in gk.items()):
		return None
	fixed: dict = {}
	groups = []
	for k, ns in wk.items():
		gs = sorted(gk[k])
		if len(ns) == 1:
			fixed[ns[0]] = (gs[0], "unique (land deeds, expansion permits) pair within the section", "strong")
		else:
			groups.append((sorted(ns), gs))
	if not groups:
		return fixed
	options = [list(itertools.permutations(gs)) for _, gs in groups]
	n_combos = math.prod(len(o) for o in options)
	if n_combos > 50000:
		return None
	best, best_score = None, None
	base = {n: g for n, (g, _, _) in fixed.items()}
	for combo in itertools.product(*options):
		a = dict(base)
		for (ns, _), perm in zip(groups, combo):
			a.update(zip(ns, perm))
		adj_count, dist = 0, 0.0
		for n in sorted(a):
			if n + 1 in a:
				g1, g2 = a[n], a[n + 1]
				if g2 in gadj.get(g1, ()):
					adj_count += 1
				(x1, y1), (x2, y2) = gcent[g1], gcent[g2]
				dist += math.hypot(x1 - x2, y1 - y2)
		score = (-adj_count, round(dist, 6))
		if best_score is None or score < best_score:
			best, best_score = a, score
	for ns, _ in groups:
		for n in ns:
			fixed[n] = (best[n], f"cost pair shared by {len(ns)} plots; chosen by neighbour-number continuity", "plausible")
	return fixed


# =====================================================================================================================
# Landmarks: curated identification of the SpecialObjects rows (no coordinates here: they come from level_0.csv)
# =====================================================================================================================
# so = SpecialObjects name; table/row = the object's own client table row (footprint); states = (state, sc, export,
# condition); feature = features.csv row (unlock level); replaces = catalogue items that duplicated the landmark;
# skin = customization kind; public_unlock = level from the public wiki when no client row states one.

def _S(state, sc, export, cond=""):
	return (state, sc, export, cond)


LANDMARK_DEFS = [
	dict(id="farmhouse", so="House", table="houses", row="Home building", name="Farmhouse", tid=None,
		states=[_S("broken", "whitehouse_skins", "home_01_broken", "new farm before the tutorial repair")]
		+ [_S(f"stage_{i}", "whitehouse_skins", f"home_{i:02d}", "achievement stage") for i in range(1, 10)]
		+ [_S("customizable", "whitehouse_skins", "home_10_customizable", "final achievement stage; takes skins")],
		default_state="customizable", skin="house", replaces=["farmhouse"], confidence="strong",
		evidence="SpecialObjects House row; a second base-Objects 'Home building' row is not drawn (its footprint would "
			"cover driveway road tiles and contain the houses.csv BuildTile, which lies on the driveway in front of the "
			"SpecialObjects position)",
		note="Fixed in place. Its look follows your achievements; the final stage takes skins (level 31, 20 achievements)."),
	dict(id="truck", so="Car", table="cars", row="Truck", name="Truck", tid=None,
		states=[_S("idle", "trucks_skins", "truck_0", "parked; cargo and exhaust hidden")],
		default_state="idle", skin="truck", replaces=["truck_and_order_board"], public_unlock=3, center=True,
		confidence="plausible",
		evidence="SpecialObjects Car row + cars.csv footprint; the truck art is centred on its registration point and "
			"the TileMap's Road_01_Blocked pair next to it marks the parking cells (blocks = that pair, plausible)",
		note="Parked next to the order board. Unlocks at level 3 (wiki)."),
	dict(id="order_board", so="OrderTable", table="order_tables", row="OrderTable", name="Order board",
		tid="TID_ORDER_TABLE_TITLE", states=[_S("default", "buildings_new", "orderboard_01")], default_state="default",
		replaces=["truck_and_order_board"], public_unlock=3, note="Truck orders. Unlocks at level 3 (wiki)."),
	dict(id="roadside_shop", so="RoadsideShop", table="roadside_shop", row="RoadsideShop", name="Roadside Shop",
		tid="TID_ROADSIDE_SHOP_TITLE", states=[_S("default", "rss_skins", "roadsideshop_customizable", "takes skins")],
		default_state="default", skin="roadside_shop", feature="RoadsideShop", replaces=["roadside_shop"],
		note="Stands on the road verge in front of the farm."),
	dict(id="newspaper_mailbox", so="MailBox", table="mailboxes", row="Mailbox", name="Mailbox (newspaper)",
		tid="TID_FEATURE_RSS_NEWSPAPER", states=[_S("default", "buildings_new", "mailbox_01")], default_state="default",
		feature="MailBox", replaces=["mailbox", "newspaper_daily_dirt"], note="Opens the Daily Dirt newspaper."),
	dict(id="letter_mailbox", so="GiftMailBox", table="giftmailbox", row="GiftMailBox", name="Letter mailbox", tid=None,
		states=[_S("default", "buildings_new", "gift_post_box")], default_state="default", feature="Postman",
		replaces=["mailbox"], note="Letters and gift cards."),
	dict(id="tom_box", so="BoyBox", table="boy_box", row="BoyBox", name="Tom's box", tid="TID_TOM",
		states=[_S("default", "buildings_new", "buyer_spot")], default_state="default", feature="Boy", replaces=[],
		note="Where you call Tom."),
	dict(id="movie_ticket", so="MovieTicket", table="movie_tickets", row="MovieTickets", name="Movie ticket",
		tid="TID_MOVIE_TICKET_TITLE", states=[_S("default", "buildings_new", "movie_ticket")], default_state="default",
		level_column="RequiredLevel", footprint_fallback=[1, 1], transient=True, hidden=True, replaces=[],
		note="Video-ad prop that comes and goes; hidden by default."),
	dict(id="wheel_of_fortune", so="SpinWheelCar", table="wheel_cars", row="TruckWheel", name="Wheel of Fortune truck",
		tid="TID_WHEEL_OF_FORTUNE_TITLE", states=[_S("parked", "buildings_new", "truck_wheel_stop"),
			_S("driving", "buildings_new", "truck_drive")], default_state="parked", feature="SpinWheelCar",
		replaces=["wheel_of_fortune_truck"], note="Parked across the road."),
	dict(id="boat_leaderboard", so="BoatScoreBoard", table="score_boards", row="BoatScores", name="Boat leaderboard",
		tid="TID_LEADERBOARD_HUD_TITLE", states=[_S("default", "buildings_new", "boat_leaderboard")],
		default_state="default", feature="BoatLeaderboard", replaces=["leaderboard"], note="On the river bank."),
	dict(id="mystery_package", so="Gift", table="gifts", row="SmallPresent", name="Mystery package spot",
		tid="TID_GIFT_S_TITLE", states=[_S("default", "buildings_new", "post_package", "only while a package waits")],
		default_state="default", feature="Gifting", transient=True, hidden=True, replaces=[],
		note="Appears only while a mystery package is waiting; never blocks placement."),
	dict(id="fishing_boat", so="FishingBoat", table="fishing_boat", row="FishingBoatWreck", name="Fishing boat",
		tid="TID_FISHING_BOAT", states=[_S("broken", "common", "fishing_boat_wreck", "before repair"),
			_S("repaired", "common", "fishing_boat"), _S("away_fishing", "common", "fishing_boat_norack",
			"while you are at the Fishing Lake")], default_state="repaired", feature="FishingBoat",
		replaces=["fishing_boat"], note="Boat to the Fishing Lake, moored on the river."),
	dict(id="event_board", so="EventBoard", table="eventboard", row="EventBoard", name="Event board",
		tid="TID_EVENT_BOARD", states=[_S("default", "buildings_new", "event_sign_post")], default_state="default",
		feature="EventBoard", replaces=["event_board"], note="Moved by Supercell in client updates; fixed for players."),
	dict(id="neighborhood_house", so="NeighborhoodBuilding", table="neighborhood_buildings",
		row="NeighborhoodBuildingBroken", name="Neighborhood house", tid="TID_NEIGHBORHOOD",
		states=[_S("broken", "buildings_new", "nh_house_broken", "before repair"), _S("repaired", "buildings_new",
			"nh_house_lvl1")], default_state="repaired", feature="Neighborhood", replaces=["neighborhood_house"],
		note="Across the road."),
	dict(id="farm_train_station", so="Drasine", table="drasine", row="DraisineFarmBroken",
		name="Train platform (to the Town)", tid="TID_TRAIN", states=[_S("broken", "common", "train_farm_station_broken",
			"before repair"), _S("repaired", "common", "train_farm_station"), _S("handcar", "common", "draisine",
			"handcar waiting")], default_state="repaired", feature="Train", replaces=["train_station_farm"],
		note="Gateway to the Town; only the structure is drawn."),
	dict(id="town_request_board", so="TownRequestBoard", table="town_request_board", row="TownRequestBoard",
		name="Town visitor request board", tid="TID_TOWN_REQUEST_BOARD_TITLE",
		states=[_S("default", "buildings_new", "town_request_board")], default_state="default",
		feature="TownRequestBoard", replaces=[], note="Across the road."),
	dict(id="derby", so="Derby", table="derby", row="Derby", name="Derby stand", tid="TID_NEIGHBORHOOD_DERBY",
		states=[_S("locked", "buildings_new", "derby_locked"), _S("broken", "buildings_new", "derby_broken"),
			_S("active", "buildings_new", "derby", "derby running")], default_state="active",
		feature="NeighborhoodDerby", replaces=["derby_stand"], note="Neighborhood Derby stand across the road."),
	dict(id="riverboat_dock", so="Dock", table="docks", row="Dock", name="Riverboat dock", tid="TID_DOCKS",
		states=[_S("broken", "buildings_new", "dock_01", "before repair"), _S("repaired", "buildings_new", "pier_stone")],
		default_state="repaired", feature="Boat", replaces=["riverboat_dock"],
		note="Mostly over the river; its land end blocks two farm tiles."),
	dict(id="neighborhood_donations_area", so="NeighborhoodDonationsArea", table="neighborhood_donations_area",
		row="DonationsArea", name="Neighborhood patio (donations area)",
		tid="TID_NEIGHBORHOOD_TRADING_DONATION_INFO_POPUP_TITLE",
		states=[_S("locked", "buildings_new", "nh_donations_area_locked"), _S("level_1", "buildings_new",
			"nh_donations_area")], default_state="level_1", feature="Neighborhood", replaces=[],
		note="Across the road, next to the neighborhood house."),
	dict(id="neighborhood_request_board", so="NeighborhoodRequestBoard", table="neighborhood_request_board",
		row="RequestBoard", name="Neighborhood mailbox (request board)", tid="TID_NEIGHBORHOOD_TRADING_REQUESTS_TITLE",
		states=[_S("locked", "buildings_new", "nh_requests_locked"), _S("broken", "buildings_new", "nh_requests_broken"),
			_S("level_1", "buildings_new", "nh_requests"), _S("level_2", "buildings_new", "nh_requests_lvl2")],
		default_state="level_1", feature="NeighborhoodRequests", replaces=["mailbox"],
		note="The neighborhood 'birdhouse' mailbox."),
	dict(id="helpers_house", so="HelperHouse", table="helper_house", row="Helper house", name="Helpers' house",
		tid="TID_FEATURE_HELPERS", states=[_S("default", "buildings_new", "helper_house")], default_state="default",
		feature="FarmHelpers", replaces=["helpers_house"], note="Up on the cliff above the mine."),
	dict(id="helper_collection_area", so="HelperCollectionArea", table="helper_collection_area",
		row="HelperCollectionArea", name="Helpers' collection area", tid=None,
		states=[_S("default", "buildings_new", "helper_collection_area")], default_state="default",
		feature="FarmHelpers", replaces=[], note="Pickup spots next to the helpers' house."),
	dict(id="maggies_workbench", so="RenovatorStand", table="renovator_stand", row="RenovatorStand",
		name="Maggie's workbench", tid="TID_FEATURE_BUILDER", states=[_S("default", "buildings_new",
			"customization_mapobject")], default_state="default", feature="RenovatorStand", replaces=[],
		note="Where house, truck and roadside shop skins are bought."),
	dict(id="valley_board", so="MapGameStand", table="mapgame_stand", row="MapGameStand", name="Valley board",
		tid="TID_FEATURE_VALLEY", states=[_S("default", "buildings_new", "boardgame_stand")], default_state="default",
		feature="MapGame", replaces=["valley_board"], note="Gateway to the Valley; only the structure is drawn."),
	dict(id="pop_promo_stand", so="PopPromoStand", table="pop_stand", row="PopPromoStand",
		name="Hay Day Pop promo stand", tid="TID_POP_PROMO_UNLOCKED_TITLE",
		states=[_S("default", "buildings_new", "map_object_pop")], default_state="default", feature="PopPromoStand",
		hidden=True, replaces=[], note="Feature disabled in this client; hidden by default."),
	dict(id="farm_pass_house", so="FarmPassBuilding", table="farm_pass_building", row="FarmPassBuilding",
		name="Farm Pass chick house", tid="TID_FEATURE_FARM_PASS",
		states=[_S("default", "buildings_new", "chick_house_mapobject", "season running"),
			_S("farm_pass", "buildings_new", "chick_house_mapobject_fp", "you own the Farm Pass"),
			_S("closed", "buildings_new", "chick_house_mapobject_closed", "between seasons")],
		default_state="default", feature="FarmPass", replaces=[], note="Across the road."),
	dict(id="decoration_collection_book", so="DecoStickerBookStand", table="deco_sticker_book_stand",
		row="DecoStickerBookStand", name="Decoration collection book stand", tid="TID_FEATURE_DECO_STICKER_BOOK",
		states=[_S("default", "buildings_new", "stickerbook_mapobject")], default_state="default",
		feature="DecoStickerBook", replaces=[], note="Across the road."),
	dict(id="design_festival_stand", so="DecoEventBuilding", table="deco_event_building", row="DecoEventBuilding",
		name="Design Festival stand", tid="TID_FEATURE_DECO_EVENT",
		states=[_S("default", "buildings_new", "decoevent_mapobject")], default_state="default", feature="DecoEvent",
		replaces=[], note="Across the road."),
	dict(id="neighborhood_nurture_object", so="NeighborhoodObject", table="neighborhood_objects", row="Placeholder",
		name="Neighborhood Nurture object", tid="TID_NH_OBJECT_HELP_TITLE",
		states=[_S("placeholder", "nh_object", "under_construction_sign", "between events")],
		default_state="placeholder", feature="NeighborhoodObject", replaces=[],
		note="Event object slot; between events a construction sign stands here."),
	dict(id="mastery_workbench", so="Workbench", table="workbench", row="BrokenWorkbench",
		name="Workbench (building mastery)", tid="TID_WORKBENCH",
		states=[_S("broken", "decos03_features", "gardening_workbench", "before repair"),
			_S("repaired", "buildings_new", "workbench_01")], default_state="broken",
		feature="WorkbenchBuildingMasteries", replaces=[],
		note="Feature flag is off in this client; whether it shows in your game is unknown."),
	dict(id="mine", so="Mine", table="mines", row="Mine", name="Mine", tid="TID_MINE",
		states=[_S("broken", "buildings_new", "mine_broken", "before repair"), _S("repaired", "buildings_new", "mine")],
		default_state="repaired", feature="Mine", replaces=["mine"], note="In a notch of the cliff; cannot be moved."),
]

# TIDs that title a feature or popup rather than the object itself
FEATURE_TIDS = {"TID_FEATURE_RSS_NEWSPAPER", "TID_TOM", "TID_FEATURE_FARM_PASS", "TID_FEATURE_DECO_STICKER_BOOK",
	"TID_FEATURE_DECO_EVENT", "TID_FEATURE_VALLEY", "TID_FEATURE_BUILDER", "TID_FEATURE_HELPERS",
	"TID_NEIGHBORHOOD_TRADING_DONATION_INFO_POPUP_TITLE", "TID_NEIGHBORHOOD_TRADING_REQUESTS_TITLE",
	"TID_NH_OBJECT_HELP_TITLE", "TID_POP_PROMO_UNLOCKED_TITLE", "TID_MOVIE_TICKET_TITLE", "TID_WHEEL_OF_FORTUNE_TITLE",
	"TID_LEADERBOARD_HUD_TITLE", "TID_ORDER_TABLE_TITLE", "TID_TOWN_REQUEST_BOARD_TITLE", "TID_NEIGHBORHOOD_DERBY",
	"TID_TRAIN"}

# Skin composition model (verified on the client's clip trees): the root export has named slot children; a part row
# swaps the slot's content for its ExportName and sets the colour transform of every node named in its TintPart rows.
SKIN_KINDS = {
	"house": {"table": "customization_house", "game_object": "Home", "landmark": "farmhouse",
		"slots": {"Building": ("Building",), "Roof": ("Roof",), "Porch": ("Porch",)},
		"slot_order": ["Building", "Roof", "Porch"], "styleguide_prefix": "Farmhouse"},
	"truck": {"table": "customization_truck", "game_object": "Truck", "landmark": "truck",
		"slots": {"TintBody": ("truck",), "Trailer": ("truck", "Trailer"), "Wheels": ("Wheels",)},
		"slot_order": ["TintBody", "Trailer", "Wheels"], "styleguide_prefix": "Truck",
		"idle_hidden": ("truck_crate", "truck_money", "Smoke")},
	"roadside_shop": {"table": "customization_rss", "game_object": "RoadsideShop", "landmark": "roadside_shop",
		"slots": {"Base": ("Base",), "Crates": ("Crates",), "Marquees": ("Marquees",)},
		"slot_order": ["Base", "Crates", "Marquees"], "styleguide_prefix": "RSS"},
}
SKIN_EVENT_TID_RE = re.compile(r"TID_CUSTOMIZATION_(BIRTHDAY|HALLOWEEN|WINTER|APRILFOOLS)")

# Catalogue items linked to client rows by the footprint research where build_pack's automatic matching has no link
# (identity only; sizes are read from the tables at run time). Landmark duplicates link to their SpecialObject table.
EXTRA_LINKS = {
	"foosil_site": ("decorations", "Fossil site"),
	"big_decorative_tree_leaf_pine": ("forests", "fir_big_01"),
	"small_decorative_tree_leaf_pine": ("forests", "fir_small_01"),
	"pond_natural": ("forests", "bog_3x3_01"),
	"rock_cluster": ("forests", "rock_2x2_01"),
	"small_rock": ("forests", "rock_1x1_01"),
	"gardener_s_decoration": ("modular_decorations", "Tree"),
	"pedestal_decoration": ("modular_decorations", "Planter"),
	"stonemason_s_decoration": ("modular_decorations", "Pond"),
	"yard_decoration": ("modular_decorations", "Pergola"),
	"nectar_bush": ("gatherer_mines", "Dandelion"),
	"peanut_bush": ("gatherer_mines", "Peanutbush"),
	"derby_stand": ("derby", "Derby"),
	"riverboat_dock": ("docks", "Dock"),
	"train_station_farm": ("drasine", "DraisineFarm"),
	"valley_board": ("mapgame_stand", "MapGameStand"),
	"wheel_of_fortune_truck": ("wheel_cars", "TruckWheel"),
	"leaderboard": ("score_boards", "BoatScores"),
	"newspaper_daily_dirt": ("mailboxes", "Mailbox"),
}
# seed objects (level_0 Objects*) -> catalogue item, from the same curated identities (natural obstacles)
EXTRA_SEED_LINKS = {f"{t}:{n}": iid for iid, (t, n) in EXTRA_LINKS.items() if t == "forests"}
# Wiki-gallery items that are probably duplicates of catalogue items listed under their in-game names: reported for a
# human to confirm, never applied.
CANDIDATE_LINKS = {
	"anchor": ("decorations", "FishingAnchor", "old_anchor"),
	"camera": ("decorations", "Camera obscura", "folding_camera"),
	"cannon": ("decorations", "FishingCannon", "old_cannon"),
	"drum": ("decorations", "CNY Drum", "big_drum"),
	"farm_theater_statue": ("decorations", "LVL 250 Reward", "farm_theater"),
	"oak_tree_swing": ("decorations", "Swing_Tree", "swing_tree"),
	"olympic_fire": ("decorations", "Olympic Flame", "classical_flame"),
	"purple_tree_with_lights": ("decorations", "Purple_lights_tree", "sparkling_tree"),
	"round_hay_bales": ("decorations", "Haybale Round", "twin_haybales"),
	"ship_wheel": ("decorations", "FishingShipWheel", "old_ship_s_wheel"),
	"skier_gnome": ("decorations", "GnomeSkier", "ski_gnome"),
	"witch_cat": ("decorations", "CatStatue", "witch_cat_statue"),
}
# catalogue items made of several client objects
STRUCTURAL = {
	"truck_and_order_board": {"parts": [("cars", "Truck"), ("order_tables", "OrderTable")],
		"action": "split into the fixed landmarks truck and order_board (world.json landmarks)"},
}
ITEM_SCOPE = {"duck_salon": "fishing_lake", "tackle_box": "fishing_lake"}


# =====================================================================================================================
# Catalogue + pack mapping
# =====================================================================================================================

def load_catalog(repo: Path = REPO_ROOT) -> dict[str, dict]:
	items = {}
	for f in sorted((repo / "data" / "items").glob("*.json")):
		if f.name == "categories.json":
			continue
		d = read_json(f, {}) or {}
		for it in (d.get("items", []) if isinstance(d, dict) else d):
			it = dict(it)
			it["_file"] = f"data/items/{f.name}"
			items[it["id"]] = it
	return items


def load_mapping(root: Path) -> dict[str, str]:
	"""client object key "<table>:<Name>" -> catalogue item id (build_pack decisions; primary links first)."""
	m = read_json(root / "mapping" / "mapping.json", {}) or {}
	dec = m.get("decisions", m) if isinstance(m, dict) else {}
	out: dict[str, str] = {}
	rank = {"primary": 0, "variant": 1}
	best: dict[str, int] = {}
	for d in dec.values():
		if not isinstance(d, dict):
			continue
		go, iid = d.get("game_object"), d.get("item_id")
		if not go or not iid or d.get("status") in ("rejected", "unmatched", "review"):
			continue
		r = rank.get(d.get("role"), 2)
		if r < best.get(go, 9):
			best[go] = r
			out[go] = iid
	return out


def primary_links(root: Path) -> dict[str, str]:
	"""catalogue item id -> client object key of its primary sprite (build_pack decisions)."""
	m = read_json(root / "mapping" / "mapping.json", {}) or {}
	dec = m.get("decisions", m) if isinstance(m, dict) else {}
	out = {}
	for d in dec.values():
		if isinstance(d, dict) and d.get("item_id") and d.get("game_object") and d.get("role") == "primary" \
				and d.get("status") not in ("rejected", "unmatched", "review"):
			out[d["item_id"]] = d["game_object"]
	return out


# =====================================================================================================================
# World builder
# =====================================================================================================================

class WorldBuilder:
	def __init__(self, client: Client, wiki: dict, catalog: dict, objmap: dict[str, str]):
		self.client = client
		self.farm = Farm(client)
		self.wiki = wiki
		self.catalog = catalog
		self.objmap = objmap
		self.report: dict = {"warnings": []}

	def warn(self, msg: str) -> None:
		self.report["warnings"].append(msg)

	# --------------------------------------------------------------------------------------------- base geometry
	def areas(self) -> dict:
		f = self.farm
		y0, y1 = f.main_road_rows()
		start_cells = [(x, y) for y in range(y0) for x in range(f.W) if f.grid[y][x] < 100
			and not (f.blocks(f.ttype(x, y)) and not f.is_road_type(f.ttype(x, y)))]
		sb = bbox_of(start_cells)
		inside = cells_of_rects([sb])
		if any(f.grid[y][x] >= 100 for x, y in inside):
			self.warn("starting land bounding box contains expansion tiles")
		road = lambda x, y: f.grid[y][x] < 100 and f.is_road_type(f.ttype(x, y))
		driveway = [(x, y) for y in range(y0) for x in range(f.W) if road(x, y)]
		town = [(x, y) for y in range(y1 + 1, f.H) for x in range(f.W) if road(x, y)]
		blocked = collections.defaultdict(list)
		for y in range(f.H):
			for x in range(f.W):
				v = f.grid[y][x]
				if v < 100 and f.blocks(v) and not f.is_road_type(v):
					blocked[v].append((x, y))
		return {"road_rows": (y0, y1), "start": sb, "start_cells": len(start_cells), "driveway": driveway,
			"town_road": town, "blocked": dict(blocked)}

	def tile_types(self) -> dict:
		f = self.farm
		used = collections.Counter(f.ttype(x, y) for y in range(f.H) for x in range(f.W))
		out = {}
		for tid in sorted(used):
			d = f.tinfo(tid)
			name = d.get("Name", str(tid))
			if name.startswith("ExpansionTile"):
				kind = "expansion"
			elif f.is_road_type(tid):
				kind = "road_blocked" if d.get("Passable", "").upper() != "TRUE" else "road"
			elif f.blocks(tid):
				kind = "blocked_passable" if d.get("Passable", "").upper() == "TRUE" else "blocked"
			else:
				kind = "buildable"
			e = {"name": name, "kind": kind, "art": d.get("ExportName") or None, "count": used[tid],
				"blocks_building": f.blocks(tid), "passable": d.get("Passable", "").upper() == "TRUE"}
			if d.get("GreenTile"):
				green = next((i for i, t in f.tiles.items() if t.get("Name") == d["GreenTile"]), None)
				e["unlocked_type"] = green
			out[str(tid)] = e
		return out

	# --------------------------------------------------------------------------------------------- expansions
	def expansions(self, road_rows) -> dict[int, dict]:
		f = self.farm
		y0, y1 = road_rows
		L = self.client.level
		groups = sorted([k for k in L if k.startswith("Objects")], key=group_index)
		on_exp = collections.defaultdict(list)
		for g in groups:
			for o in L[g]:
				e = f.expansion_at(o["x"], o["y"])
				if e:
					on_exp[e].append((group_index(g), g, o))
		out = {}
		for gid in sorted(f.exp_cells):
			cells = f.exp_cells[gid]
			ys = [c[1] for c in cells]
			side = "main" if max(ys) < y0 else ("across_road" if min(ys) > y1 else "mixed")
			if side == "mixed":
				self.warn(f"expansion {gid} straddles the main road")
			c = f.exp_cost(gid)
			batch = min((gi for gi, _, _ in on_exp.get(gid, [])), default=None)
			out[gid] = {"gid": gid, "cells": cells, "side": side, "batch": batch, **c,
				"objects": [o for _, _, o in on_exp.get(gid, [])], "centroid": centroid(cells)}
		# expansions without seed objects inherit the batch of the nearest same-side game id
		for gid, e in out.items():
			if e["batch"] is None:
				near = sorted((abs(g - gid), g) for g, o in out.items() if o["batch"] is not None and o["side"] == e["side"])
				e["batch"] = out[near[0][1]]["batch"] if near else 0
				self.warn(f"expansion {gid} has no seed objects; batch taken from expansion {near[0][1] if near else '-'}")
		adj = collections.defaultdict(set)
		owner = {c: gid for gid, e in out.items() for c in e["cells"]}
		for (x, y), g in owner.items():
			for dx, dy in ((1, 0), (0, 1)):
				o = owner.get((x + dx, y + dy))
				if o and o != g:
					adj[g].add(o)
					adj[o].add(g)
		for gid in out:
			out[gid]["neighbors"] = sorted(adj[gid])
		self.adj = adj
		return out

	def assign_sections(self, exps: dict[int, dict], start_rect) -> dict:
		"""-> {gid: {"section", "number", "wiki": {...} | None, "match", "confidence"}} + section meta."""
		wiki_secs = {s["id"]: s for s in self.wiki.get("sections", [])}
		res: dict[int, dict] = {}
		meta: dict[str, dict] = {}
		gcost = {g: e["cost"] for g, e in exps.items()}
		gcent = {g: e["centroid"] for g, e in exps.items()}
		# 1. main section: shape overlap with the public wiki tile map (u = x - starting-land width, v = y) + cost
		main = wiki_secs.get("main")
		off = start_rect[0] + start_rect[2]
		if main and main.get("main_section_tile_map"):
			wcells = collections.defaultdict(set)
			for v, row in enumerate(main["main_section_tile_map"]):
				for u, p in enumerate(row.split()):
					if _int(p):
						wcells[int(p)].add((u + off, v))
			wplot = {p["number"]: p for p in main["plots"]}
			cells = {g: set(e["cells"]) for g, e in exps.items()}
			taken: dict[int, tuple] = {}
			for n, ts in sorted(wcells.items()):
				best = max(cells, key=lambda g: (len(ts & cells[g]), -g))
				iou = len(ts & cells[best]) / len(ts | cells[best])
				same_cost = game_cost_key(gcost[best]) == wiki_cost_key(wplot.get(n, {}))
				conf = "strong" if iou >= 0.8 and same_cost else "plausible"
				if best in taken:
					self.warn(f"main plot {n} and {taken[best][0]} both overlap expansion {best} best")
					if taken[best][1] >= iou:
						continue
					res.pop(best, None)
				taken[best] = (n, iou)
				res[best] = {"section": "main", "number": n, "wiki_section": "main", "subsection": wplot.get(n, {}).get("subsection"),
					"match": f"tile overlap with the wiki main-section map (IoU {iou:.2f}) + cost {'equal' if same_cost else 'DIFFERENT'}",
					"confidence": conf}
			meta["main"] = {"wiki": "main", "numbering": "wiki"}
		# 2. remaining plots: client-locked strips, then wiki sections by cost multiset (batch = seed-object group)
		rest = [g for g in exps if g not in res]
		ver = re.findall(r"\d+", self.client.version)
		newtag = f"new_{ver[0]}_{ver[1]}" if len(ver) >= 2 else "new"
		for side, label in (("main", "main"), ("across_road", "across")):
			locked = sorted(g for g in rest if exps[g]["locked"] and exps[g]["side"] == side)
			if locked:
				sid = f"{newtag}_{label}"
				for i, g in enumerate(locked, 1):
					res[g] = {"section": sid, "number": i, "wiki_section": None, "subsection": None,
						"match": "client-locked strip; numbered in client order (ours)", "confidence": "verified-in-data"}
				meta[sid] = {"wiki": None, "numbering": "ours (client order)", "side": side}
		rest = [g for g in rest if g not in res]
		subgroups = collections.defaultdict(list)
		for g in rest:
			e = exps[g]
			subgroups[(e["side"], e["batch"], bool(e["cost"].get("expansion_permit")))].append(g)
		sg_keys = sorted(subgroups, key=lambda k: (k[0], k[1], k[2]))
		mset = lambda gs: sorted(game_cost_key(gcost[g]) for g in gs)
		used_sg: set = set()
		for wid, ws in wiki_secs.items():
			if wid == "main" or wid not in SECTION_CANON:
				continue
			wm = sorted(wiki_cost_key(p) for p in ws.get("plots", []))
			side = "main" if wid.startswith("main") else "across_road"
			cands = [k for k in sg_keys if k[0] == side and k not in used_sg]
			hit = None
			for k in cands:
				if mset(subgroups[k]) == wm:
					hit = [k]
					break
			if hit is None:
				for a, b in itertools.combinations(cands, 2):
					if sorted(mset(subgroups[a]) + mset(subgroups[b])) == wm:
						hit = [a, b]
						break
			if hit is None:
				self.warn(f"wiki section {wid}: no set of plots with the same cost multiset")
				continue
			used_sg.update(hit)
			gids = sorted(g for k in hit for g in subgroups[k])
			sid = SECTION_CANON[wid]
			plots = ws["plots"]
			how = None
			if all(p.get("adjacent_plots") for p in plots):
				sols = solve_adjacency(plots, gids, gcost, self.adj)
				if len(sols) == 1:
					how = {n: (g, "cost + complete agreement with the wiki adjacency (unique solution)", "strong")
						for n, g in sols[0].items()}
				elif sols:
					self.warn(f"{wid}: adjacency allows several numberings; using cost/continuity")
			if how is None:
				how = match_by_cost(plots, gids, gcost, self.adj, gcent)
			if how is None:
				self.warn(f"{wid}: cost pairs do not match one-to-one; plots keep exp_<id> ids")
				continue
			for n, (g, m, conf) in how.items():
				res[g] = {"section": sid, "number": n, "wiki_section": wid, "subsection": None, "match": m,
					"confidence": conf}
			meta[sid] = {"wiki": wid, "numbering": "wiki", "side": side, "batches": [k[1] for k in hit]}
		for g in exps:
			if g not in res:
				res[g] = {"section": "unmapped", "number": None, "wiki_section": None, "subsection": None,
					"match": "no wiki correspondence", "confidence": "unknown"}
		self.section_meta = meta
		return res

	# --------------------------------------------------------------------------------------------- objects
	def object_game_name(self, table: str | None, entry: dict | None, name: str) -> str:
		if entry:
			t = self.client.text(entry["rows"][0].get("TID"))
			if t:
				return t
		return name

	def resolve_object(self, name: str) -> tuple[str | None, dict | None, str | None]:
		"""seed-object row name -> (table, entry, catalogue item id or None)."""
		hits = self.client.size_index().get(name, [])
		for table, entry in hits:
			iid = self.objmap.get(f"{table}:{name}") or EXTRA_SEED_LINKS.get(f"{table}:{name}")
			if iid and iid in self.catalog:
				return table, entry, iid
			if table == "fields" and self.objmap.get("fields:EmptyField"):
				# a seed field is a field patch with a crop planted: the placeable object is the field
				return table, entry, self.objmap["fields:EmptyField"]
		if hits:
			return hits[0][0], hits[0][1], None
		return None, None, None

	# --------------------------------------------------------------------------------------------- landmarks
	def landmarks(self, areas: dict) -> list[dict]:
		f = self.farm
		c = self.client
		so_rows = {r["Name"]: r for r in c.level.get("SpecialObjects", []) if r.get("Name")}
		y0, y1 = areas["road_rows"]
		features = c.table("features")
		out = []
		seen = set()
		for d in LANDMARK_DEFS:
			r = so_rows.get(d["so"])
			if r is None:
				self.warn(f"landmark {d['id']}: SpecialObjects row {d['so']} not in this client")
				continue
			seen.add(d["so"])
			x, y = _int(r.get("X"), 0), _int(r.get("Y"), 0)
			t = c.table(d["table"])
			fp = t.footprint(d["row"]) if t else None
			fp_conf = "verified-in-data"
			if not fp:
				fp = list(d.get("footprint_fallback") or [1, 1])
				fp_conf = "plausible"
			origin = [x, y]
			blocks_conf = "verified-in-data"
			if d.get("center"):
				# parked truck: the Road_01_Blocked cells of the same column that touch its tile are its parking cells
				pair = [(x, yy) for yy in range(y - fp[1] + 1, y + fp[1]) if f.in_grid(x, yy) and f.grid[yy][x] < 100
					and f.is_road_type(f.ttype(x, yy)) and f.tinfo(f.ttype(x, yy)).get("Passable", "").upper() != "TRUE"]
				if len(pair) == fp[0] * fp[1] and pair[0][1] + len(pair) - 1 == pair[-1][1]:
					origin = [x, pair[0][1]]
				blocks_conf = "plausible"
			if x < 0:
				area = "river"
			elif y < 0:
				area = "cliff"
			elif y < y0:
				area = "farm_side"
			elif y <= y1:
				area = "road_verge"
			else:
				area = "across_road"
			rect = clip_rect([origin[0], origin[1], fp[0], fp[1]], f.W, f.H)
			blocks = [] if d.get("transient") or rect is None else [rect]   # trimmed of overlaps below
			unlock, unlock_ev = -1, None
			feat = features.first(d["feature"]) if features and d.get("feature") else None
			if feat and _int(feat.get("UnlockLevel")) is not None:
				lv = _int(feat.get("UnlockLevel"))
				enabled = feat.get("Enabled", "").upper() != "FALSE"
				if enabled and lv < 1000:
					unlock, unlock_ev = lv, f"features.csv {d['feature']} UnlockLevel"
				else:
					unlock_ev = f"features.csv {d['feature']} Enabled={feat.get('Enabled')} UnlockLevel={lv} (feature off)"
			elif d.get("level_column") and t and t.first(d["row"]) and _int(t.first(d["row"]).get(d["level_column"])):
				unlock = _int(t.first(d["row"]).get(d["level_column"]))
				unlock_ev = f"{d['table']}.csv {d['level_column']}"
			elif d.get("public_unlock"):
				unlock, unlock_ev = d["public_unlock"], "public wiki"
			game_name = c.text(d.get("tid"))
			if game_name and d.get("tid") in FEATURE_TIDS:
				game_name = f"{game_name} (feature title)"
			replaces = [i for i in d.get("replaces", []) if i in self.catalog]
			for i in d.get("replaces", []):
				if i not in self.catalog:
					self.warn(f"landmark {d['id']}: replaced catalogue item {i} does not exist")
			ev = (f"level_0.csv SpecialObjects {d['so']} (client {c.version}; same for every player); footprint "
				f"{d['table']}.csv {d['row']}" + (" (no size in the table: assumed)" if fp_conf != "verified-in-data" else "")
				+ (f"; unlock: {unlock_ev}" if unlock_ev else "") + (f"; {d['evidence']}" if d.get("evidence") else ""))
			conf = d.get("confidence") or ("plausible" if fp_conf != "verified-in-data" else "verified-in-data")
			skins = []
			if d.get("skin"):
				if not hasattr(self, "_presets"):
					self._presets = skin_presets(c)
				skins = [{"id": pr["id"], "name": pr["name"], "complete": pr["complete"], "parts": pr["parts"],
					"source": pr["source"]} for pr in self._presets.get(d["skin"], [])]
			out.append({
				"id": d["id"], "name": d["name"], "game_name": game_name, "area": area,
				"origin": origin, "footprint": fp, "mirrored": False, "blocks": blocks,
				"draw_anchor": "center" if d.get("center") else "top_corner",
				"art": f"lm_{d['id']}", "fallback_art": replaces[0] if replaces else "",
				"states": [s[0] for s in d["states"]], "default_state": d["default_state"],
				"state_info": {s[0]: s[3] for s in d["states"] if s[3]},
				"skin_kind": d.get("skin", ""), "skins": skins, "themes": [],
				"movable": False, "rotatable": False, "selectable": True,
				"transient": bool(d.get("transient")), "hidden_by_default": bool(d.get("hidden")),
				"unlock_level": unlock, "replaces_items": replaces,
				"evidence": ev, "confidence": conf, "footprint_confidence": fp_conf, "blocks_confidence": blocks_conf,
				"game_version": c.version, "special_object": d["so"], "note": d.get("note", ""),
				# The SpecialObjects row's tile (X, Y). Top-corner objects: their export's registration point is drawn
				# on its top corner (= origin). The centred truck: see landmark_anchor_offset (pending screenshot).
				"client_registration": [x, y],
			})
		for name in so_rows:
			if name not in seen:
				self.warn(f"SpecialObjects row {name} has no landmark definition (not drawn)")
		# a few client footprints overlap (all on non-buildable tiles): every tile blocks for ONE landmark; visible
		# landmarks claim tiles first (definition order), hidden-by-default ones only keep what is left
		taken: dict = {}
		for lm in sorted(out, key=lambda l: l["hidden_by_default"]):
			cells = cells_of_rects(lm["blocks"])
			mine = {cxy for cxy in cells if cxy not in taken}
			if mine != cells:
				others = sorted({taken[cxy] for cxy in cells - mine})
				lm["blocks_note"] = f"{len(cells - mine)} footprint tile(s) block for {', '.join(others)} (client footprints overlap)"
				lm["blocks"] = rects_of(mine) if mine else []
			for cxy in mine:
				taken[cxy] = lm["id"]
		return out

	# --------------------------------------------------------------------------------------------- build
	def build(self) -> dict:
		f = self.farm
		c = self.client
		ar = self.areas()
		y0, y1 = ar["road_rows"]
		exps = self.expansions(ar["road_rows"])
		secs = self.assign_sections(exps, ar["start"])
		rules = self.wiki.get("rules", {})
		lv_regular = (rules.get("farm_expansion_min_level") or {}).get("value", -1)
		lv_special = (rules.get("special_expansion_min_level") or {}).get("value", -1)
		W, H = f.W, f.H
		regions = [{"id": "start", "kind": "buildable", "name": "Starting land", "status": "game_data",
			"rects": [ar["start"]]}]
		regions.append({"id": "main_road", "kind": "road", "name": "Main road", "status": "game_data",
			"rects": [[0, y0, W, y1 - y0 + 1]]})
		if ar["driveway"]:
			regions.append({"id": "driveway", "kind": "road", "name": "Driveway", "status": "game_data",
				"rects": rects_of(ar["driveway"])})
		if ar["town_road"]:
			regions.append({"id": "town_road", "kind": "road", "name": "Road to the Town", "status": "game_data",
				"rects": rects_of(ar["town_road"])})
		for tid, cells in sorted(ar["blocked"].items()):
			name = f.tinfo(tid).get("Name", str(tid))
			regions.append({"id": f"blocked_{slug(name)}", "kind": "blocked", "name": "Not buildable" if name ==
				"DefaultBlocked" else "Not buildable (verge)", "status": "game_data", "tile_type": tid,
				"rects": rects_of(cells)})
		# plots
		plots = []
		unmapped_decos = collections.Counter()
		section_plots = collections.defaultdict(list)
		for gid in sorted(exps):
			e = exps[gid]
			s = secs[gid]
			sid = s["section"]
			pid = f"{sid}_{s['number']:02d}" if s["number"] is not None and sid != "unmapped" else f"exp_{gid}"
			decos = []
			for o in e["objects"]:
				table, entry, iid = self.resolve_object(o["name"])
				if table in ("forests", "fields") or table is None:
					continue
				if iid:
					if iid not in decos:
						decos.append(iid)
				else:
					unmapped_decos[o["name"]] += 1
			permit = e["cost"].get("expansion_permit") or 0
			wiki = {"section": s["wiki_section"], "plot": s["number"], "match": s["match"],
				"confidence": s["confidence"]} if s["wiki_section"] else None
			if sid == "main":
				name = f"Plot {s['number']}"
			elif s["number"] is not None:
				name = f"{self._section_label(sid)} plot {s['number']}"
			else:
				name = f"Expansion {gid}"
			reg = {"id": pid, "kind": "plot", "section": sid, "number": s["number"] if s["number"] is not None else gid,
				"name": name, "status": "game_data", "rects": rects_of(e["cells"]), "cost": e["cost"],
				"min_level": lv_special if permit else lv_regular,
				"min_level_source": "public rule (Supercell support): special plots (expansion permits) vs regular plots",
				"game_id": gid, "aliases": [f"exp_{gid}"], "client_locked": e["locked"],
				"locked_text": c.text(e["locked_tid"]) or "" if e["locked"] else "",
				"exclusive_decorations": decos, "wiki": wiki, "tiles": len(e["cells"]),
				"notes": "geometry, cost and lock state from the client tables" + (
					f"; wiki numbering: {s['match']}" if s["wiki_section"] else "")}
			if s.get("subsection"):
				reg["subsection"] = s["subsection"]
			plots.append(reg)
			section_plots[sid].append(pid)
		regions.extend(plots)
		# sections
		sections = []
		wiki_names = {sw["id"]: sw.get("name", sw["id"]) for sw in self.wiki.get("sections", [])}
		order = ["main"] + [SECTION_CANON[k] for k in SECTION_CANON if k != "main"] + sorted(
			(k for k in section_plots if k not in SECTION_CANON.values()),
			key=lambda k: (self.section_meta.get(k, {}).get("side") != "main", k))
		for sid in order:
			if sid not in section_plots:
				continue
			m = self.section_meta.get(sid, {})
			side = "main" if sid == "main" or m.get("side") == "main" else "across_road"
			sections.append({"id": sid, "name": wiki_names.get(m.get("wiki")) or self._section_label(sid), "side": side,
				"plots": section_plots[sid], "status": "game_data", "numbering": m.get("numbering", "ours"),
				"wiki_section": m.get("wiki")})
		# ground
		ground_rows = [rle([f.ttype(x, y) for x in range(W)]) for y in range(H)]
		# landmarks + initial objects
		lms = self.landmarks(ar)
		inits, unmapped_objs, offgrid = [], collections.Counter(), 0
		L = c.level
		for g in sorted([k for k in L if k.startswith("Objects")], key=group_index):
			for o in L[g]:
				if not f.in_grid(o["x"], o["y"]):
					offgrid += 1
					continue
				table, entry, iid = self.resolve_object(o["name"])
				if table == "houses":
					continue  # the farmhouse is a landmark
				if not iid:
					unmapped_objs[f"{table or '?'}:{o['name']}"] += 1
					continue
				gid = f.expansion_at(o["x"], o["y"])
				rec = {"item": iid, "x": o["x"], "y": o["y"], "flip": bool(o["mirrored"]),
					"group": f"exp_{gid}" if gid else "start", "game_name": self.object_game_name(table, entry, o["name"]),
					"source_group": g}
				if gid:
					rec["plot"] = next(p["id"] for p in plots if p["game_id"] == gid)
				inits.append(rec)
		# scenery placeholders + bounds
		xs = [0, W - 1] + [lm["origin"][0] for lm in lms] + [lm["origin"][0] + lm["footprint"][0] - 1 for lm in lms]
		ys = [0, H - 1] + [lm["origin"][1] for lm in lms] + [lm["origin"][1] + lm["footprint"][1] - 1 for lm in lms]
		wdz = L.get("WaterDecoZones", [])
		for z in wdz:
			xs += [_int(z.get("X"), 0), _int(z.get("X"), 0) + _int(z.get("Width"), 1) - 1]
			ys += [_int(z.get("Y"), 0), _int(z.get("Y"), 0) + _int(z.get("Height"), 1) - 1]
		bx0, by0 = min(xs) - WORLD_MARGIN, min(ys) - WORLD_MARGIN
		bx1, by1 = max(xs) + WORLD_MARGIN, max(ys) + WORLD_MARGIN
		# the camera must reach every piece of the client's edge art (river bank, cliff, forests), which extends
		# well beyond the data margin: union with the art's extent in tiles (verified placement rules, see
		# edge_art_extent); skipped with a warning when the extractor is unavailable
		ext = edge_art_extent(c, W, self.areas()["road_rows"][0])
		if ext:
			self.report["edge_art_extent"] = ext
			# + EDGE_MARGIN: the unplaced north cliff-tile copies and soft art edges
			bx0, by0 = min(bx0, math.floor(ext["x0"]) - EDGE_MARGIN), min(by0, math.floor(ext["y0"]) - EDGE_MARGIN)
			bx1, by1 = max(bx1, math.ceil(ext["x1"]) + EDGE_MARGIN), max(by1, math.ceil(ext["y1"]) + EDGE_MARGIN)
		else:
			self.warn("edge art extent unavailable (extractor or background.sc missing): world_bounds from data only")
		world_bounds = [bx0, by0, bx1 - bx0 + 1, by1 - by0 + 1]
		scenery = []
		river_x = min([_int(z.get("X"), 0) for z in wdz] + [0])
		if river_x < 0:
			scenery.append({"id": "river", "kind": "river", "rect": [river_x, by0, -river_x, by1 - by0 + 1],
				"note": "river band west of the farm (water deco zones); placeholder when no terrain is installed"})
		if bx0 < river_x:
			scenery.append({"id": "far_bank", "kind": "forest", "rect": [bx0, by0, river_x - bx0, by1 - by0 + 1]})
		if by0 < 0:
			scenery.append({"id": "cliff", "kind": "cliff", "rect": [0, by0, W, -by0],
				"note": "cliff and plateau north of the farm (mine, helpers' house)"})
		if bx1 >= W:
			scenery.append({"id": "east_forest", "kind": "forest", "rect": [W, by0, bx1 - W + 1, by1 - by0 + 1]})
		if by1 >= H:
			scenery.append({"id": "south_forest", "kind": "forest", "rect": [0, H, W, by1 - H + 1]})
		water_zones = self.water_deco_zones(wdz)
		world = {
			"format": MAP_FORMAT, "schema_version": MAP_SCHEMA, "id": MAP_ID, "name": "Hay Day farm", "frame": "game",
			"PRIVATE": PRIVATE_NOTE,
			"provenance": {"kind": "private_game_data", "source": "the user's own Hay Day client data (level_0.csv, "
				"tiles.csv, expansions.csv, special-object tables, features.csv, texts) + public wiki plot tables",
				"client_version": c.version, "generated": now_iso(), "confidence": "verified-in-data",
				"tool": f"tools/private_assets/build_world.py {TOOL_VERSION}"},
			"geometry_status": "game_data",
			"size": [W, H], "world_bounds": world_bounds,
			"regions": regions, "sections": sections,
			"ground": {"encoding": "rle-rows", "rows": ground_rows},
			"tile_types": self.tile_types(),
			"landmarks": lms, "scenery": scenery, "water_deco_zones": water_zones, "initial_objects": inits,
			"labels": [], "unmapped_sections": [],
			"sources": [f"client {c.version}: assets/data/level_0.csv (TileMap, SpecialObjects, Objects*, WaterDecoZones), tiles.csv, "
				"expansions.csv, features.csv, the special objects' own tables, localization/texts.csv",
				"data/research/expansions_research.json (public wiki plot numbers, costs, adjacency, level rules)",
				"mapping/mapping.json (client object -> catalogue item, build_pack.py)"],
			"notes": [
				"Frame: app tile == game tile; x along the road, y from the cliff to the road; origin = top corner.",
				"Plot ids are canonical (main_NN = wiki main-section plot NN); aliases exp_<game id> resolve too.",
				"Plots of the client-locked strip carry client_locked=true with the client's locked text; whether the "
				"server has unlocked them since cannot be read from the client.",
				"Landmark positions are the client's SpecialObjects rows; they are fixed for every player.",
				"water_deco_zones are the client's WaterDecoZones rows (tile rects, usually in the river west of the "
				"grid): the only tiles where WaterDeco decorations may stand. That an item's whole footprint must lie "
				"inside a zone is the app's reading (plausible), not stated by the data."],
		}
		self.report["counts"] = {
			"size": [W, H], "plots": len(plots), "plots_by_section": {s["id"]: len(s["plots"]) for s in sections},
			"plots_client_locked": sum(1 for p in plots if p["client_locked"]),
			"plots_wiki_numbered": sum(1 for p in plots if p["wiki"]),
			"plots_numbering_confidence": dict(collections.Counter(p["wiki"]["confidence"] for p in plots if p["wiki"])),
			"landmarks": len(lms), "water_deco_zones": len(water_zones), "initial_objects_mapped": len(inits),
			"initial_objects_unmapped": sum(unmapped_objs.values()), "initial_objects_offgrid_skipped": offgrid,
			"exclusive_decorations_mapped": sum(len(p["exclusive_decorations"]) for p in plots),
			"exclusive_decorations_unmapped": sum(unmapped_decos.values()),
		}
		self.report["unmapped_initial_objects"] = dict(unmapped_objs.most_common())
		self.report["unmapped_exclusive_decorations"] = dict(unmapped_decos.most_common())
		return world

	def water_deco_zones(self, rows: list) -> list:
		"""The level's WaterDecoZones rows as {id, name, rect: [x, y, w, h], enabled}; malformed rows are skipped
		with a warning. Ids are slugs of the client names (unique)."""
		out, ids = [], set()
		for i, z in enumerate(rows):
			x, y = _int(z.get("X")), _int(z.get("Y"))
			w, h = _int(z.get("Width"), 0), _int(z.get("Height"), 0)
			name = str(z.get("Name") or "").strip()
			if x is None or y is None or w <= 0 or h <= 0:
				self.warn(f"water deco zone row {i + 1} ({name or '?'}) has no usable rect: skipped")
				continue
			zid = slug(name) or f"zone_{i + 1}"
			while zid in ids:
				zid += "_2"
			ids.add(zid)
			out.append({"id": zid, "name": name or zid, "rect": [x, y, w, h],
				"enabled": str(z.get("Enabled", "true")).strip().lower() not in ("false", "0", "no")})
		return out

	def _section_label(self, sid: str) -> str:
		names = {"upper_2021": "Upper", "regular_2015": "Across the road 2015", "regular_2018": "Across the road 2018",
			"special_2017": "Special 2017", "special_2018": "Special 2018", "lower": "Lower special",
			"spring_2023": "Spring 2023"}
		if sid in names:
			return names[sid]
		m = re.fullmatch(r"new_(\d+)_(\d+)_(main|across)", sid)
		if m:
			return f"New strip (client {m.group(1)}.{m.group(2)}, {'main side' if m.group(3) == 'main' else 'across the road'})"
		return sid


# =====================================================================================================================
# Validation (map v2 schema, design s2/s3)
# =====================================================================================================================

def _is_int(v) -> bool:
	return isinstance(v, int) and not isinstance(v, bool)


def _rect_ok(r) -> bool:
	return isinstance(r, list) and len(r) == 4 and all(_is_int(v) for v in r) and r[2] > 0 and r[3] > 0


def validate_world(w: dict) -> list[str]:
	"""Schema + consistency checks; returns a list of problems (empty = valid)."""
	e: list[str] = []
	if not isinstance(w, dict):
		return ["not an object"]
	if w.get("format") != MAP_FORMAT:
		e.append("format must be hayday-sandbox-map")
	if w.get("schema_version") != MAP_SCHEMA:
		e.append("schema_version must be 2")
	if not isinstance(w.get("id"), str) or not w["id"]:
		e.append("id missing")
	if w.get("frame") != "game":
		e.append("frame must be 'game'")
	pv = w.get("provenance")
	if not isinstance(pv, dict) or pv.get("kind") not in ("public_approximation", "private_game_data"):
		e.append("provenance.kind missing/invalid")
	elif pv.get("confidence") not in ("approximate", "verified-in-data"):
		e.append("provenance.confidence invalid")
	sz = w.get("size")
	if not (isinstance(sz, list) and len(sz) == 2 and all(_is_int(v) and v > 0 for v in sz)):
		return e + ["size must be [W, H] with positive ints"]
	W, H = sz
	wb = w.get("world_bounds")
	if not _rect_ok(wb):
		e.append("world_bounds must be [x, y, w, h]")
	elif wb[0] > 0 or wb[1] > 0 or wb[0] + wb[2] < W or wb[1] + wb[3] < H:
		e.append("world_bounds must contain the placement grid")
	regions = w.get("regions")
	if not isinstance(regions, list) or not regions:
		return e + ["regions missing"]
	ids = set()
	plot_ids, aliases = set(), {}
	plot_cells: dict = {}
	for r in regions:
		rid = r.get("id") if isinstance(r, dict) else None
		if not isinstance(rid, str) or not rid:
			e.append("region without id")
			continue
		if rid in ids:
			e.append(f"duplicate region id {rid}")
		ids.add(rid)
		if r.get("kind") not in REGION_KINDS:
			e.append(f"region {rid}: kind {r.get('kind')!r} invalid")
		rects = r.get("rects")
		if not isinstance(rects, list) or not rects or not all(_rect_ok(x) for x in rects):
			e.append(f"region {rid}: rects invalid")
			continue
		if r.get("kind") == "plot":
			plot_ids.add(rid)
			for k, t in (("number", _is_int), ("game_id", _is_int), ("client_locked", lambda v: isinstance(v, bool)),
					("locked_text", lambda v: isinstance(v, str)), ("cost", lambda v: isinstance(v, dict)),
					("aliases", lambda v: isinstance(v, list) and all(isinstance(a, str) for a in v)),
					("exclusive_decorations", lambda v: isinstance(v, list) and all(isinstance(a, str) for a in v)),
					("min_level", _is_int), ("section", lambda v: isinstance(v, str) and v != "")):
				if k not in r or not t(r[k]):
					e.append(f"plot {rid}: {k} missing/invalid")
			if _is_int(r.get("game_id")) and f"exp_{r['game_id']}" not in (r.get("aliases") or []):
				e.append(f"plot {rid}: aliases must contain exp_{r['game_id']}")
			wk = r.get("wiki")
			if wk is not None and not (isinstance(wk, dict) and isinstance(wk.get("section"), str) and _is_int(wk.get("plot"))):
				e.append(f"plot {rid}: wiki must be null or {{section, plot}}")
			for a in r.get("aliases") or []:
				if a in aliases and aliases[a] != rid:
					e.append(f"alias {a} used by {aliases[a]} and {rid}")
				aliases[a] = rid
			cells = cells_of_rects(rects)
			for cxy in cells:
				if not (0 <= cxy[0] < W and 0 <= cxy[1] < H):
					e.append(f"plot {rid}: tile {cxy} outside the grid")
					break
				if cxy in plot_cells:
					e.append(f"plot {rid} overlaps plot {plot_cells[cxy]}")
					break
				plot_cells[cxy] = rid
	for a in aliases:
		if a in plot_ids and aliases[a] != a:
			e.append(f"alias {a} shadows a plot id")
	secs = w.get("sections", [])
	if not isinstance(secs, list):
		e.append("sections must be a list")
	else:
		in_sec = collections.Counter()
		for s in secs:
			if not isinstance(s, dict) or not s.get("id") or s.get("side") not in ("main", "across_road"):
				e.append(f"section {s!r:.60}: id/side invalid")
				continue
			for p in s.get("plots", []):
				if p not in plot_ids:
					e.append(f"section {s['id']}: unknown plot {p}")
				in_sec[p] += 1
		if secs:
			for p in plot_ids:
				if in_sec[p] != 1:
					e.append(f"plot {p} is in {in_sec[p]} sections")
	g = w.get("ground")
	tt = w.get("tile_types")
	if g is not None:
		rows = g.get("rows") if isinstance(g, dict) else None
		if not isinstance(g, dict) or g.get("encoding") != "rle-rows" or not isinstance(rows, list) or len(rows) != H:
			e.append("ground: encoding rle-rows with one row per grid row")
		else:
			for y, row in enumerate(rows):
				if not isinstance(row, list) or sum(n for _, n in row) != W:
					e.append(f"ground row {y} does not cover {W} tiles")
					break
				if isinstance(tt, dict) and any(str(v) not in tt for v, _ in row):
					e.append(f"ground row {y}: value without tile_types entry")
					break
	lms = w.get("landmarks", [])
	if not isinstance(lms, list):
		e.append("landmarks must be a list")
		lms = []
	lids = set()
	for lm in lms:
		lid = lm.get("id") if isinstance(lm, dict) else None
		if not isinstance(lid, str) or not lid:
			e.append("landmark without id")
			continue
		if lid in lids:
			e.append(f"duplicate landmark {lid}")
		lids.add(lid)
		o, fp = lm.get("origin"), lm.get("footprint")
		if not (isinstance(o, list) and len(o) == 2 and all(_is_int(v) for v in o)):
			e.append(f"landmark {lid}: origin invalid")
		if not (isinstance(fp, list) and len(fp) == 2 and all(_is_int(v) and v > 0 for v in fp)):
			e.append(f"landmark {lid}: footprint invalid")
		if not isinstance(lm.get("blocks"), list) or not all(_rect_ok(b) for b in lm["blocks"]):
			e.append(f"landmark {lid}: blocks invalid")
		if lm.get("draw_anchor") not in ("top_corner", "center"):
			e.append(f"landmark {lid}: draw_anchor invalid")
		if lm.get("area") not in AREAS:
			e.append(f"landmark {lid}: area invalid")
		st = lm.get("states")
		if not isinstance(st, list) or not st or lm.get("default_state") not in st:
			e.append(f"landmark {lid}: states/default_state invalid")
		if lm.get("confidence") not in CONFIDENCE:
			e.append(f"landmark {lid}: confidence invalid")
		for k in ("movable", "rotatable"):
			if lm.get(k) is not False:
				e.append(f"landmark {lid}: {k} must be false")
		for k in ("selectable", "transient", "hidden_by_default", "mirrored"):
			if not isinstance(lm.get(k), bool):
				e.append(f"landmark {lid}: {k} must be bool")
		if not _is_int(lm.get("unlock_level")):
			e.append(f"landmark {lid}: unlock_level must be int")
		if not isinstance(lm.get("art"), str) or not isinstance(lm.get("fallback_art"), str):
			e.append(f"landmark {lid}: art/fallback_art must be strings")
		sk = lm.get("skins")
		if not isinstance(sk, list) or not all(isinstance(s, dict) and isinstance(s.get("id"), str) for s in sk):
			e.append(f"landmark {lid}: skins must be a list of {{id, name}}")
		if lm.get("skin_kind") not in ("house", "truck", "roadside_shop", ""):
			e.append(f"landmark {lid}: skin_kind invalid")
		if not isinstance(lm.get("themes"), list) or not isinstance(lm.get("replaces_items"), list):
			e.append(f"landmark {lid}: themes/replaces_items must be lists")
	for o in w.get("initial_objects", []) or []:
		if not (isinstance(o, dict) and isinstance(o.get("item"), str) and o["item"] and _is_int(o.get("x"))
				and _is_int(o.get("y")) and isinstance(o.get("flip"), bool) and isinstance(o.get("group"), str)):
			e.append(f"initial object invalid: {o!r:.80}")
			break
		if not (0 <= o["x"] < W and 0 <= o["y"] < H):
			e.append(f"initial object {o['item']} outside the grid")
			break
		if o["group"] != "start" and o["group"] not in aliases and o["group"] not in plot_ids:
			e.append(f"initial object {o['item']}: group {o['group']} is not a plot")
			break
	zids = set()
	for z in w.get("water_deco_zones", []) or []:
		if not isinstance(z, dict) or not _rect_ok(z.get("rect")) or z["rect"][2] <= 0 or z["rect"][3] <= 0:
			e.append(f"water deco zone invalid: {z!r:.60}")
			continue
		if not isinstance(z.get("id"), str) or not z["id"] or z["id"] in zids:
			e.append(f"water deco zone id missing or duplicate: {z.get('id')!r}")
		zids.add(z.get("id"))
		if not isinstance(z.get("enabled", True), bool):
			e.append(f"water deco zone {z.get('id')}: enabled must be a boolean")
	for s in w.get("scenery", []) or []:
		if not isinstance(s, dict) or s.get("kind") not in SCENERY_KINDS or not _rect_ok(s.get("rect")):
			e.append(f"scenery entry invalid: {s!r:.60}")
	return e


def check_regions_against_tiles(world: dict, farm: Farm) -> list[str]:
	"""Repaint the regions like FarmMap (later regions win) and compare with the TileMap's own classification."""
	W, H = world["size"]
	kind = [["void"] * W for _ in range(H)]
	for r in world["regions"]:
		for x, y in cells_of_rects(r["rects"]):
			if 0 <= x < W and 0 <= y < H:
				kind[y][x] = r["kind"]
	bad = 0
	for y in range(H):
		for x in range(W):
			v = farm.grid[y][x]
			t = farm.ttype(x, y)
			exp = "plot" if v >= 100 else ("road" if farm.is_road_type(t) else ("blocked" if farm.blocks(t) else "buildable"))
			if kind[y][x] != exp:
				bad += 1
	return [f"{bad} tiles whose region kind differs from the TileMap"] if bad else []


# =====================================================================================================================
# Catalogue overrides (design s9)
# =====================================================================================================================

def build_overrides(client: Client, catalog: dict, links: dict[str, str]) -> tuple[dict, dict]:
	"""Footprints the client tables state for catalogue items (resize / axis swap / status confirmation) and unlock
	levels where the linked row states a real level gate. Returns (overrides document, report)."""
	items, cands, notes = {}, {}, {}
	rep = collections.Counter()
	all_links = dict(links)
	for iid, (table, name) in EXTRA_LINKS.items():
		if iid in catalog and iid not in all_links:
			all_links[iid] = f"{table}:{name}"
	for iid in sorted(all_links):
		it = catalog.get(iid)
		if it is None or it.get("category") == "planning":
			continue
		table, _, name = all_links[iid].partition(":")
		t = client.table(table)
		if t is None or name not in t.by_name:
			rep["link_row_missing"] += 1
			continue
		ent = t.by_name[name]
		r0 = ent["rows"][0]
		gfp = t.footprint(name)
		ev_row = f"assets/data/{table}.csv line {ent['line']} Name={name}"
		entry: dict = {}
		changes = []
		cur = it.get("footprint")
		prov = it.get("provisional_footprint")
		st = it.get("footprint_status")
		if gfp:
			ref = cur if isinstance(cur, list) and len(cur) == 2 else prov
			if isinstance(cur, list) and len(cur) == 2 and list(cur) == gfp:
				change = "status_only" if st == "unverified" else None
			elif ref and list(ref) == gfp:
				change = "status_only"
			elif ref and list(ref)[::-1] == gfp and gfp[0] != gfp[1]:
				change = "axis_swap"
			else:
				change = "resize"
			if change:
				entry.update({"footprint": gfp, "footprint_status": "game_data",
					"was": {"footprint": cur, "provisional_footprint": prov, "footprint_status": st},
					"evidence": f"{ev_row} TileWidth={gfp[0]} TileHeight={gfp[1]} (build {client.version})",
					"confidence": "verified-in-data"})
				changes.append(change)
				rep[f"footprint_{change}"] += 1
			else:
				rep["footprint_agrees"] += 1
		# unlock level: only a real level gate stated by the linked row (0/1 = no gate: event, reward or legacy rows)
		if "UnlockLevel" in t.header:
			lv = _int(r0.get("UnlockLevel"))
			cl = it.get("unlock_level")
			if lv is not None and lv >= 2 and lv < 1000:
				if cl != lv:
					entry["unlock_level"] = lv
					entry.setdefault("was", {})["unlock_level"] = cl
					entry["unlock_evidence"] = f"{ev_row} UnlockLevel={lv} (build {client.version})"
					entry.setdefault("confidence", "verified-in-data")
					changes.append("unlock_level")
					rep["unlock_fill" if cl is None else "unlock_correct"] += 1
				else:
					rep["unlock_agrees"] += 1
			elif lv is not None and cl != lv:
				notes[iid] = {"client_unlock_level": lv, "catalogue_unlock_level": cl,
					"reason": "the client row has no level gate (UnlockLevel 0/1: event, reward or legacy item); the "
					"catalogue value is kept", "evidence": ev_row}
				rep["unlock_not_applied_no_gate"] += 1
		if changes:
			entry["change"] = changes[0]
			entry["changes"] = changes
			if iid in ITEM_SCOPE:
				entry["scope"] = ITEM_SCOPE[iid]
			items[iid] = entry
	for iid, (table, name, dup) in CANDIDATE_LINKS.items():
		t = client.table(table)
		if iid not in catalog or t is None or name not in t.by_name:
			continue
		cands[iid] = {"footprint": t.footprint(name), "evidence": f"assets/data/{table}.csv line {t.by_name[name]['line']} "
			f"Name={name}", "duplicate_of": dup, "confidence": "plausible",
			"action": "add as an alias of the in-game-named item after a human confirms the identity"}
	structural = {}
	for iid, s in STRUCTURAL.items():
		if iid not in catalog:
			continue
		parts = []
		for table, name in s["parts"]:
			t = client.table(table)
			parts.append({"table": table, "Name": name, "footprint": t.footprint(name) if t else None})
		structural[iid] = {"parts": parts, "action": s["action"]}
	doc = {"format": OVERRIDES_FORMAT, "version": 1, "PRIVATE": PRIVATE_NOTE,
		"source": {"kind": "client_tables", "build": client.version, "generated": now_iso(),
			"tool": f"tools/private_assets/build_world.py {TOOL_VERSION}",
			"links": "build_pack.py mapping.json primary links + curated identities (EXTRA_LINKS)"},
		"axis_convention": "footprint = [TileWidth, TileHeight] = app [x, y] (x screen lower-right, y screen lower-left)",
		"items": items, "candidates_need_confirmation": cands, "structural": structural,
		"unlock_level_not_applied": notes}
	return doc, dict(rep)


def validate_overrides(doc: dict, catalog: dict | None = None) -> list[str]:
	e = []
	if doc.get("format") != OVERRIDES_FORMAT or doc.get("version") != 1:
		e.append("format/version invalid")
	for iid, it in (doc.get("items") or {}).items():
		if catalog is not None and iid not in catalog:
			e.append(f"{iid}: not a catalogue item")
		if "footprint" in it:
			fp = it["footprint"]
			if not (isinstance(fp, list) and len(fp) == 2 and all(_is_int(v) and v > 0 for v in fp)):
				e.append(f"{iid}: footprint invalid")
			if it.get("footprint_status") != "game_data":
				e.append(f"{iid}: footprint_status must be game_data")
		if "unlock_level" in it and not (_is_int(it["unlock_level"]) and it["unlock_level"] >= 1):
			e.append(f"{iid}: unlock_level invalid")
		if it.get("change") not in ("resize", "axis_swap", "status_only", "unlock_level"):
			e.append(f"{iid}: change invalid")
		if "footprint" not in it and "unlock_level" not in it:
			e.append(f"{iid}: entry changes nothing")
	return e


# =====================================================================================================================
# Landmark art (the extractor's renderer + the skin composer)
# =====================================================================================================================

RUNTIME_SLOT_RE = re.compile(r"^(Glow|Collect)\d+$")


class Art:
	def __init__(self, client: Client):
		sys.path.insert(0, str(TOOLS_DIR))
		import extract_from_apk as X  # noqa: PLC0415 - optional heavy dependency chain
		X.need("zstandard")
		X.need("texture2ddecoder")
		self.X = X
		self.client = client
		self._swf: dict = {}

	def swf(self, base: str):
		if base in self._swf:
			return self._swf[base]
		X = self.X
		p = self.client.sc / f"{base}.sc"
		if not p.exists():
			self._swf[base] = None
			return None
		raw = p.read_bytes()
		if X.is_sc2(raw):
			swf = X.parse_sc2(raw, base)
		else:
			body, _ = X.decompress_sc(raw, base)
			swf = X.parse_sc(body, base, is_tex=False)
			if swf.flags.get("external_texture"):
				tb, _ = X.decompress_sc((self.client.sc / f"{base}_tex.sc").read_bytes(), base)
				X.parse_sc(tb, base, is_tex=True, swf=swf)

		def ext(name: str):
			q = self.client.sc / name
			return q.read_bytes() if q.exists() else None
		X.load_textures(swf, "auto", ext)
		swf._ids = {}
		for i, n in swf.exports:
			swf._ids.setdefault(n, i)
		# Numbered collect slots and their pulsing glows (instances "Collect<N>" / "Glow<N>" of the helpers' and the
		# neighbourhood donations' collection areas) are runtime state: the game shows them only while something is
		# waiting to be collected (named, numbered like the slots, and code-addressed; strong, pending screenshot).
		# Drawn always, they made soft white-yellow circles in the idle art.
		slots = {n for c in swf.clips.values() for n in c.names if n and RUNTIME_SLOT_RE.match(n)}
		swf._rend = X.Renderer(swf, hidden_names=slots)
		self._swf[base] = swf
		return swf

	def has(self, base: str, export: str) -> bool:
		s = self.swf(base)
		return s is not None and export in s._ids

	def frame_of(self, swf, oid) -> int:
		clip = swf.clips.get(oid)
		if clip is None:
			return 0
		starts = {lab: i for i, (_, lab) in reversed(list(enumerate(clip.frames))) if lab}
		return next((starts[w] for w in FRAME_LABELS if w in starts), 0)

	def render_export(self, base: str, export: str, scale: float):
		swf = self.swf(base)
		oid = swf._ids.get(export) if swf else None
		if oid is None:
			return None, None
		ops, _ = swf._rend.display_list(oid, self.frame_of(swf, oid))
		if swf._rend.hidden_names and not any(o[0] == "draw" for o in ops):
			# The export is nothing but runtime slots (the helpers' collection area): the game shows an empty zone
			# there at idle. The slots are kept as the zone's only visible marker (not the idle look).
			ops, _ = self.X.Renderer(swf).display_list(oid, self.frame_of(swf, oid))
		return swf._rend.render(ops, scale=scale)

	def hidden_for(self, base: str, export: str) -> list:
		"""Instance names render_export hides for this export (empty when it keeps them; see render_export)."""
		swf = self.swf(base)
		oid = swf._ids.get(export) if swf else None
		if oid is None or not swf._rend.hidden_names:
			return []
		ops, _ = swf._rend.display_list(oid, self.frame_of(swf, oid))
		return sorted(swf._rend.hidden_names) if any(o[0] == "draw" for o in ops) else []


# Placement of the client's farm-edge art (background.sc). No table states it; the rules were derived by fitting the
# art to data facts (river bank = level_0 River sound zone, cliff foot = row 0, south road strip = the main road rows,
# east frame = the last TileMap column) and are expressed here in map terms only: "origin" = tile (0, 0), "road" =
# (0, first main-road row), "road_east" = (last column, first main-road row). The bg_edge_north_tile / _forest copies
# (their pitch is not known from data) are not placed; EDGE_MARGIN around the extent covers them.
EDGE_PIECES = (("bg_edge_west", "origin"), ("bg_edge_north", "origin"), ("deco_layer_01", "origin"),
	("bg_edge_south", "road"), ("bg_edge_southeast", "road"), ("bg_edge_east", "road_east"))


def edge_art_extent(client: "Client", W: int, road_y0: int) -> dict | None:
	"""Tile-frame extent {x0, y0, x1, y1} (floats) of every vertex the edge-art exports draw (all theme versions),
	placed by EDGE_PIECES. Geometry only: textures are not decoded. None when the extractor or the file is missing."""
	try:
		sys.path.insert(0, str(TOOLS_DIR))
		import extract_from_apk as X  # noqa: PLC0415
		X.need("zstandard")
	except Exception:  # noqa: BLE001
		return None
	f = client.sc / "background.sc"
	if not f.exists():
		return None
	raw = f.read_bytes()
	if X.is_sc2(raw):
		swf = X.parse_sc2(raw, "background")
	else:
		body, _ = X.decompress_sc(raw, "background")
		swf = X.parse_sc(body, "background", is_tex=False)
	ids = {}
	for i, n in swf.exports:
		ids.setdefault(n, i)
	rend = X.Renderer(swf, drop_placeholders=False)
	anchors = {"origin": (0, 0), "road": (0, road_y0), "road_east": (W - 1, road_y0)}
	pfx = [""] + theme_postfixes(client)
	x0 = y0 = math.inf
	x1 = y1 = -math.inf
	used = []
	for export, rule in EDGE_PIECES:
		ax, ay = anchors[rule]
		for pf in pfx:
			oid = ids.get(export + pf)
			if oid is None:
				continue
			ops, _ = rend.display_list(oid, 0)
			n = 0
			for op in ops:
				if op[0] != "draw":
					continue
				m = op[2]
				for px, py in op[1].xy:
					sx, sy = m[0] * px + m[2] * py + m[4], m[1] * px + m[3] * py + m[5]
					# SC units -> tile frame: sx = (X - Y) * 64, sy = (X + Y) * 32 relative to the anchor tile
					tx = ax + (sx / 64.0 + sy / 32.0) / 2.0
					ty = ay + (sy / 32.0 - sx / 64.0) / 2.0
					x0, x1, y0, y1 = min(x0, tx), max(x1, tx), min(y0, ty), max(y1, ty)
					n += 1
			if n:
				used.append(export + pf)
	if not used:
		return None
	return {"x0": round(x0, 2), "y0": round(y0, 2), "x1": round(x1, 2), "y1": round(y1, 2), "exports": len(used),
		"rule": "edge exports placed by EDGE_PIECES (origin / road / road_east)"}


class SkinComposer:
	"""Compose a customizable landmark from customization part rows (port of the landmark research composer)."""

	def __init__(self, art: Art, base: str, root: str, slots: dict, parts: list[dict], hide=(), root_order=None,
			theme: str | None = None):
		self.art = art
		self.swf = art.swf(base)
		X = art.X
		self.X = X
		self.root = root
		self.root_order = root_order
		self.hidden = set(hide)
		self.repl, self.tints = {}, {}
		self.angle = None
		self.missing: list[str] = []
		ids = self.swf._ids
		if theme and f"{root}{theme}" in ids:
			self.root = f"{root}{theme}"
		if "<CAR_ANGLE>" in "".join(p["export"] for p in parts):
			self.angle = self._car_angle()
		for p in parts:
			exp = p["export"].replace("<CAR_ANGLE>", str(self.angle))
			if theme and f"{exp}{theme}" in ids:
				exp = f"{exp}{theme}"
			oid = ids.get(exp)
			if oid is None:
				self.missing.append(exp)
				continue
			slot = slots[p["part"]]
			self.repl[slot] = oid
			self.tints[slot] = {t["node"]: self._tint(t) for t in p["tints"]}
			self.hidden |= set(p.get("hidden_parts") or [])

	def _car_angle(self) -> int:
		"""<CAR_ANGLE> of the root view: the a<N>_ prefix of the export placed in the root's 'truck' slot."""
		swf = self.swf
		clip = swf.clips.get(swf._ids.get(self.root))
		names = collections.defaultdict(list)
		for i, n in swf.exports:
			names[i].append(n)
		if clip is not None:
			for ch, nm in zip(clip.children, clip.names):
				if nm == "truck":
					for n in names.get(ch, []):
						m = re.match(r"a(\d+)_", n)
						if m:
							return int(m.group(1))
		raise RuntimeError(f"cannot read the view angle of {self.root}")

	@staticmethod
	def _tint(t):
		m, a = t["mul_pct"], t["add"]
		# percent -> 0..255 like the client: min(255, round(pct * 2.56)) (100 % -> 255, 50 % -> 128)
		mul = tuple(float(min(255, round((v if v is not None else 100) * 2.56))) for v in m) + (255.0,)
		add = tuple(min(255.0, float(v or 0)) for v in a)
		return (mul, add)

	def ops(self, frame: int = 0):
		ops: list = []
		oid = self.swf._ids.get(self.root)
		self._emit(oid, self.X.IDENT, self.X.CT_IDENT, frame, ops, 0, (), None)
		return ops

	def _emit(self, oid, m, ct, frame, ops, depth, path, slot, blend=0):
		X, swf, rend = self.X, self.swf, self.swf._rend
		if depth > 64:
			return
		if oid in swf.shapes:
			for cmd in swf.shapes[oid].commands:
				if not rend.is_runtime_placeholder(cmd):
					ops.append(("draw", cmd, m, ct, blend))
			return
		if oid in swf.textfields:
			return
		if oid in swf.modifiers:
			ops.append(({38: "mask", 39: "masked", 40: "unmask"}[swf.modifiers[oid]],))
			return
		clip = swf.clips.get(oid)
		if clip is None or not clip.frames:
			return
		fi = min(frame, len(clip.frames) - 1) if depth == 0 else 0
		start = sum(n for n, _ in clip.frames[:fi])
		count = clip.frames[fi][0]
		bank = swf.banks[clip.bank] if clip.bank < len(swf.banks) else swf.banks[0]
		elems = list(clip.elements[start:start + count])
		if depth == 0 and self.root_order:
			pos = [i for i, el in enumerate(elems) if el[0] < len(clip.names) and clip.names[el[0]] in self.root_order]
			named = sorted((elems[i] for i in pos), key=lambda el: self.root_order.index(clip.names[el[0]]))
			for i, el in zip(pos, named):
				elems[i] = el
		for ci, mi, ki in elems:
			if ci >= len(clip.children):
				continue
			child = clip.children[ci]
			name = clip.names[ci] if ci < len(clip.names) else None
			cm = bank["m"][mi] if mi != 0xFFFF and mi < len(bank["m"]) else X.IDENT
			cc = bank["c"][ki] if ki != 0xFFFF and ki < len(bank["c"]) else X.CT_IDENT
			cpath, cslot = path, slot
			b = clip.blends[ci] if ci < len(clip.blends) else 0
			cblend = b if b not in (0, 1) else blend
			if name:
				cpath = path + (name,)
				if name in self.hidden or name == "NoHit":
					continue
				if cpath in self.repl:
					child = self.repl[cpath]
					cslot = cpath
			if name and cslot is not None and name in self.tints.get(cslot, {}):
				cc = self.tints[cslot][name]  # a customization tint REPLACES the node's baked colour transform
			self._emit(child, X.mat_mul(m, cm), X.ct_mul(ct, cc), frame, ops, depth + 1, cpath, cslot, cblend)

	def render(self, scale: float):
		ops = self.ops(self.art.frame_of(self.swf, self.swf._ids.get(self.root)))
		return self.swf._rend.render(ops, scale=scale)


def parse_customization(client: Client, table: str) -> list[dict]:
	t = client.table(table)
	if t is None:
		return []
	parts = []
	for ent in t.entries:
		r0 = ent["rows"][0]
		p = {"name": ent["Name"], "line": ent["line"], "tid": r0.get("TID", ""), "en": client.text(r0.get("TID")),
			"part": r0.get("Part", ""), "file": r0.get("FileName", ""), "export": r0.get("ExportName", ""),
			"default": r0.get("Default", "").upper() == "TRUE", "disabled": r0.get("Disabled", "").upper() == "TRUE",
			"event_only": r0.get("ExcludeFromNormalStock", "").upper() == "TRUE", "tints": [], "hidden_parts": [],
			"part_sort_order": []}
		for r in ent["rows"]:
			if r.get("TintPart"):
				p["tints"].append({"node": r["TintPart"],
					"mul_pct": [_int(r.get("MulColorR")), _int(r.get("MulColorG")), _int(r.get("MulColorB"))],
					"add": [_int(r.get("AddColorR")), _int(r.get("AddColorG")), _int(r.get("AddColorB"))]})
			if r.get("HiddenParts"):
				p["hidden_parts"].append(r["HiddenParts"])
			if r.get("PartSortOrder"):
				p["part_sort_order"].append(r["PartSortOrder"])
		parts.append(p)
	return parts


def skin_presets(client: Client) -> dict[str, list[dict]]:
	"""Original + Style Book sets (customization_styleguide.csv) + event sets (parts sharing an event TID)."""
	out: dict[str, list[dict]] = {}
	parsed = {k: parse_customization(client, v["table"]) for k, v in SKIN_KINDS.items()}
	sg = client.table("customization_styleguide")
	for k, spec in SKIN_KINDS.items():
		P = parsed[k]
		byname = {p["name"]: p for p in P}
		defaults = {p["part"]: p["name"] for p in P if p["default"]}
		lst = [{"id": "original", "name": "Original", "parts": dict(defaults), "complete": True,
			"source": "Default=TRUE part rows"}]
		if sg:
			for ent in sg.entries:
				if not ent["Name"].startswith(spec["styleguide_prefix"]):
					continue
				names = [r.get("PartName") for r in ent["rows"] if r.get("PartName")]
				parts = {byname[n]["part"]: n for n in names if n in byname}
				en = client.text(ent["rows"][0].get("TID")) or ent["Name"]
				full = dict(defaults)
				full.update(parts)
				lst.append({"id": slug(en), "name": en, "parts": full, "complete": len(parts) == len(spec["slots"]),
					"source": f"customization_styleguide.csv {ent['Name']}"})
		groups: dict = {}
		for p in P:
			if SKIN_EVENT_TID_RE.match(p["tid"]) and p["event_only"] and not p["disabled"]:
				groups.setdefault(p["tid"], {}).setdefault(p["part"], p["name"])
		for tid, parts in groups.items():
			en = next((p["en"] for p in P if p["tid"] == tid and p["en"]), None) or tid
			year = re.search(r"(20\d\d)", tid)
			name = en if (year and year.group(1) in en) else (f"{en} ({year.group(1)})" if year else en)
			full = dict(defaults)
			full.update(parts)
			lst.append({"id": "event_" + slug(tid[len("TID_CUSTOMIZATION_"):]), "name": name, "parts": full,
				"complete": len(parts) == len(spec["slots"]), "source": f"event parts sharing {tid}"})
		seen = set()
		for s in lst:  # unique ids
			base, n = s["id"], 2
			while s["id"] in seen:
				s["id"] = f"{base}_{n}"
				n += 1
			seen.add(s["id"])
		out[k] = lst
		out[f"_{k}_parts"] = P
	return out


def theme_postfixes(client: Client) -> list[str]:
	t = client.table("themes")
	pf = []
	if t:
		for e in t.entries:
			p = e["rows"][0].get("ExportNamePostfix", "")
			if p and p not in pf:
				pf.append(p)
	return pf


def landmark_anchor_offset(lm: dict, ppw: float) -> tuple[float, float]:
	"""Texture px from an export's registration point to the pixel the app puts on the footprint's ground centre.

	The app draws every sprite with its anchor on the footprint centre.
	* top_corner: the client draws the export's registration point on the top corner of the origin tile, so
	  anchor = registration + ((W-H)*16, (W+H)*8) world px * ppw.
	* center (the parked truck): the registration point is put on the footprint centre, i.e. the art covers the
	  Road_01_Blocked parking pair exactly (verified-in-data cells). The other reading, the uniform SpecialObjects
	  rule (registration point on the top corner of the row's tile = `client_registration`), would draw it half a
	  tile further along -x. The data supports both; which one the client uses is PENDING SCREENSHOT (Plan ->
	  Accuracy -> Write placement check compares a clicked truck centre with both). Logical cells are unaffected.
	"""
	W, H = lm["footprint"]
	if lm.get("draw_anchor") == "center":
		return (0.0, 0.0)
	return ((W - H) * HALF_W / 2 * ppw, (W + H) * HALF_H / 2 * ppw)


def render_landmark_sprites(client: Client, world: dict, out_dir: Path, ppw: float = PPW, workers: int = 4) -> dict:
	"""Render every landmark state, theme variant and skin preset; returns {"sprites": {...}, "report": {...}}."""
	sys.path.insert(0, str(TOOLS_DIR))
	import build_pack as BP  # noqa: PLC0415 - shared output pipeline (trim, bleed, WebP, thumbnails)
	art = Art(client)
	scale = ppw / SC_UNITS_PER_WORLD_PX
	themes = theme_postfixes(client)
	presets = skin_presets(client)
	tmp = Path(tempfile.mkdtemp(prefix="lm_", dir=str(out_dir.parent)))
	jobs, plan = [], collections.defaultdict(dict)   # plan[lm id][variant] = job id
	rep = {"rendered": 0, "missing_exports": [], "skin_missing_parts": {}, "variants": 0}
	defs = {d["id"]: d for d in LANDMARK_DEFS}
	try:
		for lm in world["landmarks"]:
			d = defs[lm["id"]]
			off = landmark_anchor_offset(lm, ppw)

			def add(variant: str, img, origin, lm=lm, off=off, same_as: str | None = None):
				if same_as is not None:   # an alias of an already rendered variant (one file, two entries)
					if same_as in plan[lm["id"]]:
						plan[lm["id"]][variant] = plan[lm["id"]][same_as]
					return
				if img is None:
					return
				jid = f"lm_{lm['id']}|{variant}"
				src = tmp / f"{lm['id']}__{variant}.png"
				img.save(src)
				jobs.append({"id": jid, "src": str(src), "anchor": [origin[0] + off[0], origin[1] + off[1]], "ppw": ppw,
					"rel": f"world/sprites/lm_{lm['id']}__{variant}.webp", "out": str(out_dir / "world" / "sprites" /
					f"lm_{lm['id']}__{variant}.webp"), "max_ppw": ppw})
				plan[lm["id"]][variant] = jid
				rep["rendered"] += 1

			skin_kind = d.get("skin")
			found_themes = set()
			for state, sc, export, _ in d["states"]:
				is_skin_state = skin_kind and state == d["default_state"]
				if is_skin_state:
					spec = SKIN_KINDS[skin_kind]
					parts_by = {p["name"]: p for p in presets[f"_{skin_kind}_parts"]}
					for pr in presets[skin_kind]:
						parts = [parts_by[pr["parts"][s]] for s in spec["slot_order"] if s in pr["parts"]]
						order = None
						for p in parts:
							if len(p["part_sort_order"]) == 3:   # 3-entry lists read front-to-back (plausible)
								order = list(reversed(p["part_sort_order"]))
						for theme in [None] + themes:
							if theme and not art.has(sc, export + theme):
								continue
							comp = SkinComposer(art, sc, export, spec["slots"], parts, hide=spec.get("idle_hidden", ()),
								root_order=order, theme=theme)
							if comp.missing and theme is None:
								rep["skin_missing_parts"][f"{lm['id']}/{pr['id']}"] = comp.missing
							img, o = comp.render(scale)
							v = f"skin_{pr['id']}" + (f"__{theme.lstrip('_')}" if theme else "")
							add(v, img, o)
							if theme:
								found_themes.add(theme.lstrip("_"))
							if pr["id"] == "original":
								# the default state IS the original skin: same image
								add(state + (f"__{theme.lstrip('_')}" if theme else ""), None, None, same_as=v)
					continue
				if not art.has(sc, export):
					rep["missing_exports"].append(f"{lm['id']}/{state}: {sc}/{export}")
					continue
				img, o = art.render_export(sc, export, scale)
				add(state, img, o)
				for theme in themes:
					if art.has(sc, export + theme):
						img, o = art.render_export(sc, export + theme, scale)
						add(f"{state}__{theme.lstrip('_')}", img, o)
						found_themes.add(theme.lstrip("_"))
			lm["themes"] = sorted(found_themes)
		log(f"landmark sprites: {len(jobs)} images rendered; encoding WebP")
		results = {}
		import multiprocessing as mp  # noqa: PLC0415
		with mp.get_context("fork").Pool(max(1, workers)) as pool:
			for res in pool.imap_unordered(BP.render_job, jobs, chunksize=2):
				results[res["id"]] = res
		sprites = {}
		for lm in world["landmarks"]:
			vs = plan.get(lm["id"], {})
			ok = {v: results[j] for v, j in vs.items() if j in results and "error" not in results[j]}
			for v, j in vs.items():
				if j in results and "error" in results[j]:
					rep.setdefault("errors", []).append(f"{j}: {results[j]['error']}")
			if not ok:
				continue
			base_v = lm["default_state"] if lm["default_state"] in ok else next(iter(ok))
			b = ok[base_v]
			entry = {"file": b["file"], "anchor": b["anchor"], "pixels_per_world_px": b["ppw"],
				"auto_anchor": False, "landmark": lm["id"], "draw_anchor": lm["draw_anchor"],
				"source": {"kind": "apk", "build": client.version, "note": "rendered by build_world.py from the client's "
					"own exports (registration point = top corner of the footprint; anchor = footprint ground centre)"},
				"variants": {v: {"file": r["file"], "anchor": r["anchor"], "pixels_per_world_px": r["ppw"]}
					for v, r in sorted(ok.items())}}
			sprites[f"lm_{lm['id']}"] = entry
			rep["variants"] += len(entry["variants"])
		# thumbnails (one per landmark, from the base image)
		from PIL import Image  # noqa: PLC0415
		for key, e in sprites.items():
			src = out_dir / e["file"]
			t = Image.open(src).convert("RGBA").convert("RGBa")
			t.thumbnail((BP.THUMB_MAX, BP.THUMB_MAX), Image.Resampling.LANCZOS)
			t = BP.bleed_rgb(t.convert("RGBA"), 6)
			rel = f"world/thumbs/{key}.webp"
			(out_dir / rel).parent.mkdir(parents=True, exist_ok=True)
			t.save(out_dir / rel, "WEBP", quality=85, method=4, exact=True)
			e["thumb"] = rel
		# stale sprite files
		live = {e["file"] for e in sprites.values()} | {v["file"] for e in sprites.values() for v in e["variants"].values()} \
			| {e["thumb"] for e in sprites.values()}
		for sub in ("world/sprites", "world/thumbs"):
			for p in (out_dir / sub).glob("*"):
				if f"{sub}/{p.name}" not in live:
					p.unlink()
		rep["sprites"] = len(sprites)
		rep["skin_presets"] = {k: len(presets[k]) for k in SKIN_KINDS}
		return {"sprites": sprites, "report": rep}
	finally:
		shutil.rmtree(tmp, ignore_errors=True)


def contact_sheet(out_dir: Path, sprites: dict, dest: Path, cols: int = 8, cell=(260, 260)) -> Path:
	"""Private contact sheet of every landmark variant (anchor cross in red, footprint label)."""
	from PIL import Image, ImageDraw  # noqa: PLC0415
	cells = [(k, v, e) for k, s in sorted(sprites.items()) for v, e in sorted(s["variants"].items())]
	rows = math.ceil(len(cells) / cols)
	sheet = Image.new("RGBA", (cols * cell[0], rows * cell[1]), (52, 58, 64, 255))
	d = ImageDraw.Draw(sheet)
	for i, (k, v, e) in enumerate(cells):
		cx, cy = (i % cols) * cell[0], (i // cols) * cell[1]
		im = Image.open(out_dir / e["file"]).convert("RGBA")
		f = min(1.0, (cell[0] - 10) / im.width, (cell[1] - 30) / im.height)
		im2 = im.resize((max(1, int(im.width * f)), max(1, int(im.height * f))))
		ox, oy = cx + (cell[0] - im2.width) // 2, cy + 22
		sheet.alpha_composite(im2, (ox, oy))
		ax, ay = ox + e["anchor"][0] * f, oy + e["anchor"][1] * f
		if cx <= ax < cx + cell[0] and cy <= ay < cy + cell[1]:   # anchors far outside the art are not drawn
			d.line([(ax - 6, ay), (ax + 6, ay)], fill=(255, 40, 40, 255), width=2)
			d.line([(ax, ay - 6), (ax, ay + 6)], fill=(255, 40, 40, 255), width=2)
		else:
			d.text((cx + 4, cy + 14), "anchor outside the art", fill=(255, 120, 120, 255))
		d.text((cx + 4, cy + 4), f"{k[3:]}/{v}"[:40], fill=(255, 255, 255, 255))
	dest.parent.mkdir(parents=True, exist_ok=True)
	sheet.save(dest)
	return dest


# =====================================================================================================================
# Cross-checks against the private research files (agreement counts only)
# =====================================================================================================================

def research_crosscheck(root: Path, world: dict, overrides: dict) -> dict:
	out: dict = {}
	rmap = read_json(root / "research" / "map" / "world_decoded.json")
	if isinstance(rmap, dict):
		plots = {p["game_id"]: p for p in world["regions"] if p["kind"] == "plot"}
		same_geo = same_wiki = diff_wiki = 0
		diffs = []
		for e in rmap.get("expansions", []):
			p = plots.get(e["game_id"])
			if p is None:
				continue
			if cells_of_rects(p["rects"]) == cells_of_rects(e["rects"]):
				same_geo += 1
			w = e.get("wiki") or {}
			if w:
				sec = {"special_lower_2019_2021": "special_lower_2019_2021"}.get(w.get("wiki_section"), w.get("wiki_section"))
				ok = p.get("wiki") and p["wiki"]["plot"] == w.get("wiki_plot") and SECTION_CANON.get(
					p["wiki"]["section"], "") == SECTION_CANON.get(sec, sec)
				if ok:
					same_wiki += 1
				else:
					diff_wiki += 1
					diffs.append(p["id"])
		out["map"] = {"research_expansions": len(rmap.get("expansions", [])), "plots": len(plots),
			"identical_geometry": same_geo, "same_wiki_number": same_wiki, "different_wiki_number": diff_wiki,
			"different_plots": diffs}
	rl = read_json(root / "research" / "landmarks" / "landmarks_app.json")
	if isinstance(rl, dict):
		ours = {lm["id"]: lm for lm in world["landmarks"]}
		same_tile = same_fp = 0
		for l in rl.get("landmarks", []):
			o = ours.get(l["id"])
			if o is None:
				continue
			if o["origin"] == l["tile"] or (o["draw_anchor"] == "center" and [o["origin"][0], o["origin"][1] + 1] == l["tile"]):
				same_tile += 1
			if o["footprint"] == l["footprint"]:
				same_fp += 1
		out["landmarks"] = {"research": len(rl.get("landmarks", [])), "ours": len(ours), "same_position": same_tile,
			"same_footprint": same_fp, "research_skin_presets": {k: len(v.get("presets", [])) for k, v in
				(rl.get("skins") or {}).items()}}
	dr = read_json(root / "research" / "footprints" / "catalog_overrides.draft.json")
	if isinstance(dr, dict):
		ours = {k: v for k, v in overrides["items"].items() if "footprint" in v}
		theirs = dr.get("items", {})
		agree = sum(1 for k, v in theirs.items() if k in ours and ours[k]["footprint"] == v["footprint"])
		out["overrides"] = {"research_items": len(theirs), "ours_footprint_items": len(ours), "agree": agree,
			"only_research": sorted(set(theirs) - set(ours)), "only_ours": sorted(set(ours) - set(theirs)),
			"different_value": sorted(k for k in theirs if k in ours and ours[k]["footprint"] != theirs[k]["footprint"])}
	return out


# =====================================================================================================================
# Main
# =====================================================================================================================

def find_assets(root: Path, version: str | None) -> Path:
	base = root / "raw" / "apk_extracted"
	if version:
		p = base / version / "assets"
		if not (p / "data" / "level_0.csv").exists():
			raise SystemExit(f"no client tables at {p}")
		return p
	vers = sorted([d for d in base.iterdir() if (d / "assets" / "data" / "level_0.csv").exists()],
		key=lambda d: tuple(int(x) for x in re.findall(r"\d+", d.name)) or (0,)) if base.is_dir() else []
	if not vers:
		raise SystemExit(f"no extracted client under {base} (run extract_from_apk.py first)")
	return vers[-1] / "assets"


def run(args) -> int:
	root = ensure_private(args.root, "the private root")
	out = ensure_private(args.out or (root / "packs" / WORLD_DIR_NAME), "the world output")
	client = Client(find_assets(root, args.client_version))
	wiki = read_json(WIKI_RESEARCH, {}) or {}
	catalog = load_catalog()
	objmap = load_mapping(root)
	if not objmap:
		log("warning: mapping/mapping.json missing or empty: initial objects / decorations stay unmapped")
	wb = WorldBuilder(client, wiki, catalog, objmap)
	world = wb.build()
	overrides, orep = build_overrides(client, catalog, primary_links(root))
	sprites_rep = None
	if not args.no_sprites:
		res = render_landmark_sprites(client, world, out, PPW, args.workers)
		write_stable(out / "world" / "landmark_sprites.json", {"pixels_per_world_px": PPW, "generated": now_iso(),
			"PRIVATE": PRIVATE_NOTE, "sprites": res["sprites"]}, ("generated",))
		sprites_rep = res["report"]
	else:
		prev = read_json(out / "world" / "landmark_sprites.json", {}) or {}
		# keep the landmark skin/theme lists of the previous sprite build
		have = (prev.get("sprites") or {})
		for lm in world["landmarks"]:
			e = have.get(lm["art"])
			if e:
				vs = e.get("variants", {})
				lm["themes"] = sorted({v.split("__", 1)[1] for v in vs if "__" in v})
		prev_rep = (read_json(out / "build_report.json", {}) or {}).get("sprites")
		if prev_rep:
			sprites_rep = dict(prev_rep, note="from the previous sprite build (this run used --no-sprites)")
		log("sprites skipped (--no-sprites): landmark theme lists taken from the previous sprite build")
	problems = validate_world(world) + check_regions_against_tiles(world, wb.farm)
	oproblems = validate_overrides(overrides, catalog)
	if problems or oproblems:
		for p in problems + oproblems:
			log(f"INVALID: {p}")
		return 1
	write_stable(out / "world" / "world.json", world, ("provenance", "generated"), indent=None)
	write_stable(out / "catalog_overrides.json", overrides, ("source", "generated"))
	report = {"generated": now_iso(), "tool": f"build_world.py {TOOL_VERSION}", "client_version": client.version,
		"PRIVATE": PRIVATE_NOTE, **wb.report, "overrides": orep,
		"overrides_counts": {"items": len(overrides["items"]),
			"by_change": dict(collections.Counter(c for v in overrides["items"].values() for c in v["changes"])),
			"candidates": len(overrides["candidates_need_confirmation"]), "structural": len(overrides["structural"]),
			"unlock_level_not_applied": len(overrides["unlock_level_not_applied"])},
		"sprites": sprites_rep, "research_crosscheck": research_crosscheck(root, world, overrides),
		"validation": "ok"}
	write_json(out / "build_report.json", report)
	c = report["counts"]
	log(f"world: {c['plots']} plots ({c['plots_client_locked']} client-locked, {c['plots_wiki_numbered']} wiki-numbered), "
		f"{c['landmarks']} landmarks, initial objects {c['initial_objects_mapped']} mapped / "
		f"{c['initial_objects_unmapped']} unmapped / {c['initial_objects_offgrid_skipped']} off-grid")
	log(f"overrides: {report['overrides_counts']}")
	if sprites_rep and not args.no_sprites:
		log(f"sprites: {sprites_rep.get('sprites')} landmark sprites, {sprites_rep.get('variants')} variants, "
			f"missing exports {len(sprites_rep['missing_exports'])}, errors {len(sprites_rep.get('errors', []))}")
	for w in wb.report["warnings"]:
		log(f"warning: {w}")
	log(f"wrote {out}")
	if args.sheet and sprites_rep and not args.no_sprites:
		d = contact_sheet(out, read_json(out / "world" / "landmark_sprites.json")["sprites"],
			root / "review_sheets" / "landmarks_contact.png")
		log(f"contact sheet: {d}")
	return 0


# =====================================================================================================================
# Self-test (synthetic fixtures only - no client data)
# =====================================================================================================================

def _write_csv(p: Path, rows: list[list]) -> None:
	p.parent.mkdir(parents=True, exist_ok=True)
	with open(p, "w", newline="", encoding="utf-8") as f:
		csv.writer(f).writerows([[("" if v is None else v) for v in r] for r in rows])


def _fixture(tmp: Path) -> tuple[Path, dict, dict, dict]:
	"""A 10 x 9 toy farm: 4 x 4 start land with a driveway, three main-side plots (one client-locked), a main road row,
	an across-road block with two regular plots and one special plot; three landmarks; seed objects."""
	A = tmp / "assets"
	W, H = 10, 9
	g = [[0] * W for _ in range(H)]
	g[3][1] = 2                                   # driveway
	g[2][1] = 3
	for y in range(0, 2):
		for x in range(4, 6):
			g[y][x] = 107                            # exp 1
	for y in range(2, 4):
		for x in range(4, 6):
			g[y][x] = 208                            # exp 2
	for y in range(0, 4):
		for x in range(6, 10):
			g[y][x] = 307                            # exp 3 (client-locked)
	for x in range(W):
		g[4][x] = 2                                  # main road
	for y in range(5, 9):
		for x in range(0, 4):
			g[y][x] = 39                             # blocked landmark zone
	for y in range(5, 7):
		for x in range(4, 6):
			g[y][x] = 407                            # exp 4
	for y in range(7, 9):
		for x in range(4, 6):
			g[y][x] = 507                            # exp 5
	for y in range(5, 9):
		for x in range(6, 10):
			g[y][x] = 609                            # exp 6 (special)
	level = [["TileMap"], [""] + ["t"] * 4 + ["e"] * 6, [""] + ["int"] * W]
	level += [[""] + ["" if v == 0 else v for v in row] for row in g]
	level += [["SpecialObjects"], ["", "Name", "X", "Y", "Mirrored", "Xoffset", "YoffSet"],
		["", "String", "int", "int", "boolean", "int", "int"],
		["", "House", 1, 0], ["", "Car", 1, 2], ["", "MailBox", 2, 4], ["", "Mine", 2, -3], ["", "Mystery", 0, 0]]
	level += [["Objects"], ["", "fir_01"], ["", "", "X", "Y", "Mirrored"], ["", "", "int", "int", "boolean"],
		["", "", 4, 0], ["", "", 4, 2], ["", "", 0, 3], ["", "", 4, 5], ["", "", 5, 8], ["", "", -2, 1],
		["", "Wheat"], ["", "", "X", "Y", "Mirrored"], ["", "", "int", "int", "boolean"], ["", "", 3, 1, "TRUE"]]
	level += [["Objects1"], ["", "Fancy statue"], ["", "", "X", "Y", "Mirrored"], ["", "", "int", "int", "boolean"],
		["", "", 7, 6]]
	level += [["Objects2"], ["", "fir_01"], ["", "", "X", "Y", "Mirrored"], ["", "", "int", "int", "boolean"],
		["", "", 8, 1]]
	level += [["WaterDecoZones"], ["", "Name", "X", "Y", "Width", "Height", "Enabled"],
		["", "String", "int", "int", "int", "int", "boolean"], ["", "Bank", -3, 0, 2, 3, "true"]]
	_write_csv(A / "data" / "level_0.csv", level)
	tiles = [["Name", "ExportName", "FileName", "BlocksBuilding", "GreenTile", "Passable"],
		["String", "String", "String", "boolean", "String", "boolean"]]
	names = {0: ("Default", "", "TRUE"), 2: ("Road_01", "TRUE", "TRUE"), 3: ("Road_N01", "TRUE", "TRUE"),
		7: ("ExpansionTile01", "", "TRUE"), 9: ("ExpansionTile03", "", "TRUE"), 39: ("DefaultBlocked", "TRUE", "")}
	for i in range(40):
		n = names.get(i, (f"Unused{i}", "", "TRUE"))
		tiles.append([n[0], f"ground_{i}", "sc/background.sc", n[1], "Default" if n[0].startswith("ExpansionTile") else "",
			n[2]])
	_write_csv(A / "data" / "tiles.csv", tiles)
	exp = [["Name", "CollectionTool", "CollectionToolAmount", "TapSound", "LimitedCollectionTool",
		"LimitedCollectionToolAmount", "Disabled", "Locked", "LockedTextTID"],
		["String", "String", "int", "String", "String", "int", "boolean", "boolean", "String"]]
	costs = {1: (5, 0, False), 2: (6, 0, False), 3: (9, 0, True), 4: (7, 0, False), 5: (8, 0, False), 6: (11, 2, False)}
	for gid in range(1, 7):
		n, permit, locked = costs[gid]
		exp.append([gid * 10, "Land Deed", n, "", "Expansion Key" if permit else "", permit or "", "",
			"TRUE" if locked else "", "TID_SOON" if locked else ""])
		exp.append(["", "Mallet", n])
		exp.append(["", "Marker Stake", n])
	_write_csv(A / "data" / "expansions.csv", exp)
	_write_csv(A / "data" / "houses.csv", [["Name", "ExportName", "TileWidth", "TileHeight"], ["String"] * 4,
		["Home building", "home_01", 2, 2]])
	_write_csv(A / "data" / "cars.csv", [["Name", "ExportName", "TileWidth", "TileHeight"], ["String"] * 4,
		["Truck", "truck_0", 1, 2]])
	_write_csv(A / "data" / "mailboxes.csv", [["Name", "ExportName", "TileWidth", "TileHeight"], ["String"] * 4,
		["Mailbox", "mailbox_01", 1, 1]])
	_write_csv(A / "data" / "mines.csv", [["Name", "ExportName", "TileWidth", "TileHeight"], ["String"] * 4,
		["Mine", "mine", 3, 3]])
	_write_csv(A / "data" / "features.csv", [["Name", "Enabled", "UnlockLevel"], ["String", "Boolean", "int"],
		["MailBox", "TRUE", 7], ["Mine", "TRUE", 24]])
	_write_csv(A / "data" / "forests.csv", [["Name", "ExportName", "TileWidth", "TileHeight", "TID"], ["String"] * 5,
		["fir_01", "fir_01", 1, 1, ""]])
	_write_csv(A / "data" / "fields.csv", [["Name", "ExportName", "TileWidth", "TileHeight", "TID"], ["String"] * 5,
		["Wheat", "field", 1, 1, "TID_WHEAT"]])
	_write_csv(A / "data" / "decorations.csv", [["Name", "ExportName", "TileWidth", "TileHeight", "TID", "UnlockLevel"],
		["String"] * 6, ["Fancy statue", "statue", 2, 1, "TID_STATUE", 31], ["Gnome", "gnome", 1, 1, "TID_GNOME", 1],
		["Flower bed", "fb", 2, 2, "TID_FB", 12], ["Bench", "bench", 2, 1, "TID_BENCH", 0]])
	_write_csv(A / "localization" / "texts.csv", [["Name", "EN"], ["string", "string"], ["TID_SOON", "Unlocks soon!"],
		["TID_STATUE", "Fancy Statue"], ["TID_WHEAT", "Wheat"], ["TID_MINE", "Mine"]])
	(A / "fingerprint.json").write_text(json.dumps({"version": "9.8.7"}))
	wiki = {"rules": {"farm_expansion_min_level": {"value": 22}, "special_expansion_min_level": {"value": 25}},
		"sections": [
			{"id": "main", "name": "Main", "main_section_tile_map": ["01 01", "01 01", "02 02", "02 02"],
				"plots": [{"number": 1, "cost": {"land_deed": 5}, "subsection": 1},
					{"number": 2, "cost": {"land_deed": 6}, "subsection": 1}]},
			{"id": "across_road_regular_2015", "name": "Regular 2015", "plots": [
				{"number": 1, "cost": {"land_deed": 8}, "adjacent_plots": [2]},
				{"number": 2, "cost": {"land_deed": 7}, "adjacent_plots": [1]}]},
			{"id": "special_2017", "name": "Special 2017", "plots": [
				{"number": 1, "cost": {"land_deed": 11, "expansion_permit": 2}}]}]}
	catalog = {"fir_tree": {"id": "fir_tree", "category": "obstacle", "footprint": [1, 1]},
		"wheat_field": {"id": "wheat_field", "category": "field", "footprint": [1, 1], "flippable": True},
		"fancy_statue": {"id": "fancy_statue", "category": "decoration", "footprint": [1, 2],
			"footprint_status": "community", "unlock_level": None},
		"gnome": {"id": "gnome", "category": "decoration", "footprint": [1, 1], "footprint_status": "unverified",
			"unlock_level": 15},
		"flower_bed": {"id": "flower_bed", "category": "decoration", "footprint": [1, 1],
			"footprint_status": "community", "unlock_level": 12},
		"bench": {"id": "bench", "category": "decoration", "footprint": None, "provisional_footprint": [2, 1],
			"unlock_level": 3},
		"farmhouse": {"id": "farmhouse", "category": "farm_building", "footprint": [4, 4]},
		"mailbox": {"id": "mailbox", "category": "structures", "footprint": [1, 1]}}
	objmap = {"forests:fir_01": "fir_tree", "fields:Wheat": "wheat_field", "decorations:Fancy statue": "fancy_statue"}
	return A, wiki, catalog, objmap


def self_test() -> int:
	fails = []

	def check(cond, msg):
		if not cond:
			fails.append(msg)

	# helpers
	cells = {(0, 0), (1, 0), (0, 1), (1, 1), (3, 1), (2, 2), (3, 2)}
	rs = rects_of(cells)
	check(cells_of_rects(rs) == cells, "rects_of round trip")
	check(unrle([rle([1, 1, 2, 3, 3, 3])]) == [[1, 1, 2, 3, 3, 3]], "rle round trip")
	# adjacency solver: a 3-chain with two equal costs is solved uniquely by adjacency
	wp = [{"number": 1, "cost": {"land_deed": 5}, "adjacent_plots": [2]},
		{"number": 2, "cost": {"land_deed": 5}, "adjacent_plots": [1, 3]},
		{"number": 3, "cost": {"land_deed": 9}, "adjacent_plots": [2]}]
	gc = {10: {"land_deed": 5}, 11: {"land_deed": 9}, 12: {"land_deed": 5}}
	ga = {10: {12}, 12: {10, 11}, 11: {12}}
	sols = solve_adjacency(wp, [10, 11, 12], gc, ga)
	check(sols == [{1: 10, 2: 12, 3: 11}], f"adjacency solver: {sols}")
	# cost-pair matching with continuity
	wp2 = [{"number": 1, "cost": {"land_deed": 5}}, {"number": 2, "cost": {"land_deed": 5}},
		{"number": 3, "cost": {"land_deed": 9}}]
	cent = {10: (0.5, 0.5), 11: (1.5, 0.5), 12: (5.5, 5.5)}
	m = match_by_cost(wp2, [10, 11, 12], {10: {"land_deed": 5}, 12: {"land_deed": 5}, 11: {"land_deed": 9}},
		{10: {11}, 11: {10}}, cent)
	check(m and m[3][0] == 11 and m[3][2] == "strong" and m[2][0] == 10 and m[1][2] == "plausible",
		f"cost/continuity matching: {m}")
	check(match_by_cost(wp2, [10, 11], {10: {"land_deed": 5}, 11: {"land_deed": 9}}, {}, cent) is None,
		"cost multiset mismatch must fail")
	with tempfile.TemporaryDirectory() as td:
		A, wiki, catalog, objmap = _fixture(Path(td))
		client = Client(A)
		check(client.version == "9.8.7", "version from fingerprint.json")
		wb = WorldBuilder(client, wiki, catalog, objmap)
		world = wb.build()
		probs = validate_world(world) + check_regions_against_tiles(world, wb.farm)
		check(not probs, f"fixture world valid: {probs}")
		plots = {p["id"]: p for p in world["regions"] if p["kind"] == "plot"}
		check(set(plots) == {"main_01", "main_02", "new_9_8_main_01", "regular_2015_01", "regular_2015_02",
			"special_2017_01"}, f"plot ids: {sorted(plots)}")
		check(plots["main_01"]["game_id"] == 1 and plots["main_01"]["aliases"] == ["exp_1"], "main_01 = exp 1")
		check(plots["regular_2015_01"]["game_id"] == 5 and plots["regular_2015_02"]["game_id"] == 4, "regular by cost")
		check(plots["new_9_8_main_01"]["client_locked"] and plots["new_9_8_main_01"]["locked_text"] == "Unlocks soon!",
			"client lock + text")
		check(plots["special_2017_01"]["min_level"] == 25 and plots["main_01"]["min_level"] == 22, "min levels")
		check(plots["special_2017_01"]["cost"].get("expansion_permit") == 2, "permit cost")
		check(plots["special_2017_01"]["exclusive_decorations"] == ["fancy_statue"], "exclusive decoration mapped")
		check(world["regions"][0]["rects"] == [[0, 0, 4, 4]], f"start land {world['regions'][0]['rects']}")
		mr = next(r for r in world["regions"] if r["id"] == "main_road")
		check(mr["rects"] == [[0, 4, 10, 1]], "main road")
		lms = {l["id"]: l for l in world["landmarks"]}
		check(set(lms) == {"farmhouse", "truck", "newspaper_mailbox", "mine"}, f"landmarks {sorted(lms)}")
		check(lms["farmhouse"]["area"] == "farm_side" and lms["farmhouse"]["blocks"] == [[1, 0, 2, 2]], "farmhouse")
		check(lms["mine"]["area"] == "cliff" and lms["mine"]["blocks"] == [], f"mine off grid: {lms['mine']['blocks']}")
		check(lms["newspaper_mailbox"]["area"] == "road_verge" and lms["newspaper_mailbox"]["unlock_level"] == 7,
			"mailbox area/unlock")
		check(lms["truck"]["draw_anchor"] == "center" and lms["truck"]["replaces_items"] == [], "truck")
		# sprite anchors: registration point on the client tile's top corner
		tk, fh = lms["truck"], lms["farmhouse"]
		check(len(tk["client_registration"]) == 2 and fh["client_registration"] == fh["origin"], "registration tiles")
		check(landmark_anchor_offset({"footprint": [3, 2], "origin": [5, 5], "draw_anchor": "top_corner"}, 2.0) == (32.0, 80.0),
			"top-corner anchor offset = ((W-H)*16, (W+H)*8) * ppw")
		check(landmark_anchor_offset({"footprint": [1, 2], "origin": [7, 6], "draw_anchor": "center"}, 3.0) == (0.0, 0.0),
			"centred sprite: registration point on the footprint centre")
		check(lms["farmhouse"]["fallback_art"] == "farmhouse", "fallback art")
		inits = world["initial_objects"]
		check(len(inits) == 8 and all(o["item"] in catalog for o in inits), f"initial objects {len(inits)}")
		check(any(o["item"] == "wheat_field" and o["flip"] for o in inits), "mirrored seed object")
		check(wb.report["counts"]["initial_objects_offgrid_skipped"] == 1, "off-grid seed skipped")
		check(world["world_bounds"][0] < -3 and world["world_bounds"][1] < -3, "world bounds include off-grid content")
		check(any(s["kind"] == "river" for s in world["scenery"]), "river scenery from water zones")
		check(world["water_deco_zones"] == [{"id": "bank", "name": "Bank", "rect": [-3, 0, 2, 3], "enabled": True}],
			f"water deco zones: {world['water_deco_zones']}")
		check(validate_world({**world, "water_deco_zones": [{"id": "z", "rect": [0, 0, 0, 1]}]}) != [], "bad zone rejected")
		# validator negatives
		bad = json.loads(json.dumps(world))
		bad["regions"].append(dict(plots["main_01"], id="dup"))
		check(any("overlaps" in p for p in validate_world(bad)), "overlap detected")
		bad = json.loads(json.dumps(world))
		bad["landmarks"][0]["movable"] = True
		bad["ground"]["rows"][0] = bad["ground"]["rows"][0][:-1]
		pr = validate_world(bad)
		check(any("movable" in p for p in pr) and any("ground row" in p for p in pr), f"negatives: {pr}")
		bad = json.loads(json.dumps(world))
		bad["frame"] = "app"
		bad["sections"][0]["plots"].append("nope")
		pr = validate_world(bad)
		check(any("frame" in p for p in pr) and any("unknown plot" in p for p in pr), "frame/section negatives")
		# overrides
		links = {"fancy_statue": "decorations:Fancy statue", "gnome": "decorations:Gnome",
			"flower_bed": "decorations:Flower bed", "bench": "decorations:Bench"}
		doc, rep = build_overrides(client, catalog, links)
		it = doc["items"]
		check(it.get("fancy_statue", {}).get("change") == "axis_swap" and it["fancy_statue"]["footprint"] == [2, 1],
			f"axis swap {it.get('fancy_statue')}")
		check(it["fancy_statue"].get("unlock_level") == 31 and "unlock_level" in it["fancy_statue"]["changes"], "unlock fill")
		check(it.get("gnome", {}).get("change") == "status_only" and "unlock_level" not in it["gnome"], "status only")
		check("gnome" in doc["unlock_level_not_applied"], "level 1 is not a gate")
		check(it.get("flower_bed", {}).get("change") == "resize" and it["flower_bed"]["footprint"] == [2, 2], "resize")
		check(it.get("bench", {}).get("change") == "status_only", "provisional confirmed")
		check(not validate_overrides(doc, catalog), f"overrides valid: {validate_overrides(doc, catalog)}")
		# refuses the git work tree
		try:
			ensure_private(REPO_ROOT / "tmp_world", "x")
			check(False, "git work tree must be refused")
		except SystemExit:
			pass
	for f in fails:
		print("FAIL:", f)
	print(f"build_world self-test: {'PASS' if not fails else 'FAIL'} ({len(fails)} failures)")
	return 1 if fails else 0


def main(argv=None) -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--root", type=Path, default=DEFAULT_ROOT, help=f"private root (default {DEFAULT_ROOT})")
	ap.add_argument("--out", type=Path, default=None, help=f"output folder (default <root>/packs/{WORLD_DIR_NAME})")
	ap.add_argument("--client-version", default=None, help="client build folder under raw/apk_extracted (default newest)")
	ap.add_argument("--no-sprites", action="store_true", help="world.json + overrides only (no landmark rendering)")
	ap.add_argument("--sheet", action="store_true", help="also write <root>/review_sheets/landmarks_contact.png")
	ap.add_argument("--workers", type=int, default=min(4, os.cpu_count() or 1))
	ap.add_argument("--validate", type=Path, default=None, help="validate a world.json and exit")
	ap.add_argument("--self-test", action="store_true", help="run the built-in tests on synthetic fixtures and exit")
	args = ap.parse_args(argv)
	if args.self_test:
		return self_test()
	if args.validate:
		w = read_json(args.validate)
		probs = validate_world(w) if w is not None else ["unreadable JSON"]
		for p in probs:
			print("INVALID:", p)
		print(f"{args.validate}: {'valid' if not probs else f'{len(probs)} problems'}")
		return 1 if probs else 0
	return run(args)


if __name__ == "__main__":
	sys.exit(main())
