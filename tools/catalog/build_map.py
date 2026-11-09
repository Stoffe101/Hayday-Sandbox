#!/usr/bin/env python3
"""Build the PUBLIC farm map (data/maps/hayday_farm.json, schema v2) from data/research/expansions_research.json.

Schema v2 uses the game tile frame (W2 design s1/s2): the placement grid is [0, W) x [0, H); world content
(scenery placeholders, landmarks) may use negative tile coordinates. The public map is an APPROXIMATION:

  * starting land 32x32 at (0, 0) (the 48x32 hypothesis "hayday_farm_h1" is retired; its layouts migrate);
  * main section (52 plots) to the east, plot shapes reconstructed from the Hay Day Wiki map image;
  * main road: a 5-tile-deep strip directly south of the starting land (y 32..36);
  * across-road area: blocked, geometry not mapped (sections are listed in `unmapped_sections`);
  * river / forest edge: off-grid `scenery` placeholders at negative coordinates;
  * landmarks: only the five fixed structures the v1 starter template used (farmhouse, truck, order board,
    roadside shop, newspaper mailbox) at their v1 approximate spots shifted into the game frame, confidence
    "approximate". Real positions come only from the user's private world data (never committed).

This file must never contain game-derived data (decoded geometry, coordinates, initial objects, ground layer);
tools/ci/validate_data.py enforces that for every tracked map.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "data/research/expansions_research.json"
OUT = ROOT / "data/maps"
MAP_ID = "hayday_farm"
RETIRED = ("hayday_farm_h1",)    # kept known in WorldLoader.LEGACY_MAP_IDS for layout migration
GENERATED = "2026-11-09"         # bump when the generator's output intentionally changes

START_W = 32           # starting land width (32x32)
ROAD_D = 5             # road strip depth (rows directly south of the starting land)
ACROSS_H = 8           # unmapped across-road strip shown below the road
EDGE_R = 5             # farm edge beyond the last main-section column
RIVER_W = 5            # off-grid river placeholder width (west, x < 0)
FOREST_D = 3           # off-grid forest edge placeholder depth (north, y < 0)

# v1 map frame -> game frame (v1 had river/forest margins inside the grid at x 0..4 / y 0..2)
V1_SHIFT = (-5, -3)

# Public approximate landmarks: the v1 starter template (src/app/app.gd _add_starter_buildings) placed these
# relative to the starting-land origin, i.e. already in game-frame coordinates. Provisional catalogue sizes.
LANDMARK_EVIDENCE = "public approximation carried over from v1; install the private world data for game positions"
LANDMARK_NOTE = "Fixed in place in the game (can't be moved). Position here is approximate."


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


def landmark(lid: str, name: str, origin: list[int], footprint: list[int], fallback_art: str,
             replaces: list[str], skin_kind: str = "", draw_anchor: str = "top_corner") -> dict:
    return {
        "id": lid, "name": name, "area": "farm_side", "origin": origin, "footprint": footprint, "mirrored": False,
        "draw_anchor": draw_anchor, "art": f"lm_{lid}", "fallback_art": fallback_art,
        "states": [], "default_state": "", "skin_kind": skin_kind, "skins": [], "themes": [],
        "movable": False, "rotatable": False, "selectable": True, "transient": False, "hidden_by_default": False,
        "unlock_level": -1, "replaces_items": replaces,
        "evidence": LANDMARK_EVIDENCE, "confidence": "approximate", "game_version": "", "note": LANDMARK_NOTE,
    }


def public_landmarks() -> list[dict]:
    # v1 starter offsets (relative to the starting-land origin == game frame):
    #   farmhouse (14,12) 4x4; truck_and_order_board (13, 32-4) 4x3; roadside_shop (19, 32-4) 3x3; mailbox (18,12)
    tob = (13, START_W - 4)    # old combined 4x3 block x 13..16, y 28..30: split into order board + truck
    return [
        landmark("farmhouse", "Farmhouse", [14, 12], [4, 4], "farmhouse", ["farmhouse"], "house"),
        # the catalogue placeholder "truck_and_order_board" depicts the board; no truck placeholder exists yet
        landmark("order_board", "Order board", [tob[0], tob[1] + 1], [2, 2], "truck_and_order_board",
                 ["truck_and_order_board"]),
        landmark("truck", "Truck", [tob[0] + 3, tob[1] + 1], [1, 2], "", ["truck_and_order_board"], "truck", "center"),
        landmark("roadside_shop", "Roadside Shop", [19, START_W - 4], [3, 3], "roadside_shop", ["roadside_shop"],
                 "roadside_shop"),
        landmark("newspaper_mailbox", "Mailbox", [18, 12], [1, 1], "mailbox", ["mailbox", "newspaper_daily_dirt"]),
    ]


def build() -> dict:
    res = json.loads(SRC.read_text(encoding="utf-8"))
    main = next(s for s in res["sections"] if s["id"] == "main")
    tm = [[int(x) for x in row.split()] for row in main["main_section_tile_map"]]
    main_w = len(tm[0])
    land_h = len(tm)
    mx0 = START_W
    width = mx0 + main_w + EDGE_R
    road_y = land_h
    height = road_y + ROAD_D + ACROSS_H
    regions = [
        {"id": "start", "kind": "buildable", "name": "Starting land", "status": "approximation",
         "rects": [[0, 0, START_W, land_h]]},
        {"id": "far_end", "kind": "scenery", "name": "Farm edge", "rects": [[mx0 + main_w, 0, EDGE_R, land_h]]},
        {"id": "road", "kind": "road", "name": "Main road", "rects": [[0, road_y, width, ROAD_D]]},
        {"id": "across_road", "kind": "blocked", "name": "Across-the-road expansions (geometry not mapped yet)",
         "status": "unverified", "rects": [[0, road_y + ROAD_D, width, ACROSS_H]]},
    ]
    plot_ids = []
    for p in main["plots"]:
        n = p["number"]
        rects = [[mx0 + r[0], r[1], r[2], r[3]] for r in plot_rects(tm, n)]
        if not rects:
            continue
        cost = {k: v for k, v in p.get("cost", {}).items()}
        pid = f"main_{n:02d}"
        plot_ids.append(pid)
        regions.append({
            "id": pid, "kind": "plot", "section": "main", "number": n, "name": f"Plot {n}",
            "rects": rects, "cost": cost, "min_level": 22, "status": p.get("geometry_confidence", "approximation"),
            "notes": p.get("notes", ""), "wiki": {"section": "main", "plot": n},
        })
    unmapped = []
    for s in res["sections"]:
        if s["id"] == "main":
            continue
        lem = sum(int(p.get("cost", {}).get("land_deed", 0)) for p in s["plots"])
        permits = sum(int(p.get("cost", {}).get("expansion_permit", 0)) for p in s["plots"])
        unmapped.append({"id": s["id"], "name": s.get("name", s["id"]), "location": s.get("location", ""),
                         "plots": len(s["plots"]), "land_deeds_each": lem, "expansion_permits": permits})
    scenery = [
        {"id": "forest", "kind": "forest", "name": "Forest edge", "rect": [-RIVER_W, -FOREST_D, width + RIVER_W, FOREST_D]},
        {"id": "river", "kind": "river", "name": "River", "rect": [-RIVER_W, 0, RIVER_W, height]},
    ]
    world_bounds = [-RIVER_W, -FOREST_D, width + RIVER_W, height + FOREST_D]
    return {
        "format": "hayday-sandbox-map", "schema_version": 2, "id": MAP_ID, "name": "Hay Day farm",
        "frame": "game",
        "provenance": {
            "kind": "public_approximation",
            "source": "Hay Day Wiki expansion pages and map image (plot costs, numbering, shapes reconstructed); "
                      "v1 public map shifted into the game frame",
            "client_version": "", "generated": GENERATED, "confidence": "approximate",
        },
        "geometry_status": "approximation",
        "generated_by": "tools/catalog/build_map.py from data/research/expansions_research.json",
        "license": res.get("license", ""),
        "size": [width, height],
        "world_bounds": world_bounds,
        "origin_note": "Game tile frame: X runs along the road (screen down-right), Y from the cliff/forest to the "
                       f"road (screen down-left). Starting land X 0..{START_W - 1}, Y 0..{land_h - 1}; main road "
                       f"Y {road_y}..{road_y + ROAD_D - 1}. Negative tiles (river, forest) are scenery, never buildable.",
        "regions": regions,
        "sections": [{"id": "main", "name": "Main section (52 plots)", "side": "main", "plots": plot_ids,
                      "status": "approximation"}],
        "landmarks": public_landmarks(),
        "scenery": scenery,
        "unmapped_sections": unmapped,
        "labels": [
            {"text": "Main road", "at": [width * 0.5, road_y + ROAD_D * 0.5]},
        ],
        "sources": [s.get("url", str(s)) if isinstance(s, dict) else str(s) for s in res.get("sources", [])][:12],
        "notes": [
            "Starting land is 32x32 (verified in client data); the 48x32 alternative map was retired and its "
            "layouts migrate to this map.",
            "Main road: a strip directly south of the starting land, 5 tiles deep (conclusion from client data "
            "research); nothing can be built on it.",
            "Main-section plot shapes are reconstructed from the Hay Day Wiki map image (approximation; subsection "
            "widths 16/8/15/14 measured vs 17/8/15/13 in wiki text).",
            "Upper plots and all across-the-road sections exist in the game but their public tile geometry is "
            "unknown; they are listed, not drawn.",
            "Landmark positions (farmhouse, truck, order board, roadside shop, mailbox) are approximate; install the "
            "private world data from your own game files for the real positions and every other landmark.",
            "River and forest edge are schematic placeholders outside the placement grid.",
        ],
    }


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    m = build()
    (OUT / f"{MAP_ID}.json").write_text(json.dumps(m, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    for rid in RETIRED:
        old = OUT / f"{rid}.json"
        if old.exists():
            old.unlink()
            print(f"removed retired map {old.name}")
    plots = sum(1 for r in m["regions"] if r["kind"] == "plot")
    print(f"{MAP_ID}: size {m['size']}, world {m['world_bounds']}, {plots} plots, {len(m['landmarks'])} landmarks, "
          f"{len(m['unmapped_sections'])} unmapped sections")
    return 0


if __name__ == "__main__":
    sys.exit(main())
