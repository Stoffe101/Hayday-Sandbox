#!/usr/bin/env python3
"""Validate repository data and enforce the art/licensing guard.

Checks
  * item manifests: schema, unique ids/aliases, known categories, footprints,
    status values, connection styles, landmark/scope flags (landmark duplicates
    are never placeable/movable; "game_data" status never appears in public data)
  * maps (schema v1 and v2): regions inside the grid, unique plot ids/aliases,
    v2 frame/provenance/world_bounds, sections, landmarks (ids, rects, anchors,
    confidence, replaced catalogue items), scenery, ground RLE, tile types,
    initial objects; PRIVACY: tracked maps must be public approximations without
    game-derived layers (ground, initial_objects, terrain, tile_types)
  * built-in asset pack: every referenced file exists, no orphan images,
    every catalogue item resolves to art
  * sample layouts: format, all items exist, no overlaps
  * LICENSE GUARD: nothing but README/.gdignore in assets/original/, no
    game-archive file types anywhere, no images outside the allowed folders,
    no unexpectedly large files
Exit status 1 on any error. Usage: python3 tools/ci/validate_data.py
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STATUSES = {"confirmed", "community", "approximation", "unverified", "unknown", "original"}
PRIVATE_STATUSES = {"game_data"}   # only ever set at runtime from a private pack
SCOPES = {"main_farm", "fishing_lake"}
REGION_KINDS = {"void", "buildable", "plot", "road", "water", "blocked", "scenery"}
SCENERY_KINDS = {"river", "cliff", "forest", "edge"}
LANDMARK_AREAS = {"farm_side", "road_verge", "across_road", "river", "cliff"}
LANDMARK_ANCHORS = {"top_corner", "center"}
LANDMARK_CONFIDENCE = {"verified-in-data", "strong", "plausible", "approximate"}
RETIRED_MAPS = {"hayday_farm_h1.json"}
PRIVATE_MAP_KEYS = ("ground", "initial_objects", "terrain", "tile_types")
PROHIBITED_EXT = {".sc", ".apk", ".xapk", ".obb", ".ipa", ".ktx", ".sctx", ".zktx", ".pvr", ".astc"}
IMAGE_EXT = {".png", ".webp", ".jpg", ".jpeg", ".gif", ".bmp", ".tga", ".ico"}
ALLOWED_IMAGE_DIRS = ("assets/placeholders/items/", "assets/ui/", "docs/screenshots/")
MAX_FILE_BYTES = 5 * 1024 * 1024

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def tracked_files() -> list[str]:
    try:
        out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout
        return [l for l in out.splitlines() if l]
    except Exception:
        return [str(p.relative_to(ROOT)) for p in ROOT.rglob("*") if p.is_file() and ".git/" not in str(p)]


def check_items() -> dict:
    cats = {c["id"] for c in json.loads((ROOT / "data/items/categories.json").read_text())["categories"]}
    items: dict[str, dict] = {}
    aliases: dict[str, str] = {}
    for f in sorted((ROOT / "data/items").glob("*.json")):
        if f.name == "categories.json":
            continue
        doc = json.loads(f.read_text(encoding="utf-8"))
        if doc.get("schema") != "hayday-sandbox-items":
            err(f"{f.name}: missing schema header")
        for it in doc.get("items", []):
            iid = it.get("id", "")
            if not iid or not iid.replace("_", "a").isalnum() or iid.lower() != iid:
                err(f"{f.name}: bad id {iid!r}")
            if iid in items:
                err(f"duplicate id {iid}")
            items[iid] = it
            if it.get("category") not in cats:
                err(f"{iid}: unknown category {it.get('category')}")
            fp = it.get("footprint")
            if fp is None:
                prov = it.get("provisional_footprint")
                if not (isinstance(prov, list) and len(prov) == 2):
                    err(f"{iid}: unknown footprint without provisional_footprint")
            elif not (isinstance(fp, list) and len(fp) == 2 and all(isinstance(v, int) and v > 0 for v in fp)):
                err(f"{iid}: bad footprint {fp}")
            st = it.get("footprint_status", "unknown" if fp is None else "unverified")
            if st in PRIVATE_STATUSES:
                err(f"{iid}: footprint_status {st!r} comes from private game files and must not be committed")
            elif st not in STATUSES:
                err(f"{iid}: bad footprint_status {st}")
            lms = list(it.get("landmarks", []))
            lm = it.get("landmark")
            if lm is not None and not (isinstance(lm, str) and is_slug(lm)):
                err(f"{iid}: bad landmark {lm!r}")
            if lms and (not all(isinstance(x, str) and is_slug(x) for x in lms) or (lm and lms[0] != lm)):
                err(f"{iid}: 'landmarks' must be landmark ids starting with 'landmark'")
            if lm or lms:
                if it.get("placeable", True) or it.get("movable", True):
                    err(f"{iid}: landmark duplicates must be placeable: false and movable: false")
            scope = it.get("scope", "main_farm")
            if scope not in SCOPES:
                err(f"{iid}: unknown scope {scope!r}")
            elif scope != "main_farm" and it.get("placeable", True):
                err(f"{iid}: items outside the main farm (scope {scope}) must be placeable: false")
            if it.get("category") == "obstacle" and it.get("movable", True):
                err(f"{iid}: obstacles are removed, not moved (movable: false)")
            conn = it.get("connect")
            if conn and conn.get("style") not in ("fence", "path"):
                err(f"{iid}: bad connect style {conn}")
            for a in it.get("aliases", []):
                if a in aliases:
                    err(f"alias {a} used twice")
                aliases[a] = iid
    for a in aliases:
        if a in items:
            err(f"alias {a} collides with an item id")
    return items


def is_slug(s: str) -> bool:
    return bool(s) and s.replace("_", "a").isalnum() and s.lower() == s and s[0] != "_"


def is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def is_rect(r) -> bool:
    return isinstance(r, list) and len(r) == 4 and all(is_int(v) for v in r) and r[2] > 0 and r[3] > 0


def is_vec(v, positive: bool = False) -> bool:
    return isinstance(v, list) and len(v) == 2 and all(is_int(x) for x in v) and (not positive or min(v) > 0)


def check_landmark(name: str, lm: dict, items: dict, pack_sprites: dict) -> None:
    lid = lm.get("id", "")
    tag = f"{name}: landmark {lid or '?'}"
    if not is_slug(lid):
        err(f"{tag}: bad id")
    if not is_vec(lm.get("origin")):
        err(f"{tag}: origin must be [x, y] integers")
    if not is_vec(lm.get("footprint"), True):
        err(f"{tag}: footprint must be [w, h] positive integers")
    for b in lm.get("blocks", []) or []:
        if not is_rect(b):
            err(f"{tag}: bad blocks rect {b}")
    if lm.get("area", "farm_side") not in LANDMARK_AREAS:
        err(f"{tag}: unknown area {lm.get('area')!r}")
    if lm.get("draw_anchor", "top_corner") not in LANDMARK_ANCHORS:
        err(f"{tag}: bad draw_anchor {lm.get('draw_anchor')!r}")
    if lm.get("confidence", "approximate") not in LANDMARK_CONFIDENCE:
        err(f"{tag}: bad confidence {lm.get('confidence')!r}")
    states = lm.get("states", [])
    if states and lm.get("default_state", states[0]) not in states:
        err(f"{tag}: default_state not in states")
    if lm.get("movable") or lm.get("rotatable"):
        err(f"{tag}: landmarks are never movable/rotatable")
    for iid in lm.get("replaces_items", []):
        it = items.get(iid)
        if it is None:
            err(f"{tag}: replaces unknown catalogue item {iid}")
        elif lid not in ([it.get("landmark")] + list(it.get("landmarks", []))):
            err(f"{tag}: catalogue item {iid} must name this landmark in 'landmark'/'landmarks'")
    fb = lm.get("fallback_art", "")
    if fb and fb not in pack_sprites:
        warnings.append(f"{tag}: fallback_art {fb!r} has no placeholder sprite")


def check_ground(name: str, m: dict, w: int, h: int) -> None:
    g = m["ground"]
    if not isinstance(g, dict) or g.get("encoding", "rle-rows") != "rle-rows":
        err(f"{name}: ground must be {{'encoding': 'rle-rows', 'rows': [...]}}")
        return
    gx, gy, gw, gh = g.get("rect", [0, 0, w, h])
    rows = g.get("rows", [])
    if len(rows) != gh:
        err(f"{name}: ground has {len(rows)} rows, expected {gh}")
    types = {int(k) for k in m.get("tile_types", {})}
    for y, row in enumerate(rows):
        total = 0
        for run in row:
            if not (isinstance(run, list) and len(run) == 2 and is_int(run[0]) and is_int(run[1])
                    and 0 <= run[0] <= 255 and run[1] > 0):
                err(f"{name}: ground row {y}: bad run {run}")
                return
            if types and run[0] not in types:
                err(f"{name}: ground row {y}: undeclared tile type {run[0]}")
            total += run[1]
        if total != gw:
            err(f"{name}: ground row {y} covers {total} of {gw} tiles")
            return


def check_maps(items: dict | None = None, pack_sprites: dict | None = None, paths: list[Path] | None = None,
               public: bool = True) -> None:
    items = items or {}
    pack_sprites = pack_sprites or {}
    files = paths if paths is not None else sorted((ROOT / "data/maps").glob("*.json"))
    for f in files:
        name = f.name
        if public and name in RETIRED_MAPS:
            err(f"{name}: retired map must not be shipped (its layouts migrate to hayday_farm)")
        m = json.loads(f.read_text(encoding="utf-8"))
        if m.get("format") != "hayday-sandbox-map":
            err(f"{name}: bad format")
        sv = m.get("schema_version", 1)
        if sv not in (1, 2):
            err(f"{name}: unknown schema_version {sv}")
        if not is_vec(m.get("size"), True):
            err(f"{name}: size must be [w, h]")
            continue
        w, h = m["size"]
        ids = set()
        plots: set[str] = set()
        aliases: dict[str, str] = {}
        for r in m.get("regions", []):
            if r["id"] in ids:
                err(f"{name}: duplicate region id {r['id']}")
            ids.add(r["id"])
            if r.get("kind", "buildable") not in REGION_KINDS:
                err(f"{name}: region {r['id']} has unknown kind {r.get('kind')}")
            for rect in r.get("rects", []):
                if not is_rect(rect):
                    err(f"{name}: region {r['id']} has a bad rect {rect}")
                    continue
                x, y, rw, rh = rect
                if x < 0 or y < 0 or x + rw > w or y + rh > h:
                    err(f"{name}: region {r['id']} rect out of bounds")
            if r.get("kind") == "plot":
                plots.add(r["id"])
                for a in r.get("aliases", []):
                    if a in aliases:
                        err(f"{name}: plot alias {a} used twice")
                    aliases[a] = r["id"]
        for a in aliases:
            if a in plots:
                err(f"{name}: plot alias {a} collides with a plot id")
        if sv < 2:
            continue
        if m.get("frame") != "game":
            err(f"{name}: schema v2 maps must declare frame 'game'")
        prov = m.get("provenance", {})
        if prov.get("kind") not in ("public_approximation", "private_game_data"):
            err(f"{name}: provenance.kind must be public_approximation or private_game_data")
        wb = m.get("world_bounds")
        if wb is not None:
            if not is_rect(wb):
                err(f"{name}: world_bounds must be [x, y, w, h]")
            elif wb[0] > 0 or wb[1] > 0 or wb[0] + wb[2] < w or wb[1] + wb[3] < h:
                err(f"{name}: world_bounds must enclose the placement grid")
        sec_ids = set()
        for s in m.get("sections", []):
            if s.get("id") in sec_ids or not s.get("id"):
                err(f"{name}: duplicate or missing section id {s.get('id')}")
            sec_ids.add(s.get("id"))
            if s.get("side", "main") not in ("main", "across_road"):
                err(f"{name}: section {s.get('id')} has unknown side {s.get('side')}")
            for pid in s.get("plots", []):
                if pid not in plots and pid not in aliases:
                    err(f"{name}: section {s.get('id')} lists unknown plot {pid}")
        lids = set()
        for lm in m.get("landmarks", []):
            if lm.get("id") in lids:
                err(f"{name}: duplicate landmark id {lm.get('id')}")
            lids.add(lm.get("id"))
            check_landmark(name, lm, items, pack_sprites)
        for sc in m.get("scenery", []):
            if sc.get("kind") not in SCENERY_KINDS or not is_rect(sc.get("rect")):
                err(f"{name}: bad scenery entry {sc.get('id')}")
        if "ground" in m:
            check_ground(name, m, w, h)
        for t in m.get("tile_types", {}):
            if not str(t).isdigit() or not 0 <= int(t) <= 255:
                err(f"{name}: tile type id {t} must be 0..255")
        for o in m.get("initial_objects", []):
            if not (is_int(o.get("x")) and is_int(o.get("y")) and o.get("item")):
                err(f"{name}: initial object without item/x/y")
            elif items and o["item"] not in items:
                err(f"{name}: initial object uses unknown item {o['item']}")
        if public:
            # PRIVACY: tracked maps are public approximations only (W2 design s0).
            if prov.get("kind") != "public_approximation" or m.get("geometry_status") == "game_data":
                err(f"{name}: tracked maps must be public approximations (game data stays in the private pack)")
            for k in PRIVATE_MAP_KEYS:
                if k in m:
                    err(f"{name}: '{k}' is game-derived and must not be in a tracked map")
            for lm in m.get("landmarks", []):
                if lm.get("confidence") != "approximate" or lm.get("skins"):
                    err(f"{name}: landmark {lm.get('id')} in a tracked map must be 'approximate' without skins")


def check_pack(items: dict) -> None:
    pack_path = ROOT / "assets/placeholders/pack.json"
    pack = json.loads(pack_path.read_text())
    if pack.get("format") != "hayday-sandbox-asset-pack":
        err("pack.json: bad format")
    refs = set()

    def ref(e: dict, key: str) -> None:
        f = e.get("file")
        if not f or not (ROOT / "assets/placeholders" / f).exists():
            err(f"pack.json: {key} references missing file {f}")
        refs.add(f)
        if "shadow" in e:
            ref(e["shadow"], key + ".shadow")
        if "anim" in e:
            a = e["anim"]
            sheet = a.get("sheet")
            if not sheet or not (ROOT / "assets/placeholders" / sheet).exists():
                err(f"pack.json: {key}.anim references missing sheet {sheet}")
            refs.add(sheet)
            if not (is_int(a.get("frames")) and a["frames"] > 0) or not a.get("fps", 0) > 0:
                err(f"pack.json: {key}.anim needs frames > 0 and fps > 0")
            if a.get("mode", "overlay") not in ("overlay", "replace"):
                err(f"pack.json: {key}.anim has unknown mode {a.get('mode')!r}")

    for key, e in pack["sprites"].items():
        ref(e, key)
        for m, c in e.get("connections", {}).items():
            ref(c, f"{key}#m{m}")
    for p in (ROOT / "assets/placeholders/items").glob("*.png"):
        if f"items/{p.name}" not in refs:
            err(f"orphan placeholder image {p.name}")
    missing = [i for i, it in items.items() if it.get("art", i) not in pack["sprites"]]
    if missing:
        warnings.append(f"{len(missing)} items without placeholder art: {missing[:10]}")


def check_samples(items: dict) -> None:
    for f in sorted((ROOT / "data/samples").glob("*.hdlayout")):
        d = json.loads(f.read_text(encoding="utf-8"))
        if d.get("format") != "hayday-sandbox-layout":
            err(f"{f.name}: bad format")
        occ = {}
        for o in d.get("objects", []):
            if o["item"] not in items:
                err(f"{f.name}: unknown item {o['item']}")
            for y in range(o["y"], o["y"] + o["h"]):
                for x in range(o["x"], o["x"] + o["w"]):
                    if (x, y) in occ:
                        err(f"{f.name}: overlap at {x},{y}")
                    occ[(x, y)] = o["uid"]


def license_guard() -> None:
    for rel in tracked_files():
        p = ROOT / rel
        low = rel.lower()
        suffix = Path(low).suffix
        if low.startswith("assets/original/") and Path(rel).name not in ("README.md", ".gdignore"):
            err(f"LICENSE GUARD: {rel} must not be committed (assets/original is local-only)")
        if suffix in PROHIBITED_EXT:
            err(f"LICENSE GUARD: game-archive/texture file type not allowed: {rel}")
        if suffix in IMAGE_EXT and not low.startswith(ALLOWED_IMAGE_DIRS):
            err(f"LICENSE GUARD: image outside allowed folders: {rel} (only original art may be committed)")
        if p.exists() and p.is_file() and p.stat().st_size > MAX_FILE_BYTES and not low.endswith(".ttf"):
            err(f"LICENSE GUARD: unexpectedly large file ({p.stat().st_size // 1024} KiB): {rel}")


def main() -> int:
    items = check_items()
    pack_sprites = json.loads((ROOT / "assets/placeholders/pack.json").read_text()).get("sprites", {})
    if len(sys.argv) > 1:
        # validate given (e.g. private) map files without the public-only rules
        check_maps(items, pack_sprites, [Path(a) for a in sys.argv[1:]], public=False)
    else:
        check_maps(items, pack_sprites)
    check_pack(items)
    check_samples(items)
    license_guard()
    for w in warnings:
        print("warning:", w)
    for e in errors:
        print("ERROR:", e)
    print(f"validated {len(items)} items; {len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
