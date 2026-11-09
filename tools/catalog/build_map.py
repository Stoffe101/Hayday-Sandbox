#!/usr/bin/env python3
"""Build farm geometry files (data/maps/*.json) from data/research/expansions_research.json.

Two hypotheses about the starting land are generated (see docs/research/PLACEMENT_RESEARCH.md):
  hayday_farm      H2 (favoured): starting land 32x32, main expansion strip X=32..84
  hayday_farm_h1   H1:            starting land 48x32, main expansion strip X=48..100
Geometry of the main section's 52 plots comes from a tile map reconstructed from
the Hay Day Wiki expansion image (approximation). Sections whose tile geometry is
unknown (upper plots, everything across the road) are listed as `unmapped_sections`
with their costs, and are NOT drawn as fake land.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "data/research/expansions_research.json"
OUT = ROOT / "data/maps"

PAD_X = 5      # river margin on the left
PAD_Y = 3      # forest / cliff margin at the top
ROAD_W = 2
ACROSS_H = 8   # unmapped across-road strip
PAD_R = 5


def plot_rects(tile_map: list[list[int]], number: int) -> list[list[int]]:
    """Greedy decomposition of one plot's tiles into rectangles (u, v, w, h)."""
    rects: list[list[int]] = []
    open_rects: dict[tuple[int, int], list[int]] = {}
    for v, row in enumerate(tile_map):
        runs = []
        u = 0
        while u < len(row):
            if row[u] == number:
                s = u
                while u < len(row) and row[u] == number:
                    u += 1
                runs.append((s, u))
            else:
                u += 1
        nxt = {}
        for (s, e) in runs:
            r = open_rects.get((s, e))
            if r is not None and r[1] + r[3] == v:
                r[3] += 1
            else:
                r = [s, v, e - s, 1]
                rects.append(r)
            nxt[(s, e)] = r
        open_rects = nxt
    return rects


def build(start_w: int, map_id: str, label: str) -> dict:
    res = json.loads(SRC.read_text(encoding="utf-8"))
    main = next(s for s in res["sections"] if s["id"] == "main")
    tm = [[int(x) for x in row.split()] for row in main["main_section_tile_map"]]
    main_w = len(tm[0])
    land_h = len(tm)
    x0 = PAD_X
    y0 = PAD_Y
    mx0 = x0 + start_w
    width = mx0 + main_w + PAD_R
    road_y = y0 + land_h
    height = road_y + ROAD_W + ACROSS_H
    regions = [
        {"id": "forest", "kind": "scenery", "name": "Forest edge", "rects": [[0, 0, width, y0]]},
        {"id": "river", "kind": "water", "name": "River", "rects": [[0, 0, x0, road_y + ROAD_W]]},
        {"id": "start", "kind": "buildable", "name": "Starting land", "status": "approximation",
         "rects": [[x0, y0, start_w, land_h]]},
        {"id": "far_end", "kind": "scenery", "name": "Farm edge", "rects": [[mx0 + main_w, y0, PAD_R, land_h]]},
        {"id": "road", "kind": "road", "name": "Main road", "rects": [[0, road_y, width, ROAD_W]]},
        {"id": "across_road", "kind": "blocked", "name": "Across-the-road expansions (geometry not mapped yet)",
         "status": "unverified", "rects": [[0, road_y + ROAD_W, width, ACROSS_H]]},
    ]
    for p in main["plots"]:
        n = p["number"]
        rects = [[mx0 + r[0], y0 + r[1], r[2], r[3]] for r in plot_rects(tm, n)]
        if not rects:
            continue
        cost = {k: v for k, v in p.get("cost", {}).items()}
        regions.append({
            "id": f"main_{n:02d}", "kind": "plot", "section": "main", "number": n, "name": f"Plot {n}",
            "rects": rects, "cost": cost, "min_level": 22, "status": p.get("geometry_confidence", "approximation"),
            "notes": p.get("notes", ""),
        })
    unmapped = []
    for s in res["sections"]:
        if s["id"] == "main":
            continue
        lem = sum(int(p.get("cost", {}).get("land_deed", 0)) for p in s["plots"])
        permits = sum(int(p.get("cost", {}).get("expansion_permit", 0)) for p in s["plots"])
        unmapped.append({"id": s["id"], "name": s.get("name", s["id"]), "location": s.get("location", ""),
                         "plots": len(s["plots"]), "land_deeds_each": lem, "expansion_permits": permits})
    return {
        "format": "hayday-sandbox-map", "schema_version": 1, "id": map_id, "name": label,
        "geometry_status": "approximation",
        "generated_by": "tools/catalog/build_map.py from data/research/expansions_research.json",
        "license": res.get("license", ""),
        "size": [width, height],
        "origin_note": f"Farm grid X along the road (screen down-right), Y forest->road (screen down-left). Starting land at X={x0}..{x0 + start_w - 1}, Y={y0}..{y0 + land_h - 1}.",
        "regions": regions,
        "unmapped_sections": unmapped,
        "labels": [
            {"text": "Main road", "at": [width * 0.5, road_y + 1]},
            {"text": "River", "at": [x0 * 0.5, road_y * 0.5]},
        ],
        "sources": [s.get("url", str(s)) if isinstance(s, dict) else str(s) for s in res.get("sources", [])][:12],
        "notes": [
            "Starting-land size is unresolved: 32x32 (H2, favoured) vs 48x32 (H1). Both maps ship; choose in Settings.",
            "Main-section plot shapes are reconstructed from the Hay Day Wiki map image (approximation; subsection widths 16/8/15/14 measured vs 17/8/15/13 in wiki text).",
            "Upper plots and all across-the-road sections exist in the game but their tile geometry is unknown; they are listed, not drawn.",
            "Positions of the river, forest edge and road width are schematic.",
        ],
    }


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for start_w, mid, label in ((32, "hayday_farm", "Hay Day farm — 32×32 start (favoured)"),
                                (48, "hayday_farm_h1", "Hay Day farm — 48×32 start (alternative)")):
        m = build(start_w, mid, label)
        (OUT / f"{mid}.json").write_text(json.dumps(m, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        plots = sum(1 for r in m["regions"] if r["kind"] == "plot")
        print(f"{mid}: size {m['size']}, {plots} plots, {len(m['unmapped_sections'])} unmapped sections")
    return 0


if __name__ == "__main__":
    sys.exit(main())
