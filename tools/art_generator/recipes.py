"""Item -> 3D model recipes. Every model is original; it only borrows the
item's *function* (a bakery gets a bread plaque, an apple tree red fruit) so
placeholders stay recognisable without copying any proprietary artwork."""
from __future__ import annotations

import hashlib
import math
import re

import numpy as np

from iso3d import Mesh, hex_rgb, mix
from parts import (C, animal, barrel, bush, crate, door, fence_ring, flowers, fruit_color, glyph_for, ground_patch,
                   has, hue_for, pine, plaque, rng_for, round_tree, sack, window)

RECIPE_VERSION = 4


def build(item: dict, mask: int | None = None) -> Mesh:
    name = item.get("name", item["id"])
    cat = item.get("category", "decoration")
    w, h = item["footprint"]
    m = Mesh()
    sig = signature(item)
    rng = rng_for(sig)
    conn = (item.get("connect") or {}).get("style", "")
    if conn == "fence":
        fence(m, item, w, h, mask or 0)
    elif conn == "path" or cat == "path":
        path(m, item, w, h, mask or 0)
    elif cat == "production":
        workshop(m, item, w, h, rng)
    elif cat == "farm_building":
        farm_building(m, item, w, h, rng)
    elif cat == "animal_home":
        animal_home(m, item, w, h, rng)
    elif cat == "field":
        field(m, w, h, rng)
    elif cat == "fruit_tree":
        fruit_tree(m, item, w, h, rng)
    elif cat == "bush":
        bush(m, w / 2, h / 2, min(w, h) * 0.38, berries=fruit_color(name), rng=rng)
    elif cat == "fence":
        fence(m, item, w, h, mask or 0)
    elif cat == "planning":
        planning_marker(m, w, h)
    else:
        decoration(m, item, w, h, rng, sig)
    if not m.verts:
        monument(m, w, h, rng, hue_for(sig))
    return m


# ---------------------------------------------------------------------------
# Buildings
# ---------------------------------------------------------------------------

def workshop(m: Mesh, item, w, h, rng):
    name = item.get("name", "")
    roof = hue_for(item["id"])
    walls = [C["cream"], C["white"], C["plaster"], mix(C["wood_light"], C["cream"], 0.5), mix(C["stone"], C["cream"], 0.4)]
    wall = walls[int(rng.integers(len(walls)))]
    big = min(w, h) >= 3
    x0, y0 = 0.22, 0.22
    x1 = w - (0.85 if big else 0.22)
    y1 = h - 0.22
    wall_h = 0.85 + 0.17 * min(w, h)
    base = mix(C["stone"], C["stone_dark"], 0.3)
    m.box(x0 - 0.05, y0 - 0.05, 0, x1 + 0.05, y1 + 0.05, 0.1, base)
    m.box(x0, y0, 0.1, x1, y1, wall_h, wall)
    style = ["gable_x", "gable_y", "hip"][int(rng.integers(3))]
    rh = 0.45 + 0.12 * min(w, h)
    if style == "gable_x":
        m.gable_roof(x0, y0, x1, y1, wall_h, rh, roof, ridge="x", gable_color=wall)
    elif style == "gable_y":
        m.gable_roof(x0, y0, x1, y1, wall_h, rh, roof, ridge="y", gable_color=wall)
    else:
        m.hip_roof(x0, y0, x1, y1, wall_h, rh, roof, apex_inset=min(x1 - x0, y1 - y0) * 0.42)
    # Front (+y, lit) face: plaque with function glyph + window.
    g, gcol = glyph_for(name)
    psize = min(wall_h * 0.62, (x1 - x0) * 0.55)
    plaque(m, "+y", x0, y0, x1, y1, wall_h * 0.5 - psize * 0.5 + 0.05, psize, g, gcol)
    # Side (+x) face: door + window.
    span = y1 - y0
    du = min(0.34 / span, 0.3)
    door(m, "+x", x0, y0, x1, y1, 0.5 - du / 2 - (0.12 if span > 1.5 else 0), 0.5 + du / 2 - (0.12 if span > 1.5 else 0), wall_h * 0.62)
    if span > 1.4:
        ww = 0.28 / span
        window(m, "+x", x0, y0, x1, y1, 0.78 - ww / 2, 0.78 + ww / 2, wall_h * 0.42, wall_h * 0.75)
    # Chimney / vent
    if rng.random() < 0.6:
        cx = x0 + (x1 - x0) * 0.3
        cy = y0 + (y1 - y0) * 0.3
        m.box(cx - 0.12, cy - 0.12, wall_h, cx + 0.12, cy + 0.12, wall_h + rh + 0.3, C["brick"], top=C["stone_dark"])
    # Awning over the door
    if rng.random() < 0.55:
        ac = mix(roof, C["white"], 0.25)
        yc = y0 + (y1 - y0) * (0.5 - (0.12 if span > 1.5 else 0))
        m.poly([(x1, yc - 0.32, wall_h * 0.8), (x1, yc + 0.32, wall_h * 0.8), (x1 + 0.3, yc + 0.32, wall_h * 0.66), (x1 + 0.3, yc - 0.32, wall_h * 0.66)],
               ac, center=(x1 - 1, yc, 0))
    # Yard props
    if big:
        props = int(rng.integers(2, 4))
        spots = [(x1 + 0.2, y1 - 0.45), (x1 + 0.25, y0 + 0.2), (x1 + 0.3, (y0 + y1) / 2 + 0.6)]
        for i in range(props):
            px, py = spots[i]
            k = int(rng.integers(3))
            if k == 0:
                crate(m, px, py)
            elif k == 1:
                barrel(m, px + 0.16, py + 0.16)
            else:
                sack(m, px + 0.16, py + 0.16)


def barn(m: Mesh, w, h, color=None):
    color = C["barn_red"] if color is None else color
    x0, y0, x1, y1 = 0.2, 0.2, w - 0.2, h - 0.2
    wh = 1.2 + 0.1 * min(w, h)
    m.box(x0, y0, 0, x1, y1, wh, color)
    # Gambrel roof along x.
    ym = (y0 + y1) / 2
    hw = (y1 - y0) / 2 + 0.1
    z1 = wh + 0.55
    z2 = wh + 1.0
    roof = hex_rgb("#6b4a3a")
    ctr = ((x0 + x1) / 2, ym, wh)
    for side in (1, -1):
        m.poly([(x0 - 0.1, ym + side * hw, wh), (x1 + 0.1, ym + side * hw, wh), (x1 + 0.1, ym + side * hw * 0.55, z1), (x0 - 0.1, ym + side * hw * 0.55, z1)], roof, center=ctr)
        m.poly([(x0 - 0.1, ym + side * hw * 0.55, z1), (x1 + 0.1, ym + side * hw * 0.55, z1), (x1 + 0.1, ym, z2), (x0 - 0.1, ym, z2)], roof, center=ctr)
    gable = [(x1, y0, wh), (x1, y1, wh), (x1, ym + hw * 0.55 - 0.1, z1), (x1, ym, z2), (x1, ym - hw * 0.55 + 0.1, z1)]
    m.poly(gable, color, normal=(1, 0, 0))
    m.poly([(x0, p[1], p[2]) for p in gable], color, normal=(-1, 0, 0))
    # Big door with white X on +x face.
    span = y1 - y0
    u0, u1 = 0.3, 0.7
    m.facade_poly("+x", x0, y0, x1, y1, [(u0, 0), (u1, 0), (u1, wh * 0.8), (u0, wh * 0.8)], C["white"], offset=0.015)
    m.facade_poly("+x", x0, y0, x1, y1, [(u0 + 0.03, 0.04), (u1 - 0.03, 0.04), (u1 - 0.03, wh * 0.76), (u0 + 0.03, wh * 0.76)], mix(color, C["black"], 0.15), offset=0.02, flags=8)
    for a, b in (((u0 + 0.03, 0.04), (u1 - 0.03, wh * 0.76)), ((u1 - 0.03, 0.04), (u0 + 0.03, wh * 0.76))):
        d = 0.025
        m.facade_poly("+x", x0, y0, x1, y1, [(a[0] - d, a[1]), (a[0] + d, a[1]), (b[0] + d, b[1]), (b[0] - d, b[1])], C["white"], offset=0.026, flags=8)
    window(m, "+y", x0, y0, x1, y1, 0.42, 0.58, wh * 0.55, wh * 0.85)
    m.box(x0 - 0.02, y0 - 0.02, wh - 0.06, x1 + 0.02, y1 + 0.02, wh + 0.02, C["white"])


def silo(m: Mesh, w, h):
    cx, cy = w / 2, h / 2
    r = min(w, h) * 0.36
    ht = 1.9 + 0.3 * min(w, h)
    body = hex_rgb("#c9cdd2")
    m.cylinder(cx, cy, 0, ht, r, body, segs=24)
    for z in (ht * 0.25, ht * 0.5, ht * 0.75):
        m.cylinder(cx, cy, z, z + 0.05, r * 1.02, C["metal_dark"], segs=24)
    m.ellipsoid(cx, cy, ht, r * 1.03, r * 1.03, r * 0.75, hex_rgb("#4f7fb8"), segs=20, rings=10, zmin=ht)
    m.box(cx + r * 0.9, cy - 0.06, 0.2, cx + r * 0.98, cy + 0.06, ht - 0.1, C["metal_dark"])


def farmhouse(m: Mesh, w, h, rng):
    x0, y0, x1, y1 = 0.25, 0.25, w - 0.25, h - 0.9
    wh = 1.15 + 0.08 * min(w, h)
    m.box(x0 - 0.05, y0 - 0.05, 0, x1 + 0.05, y1 + 0.05, 0.12, C["stone"])
    m.box(x0, y0, 0.12, x1, y1, wh, C["cream"])
    m.gable_roof(x0, y0, x1, y1, wh, 0.9, hex_rgb("#c44f3b"), ridge="x", gable_color=C["cream"])
    m.box(x0 + 0.4, y0 + 0.3, wh, x0 + 0.68, y0 + 0.58, wh + 1.2, C["brick"], top=C["stone_dark"])
    # Porch on the front (+y)
    py1 = h - 0.2
    m.box(x0, y1, 0, x1, py1, 0.12, C["wood_light"])
    for px in (x0 + 0.1, x1 - 0.1, (x0 + x1) / 2):
        m.box(px - 0.05, py1 - 0.15, 0.12, px + 0.05, py1 - 0.05, wh * 0.75, C["white"])
    m.poly([(x0 - 0.05, y1, wh * 0.82), (x1 + 0.05, y1, wh * 0.82), (x1 + 0.05, py1 + 0.05, wh * 0.68), (x0 - 0.05, py1 + 0.05, wh * 0.68)], hex_rgb("#a8473a"), center=(0, -9, 0))
    door(m, "+y", x0, y0, x1, y1, 0.44, 0.56, wh * 0.62)
    for u in (0.18, 0.75):
        window(m, "+y", x0, y0, x1, y1, u, u + 0.12, wh * 0.4, wh * 0.78)
    window(m, "+x", x0, y0, x1, y1, 0.35, 0.65, wh * 0.4, wh * 0.78)


def market_stall(m: Mesh, w, h, rng, color):
    x0, y0, x1, y1 = 0.2, 0.2, w - 0.2, h - 0.2
    m.box(x0, y0, 0, x1, y1 - 0.3, 0.55, C["wood_light"], top=C["wood"])
    for px, py in ((x0, y0), (x1, y0), (x0, y1), (x1, y1)):
        m.box(px - 0.05, py - 0.05, 0, px + 0.05, py + 0.05, 1.35, C["wood"])
    # Striped awning
    n = 6
    for i in range(n):
        xa = x0 - 0.1 + (x1 - x0 + 0.2) * i / n
        xb = x0 - 0.1 + (x1 - x0 + 0.2) * (i + 1) / n
        col = color if i % 2 == 0 else C["white"]
        m.poly([(xa, y0 - 0.1, 1.55), (xb, y0 - 0.1, 1.55), (xb, y1 + 0.15, 1.2), (xa, y1 + 0.15, 1.2)], col, center=(0, 0, -5))
    for i, col in enumerate([C["red"], C["yellow"], C["green"], C["orange"]]):
        m.ellipsoid(x0 + 0.3 + i * (x1 - x0 - 0.6) / 3, (y0 + y1 - 0.3) / 2, 0.62, 0.11, 0.11, 0.08, col, segs=8, rings=5)


def board(m: Mesh, w, h, color):
    x0, x1 = 0.25, w - 0.25
    yc = h / 2
    for px in (x0 + 0.1, x1 - 0.1):
        m.box(px - 0.05, yc - 0.05, 0, px + 0.05, yc + 0.05, 1.3, C["wood_dark"])
    m.box(x0, yc - 0.06, 0.55, x1, yc + 0.06, 1.25, C["wood_light"])
    for i in range(3):
        u0 = x0 + 0.15 + i * (x1 - x0 - 0.3) / 3
        m.box(u0, yc + 0.06, 0.7, u0 + (x1 - x0 - 0.3) / 3 - 0.08, yc + 0.08, 1.1, [C["white"], C["cream"], hex_rgb("#f2e1a8")][i])
    m.gable_roof(x0, yc - 0.15, x1, yc + 0.15, 1.3, 0.2, color, ridge="x")


def farm_building(m: Mesh, item, w, h, rng):
    n = item.get("name", "").lower()
    if "barn" in n:
        barn(m, w, h)
    elif "silo" in n:
        silo(m, w, h)
    elif "farmhouse" in n or "house" in n:
        farmhouse(m, w, h, rng)
    elif has(n, "shop", "stall", "market"):
        market_stall(m, w, h, rng, hue_for(item["id"]))
    elif has(n, "board", "order", "truck", "newspaper", "notice"):
        board(m, w, h, hue_for(item["id"]))
    elif has(n, "mailbox", "mail"):
        mailbox(m, w, h)
    else:
        workshop(m, item, w, h, rng)


def mailbox(m: Mesh, w, h):
    cx, cy = w / 2, h / 2
    m.box(cx - 0.04, cy - 0.04, 0, cx + 0.04, cy + 0.04, 0.6, C["wood_dark"])
    m.box(cx - 0.18, cy - 0.12, 0.6, cx + 0.18, cy + 0.12, 0.82, C["blue"])
    m.cylinder(cx, cy, 0.82, 0.86, 0.12, C["blue"], segs=10)
    m.box(cx + 0.18, cy - 0.02, 0.75, cx + 0.2, cy + 0.02, 0.98, C["red"])


# ---------------------------------------------------------------------------
# Animals, fields, trees
# ---------------------------------------------------------------------------

def animal_home(m: Mesh, item, w, h, rng):
    n = item.get("name", "").lower()
    kinds = ["chicken", "cow", "pig", "sheep", "goat", "horse", "donkey", "duck", "rabbit", "cat", "dog"]
    kind = next((k for k in kinds if k in n), None)
    if kind is None and has(n, "coop", "hen"):
        kind = "chicken"
    if kind is None and has(n, "pasture", "dairy"):
        kind = "cow"
    if kind is None and has(n, "pen", "sty"):
        kind = "pig"
    if has(n, "bee", "hive", "apiary"):
        beehive(m, w, h)
        return
    if has(n, "fish", "pond", "lobster", "duck"):
        pond(m, w, h, rng, with_animal="duck" if "duck" in n else None)
        return
    if kind is None:
        workshop(m, item, w, h, rng)
        return
    floor = C["mud"] if kind == "pig" else mix(C["grass"], C["hay"], 0.35)
    ground_patch(m, 0.08, 0.08, w - 0.08, h - 0.08, floor, z=0.03)
    fence_ring(m, 0.12, 0.12, w - 0.12, h - 0.12, gap_side="+y")
    # Shelter in the back corner.
    roof = hue_for(item["id"])
    sx1 = min(w * 0.55, 1.6)
    sy1 = min(h * 0.55, 1.6)
    if kind == "chicken":
        m.box(0.3, 0.3, 0.25, sx1, sy1, 0.95, C["wood_light"])
        for px, py in ((0.35, 0.35), (sx1 - 0.05, 0.35), (0.35, sy1 - 0.05), (sx1 - 0.05, sy1 - 0.05)):
            m.box(px - 0.04, py - 0.04, 0, px + 0.04, py + 0.04, 0.25, C["wood_dark"])
        m.gable_roof(0.3, 0.3, sx1, sy1, 0.95, 0.45, roof, ridge="x", gable_color=C["wood_light"])
        m.facade_poly("+y", 0.3, 0.3, sx1, sy1, [(0.38, 0.25), (0.62, 0.25), (0.62, 0.6), (0.38, 0.6)], C["wood_dark"], offset=0.015)
        m.poly([((0.3 + sx1) / 2 - 0.12, sy1, 0.25), ((0.3 + sx1) / 2 + 0.12, sy1, 0.25), ((0.3 + sx1) / 2 + 0.12, sy1 + 0.45, 0.03), ((0.3 + sx1) / 2 - 0.12, sy1 + 0.45, 0.03)], C["wood"], normal=(0, 0.5, 1))
    else:
        for px, py in ((0.35, 0.35), (sx1, 0.35), (0.35, sy1), (sx1, sy1)):
            m.box(px - 0.05, py - 0.05, 0, px + 0.05, py + 0.05, 1.0, C["wood"])
        m.box(0.3, 0.3, 0, sx1, 0.38, 0.9, C["wood_light"])
        m.box(0.3, 0.3, 0, 0.38, sy1, 0.9, C["wood_light"])
        m.gable_roof(0.3, 0.3, sx1, sy1, 1.0, 0.4, roof, ridge="y" if w > h else "x", overhang=0.15)
        m.box(0.45, 0.45, 0, sx1 - 0.1, sy1 - 0.1, 0.12, C["hay"], top=C["hay"])
    # Trough
    tx, ty = w - 0.7, 0.4
    m.box(tx, ty, 0, tx + 0.45, ty + 0.22, 0.2, C["wood"])
    m.box(tx + 0.04, ty + 0.04, 0.16, tx + 0.41, ty + 0.18, 0.19, C["hay"] if kind != "pig" else C["mud"], flags=8)
    # Animals
    count = 3 if kind == "chicken" else 2
    spots = [(w * 0.68, h * 0.7), (w * 0.4, h * 0.78), (w * 0.78, h * 0.45)]
    for i in range(count):
        ax, ay = spots[i]
        animal(m, kind, ax, ay, facing=1 if i % 2 == 0 else -1)


def beehive(m: Mesh, w, h):
    ground_patch(m, 0.1, 0.1, w - 0.1, h - 0.1, mix(C["grass"], C["leaf_light"], 0.3))
    spots = [(w * 0.3, h * 0.3), (w * 0.65, h * 0.55), (w * 0.3, h * 0.72)] if min(w, h) >= 2 else [(w / 2, h / 2)]
    for (cx, cy) in spots:
        m.box(cx - 0.2, cy - 0.2, 0, cx + 0.2, cy + 0.2, 0.12, C["wood_dark"])
        for i in range(3):
            col = C["white"] if i % 2 == 0 else hex_rgb("#f2d27a")
            m.box(cx - 0.18, cy - 0.18, 0.12 + i * 0.16, cx + 0.18, cy + 0.18, 0.28 + i * 0.16, col)
        m.gable_roof(cx - 0.2, cy - 0.2, cx + 0.2, cy + 0.2, 0.6, 0.15, C["wood"], ridge="x", overhang=0.04)
    if min(w, h) >= 2:
        flowers(m, 0.15, h * 0.75, w * 0.6, h - 0.15, [C["yellow"], C["pink"], C["white"]], np.random.default_rng(5), density=6)


def field(m: Mesh, w, h, rng):
    soil = C["soil"]
    m.box(0.06, 0.06, 0, w - 0.06, h - 0.06, 0.08, soil, top=mix(soil, C["soil_dark"], 0.1))
    rows = max(2, int(round(w * 2)))
    for i in range(rows):
        y = 0.18 + (h - 0.36) * (i + 0.5) / rows
        m.box(0.14, y - 0.07, 0.08, w - 0.14, y + 0.07, 0.13, mix(soil, C["wood"], 0.25))
        for j in range(max(2, int(w * 2))):
            x = 0.3 + (w - 0.6) * (j + 0.5) / max(2, int(w * 2))
            m.cone(x, y, 0.13, 0.13, 0.05, C["leaf_light"], segs=6)


def fruit_tree(m: Mesh, item, w, h, rng):
    n = item.get("name", "").lower()
    size = min(w, h)
    cx, cy = w / 2, h / 2
    if has(n, "coconut", "palm", "banana", "date"):
        palm(m, cx, cy, 1.9 * size ** 0.5, fruit_color(n))
        return
    round_tree(m, cx, cy, 1.5 + 0.55 * size, 0.42 * size + 0.12, fruit=fruit_color(n), rng=rng)


def palm(m: Mesh, cx, cy, height, fruit):
    segs = 6
    x, y = cx, cy
    for i in range(segs):
        z0 = height * i / segs
        z1 = height * (i + 1) / segs
        lean = 0.04 * i
        m.cylinder(x + lean, y - lean * 0.3, z0, z1 + 0.02, 0.09 - 0.006 * i, mix(C["wood"], C["sand"], 0.3 * (i % 2)), segs=8)
    tx, ty, tz = x + 0.04 * segs, y - 0.012 * segs, height
    for k in range(7):
        a = k * 2 * math.pi / 7
        lx, ly = math.cos(a) * 0.55, math.sin(a) * 0.55
        m.ellipsoid(tx + lx, ty + ly, tz - 0.08, 0.42, 0.42, 0.06, mix(C["leaf"], C["leaf_dark"], (k % 2) * 0.3), segs=10, rings=4)
    for k in range(3):
        a = 0.5 + k * 0.6
        m.ellipsoid(tx + math.cos(a) * 0.12, ty + math.sin(a) * 0.12, tz - 0.15, 0.08, 0.08, 0.08, fruit, segs=8, rings=5)


# ---------------------------------------------------------------------------
# Connected fences and paths (mask bits: 1=NE(-y) 2=SE(+x) 4=SW(+y) 8=NW(-x))
# ---------------------------------------------------------------------------

def fence_style(name: str):
    n = name.lower()
    if has(n, "hedge", "bush", "topiary"):
        return "hedge", C["leaf"]
    if has(n, "stone", "rock", "brick", "wall"):
        return "stone", C["stone"]
    if has(n, "iron", "metal", "steel", "wrought"):
        return "iron", C["black"]
    if has(n, "white", "picket"):
        return "picket", C["white"]
    if has(n, "bamboo"):
        return "bamboo", hex_rgb("#c9b45a")
    if has(n, "candy", "pink"):
        return "picket", C["pink"]
    return "wood", C["wood_light"]


def fence(m: Mesh, item, w, h, mask):
    style, col = fence_style(item.get("name", ""))
    cx, cy = w / 2, h / 2
    ends = {1: (cx, 0.0), 2: (float(w), cy), 4: (cx, float(h)), 8: (0.0, cy)}
    arms = [b for b in (1, 2, 4, 8) if mask & b]
    if style == "hedge":
        r = 0.32
        m.box(cx - r, cy - r, 0, cx + r, cy + r, 0.55, col, top=mix(col, C["leaf_light"], 0.25))
        for b in arms:
            ex, ey = ends[b]
            m.box(min(cx, ex) - (r if b in (1, 4) else 0), min(cy, ey) - (r if b in (2, 8) else 0), 0,
                  max(cx, ex) + (r if b in (1, 4) else 0), max(cy, ey) + (r if b in (2, 8) else 0), 0.55, col,
                  top=mix(col, C["leaf_light"], 0.25), part=1)
        return
    if style == "stone":
        hgt = 0.42
        r = 0.2
        m.box(cx - r, cy - r, 0, cx + r, cy + r, hgt + 0.08, mix(col, C["stone_dark"], 0.2), top=col)
        for b in arms:
            ex, ey = ends[b]
            t = 0.14
            m.box(min(cx, ex) - (t if b in (1, 4) else 0), min(cy, ey) - (t if b in (2, 8) else 0), 0,
                  max(cx, ex) + (t if b in (1, 4) else 0), max(cy, ey) + (t if b in (2, 8) else 0), hgt, col,
                  top=mix(col, C["white"], 0.15))
        return
    post_h = {"wood": 0.62, "picket": 0.55, "iron": 0.75, "bamboo": 0.7}[style]
    pr = 0.06 if style != "iron" else 0.035
    m.box(cx - pr, cy - pr, 0, cx + pr, cy + pr, post_h, col, top=mix(col, C["white"], 0.15))
    if style == "iron":
        m.ellipsoid(cx, cy, post_h + 0.04, 0.05, 0.05, 0.05, C["gold"], segs=8, rings=4)
    t = 0.025
    for b in arms:
        ex, ey = ends[b]
        lo_x, hi_x = min(cx, ex), max(cx, ex)
        lo_y, hi_y = min(cy, ey), max(cy, ey)
        if b in (1, 4):
            lo_x, hi_x = cx - t, cx + t
        else:
            lo_y, hi_y = cy - t, cy + t
        rails = (0.25, 0.48) if style != "iron" else (0.12, 0.62)
        for z in rails:
            m.box(lo_x, lo_y, z - t, hi_x, hi_y, z + t, col)
        if style == "picket":
            # Pointed boards along the arm
            n = 2
            for i in range(1, n + 1):
                f = i / (n + 0.5)
                px = cx + (ex - cx) * f
                py = cy + (ey - cy) * f
                m.box(px - 0.04, py - 0.04, 0.05, px + 0.04, py + 0.04, post_h - 0.05, col)
                m.cone(px, py, post_h - 0.05, 0.09, 0.05, col, segs=4)
        if style == "iron":
            for i in range(1, 3):
                f = i / 3
                px = cx + (ex - cx) * f
                py = cy + (ey - cy) * f
                m.box(px - 0.012, py - 0.012, 0.05, px + 0.012, py + 0.012, 0.62, col)


def path_style(name: str):
    n = name.lower()
    if has(n, "wood", "plank", "boardwalk"):
        return "plank", C["wood_light"]
    if has(n, "brick"):
        return "brick", C["brick"]
    if has(n, "sand", "dirt", "gravel"):
        return "gravel", C["sand"]
    if has(n, "grass", "moss"):
        return "gravel", mix(C["grass"], C["leaf_light"], 0.3)
    if has(n, "marble", "white", "tile"):
        return "tile", hex_rgb("#ece6dc")
    if has(n, "snow", "ice"):
        return "tile", C["snow"]
    return "cobble", C["stone"]


def path(m: Mesh, item, w, h, mask):
    style, col = path_style(item.get("name", ""))
    inset = 0.07
    x0 = 0.0 if mask & 8 else inset
    x1 = w if mask & 2 else w - inset
    y0 = 0.0 if mask & 1 else inset
    y1 = h if mask & 4 else h - inset
    edge = mix(col, C["black"], 0.25)
    m.box(x0, y0, 0, x1, y1, 0.03, edge, top=mix(col, C["black"], 0.12))
    rng = np.random.default_rng(int(sum(map(ord, item["id"]))))
    if style == "cobble":
        for i in range(3):
            for j in range(3):
                sx = 0.06 + i * 0.31 + rng.uniform(-0.02, 0.02)
                sy = 0.06 + j * 0.31 + rng.uniform(-0.02, 0.02)
                s = mix(col, C["white"], rng.uniform(0, 0.25))
                m.box(max(sx, x0 + 0.02), max(sy, y0 + 0.02), 0.03, min(sx + 0.26, x1 - 0.02), min(sy + 0.26, y1 - 0.02), 0.05, s, top=s)
    elif style == "plank":
        for i in range(4):
            sx = 0.02 + i * 0.245
            m.box(max(sx, x0), y0, 0.03, min(sx + 0.22, x1), y1, 0.06, mix(col, C["wood"], (i % 2) * 0.3))
    elif style == "brick":
        for j in range(4):
            off = 0.12 if j % 2 else 0
            for i in range(3):
                sx = off + i * 0.32 - 0.1
                sy = j * 0.245 + 0.02
                bx0, bx1 = max(sx, x0 + 0.02), min(sx + 0.28, x1 - 0.02)
                if bx1 - bx0 > 0.04:
                    m.box(bx0, max(sy, y0 + 0.02), 0.03, bx1, min(sy + 0.21, y1 - 0.02), 0.05, mix(col, C["white"], rng.uniform(0, 0.15)))
    elif style == "tile":
        for i in range(2):
            for j in range(2):
                sx, sy = 0.04 + i * 0.48, 0.04 + j * 0.48
                m.box(max(sx, x0 + 0.02), max(sy, y0 + 0.02), 0.03, min(sx + 0.44, x1 - 0.02), min(sy + 0.44, y1 - 0.02), 0.05, mix(col, C["stone"], ((i + j) % 2) * 0.2))
    else:
        m.box(x0 + 0.02, y0 + 0.02, 0.03, x1 - 0.02, y1 - 0.02, 0.045, col, top=col)
        for i in range(10):
            px, py = rng.uniform(x0 + 0.1, x1 - 0.1), rng.uniform(y0 + 0.1, y1 - 0.1)
            m.ellipsoid(px, py, 0.05, 0.035, 0.035, 0.02, mix(col, C["stone_dark"], 0.4), segs=6, rings=3)


# ---------------------------------------------------------------------------
# Decorations
# ---------------------------------------------------------------------------

def pond(m: Mesh, w, h, rng, with_animal=None):
    cx, cy = w / 2, h / 2
    rx, ry = w * 0.44, h * 0.44
    pts = [(cx + rx * math.cos(a) * (1 + 0.06 * math.sin(3 * a)), cy + ry * math.sin(a) * (1 + 0.06 * math.cos(2 * a)))
           for a in np.linspace(0, 2 * math.pi, 28, endpoint=False)]
    m.flat(pts, 0.03, C["water"])
    inner = [(cx + (x - cx) * 0.6, cy + (y - cy) * 0.6) for x, y in pts]
    m.flat(inner, 0.035, mix(C["water"], C["water_deep"], 0.6), flags=8)
    for i, (x, y) in enumerate(pts):
        if i % 2 == 0:
            m.ellipsoid(x, y, 0.06, 0.13, 0.13, 0.09, mix(C["stone"], C["white"], rng.uniform(0, 0.3)), segs=8, rings=4, zmin=0)
    for k in range(3):
        a = rng.uniform(0, 2 * math.pi)
        lx, ly = cx + math.cos(a) * rx * 0.45, cy + math.sin(a) * ry * 0.45
        m.flat([(lx + 0.12 * math.cos(t), ly + 0.12 * math.sin(t)) for t in np.linspace(0.3, 2 * math.pi, 12)], 0.045, C["leaf"], flags=8)
    if with_animal:
        animal(m, with_animal, cx, cy, scale=1.2)


def fountain(m: Mesh, w, h):
    cx, cy = w / 2, h / 2
    r = min(w, h) * 0.44
    m.cylinder(cx, cy, 0, 0.3, r, C["stone"], segs=24, top=C["stone_dark"])
    m.cylinder(cx, cy, 0.22, 0.29, r * 0.86, C["water"], segs=24, flags=8)
    m.cylinder(cx, cy, 0.29, 0.8, r * 0.14, C["stone"], segs=12)
    m.cylinder(cx, cy, 0.8, 0.9, r * 0.45, C["stone"], segs=18, top=C["water"])
    m.cylinder(cx, cy, 0.9, 1.25, r * 0.08, C["stone"], segs=10)
    m.ellipsoid(cx, cy, 1.32, r * 0.1, r * 0.1, r * 0.12, C["glass"], segs=10, rings=6, flags=2)


def bench(m: Mesh, w, h, color):
    along_x = w >= h
    x0, y0, x1, y1 = 0.12, 0.25, w - 0.12, h - 0.25
    if not along_x:
        x0, y0, x1, y1 = 0.25, 0.12, w - 0.25, h - 0.12
    m.box(x0, y0, 0.28, x1, y1, 0.34, color)
    for px, py in ((x0 + 0.05, y0 + 0.05), (x1 - 0.1, y0 + 0.05), (x0 + 0.05, y1 - 0.1), (x1 - 0.1, y1 - 0.1)):
        m.box(px, py, 0, px + 0.05, py + 0.05, 0.28, C["metal_dark"])
    if along_x:
        m.box(x0, y0, 0.34, x1, y0 + 0.06, 0.7, color)
    else:
        m.box(x0, y0, 0.34, x0 + 0.06, y1, 0.7, color)


def lamp(m: Mesh, w, h, color):
    cx, cy = w / 2, h / 2
    m.cylinder(cx, cy, 0, 0.12, 0.12, C["metal_dark"], segs=10)
    m.cylinder(cx, cy, 0.12, 1.45, 0.035, color, segs=8)
    m.box(cx - 0.11, cy - 0.11, 1.45, cx + 0.11, cy + 0.11, 1.72, C["lamp"], flags=2)
    m.hip_roof(cx - 0.11, cy - 0.11, cx + 0.11, cy + 0.11, 1.72, 0.12, color, overhang=0.04)


def statue(m: Mesh, w, h, color, rng):
    cx, cy = w / 2, h / 2
    s = min(w, h)
    m.box(cx - 0.32 * s, cy - 0.32 * s, 0, cx + 0.32 * s, cy + 0.32 * s, 0.35 * s, C["stone"], top=mix(C["stone"], C["white"], 0.2))
    z = 0.35 * s
    m.ellipsoid(cx, cy, z + 0.35 * s, 0.17 * s, 0.17 * s, 0.32 * s, color, segs=14, rings=8)
    m.ellipsoid(cx, cy, z + 0.8 * s, 0.13 * s, 0.13 * s, 0.13 * s, color, segs=12, rings=8)
    m.ellipsoid(cx + 0.15 * s, cy + 0.05 * s, z + 0.45 * s, 0.06 * s, 0.06 * s, 0.17 * s, color, segs=8, rings=5)


def gazebo(m: Mesh, w, h, roof):
    cx, cy = w / 2, h / 2
    r = min(w, h) * 0.42
    m.cylinder(cx, cy, 0, 0.12, r, C["wood_light"], segs=8)
    for k in range(6):
        a = k * math.pi / 3 + 0.3
        px, py = cx + math.cos(a) * r * 0.85, cy + math.sin(a) * r * 0.85
        m.cylinder(px, py, 0.12, 1.3, 0.05, C["white"], segs=6)
    m.cone(cx, cy, 1.3, 0.8, r * 1.1, roof, segs=8)
    m.ellipsoid(cx, cy, 2.12, 0.07, 0.07, 0.07, C["gold"], segs=6, rings=4)


def windmill(m: Mesh, w, h, roof):
    cx, cy = w / 2, h / 2
    r = min(w, h) * 0.32
    m.cylinder(cx, cy, 0, 2.0, r, C["cream"], segs=12, r_top=r * 0.7)
    m.cone(cx, cy, 2.0, 0.6, r * 0.85, roof, segs=12)
    hub = (cx + r * 0.78, cy + r * 0.78, 1.8)
    for k in range(4):
        a = k * math.pi / 2 + 0.4
        dx, dz = math.cos(a), math.sin(a)
        u = np.array([0.7071, -0.7071, 0.0]) * dx + np.array([0, 0, 1.0]) * dz
        p0 = np.array(hub) + np.array([0.05, 0.05, 0])
        perp = np.array([0.7071, -0.7071, 0.0]) * (-dz) + np.array([0, 0, 1.0]) * dx
        q = [p0 + u * 0.15 - perp * 0.1, p0 + u * 1.1 - perp * 0.12, p0 + u * 1.1 + perp * 0.12, p0 + u * 0.15 + perp * 0.1]
        m.poly(q, C["white"], normal=(1, 1, 0), flags=1)
    m.ellipsoid(*hub, 0.1, 0.1, 0.1, C["wood_dark"], segs=8, rings=5)


def rocks(m: Mesh, w, h, rng):
    n = 3 + int(rng.integers(3))
    for i in range(n):
        cx = rng.uniform(0.3, w - 0.3)
        cy = rng.uniform(0.3, h - 0.3)
        r = rng.uniform(0.18, 0.35) * min(w, h) ** 0.5
        m.ellipsoid(cx, cy, r * 0.5, r, r * 0.9, r * 0.75, mix(C["stone"], C["stone_dark"], rng.uniform(0, 0.6)), segs=9, rings=5, zmin=0)


def flowerbed(m: Mesh, item, w, h, rng):
    n = item.get("name", "").lower()
    palette = {
        "tulip": [C["red"], C["yellow"], C["pink"]], "rose": [C["red"], C["pink"]], "sunflower": [C["yellow"]],
        "lavender": [C["purple"]], "daisy": [C["white"]], "violet": [C["purple"], C["blue"]],
    }
    cols = next((v for k, v in palette.items() if k in n), [C["red"], C["yellow"], C["pink"], C["white"], C["purple"]])
    if has(n, "pot", "planter", "vase"):
        cx, cy = w / 2, h / 2
        r = min(w, h) * 0.32
        m.cylinder(cx, cy, 0, 0.45, r * 0.75, C["brick"], segs=14, r_top=r, top=C["soil"])
        bush(m, cx, cy, r * 0.8, berries=cols[0], rng=rng, n_berries=8)
        return
    m.box(0.08, 0.08, 0, w - 0.08, h - 0.08, 0.1, C["wood"], top=C["soil"])
    flowers(m, 0.1, 0.1, w - 0.1, h - 0.1, cols, rng, density=12, stem=0.16 if "sunflower" not in n else 0.5)


def monument(m: Mesh, w, h, rng, color):
    """Fallback: a tasteful pedestal + abstract sculpture, sized to footprint."""
    cx, cy = w / 2, h / 2
    s = min(w, h)
    m.box(cx - 0.36 * s, cy - 0.36 * s, 0, cx + 0.36 * s, cy + 0.36 * s, 0.18 * s, C["stone"], top=mix(C["stone"], C["white"], 0.25))
    kind = int(rng.integers(3))
    if kind == 0:
        m.ellipsoid(cx, cy, 0.18 * s + 0.32 * s, 0.28 * s, 0.28 * s, 0.32 * s, color, segs=16, rings=10)
    elif kind == 1:
        m.cylinder(cx, cy, 0.18 * s, 0.9 * s, 0.14 * s, color, segs=4, r_top=0.03 * s)
    else:
        m.box(cx - 0.18 * s, cy - 0.18 * s, 0.18 * s, cx + 0.18 * s, cy + 0.18 * s, 0.6 * s, color)
        m.ellipsoid(cx, cy, 0.75 * s, 0.14 * s, 0.14 * s, 0.14 * s, C["gold"], segs=10, rings=6)


COLOR_WORDS = [("gold", "#e7b83f"), ("silver", "#c9cdd2"), ("red", "#cf4e3e"), ("pink", "#e389a8"),
               ("blue", "#4b7fc4"), ("green", "#5aa65a"), ("yellow", "#efc94c"), ("orange", "#e58a3a"),
               ("purple", "#8a62b5"), ("white", "#f3efe6"), ("black", "#3b3533"), ("dark", "#4a4040"),
               ("brown", "#8a5a36"), ("rainbow", "#d96aa8"), ("crystal", "#a9d8ef"), ("ice", "#cfe9f5"),
               ("snow", "#f4f7fb"), ("teal", "#3e9e9a"), ("lilac", "#b59ad6"), ("lavender", "#9b7fc4")]

DECO_KINDS = [
    ("fountain", ("fountain",)), ("pond", ("pond", "lake", "pool", "puddle")), ("bench", ("bench", "seat", "sofa", "chair", "stool")),
    ("lamp", ("lamp", "lantern", "light", "streetlight", "torch", "candle")), ("statue", ("statue", "sculpture", "bust", "gnome", "figure")),
    ("gazebo", ("gazebo", "pavilion", "bandstand")), ("windmill", ("windmill",)), ("rocks", ("rock", "boulder", "stones", "pebble")),
    ("pine", ("pine", "fir", "spruce", "christmas tree", "xmas tree")), ("palm", ("palm",)),
    ("tree", ("tree", "oak", "maple", "birch", "willow", "blossom", "sakura")),
    ("bush", ("bush", "shrub", "topiary", "hedge", "fern", "plant", "cactus")),
    ("flowerbed", ("flower", "tulip", "rose", "daisy", "garden", "bed", "planter", "pot", "sunflower", "lavender", "violet", "crocus", "lily", "orchid", "gazania")),
    ("pumpkin", ("pumpkin", "gourd")), ("snowman", ("snowman",)), ("hay", ("hay", "straw")), ("well", ("well",)),
    ("table", ("table", "picnic")), ("umbrella", ("umbrella", "parasol")), ("arch", ("arch", "arbor", "gate", "pergola", "trellis")),
    ("sign", ("sign", "board", "poster", "letter", "icon", "post", "billboard")), ("flag", ("flag", "banner")), ("cart", ("cart", "wagon", "wheelbarrow", "tractor", "bike", "car")),
    ("crate", ("crate", "box", "gift", "present")), ("barrel", ("barrel", "keg")), ("tent", ("tent", "teepee")), ("bridge", ("bridge",)),
    ("scarecrow", ("scarecrow",)), ("birdhouse", ("birdhouse", "bird house", "wren", "nest box")),
    ("balloon", ("balloon",)), ("swing", ("swing", "hammock")), ("ferris", ("ferris", "carousel", "merry")),
    ("cake", ("cake", "cupcake", "pie")), ("trophy", ("trophy", "cup", "medal")), ("mushroom", ("mushroom", "toadstool")),
    ("tile", ("tile", "carpet", "rug", "mat", "patch", "plowed", "mosaic")), ("eggs", ("egg", "nest")),
    ("cannon", ("cannon", "telescope")),
    ("animal", ("chicken", "chick", "hen", "rooster", "sheep", "lamb", "bunny", "rabbit", "horse", "pony", "goat", "cow",
                "pig", "fox", "peacock", "alpaca", "llama", "puppy", "dog", "cat", "kitten", "reindeer", "deer", "duck",
                "swan", "frog", "turtle", "tortoise", "snail", "owl", "bear", "squirrel", "hedgehog", "donkey", "raven",
                "crow", "flamingo", "penguin", "seal", "dino", "dragon")),
    ("building", ("house", "cottage", "hut", "cabin", "shed", "tower", "castle", "church", "mill", "barn", "temple", "pagoda", "kiosk", "stand", "stall", "booth", "shop")),
]


def deco_kind(item) -> str:
    n = item.get("name", "").lower()
    if item.get("category") == "water" and not any(k in n for k in ("fountain",)):
        return "pond" if not any(k in n for k in ("statue", "lamp", "bench")) else _match(n)
    if item.get("category") == "flowers":
        k = _match(n)
        return k if k in ("flowerbed", "arch", "bush", "tree") else "flowerbed"
    return _match(n)


def _match(n: str) -> str:
    for kind, words in DECO_KINDS:
        if any(re.search(r"\b" + re.escape(w), n) for w in words):
            return kind
    return "monument"


def color_word(name: str):
    n = name.lower()
    for w, col in COLOR_WORDS:
        if w in n:
            return w, hex_rgb(col)
    return None, None


def decoration(m: Mesh, item, w, h, rng, sig: str = ""):
    n = item.get("name", "").lower()
    kind = deco_kind(item)
    cw, ccol = color_word(n)
    col = ccol if ccol is not None else hue_for(sig or item["id"])
    s = min(w, h)
    if kind == "pond":
        pond(m, w, h, rng)
    elif kind == "fountain":
        fountain(m, w, h)
    elif kind == "bench":
        bench(m, w, h, ccol if ccol is not None else C["wood"])
    elif kind == "lamp":
        lamp(m, w, h, ccol if ccol is not None else C["black"])
    elif kind == "statue":
        statue(m, w, h, ccol if ccol is not None else mix(C["stone"], C["white"], 0.3), rng)
    elif kind == "gazebo":
        gazebo(m, w, h, col)
    elif kind == "windmill":
        windmill(m, w, h, col)
    elif kind == "rocks":
        rocks(m, w, h, rng)
    elif kind == "pine":
        pine(m, w / 2, h / 2, 1.6 + 0.5 * s, 0.4 * s, snow=has(n, "snow"), ornaments=has(n, "christmas", "xmas", "holiday"), rng=rng)
    elif kind == "palm":
        palm(m, w / 2, h / 2, 1.8 * s ** 0.5, C["wood"])
    elif kind == "tree":
        leaf = C["leaf"]
        if has(n, "autumn", "maple", "fall"):
            leaf = C["orange"]
        if has(n, "blossom", "sakura", "cherry"):
            leaf = mix(C["pink"], C["white"], 0.3)
        if ccol is not None and cw not in ("dark", "black", "brown"):
            leaf = mix(leaf, ccol, 0.6)
        if has(n, "dark"):
            leaf = C["leaf_dark"]
        trunk = C["white"] if "birch" in n else None
        round_tree(m, w / 2, h / 2, 1.4 + 0.6 * s, 0.38 * s + 0.15, leaf=leaf, trunk=trunk, rng=rng)
    elif kind == "bush":
        bush(m, w / 2, h / 2, s * 0.4, leaf=mix(C["leaf"], ccol, 0.4) if ccol is not None else None, rng=rng)
    elif kind == "flowerbed":
        flowerbed(m, item, w, h, rng)
    elif kind == "pumpkin":
        for i, (dx, dy, r) in enumerate(((0.5, 0.5, 0.3), (0.25, 0.75, 0.2), (0.78, 0.3, 0.18))):
            if i and s < 1:
                break
            m.ellipsoid(w * dx, h * dy, r * s * 0.7, r * s, r * s, r * s * 0.7, C["orange"], segs=12, rings=8, zmin=0)
            m.cylinder(w * dx, h * dy, r * s * 1.3, r * s * 1.55, 0.03, C["leaf_dark"], segs=6)
    elif kind == "snowman":
        cx, cy = w / 2, h / 2
        for z, r in ((0.3, 0.3), (0.78, 0.22), (1.12, 0.15)):
            m.ellipsoid(cx, cy, z * s, r * s, r * s, r * s, C["snow"], segs=14, rings=8)
        m.cone(cx + 0.12 * s, cy + 0.12 * s, 1.12 * s, 0.05, 0.03, C["orange"], segs=6)
        m.cylinder(cx, cy, 1.24 * s, 1.5 * s, 0.11 * s, C["black"], segs=12)
    elif kind == "hay":
        n_b = max(1, int(round(max(w, h))))
        along_x = w >= h
        for i in range(n_b):
            if along_x:
                m.box(0.1 + i, h / 2 - 0.28, 0, 0.9 + i, h / 2 + 0.28, 0.45, C["hay"])
            else:
                m.box(w / 2 - 0.28, 0.1 + i, 0, w / 2 + 0.28, 0.9 + i, 0.45, C["hay"])
    elif kind == "well":
        cx, cy = w / 2, h / 2
        r = s * 0.35
        m.cylinder(cx, cy, 0, 0.45, r, C["stone"], segs=16, top=C["water_deep"])
        for dx in (-r * 0.85, r * 0.85):
            m.box(cx + dx - 0.04, cy - 0.04, 0.45, cx + dx + 0.04, cy + 0.04, 1.3, C["wood"])
        m.gable_roof(cx - r - 0.05, cy - r * 0.6, cx + r + 0.05, cy + r * 0.6, 1.3, 0.35, col, ridge="x")
    elif kind == "table":
        m.box(0.25, 0.25, 0.42, w - 0.25, h - 0.25, 0.48, ccol if ccol is not None else C["wood_light"])
        m.box(w / 2 - 0.06, h / 2 - 0.06, 0, w / 2 + 0.06, h / 2 + 0.06, 0.42, C["wood_dark"])
    elif kind == "umbrella":
        m.cylinder(w / 2, h / 2, 0, 1.3, 0.03, C["white"], segs=6)
        m.cone(w / 2, h / 2, 1.1, 0.35, 0.5 * s, col, segs=12)
    elif kind == "arch":
        x0, x1 = 0.15, w - 0.15
        yc = h / 2
        pc = ccol if ccol is not None else C["white"]
        for px in (x0, x1 - 0.1):
            m.box(px, yc - 0.06, 0, px + 0.1, yc + 0.06, 1.4, pc)
        m.box(x0, yc - 0.08, 1.35, x1, yc + 0.08, 1.5, pc)
        for i in range(5):
            m.ellipsoid(x0 + (x1 - x0) * i / 4, yc, 1.5, 0.14, 0.14, 0.1, C["leaf"], segs=8, rings=5)
            m.ellipsoid(x0 + (x1 - x0) * i / 4 + 0.05, yc + 0.08, 1.52, 0.04, 0.04, 0.04, C["pink"], segs=6, rings=4)
    elif kind == "sign":
        board(m, w, h, col)
    elif kind == "flag":
        m.cylinder(w / 2, h / 2, 0, 1.8, 0.03, C["white"], segs=6)
        m.poly([(w / 2, h / 2, 1.75), (w / 2 + 0.5, h / 2 - 0.5, 1.6), (w / 2 + 0.5, h / 2 - 0.5, 1.3), (w / 2, h / 2, 1.42)], col, normal=(1, 1, 0), flags=1)
    elif kind == "cart":
        m.box(0.2, 0.3, 0.25, w - 0.2, h - 0.3, 0.6, ccol if ccol is not None else C["wood"])
        m.box(0.28, 0.38, 0.55, w - 0.28, h - 0.38, 0.62, C["hay"])
        for px in (0.4, w - 0.4):
            m.cylinder(px, h - 0.28, 0.0, 0.05, 0.22, C["wood_dark"], segs=12)
    elif kind == "crate":
        crate(m, w / 2 - 0.2, h / 2 - 0.2, 0.4, color=ccol)
        if s >= 2:
            crate(m, w / 2 + 0.25, h / 2 - 0.6, 0.35, color=ccol)
    elif kind == "barrel":
        barrel(m, w / 2, h / 2, 0.22, 0.5)
    elif kind == "tent":
        m.gable_roof(0.2, 0.2, w - 0.2, h - 0.2, 0.0, 1.1, col, ridge="x", overhang=0.0, gable_color=mix(col, C["white"], 0.3))
    elif kind == "bridge":
        m.box(0.1, h / 2 - 0.35, 0.15, w - 0.1, h / 2 + 0.35, 0.25, C["wood_light"])
        for px in (0.15, w - 0.25):
            for py in (h / 2 - 0.35, h / 2 + 0.3):
                m.box(px, py, 0, px + 0.08, py + 0.05, 0.6, C["wood"])
    elif kind == "scarecrow":
        cx, cy = w / 2, h / 2
        m.box(cx - 0.04, cy - 0.04, 0, cx + 0.04, cy + 0.04, 1.3, C["wood"])
        m.box(cx - 0.4, cy - 0.03, 0.95, cx + 0.4, cy + 0.03, 1.02, C["wood"])
        m.box(cx - 0.18, cy - 0.12, 0.55, cx + 0.18, cy + 0.12, 1.05, C["blue"])
        m.ellipsoid(cx, cy, 1.22, 0.14, 0.14, 0.14, C["sand"], segs=10, rings=6)
        m.cone(cx, cy, 1.3, 0.3, 0.24, C["hay"], segs=10)
    elif kind == "birdhouse":
        m.cylinder(w / 2, h / 2, 0, 1.0, 0.03, C["wood_dark"], segs=6)
        m.box(w / 2 - 0.15, h / 2 - 0.15, 1.0, w / 2 + 0.15, h / 2 + 0.15, 1.3, col)
        m.gable_roof(w / 2 - 0.15, h / 2 - 0.15, w / 2 + 0.15, h / 2 + 0.15, 1.3, 0.15, C["red"], ridge="x")
    elif kind == "balloon":
        cx, cy = w / 2, h / 2
        m.box(cx - 0.12, cy - 0.12, 0, cx + 0.12, cy + 0.12, 0.12, C["stone"])
        cols = [C["red"], C["yellow"], C["blue"], C["pink"], C["green"]] if ccol is None else [ccol, mix(ccol, C["white"], 0.4)]
        for i in range(5):
            a = i * 2 * math.pi / 5
            bx, by, bz = cx + math.cos(a) * 0.22, cy + math.sin(a) * 0.22, 1.2 + 0.18 * (i % 2)
            m.box(cx - 0.006, cy - 0.006, 0.12, cx + 0.006, cy + 0.006, bz - 0.15, C["white"], part=0)
            m.ellipsoid(bx, by, bz, 0.17, 0.17, 0.21, cols[i % len(cols)], segs=10, rings=7)
    elif kind == "swing":
        x0, x1 = 0.15, w - 0.15
        yc = h / 2
        fc = ccol if ccol is not None else C["wood"]
        for px in (x0, x1 - 0.08):
            m.box(px, yc - 0.3, 0, px + 0.08, yc - 0.22, 1.3, fc)
            m.box(px, yc + 0.22, 0, px + 0.08, yc + 0.3, 1.3, fc)
        m.box(x0, yc - 0.04, 1.25, x1, yc + 0.04, 1.33, fc)
        m.box(w / 2 - 0.25, yc - 0.12, 0.4, w / 2 + 0.25, yc + 0.12, 0.46, C["wood_light"])
        for dx in (-0.22, 0.22):
            m.box(w / 2 + dx - 0.01, yc - 0.01, 0.46, w / 2 + dx + 0.01, yc + 0.01, 1.25, C["stone_dark"])
    elif kind == "ferris":
        cx, cy = w / 2, h / 2
        r = s * 0.42
        m.box(cx - r * 0.6, cy - 0.15, 0, cx + r * 0.6, cy + 0.15, 0.12, C["stone"])
        for k in range(12):
            a = k * math.pi / 6
            px, pz = cx + math.cos(a) * r, r + 0.25 + math.sin(a) * r
            m.box(px - 0.02, cy - 0.02, pz - 0.02, px + 0.02, cy + 0.02, pz + 0.02, C["white"])
            m.box(px - 0.08, cy - 0.06, pz - 0.18, px + 0.08, cy + 0.06, pz - 0.02, [C["red"], C["yellow"], C["blue"]][k % 3])
            m.poly([(cx, cy + 0.03, r + 0.25), (px, cy + 0.03, pz), (px + 0.02, cy + 0.03, pz + 0.02)], C["white"], normal=(0, 1, 0), flags=1)
        m.ellipsoid(cx, cy, r + 0.25, 0.08, 0.08, 0.08, C["gold"], segs=8, rings=5)
    elif kind == "cake":
        cx, cy = w / 2, h / 2
        r = s * 0.38
        fc = ccol if ccol is not None else C["pink"]
        for i, k in enumerate((1.0, 0.75, 0.5)):
            m.cylinder(cx, cy, 0.3 * i * s, 0.3 * (i + 1) * s, r * k, mix(fc, C["white"], 0.4 * (i % 2)), segs=18, top=C["white"])
        m.ellipsoid(cx, cy, 0.95 * s, 0.07 * s, 0.07 * s, 0.07 * s, C["red"], segs=8, rings=5)
    elif kind == "trophy":
        cx, cy = w / 2, h / 2
        m.box(cx - 0.25 * s, cy - 0.25 * s, 0, cx + 0.25 * s, cy + 0.25 * s, 0.25 * s, C["wood_dark"])
        m.cylinder(cx, cy, 0.25 * s, 0.5 * s, 0.05 * s, C["gold"], segs=10)
        m.cylinder(cx, cy, 0.5 * s, 0.95 * s, 0.1 * s, C["gold"], segs=16, r_top=0.25 * s)
    elif kind == "mushroom":
        cx, cy = w / 2, h / 2
        cap = ccol if ccol is not None else C["red"]
        for (dx, dy, k) in ((0, 0, 1.0), (0.28, 0.25, 0.6), (-0.25, 0.3, 0.45)):
            if k < 1.0 and s < 1:
                pass
            m.cylinder(cx + dx * s, cy + dy * s, 0, 0.45 * k * s, 0.08 * k * s, C["cream"], segs=10)
            m.ellipsoid(cx + dx * s, cy + dy * s, 0.45 * k * s, 0.26 * k * s, 0.26 * k * s, 0.16 * k * s, cap, segs=12, rings=7, zmin=0.45 * k * s)
    elif kind == "tile":
        fc = ccol if ccol is not None else mix(C["stone"], hue_for(sig or item["id"]), 0.35)
        m.box(0.04, 0.04, 0, w - 0.04, h - 0.04, 0.04, mix(fc, C["black"], 0.2), top=fc)
        for i in range(int(w * 2)):
            for j in range(int(h * 2)):
                if (i + j) % 2 == 0:
                    m.box(0.08 + i * 0.5, 0.08 + j * 0.5, 0.04, 0.42 + i * 0.5, 0.42 + j * 0.5, 0.055, mix(fc, C["white"], 0.3), flags=8)
    elif kind == "eggs":
        cx, cy = w / 2, h / 2
        m.cylinder(cx, cy, 0, 0.12, 0.3 * s, C["hay"], segs=14, r_top=0.34 * s)
        cols = [C["white"], C["pink"], C["blue"], C["yellow"]] if ccol is None else [ccol]
        for i, (dx, dy) in enumerate(((0, 0), (0.12, 0.1), (-0.1, 0.12), (0.08, -0.12))):
            m.ellipsoid(cx + dx * s, cy + dy * s, 0.22, 0.09, 0.09, 0.12, cols[i % len(cols)], segs=10, rings=6)
    elif kind == "cannon":
        cx, cy = w / 2, h / 2
        m.box(cx - 0.25, cy - 0.2, 0, cx + 0.25, cy + 0.2, 0.25, C["wood"])
        m.cylinder(cx, cy, 0.25, 0.85, 0.11, ccol if ccol is not None else C["metal_dark"], segs=12, r_top=0.08)
    elif kind == "animal":
        n2 = n
        mapping = [("chick", "chicken"), ("hen", "chicken"), ("rooster", "chicken"), ("lamb", "sheep"), ("bunny", "rabbit"),
                   ("pony", "horse"), ("kitten", "cat"), ("puppy", "dog"), ("alpaca", "goat"), ("llama", "goat"),
                   ("reindeer", "goat"), ("deer", "goat"), ("swan", "duck"), ("raven", "duck"), ("crow", "duck"),
                   ("flamingo", "duck"), ("penguin", "duck"), ("fox", "cat"), ("squirrel", "cat"), ("hedgehog", "rabbit"),
                   ("bear", "dog"), ("donkey", "donkey")]
        kind2 = next((k for k in ("chicken", "sheep", "rabbit", "horse", "goat", "cow", "pig", "cat", "dog", "duck", "donkey") if k in n2), None)
        if kind2 is None:
            kind2 = next((v for k, v in mapping if k in n2), "dog")
        ground_patch(m, 0.12, 0.12, w - 0.12, h - 0.12, mix(C["grass"], C["leaf_light"], 0.3), z=0.02)
        count = 1 if s < 2 else 2
        for i in range(count):
            animal(m, kind2, w * (0.5 if count == 1 else 0.35 + 0.3 * i), h * (0.5 if count == 1 else 0.6 - 0.2 * i),
                   facing=1 if i % 2 == 0 else -1, scale=1.6 if kind2 in ("chicken", "duck", "rabbit", "cat") else 1.15)
    elif kind == "building":
        workshop(m, {"id": sig or item["id"], "name": item.get("name", "")}, w, h, rng)
    else:
        monument(m, w, h, rng, col)


def planning_marker(m: Mesh, w, h):
    col = hex_rgb("#7fb3e6")
    m.box(0.06, 0.06, 0, w - 0.06, h - 0.06, 0.04, col, top=mix(col, C["white"], 0.35))
    for (px, py) in ((0.15, 0.15), (w - 0.15, 0.15), (0.15, h - 0.15), (w - 0.15, h - 0.15)):
        m.box(px - 0.03, py - 0.03, 0, px + 0.03, py + 0.03, 0.55, C["wood_light"])
        m.poly([(px, py, 0.55), (px + 0.22, py - 0.22, 0.48), (px, py, 0.4)], hex_rgb("#4b7fc4"), normal=(1, 1, 0), flags=1)


def signature(item: dict) -> str:
    """Items with the same signature render identically and share a sprite."""
    cat = item.get("category", "decoration")
    w, h = item["footprint"]
    name = item.get("name", "")
    conn = (item.get("connect") or {}).get("style", "")
    unique = ("production", "farm_building", "animal_home", "field", "fruit_tree", "bush", "planning")
    if cat in unique:
        return f"u:{item['id']}"
    cw, _ = color_word(name)
    if conn == "fence" or cat == "fence":
        style, _c = fence_style(name)
        return f"fence:{style}:{cw}:{w}x{h}"
    if conn == "path" or cat == "path":
        style, _c = path_style(name)
        return f"path:{style}:{cw}:{w}x{h}"
    kind = deco_kind(item)
    if cw is None:
        bucket = int(hashlib.sha1(item["id"].encode()).hexdigest()[:4], 16) % 6
        cw = f"h{bucket}"
    extra = ""
    if kind in ("pine", "tree"):
        n = name.lower()
        extra = ":" + "".join(k[0] for k in ("snow", "christmas", "autumn", "blossom", "birch", "dark") if k in n)
    return f"{kind}:{cw}:{w}x{h}{extra}"
