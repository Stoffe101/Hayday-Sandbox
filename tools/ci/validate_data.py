#!/usr/bin/env python3
"""Validate repository data and enforce the art/licensing guard.

Checks
  * item manifests: schema, unique ids/aliases, known categories, footprints,
    status values, connection styles
  * maps: regions inside bounds, unique plot ids
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
            if st not in STATUSES:
                err(f"{iid}: bad footprint_status {st}")
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


def check_maps() -> None:
    for f in sorted((ROOT / "data/maps").glob("*.json")):
        m = json.loads(f.read_text(encoding="utf-8"))
        w, h = m["size"]
        ids = set()
        for r in m.get("regions", []):
            if r["id"] in ids:
                err(f"{f.name}: duplicate region id {r['id']}")
            ids.add(r["id"])
            for x, y, rw, rh in r.get("rects", []):
                if x < 0 or y < 0 or x + rw > w or y + rh > h or rw <= 0 or rh <= 0:
                    err(f"{f.name}: region {r['id']} rect out of bounds")


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
    check_maps()
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
