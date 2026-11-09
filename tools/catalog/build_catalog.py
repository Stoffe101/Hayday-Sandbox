#!/usr/bin/env python3
"""Build the app's item manifests (data/items/*.json) from researched facts.

Inputs
  data/research/items_research.json   facts gathered from fan wikis (see docs/research/ITEM_DATA_RESEARCH.md)
  data/research/item_overrides.json   hand-maintained corrections, provisional sizes, connection rules
Outputs
  data/items/<file>.json              one manifest per catalogue section (schema hayday-sandbox-items v1)

Rules
  * Never invent a footprint. Missing sizes become `"footprint": null` plus an
    explicit `provisional_footprint` (from overrides) so the item is usable for
    planning but flagged as unknown everywhere in the UI.
  * Ids are stable slugs of the item name. Renames must be recorded as aliases
    in item_overrides.json so saved layouts keep working.
"""
from __future__ import annotations

import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESEARCH = ROOT / "data/research/items_research.json"
OVERRIDES = ROOT / "data/research/item_overrides.json"
OUT = ROOT / "data/items"

FILES = {
    "production": "production.json", "farm_building": "farm_buildings.json", "animal_home": "animal_homes.json",
    "field": "crops_and_trees.json", "fruit_tree": "crops_and_trees.json", "bush": "crops_and_trees.json",
    "fence": "fences.json", "path": "paths.json", "water": "water.json", "flowers": "flowers.json",
    "nature": "nature.json", "furniture": "furniture.json", "structures": "structures.json",
    "seasonal": "seasonal.json", "decoration": "decorations.json", "obstacle": "obstacles.json",
    "planning": "planning.json",
}

CATMAP = {
    "production": "production", "farm_building": "farm_building", "animal_home": "animal_home", "field": "field",
    "fruit_tree": "fruit_tree", "bush": "bush", "decoration_fence": "fence", "decoration_path": "path",
    "decoration_water": "water", "decoration_flower": "flowers", "decoration_seasonal": "seasonal",
    "decoration_other": "decoration", "scenery": "obstacle",
}

KW = {
    "nature": ["tree", "pine", "palm", "oak", "maple", "birch", "willow", "shrub", "rock", "boulder", "log", "stump",
               "mushroom", "plant", "cactus", "grass", "topiary", "bamboo", "fern", "reed", "bush"],
    "furniture": ["bench", "chair", "table", "lamp", "lantern", "light", "swing", "umbrella", "parasol", "sofa",
                  "hammock", "bike", "hydrant", "sign", "clock", "barrel", "keg", "crate", "cart", "wheelbarrow",
                  "campfire", "grill", "mailbox", "seat", "stool"],
    "structures": ["house", "hut", "cabin", "arch", "gazebo", "pavilion", "bridge", "tower", "windmill", "well",
                   "tent", "castle", "gate", "stand", "stall", "shed", "outhouse", "lighthouse", "temple", "pagoda",
                   "church", "mill", "fort", "palace", "kiosk", "stage", "shelter", "greenhouse", "booth"],
}


def slug(name: str) -> str:
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    s = re.sub(r"\[.*?\]", "", s)
    s = re.sub(r"\(.*?\)", lambda m: " " + m.group(0)[1:-1] + " ", s)
    s = re.sub(r"[^a-zA-Z0-9]+", "_", s).strip("_").lower()
    return s or "item"


def clean_name(name: str) -> str:
    return re.sub(r"\s*\[[^\]]*\]\s*$", "", name).strip()


def subcategory(name: str) -> str:
    n = name.lower()
    for cat in ("structures", "furniture", "nature"):
        if any(re.search(r"\b" + re.escape(k), n) for k in KW[cat]):
            return cat
    return "decoration"


def main() -> int:
    research = json.loads(RESEARCH.read_text(encoding="utf-8"))
    ov = json.loads(OVERRIDES.read_text(encoding="utf-8")) if OVERRIDES.exists() else {}
    by_name = {k.lower(): v for k, v in ov.get("items", {}).items()}
    sections: dict[str, list] = {}
    seen: dict[str, str] = {}
    stats = {"total": 0, "with_footprint": 0, "provisional": 0, "skipped": 0}
    for r in research:
        name = clean_name(r["name"])
        o = by_name.get(r["name"].lower()) or by_name.get(name.lower()) or {}
        if o.get("skip"):
            stats["skipped"] += 1
            continue
        cat = o.get("category") or CATMAP.get(r["category"], "decoration")
        if cat == "decoration":
            cat = subcategory(name)
        if r["category"] == "decoration_fence" and re.search(r"\bpath\b", name.lower()) and "category" not in o:
            cat = "path"
        iid = o.get("id") or slug(name)
        if iid in seen:
            iid = f"{iid}_{slug(cat)}"
        if iid in seen:
            n = 2
            while f"{iid}_{n}" in seen:
                n += 1
            iid = f"{iid}_{n}"
        seen[iid] = name
        fp = r.get("footprint")
        conf = r.get("confidence", "unverified")
        item: dict = {"id": iid, "name": o.get("name", name), "category": cat}
        if fp:
            item["footprint"] = [int(fp["w"]), int(fp["h"])]
            item["footprint_status"] = o.get("footprint_status", conf)
            stats["with_footprint"] += 1
        else:
            item["footprint"] = None
            prov = o.get("provisional_footprint", [1, 1])
            item["provisional_footprint"] = prov
            stats["provisional"] += 1
        if "footprint" in o:
            item["footprint"] = o["footprint"]
            item["footprint_status"] = o.get("footprint_status", "unverified")
            item.pop("provisional_footprint", None)
        if r.get("unlock_level") is not None:
            item["unlock_level"] = int(r["unlock_level"])
        cost = r.get("cost") or {}
        item["cost"] = {"coins": cost.get("coins"), "diamonds": cost.get("diamonds"), "other": cost.get("other")}
        if r.get("max_count") is not None:
            item["max_count"] = int(r["max_count"])
        rot = r.get("rotatable")
        item["flippable"] = bool(o.get("flippable", rot if rot is not None else False))
        if cat == "path" and "flippable" not in o:
            item["flippable"] = False  # PLACEMENT_RESEARCH.md: path tiles cannot be rotated
        if "movable" in o:
            item["movable"] = o["movable"]
        if "placeable" in o:
            item["placeable"] = o["placeable"]
        conn = o.get("connect")
        if conn is None and cat == "fence" and item.get("footprint") == [1, 1]:
            conn = {"group": iid, "style": "fence"}
        if conn is None and cat == "path":
            conn = {"group": iid, "style": "path"}
        if conn:
            item["connect"] = conn
        if cat == "path" or o.get("layer") == "ground":
            item["layer"] = "ground"
        if cat == "seasonal":
            item["season"] = o.get("season", "")
        item["data_status"] = conf
        item["sources"] = [s for s in [r.get("source")] if s]
        notes = r.get("notes", "")
        if o.get("note"):
            notes = (o["note"] + " | " + notes) if notes else o["note"]
        if notes:
            item["notes"] = notes
        if o.get("aliases"):
            item["aliases"] = o["aliases"]
        if "[" in r["name"]:
            item.setdefault("tags", []).append(re.search(r"\[(.*?)\]", r["name"]).group(1))
        sections.setdefault(FILES[cat], []).append(item)
        stats["total"] += 1
    # Extra hand-authored items (originals or missing facts), from overrides.
    for extra in ov.get("extra_items", []):
        sections.setdefault(FILES[extra["category"]], []).append(extra)
        stats["total"] += 1
    OUT.mkdir(parents=True, exist_ok=True)
    for f in OUT.glob("*.json"):
        if f.name != "categories.json":
            f.unlink()
    for fname, items in sorted(sections.items()):
        items.sort(key=lambda x: (x["category"], x["name"].lower()))
        doc = {
            "schema": "hayday-sandbox-items", "schema_version": 1,
            "generated_by": "tools/catalog/build_catalog.py",
            "source_dataset": "data/research/items_research.json (fan wiki research, verified 2026-11-09)",
            "items": items,
        }
        (OUT / fname).write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main())
