#!/usr/bin/env python3
"""Generate the built-in ORIGINAL placeholder asset pack.

Reads item metadata from data/items/*.json, renders each item with the recipe
library, and writes:
  assets/placeholders/items/<art_key>.png            sprite
  assets/placeholders/items/<art_key>.shadow.png     soft ground shadow
  assets/placeholders/items/<art_key>__mNN.png       connection shapes (fences/paths)
  assets/placeholders/items/<stem>.anim.png          ambient animation sheets (world_art.py)
  assets/placeholders/pack.json                      asset-pack manifest
Art that no catalogue item owns (the truck landmark) lives in world_art.py.
Unchanged items are skipped using a content hash cache (.cache.json).

Usage:
  python3 tools/art_generator/generate.py [--force] [--only id1,id2] [--sheet out.png] [--jobs N]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from iso3d import render  # noqa: E402
import recipes  # noqa: E402
import world_art  # noqa: E402

SCALE = 2.0  # art pixels per world pixel (crisp up to 200% zoom)
PACK_ID = "builtin_placeholders"


def load_items(items_dir: Path) -> list[dict]:
    out = []
    for f in sorted(items_dir.glob("*.json")):
        if f.name == "categories.json":
            continue
        data = json.loads(f.read_text(encoding="utf-8"))
        for it in data.get("items", []):
            fp = it.get("footprint") or it.get("provisional_footprint") or [1, 1]
            it = dict(it)
            it["footprint"] = [max(1, int(fp[0])), max(1, int(fp[1]))]
            out.append(it)
    return out


_SRC_HASH = None


def art_fingerprint(it: dict) -> str:
    global _SRC_HASH
    if _SRC_HASH is None:
        src = "".join((HERE / n).read_text(encoding="utf-8") for n in ("iso3d.py", "parts.py", "recipes.py"))
        _SRC_HASH = hashlib.sha1(src.encode()).hexdigest()
    rel = {k: it.get(k) for k in ("name", "category", "footprint", "connect", "layer")}
    rel["sig"] = recipes.signature(it)
    return hashlib.sha1((json.dumps(rel, sort_keys=True) + str(SCALE) + _SRC_HASH).encode()).hexdigest()[:16]


def file_key(it: dict) -> str:
    """File stem shared by every item with the same visual signature."""
    sig = recipes.signature(it)
    if sig.startswith("u:"):
        return it.get("art", it["id"])
    return "g_" + hashlib.sha1(sig.encode()).hexdigest()[:10]


def render_item(args):
    it, out_dir = args
    key = file_key(it)
    fp = tuple(it["footprint"])
    style = (it.get("connect") or {}).get("style", "")
    flat = it.get("layer") == "ground"
    entry = {}
    items_dir = Path(out_dir) / "items"
    if style in ("fence", "path"):
        conns = {}
        for mask in range(16):
            spr = render(recipes.build(it, mask), fp, scale=SCALE, shadow=not flat)
            name = f"{key}__m{mask:02d}.png"
            spr.image.save(items_dir / name, optimize=True)
            c = {"file": f"items/{name}", "anchor": list(spr.anchor)}
            if spr.shadow is not None:
                sname = f"{key}__m{mask:02d}.shadow.png"
                spr.shadow.save(items_dir / sname, optimize=True)
                c["shadow"] = {"file": f"items/{sname}", "anchor": list(spr.shadow_anchor)}
            conns[str(mask)] = c
        entry = dict(conns["0"])
        entry["connections"] = conns
    else:
        spr = render(recipes.build(it), fp, scale=SCALE, shadow=not flat)
        name = f"{key}.png"
        spr.image.save(items_dir / name, optimize=True)
        entry = {"file": f"items/{name}", "anchor": list(spr.anchor)}
        if spr.shadow is not None:
            sname = f"{key}.shadow.png"
            spr.shadow.save(items_dir / sname, optimize=True)
            entry["shadow"] = {"file": f"items/{sname}", "anchor": list(spr.shadow_anchor)}
    entry["footprint"] = list(fp)
    return key, entry


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--items", default=str(ROOT / "data/items"))
    ap.add_argument("--out", default=str(ROOT / "assets/placeholders"))
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--sheet", default="", help="also write a contact sheet PNG for review")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    a = ap.parse_args()
    out = Path(a.out)
    (out / "items").mkdir(parents=True, exist_ok=True)
    items = load_items(Path(a.items))
    only = {s for s in a.only.split(",") if s}
    cache_path = out / ".cache.json"
    cache = json.loads(cache_path.read_text()) if cache_path.exists() and not a.force else {}
    pack_path = out / "pack.json"
    old_pack = json.loads(pack_path.read_text()) if pack_path.exists() else {}
    sprites = dict(old_pack.get("sprites", {}))
    todo = []
    keys_seen = set()
    groups: dict[str, list] = {}
    for it in items:
        groups.setdefault(file_key(it), []).append(it)
    for fk, members in groups.items():
        rep = members[0]
        for it in members:
            keys_seen.add(it.get("art", it["id"]))
        if only and not any(it["id"] in only for it in members):
            continue
        fpk = art_fingerprint(rep)
        if not a.force and cache.get(fk) == fpk and all(it.get("art", it["id"]) in sprites for it in members) \
                and (out / sprites[members[0].get("art", members[0]["id"])]["file"]).exists():
            continue
        todo.append((fk, rep, members, fpk))
    print(f"{len(items)} items, {len(groups)} unique sprites, {len(todo)} to render")
    with ProcessPoolExecutor(max_workers=a.jobs) as ex:
        results = ex.map(render_item, [(rep, str(out)) for _fk, rep, _m, _f in todo], chunksize=4)
        for (key, entry), (fk, rep, members, fpk) in zip(results, todo):
            for it in members:
                e = dict(entry)
                if len(members) > 1:
                    e["shared"] = True
                sprites[it.get("art", it["id"])] = e
            cache[fk] = fpk
    keys_seen |= world_art.build_world_sprites(out, sprites, cache, SCALE, a.force)
    world_art.build_animations(out, sprites, items, cache, SCALE, file_key, a.force)
    # Drop sprites for items that no longer exist (and their files).
    for key in list(sprites):
        if key not in keys_seen:
            del sprites[key]
    referenced = set()
    for e in sprites.values():
        referenced.add(e["file"])
        if "shadow" in e:
            referenced.add(e["shadow"]["file"])
        if "anim" in e:
            referenced.add(e["anim"]["sheet"])
        for c in e.get("connections", {}).values():
            referenced.add(c["file"])
            if "shadow" in c:
                referenced.add(c["shadow"]["file"])
    removed = 0
    for f in (out / "items").glob("*.png"):
        if f"items/{f.name}" not in referenced:
            f.unlink()
            imp = f.with_suffix(".png.import")
            if imp.exists():
                imp.unlink()
            removed += 1
    pack = {
        "format": "hayday-sandbox-asset-pack",
        "schema_version": 1,
        "id": PACK_ID,
        "name": "Built-in placeholder art (original)",
        "author": "Hayday Sandbox contributors (generated by tools/art_generator)",
        "license": "CC0-1.0",
        "license_note": "Original procedurally generated artwork. Contains no Supercell assets.",
        "priority": 0,
        "pixels_per_world_px": SCALE,
        "sprites": dict(sorted(sprites.items())),
    }
    pack_path.write_text(json.dumps(pack, indent=1) + "\n", encoding="utf-8")
    cache_path.write_text(json.dumps(cache, indent=0, sort_keys=True), encoding="utf-8")
    print(f"pack.json: {len(sprites)} sprites; removed {removed} stale files")
    if a.sheet:
        contact_sheet(out, pack, items, Path(a.sheet))
    return 0


def contact_sheet(out: Path, pack: dict, items: list[dict], path: Path, cols: int = 10):
    from PIL import Image, ImageDraw
    cell = 220
    uniq, seen = [], set()
    for it in items:
        e = pack["sprites"].get(it.get("art", it["id"]))
        if e and e["file"] not in seen:
            seen.add(e["file"])
            uniq.append(it)
    items = uniq
    cols = 16
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell, rows * cell), (124, 176, 96, 255))
    d = ImageDraw.Draw(sheet)
    for i, it in enumerate(items):
        e = pack["sprites"].get(it.get("art", it["id"]))
        if not e:
            continue
        im = Image.open(out / e["file"]).convert("RGBA")
        k = min(1.0, (cell - 30) / max(im.width, im.height))
        im = im.resize((max(1, int(im.width * k)), max(1, int(im.height * k))), Image.LANCZOS)
        x = (i % cols) * cell + (cell - im.width) // 2
        y = (i // cols) * cell + (cell - 24 - im.height) // 2
        sheet.alpha_composite(im, (x, y))
        d.text(((i % cols) * cell + 6, (i // cols) * cell + cell - 18), it["name"][:30], fill=(20, 30, 20, 255))
    sheet.save(path)
    print(f"contact sheet -> {path}")


if __name__ == "__main__":
    sys.exit(main())
