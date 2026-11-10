#!/usr/bin/env python3
"""Classify the client records the price import could not match, and build PRIVATE catalogue additions.

PERSONAL USE ONLY. The input is the user's own Hay Day client data (tables, English texts, extracted sprites); every
output is game-derived and goes to the private root, never into the repository (the tool refuses a path inside a
git work tree). See docs/research/CLIENT_PRICES.md ("Records the catalogue does not have").

Input
  --review FILE   a client-price supplement or its report (user://private_data/client_prices.json or
                  client_price_report.json): its "review" list holds the records that were not applied.
  --tables DIR    the client's assets/data folder (default <root>/raw/apk_extracted/<build>/assets/data); the
                  English texts are read from ../localization/texts.csv.
  --sprites DIR   extracted client sprites (default <root>/raw/apk_sprites/<build>): an export with a sprite file
                  there has real art.
  --pack DIR      an art pack (default: the installed hayday_original): a catalogue item that already shows a
                  record's client export (matched by name similarity, e.g. a misspelt wiki name) makes the record a
                  duplicate of that item, never a new one.
Output
  <root>/qa/<date>/client_records/classification.json + .md   every review record with a class and the evidence
  <root>/research/catalog/client_additions.json                 the records added as catalogue items (build_pack.py
                                                                 merges them into the pack's catalog_overrides.json
                                                                 "additions"; the app adds them while the pack is on)

Classes (first rule that applies; the evidence is written per record):
  duplicate            the catalogue already has the object: the game text equals a catalogue name / tag, a
                       catalogue item already shows the record's art in the pack, or the record is ambiguous
                       between catalogue entries (your choice in Asset manager > Game data)
  variant              a yearly / numbered copy of another record, or a looser name match to a catalogue item
                       (review candidates exist): not added, listed for your choice
  out_of_scope_area    UseCase NHObj (neighborhood) or Valley, or a neighborhood export (nhobj_*)
  unreleased           placeholder art (sc/placeholders.sc) or an untranslated <TODO> text: not in the released game
  event_only           event mechanics rather than a farm object (seasonal event creatures)
  customization_component  appearance parts (never items; the importer keeps them apart, so normally none here)
  missing_farm_object  a main-farm object with complete data (English text, footprint, real art): ADDED
  incomplete           a main-farm object whose data is incomplete (no text, footprint or art): listed, not added

Facts written into an addition come from the client data only: name = English game text, footprint = TileWidth x
TileHeight (status game_data), unlock level, connect style for fence/path pieces (the same name rule
tools/catalog/build_catalog.py uses), category = water for WaterDeco, seasonal for a Theme, else the public
catalogue's keyword rule. "flippable" is true only when the client has a mirrored export (ExportNameMirror); prices
come from the client-price supplement, never from this file.

Usage
  python3 tools/private_assets/client_catalog.py --review ~/.local/share/HaydaySandbox/private_data/client_prices.json
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "catalog"))
from build_catalog import slug, subcategory  # noqa: E402  (the public catalogue's own naming rules)

DEFAULT_ROOT = Path(os.environ.get("HAYDAY_PRIVATE_ASSETS", "/root/hayday-sandbox-private-assets"))
FORMAT = "hayday-sandbox-client-additions"
CLASSES = ["missing_farm_object", "duplicate", "variant", "out_of_scope_area", "unreleased", "event_only",
	"customization_component", "incomplete"]
CLASS_TEXT = {
	"missing_farm_object": "Missing main-farm object (added privately)",
	"duplicate": "Duplicate of a catalogue item",
	"variant": "Variant (yearly copy or near-name of a catalogue item)",
	"out_of_scope_area": "Other area (neighborhood / valley)",
	"unreleased": "Not released (placeholder art or untranslated text)",
	"event_only": "Event mechanics (not a farm object)",
	"customization_component": "Appearance part",
	"incomplete": "Main-farm object with incomplete data (listed, not added)",
}
WATER_NOTE = ("In the game it is placed only in the river's water-decoration zones (client level data); this sandbox "
	"does not model those zones yet, so its placement check treats it like any other decoration.")


def norm(s: str) -> str:
	return re.sub(r"[^a-z0-9]+", "_", (s or "").lower()).strip("_")


def in_git_tree(p: Path) -> bool:
	p = p.resolve()
	for q in [p] + list(p.parents):
		if (q / ".git").exists():
			return True
	return False


def read_table(path: Path) -> dict[str, dict]:
	"""name (lower) -> first row of the group (row 2 = types, skipped)."""
	out: dict[str, dict] = {}
	if not path.is_file():
		return out
	with path.open(encoding="utf-8", newline="") as f:
		rows = list(csv.reader(f))
	if not rows:
		return out
	h = rows[0]
	for row in rows[2:]:
		if not row or not row[0].strip():
			continue
		out[row[0].strip().lower()] = {h[i]: row[i].strip() for i in range(min(len(h), len(row))) if row[i].strip()}
	return out


def read_texts(path: Path) -> dict[str, str]:
	out: dict[str, str] = {}
	if not path.is_file():
		return out
	with path.open(encoding="utf-8", newline="") as f:
		rows = list(csv.reader(f))
	en = rows[0].index("EN") if rows and "EN" in rows[0] else -1
	for row in rows[1:]:
		if en >= 0 and len(row) > en and row[0].startswith("TID_") and row[en].strip():
			out[row[0]] = row[en].strip()
	return out


def load_catalogue() -> tuple[dict, dict]:
	"""(id -> item, normalized name / tag / alias -> [ids]) of the public catalogue."""
	items: dict = {}
	for f in sorted((REPO_ROOT / "data" / "items").glob("*.json")):
		if f.name == "categories.json":
			continue
		for it in json.loads(f.read_text(encoding="utf-8")).get("items", []):
			items[it["id"]] = it
	names: dict = collections.defaultdict(list)
	for it in items.values():
		keys = {norm(it["name"]), norm(it["id"])} | {norm(t) for t in it.get("tags", [])} | {norm(a) for a in it.get("aliases", [])}
		for k in keys:
			if k and it["id"] not in names[k]:
				names[k].append(it["id"])
	return items, names


def sprite_index(sprites: Path) -> dict[str, list[str]]:
	out: dict[str, list[str]] = collections.defaultdict(list)
	if sprites.is_dir():
		for p in sprites.glob("*/*.png"):
			out[p.stem].append(p.parent.name)
	return out


def pack_export_users(pack_dir: Path, items: dict) -> dict[str, list[tuple[str, str]]]:
	"""client export -> [(public catalogue item id, match confidence)] for the art the pack shows."""
	out: dict[str, list[tuple[str, str]]] = collections.defaultdict(list)
	pack = {}
	try:
		pack = json.loads((pack_dir / "pack.json").read_text(encoding="utf-8"))
	except (OSError, ValueError):
		return out
	by_art: dict[str, list[str]] = collections.defaultdict(list)
	for it in items.values():
		by_art[it.get("art", it["id"])].append(it["id"])
	for key, e in (pack.get("sprites") or {}).items():
		src = e.get("source") or {} if isinstance(e, dict) else {}
		ex = src.get("export", "") if isinstance(src, dict) else ""
		if not ex or src.get("kind") != "apk":
			continue
		conf = str((e.get("match") or {}).get("confidence", "")) or ("verified" if e.get("verified") else "")
		for iid in by_art.get(key, []):
			out[ex].append((iid, conf))
	return out


def fence_or_path(name: str, export: str) -> str:
	n, e = name.lower(), export.lower()
	if re.search(r"\b(path|tile|walkway)\b", n) or re.search(r"_(path|tile)(_pole)?$", e):
		return "path"
	return "fence"


def classify(r: dict, row: dict, text: str, art: list[str], names: dict, items: dict, text_count: collections.Counter,
		users: dict | None = None) -> tuple[str, str, list[str]]:
	"""(class, evidence, candidate ids)."""
	table, name, export = r["table"], r["name"], row.get("ExportName", r.get("export", ""))
	use = row.get("UseCase", "")
	fname = row.get("FileName", "")
	cands = list(r.get("candidates", []))
	if r.get("kind") == "ambiguous" or r.get("kind") == "conflict":
		return "duplicate", f"{r.get('reason', '')}; choose one in Asset manager > Game data", cands
	if table.startswith("customization_"):
		return "customization_component", "appearance part table", []
	if use == "NHObj" or export.startswith("nhobj_"):
		return "out_of_scope_area", f"neighborhood object (UseCase {use or '-'}, export {export})", []
	if use == "Valley":
		return "out_of_scope_area", "valley object (UseCase Valley)", []
	if export.startswith("placeholder_") or "placeholders.sc" in fname or "<TODO" in text:
		return "unreleased", f"placeholder art ({fname or export})" + ("; untranslated text" if "<TODO" in text else ""), []
	if "seasonal_creatures.sc" in fname:
		return "event_only", f"seasonal event creature art ({fname}); plausible, not verified", []
	hit = names.get(norm(text), []) if text else []
	if hit:
		return "duplicate", f"the game text '{text}' equals catalogue name/tag of {', '.join(hit)}", hit
	shown = (users or {}).get(export, [])
	if shown:
		ids = sorted({i for i, _ in shown})
		names_txt = ", ".join(f"{i} ({items.get(i, {}).get('name', i)}, {c or 'unrated'} match)" for i, c in sorted(set(shown)))
		return "duplicate", f"the pack already shows this record's art ({export}) as {names_txt}; choose it in Asset manager > Game data to apply the price", ids
	if re.search(r"_(19|20)\d\d$", name) or (text and text_count[(table, text)] > 1):
		return "variant", f"several {table} records share the game text '{text}' (yearly or numbered copies)", cands
	if table == "gatherer_habitats" or (cands and row.get("WaterDeco") != "TRUE"):
		why = "looser name match to " + ", ".join(cands) if cands else "a gatherer home the catalogue may list under another name"
		return "variant", why + "; choose in Asset manager > Game data if it is the same object", cands
	missing = [k for k, ok in (("English text", bool(text)), ("footprint", bool(row.get("TileWidth") and row.get("TileHeight"))),
		("art", bool(art))) if not ok]
	if table not in ("decorations", "deco_fences") or missing:
		return "incomplete", ("missing " + ", ".join(missing)) if missing else f"{table}: the client data does not state the item type", []
	return "missing_farm_object", "main-farm object; text, footprint and art present", []


def addition(r: dict, row: dict, text: str, build: str, ids_taken: set) -> tuple[str, dict]:
	table = r["table"]
	export = row.get("ExportName", "")
	iid = slug(text)
	if iid in ids_taken:
		iid = f"{iid}_{slug(table)}"
	n = 2
	while iid in ids_taken:
		iid = f"{slug(text)}_{n}"
		n += 1
	ids_taken.add(iid)
	w, h = int(row["TileWidth"]), int(row["TileHeight"])
	tags = ["client_only"]
	notes = [f"From your own game files (client {build}, {table}.csv); not in the public catalogue."]
	rec: dict = {"name": text, "footprint": [w, h], "footprint_status": "game_data", "data_status": "game_data"}
	if table == "deco_fences":
		cat = fence_or_path(text, export)
		rec["category"] = cat
		rec["connect"] = {"group": iid, "style": cat}
		if cat == "path":
			rec["layer"] = "ground"
			rec["flippable"] = False
		else:
			rec["flippable"] = True
	else:
		if row.get("WaterDeco", "").upper() == "TRUE":
			cat = "water"
			tags.append("water_deco")
			notes.append(WATER_NOTE)
		elif row.get("Theme"):
			cat = "seasonal"
			tags.append(row["Theme"].lower())
		else:
			cat = subcategory(text)
		if row.get("TagSanctuary", "").upper() == "TRUE":
			tags.append("sanctuary")
		rec["category"] = cat
		rec["flippable"] = bool(row.get("ExportNameMirror"))
	if row.get("UnlockLevel", "").isdigit():
		rec["unlock_level"] = int(row["UnlockLevel"])
	rec["tags"] = tags
	rec["notes"] = " ".join(notes)
	rec["sources"] = [f"client {build} {table}.csv"]
	rec["client"] = {"table": table, "name": r["name"], "key": r["key"], "tid": row.get("TID", ""), "export": export,
		"file": row.get("FileName", ""), "build": build}
	return iid, rec


def main(argv=None) -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--root", type=Path, default=DEFAULT_ROOT)
	ap.add_argument("--build", default="1.73.89")
	ap.add_argument("--review", type=Path, required=True)
	ap.add_argument("--tables", type=Path)
	ap.add_argument("--sprites", type=Path)
	ap.add_argument("--pack", type=Path, default=Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))) / "HaydaySandbox" / "asset_packs" / "hayday_original")
	ap.add_argument("--out-qa", type=Path)
	ap.add_argument("--out-additions", type=Path)
	ap.add_argument("--date", default=dt.date.today().isoformat())
	a = ap.parse_args(argv)
	root = a.root
	tables = a.tables or root / "raw" / "apk_extracted" / a.build / "assets" / "data"
	sprites = a.sprites or root / "raw" / "apk_sprites" / a.build
	out_qa = a.out_qa or root / "qa" / a.date / "client_records"
	out_add = a.out_additions or root / "research" / "catalog" / "client_additions.json"
	for p in (out_qa, out_add.parent):
		p.mkdir(parents=True, exist_ok=True)
		if in_git_tree(p):
			print(f"refusing to write game-derived data inside a git work tree: {p}", file=sys.stderr)
			return 2
	doc = json.loads(a.review.read_text(encoding="utf-8"))
	review = doc.get("review", [])
	texts = read_texts(tables.parent / "localization" / "texts.csv")
	items, names = load_catalogue()
	spr = sprite_index(sprites)
	users = pack_export_users(a.pack, items)
	tabs: dict[str, dict] = {}
	enriched = []
	for r in review:
		t = r["table"]
		if t not in tabs:
			tabs[t] = read_table(tables / f"{t}.csv")
		row = tabs[t].get(r["name"].lower(), {})
		enriched.append((r, row, texts.get(row.get("TID", ""), r.get("text", "")) or ""))
	text_count = collections.Counter((r["table"], tx) for r, _, tx in enriched if tx)
	ids_taken = set(items) | {al for it in items.values() for al in it.get("aliases", [])}
	records, additions = [], {}
	for r, row, text in enriched:
		export = row.get("ExportName", r.get("export", ""))
		art = spr.get(export, [])
		cls, why, cands = classify(r, row, text, art, names, items, text_count, users)
		rec = {"key": r["key"], "table": r["table"], "name": r["name"], "text": text, "tid": row.get("TID", ""),
			"export": export, "art": art, "footprint": [int(row["TileWidth"]), int(row["TileHeight"])] if row.get("TileWidth") and row.get("TileHeight") else None,
			"price": r.get("price", {}), "can_buy": r.get("can_buy"), "review_kind": r.get("kind", ""), "class": cls,
			"evidence": why, "candidates": cands,
			"flags": {k: row[k] for k in ("UseCase", "Theme", "TagSanctuary", "WaterDeco", "FileName") if row.get(k)}}
		if cls == "missing_farm_object":
			iid, add = addition(r, row, text, a.build, ids_taken)
			additions[iid] = add
			rec["added_as"] = iid
		records.append(rec)
	counts = collections.Counter(x["class"] for x in records)
	now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
	qa = {"format": "hayday-sandbox-client-record-classification", "version": 1, "generated": now, "build": a.build,
		"PRIVATE": "Derived from the user's own game files. Never commit or share.",
		"source": {"review": str(a.review), "tables": str(tables), "sprites": str(sprites), "pack": str(a.pack)},
		"counts": {c: counts.get(c, 0) for c in CLASSES}, "by_review_kind": dict(collections.Counter(x["review_kind"] for x in records)),
		"records": records}
	(out_qa / "classification.json").write_text(json.dumps(qa, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
	L = [f"# Client records not applied by the price import (client {a.build}, {now[:10]})", "",
		"PRIVATE: derived from your own game files. Do not commit or share.", "",
		"| Class | Records |", "|---|---|"]
	for c in CLASSES:
		L.append(f"| {CLASS_TEXT[c]} | {counts.get(c, 0)} |")
	L.append(f"| **Total** | **{len(records)}** |")
	for c in CLASSES:
		rows = [x for x in records if x["class"] == c]
		if not rows:
			continue
		L += ["", f"## {CLASS_TEXT[c]} ({len(rows)})", "", "| Record | Game text | Footprint | Price | Evidence |", "|---|---|---|---|---|"]
		for x in sorted(rows, key=lambda x: x["key"]):
			fp = "x".join(map(str, x["footprint"])) if x["footprint"] else "?"
			price = ", ".join(f"{v} {k}" for k, v in (x["price"] or {}).items()) or "-"
			ev = x["evidence"] + (f" -> added as `{x['added_as']}`" if x.get("added_as") else "")
			L.append(f"| `{x['key']}` | {x['text'] or '-'} | {fp} | {price} | {ev} |")
	(out_qa / "classification.md").write_text("\n".join(L) + "\n", encoding="utf-8")
	add_doc = {"format": FORMAT, "version": 1, "generated": now, "build": a.build,
		"PRIVATE": "Catalogue additions from the user's own game files. Never commit or share.",
		"source": {"classification": str(out_qa / "classification.json")}, "additions": dict(sorted(additions.items()))}
	out_add.write_text(json.dumps(add_doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
	print("CLIENT-CATALOG records=%d %s additions=%d -> %s, %s" % (len(records),
		" ".join(f"{c}={counts.get(c, 0)}" for c in CLASSES), len(additions), out_qa, out_add))
	return 0


if __name__ == "__main__":
	sys.exit(main())
