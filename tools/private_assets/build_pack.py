#!/usr/bin/env python3
"""Build the PRIVATE "hayday_original" asset pack from original Hay Day art the user has acquired.

PERSONAL USE ONLY. Every image this tool reads or writes is proprietary Supercell art. The user states that
Supercell support authorised personal use in this app on condition that nothing is redistributed. So:
  * the tool contains no art and never writes inside a git work tree (it refuses);
  * all output goes to the private root (default /root/hayday-sandbox-private-assets, or $HAYDAY_PRIVATE_ASSETS)
    and, with --install-dir, to the app's user pack folder (user://asset_packs/hayday_original);
  * nothing is uploaded anywhere. Never commit, zip for others, or share the output.

Inputs (all under <root>/raw, produced by fetch_fankit.py, fetch_wiki.py and extract_from_apk.py):
  fankit/index.json + files/        Supercell Fan Kit originals (marketing renders, no registration point)
  wiki/index.json, wiki_ru/...      Hay Day Fandom wiki uploads (EN / RU)
  apk_sprites/<build>/<sc>/...      exports rendered from a Supercell-signed client build, with registration point
  apk_extracted/<build>/assets/data + localization   the build's own CSV tables (export names, tile sizes, TIDs)

Pipeline:
  1. inventory   every file: size, mode, alpha, opaque bboxes (alpha>0, >8, >=160), baked-shadow statistics,
                 sha256, dHash + pHash (numpy DCT), provenance       -> mapping/inventory.json (cached by mtime)
  2. names       CamelCase split, "HayDay" / extensions / numbering stripped, plurals folded; level, mastery,
                 stage, year and fence/path piece suffixes become VARIANT tags of one item
  3. matching    client build: catalogue name == game text of the CSV row's TID (EN, else RU) -> exact;
                 internal row name / fuzzy (rapidfuzz) -> high/medium.  Fan Kit + wiki: exact normalised name,
                 wiki-recorded catalogue links, fuzzy; restricted by category compatibility (Fan Kit asset type,
                 wiki categories, CSV table) and aspect plausibility.  Tiers: exact/high -> auto, medium ->
                 review, below -> unmatched.  Decisions persist in mapping/mapping.json; confirmed/rejected
                 entries (and user decisions from <install-dir>/overrides.json) are never overridden.
  4. calibration client renders carry their registration point (= top corner of the footprint, 1 tile = 128x64
                 SC units) and scale, so anchor = origin + scale*((W-H)*32, (W+H)*16) with the game's own tile
                 size; no fitting.  For Fan Kit / wiki images the scale consistency is measured (against the
                 client renders of the same object and against trusted footprints); the report says whether a
                 common per-category scale exists, else per-item footprint fitting is used, flagged auto_anchor.
                 Overrides: mapping/calibration_overrides.json.          -> mapping/calibration_report.json
  5. variants    mastered / level / yearly skins -> "variants"; fences (pole/below/right/corner) and ditch-style
                 paths/water (16 pieces) -> "connections" masks 1=NE(-y) 2=SE(+x) 4=SW(+y) 8=NW(-x).
  6. output      packs/hayday_original/{pack.json, items/*.webp (<= 2 px per world px, WebP q92 with alpha),
                 thumbs/*.webp (<= 128 px), review.json + review/, hashes.json}; optional install (keeps the
                 user's overrides.json).
  7. coverage    mapping/coverage.json + dashboard/index.html (self-contained, thumbnails linked relatively).
  8. sheets      review_sheets/contact_*.png for eyeballing matches and anchors.

Usage:
  python3 tools/private_assets/build_pack.py                         # build into <root>/packs/hayday_original
  python3 tools/private_assets/build_pack.py --install-dir ~/.local/share/HaydaySandbox/asset_packs/hayday_original
  python3 tools/private_assets/build_pack.py --only-match            # inventory + matching + coverage, no images
  python3 tools/private_assets/build_pack.py --rebuild               # ignore the inventory cache, rewrite the pack
  python3 tools/private_assets/build_pack.py --report                # print the last coverage summary and exit

Requires Python 3.10+, Pillow (with WebP) and numpy; rapidfuzz is used when installed (difflib otherwise).
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import hashlib
import html
import io
import json
import math
import multiprocessing as mp
import os
import re
import shutil
import statistics
import sys
import time
import unicodedata
from pathlib import Path

try:
	import numpy as np
	from PIL import Image, ImageDraw, ImageOps
except ImportError:  # pragma: no cover
	sys.exit("Pillow and numpy are required: pip install pillow numpy")

try:
	from rapidfuzz import fuzz as _rf_fuzz
except ImportError:  # pragma: no cover - difflib fallback
	_rf_fuzz = None

Image.MAX_IMAGE_PIXELS = 200_000_000

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ROOT = Path(os.environ.get("HAYDAY_PRIVATE_ASSETS", "/root/hayday-sandbox-private-assets"))
PACK_ID = "hayday_original"
PACK_NAME = "Hay Day original art (private)"
LICENSE = "Supercell — personal use only, DO NOT REDISTRIBUTE"
TOOL_VERSION = "1.0"

HALF_W, HALF_H = 32.0, 16.0          # world px of half a tile (64 x 32 tiles)
SC_TILE_HALF_W, SC_TILE_HALF_H = 64.0, 32.0   # SC units of half a tile in client exports
MAX_PPW = 2.0                        # output pixels per world px (cap)
THUMB_MAX = 128
REVIEW_MAX_SIDE = 512
WEBP_QUALITY = 92
A_VIS = 8                            # alpha threshold for "visible"
A_SOLID = 160                        # alpha threshold for "solid object" (excludes soft baked shadows)
A_TRIM = 2                           # alpha threshold for trimming padding

PHASH_DUP = 12                       # <= : same appearance (duplicate)
PHASH_ALT = 22                       # >  : candidate for a genuinely different appearance (alternate) ...
HIST_ALT_MIN = 0.25                  # ... and colour-histogram distance above max(this, p95 of duplicate pairs)

DECOR = {"decoration", "seasonal", "furniture", "structures", "nature", "flowers", "water", "fence", "path",
	"obstacle"}
BUILDINGS = {"production", "farm_building", "animal_home", "structures"}
PLANTS = {"fruit_tree", "bush", "flowers", "nature"}
ALL_CATS = DECOR | BUILDINGS | PLANTS | {"field", "planning"}

FANKIT_TYPE_CATS = {
	"Buildings": BUILDINGS,
	"Decorations": DECOR,
	"Fences": {"fence", "flowers", "nature"},
	"Paths": {"path", "water"},
	"Flowers Plants and Trees": PLANTS | {"fence", "obstacle", "decoration", "seasonal"},
	"Farm Pass": DECOR | {"animal_home"},
	"Valley": DECOR,
	"Sanctuary": DECOR | {"animal_home"},
	"Characters": set(),          # only animal statues etc. (name check below)
	"Crops & Goods": {"field"},
	"Animal Accessories": set(),
	"Hay Day": set(),
}
# CSV tables of the client build -> compatible catalogue categories (unknown tables: any).
TABLE_CATS = {
	"processing_buildings": {"production"},
	"service_buildings": {"production", "structures", "farm_building"},
	"animal_habitats": {"animal_home"}, "pet_habitats": {"animal_home"}, "gatherer_habitats": {"animal_home"},
	"sanctuary_animal_habitats": {"animal_home", "structures", "decoration"},
	"fruit_trees": {"fruit_tree", "bush"},
	"fields": {"field"},
	"deco_fences": DECOR, "deco_ditches": DECOR, "decorations": DECOR, "modular_decorations": DECOR,
	"mapgame_decorations": DECOR, "farm_pass_road_decorations": DECOR, "neighborhood_objects": DECOR,
	"forests": {"obstacle", "nature"},
	"silos": {"farm_building"}, "warehouses": {"farm_building"}, "houses": {"farm_building"},
	"helper_house": {"farm_building"}, "roadside_shop": {"farm_building"}, "mailboxes": {"farm_building"},
	"eventboard": {"farm_building"}, "neighborhood_buildings": {"farm_building"}, "tackle_box": {"farm_building"},
	"mapgame_stand": {"farm_building"}, "farm_bridge": {"farm_building"}, "town_request_board": {"farm_building"},
	"mines": {"structures", "production", "farm_building"}, "gatherer_mines": {"structures", "production", "farm_building"},
	"lobster_pool": BUILDINGS, "duck_salon": BUILDINGS, "net_maker": BUILDINGS, "bait_maker": BUILDINGS,
}
# Tables that are rendered as the client's "level decoration" or are not player-placeable objects.
TABLE_SKIP = {"level_deco", "level_deco_beach", "tiles", "expansion_fences", "animals", "pets", "baby_pets",
	"sanctuary_animals", "circus_animals", "people", "passenger", "helpers", "builders", "photographer",
	"balloons", "construction_buildings", "customization_house", "customization_rss", "customization_truck",
	"boats", "cars", "train_parts", "circus_train_parts", "wheel_cars", "drasine", "personal_train",
	"angus", "lobsters", "ducks", "gatherers", "molluscs", "fishes", "creature_definitions", "scarecrows"}

# Client tables whose rows are things a player places on the farm (unmatched rows go to the review queue).
PLACEABLE_TABLES = {"decorations", "deco_fences", "deco_ditches", "modular_decorations", "processing_buildings",
	"animal_habitats", "pet_habitats", "gatherer_habitats", "sanctuary_animal_habitats", "fruit_trees"}

# Curated links for client rows that have no player-facing TID or whose catalogue name is generic.
# (table, internal row name) -> (catalogue id, confidence, evidence). medium = review queue, never automatic.
CURATED = {
	("houses", "Home building"): ("farmhouse", "high", "houses.csv holds exactly one row: the 4x4 farmhouse"),
	("helper_house", "Helper house"): ("helpers_house", "high", "helper_house.csv: the helpers' house"),
	("eventboard", "EventBoard"): ("event_board", "high", "eventboard.csv: the event board sign post"),
	("neighborhood_buildings", "NeighborhoodBuilding"): ("neighborhood_house", "high", "TID_NEIGHBORHOOD row"),
	("pet_habitats", "HorseHouse"): ("horse_stable", "high", "TID_HORSE_HOUSE (game text 'Stable'): the horse home"),
	("gatherer_habitats", "SquirrelTree"): ("squirrel_house", "high", "TID_SQUIRREL_TREE: the only squirrel habitat"),
	("mapgame_stand", "MapGameStand"): ("valley_board", "medium", "valley (map game) stand; name differs"),
	("farm_bridge", "FarmBridge"): ("leaderboard", "medium", "export boat_leaderboard; unverified link"),
	("forests", "rock_1x1_01"): ("small_rock", "medium", "1x1 obstacle rock; catalogue name is generic"),
	("forests", "rock_2x2_01"): ("rock_cluster", "medium", "2x2 obstacle rock; catalogue name is generic"),
	("forests", "fir_small_01"): ("small_decorative_tree_leaf_pine", "medium", "small obstacle pine"),
	("forests", "fir_big_01"): ("big_decorative_tree_leaf_pine", "medium", "big obstacle pine"),
	("forests", "bog_3x3_01"): ("pond_natural", "medium", "obstacle bog; catalogue says 2x2 pond"),
}
# Client exports whose idle frame bakes in a HUD bubble (upgrade arrow) that must be removed.
STRIP_OVERLAY_RE = re.compile(r"^(silo|shed)_\d+$")
# Top-level child instances that are HUD, not art (measured on 1.73.89: only silo_* / shed_* carry "UIUpgrade").
HUD_INSTANCE_RE = re.compile(r"^(UI[A-Z].*|silo_capacity)$")
# Client .sc files whose exports are map objects (unreferenced exports there are "object-like").
OBJECT_SC_RE = re.compile(r"^(buildings_new|decos\d\d.*|fruit_trees.*|nature_new|fishing_area_buildings_and_decos|"
	r"train_buildings|train_nature|whitehouse_skins|rss_skins|nh_object|seasonal_creatures|farmpass|placeholders)$")
PIECE_WORDS = {"corner", "pole", "mirrored", "straight", "staright", "end", "int", "cross", "crossroad", "crossroads",
	"left", "right", "top", "bottom", "up", "down", "below"}
MONTHS = {"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"}


# ------------------------------------------------------------------------------------------------- utilities
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
		sys.exit(f"refusing to write {what} inside a git work tree ({wt or REPO_ROOT}): proprietary art must stay private")
	return p


def read_json(p: Path, default=None):
	try:
		with open(p, encoding="utf-8") as f:
			return json.load(f)
	except (OSError, ValueError):
		return default


def write_json(p: Path, data, indent: int | None = 1) -> None:
	p.parent.mkdir(parents=True, exist_ok=True)
	tmp = p.with_name(p.name + ".tmp")
	with open(tmp, "w", encoding="utf-8") as f:
		json.dump(data, f, ensure_ascii=False, indent=indent, sort_keys=False)
	os.replace(tmp, p)


def sha256_file(p: Path) -> str:
	h = hashlib.sha256()
	with open(p, "rb") as f:
		for chunk in iter(lambda: f.read(1 << 20), b""):
			h.update(chunk)
	return h.hexdigest()


def slug(s: str, n: int = 48) -> str:
	s = unicodedata.normalize("NFKD", s)
	s = re.sub(r"[^A-Za-z0-9]+", "_", s.encode("ascii", "ignore").decode()).strip("_").lower()
	return (s[:n] or "x").strip("_") or "x"


def short_hash(s: str, n: int = 8) -> str:
	return hashlib.sha1(s.encode("utf-8")).hexdigest()[:n]


def ratio(a: str, b: str) -> float:
	if _rf_fuzz is not None:
		return float(_rf_fuzz.ratio(a, b))
	import difflib
	return 100.0 * difflib.SequenceMatcher(None, a, b).ratio()


def token_sort_ratio(a: str, b: str) -> float:
	return ratio(" ".join(sorted(a.split())), " ".join(sorted(b.split())))


def hamming(a: str | None, b: str | None) -> int:
	if not a or not b:
		return 64
	return (int(a, 16) ^ int(b, 16)).bit_count()


def img_distance(a: dict, b: dict) -> int:
	"""Mirror-invariant pHash distance (wiki/Fan Kit images are often the flipped orientation)."""
	return min(hamming(a.get("phash"), b.get("phash")), hamming(a.get("phash_m"), b.get("phash")))


def hist_distance(a: dict, b: dict) -> float:
	"""1 - histogram intersection of 64-bin RGB histograms of solid pixels (mirror/crop invariant)."""
	ha, hb = a.get("hist"), b.get("hist")
	if not ha or not hb:
		return 1.0
	return 1.0 - sum(min(x, y) for x, y in zip(ha, hb)) / 1000.0


def pct(vals, q):
	if not vals:
		return None
	return float(np.percentile(np.asarray(vals, dtype=float), q))


def robust(vals):
	vals = [v for v in vals if v is not None and math.isfinite(v)]
	if not vals:
		return {"n": 0}
	med = statistics.median(vals)
	q1, q3 = pct(vals, 25), pct(vals, 75)
	return {"n": len(vals), "median": round(med, 4), "q1": round(q1, 4), "q3": round(q3, 4),
		"iqr": round(q3 - q1, 4), "rel_iqr": round((q3 - q1) / med, 4) if med else None,
		"min": round(min(vals), 4), "max": round(max(vals), 4)}


# ------------------------------------------------------------------------------------------------- names
_CAMEL1 = re.compile(r"(?<=[a-z])(?=[A-Z])")
_CAMEL2 = re.compile(r"(?<=[A-Z])(?=[A-Z][a-z])")
_DIGIT = re.compile(r"(?<=[A-Za-z])(?=\d)|(?<=\d)(?=[A-Za-z])")


def _fold_latin(s: str) -> str:
	out = []
	for ch in unicodedata.normalize("NFKD", s):
		if unicodedata.combining(ch) and out and out[-1].isascii():
			continue
		out.append(ch)
	return unicodedata.normalize("NFKC", "".join(out))


def singular(t: str) -> str:
	if len(t) <= 3 or t.isdigit():
		return t
	if t.endswith("ies") and len(t) > 4:
		return t[:-3] + "y"
	if t.endswith(("sses", "shes", "ches", "xes", "zes")):
		return t[:-2]
	if t.endswith("s") and not t.endswith(("ss", "us", "is", "os")):
		return t[:-1]
	return t


def tokens_of(s: str) -> list[str]:
	s = unicodedata.normalize("NFKC", str(s))
	s = re.sub(r"\.(png|jpe?g|gif|webp|svg|bmp)$", "", s.strip(), flags=re.I)
	s = re.sub(r"^(file|файл|image)\s*:", "", s, flags=re.I)
	s = _CAMEL2.sub(" ", _CAMEL1.sub(" ", s))
	s = _DIGIT.sub(" ", s)
	s = _fold_latin(s).lower().replace("ё", "е").replace("&", " and ")
	s = re.sub(r"[’'`´]", "", s)
	toks = re.findall(r"[a-z0-9]+|[а-я]+", s)
	# "Hay Day" / "HayDay" / "hayday" prefixes and fan kit promo prefixes ("FP", "Oct2026")
	out = []
	i = 0
	while i < len(toks):
		t = toks[i]
		if t == "hayday" or (t == "hay" and i + 1 < len(toks) and toks[i + 1] == "day" and not out):
			i += 2 if t == "hay" else 1
			continue
		out.append(t)
		i += 1
	while out and (out[0] in ("fp",) or (out[0] in MONTHS and len(out) > 1 and re.fullmatch(r"\d{2,4}", out[1]))):
		out = out[2:] if out[0] in MONTHS else out[1:]
	return out


def norm_key(tokens: list[str]) -> str:
	return " ".join(singular(t) for t in tokens if t not in ("the", "a", "an"))


def split_variant(tokens: list[str]) -> tuple[list[str], list[str]]:
	"""Strip trailing level / mastery / stage / year / numbering / piece tokens -> (base tokens, tags)."""
	toks = list(tokens)
	tags: list[str] = []
	changed = True
	while changed and len(toks) > 1:
		changed = False
		last = toks[-1]
		if len(toks) >= 3 and toks[-2] in ("lvl", "level", "lv", "l") and last.isdigit():
			tags.insert(0, f"lvl_{int(last)}")
			toks = toks[:-2]
		elif last in ("mastered", "mastery", "master"):
			tags.insert(0, "mastered")
			toks = toks[:-1]
		elif len(toks) >= 3 and toks[-2] in ("stage", "phase", "step") and last.isdigit():
			tags.insert(0, f"stage_{int(last)}")
			toks = toks[:-2]
		elif re.fullmatch(r"(19|20)\d\d", last):
			tags.insert(0, f"y{last}")
			toks = toks[:-1]
		elif last.isdigit() and len(last) <= 2:
			tags.insert(0, f"n{int(last)}")
			toks = toks[:-1]
		elif last in PIECE_WORDS:
			tags.insert(0, f"piece_{last}")
			toks = toks[:-1]
		elif last in ("new", "old", "copy", "final", "v"):
			tags.insert(0, last)
			toks = toks[:-1]
		else:
			break
		changed = True
	return toks, tags


def variant_id_from_tags(tags: list[str]) -> str:
	tags = [t for t in tags if not t.startswith("piece_")]
	return "_".join(tags) if tags else ""


# ------------------------------------------------------------------------------------------------- catalogue
def load_catalog() -> tuple[list[dict], dict]:
	items = []
	for f in sorted((REPO_ROOT / "data" / "items").glob("*.json")):
		if f.name == "categories.json":
			continue
		d = read_json(f, {})
		for it in (d.get("items", []) if isinstance(d, dict) else d):
			fp = it.get("footprint")
			trusted = isinstance(fp, list) and len(fp) == 2 and it.get("footprint_status") in ("confirmed", "community", "original")
			if not (isinstance(fp, list) and len(fp) == 2):
				fp = it.get("provisional_footprint") or [1, 1]
			conn = it.get("connect") or {}
			items.append({
				"id": it["id"], "name": it.get("name", it["id"]), "category": it.get("category", "decoration"),
				"fp": (max(1, int(fp[0])), max(1, int(fp[1]))), "fp_trusted": bool(trusted),
				"fp_status": it.get("footprint_status") if it.get("footprint") else "unknown",
				"art_key": it.get("art", it["id"]), "aliases": list(it.get("aliases", [])),
				"connect_style": conn.get("style", ""), "connect_group": conn.get("group", ""),
				"layer": it.get("layer", "object"), "season": it.get("season", ""), "file": f.name,
			})
	cats = read_json(REPO_ROOT / "data" / "items" / "categories.json", {}).get("categories", [])
	return items, {c["id"]: c for c in cats}


class CatalogIndex:
	def __init__(self, items: list[dict]):
		self.items = items
		self.by_id = {it["id"]: it for it in items}
		self.exact: dict[str, list[str]] = collections.defaultdict(list)
		self.sorted_key: dict[str, list[str]] = collections.defaultdict(list)
		self.keys: list[tuple[str, str]] = []   # (key, item id) for fuzzy matching
		for it in items:
			names = [it["name"], it["id"].replace("_", " ")] + it["aliases"]
			# "Large spruce (autumn)" also as "large spruce autumn"; "(collection prize)" dropped as well
			base = re.sub(r"\((collection prize|decoration|event|deco)\)", "", it["name"], flags=re.I)
			names.append(base)
			seen = set()
			for n in names:
				k = norm_key(tokens_of(n))
				if not k or k in seen:
					continue
				seen.add(k)
				self.exact[k].append(it["id"])
				self.sorted_key[" ".join(sorted(k.split()))].append(it["id"])
				self.keys.append((k, it["id"]))
		for d in (self.exact, self.sorted_key):
			for k in d:
				d[k] = sorted(set(d[k]), key=d[k].index)

	def lookup(self, key: str, allowed: set | None = None) -> tuple[list[str], str]:
		ids = self.exact.get(key, [])
		how = "exact"
		if not ids:
			ids = self.sorted_key.get(" ".join(sorted(key.split())), [])
			how = "token_order"
		if allowed is not None:
			ids = [i for i in ids if self.by_id[i]["category"] in allowed]
		return ids, how

	def fuzzy(self, key: str, allowed: set | None = None, limit: int = 5) -> list[tuple[str, float]]:
		if not key:
			return []
		best: dict[str, float] = {}
		kl = len(key)
		for k, iid in self.keys:
			if allowed is not None and self.by_id[iid]["category"] not in allowed:
				continue
			if abs(len(k) - kl) > max(6, kl * 0.5):
				continue
			s = max(ratio(key, k), token_sort_ratio(key, k))
			if s > best.get(iid, 0):
				best[iid] = s
		return sorted(best.items(), key=lambda x: -x[1])[:limit]


# ------------------------------------------------------------------------------------------------- game data
def _version_tuple(v: str):
	return tuple(int(x) for x in re.findall(r"\d+", v)) or (0,)


def load_game_data(root: Path) -> dict:
	"""CSV tables + texts of the newest build that has rendered sprites. {} when unavailable."""
	sprites_root = root / "raw" / "apk_sprites"
	versions = sorted([p.name for p in sprites_root.iterdir() if p.is_dir()], key=_version_tuple) if sprites_root.is_dir() else []
	for ver in reversed(versions):
		base = root / "raw" / "apk_extracted" / ver / "assets"
		data_dir, loc_dir = base / "data", base / "localization"
		if not data_dir.is_dir():
			continue
		texts_en, texts_ru = {}, {}
		for name, target in (("texts.csv", texts_en), ("texts_patch.csv", texts_en), ("ru.csv", texts_ru)):
			for d in (loc_dir, data_dir):
				p = d / name
				if p.exists():
					with open(p, encoding="utf-8", errors="replace") as f:
						for row in csv.reader(f):
							if len(row) >= 2 and row[0].startswith("TID_") and row[1]:
								target[row[0]] = row[1].replace("<TODO:>", "").strip()
					break
		tables = {}
		for p in sorted(data_dir.glob("*.csv")):
			try:
				with open(p, encoding="utf-8", errors="replace") as f:
					rows = list(csv.reader(f))
			except OSError:
				continue
			if len(rows) < 3:
				continue
			hdr = rows[0]
			entries, cur = [], None
			for r in rows[2:]:
				d = dict(zip(hdr, r))
				if d.get("Name"):
					cur = {"Name": d["Name"], "rows": [d]}
					entries.append(cur)
				elif cur is not None:
					cur["rows"].append(d)
			tables[p.stem] = {"header": hdr, "entries": entries}
		return {"version": ver, "texts_en": texts_en, "texts_ru": texts_ru, "tables": tables, "data_dir": str(data_dir)}
	return {}


DITCH_MASKS = {"ExportName": 0, "DitchN": 1, "DitchE": 2, "DitchS": 4, "DitchW": 8, "DitchNS": 5, "DitchWE": 10,
	"DitchNE": 3, "DitchNW": 9, "DitchSE": 6, "DitchSW": 12, "DitchNWE": 11, "DitchSWE": 14, "DitchWNS": 13,
	"DitchENS": 7, "DitchNSWE": 15}


def game_objects(gd: dict) -> list[dict]:
	"""Placeable client objects: table, internal name, TID texts, sprite exports, game tile size, pieces."""
	out = []
	if not gd:
		return out
	pieces = {}
	ap = gd["tables"].get("animal_habitat_pieces")
	if ap:
		for e in ap["entries"]:
			r = e["rows"][0]
			pieces[e["Name"]] = {"sc": Path(r.get("FileName", "")).stem, "export": r.get("ExportName", "")}
	for tname, t in gd["tables"].items():
		hdr = t["header"]
		if tname in TABLE_SKIP or "ExportName" not in hdr or "FileName" not in hdr or "TileWidth" not in hdr:
			continue
		for idx, e in enumerate(t["entries"]):
			r0 = e["rows"][0]
			exp = r0.get("ExportName", "")
			if not exp or "<" in exp:
				continue
			try:
				w, h = int(r0.get("TileWidth") or 0), int(r0.get("TileHeight") or 0)
			except ValueError:
				continue
			if w <= 0 or h <= 0:
				continue
			tid = r0.get("TID", "")
			obj = {"key": f"{tname}:{e['Name']}", "table": tname, "name": e["Name"], "row": idx, "tid": tid,
				"en": gd["texts_en"].get(tid, "") if tid else "", "ru": gd["texts_ru"].get(tid, "") if tid else "",
				"sc": Path(r0.get("FileName", "")).stem, "export": exp, "fp": (w, h),
				"mastered": r0.get("ExportNameMastered", ""), "mirror": r0.get("ExportNameMirror", ""),
				"fence": None, "ditch": None, "levels": [], "parts": [], "pieces": [],
				"placeholder_art": Path(r0.get("FileName", "")).stem == "placeholders"}
			if r0.get("FenceBelowExportName"):
				obj["fence"] = {"pole": exp, "below": r0.get("FenceBelowExportName", ""),
					"right": r0.get("FenceRightExportName", ""), "corner": r0.get("FenceCornerExportName", "")}
			if r0.get("DitchN"):
				obj["ditch"] = {m: r0.get(col, "") for col, m in DITCH_MASKS.items()}
			for col in ("ExportNameMiddle", "ExportNameTop"):
				if r0.get(col):
					obj["parts"].append(r0[col])
			# level rows: continuation rows with their own ExportName
			seen = [exp]
			for li, r in enumerate(e["rows"][1:], start=2):
				le = r.get("ExportName", "")
				if le and le not in seen and "<" not in le:
					seen.append(le)
					obj["levels"].append({"level": li, "export": le,
						"parts": [r[c] for c in ("ExportNameMiddle", "ExportNameTop") if r.get(c)]})
			if tname == "animal_habitats" and pieces:
				for r in e["rows"]:
					pn = r.get("Piece", "")
					if pn and pn in pieces:
						obj["pieces"].append({"export": pieces[pn]["export"], "sc": pieces[pn]["sc"] or obj["sc"],
							"x": int(r.get("PieceTileX") or 0), "y": int(r.get("PieceTileY") or 0),
							"mirrored": str(r.get("PieceMirrored", "")).upper() == "TRUE"})
			out.append(obj)
	return out


# ------------------------------------------------------------------------------------------------- discovery
def discover(root: Path) -> tuple[list[dict], dict]:
	"""All acquired files with provenance (no pixel statistics yet)."""
	recs: list[dict] = []
	meta: dict = {"sources": {}}
	raw = root / "raw"
	# Fan Kit
	fk = read_json(raw / "fankit" / "index.json")
	if fk:
		n = 0
		for a in fk.get("assets", []):
			if a.get("status") != "ok" or not a.get("local_path"):
				continue
			p = raw / "fankit" / a["local_path"]
			if not p.exists():
				continue
			recs.append({"key": f"fankit:{a['id']}", "source": "fankit", "path": str(p), "title": a.get("title", ""),
				"prov": {"source": "Supercell Fan Kit", "id": a["id"], "title": a.get("title"), "url": a.get("url"),
					"types": a.get("types") or [], "characters": a.get("characters") or [],
					"created": a.get("created"), "fetched_at": fk.get("fetched_at")}})
			n += 1
		meta["sources"]["fankit"] = {"fetched_at": fk.get("fetched_at"), "files_found": fk.get("api_total"),
			"listed": fk.get("listed"), "acquired": n, "failed": fk.get("failed")}
	# Wikis
	for src, sub in (("wiki_en", "wiki"), ("wiki_ru", "wiki_ru")):
		wi = read_json(raw / sub / "index.json")
		if not wi:
			continue
		n = 0
		for f in wi.get("files", []):
			p = Path(f.get("local_path") or (root / f.get("rel_path", "")))
			if not p.exists():
				continue
			recs.append({"key": f"{src}:{f['title']}", "source": src, "path": str(p), "title": f["title"],
				"prov": {"source": f"Hay Day Wiki ({wi.get('wiki')})", "title": f["title"], "url": f.get("url"),
					"description_url": f.get("description_url"), "categories": f.get("categories") or [],
					"timestamp": f.get("timestamp"), "fetched_at": wi.get("fetched_at"),
					"catalog_ids": f.get("catalog_ids") or [], "catalog_ids_page_title": f.get("catalog_ids_page_title") or [],
					"page_catalog_ids": f.get("page_catalog_ids") or [], "duplicate_of": f.get("duplicate_of"),
					"verification": f.get("verification")}})
			n += 1
		st = wi.get("stats", {}) or {}
		disc = wi.get("discovery", {}) or {}
		found = st.get("discovered") or (len(wi.get("files", [])) + len(wi.get("skipped", [])))
		meta["sources"][src] = {"fetched_at": wi.get("fetched_at"), "files_found": found, "acquired": n,
			"skipped": len(wi.get("skipped", [])), "failed": len(read_json(raw / sub / "failed.json", []) or [])}
	# Client builds
	sp = raw / "apk_sprites"
	if sp.is_dir():
		for vdir in sorted([p for p in sp.iterdir() if p.is_dir()], key=lambda p: _version_tuple(p.name)):
			rep = read_json(vdir / "extract_report.json", {}) or {}
			n = exports = 0
			for scdir in sorted([p for p in vdir.iterdir() if p.is_dir()]):
				idx = read_json(scdir / "index.json", {}) or {}
				exports += len(idx)
				for ename, e in idx.items():
					if not isinstance(e, dict) or not e.get("file"):
						continue
					p = scdir / e["file"]
					if not p.exists():
						continue
					recs.append({"key": f"apk:{vdir.name}/{scdir.name}/{ename}", "source": "apk", "path": str(p),
						"title": ename, "prov": {"source": f"Hay Day client {vdir.name} (Supercell-signed)",
							"build": vdir.name, "sc": scdir.name, "export": ename, "fetched_at": rep.get("finished") or rep.get("started")},
						"apk": {"build": vdir.name, "sc": scdir.name, "export": ename, "origin": e.get("origin"),
							"scale": e.get("scale"), "ppw": e.get("pixels_per_world_px"), "frames": e.get("frames"),
							"frame_label": e.get("frame_label"), "kind": e.get("kind"), "warnings": e.get("warnings") or []}})
					n += 1
			meta["sources"][f"apk_{vdir.name}"] = {"fetched_at": rep.get("finished") or rep.get("started"),
				"files_found": exports, "acquired": n, "input": Path(str(rep.get("input", ""))).name}
	return recs, meta


# ------------------------------------------------------------------------------------------------- inventory
_N = 32
_DCT = np.array([[(math.sqrt(1 / _N) if k == 0 else math.sqrt(2 / _N)) * math.cos(math.pi * (2 * n + 1) * k / (2 * _N))
	for n in range(_N)] for k in range(_N)])


def _bits_hex(bits) -> str:
	v = 0
	for b in bits:
		v = (v << 1) | int(bool(b))
	return f"{v:016x}"


def phash_dhash(gray: Image.Image) -> tuple[str, str]:
	"""64-bit pHash (8x8 low DCT of a 32x32 Lanczos thumbnail vs median) and 64-bit dHash, as hex."""
	x = np.asarray(gray.resize((_N, _N), Image.Resampling.LANCZOS), dtype=np.float64)
	d = _DCT @ x @ _DCT.T
	low = d[:8, :8].flatten()
	ph = _bits_hex(low > np.median(low))
	y = np.asarray(gray.resize((9, 8), Image.Resampling.LANCZOS), dtype=np.int16)
	dh = _bits_hex((y[:, 1:] > y[:, :-1]).flatten())
	return ph, dh


def _bbox(mask) -> list[int] | None:
	rows = np.flatnonzero(mask.any(axis=1))
	if rows.size == 0:
		return None
	cols = np.flatnonzero(mask.any(axis=0))
	return [int(cols[0]), int(rows[0]), int(cols[-1]) + 1, int(rows[-1]) + 1]


def load_rgba(path: str) -> Image.Image:
	im = Image.open(path)
	try:
		im.seek(0)
	except EOFError:
		pass
	return im.convert("RGBA")


def inspect_image(args) -> tuple[str, dict]:
	key, path = args
	try:
		st = os.stat(path)
		sha = sha256_file(Path(path))
		im = Image.open(path)
		fmt, mode, frames = im.format, im.mode, getattr(im, "n_frames", 1)
		alpha_channel = mode in ("RGBA", "LA", "PA", "RGBa") or "transparency" in im.info
		rgba = load_rgba(path)
		arr = np.asarray(rgba)
		a = arr[..., 3]
		vis = a > A_VIS
		nvis = int(vis.sum())
		solid = a >= A_SOLID
		semi = vis & ~solid
		rgb = arr[..., :3].astype(np.float32)
		lum = rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114
		shadow = semi & (lum < 90)
		bb, bb0, bbs, bsh = _bbox(vis), _bbox(a > 0), _bbox(solid), _bbox(shadow)
		crop = rgba.crop(bb) if bb else rgba
		bg = Image.new("RGBA", crop.size, (128, 128, 128, 255))
		bg.alpha_composite(crop)
		gray = bg.convert("L")
		ph, dh = phash_dhash(gray)
		ph_m, _ = phash_dhash(ImageOps.mirror(gray))
		sol = arr[a >= 128][:, :3] // 64
		hist = np.bincount((sol[:, 0].astype(np.int32) * 16 + sol[:, 1] * 4 + sol[:, 2]), minlength=64) if sol.size else np.zeros(64)
		hist = [int(round(1000 * v / max(1, hist.sum()))) for v in hist]
		info = {"stat": [st.st_size, st.st_mtime_ns], "sha256": sha, "format": fmt, "mode": mode, "frames": frames,
			"w": rgba.width, "h": rgba.height, "alpha_channel": bool(alpha_channel), "alpha_used": bool((a < 255).any()),
			"bbox": bb, "bbox0": bb0, "bbox_solid": bbs, "visible_frac": round(nvis / a.size, 4),
			"semi_frac": round(float(semi.sum()) / max(1, nvis), 4),
			"shadow_frac": round(float(shadow.sum()) / max(1, nvis), 4), "bbox_shadow": bsh,
			"shadow_below_px": (bsh[3] - bbs[3]) if (bsh and bbs) else 0, "phash": ph, "phash_m": ph_m, "dhash": dh, "hist": hist}
		return key, info
	except Exception as ex:  # noqa: BLE001 - one bad file must not stop the run
		return key, {"error": f"{type(ex).__name__}: {ex}"}


def run_inventory(recs: list[dict], cache_path: Path, rebuild: bool, workers: int) -> dict:
	cache = {} if rebuild else (read_json(cache_path, {}) or {}).get("records", {})
	todo = []
	inv = {}
	for r in recs:
		c = cache.get(r["key"])
		try:
			st = os.stat(r["path"])
		except OSError:
			continue
		if c and c.get("img", {}).get("stat") == [st.st_size, st.st_mtime_ns] and c.get("path") == r["path"] \
				and "hist" in c.get("img", {}):
			r["img"] = c["img"]
		else:
			todo.append((r["key"], r["path"]))
		inv[r["key"]] = r
	log(f"inventory: {len(recs)} files, {len(recs) - len(todo)} cached, {len(todo)} to inspect ({workers} workers)")
	t0 = time.time()
	if todo:
		with mp.Pool(workers) as pool:
			for i, (key, info) in enumerate(pool.imap_unordered(inspect_image, todo, chunksize=16), 1):
				inv[key]["img"] = info
				if i % 2000 == 0:
					log(f"  inspected {i}/{len(todo)} ({time.time() - t0:.0f}s)")
	log(f"inventory done in {time.time() - t0:.0f}s")
	return inv


# ------------------------------------------------------------------------------------------------- matching
def allowed_for_record(r: dict) -> set | None:
	if r["source"] == "fankit":
		types = r["prov"].get("types") or []
		if not types:
			return set(DECOR) | {"animal_home"}   # untagged: decorations (measured), plus emotes filtered elsewhere
		cats = set()
		for t in types:
			cats |= FANKIT_TYPE_CATS.get(t, set())
		return cats
	if r["source"].startswith("wiki"):
		cats_txt = " ".join(r["prov"].get("categories") or []).lower()
		cats = set()
		if re.search(r"deco|украш|декор", cats_txt):
			cats |= DECOR
		if re.search(r"build|здани|постро|производ", cats_txt):
			cats |= BUILDINGS
		if re.search(r"tree|bush|plant|flower|дерев|куст|цвет|растен", cats_txt):
			cats |= PLANTS | {"fence", "decoration", "seasonal"}
		if re.search(r"fence|забор|огра", cats_txt):
			cats |= {"fence", "flowers", "nature"}
		if re.search(r"path|дорож|тропин|плитк", cats_txt):
			cats |= {"path", "water"}
		if re.search(r"animal|habitat|живот|дом", cats_txt):
			cats |= {"animal_home"}
		return cats or None
	return None


def plausible_aspect(img: dict, item: dict, aspect_ranges: dict) -> bool:
	bb = img.get("bbox_solid") or img.get("bbox")
	if not bb:
		return False
	ar = (bb[2] - bb[0]) / max(1, bb[3] - bb[1])
	rng = aspect_ranges.get(item["category"])
	if not rng:
		return 0.15 <= ar <= 8.0
	return rng[0] * 0.75 <= ar <= rng[1] * 1.33


def match_game_objects(objs: list[dict], cat: CatalogIndex) -> dict:
	"""catalogue id -> {'primary': obj, 'others': [obj...], 'confidence', 'method'}; plus review/unmatched lists."""
	links: dict[str, list] = collections.defaultdict(list)   # item id -> [(obj, conf, method)]
	obj_status = {}
	for o in objs:
		if o["placeholder_art"]:
			obj_status[o["key"]] = ("skip", None, "none", "game_placeholder_art", "row uses the client's placeholder art")
			continue
		allowed = TABLE_CATS.get(o["table"])
		cur = CURATED.get((o["table"], o["name"]))
		if cur:
			iid, conf, note = cur
			if iid in cat.by_id:
				if conf in ("exact", "high"):
					links[iid].append((o, conf, "game_curated"))
					obj_status[o["key"]] = ("auto", iid, conf, "game_curated", note)
				else:
					obj_status[o["key"]] = ("review", iid, conf, "game_curated", note)
				continue
		found = None
		for txt, method in ((o["en"], "game_text_en"), (o["ru"], "game_text_ru")):
			if not txt:
				continue
			key = norm_key(tokens_of(txt))
			ids, how = cat.lookup(key, allowed)
			if ids:
				conf = "exact" if how == "exact" else "high"
				found = (ids, conf, method if how == "exact" else method + "_token_order")
				break
			ids_any, how2 = cat.lookup(key, None)
			if ids_any:
				found = (ids_any, "medium", method + "_category_mismatch")
				break
		if not found:
			key = norm_key(tokens_of(o["name"]))
			ids, how = cat.lookup(key, allowed)
			if ids:
				found = (ids, "high", "game_internal_name")
		if found:
			ids, conf, method = found
			# several catalogue items share the key: prefer equal footprint, then first
			if len(ids) > 1:
				eq = [i for i in ids if tuple(cat.by_id[i]["fp"]) in (o["fp"], o["fp"][::-1])]
				ids = eq or ids
			iid = ids[0]
			if conf == "medium":
				obj_status[o["key"]] = ("review", iid, conf, method, "game text matches a catalogue item of another category")
			else:
				links[iid].append((o, conf, method))
				obj_status[o["key"]] = ("auto", iid, conf, method, "")
		else:
			obj_status[o["key"]] = None
	# fuzzy pass for catalogue items still without a link (typos such as "Hithing post")
	linked_objs = {o["key"] for v in links.values() for o, _, _ in v}
	pending = [o for o in objs if obj_status.get(o["key"]) is None and not o["placeholder_art"]]
	pend_keys = []
	for o in pending:
		for txt in (o["en"], o["ru"], o["name"]):
			if txt:
				pend_keys.append((norm_key(tokens_of(txt)), o))
	for it in cat.items:
		if it["id"] in links or it["category"] == "planning":
			continue
		k = norm_key(tokens_of(it["name"]))
		scored = []
		for pk, o in pend_keys:
			allowed = TABLE_CATS.get(o["table"])
			if allowed is not None and it["category"] not in allowed:
				continue
			if abs(len(pk) - len(k)) > max(5, len(k) * 0.4):
				continue
			s = max(ratio(k, pk), token_sort_ratio(k, pk))
			if s >= 82:
				scored.append((s, o))
		if not scored:
			continue
		scored.sort(key=lambda x: -x[0])
		s, o = scored[0]
		second = next((x[0] for x in scored[1:] if x[1]["key"] != o["key"]), 0)
		if o["key"] in linked_objs:
			continue
		if s >= 92 and s - second >= 3:
			links[it["id"]].append((o, "high", "game_text_fuzzy"))
			obj_status[o["key"]] = ("auto", it["id"], "high", "game_text_fuzzy", f"score {s:.0f}")
			linked_objs.add(o["key"])
		elif obj_status.get(o["key"]) is None:
			obj_status[o["key"]] = ("review", it["id"], "medium", "game_text_fuzzy", f"score {s:.0f}")
	result = {}
	for iid, lst in links.items():
		it = cat.by_id[iid]

		def rank(x):
			o, conf, _ = x
			conn_table = o["table"] in ("deco_fences", "deco_ditches")
			table_pref = 0 if bool(it["connect_style"]) == conn_table else 1
			return (0 if conf == "exact" else 1, table_pref, 0 if o["fp"] in (it["fp"], it["fp"][::-1]) else 1,
				1 if re.search(r"_?20\d\d$", o["name"]) else 0, o["row"])
		lst.sort(key=rank)
		prim = lst[0][0]
		result[iid] = {"primary": prim, "confidence": lst[0][1], "method": lst[0][2],
			"others": [x[0] for x in lst[1:] if x[0]["table"] == prim["table"]],
			"other_tables": [x[0] for x in lst[1:] if x[0]["table"] != prim["table"]]}
	return {"links": result, "obj_status": obj_status}


def variant_name_from(base_obj: dict, other: dict) -> str:
	bt = set(tokens_of(base_obj["name"]))
	extra = [t for t in tokens_of(other["name"]) if t not in bt]
	if extra:
		return slug("_".join(extra), 24)
	bt = set(re.split(r"[_\W]+", base_obj["export"].lower()))
	extra = [t for t in re.split(r"[_\W]+", other["export"].lower()) if t and t not in bt]
	return slug("_".join(extra) or other["export"], 24)


def match_named_record(r: dict, cat: CatalogIndex, aspect_ranges: dict) -> dict:
	"""Fan Kit / wiki image -> decision dict (status, item_id, confidence, method, variant, suggestions)."""
	img = r.get("img") or {}
	if img.get("error"):
		return {"status": "unmatched", "role": "unreadable", "reason": img["error"]}
	if r["source"] == "fankit":
		types = r["prov"].get("types") or []
		if img.get("frames", 1) > 1:
			return {"status": "unmatched", "role": "not_object", "reason": "animated image (emote/effect)"}
		if types and all(t in ("Crops & Goods", "Animal Accessories", "Hay Day") for t in types):
			return {"status": "unmatched", "role": "not_object", "reason": f"fan kit type {types}"}
	if r["source"].startswith("wiki") and r["prov"].get("duplicate_of"):
		return {"status": "unmatched", "role": "duplicate_upload", "reason": f"duplicate of {r['prov']['duplicate_of']}"}
	if not img.get("alpha_used") or img.get("visible_frac", 1) >= 0.95:
		return {"status": "unmatched", "role": "opaque", "reason": "no (or only edge) transparency: screenshot/card, unusable as a map sprite"}
	toks = tokens_of(r["title"])
	base, tags = split_variant(toks)
	allowed = allowed_for_record(r)
	char_only = r["source"] == "fankit" and set(r["prov"].get("types") or []) == {"Characters"}
	cands: list[tuple[str, str, str, float]] = []   # (item, conf, method, score)
	for key, vtags in ((norm_key(toks), []), (norm_key(base), tags)):
		if not key:
			continue
		ids, how = cat.lookup(key, allowed)
		for i in ids:
			cands.append((i, "exact" if how == "exact" else "high", f"name_{how}", 100.0))
		if ids:
			if vtags:
				tags = vtags
			else:
				tags = []
			break
	if r["source"].startswith("wiki"):
		pv = r["prov"]
		for i in pv.get("catalog_ids") or []:
			if i in cat.by_id:
				cands.append((i, "exact", "wiki_name_link", 100.0))
		for i in pv.get("catalog_ids_page_title") or []:
			if i in cat.by_id:
				conf = "medium" if cat.by_id[i]["category"] == "obstacle" else "high"
				cands.append((i, conf, "wiki_page_title_link", 95.0))
		for i in pv.get("page_catalog_ids") or []:
			if i in cat.by_id:
				cands.append((i, "medium", "wiki_lead_image_of_cited_page", 80.0))
	if not cands:
		for i, s in cat.fuzzy(norm_key(base) or norm_key(toks), allowed):
			if s >= 94:
				cands.append((i, "high", "fuzzy", s))
			elif s >= 85:
				cands.append((i, "medium", "fuzzy", s))
			if len(cands) >= 3:
				break
	if char_only:
		cands = [c for c in cands if re.search(r"statue|figure|gnome|sculpt", cat.by_id[c[0]]["name"], re.I)]
	if allowed is not None:
		cands = [c for c in cands if cat.by_id[c[0]]["category"] in allowed or c[2].startswith("wiki_")]
	if not cands:
		sugg = [i for i, s in cat.fuzzy(norm_key(base) or norm_key(toks), allowed, 3) if s >= 70]
		return {"status": "unmatched", "role": "no_match", "suggestions": sugg, "reason": "no catalogue name matches"}
	order = {"exact": 0, "high": 1, "medium": 2}
	best: dict[str, tuple] = {}
	for c in cands:
		if c[0] not in best or order[c[1]] < order[best[c[0]][1]]:
			best[c[0]] = c
	ranked = sorted(best.values(), key=lambda c: (order[c[1]], -c[3]))
	iid, conf, method, score = ranked[0]
	if len([c for c in ranked if order[c[1]] == order[conf]]) > 1 and conf != "exact":
		conf = "medium"
		method += "_ambiguous"
	item = cat.by_id[iid]
	aspect_ok = plausible_aspect(img, item, aspect_ranges)
	if not aspect_ok:
		conf = {"exact": "high", "high": "medium", "medium": "low"}[conf]
		method += "+aspect_implausible"
	if any(t.startswith("piece_") for t in tags) and item["connect_style"]:
		role = "piece"
	else:
		role = "candidate"
	status = "auto" if conf in ("exact", "high") else ("review" if conf == "medium" else "unmatched")
	return {"status": status, "item_id": iid if status != "unmatched" else None, "confidence": conf, "method": method,
		"variant": variant_id_from_tags(tags), "role": role, "score": round(score, 1),
		"suggestions": [c[0] for c in ranked[:5]], "aspect_ok": aspect_ok}


# ------------------------------------------------------------------------------------------------- user decisions
def merge_user_decisions(mapping: dict, install_dir: Path | None, log_lines: list) -> dict:
	"""Read <install-dir>/overrides.json (assign / rejected / verified) into mapping.json as confirmed/rejected."""
	if not install_dir:
		return {}
	ov = read_json(install_dir / "overrides.json")
	if not isinstance(ov, dict):
		return {}
	pack = read_json(install_dir / "pack.json", {}) or {}
	review = read_json(install_dir / "review.json", {}) or {}
	file_to_key = {e.get("file"): e.get("source_key") for e in review.get("items", []) if isinstance(e, dict)}
	sprites = pack.get("sprites", {}) or {}
	changes = {"assign": 0, "rejected": 0, "verified": 0, "unresolved": 0}
	ts = now_iso()
	for rel, iid in (ov.get("assign") or {}).items():
		sk = file_to_key.get(rel)
		if not sk:
			changes["unresolved"] += 1
			continue
		if iid:
			mapping[sk] = {**mapping.get(sk, {}), "item_id": iid, "status": "confirmed", "confidence": "user",
				"method": "user_assign", "updated": ts}
			changes["assign"] += 1
	for art_key, sd in (ov.get("sprites") or {}).items():
		if not isinstance(sd, dict):
			continue
		ent = sprites.get(art_key) or {}
		targets = [(ent, sd)]
		for vid, vd in (sd.get("variants") or {}).items():
			if isinstance(vd, dict):
				targets.append(((ent.get("variants") or {}).get(vid) or {}, vd))
		for e, d in targets:
			sk = (e.get("source") or {}).get("key")
			if not sk:
				if d.get("rejected") or "verified" in d:
					changes["unresolved"] += 1
				continue
			if d.get("rejected"):
				mapping[sk] = {**mapping.get(sk, {}), "status": "rejected", "method": "user_rejected", "updated": ts}
				changes["rejected"] += 1
			elif d.get("verified"):
				mapping[sk] = {**mapping.get(sk, {}), "status": "confirmed", "verified": True,
					"method": mapping.get(sk, {}).get("method", "user_verified"), "updated": ts}
				changes["verified"] += 1
			elif d.get("verified") is False:
				# the user un-verified it (e.g. a builder-QA mark they disagree with): never re-apply QA verification
				mapping[sk] = {**mapping.get(sk, {}), "user_unverified": True, "updated": ts}
				changes.setdefault("unverified", 0)
				changes["unverified"] += 1
	log_lines.append(f"user decisions from overrides.json: {changes}")
	return changes


def load_qa_verified(path: Path) -> dict[str, str]:
	"""Builder QA list (mapping/visually_verified.json): item id -> the source key that was inspected by eye.

	These are checks made while building/testing the pack, not decisions by the pack's user, so they are written to
	pack.json as verified + verified_by "qa" and never counted as "confirmed by you"."""
	data = read_json(path, {}) or {}
	out = {}
	for iid, rec in (data.get("verified") or {}).items():
		if isinstance(rec, dict) and isinstance(rec.get("source"), str):
			out[iid] = rec["source"]
	return out


# ------------------------------------------------------------------------------------------------- image ops
def strip_detached_top(im: Image.Image) -> tuple[Image.Image, int]:
	"""Remove small connected blobs that float above the main body (HUD bubbles baked into idle frames)."""
	a = np.asarray(im)[..., 3] > A_VIS
	h, w = a.shape
	f = 2   # label on a half-resolution mask (cheap, and closes 1-px gaps)
	small = a[: h - h % f, : w - w % f].reshape(h // f, f, w // f, f).any(axis=(1, 3))
	lab = np.zeros(small.shape, dtype=np.int32)
	nlab = 0
	sizes = {}
	for y0, x0 in zip(*np.nonzero(small)):
		if lab[y0, x0]:
			continue
		nlab += 1
		stack = [(y0, x0)]
		lab[y0, x0] = nlab
		cnt = 0
		while stack:
			y, x = stack.pop()
			cnt += 1
			for yy, xx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
				if 0 <= yy < small.shape[0] and 0 <= xx < small.shape[1] and small[yy, xx] and not lab[yy, xx]:
					lab[yy, xx] = nlab
					stack.append((yy, xx))
		sizes[nlab] = cnt
	if nlab <= 1:
		return im, 0
	main = max(sizes, key=sizes.get)
	ys = np.nonzero(lab == main)[0]
	main_top = ys.min()
	removed = 0
	arr = np.array(im)
	for lid, cnt in sizes.items():
		if lid == main:
			continue
		yy, xx = np.nonzero(lab == lid)
		if cnt < 0.2 * sizes[main] and yy.max() < main_top + 0.25 * (ys.max() - main_top) and yy.min() <= main_top:
			m = np.zeros(small.shape, bool)
			m[yy, xx] = True
			big = np.repeat(np.repeat(m, f, axis=0), f, axis=1)
			full = np.zeros((h, w), bool)
			full[: big.shape[0], : big.shape[1]] = big
			arr[full] = 0
			removed += 1
	return Image.fromarray(arr, "RGBA"), removed


def composite_exports(layers: list[dict]) -> tuple[Image.Image, tuple[float, float]]:
	"""Overlay client renders that share one registration point. layers: {path, origin, dx, dy, mirror} (px)."""
	boxes = []
	ims = []
	for L in layers:
		im = load_rgba(L["path"])
		ox, oy = L["origin"]
		if L.get("mirror"):
			im = ImageOps.mirror(im)
			ox = im.width - ox
		ims.append((im, ox - L.get("dx", 0.0), oy - L.get("dy", 0.0)))
		boxes.append((-(ox - L.get("dx", 0.0)), -(oy - L.get("dy", 0.0)),
			im.width - (ox - L.get("dx", 0.0)), im.height - (oy - L.get("dy", 0.0))))
	x0 = math.floor(min(b[0] for b in boxes))
	y0 = math.floor(min(b[1] for b in boxes))
	x1 = math.ceil(max(b[2] for b in boxes))
	y1 = math.ceil(max(b[3] for b in boxes))
	canvas = Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 0))
	for im, ox, oy in ims:
		canvas.alpha_composite(im, (int(round(-ox - x0)), int(round(-oy - y0))))
	return canvas, (-x0, -y0)


def bleed_rgb(im: Image.Image, iterations: int = 16, threshold: int = 20) -> Image.Image:
	"""Spread the colour of visible pixels into the (nearly) transparent ones around them (alpha unchanged).

	Resizing in premultiplied mode leaves RGB = 0 (black) under alpha 0 and quantised, mostly dark RGB under very
	low alpha. Engines that build mipmaps or filter straight-alpha textures pull that into the edges: dark fringes
	when the farm is zoomed out and on downscaled thumbnails. Like Godot's "fix alpha border" (pixels with
	alpha < 20 take the colour of nearby stronger pixels), done once at build time; the pack declares
	"alpha_bleed": true so the app skips its own runtime fix. Measured against premultiplied downsampling on 10
	pack sprites (mip levels 2/3): mean edge error 6.4/11.0 (black), 2.5/4.3 (Godot fix_alpha_edges), 2.4/4.0 (this)."""
	a = np.asarray(im.convert("RGBA")).astype(np.float32)
	alpha = a[..., 3]
	rgb = a[..., :3].copy()
	known = alpha >= threshold
	if known.all() or not known.any():
		return im
	h, w = known.shape
	for _ in range(iterations):
		acc = np.zeros_like(rgb)
		cnt = np.zeros((h, w), np.float32)
		kp = np.pad(known, 1)
		rp = np.pad(rgb * known[..., None], ((1, 1), (1, 1), (0, 0)))
		for dy, dx in ((0, 1), (2, 1), (1, 0), (1, 2)):
			k = kp[dy:dy + h, dx:dx + w]
			acc += rp[dy:dy + h, dx:dx + w]
			cnt += k
		new = (~known) & (cnt > 0)
		if not new.any():
			break
		rgb[new] = acc[new] / cnt[new][:, None]
		known = known | new
	if not known.all():
		strong = alpha >= threshold
		rgb[~known] = rgb[strong].mean(axis=0) if strong.any() else rgb[~known]
	out = np.dstack([np.clip(rgb + 0.5, 0, 255), alpha]).astype(np.uint8)
	return Image.fromarray(out, "RGBA")


def render_job(job: dict) -> dict:
	"""Load -> (composite) -> (strip overlay) -> (mirror) -> trim -> downscale to <= max ppw -> WebP + thumb."""
	try:
		if job.get("layers"):
			im, origin = composite_exports(job["layers"])
			ax, ay = origin[0] + job["anchor_rel"][0], origin[1] + job["anchor_rel"][1]
		else:
			im = load_rgba(job["src"])
			ax, ay = job["anchor"]
		notes = []
		if job.get("strip_overlay"):
			im, n = strip_detached_top(im)
			if n:
				notes.append(f"removed {n} detached HUD blob(s)")
		if job.get("mirror"):
			im = ImageOps.mirror(im)
			ax = im.width - ax
		a = np.asarray(im)[..., 3]
		bb = _bbox(a > A_TRIM)
		if bb is None:
			return {"id": job["id"], "error": "empty image"}
		im = im.crop(bb)
		ax, ay = ax - bb[0], ay - bb[1]
		ppw = float(job["ppw"])
		max_ppw = job.get("max_ppw", MAX_PPW)
		w0, h0 = im.size
		if job.get("max_side") and max(w0, h0) > job["max_side"]:
			f = job["max_side"] / max(w0, h0)
		else:
			f = min(1.0, max_ppw / ppw) if ppw > 0 else 1.0
		if f < 0.999:
			nw, nh = max(1, round(w0 * f)), max(1, round(h0 * f))
			im = im.convert("RGBa").resize((nw, nh), Image.Resampling.LANCZOS).convert("RGBA")
			fx, fy = nw / w0, nh / h0
			ax, ay = ax * fx, ay * fy
			ppw = ppw * (fx + fy) / 2
		out = Path(job["out"])
		out.parent.mkdir(parents=True, exist_ok=True)
		im = bleed_rgb(im)
		im.save(out, "WEBP", quality=WEBP_QUALITY, method=4, exact=True)
		res = {"id": job["id"], "file": job["rel"], "anchor": [round(ax, 2), round(ay, 2)], "ppw": round(ppw, 5),
			"size": list(im.size), "sha256": sha256_file(out), "notes": notes}
		if job.get("thumb"):
			t = im.convert("RGBa")
			t.thumbnail((THUMB_MAX, THUMB_MAX), Image.Resampling.LANCZOS)
			t = bleed_rgb(t.convert("RGBA"), 6)
			tp = Path(job["thumb"])
			tp.parent.mkdir(parents=True, exist_ok=True)
			t.save(tp, "WEBP", quality=85, method=4, exact=True)
			res["thumb"] = job["thumb_rel"]
			res["thumb_sha256"] = sha256_file(tp)
		return res
	except Exception as ex:  # noqa: BLE001
		return {"id": job["id"], "error": f"{type(ex).__name__}: {ex}"}


# ------------------------------------------------------------------------------------------------- HUD-free renders
def rerender_without_hud(root: Path, version: str) -> dict:
	"""Re-render client exports whose clip has HUD children (e.g. the barn's upgrade bubble) without them.

	Uses tools/private_assets/extract_from_apk.py as a library on the container files already copied to
	<root>/raw/apk_extracted/<version>/assets/sc (nothing is downloaded). Output: <root>/raw/apk_sprites_clean/
	<version>/<sc>/<export>.png + index.json (same fields as the extractor). Returns {(sc, export): entry}.
	Skipped (returns what exists) when the extractor's dependencies (zstandard, texture2ddecoder) are missing."""
	out_root = root / "raw" / "apk_sprites_clean" / version
	have = {}
	for idx_p in out_root.glob("*/index.json"):
		for ex, e in (read_json(idx_p, {}) or {}).items():
			if e.get("file") and (idx_p.parent / e["file"]).exists():
				have[(idx_p.parent.name, ex)] = {**e, "path": str(idx_p.parent / e["file"])}
	sc_dir = root / "raw" / "apk_extracted" / version / "assets" / "sc"
	src_dir = root / "raw" / "apk_sprites" / version
	targets = collections.defaultdict(list)
	for scd in sorted(p for p in src_dir.iterdir() if p.is_dir()) if src_dir.is_dir() else []:
		for ex in (read_json(scd / "index.json", {}) or {}):
			if STRIP_OVERLAY_RE.match(ex) and (scd.name, ex) not in have:
				targets[scd.name].append(ex)
	if not targets:
		return have
	try:
		sys.path.insert(0, str(Path(__file__).resolve().parent))
		import extract_from_apk as X  # noqa: PLC0415 - optional dependency chain
		X.need("zstandard")
		X.need("texture2ddecoder")
	except Exception as ex:  # noqa: BLE001
		log(f"HUD-free re-render skipped ({ex}); the overlay-strip heuristic is used instead")
		return have
	for sc, exports in targets.items():
		f = sc_dir / f"{sc}.sc"
		if not f.exists():
			continue
		raw_sc = f.read_bytes()
		swf = X.parse_sc2(raw_sc, sc) if X.is_sc2(raw_sc) else None
		if swf is None:
			continue

		def _external(name: str):
			p = sc_dir / name
			return p.read_bytes() if p.exists() else None
		X.load_textures(swf, "auto", _external)
		empty_id = -424242
		swf.shapes[empty_id] = X.Shape(empty_id)
		rend = X.Renderer(swf)
		ids = {n: i for i, n in swf.exports}
		idx_p = out_root / sc / "index.json"
		index = read_json(idx_p, {}) or {}
		for ex in exports:
			oid = ids.get(ex)
			clip = swf.clips.get(oid)
			if clip is None:
				continue
			removed = []
			for ci, nm in enumerate(clip.names):
				if nm and HUD_INSTANCE_RE.match(nm):
					clip.children[ci] = empty_id
					removed.append(nm)
			starts = {lab: i for i, (_, lab) in reversed(list(enumerate(clip.frames))) if lab}
			frame = starts.get("IdleStart", 0)
			ops, warns = rend.display_list(oid, frame)
			img, origin = rend.render(ops, 1.5)
			if img is None:
				continue
			(out_root / sc).mkdir(parents=True, exist_ok=True)
			img.save(out_root / sc / f"{ex}.png")
			index[ex] = {"id": oid, "file": f"{ex}.png", "size": list(img.size), "origin": [round(origin[0], 2),
				round(origin[1], 2)], "scale": 1.5, "pixels_per_world_px": 3.0, "frame_rendered": frame,
				"frame_label": "IdleStart" if "IdleStart" in starts else None, "removed_instances": removed,
				"warnings": sorted(set(warns))}
			have[(sc, ex)] = {**index[ex], "path": str(out_root / sc / f"{ex}.png")}
		write_json(idx_p, index)
	log(f"HUD-free re-render: {sum(len(v) for v in targets.values())} exports -> {out_root}")
	return have


# ------------------------------------------------------------------------------------------------- builder
class Builder:
	def __init__(self, args):
		self.args = args
		self.root = ensure_private(args.root, "the private root")
		self.mapdir = self.root / "mapping"
		self.packdir = self.root / "packs" / PACK_ID
		self.install = ensure_private(args.install_dir, "the installed pack") if args.install_dir else None
		self.workers = max(1, min(args.workers, os.cpu_count() or 1))
		self.notes: list[str] = []
		self.t0 = time.time()
		self.qa_verified = load_qa_verified(self.mapdir / "visually_verified.json")

	# --- stage 1
	def inventory(self):
		self.items, self.categories = load_catalog()
		self.cat = CatalogIndex(self.items)
		recs, self.src_meta = discover(self.root)
		vers = sorted({r["apk"]["build"] for r in recs if r["source"] == "apk"}, key=_version_tuple)
		self.clean = rerender_without_hud(self.root, vers[-1]) if vers else {}
		for r in recs:
			if r["source"] == "apk" and r["apk"]["build"] == (vers[-1] if vers else None):
				c = self.clean.get((r["apk"]["sc"], r["apk"]["export"]))
				if c:
					r["path"] = c["path"]
					r["apk"]["origin"] = c["origin"]
					r["apk"]["hud_removed"] = c.get("removed_instances", [])
					r["prov"]["rerendered_without"] = c.get("removed_instances", [])
		self.inv = run_inventory(recs, self.mapdir / "inventory.json", self.args.rebuild, self.workers)
		self.recs = {r["key"]: r for r in recs if r["key"] in self.inv}
		inv_out = {"generated": now_iso(), "tool": f"build_pack.py {TOOL_VERSION}", "root": str(self.root),
			"note": "PRIVATE: proprietary Supercell art inventory. Never commit or share.",
			"sources": self.src_meta, "records": {k: {kk: vv for kk, vv in r.items() if kk != "match"} for k, r in self.inv.items()}}
		write_json(self.mapdir / "inventory.json", inv_out, indent=None)
		errs = sum(1 for r in self.inv.values() if (r.get("img") or {}).get("error"))
		log(f"inventory: {len(self.inv)} records written ({errs} unreadable)")

	# --- stage 2/3
	def match(self):
		gd = load_game_data(self.root)
		self.game_version = gd.get("version", "")
		self.objs = game_objects(gd)
		self.obj_by_key = {o["key"]: o for o in self.objs}
		log(f"game data: build {self.game_version or '-'}; {len(self.objs)} placeable client objects")
		gm = match_game_objects(self.objs, self.cat)
		self.links = gm["links"]
		self.obj_status = gm["obj_status"]
		apk_by = {}
		for k, r in self.inv.items():
			if r["source"] == "apk" and r["apk"]["build"] == self.game_version:
				apk_by[(r["apk"]["sc"], r["apk"]["export"])] = k
		self.apk_by = apk_by
		# aspect ranges per category from client renders linked to the catalogue
		ar = collections.defaultdict(list)
		for iid, L in self.links.items():
			k = apk_by.get((L["primary"]["sc"], L["primary"]["export"]))
			img = (self.inv.get(k) or {}).get("img") or {}
			bb = img.get("bbox_solid") or img.get("bbox")
			if bb:
				ar[self.cat.by_id[iid]["category"]].append((bb[2] - bb[0]) / max(1, bb[3] - bb[1]))
		self.aspect_ranges = {c: (pct(v, 2), pct(v, 98)) for c, v in ar.items() if len(v) >= 8}

		prior = read_json(self.mapdir / "mapping.json", {}) or {}
		prior_dec = prior.get("decisions", prior) if isinstance(prior, dict) else {}
		decisions: dict[str, dict] = {}
		ts = now_iso()
		# client exports referenced by linked objects
		used = {}
		for iid, L in self.links.items():
			for o in [L["primary"]] + L["others"]:
				role_base = "primary" if o is L["primary"] else "variant"
				vbase = "" if o is L["primary"] else variant_name_from(L["primary"], o)
				conf = L["confidence"] if o is L["primary"] else "high"
				refs = [(o["export"], role_base, vbase)]
				if o["mastered"]:
					refs.append((o["mastered"], "variant", (vbase + "_" if vbase else "") + "mastered"))
				for lv in o["levels"]:
					refs.append((lv["export"], "variant", (vbase + "_" if vbase else "") + f"lvl_{lv['level']}"))
				for p in o["parts"]:
					refs.append((p, "part", vbase))
				if o["fence"]:
					for piece, ex in o["fence"].items():
						if ex and piece != "pole":
							refs.append((ex, "connection", f"fence_{piece}"))
				if o["ditch"]:
					for m, ex in o["ditch"].items():
						if ex and m != 0:
							refs.append((ex, "connection", f"mask_{m}"))
				for pc in o["pieces"]:
					refs.append((pc["export"], "part", "habitat_piece"))
				for ex, role, var in refs:
					k = apk_by.get((o["sc"], ex))
					if not k or k in used:
						continue
					used[k] = True
					decisions[k] = {"item_id": iid, "status": "auto", "confidence": conf,
						"method": L["method"] if o is L["primary"] else "game_same_name_row", "variant": var,
						"role": role, "game_object": o["key"], "game_fp": list(o["fp"]), "updated": ts}
		# client exports of unlinked objects (review / unmatched)
		other_tab = {x["key"] for L in self.links.values() for x in L.get("other_tables", [])}
		for o in self.objs:
			k = apk_by.get((o["sc"], o["export"]))
			if not k or k in decisions:
				continue
			st = self.obj_status.get(o["key"])
			label = o["en"] or o["ru"] or o["name"]
			if st and st[0] == "skip":
				decisions[k] = {"item_id": None, "status": "unmatched", "confidence": "none", "method": st[3],
					"variant": "", "role": "game_placeholder_art", "game_object": o["key"], "reason": st[4], "updated": ts}
				continue
			if o["key"] in other_tab:
				decisions[k] = {"item_id": None, "status": "unmatched", "confidence": "none", "method": "game_text",
					"variant": "", "role": "same_name_other_table", "game_object": o["key"], "game_fp": list(o["fp"]),
					"reason": f"client object '{label}' [{o['table']}] shares a name with an item linked to another table",
					"updated": ts}
				continue
			if st and st[0] == "review":
				decisions[k] = {"item_id": None, "status": "review", "confidence": "medium", "method": st[3],
					"variant": "", "role": "candidate", "suggestions": [st[1]], "game_object": o["key"],
					"game_fp": list(o["fp"]), "reason": f"client object '{label}' ({st[4] or st[3]})", "updated": ts}
			else:
				sugg = [i for i, s in self.cat.fuzzy(norm_key(tokens_of(label)), TABLE_CATS.get(o["table"]), 3) if s >= 75]
				role = "game_object_not_in_catalog" if o["table"] in PLACEABLE_TABLES else "game_object_not_placeable"
				decisions[k] = {"item_id": None, "status": "unmatched", "confidence": "none", "method": "game_text",
					"variant": "", "role": role, "suggestions": sugg, "game_object": o["key"],
					"game_fp": list(o["fp"]), "reason": f"client object '{label}' [{o['table']}] has no catalogue item",
					"updated": ts}
		# all other client exports
		for k, r in self.inv.items():
			if r["source"] != "apk" or k in decisions:
				continue
			if r["apk"]["build"] != self.game_version:
				role, reason = "older_build", f"build {r['apk']['build']} (newest {self.game_version} used)"
			elif OBJECT_SC_RE.match(r["apk"]["sc"]):
				role, reason = "unreferenced_export", "export not referenced by any placeable CSV row (part/state/skin)"
			else:
				role, reason = "not_object", f"{r['apk']['sc']}: HUD/characters/effects"
			decisions[k] = {"item_id": None, "status": "unmatched", "confidence": "none", "method": "-",
				"variant": "", "role": role, "reason": reason, "updated": ts}
		# Fan Kit / wiki
		for k, r in self.inv.items():
			if r["source"] == "apk":
				continue
			d = match_named_record(r, self.cat, self.aspect_ranges)
			d.setdefault("item_id", None)
			d.setdefault("confidence", "none")
			d.setdefault("method", "-")
			d.setdefault("variant", "")
			d["updated"] = ts
			decisions[k] = d
		# reuse prior human decisions (never overridden by automation)
		kept = 0
		for k, p in prior_dec.items():
			if isinstance(p, dict) and p.get("status") in ("confirmed", "rejected"):
				auto = decisions.get(k)
				decisions[k] = dict(p)
				if auto and auto.get("status") not in ("confirmed", "rejected"):
					decisions[k]["automation_would_say"] = {x: auto.get(x) for x in ("item_id", "status", "confidence", "method")}
				kept += 1
		self.user_changes = merge_user_decisions(decisions, self.install, self.notes)
		self.decisions = decisions
		self.kept_human = kept
		log(f"matching: {len(decisions)} decisions; kept {kept} human decisions; {self.user_changes or 'no overrides.json'}")

	def _hist_threshold(self):
		"""Colour distance threshold: p95 over pHash-duplicate pairs (same item, client vs Fan Kit/wiki)."""
		D, inv = self.decisions, self.inv
		prim = {}
		for k, d in D.items():
			if d.get("role") == "primary" and d.get("item_id") and inv.get(k, {}).get("source") == "apk":
				prim[d["item_id"]] = k
		same, rand = [], []
		keys = list(prim.values())
		rng = np.random.default_rng(5)
		for k, d in D.items():
			r = inv.get(k)
			if not r or r["source"] == "apk" or d.get("status") != "auto" or d.get("item_id") not in prim:
				continue
			a, b = r.get("img") or {}, inv[prim[d["item_id"]]].get("img") or {}
			if img_distance(a, b) <= PHASH_DUP:
				same.append(hist_distance(a, b))
			if keys:
				rand.append(hist_distance(a, inv[keys[int(rng.integers(len(keys)))]].get("img") or {}))
		p95 = pct(same, 95)
		self.hist_alt = max(HIST_ALT_MIN, p95 or 0.0)
		self.hist_stats = {"duplicate_pairs": robust(same), "duplicate_pairs_p95": p95, "random_pairs": robust(rand),
			"alternate_threshold": round(self.hist_alt, 3)}

	# --- selection
	def select(self):
		"""Per catalogue item: primary sprite, variants, connections, alternates, duplicates."""
		D = self.decisions
		inv = self.inv
		self._hist_threshold()
		per_item = collections.defaultdict(list)
		for k, d in D.items():
			if d.get("item_id") and d.get("status") in ("auto", "confirmed") and k in inv:
				per_item[d["item_id"]].append(k)
		self.sel = {}
		src_rank = {"apk": 0, "fankit": 1, "wiki_en": 2, "wiki_ru": 3}
		conf_rank = {"user": -1, "exact": 0, "high": 1, "medium": 2}
		for iid, keys in per_item.items():
			it = self.cat.by_id.get(iid)
			if not it:
				continue
			apk_primary = [k for k in keys if D[k].get("role") == "primary" and inv[k]["source"] == "apk"]
			confirmed = [k for k in keys if D[k].get("status") == "confirmed" and D[k].get("role") not in ("connection", "part")]
			cands = [k for k in keys if D[k].get("role") in ("primary", "candidate", None) or D[k].get("status") == "confirmed"]
			cands = [k for k in cands if (inv[k].get("img") or {}).get("alpha_used")]

			def rank(k):
				d, r = D[k], inv[k]
				img = r.get("img") or {}
				return (0 if d.get("status") == "confirmed" else 1, src_rank.get(r["source"], 9),
					1 if d.get("variant") else 0, conf_rank.get(d.get("confidence"), 3),
					-(img.get("w", 0) * img.get("h", 0)))
			primary = sorted(confirmed or apk_primary or cands, key=rank)[0] if (confirmed or apk_primary or cands) else None
			if primary is None:
				continue
			s = {"primary": primary, "variants": {}, "connections": {}, "alternates": [], "duplicates": [], "parts": []}
			pd = D[primary]
			game_obj = None
			if pd.get("game_object"):
				game_obj = self.obj_by_key.get(pd["game_object"])
			s["game_object"] = game_obj
			# variants and pieces from the client
			for k in keys:
				d = D[k]
				if k == primary:
					continue
				if d.get("role") == "variant" and inv[k]["source"] == "apk":
					vid = d.get("variant") or slug(inv[k]["apk"]["export"])
					s["variants"].setdefault(vid, k)
				elif d.get("role") == "connection":
					s["connections"][d.get("variant")] = k
				elif d.get("role") == "part":
					s["parts"].append(k)
			# alternates / duplicates among the other (non-client) matches
			chosen = [primary] + list(s["variants"].values())
			for k in sorted(keys, key=rank):
				if k in chosen or D[k].get("role") in ("variant", "connection", "part") and inv[k]["source"] == "apk":
					continue
				img = inv[k].get("img") or {}
				if not img.get("alpha_used") or D[k].get("confidence") not in ("exact", "high", "user"):
					continue
				dist = min(img_distance(img, inv[c].get("img") or {}) for c in chosen)
				hd = min(hist_distance(img, inv[c].get("img") or {}) for c in chosen)
				D[k]["phash_distance_to_selected"] = dist
				D[k]["colour_distance_to_selected"] = round(hd, 3)
				if D[k].get("role") == "piece" or (it["connect_style"] and self._has_pieces(s)):
					s["duplicates"].append(k)
					D[k]["role"] = "piece_duplicate"
				elif dist <= PHASH_ALT or hd <= self.hist_alt:
					s["duplicates"].append(k)
					D[k]["role"] = "duplicate" if dist <= PHASH_DUP else "similar"
				else:
					vid = f"alt_{inv[k]['source']}_{slug(str(inv[k]['prov'].get('id') or inv[k]['title']), 20)}"
					s["variants"][vid] = k
					s["alternates"].append(k)
					D[k]["role"] = "alternate"
					chosen.append(k)
			D[primary]["role"] = "primary" if D[primary].get("role") in (None, "candidate", "primary") else D[primary]["role"]
			self.sel[iid] = s

	def _has_pieces(self, s: dict) -> bool:
		go = s.get("game_object")
		return bool(go and (go["fence"] or go["ditch"]))

	# --- calibration
	def calibrate(self):
		D, inv = self.decisions, self.inv
		cov = read_json(self.mapdir / "calibration_overrides.json")
		if cov is None:
			cov = {"_doc": "Per-item calibration overrides (private). Keys are catalogue ids. Fields: source_key (force "
				"a source image), anchor_src [x,y] and ppw_src (source-image pixels, before trimming/scaling), mirror "
				"(bool). Example: {\"items\": {\"bakery\": {\"anchor_src\": [300, 410], \"ppw_src\": 3.0}}}",
				"items": {}}
			write_json(self.mapdir / "calibration_overrides.json", cov)
		self.cal_over = cov.get("items", {}) or {}
		# ground truth from client renders whose game footprint equals the catalogue footprint
		gt = collections.defaultdict(lambda: collections.defaultdict(list))
		for iid, s in self.sel.items():
			k = s["primary"]
			r = inv[k]
			if r["source"] != "apk" or not s.get("game_object"):
				continue
			it = self.cat.by_id[iid]
			W, H = s["game_object"]["fp"]
			img = r.get("img") or {}
			bb = img.get("bbox_solid") or img.get("bbox")
			if not bb or r["apk"].get("origin") is None:
				continue
			sc = float(r["apk"]["scale"])
			ppw = float(r["apk"]["ppw"])
			ox, oy = r["apk"]["origin"]
			axp = ox + sc * (W - H) * SC_TILE_HALF_W / 2 * 1.0
			ayp = oy + sc * (W + H) * SC_TILE_HALF_H / 2 * 1.0
			cat_ = it["category"]
			dw = (W + H) * HALF_W
			gt[cat_]["k_w"].append((bb[2] - bb[0]) / ppw / dw)
			gt[cat_]["c_b"].append((bb[3] - ayp) / ppw / ((W + H) * HALF_H / 2))
			gt[cat_]["x_off"].append(((bb[0] + bb[2]) / 2 - axp) / ppw / dw)
			if it["fp_trusted"]:
				gt[cat_]["ppw_footprint_est"].append((bb[2] - bb[0]) / ((it["fp"][0] + it["fp"][1]) * HALF_W))
		self.gt = {c: {m: robust(v) for m, v in d.items()} for c, d in gt.items()}
		allv = collections.defaultdict(list)
		for c, d in gt.items():
			for m, v in d.items():
				allv[m] += v
		self.gt_all = {m: robust(v) for m, v in allv.items()}
		# scale of Fan Kit / wiki images, measured against the client render of the same object
		rel = collections.defaultdict(lambda: collections.defaultdict(list))
		fpfit = collections.defaultdict(lambda: collections.defaultdict(list))
		ph_same, ph_rand = [], []
		by_item_named = collections.defaultdict(list)
		for k, d in D.items():
			if d.get("item_id") and d.get("status") in ("auto", "confirmed") and inv.get(k, {}).get("source") in ("fankit", "wiki_en", "wiki_ru"):
				by_item_named[d["item_id"]].append(k)
		rng = np.random.default_rng(7)
		apk_prims = [s["primary"] for s in self.sel.values() if inv[s["primary"]]["source"] == "apk"]
		for iid, keys in by_item_named.items():
			s = self.sel.get(iid)
			it = self.cat.by_id[iid]
			for k in keys:
				r = inv[k]
				img = r.get("img") or {}
				bb = img.get("bbox_solid") or img.get("bbox")
				if not bb:
					continue
				src = r["source"]
				if it["fp_trusted"]:
					fpfit[src][it["category"]].append((bb[2] - bb[0]) / ((it["fp"][0] + it["fp"][1]) * HALF_W))
				if s and inv[s["primary"]]["source"] == "apk":
					pimg = inv[s["primary"]].get("img") or {}
					pbb = pimg.get("bbox_solid") or pimg.get("bbox")
					dist = img_distance(img, pimg)
					ph_same.append(dist)
					if apk_prims:
						other = apk_prims[int(rng.integers(len(apk_prims)))]
						ph_rand.append(img_distance(img, inv[other].get("img") or {}))
					if pbb and dist <= PHASH_DUP:
						apk_ppw = float(inv[s["primary"]]["apk"]["ppw"])
						rel[src][it["category"]].append((bb[2] - bb[0]) / ((pbb[2] - pbb[0]) / apk_ppw))
		self.scale_stats = {src: {c: robust(v) for c, v in d.items()} for src, d in rel.items()}
		self.scale_all = {src: robust([x for v in d.values() for x in v]) for src, d in rel.items()}
		self.fpfit_stats = {src: {c: robust(v) for c, v in d.items()} for src, d in fpfit.items()}
		self.phash_stats = {"same_item_pairs": robust(ph_same), "random_pairs": robust(ph_rand),
			"thresholds": {"duplicate_max": PHASH_DUP, "alternate_min": PHASH_ALT + 1},
			"colour_histogram": self.hist_stats,
			"rule": "duplicate: pHash (mirror-invariant) <= 12; alternate: pHash > 22 AND colour distance > threshold; "
				"otherwise 'similar' (same appearance, not added)"}
		# decide the policy for non-client images
		self.common_scale = {}
		for src, d in self.scale_stats.items():
			for c, st in d.items():
				if st.get("n", 0) >= 5 and st.get("rel_iqr") is not None and st["rel_iqr"] <= 0.15:
					self.common_scale[(src, c)] = st["median"]
		log(f"calibration: client ground truth in {len(self.gt)} categories; common Fan Kit/wiki scale in "
			f"{len(self.common_scale)} (source, category) groups")

	def _apk_anchor(self, r: dict, fp: tuple[int, int]) -> tuple[float, float]:
		ox, oy = r["apk"]["origin"]
		sc = float(r["apk"]["scale"])
		W, H = fp
		return ox + sc * (W - H) * SC_TILE_HALF_W / 2, oy + sc * (W + H) * SC_TILE_HALF_H / 2

	# Qualifiers that name a seasonal / decorated edition of an object whose client render exists
	# ("large_spruce_autumn" -> "large_spruce", "purple_tree_with_lights" -> "purple_tree").
	# Not "decoration"/"furniture": in the catalogue those only disambiguate names and often mean a
	# different object (fitting_room_decoration is a tent, fitting_room a mirror).
	SIBLING_QUALIFIERS = ("autumn", "winter", "spring", "summer", "snowy", "frozen", "festive", "with_lights")

	def _sibling_of(self, it: dict) -> tuple[str, dict] | None:
		"""A catalogue item with a single-export client render that is the same object as `it` (name minus a
		seasonal/edition qualifier). Its world size and anchor transfer to `it`'s Fan Kit / wiki image."""
		iid = it["id"]
		for q in self.SIBLING_QUALIFIERS:
			for cand in (iid[: -len(q) - 1] if iid.endswith("_" + q) else None,
					iid.replace("_" + q + "_", "_") if ("_" + q + "_") in iid else None):
				if not cand or cand == iid or cand not in self.cat.by_id:
					continue
				ss = self.sel.get(cand)
				if not ss:
					continue
				sr = self.inv.get(ss["primary"])
				go = ss.get("game_object")
				if not sr or sr["source"] != "apk" or (go and (go["parts"] or go["pieces"])):
					continue
				if tuple(self.cat.by_id[cand]["fp"]) != tuple(it["fp"]):
					continue
				return cand, sr
		return None

	def _sibling_calibration(self, r: dict, it: dict) -> dict | None:
		"""Scale + anchor from the sibling's client render: same visible width in world px, same anchor
		position relative to the visible bounding box. Rejected when the shapes differ (aspect > 30 %)."""
		sib = self._sibling_of(it)
		if not sib:
			return None
		cand, sr = sib
		img = r.get("img") or {}
		bb = img.get("bbox")
		simg = sr.get("img") or {}
		sbb = simg.get("bbox")
		if not bb or not sbb:
			return None
		bw, bh = bb[2] - bb[0], bb[3] - bb[1]
		sw, sh = sbb[2] - sbb[0], sbb[3] - sbb[1]
		if min(bw, bh, sw, sh) <= 0:
			return None
		aspect = (bw / bh) / (sw / sh)
		if not 0.77 <= aspect <= 1.3:
			return None
		go = (self.sel.get(cand) or {}).get("game_object")
		gfp = tuple(go["fp"]) if go else tuple(self.cat.by_id[cand]["fp"])
		sax, say = self._apk_anchor(sr, gfp)
		sppw = float(sr["apk"]["ppw"])
		world_w = sw / sppw
		ppw = bw / world_w
		ax = bb[0] + (sax - sbb[0]) / sw * bw
		ay = bb[3] - (sbb[3] - say) / sppw * ppw
		return {"anchor": (ax, ay), "ppw": ppw, "method": "sibling_client_render", "sibling": cand,
			"shadow_used": False, "aspect_ratio_vs_sibling": round(aspect, 3)}

	def _named_calibration(self, r: dict, it: dict) -> dict:
		"""Anchor + ppw (source px) for a Fan Kit / wiki image (no registration point)."""
		sib = self._sibling_calibration(r, it)
		if sib:
			return sib
		img = r.get("img") or {}
		bbv = img.get("bbox")
		bbs = img.get("bbox_solid") or bbv
		w, h = it["fp"]
		cat_ = it["category"]
		g = self.gt.get(cat_) or self.gt_all
		gall = self.gt_all
		k_w = (g.get("k_w") or {}).get("median") or (gall.get("k_w") or {}).get("median") or 1.0
		c_b = (g.get("c_b") or {}).get("median") or (gall.get("c_b") or {}).get("median") or 1.0
		x_off = (g.get("x_off") or {}).get("median") or 0.0
		flat = cat_ in ("path", "water", "field") or it["layer"] == "ground"
		dw = (w + h) * HALF_W
		method = None
		common = self.common_scale.get((r["source"], cat_))
		shadow = img.get("shadow_frac", 0) > 0.08 and img.get("shadow_below_px", 0) > 2
		bb = bbs if shadow else bbv
		if flat:
			ppw = (bbv[2] - bbv[0]) / dw
			ax, ay = (bbv[0] + bbv[2]) / 2, (bbv[1] + bbv[3]) / 2
			method = "flat_fit_bbox"
		else:
			if common:
				ppw = common * 1.0   # source px per world px is relative: px per client px * client ppw / client ppw
				# common scale is measured as source width / client world width -> already px per world px
				method = "category_common_scale"
			else:
				ppw = (bb[2] - bb[0]) / (dw * k_w)
				method = "footprint_fit_k_w"
			ax = (bb[0] + bb[2]) / 2 - x_off * dw * ppw
			ay = bb[3] - c_b * (w + h) * HALF_H / 2 * ppw
		return {"anchor": (ax, ay), "ppw": ppw, "method": method, "shadow_used": bool(shadow and not flat),
			"k_w": k_w, "c_b": c_b}

	def plan(self) -> list[dict]:
		"""Render jobs + pack entries skeleton."""
		inv, D = self.inv, self.decisions
		self.entries = {}
		self.cal_rows = []
		self.mirrored_items = []
		self.fp_mismatch = []
		jobs = []
		pd = self.packdir

		def job_for(jid, k, anchor, ppw, rel, thumb_rel=None, mirror=False, layers=None, anchor_rel=None, strip=False):
			r = inv[k]
			j = {"id": jid, "src": r["path"], "anchor": anchor, "ppw": ppw, "rel": rel, "out": str(pd / rel),
				"mirror": mirror, "strip_overlay": strip, "max_ppw": MAX_PPW}
			if thumb_rel:
				j["thumb"] = str(pd / thumb_rel)
				j["thumb_rel"] = thumb_rel
			if layers:
				j["layers"] = layers
				j["anchor_rel"] = anchor_rel
			jobs.append(j)
			return j

		for iid, s in sorted(self.sel.items()):
			it = self.cat.by_id[iid]
			key = it["art_key"]
			k = s["primary"]
			r = inv[k]
			over = self.cal_over.get(iid) or {}
			if over.get("source_key") and over["source_key"] in inv:
				k = over["source_key"]
				r = inv[k]
			ent = {"source": {"key": k, "kind": r["source"]}, "match": {x: D[k].get(x) for x in ("status", "confidence", "method")}}
			if r["source"] == "apk":
				ent["source"].update({"build": r["apk"]["build"], "sc": r["apk"]["sc"], "export": r["apk"]["export"]})
			else:
				ent["source"].update({"title": r["title"], "url": r["prov"].get("url") or r["prov"].get("description_url")})
			mirror = False
			go = s.get("game_object")
			cal = {"item": iid, "category": it["category"], "source": r["source"], "catalog_fp": list(it["fp"]),
				"catalog_fp_status": it["fp_status"]}
			if r["source"] == "apk":
				gfp = tuple(go["fp"]) if go else tuple(it["fp"])
				cal["game_fp"] = list(gfp)
				if gfp != tuple(it["fp"]):
					if gfp == tuple(it["fp"])[::-1] and gfp[0] != gfp[1]:
						mirror = True
						self.mirrored_items.append(iid)
					else:
						self.fp_mismatch.append({"item": iid, "name": it["name"], "category": it["category"],
							"catalog": list(it["fp"]), "catalog_status": it["fp_status"], "game": list(gfp),
							"game_object": go["key"] if go else None})
				anchor = self._apk_anchor(r, gfp)
				ppw = float(r["apk"]["ppw"])
				cal.update({"method": "client_registration_point", "ppw_src": ppw})
				ent["auto_anchor"] = False
				layers = None
				anchor_rel = None
				if go and (go["parts"] or go["pieces"]):
					layers, anchor_rel = self._layers_for(go, None, gfp)
					cal["composite"] = "parts" if go["parts"] else "habitat_pieces"
					ent["composite"] = cal["composite"] + " (assembled from client exports; unverified against the game)"
				strip = bool(STRIP_OVERLAY_RE.match(r["apk"]["export"])) and not r["apk"].get("hud_removed")
			else:
				c = self._named_calibration(r, it)
				anchor, ppw = c["anchor"], c["ppw"]
				cal.update({"method": c["method"], "ppw_src": round(ppw, 4), "shadow_used": c["shadow_used"]})
				if c.get("sibling"):
					cal["sibling"] = c["sibling"]
					ent["calibrated_from"] = c["sibling"]
				ent["auto_anchor"] = True
				layers = anchor_rel = None
				strip = False
			if over.get("anchor_src"):
				anchor = tuple(over["anchor_src"])
				cal["override"] = True
				ent["auto_anchor"] = False
			if over.get("ppw_src"):
				ppw = float(over["ppw_src"])
				cal["override"] = True
			if "mirror" in over:
				mirror = bool(over["mirror"])
			cal["mirrored"] = mirror
			self.cal_rows.append(cal)
			jid = f"{key}"
			job_for(jid, k, list(anchor), ppw, f"items/{key}.webp", f"thumbs/{key}.webp", mirror, layers, anchor_rel, strip)
			ent["mirrored"] = mirror
			if D.get(k, {}).get("verified"):
				ent["verified"] = True                     # the user's own decision (overrides.json)
			elif self.qa_verified.get(iid) == k and not D.get(k, {}).get("user_unverified"):
				# builder QA: inspected by eye in the app, recorded in mapping/visually_verified.json. Not a user decision;
				# only valid while the item still uses the very source image that was inspected.
				ent["verified"] = True
				ent["verified_by"] = "qa"
			# variants
			vents = {}
			for vid, vk in sorted(s["variants"].items()):
				vr = inv[vk]
				if vr["source"] == "apk":
					vgo = self.obj_by_key.get(D[vk].get("game_object")) or go
					vfp = tuple(vgo["fp"]) if vgo else tuple(it["fp"])
					va = self._apk_anchor(vr, vfp)
					vppw = float(vr["apk"]["ppw"])
					vlayers = vrel = None
					if vgo and vgo["parts"] and vid.startswith("lvl_"):
						lv = next((x for x in vgo["levels"] if f"lvl_{x['level']}" == vid), None)
						if lv and lv["parts"]:
							vlayers, vrel = self._layers_for(vgo, lv, vfp)
					vmirror = mirror
					vauto = False
				else:
					c = self._named_calibration(vr, it)
					va, vppw = c["anchor"], c["ppw"]
					vlayers = vrel = None
					vmirror = False
					vauto = True
				vfile = f"items/{key}__{slug(vid, 40)}.webp"
				job_for(f"{key}|v|{vid}", vk, list(va), vppw, vfile, f"thumbs/{key}__{slug(vid, 40)}.webp", vmirror,
					vlayers, vrel, bool(vr["source"] == "apk" and STRIP_OVERLAY_RE.match(vr["apk"]["export"])
					and not vr["apk"].get("hud_removed")))
				vents[vid] = {"source": {"key": vk, "kind": vr["source"]}, "auto_anchor": vauto}
			if vents:
				ent["variants"] = vents
			# connections
			conns = self._connection_plan(it, s, mirror)
			if conns:
				ent["connections"] = {}
				done = {}
				pieces = {p for _, p in conns.values()}
				thumb_piece = next((p for p in ("corner", "below", "right", "m05", "m10", "m06") if p in pieces), None)
				ent["thumb_piece"] = thumb_piece
				for mask, (ck, piece) in conns.items():
					if ck == k:
						ent["connections"][str(mask)] = {"piece": "@base", "source_key": ck}
						continue
					if ck not in done:
						cr = inv[ck]
						ca = self._apk_anchor(cr, (1, 1))
						cfile = f"items/{key}__{slug(piece, 20)}.webp"
						tfile = f"thumbs/{key}__{slug(piece, 20)}.webp" if piece == thumb_piece else None
						job_for(f"{key}|c|{piece}", ck, list(ca), float(cr["apk"]["ppw"]), cfile, tfile, mirror)
						done[ck] = piece
					ent["connections"][str(mask)] = {"piece": done[ck], "source_key": ck}
			self.entries[key] = {"item": iid, "entry": ent}
		return jobs

	def _layers_for(self, go: dict, level: dict | None, gfp) -> tuple[list, tuple]:
		"""Layer list for multi-export objects; anchor relative to the shared registration point."""
		inv = self.inv
		sc = go["sc"]
		layers = []
		base_exp = level["export"] if level else go["export"]
		parts = level["parts"] if level else go["parts"]
		scale = None
		for ex in [base_exp] + list(parts):
			k = self.apk_by.get((sc, ex))
			if not k:
				continue
			r = inv[k]
			scale = scale or float(r["apk"]["scale"])
			layers.append({"path": r["path"], "origin": r["apk"]["origin"]})
		if not level:
			# habitat pieces: each at its tile's top corner, mirrored ones flipped; back-to-front by (x+y)
			for pc in sorted(go["pieces"], key=lambda p: (p["x"] + p["y"], p["y"])):
				k = self.apk_by.get((pc["sc"], pc["export"]))
				if not k:
					continue
				r = inv[k]
				s = float(r["apk"]["scale"])
				dx = s * (pc["x"] - pc["y"]) * SC_TILE_HALF_W
				dy = s * (pc["x"] + pc["y"]) * SC_TILE_HALF_H
				layers.append({"path": r["path"], "origin": r["apk"]["origin"], "dx": dx, "dy": dy,
					"mirror": pc["mirrored"]})
		scale = scale or 1.5
		W, H = gfp
		return layers, (scale * (W - H) * SC_TILE_HALF_W / 2, scale * (W + H) * SC_TILE_HALF_H / 2)

	def _connection_plan(self, it: dict, s: dict, mirror: bool) -> dict:
		"""mask -> (source key, piece name). Fences: own SE/SW bits pick pole/right/below/corner."""
		go = s.get("game_object")
		if not go or not it["connect_style"]:
			return {}
		out = {}
		pole_k = s["primary"]
		if go["fence"]:
			f = go["fence"]
			pk = {name: self.apk_by.get((go["sc"], ex)) for name, ex in f.items() if ex}
			pk["pole"] = pole_k
			if mirror:   # mirrored art swaps the axes
				pk["below"], pk["right"] = pk.get("right"), pk.get("below")
			for mask in range(16):
				se, sw = bool(mask & 2), bool(mask & 4)
				name = "corner" if se and sw else ("right" if se else ("below" if sw else "pole"))
				k = pk.get(name)
				if not k and name == "corner":
					k, name = pk.get("pole"), "pole"
				if k:
					out[mask] = (k, name)
			return out
		if go["ditch"]:
			for mask, ex in go["ditch"].items():
				k = self.apk_by.get((go["sc"], ex)) if ex else None
				if k:
					m = mask
					if mirror:
						m = ((mask & 1) << 3) | ((mask & 8) >> 3) | ((mask & 2) << 1) | ((mask & 4) >> 1)
					out[m] = (k, f"m{m:02d}")
			return out
		return {}

	# --- output
	def write_pack(self, jobs: list[dict]):
		pd = self.packdir
		if self.args.rebuild and pd.exists():
			shutil.rmtree(pd)
		for sub in ("items", "thumbs", "review"):
			(pd / sub).mkdir(parents=True, exist_ok=True)
		# review images
		rjobs, rentries = self._review_plan()
		log(f"rendering {len(jobs)} sprite images + {len(rjobs)} review images ({self.workers} workers)")
		t0 = time.time()
		results = {}
		with mp.Pool(self.workers) as pool:
			for i, res in enumerate(pool.imap_unordered(render_job, jobs + rjobs, chunksize=4), 1):
				results[res["id"]] = res
				if i % 1000 == 0:
					log(f"  rendered {i}/{len(jobs) + len(rjobs)} ({time.time() - t0:.0f}s)")
		log(f"rendered in {time.time() - t0:.0f}s")
		errors = {k: v["error"] for k, v in results.items() if "error" in v}
		self.render_errors = errors
		sprites = {}
		self.render_notes = {}
		for key, e in sorted(self.entries.items()):
			ent = dict(e["entry"])
			res = results.get(key)
			if not res or "error" in res:
				continue
			out = {"file": res["file"], "anchor": res["anchor"], "pixels_per_world_px": res["ppw"]}
			if res.get("thumb"):
				out["thumb"] = res["thumb"]
			if res.get("notes"):
				self.render_notes[key] = res["notes"]
			for f in ("auto_anchor", "verified", "verified_by", "mirrored", "composite", "source", "match"):
				if f in ent and ent[f] not in (None, False) or f == "auto_anchor":
					out[f] = ent.get(f, False)
			if ent.get("variants"):
				vs = {}
				for vid, vd in ent["variants"].items():
					vr = results.get(f"{key}|v|{vid}")
					if not vr or "error" in vr:
						continue
					vs[vid] = {"file": vr["file"], "anchor": vr["anchor"], "pixels_per_world_px": vr["ppw"],
						"thumb": vr.get("thumb"), "auto_anchor": vd["auto_anchor"], "source": vd["source"]}
				if vs:
					out["variants"] = vs
			if ent.get("connections"):
				cs = {}
				for mask, cd in ent["connections"].items():
					if cd["piece"] == "@base":
						cs[mask] = {"file": out["file"], "anchor": out["anchor"], "pixels_per_world_px": out["pixels_per_world_px"]}
						continue
					cres = results.get(f"{key}|c|{cd['piece']}")
					if cres is None or "error" in cres:
						continue
					cs[mask] = {"file": cres["file"], "anchor": cres["anchor"], "pixels_per_world_px": cres["ppw"]}
				if cs:
					out["connections"] = dict(sorted(cs.items(), key=lambda x: int(x[0])))
					tp = ent.get("thumb_piece")
					tres = results.get(f"{key}|c|{tp}") if tp else None
					if tres and tres.get("thumb"):
						out["thumb"] = tres["thumb"]
			sprites[key] = out
		self.sprites = sprites
		review_items = []
		for re_ in rentries:
			res = results.get(re_["job_id"])
			if res and "error" not in res:
				review_items.append({"file": res["file"], "suggestions": re_["suggestions"], "reason": re_["reason"],
					"source_key": re_["source_key"], "anchor_hint": res["anchor"], "pixels_per_world_px": res["ppw"]})
		self.review_items = review_items
		# stale files
		live = set()
		for sp in sprites.values():
			live.add(sp["file"])
			if sp.get("thumb"):
				live.add(sp["thumb"])
			for v in (sp.get("variants") or {}).values():
				live.add(v["file"])
				if v.get("thumb"):
					live.add(v["thumb"])
			for c in (sp.get("connections") or {}).values():
				live.add(c["file"])
		live |= {ri["file"] for ri in review_items}
		removed = 0
		for sub in ("items", "thumbs", "review"):
			for p in (pd / sub).glob("*"):
				if f"{sub}/{p.name}" not in live:
					p.unlink()
					removed += 1
		# the version changes whenever an entry OR an image changes (e.g. re-encoded edges)
		img_sums = sorted(f"{k}:{v.get('sha256', '')}:{v.get('thumb_sha256', '')}" for k, v in results.items() if "error" not in v)
		digest = hashlib.sha256((json.dumps(sprites, sort_keys=True) + "\n".join(img_sums)).encode()).hexdigest()[:8]
		prev = read_json(pd / "pack.json", {}) or {}
		pv = str(prev.get("version", ""))
		version = pv if pv.endswith("-" + digest) else dt.datetime.now(dt.timezone.utc).strftime("%Y.%m.%d") + "-" + digest
		pack = {"format": "hayday-sandbox-asset-pack", "schema_version": 1, "id": PACK_ID, "name": PACK_NAME,
			"license": LICENSE, "art_kind": "original", "priority": 100, "version": version,
			"pixels_per_world_px": MAX_PPW, "alpha_bleed": True,
			"provenance": {"generated": now_iso(), "tool": f"tools/private_assets/build_pack.py {TOOL_VERSION}",
				"private_root": str(self.root), "client_build": self.game_version,
				"sources": self.src_meta.get("sources", {}),
				"note": "PRIVATE personal-use pack built from original Supercell art. Never commit, share or redistribute."},
			"sprites": sprites}
		write_json(pd / "pack.json", pack)
		write_json(pd / "review.json", {"items": review_items, "generated": now_iso(),
			"note": "Images the builder could not match automatically. Assign them in the Asset Manager (review queue)."})
		hashes = {"generated": now_iso(), "pack": PACK_ID,
			"note": "sha256 of every output file and every source image, for leak checks (PRIVATE).", "outputs": {}, "sources": {}}
		for p in sorted(pd.rglob("*")):
			if p.is_file() and p.name != "hashes.json":
				hashes["outputs"][str(p.relative_to(pd))] = sha256_file(p)
		for k, r in sorted(self.inv.items()):
			sha = (r.get("img") or {}).get("sha256")
			if sha:
				hashes["sources"][k] = sha
		write_json(pd / "hashes.json", hashes, indent=None)
		self.pack_version = version
		self.stale_removed = removed
		log(f"pack: {len(sprites)} sprites, {sum(len(s.get('variants', {})) for s in sprites.values())} variants, "
			f"{sum(len(s.get('connections', {})) for s in sprites.values())} connection entries, {len(review_items)} review "
			f"images; {len(errors)} render errors; {removed} stale files removed")

	def _review_plan(self):
		"""Review queue: medium matches and unmatched client objects / object-like images with suggestions."""
		inv, D = self.inv, self.decisions
		have = set(self.sel)
		jobs, entries = [], []
		for k, d in sorted(D.items()):
			r = inv.get(k)
			if not r:
				continue
			img = r.get("img") or {}
			if img.get("error") or not img.get("alpha_used"):
				continue
			reason = None
			sugg = [s for s in (d.get("suggestions") or []) if s in self.cat.by_id]
			if d.get("status") == "review":
				if sugg and all(s in have and self.decisions[self.sel[s]["primary"]].get("confidence") in ("exact", "user") for s in sugg):
					continue   # every suggested item already has exact art
				reason = d.get("reason") or f"{d.get('method')} ({d.get('confidence')})"
			elif d.get("status") == "unmatched" and d.get("role") == "game_object_not_in_catalog":
				reason = d.get("reason")
			elif d.get("status") == "unmatched" and d.get("role") == "no_match" and r["source"] == "fankit" and sugg:
				missing = [s for s in sugg if s not in have]
				if not missing:
					continue
				sugg = missing
				reason = "fan kit image without a confident match; suggestions lack art"
			if not reason:
				continue
			d["in_review_queue"] = True
			name = f"review/{r['source']}_{slug(r['title'], 40)}_{short_hash(k)}.webp"
			if r["source"] == "apk":
				gfp = tuple(d.get("game_fp") or (1, 1))
				anchor = self._apk_anchor(r, gfp)
				ppw = float(r["apk"]["ppw"])
				j = {"id": f"review|{k}", "src": r["path"], "anchor": list(anchor), "ppw": ppw, "rel": name,
					"out": str(self.packdir / name), "max_ppw": MAX_PPW}
			else:
				bb = img.get("bbox") or [0, 0, img.get("w", 1), img.get("h", 1)]
				j = {"id": f"review|{k}", "src": r["path"], "anchor": [(bb[0] + bb[2]) / 2, bb[3]], "ppw": 1.0, "rel": name,
					"out": str(self.packdir / name), "max_side": REVIEW_MAX_SIDE}
			jobs.append(j)
			entries.append({"job_id": j["id"], "suggestions": sugg[:5], "reason": reason, "source_key": k})
		return jobs, entries

	def install_pack(self):
		if not self.install:
			return
		dst = self.install
		dst.parent.mkdir(parents=True, exist_ok=True)
		tmp = dst.parent / f".{dst.name}.installing"
		if tmp.exists():
			shutil.rmtree(tmp)
		shutil.copytree(self.packdir, tmp)
		if dst.exists():
			ov = dst / "overrides.json"
			if ov.exists():
				shutil.copy2(ov, tmp / "overrides.json")
			old = dst.parent / f".{dst.name}.old"
			if old.exists():
				shutil.rmtree(old)
			os.replace(dst, old)
			os.replace(tmp, dst)
			shutil.rmtree(old)
		else:
			os.replace(tmp, dst)
		log(f"installed into {dst} (overrides.json preserved: {(dst / 'overrides.json').exists()})")

	# --- reports
	def write_mapping(self):
		D = self.decisions
		counts = collections.Counter((d.get("status"), self.inv.get(k, {}).get("source", "?")) for k, d in D.items())
		write_json(self.mapdir / "mapping.json", {"generated": now_iso(), "tool": f"build_pack.py {TOOL_VERSION}",
			"note": "PRIVATE. status: auto|confirmed|rejected|review|unmatched. confirmed/rejected are human decisions and "
				"are never overridden by automation. Edit confirmed/rejected here, or use the app's Asset Manager "
				"(overrides.json is merged on the next build with --install-dir).",
			"counts": {f"{s}:{src}": n for (s, src), n in sorted(counts.items(), key=str)},
			"decisions": dict(sorted(D.items()))})

	def write_calibration_report(self):
		rep = {"generated": now_iso(),
			"client_geometry": {"rule": "registration point = top (north) corner of the footprint; 1 tile = 128x64 SC "
				"units; pixels_per_world_px = 2 * render scale; anchor = origin + scale*((W-H)*32, (W+H)*16) using the "
				"game's TileWidth/TileHeight (W along +x / screen lower-right, verified on non-square objects)",
				"build": self.game_version},
			"client_ground_truth_by_category": self.gt, "client_ground_truth_all": self.gt_all,
			"definitions": {"k_w": "solid-bbox width / footprint diamond width (art overhang factor)",
				"c_b": "(solid-bbox bottom - anchor y) / half-diamond height", "x_off": "(bbox centre - anchor x) / diamond width",
				"ppw_footprint_est": "solid-bbox width px / ((w+h)*32) for client renders (catalogue footprint trusted)",
				"fankit_rel_scale": "Fan Kit/wiki solid width (px) / client solid width (world px) for pHash duplicates"},
			"named_source_scale_vs_client": {"by_category": self.scale_stats, "all": self.scale_all},
			"named_source_footprint_ratio": self.fpfit_stats,
			"common_scale_groups": {f"{s}|{c}": v for (s, c), v in self.common_scale.items()},
			"policy": ("client renders: exact registration point and the game's own scale (3 px/world px, downscaled "
				"to 2). Fan Kit/wiki: category median scale where a (source, category) group has >=5 duplicate pairs "
				"with relative IQR <= 0.15, otherwise per-item footprint fitting with the client-derived k_w/c_b "
				"(flagged auto_anchor). Exception: a seasonal/edition image whose base object has a single-export "
				"client render with the same footprint and a similar shape (aspect within 30 %) takes that render's "
				"visible world width and anchor position (method sibling_client_render)."),
			"phash": self.phash_stats,
			"footprint_mismatch_catalog_vs_game": self.fp_mismatch,
			"mirrored_to_fit_catalog": sorted(self.mirrored_items),
			"render_notes": getattr(self, "render_notes", {}),
			"items": self.cal_rows}
		write_json(self.mapdir / "calibration_report.json", rep)

	def coverage(self, built: bool):
		D, inv = self.decisions, self.inv
		items = self.items
		sprites = getattr(self, "sprites", {})
		cats = collections.OrderedDict()
		for c in sorted(self.categories.values(), key=lambda c: c.get("order", 99)):
			cats[c["id"]] = {"name": c["name"], "group": c.get("group"), "total": 0, "matched": 0, "client": 0,
				"named_only": 0, "variants": 0, "alternates": 0, "placeholder": 0, "fp_unverified": 0, "review": 0}
		review_items = collections.defaultdict(int)
		for k, d in D.items():
			if d.get("status") == "review":
				for s in d.get("suggestions") or []:
					review_items[s] += 1
		placeholders = []
		alt_items = []
		for it in items:
			c = cats.setdefault(it["category"], {"name": it["category"], "total": 0, "matched": 0, "client": 0,
				"named_only": 0, "variants": 0, "alternates": 0, "placeholder": 0, "fp_unverified": 0, "review": 0})
			c["total"] += 1
			if not it["fp_trusted"]:
				c["fp_unverified"] += 1
			s = self.sel.get(it["id"])
			has = (it["art_key"] in sprites) if built else (s is not None)
			if has:
				c["matched"] += 1
				src = inv[s["primary"]]["source"]
				if src == "apk":
					c["client"] += 1
				else:
					c["named_only"] += 1
				if s["variants"]:
					c["variants"] += 1
				if s["alternates"]:
					c["alternates"] += 1
					alt_items.append(it["id"])
			else:
				c["placeholder"] += 1
				placeholders.append({"id": it["id"], "name": it["name"], "category": it["category"],
					"review_candidates": review_items.get(it["id"], 0)})
			if review_items.get(it["id"]) and not has:
				c["review"] += 1
		st = collections.Counter()
		by_src = collections.defaultdict(collections.Counter)
		for k, d in D.items():
			st[d.get("status")] += 1
			by_src[inv.get(k, {}).get("source", "?")][d.get("status")] += 1
		roles = collections.Counter(d.get("role") for d in D.values())
		complete = set()
		for k, r in inv.items():
			img = r.get("img") or {}
			if not img.get("alpha_used") or img.get("error"):
				continue
			d = D.get(k, {})
			if d.get("role") in ("not_object", "older_build", "part", "connection", "unreadable", "opaque"):
				continue
			if r["source"] == "fankit" and d.get("role") == "not_object":
				continue
			complete.add(img.get("sha256"))
		verified = sum(1 for sp in sprites.values() if sp.get("verified"))
		qa_verified = sum(1 for sp in sprites.values() if sp.get("verified") and sp.get("verified_by") == "qa")
		mis = self.fp_mismatch
		cov = {"generated": now_iso(), "pack_version": getattr(self, "pack_version", None), "built": built,
			"catalog_items": len(items),
			"pipeline": {
				"files_found": {k: v.get("files_found") for k, v in self.src_meta["sources"].items()},
				"acquired": {k: v.get("acquired") for k, v in self.src_meta["sources"].items()},
				"inventoried": len(inv),
				"unique_complete_sprites": len(complete),
				"matched_items": sum(1 for it in items if (it["art_key"] in sprites if built else it["id"] in self.sel)),
				"visually_verified": verified,
				"rendered_in_app": None},
			"decisions_by_status": dict(st), "decisions_by_source": {k: dict(v) for k, v in by_src.items()},
			"decisions_by_role": dict(roles),
			"items_auto": sum(1 for iid, s in self.sel.items() if D[s["primary"]].get("status") == "auto"),
			"items_confirmed": sum(1 for iid, s in self.sel.items() if D[s["primary"]].get("status") == "confirmed"),
			"items_qa_verified": qa_verified,
			"items_with_review_candidates_only": sum(1 for p in placeholders if p["review_candidates"]),
			"review_queue_images": len(getattr(self, "review_items", [])),
			"items_by_primary_source": dict(collections.Counter(inv[s["primary"]]["source"] for s in self.sel.values())),
			"items_with_variants": sum(1 for s in self.sel.values() if s["variants"]),
			"items_with_alternate_artwork": len(alt_items), "alternate_items": sorted(alt_items),
			"items_with_connections": sum(1 for sp in sprites.values() if sp.get("connections")),
			"connection_items_without_pieces": sorted(it["id"] for it in items if it["connect_style"] and it["id"] in self.sel
				and not self._connection_plan(it, self.sel[it["id"]], False)),
			"composites": sorted(k for k, sp in sprites.items() if sp.get("composite")),
			"remaining_placeholders": len(placeholders), "placeholder_items": placeholders,
			"footprint_unverified_items": sum(1 for it in items if not it["fp_trusted"]),
			"footprint_unverified_with_art": sum(1 for it in items if not it["fp_trusted"] and it["id"] in self.sel),
			"footprint_mismatch_catalog_vs_game": len(mis),
			"mirrored_to_fit_catalog": len(self.mirrored_items),
			"categories": cats,
			"snapshots": {k: v.get("fetched_at") for k, v in self.src_meta["sources"].items()},
			"render_errors": getattr(self, "render_errors", {}),
			"elapsed_s": round(time.time() - self.t0, 1)}
		chk = read_json(self.mapdir / "godot_load_check.json", {}) or {}
		if built and chk.get("pack_stats", {}).get("version") == cov["pack_version"]:
			cov["pipeline"]["rendered_in_app"] = chk.get("base_sprites_loaded")
			cov["app_check"] = {k: (len(v) if isinstance(v, list) else v) for k, v in chk.items() if k != "pack_stats"}
		write_json(self.mapdir / "coverage.json", cov)
		self.cov = cov
		write_dashboard(self.root, cov, sprites, self.cat, self.decisions, self.inv, self.sel)
		return cov

	def contact_sheets(self):
		out_dir = self.root / "review_sheets"
		out_dir.mkdir(parents=True, exist_ok=True)
		sprites = self.sprites
		ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
		rng = np.random.default_rng(11)
		by_cat = collections.defaultdict(list)
		for key, sp in sprites.items():
			iid = self.entries[key]["item"]
			if not sp.get("connections"):
				by_cat[self.cat.by_id[iid]["category"]].append(key)
		pick = []
		order = list(by_cat)
		quota = {c: 4 for c in order}
		for c in ("production", "farm_building", "animal_home", "fruit_tree", "bush", "decoration", "seasonal"):
			quota[c] = 7 if c in ("production", "decoration", "seasonal") else 5
		for c in order:
			lst = sorted(by_cat[c])
			n = min(len(lst), quota.get(c, 4))
			pick += [lst[i] for i in rng.choice(len(lst), n, replace=False)]
		named = sorted(k for k, sp in sprites.items() if sp.get("source", {}).get("kind") != "apk")
		pick += [k for k in named[:8] if k not in pick]
		pick = pick[:64]
		paths = [out_dir / f"contact_{ts}_objects.png"]
		self._sheet(pick, paths[0])
		fences = sorted(k for k, sp in sprites.items() if sp.get("connections"))
		if fences:
			sel = [fences[i] for i in sorted(rng.choice(len(fences), min(12, len(fences)), replace=False))]
			paths.append(out_dir / f"contact_{ts}_connections.png")
			self._conn_sheet(sel, paths[-1])
		withv = sorted(k for k, sp in sprites.items() if sp.get("variants"))
		if withv:
			pickv = [withv[i] for i in sorted(rng.choice(len(withv), min(12, len(withv)), replace=False))]
			for must in ("barn", "silo", "bakery", "beehive_tree"):
				if must in sprites and must not in pickv and sprites[must].get("variants"):
					pickv[len(pickv) - 1 - ("barn", "silo", "bakery", "beehive_tree").index(must)] = must
			paths.append(out_dir / f"contact_{ts}_variants.png")
			self._variant_sheet(pickv, paths[-1])
		self.sheet_paths = [str(p) for p in paths]
		log("contact sheets: " + ", ".join(self.sheet_paths))

	def _sheet(self, keys, path, cw=300, ch=300, cols=8):
		rows = (len(keys) + cols - 1) // cols
		sheet = Image.new("RGB", (cw * cols, ch * rows), (30, 30, 30))
		for i, key in enumerate(keys):
			sp = self.sprites[key]
			iid = self.entries[key]["item"]
			it = self.cat.by_id[iid]
			cell = Image.new("RGBA", (cw, ch), (96, 140, 72, 255))
			im = Image.open(self.packdir / sp["file"]).convert("RGBA")
			ppw = sp["pixels_per_world_px"]
			w, h = it["fp"]
			# fit: world -> cell scale
			wext = max((w + h) * HALF_W * 1.4, im.width / ppw, im.height / ppw * 1.3)
			z = (cw - 20) / wext
			f = z / ppw
			sim = im.resize((max(1, int(im.width * f)), max(1, int(im.height * f))), Image.Resampling.LANCZOS)
			cx, cy = cw / 2, ch * 0.62
			d = ImageDraw.Draw(cell)
			pts = []
			for gx, gy in ((0, 0), (w, 0), (w, h), (0, h)):
				wx, wy = (gx - gy) * HALF_W, (gx + gy) * HALF_H
				pts.append((cx + (wx - (w - h) * HALF_W / 2) * z, cy + (wy - (w + h) * HALF_H / 2) * z))
			d.polygon(pts, fill=(120, 165, 90, 255), outline=(255, 230, 0, 255))
			ax, ay = sp["anchor"]
			cell.alpha_composite(sim, (int(round(cx - ax * f)), int(round(cy - ay * f))))
			d = ImageDraw.Draw(cell)
			d.polygon(pts, outline=(255, 230, 0, 255))
			d.line([(cx - 6, cy), (cx + 6, cy)], fill=(255, 0, 0, 255), width=2)
			d.line([(cx, cy - 6), (cx, cy + 6)], fill=(255, 0, 0, 255), width=2)
			src = sp.get("source", {}).get("kind", "?")
			d.rectangle([0, 0, cw, 26], fill=(0, 0, 0, 160))
			d.text((3, 1), f"{iid[:40]}", fill=(255, 255, 255, 255))
			d.text((3, 13), f"{it['category']} {w}x{h} {src} {'auto' if sp.get('auto_anchor') else 'exact'}", fill=(200, 220, 255, 255))
			sheet.paste(cell.convert("RGB"), ((i % cols) * cw, (i // cols) * ch))
		sheet.save(path)

	def _variant_sheet(self, keys, path, cw=200, ch=230, per_row=6):
		"""One row per item: base + up to 5 variants, each on its footprint with the anchor cross."""
		sheet = Image.new("RGB", (cw * per_row, ch * len(keys)), (30, 30, 30))
		for row, key in enumerate(keys):
			sp = self.sprites[key]
			iid = self.entries[key]["item"]
			it = self.cat.by_id[iid]
			ents = [("@base", sp)] + list((sp.get("variants") or {}).items())[: per_row - 1]
			for col, (vid, e) in enumerate(ents):
				cell = Image.new("RGBA", (cw, ch), (96, 140, 72, 255))
				im = Image.open(self.packdir / e["file"]).convert("RGBA")
				ppw = e.get("pixels_per_world_px", sp["pixels_per_world_px"])
				w, h = it["fp"]
				z = (cw - 16) / max((w + h) * HALF_W * 1.5, 1)
				f = z / ppw
				sim = im.resize((max(1, int(im.width * f)), max(1, int(im.height * f))), Image.Resampling.LANCZOS)
				cx, cy = cw / 2, ch * 0.7
				d = ImageDraw.Draw(cell)
				pts = [(cx + ((gx - gy) * HALF_W - (w - h) * HALF_W / 2) * z, cy + ((gx + gy) * HALF_H - (w + h) * HALF_H / 2) * z)
					for gx, gy in ((0, 0), (w, 0), (w, h), (0, h))]
				d.polygon(pts, fill=(120, 165, 90, 255), outline=(255, 230, 0, 255))
				ax, ay = e["anchor"]
				cell.alpha_composite(sim, (int(round(cx - ax * f)), int(round(cy - ay * f))))
				d = ImageDraw.Draw(cell)
				d.line([(cx - 5, cy), (cx + 5, cy)], fill=(255, 0, 0, 255), width=2)
				d.line([(cx, cy - 5), (cx, cy + 5)], fill=(255, 0, 0, 255), width=2)
				d.rectangle([0, 0, cw, 14], fill=(0, 0, 0, 160))
				d.text((3, 1), f"{iid[:18]} {vid[:14]}", fill=(255, 255, 255, 255))
				sheet.paste(cell.convert("RGB"), (col * cw, row * ch))
		sheet.save(path)

	def _conn_sheet(self, keys, path, cw=420, ch=300, cols=4):
		# a small closed loop (3x3 ring) plus a spur, so every mask class appears
		tiles = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1), (3, 1)]
		tset = set(tiles)
		rows = (len(keys) + cols - 1) // cols
		sheet = Image.new("RGB", (cw * cols, ch * rows), (30, 30, 30))
		for i, key in enumerate(keys):
			sp = self.sprites[key]
			iid = self.entries[key]["item"]
			cell = Image.new("RGBA", (cw, ch), (96, 140, 72, 255))
			d = ImageDraw.Draw(cell)
			z = 1.0
			ox, oy = cw / 2 - 16, 70
			for gx in range(-1, 5):
				for gy in range(-1, 4):
					x0, y0 = ox + (gx - gy) * HALF_W * z, oy + (gx + gy) * HALF_H * z
					d.polygon([(x0, y0), (x0 + HALF_W * z, y0 + HALF_H * z), (x0, y0 + 2 * HALF_H * z), (x0 - HALF_W * z, y0 + HALF_H * z)], outline=(80, 120, 60, 255))
			cache = {}
			for (tx, ty) in sorted(tiles, key=lambda t: (t[0] + t[1], t[0])):
				mask = (1 if (tx, ty - 1) in tset else 0) | (2 if (tx + 1, ty) in tset else 0) | (4 if (tx, ty + 1) in tset else 0) | (8 if (tx - 1, ty) in tset else 0)
				conns = sp["connections"]
				c = conns.get(str(mask)) or conns.get("0") or sp
				f = z / c["pixels_per_world_px"]
				if c["file"] not in cache:
					im = Image.open(self.packdir / c["file"]).convert("RGBA")
					cache[c["file"]] = im.resize((max(1, int(im.width * f)), max(1, int(im.height * f))), Image.Resampling.LANCZOS)
				sim = cache[c["file"]]
				cx, cy = ox + (tx - ty) * HALF_W * z, oy + (tx + ty + 1) * HALF_H * z
				cell.alpha_composite(sim, (int(round(cx - c["anchor"][0] * f)), int(round(cy - c["anchor"][1] * f))))
			d = ImageDraw.Draw(cell)
			d.rectangle([0, 0, cw, 14], fill=(0, 0, 0, 160))
			d.text((3, 1), f"{iid} ({len(sp['connections'])} masks)", fill=(255, 255, 255, 255))
			sheet.paste(cell.convert("RGB"), ((i % cols) * cw, (i // cols) * ch))
		sheet.save(path)


# ------------------------------------------------------------------------------------------------- app check
GODOT_CHECK_GD = r'''extends SceneTree
## Loads the installed private pack through the app's own AssetLibrary and counts what resolves.
## Writes a JSON report to the path in the HD_CHECK_OUT environment variable (outside the repo).

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var db := ItemDatabase.new()
	db.load_default()
	var lib := AssetLibrary.new()
	lib.load_all(db)
	var pack := lib.pack_by_id("hayday_original")
	var out := {"pack_found": not pack.is_empty(), "errors_after_load": Array(lib.errors), "items": db.count()}
	if pack.is_empty():
		_finish(out, t0)
		return
	var st := lib.pack_stats("hayday_original")
	out["pack_stats"] = st
	var from_pack := 0
	var loaded := 0
	var null_sprites := []
	var variants_ok := 0
	var variants_bad := []
	var conn_ok := 0
	var conn_bad := []
	var thumbs := 0
	var bad_size := []
	var n := 0
	for it: ItemDef in db.ordered:
		if lib.art_source(it.art_key) != "hayday_original":
			continue
		from_pack += 1
		var info := lib.get_sprite(it.art_key, AssetLibrary.BASE_VARIANT)
		if info == null or info.texture == null:
			null_sprites.append(it.id)
		else:
			loaded += 1
			var sz := info.texture.get_size() * info.scale
			if sz.x < 4 or sz.y < 4 or sz.x > 2000 or sz.y > 2000:
				bad_size.append([it.id, sz.x, sz.y])
		if lib.get_thumbnail(it.art_key) != null:
			thumbs += 1
		for v in lib.variants_of(it.art_key):
			var vi := lib.get_sprite(it.art_key, v)
			if vi != null and vi.variant == v:
				variants_ok += 1
			else:
				variants_bad.append("%s/%s" % [it.id, v])
		var masks := lib.connection_masks(it.art_key)
		for m in masks:
			var ci := lib.get_sprite(it.art_key, "", int(m))
			if ci != null and ci.texture != null:
				conn_ok += 1
			else:
				conn_bad.append("%s/%d" % [it.id, int(m)])
		n += 1
		if n % 300 == 0:
			lib.clear_cache()
	out["items_resolved_to_pack"] = from_pack
	out["base_sprites_loaded"] = loaded
	out["base_sprites_null"] = null_sprites
	out["thumbnails_loaded"] = thumbs
	out["variants_ok"] = variants_ok
	out["variants_bad"] = variants_bad
	out["connections_ok"] = conn_ok
	out["connections_bad"] = conn_bad
	out["implausible_world_size"] = bad_size
	out["review_queue"] = lib.review_queue("hayday_original").size()
	out["missing_files"] = lib.missing_files("hayday_original")
	out["errors_total"] = lib.errors.size()
	out["errors_sample"] = Array(lib.errors).slice(0, 20)
	_finish(out, t0)


func _finish(out: Dictionary, t0: int) -> void:
	out["elapsed_ms"] = Time.get_ticks_msec() - t0
	var path := OS.get_environment("HD_CHECK_OUT")
	var txt := JSON.stringify(out, "  ")
	if not path.is_empty():
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(txt)
		f.close()
	print("PACK-CHECK items=%s from_pack=%s loaded=%s variants_ok=%s conn_ok=%s missing=%s" % [out.get("items"),
		out.get("items_resolved_to_pack"), out.get("base_sprites_loaded"), out.get("variants_ok"),
		out.get("connections_ok"), (out.get("missing_files", []) as Array).size()])
	quit(0)
'''


def run_app_check(root: Path, install: Path, out_json: Path) -> dict:
	"""Load the installed pack through the app's own AssetLibrary in headless Godot (read-only)."""
	godot = shutil.which(os.environ.get("GODOT", "godot"))
	if not godot:
		log("app check skipped: godot not on PATH")
		return {}
	script = root / "tmp" / "godot_pack_check.gd"
	script.parent.mkdir(parents=True, exist_ok=True)
	script.write_text(GODOT_CHECK_GD, encoding="utf-8")
	env = dict(os.environ, HD_CHECK_OUT=str(out_json))
	if install.parent.name == "asset_packs" and install.parent.parent.name == "HaydaySandbox":
		env["XDG_DATA_HOME"] = str(install.parent.parent.parent)
	import subprocess
	t0 = time.time()
	res = subprocess.run([godot, "--headless", "--path", str(REPO_ROOT), "--script", str(script)], env=env,
		capture_output=True, text=True, timeout=1800)
	line = next((ln for ln in res.stdout.splitlines() if ln.startswith("PACK-CHECK")), "")
	log(f"app check ({time.time() - t0:.0f}s): {line or 'no result'}")
	return read_json(out_json, {}) or {}


# ------------------------------------------------------------------------------------------------- dashboard
def write_dashboard(root: Path, cov: dict, sprites: dict, cat: CatalogIndex, D: dict, inv: dict, sel: dict):
	out = root / "dashboard" / "index.html"
	out.parent.mkdir(parents=True, exist_ok=True)
	esc = html.escape
	p = cov["pipeline"]
	total = cov["catalog_items"]
	matched = p["matched_items"]

	def tile(label, value, sub=""):
		return f'<div class="tile"><div class="v">{esc(str(value))}</div><div class="l">{esc(label)}</div><div class="s">{esc(sub)}</div></div>'

	acq = p["acquired"]
	found = p["files_found"]
	src_rows = "".join(f"<tr><td>{esc(k)}</td><td>{esc(str(found.get(k)))}</td><td>{esc(str(acq.get(k)))}</td>"
		f"<td>{esc(str(cov['snapshots'].get(k) or ''))}</td></tr>" for k in acq)
	cat_rows = []
	for cid, c in cov["categories"].items():
		if not c.get("total"):
			continue
		pct_ = 100.0 * c["matched"] / c["total"]
		cat_rows.append(f"<tr><td>{esc(c['name'])}</td><td class=n>{c['total']}</td><td class=n>{c['matched']}</td>"
			f"<td><div class=bar><div style='width:{pct_:.1f}%'></div></div><span class=pc>{pct_:.0f}%</span></td>"
			f"<td class=n>{c['client']}</td><td class=n>{c['named_only']}</td><td class=n>{c['variants']}</td>"
			f"<td class=n>{c['alternates']}</td><td class=n>{c['placeholder']}</td><td class=n>{c['fp_unverified']}</td></tr>")
	st = cov["decisions_by_status"]
	ph_rows = "".join(f"<li><b>{esc(x['name'])}</b> <span class=m>{esc(x['id'])} · {esc(x['category'])}"
		f"{' · ' + str(x['review_candidates']) + ' review candidate(s)' if x['review_candidates'] else ''}</span></li>"
		for x in cov["placeholder_items"][:400])
	thumbs = []
	keys = sorted(sprites)
	step = max(1, len(keys) // 120)
	for key in keys[::step][:120]:
		sp = sprites[key]
		if not sp.get("thumb"):
			continue
		src = sp.get("source", {}).get("kind", "")
		thumbs.append(f'<figure><img loading="lazy" src="../packs/{PACK_ID}/{esc(sp["thumb"])}" alt=""><figcaption>'
			f'{esc(key)}<br><span class=m>{esc(src)}{" · auto" if sp.get("auto_anchor") else ""}</span></figcaption></figure>')
	gen = esc(cov["generated"])
	body = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Original art coverage</title><style>
:root{{--bg:#f6f4ef;--card:#fff;--ink:#22201c;--mut:#6d675e;--line:#e3ded4;--acc:#4f8a3a;--acc2:#d08a2e;--warn:#b5462f}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1b1a17;--card:#25231f;--ink:#ece8df;--mut:#a39d92;--line:#3a3731;--acc:#7cbf5e;--acc2:#e3a24a;--warn:#e07a62}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}}
main{{max-width:1180px;margin:0 auto;padding:24px 16px 64px}}h1{{font-size:22px;margin:0 0 4px}}h2{{font-size:16px;margin:28px 0 10px}}
.m,.s{{color:var(--mut);font-size:12px}}.banner{{background:var(--warn);color:#fff;border-radius:8px;padding:8px 12px;margin:12px 0;font-weight:600}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:10px}}
.tile{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}}.tile .v{{font-size:24px;font-weight:700}}.tile .l{{font-weight:600}}
table{{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}}
th,td{{padding:6px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:middle}}th{{font-size:12px;color:var(--mut);font-weight:600}}
td.n{{text-align:right;font-variant-numeric:tabular-nums}}.bar{{display:inline-block;width:110px;height:8px;background:var(--line);border-radius:4px;vertical-align:middle;overflow:hidden}}
.bar div{{height:100%;background:var(--acc)}}.pc{{margin-left:6px;font-size:12px;color:var(--mut)}}
.flow{{display:flex;flex-wrap:wrap;gap:6px;align-items:center}}.flow span{{background:var(--card);border:1px solid var(--line);border-radius:999px;padding:4px 10px}}
.flow b{{color:var(--acc)}}.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:8px}}
figure{{margin:0;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:6px;text-align:center}}figure img{{max-width:96px;max-height:96px}}
figcaption{{font-size:11px;word-break:break-all}}ul.ph{{columns:3 260px;padding-left:18px}}.wrap{{overflow-x:auto}}
</style></head><body><main>
<h1>Hay Day original art — private pack coverage</h1>
<div class="m">Generated {gen} · pack <code>{PACK_ID}</code> version {esc(str(cov.get('pack_version')))} · built={esc(str(cov['built']))}</div>
<div class="banner">PRIVATE — proprietary Supercell art for personal use only. Do not share, upload or redistribute this page or the pack.</div>
<h2>Pipeline</h2>
<div class="flow"><span>files found <b>{sum(v or 0 for v in found.values())}</b></span>→<span>acquired <b>{sum(v or 0 for v in acq.values())}</b></span>→
<span>unique complete sprites <b>{p['unique_complete_sprites']}</b></span>→<span>catalogue items matched <b>{matched}</b> / {total}</span>→
<span>visually verified (builder QA + you) <b>{p['visually_verified']}</b></span>→<span>loaded by the app (headless AssetLibrary) <b>{esc(str(p['rendered_in_app'] if p['rendered_in_app'] is not None else 'not checked'))}</b></span></div>
<h2>Summary</h2><div class="tiles">
{tile('Catalogue items', total)}{tile('Items with original art', matched, f'{100.0 * matched / max(1, total):.1f}%')}
{tile('Remaining placeholders', cov['remaining_placeholders'])}{tile('Auto-matched items', cov['items_auto'])}
{tile('Confirmed by you', cov['items_confirmed'], 'your decisions in the Asset Manager')}{tile('QA-verified by the builder', cov.get('items_qa_verified', 0), 'checked by eye in the app, not by you')}{tile('Review queue images', cov['review_queue_images'])}
{tile('Items with variants', cov['items_with_variants'])}{tile('Items with alternate artwork', cov['items_with_alternate_artwork'])}
{tile('Fences/paths with pieces', cov['items_with_connections'])}{tile('Footprint unverified', cov['footprint_unverified_items'], f"{cov['footprint_unverified_with_art']} of them have art")}
{tile('Catalogue vs game size differs', cov['footprint_mismatch_catalog_vs_game'], 'see calibration_report.json')}{tile('Decisions: review / unmatched', f"{st.get('review', 0)} / {st.get('unmatched', 0)}")}
</div>
<h2>Sources</h2><div class="wrap"><table><tr><th>Source</th><th>Files found</th><th>Acquired</th><th>Snapshot</th></tr>{src_rows}</table></div>
<h2>Matched items per category</h2><div class="wrap"><table><tr><th>Category</th><th>Items</th><th>Matched</th><th>Coverage</th><th>Client render</th><th>Fan Kit / wiki only</th><th>With variants</th><th>Alternates</th><th>Placeholder</th><th>Size unverified</th></tr>{''.join(cat_rows)}</table></div>
<h2>Sample of matched sprites</h2><div class="grid">{''.join(thumbs)}</div>
<h2>Remaining placeholders ({cov['remaining_placeholders']})</h2><ul class="ph">{ph_rows}</ul>
</main></body></html>"""
	out.write_text(body, encoding="utf-8")


# ------------------------------------------------------------------------------------------------- CLI
def print_report(root: Path) -> int:
	cov = read_json(root / "mapping" / "coverage.json")
	if not cov:
		print("no coverage.json yet - run the builder first")
		return 1
	p = cov["pipeline"]
	print(f"coverage generated {cov['generated']} (pack {cov.get('pack_version')}, built={cov.get('built')})")
	print(f"  catalogue items          {cov['catalog_items']}")
	print(f"  files found              {p['files_found']}")
	print(f"  acquired                 {p['acquired']}")
	print(f"  inventoried              {p['inventoried']}")
	print(f"  unique complete sprites  {p['unique_complete_sprites']}")
	print(f"  matched items            {p['matched_items']}  (by primary source {cov['items_by_primary_source']})")
	print(f"  visually verified        {p['visually_verified']}  (builder QA {cov.get('items_qa_verified', 0)}, "
		f"confirmed by you {cov.get('items_confirmed', 0)})")
	print(f"  rendered in app          {p['rendered_in_app']}")
	print(f"  remaining placeholders   {cov['remaining_placeholders']}")
	print(f"  decisions by status      {cov['decisions_by_status']}")
	print(f"  review queue images      {cov['review_queue_images']}")
	print(f"  items with variants      {cov['items_with_variants']}; alternates {cov['items_with_alternate_artwork']}; "
		f"with connections {cov['items_with_connections']}")
	print(f"  footprint unverified     {cov['footprint_unverified_items']}; catalogue vs game size differs "
		f"{cov['footprint_mismatch_catalog_vs_game']}")
	for cid, c in cov["categories"].items():
		if c.get("total"):
			print(f"    {cid:14s} {c['matched']:5d}/{c['total']:<5d} client {c['client']:4d} named {c['named_only']:3d} "
				f"placeholder {c['placeholder']:4d}")
	return 0


def main(argv=None) -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--root", type=Path, default=DEFAULT_ROOT, help=f"private root (default {DEFAULT_ROOT})")
	ap.add_argument("--install-dir", type=Path, default=None,
		help="install the pack here, e.g. ~/.local/share/HaydaySandbox/asset_packs/hayday_original (keeps overrides.json)")
	ap.add_argument("--rebuild", action="store_true", help="ignore the inventory cache and rewrite the pack from scratch")
	ap.add_argument("--only-match", action="store_true", help="inventory + matching + coverage only (no images written)")
	ap.add_argument("--report", action="store_true", help="print the last coverage summary and exit")
	ap.add_argument("--no-sheets", action="store_true", help="skip the review contact sheets")
	ap.add_argument("--app-check", action="store_true",
		help="after installing, load the pack with the app's AssetLibrary in headless Godot (needs --install-dir)")
	ap.add_argument("--workers", type=int, default=min(4, os.cpu_count() or 1))
	args = ap.parse_args(argv)
	root = ensure_private(args.root, "the private root")
	if args.report:
		return print_report(root)
	b = Builder(args)
	b.inventory()
	b.match()
	b.select()
	b.calibrate()
	if args.only_match:
		b.plan()
		b.write_mapping()
		b.write_calibration_report()
		b.coverage(built=False)
		print_report(root)
		return 0
	jobs = b.plan()
	b.write_pack(jobs)
	b.write_mapping()
	b.write_calibration_report()
	b.install_pack()
	if args.app_check and b.install:
		run_app_check(b.root, b.install, b.mapdir / "godot_load_check.json")
	b.coverage(built=True)
	if not args.no_sheets:
		b.contact_sheets()
	for n in b.notes:
		log(n)
	print_report(root)
	return 0


if __name__ == "__main__":
	mp.set_start_method("fork", force=True)
	sys.exit(main())
