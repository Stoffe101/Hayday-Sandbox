"""Reusable model parts: palette, sign glyphs, animals, plants, props."""
from __future__ import annotations

import hashlib
import math

import numpy as np

from iso3d import Mesh, hex_rgb, mix

C = {k: hex_rgb(v) for k, v in {
    "cream": "#f3e5c4", "white": "#f6f2e8", "plaster": "#efd9b4", "wood": "#b07a45", "wood_dark": "#7d522c",
    "wood_light": "#d3a46a", "stone": "#bdb7ab", "stone_dark": "#8e877b", "brick": "#c06a4a",
    "leaf": "#62a646", "leaf_dark": "#3f7d35", "leaf_light": "#8cc65a", "grass": "#86bf5c",
    "soil": "#8b5a3a", "soil_dark": "#6b4229", "mud": "#7a5a3c", "water": "#58b4dc", "water_deep": "#3a8fc4",
    "metal": "#8f99a3", "metal_dark": "#5d6670", "gold": "#e7b83f", "glass": "#a9d8ef", "hay": "#e4c35a",
    "red": "#cf4e3e", "barn_red": "#b8443a", "orange": "#e58a3a", "yellow": "#efc94c", "green": "#5aa65a",
    "teal": "#3e9e9a", "blue": "#4b7fc4", "purple": "#8a62b5", "pink": "#e389a8", "brown": "#8a5a36",
    "black": "#3b3533", "snow": "#f4f7fb", "sand": "#e3cf9a", "lamp": "#ffe08a",
}.items()}

ROOF_HUES = ["#cf5440", "#e0853a", "#d6a836", "#6aa84f", "#3f93a8", "#4f72b8", "#8a5fb0", "#c75d8e",
             "#7d5a44", "#4f8f6a", "#b8453d", "#d9734a", "#5d7fa3", "#a1683c", "#3f7f8f", "#9b4f7a"]


def rng_for(key: str) -> np.random.Generator:
    seed = int(hashlib.sha1(key.encode()).hexdigest()[:8], 16)
    return np.random.default_rng(seed)


def hue_for(key: str) -> np.ndarray:
    h = int(hashlib.sha1(key.encode()).hexdigest()[:6], 16)
    return hex_rgb(ROOF_HUES[h % len(ROOF_HUES)])


def has(name: str, *words) -> bool:
    n = name.lower()
    return any(w in n for w in words)


# ---------------------------------------------------------------------------
# Glyphs: lists of convex polygons in a unit square (u right, v up).
# ---------------------------------------------------------------------------

def _circle(cx, cy, r, n=18, sx=1.0, sy=1.0, a0=0.0, a1=2 * math.pi):
    pts = []
    full = abs(a1 - a0 - 2 * math.pi) < 1e-6
    steps = n if full else n
    for i in range(steps + (0 if full else 1)):
        a = a0 + (a1 - a0) * i / steps
        pts.append((cx + r * sx * math.cos(a), cy + r * sy * math.sin(a)))
    if not full:
        pts.append((cx, cy))
    return pts


def _rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def glyph(kind: str):
    """Returns list of (polygon, shade) where shade in {0: main, 1: accent}."""
    G = []
    if kind == "bread":
        G += [(_circle(0.5, 0.48, 0.3, sx=1.25, sy=0.75), 0)]
        for x in (0.36, 0.5, 0.64):
            G += [(_rect(x - 0.025, 0.38, x + 0.025, 0.6), 1)]
    elif kind == "drop":
        G += [(_circle(0.5, 0.4, 0.22), 0), ([(0.31, 0.47), (0.69, 0.47), (0.5, 0.85)], 0)]
    elif kind == "flame":
        G += [(_circle(0.5, 0.38, 0.2), 0), ([(0.32, 0.45), (0.68, 0.45), (0.55, 0.88)], 0), (_circle(0.5, 0.35, 0.09), 1)]
    elif kind == "star":
        pts = []
        for i in range(10):
            a = math.pi / 2 + i * math.pi / 5
            r = 0.36 if i % 2 == 0 else 0.15
            pts.append((0.5 + r * math.cos(a), 0.5 + r * math.sin(a)))
        inner = [pts[i] for i in range(1, 10, 2)]
        G += [(inner, 0)]
        for i in range(0, 10, 2):
            G += [([pts[i - 1], pts[i], pts[(i + 1) % 10]], 0)]
    elif kind == "heart":
        G += [(_circle(0.39, 0.58, 0.14), 0), (_circle(0.61, 0.58, 0.14), 0), ([(0.26, 0.55), (0.74, 0.55), (0.5, 0.22)], 0)]
    elif kind == "leaf":
        G += [(_circle(0.5, 0.5, 0.3, sx=0.55, sy=1.0), 0), (_rect(0.485, 0.2, 0.515, 0.78), 1)]
    elif kind == "diamond":
        G += [([(0.5, 0.15), (0.78, 0.5), (0.5, 0.85), (0.22, 0.5)], 0), ([(0.5, 0.3), (0.64, 0.5), (0.5, 0.7), (0.36, 0.5)], 1)]
    elif kind == "cup":
        G += [([(0.3, 0.72), (0.66, 0.72), (0.6, 0.28), (0.36, 0.28)], 0), (_circle(0.7, 0.55, 0.09), 0), (_rect(0.25, 0.2, 0.71, 0.26), 1)]
    elif kind == "bottle":
        G += [(_rect(0.36, 0.18, 0.64, 0.6), 0), ([(0.36, 0.6), (0.64, 0.6), (0.56, 0.7), (0.44, 0.7)], 0), (_rect(0.45, 0.7, 0.55, 0.84), 0), (_rect(0.36, 0.33, 0.64, 0.47), 1)]
    elif kind == "flower":
        for i in range(5):
            a = math.pi / 2 + i * 2 * math.pi / 5
            G += [(_circle(0.5 + 0.17 * math.cos(a), 0.52 + 0.17 * math.sin(a), 0.13), 0)]
        G += [(_circle(0.5, 0.52, 0.1), 1)]
    elif kind == "gear":
        G += [(_circle(0.5, 0.5, 0.25), 0)]
        for i in range(8):
            a = i * math.pi / 4
            ca, sa = math.cos(a), math.sin(a)
            px, py = -sa, ca
            c0 = (0.5 + 0.22 * ca, 0.5 + 0.22 * sa)
            c1 = (0.5 + 0.36 * ca, 0.5 + 0.36 * sa)
            w = 0.055
            G += [([(c0[0] + px * w, c0[1] + py * w), (c1[0] + px * w, c1[1] + py * w), (c1[0] - px * w, c1[1] - py * w), (c0[0] - px * w, c0[1] - py * w)], 0)]
        G += [(_circle(0.5, 0.5, 0.09), 1)]
    elif kind == "fish":
        G += [(_circle(0.45, 0.5, 0.24, sx=1.2, sy=0.62), 0), ([(0.7, 0.5), (0.86, 0.66), (0.86, 0.34)], 0), (_circle(0.33, 0.54, 0.035), 1)]
    elif kind == "cake":
        G += [(_rect(0.24, 0.2, 0.76, 0.42), 0), (_rect(0.32, 0.42, 0.68, 0.62), 0), (_rect(0.24, 0.29, 0.76, 0.33), 1), (_circle(0.5, 0.69, 0.07), 1)]
    elif kind == "bowl":
        G += [(_circle(0.5, 0.52, 0.32, a0=math.pi, a1=2 * math.pi), 0), (_rect(0.16, 0.5, 0.84, 0.56), 1), (_circle(0.42, 0.66, 0.05), 1), (_circle(0.56, 0.7, 0.04), 1)]
    elif kind == "spool":
        G += [(_rect(0.36, 0.28, 0.64, 0.72), 0), (_rect(0.28, 0.2, 0.72, 0.28), 1), (_rect(0.28, 0.72, 0.72, 0.8), 1)]
    elif kind == "hexagon":
        G += [(_circle(0.5, 0.5, 0.32, n=6), 0), (_circle(0.5, 0.5, 0.17, n=6), 1)]
    elif kind == "triangle":
        G += [([(0.22, 0.25), (0.78, 0.25), (0.5, 0.78)], 0), ([(0.3, 0.32), (0.7, 0.32), (0.5, 0.45)], 1)]
    elif kind == "candle":
        G += [(_rect(0.4, 0.18, 0.6, 0.6), 0), (_circle(0.5, 0.7, 0.07), 1), ([(0.45, 0.72), (0.55, 0.72), (0.5, 0.86)], 1)]
    elif kind == "candy":
        G += [(_circle(0.5, 0.5, 0.18), 0), ([(0.32, 0.5), (0.16, 0.62), (0.16, 0.38)], 1), ([(0.68, 0.5), (0.84, 0.62), (0.84, 0.38)], 1)]
    elif kind == "pot":
        G += [([(0.26, 0.6), (0.74, 0.6), (0.66, 0.24), (0.34, 0.24)], 0), (_rect(0.22, 0.6, 0.78, 0.68), 1), (_circle(0.5, 0.76, 0.05), 1)]
    elif kind == "scissors":
        G += [(_circle(0.36, 0.3, 0.1), 0), (_circle(0.64, 0.3, 0.1), 0), ([(0.4, 0.36), (0.46, 0.38), (0.7, 0.82), (0.64, 0.82)], 1), ([(0.6, 0.36), (0.54, 0.38), (0.3, 0.82), (0.36, 0.82)], 1)]
    elif kind == "hat":
        G += [(_rect(0.2, 0.3, 0.8, 0.38), 0), (_rect(0.34, 0.38, 0.66, 0.72), 0), (_rect(0.34, 0.42, 0.66, 0.5), 1)]
    elif kind == "cheese":
        G += [([(0.2, 0.3), (0.8, 0.3), (0.8, 0.55), (0.2, 0.68)], 0), (_circle(0.4, 0.45, 0.05), 1), (_circle(0.62, 0.4, 0.04), 1)]
    else:  # circle
        G += [(_circle(0.5, 0.5, 0.3), 0), (_circle(0.5, 0.5, 0.15), 1)]
    return G


GLYPH_RULES = [
    (("bakery", "bread", "baker"), "bread", "#d9963f"),
    (("dairy", "milk", "yogurt", "yoghurt"), "drop", "#5aa4d6"),
    (("cheese", "fondue"), "cheese", "#e8c04a"),
    (("sugar", "candy", "sweet"), "candy", "#e06aa0"),
    (("popcorn", "corn"), "star", "#e9c142"),
    (("bbq", "grill", "barbecue", "fry", "fryer", "wok", "hot dog"), "flame", "#e2603a"),
    (("pie", "pizza", "taco", "omelet", "donut", "doughnut"), "circle", "#d98a3a"),
    (("cake", "cupcake", "bakeshop", "patisserie"), "cake", "#e58fb0"),
    (("loom", "sewing", "tailor", "fabric", "wool", "knit"), "spool", "#8a6bc4"),
    (("hat",), "hat", "#6a5fb0"),
    (("juice", "smoothie", "tea", "coffee", "kiosk", "lemonade", "drink"), "cup", "#c4793a"),
    (("jam", "jar", "sauce", "honey", "preserv", "pickle"), "bottle", "#c4453d"),
    (("jewel", "gem", "ring"), "diamond", "#5ac0d6"),
    (("honey", "bee"), "hexagon", "#e3b13a"),
    (("soup", "stew", "noodle", "pasta", "ramen", "pot"), "bowl", "#d5743d"),
    (("candle", "wax"), "candle", "#efc85a"),
    (("flower", "florist", "bouquet", "perfum", "essential", "oil"), "flower", "#e07aa8"),
    (("sushi", "fish", "seafood", "net", "lure"), "fish", "#4f9fc4"),
    (("salad", "veg", "herb"), "leaf", "#5aa65a"),
    (("sandwich", "burger"), "triangle", "#d9a43f"),
    (("pottery", "ceramic", "vase", "clay"), "pot", "#c06a4a"),
    (("feed", "mill", "smelter", "machine", "factory", "workshop", "mine"), "gear", "#7d8a96"),
    (("ice cream", "frozen", "cream"), "heart", "#e58fb0"),
]


def glyph_for(name: str):
    n = name.lower()
    for keys, g, col in GLYPH_RULES:
        if any(k in n for k in keys):
            return g, hex_rgb(col)
    h = int(hashlib.sha1(name.encode()).hexdigest()[:4], 16)
    opts = ["star", "heart", "diamond", "circle", "gear", "leaf"]
    return opts[h % len(opts)], hex_rgb(ROOF_HUES[h % len(ROOF_HUES)])


def plaque(m: Mesh, face, x0, y0, x1, y1, z0, size, glyph_kind, color, bg=None):
    """Round white plaque with a coloured glyph on a vertical face."""
    bg = C["white"] if bg is None else bg
    p = m.new_part()
    # face extents along u
    if face == "+y":
        span = (x1 - x0)
    else:
        span = (y1 - y0)
    uc = 0.5
    s = size / span          # plaque size in u units
    hz = size                # in world z units
    pts = [(uc + (px - 0.5) * s, z0 + py * hz) for px, py in _circle(0.5, 0.5, 0.5, n=20)]
    m.facade_poly(face, x0, y0, x1, y1, pts, bg, offset=0.02, part=p)
    for poly, shade in glyph(glyph_kind):
        col = color if shade == 0 else mix(color, np.array([1, 1, 1]), 0.55)
        q = [(uc + (px - 0.5) * s * 0.92, z0 + (py * 0.92 + 0.04) * hz) for px, py in poly]
        m.facade_poly(face, x0, y0, x1, y1, q, col, offset=0.03, part=p, flags=8)


def window(m: Mesh, face, x0, y0, x1, y1, u0, u1, z0, z1, frame=None):
    frame = C["white"] if frame is None else frame
    p = m.new_part()
    m.facade_poly(face, x0, y0, x1, y1, [(u0, z0), (u1, z0), (u1, z1), (u0, z1)], frame, offset=0.015, part=p)
    du = (u1 - u0) * 0.14
    dz = (z1 - z0) * 0.14
    m.facade_poly(face, x0, y0, x1, y1, [(u0 + du, z0 + dz), (u1 - du, z0 + dz), (u1 - du, z1 - dz), (u0 + du, z1 - dz)],
                  C["glass"], offset=0.022, part=p, flags=8)
    um = (u0 + u1) / 2
    m.facade_poly(face, x0, y0, x1, y1, [(um - du * 0.25, z0 + dz), (um + du * 0.25, z0 + dz), (um + du * 0.25, z1 - dz), (um - du * 0.25, z1 - dz)],
                  frame, offset=0.026, part=p, flags=8)


def door(m: Mesh, face, x0, y0, x1, y1, u0, u1, z1, color=None):
    color = C["wood_dark"] if color is None else color
    p = m.new_part()
    m.facade_poly(face, x0, y0, x1, y1, [(u0, 0.0), (u1, 0.0), (u1, z1), (u0, z1)], color, offset=0.015, part=p)
    m.facade_poly(face, x0, y0, x1, y1, [(u0 + (u1 - u0) * 0.75, z1 * 0.45), (u0 + (u1 - u0) * 0.85, z1 * 0.45),
                                          (u0 + (u1 - u0) * 0.85, z1 * 0.52), (u0 + (u1 - u0) * 0.75, z1 * 0.52)],
                  C["gold"], offset=0.022, part=p, flags=8)


# ---------------------------------------------------------------------------
# Animals (stylised, tiny) — original simple shapes.
# ---------------------------------------------------------------------------

ANIMALS = {
    "cow": ("#f4f1ea", "#3d3633", 0.34), "pig": ("#f2a7b0", "#e48d99", 0.30), "sheep": ("#f6f3ee", "#4a4140", 0.30),
    "goat": ("#e2cfaf", "#b59a72", 0.28), "horse": ("#9a6a42", "#5a3a24", 0.38), "chicken": ("#f8f5f0", "#d9473a", 0.16),
    "donkey": ("#9c938a", "#6a625b", 0.32), "duck": ("#f7f3e8", "#e5a02e", 0.15), "cat": ("#e39b4c", "#c27a35", 0.16),
    "dog": ("#c79a65", "#8a6038", 0.2), "rabbit": ("#efe8df", "#e0a8b0", 0.14),
}


def animal(m: Mesh, kind: str, x, y, facing=1, scale=1.0):
    body, head, size = ANIMALS.get(kind, ANIMALS["cow"])
    body, head = hex_rgb(body), hex_rgb(head)
    s = size * scale
    leg_h = s * 0.55
    # legs
    for dx in (-0.45, 0.45):
        for dy in (-0.3, 0.3):
            m.cylinder(x + dx * s * facing, y + dy * s, 0, leg_h + 0.02, s * 0.1, mix(body, np.zeros(3), 0.35) if kind != "chicken" else hex_rgb("#e5a02e"), segs=6)
    if kind == "sheep":
        for dx, dy, dz in ((-0.3, 0, 0), (0.3, 0, 0), (0, -0.2, 0.1), (0, 0.2, 0.1), (0, 0, 0.22)):
            m.ellipsoid(x + dx * s, y + dy * s, leg_h + s * 0.45 + dz * s, s * 0.42, s * 0.36, s * 0.34, body, segs=10, rings=6)
    else:
        m.ellipsoid(x, y, leg_h + s * 0.42, s * 0.7, s * 0.42, s * 0.42, body, segs=12, rings=8)
    hx = x + facing * s * 0.72
    m.ellipsoid(hx, y, leg_h + s * 0.75, s * 0.28, s * 0.25, s * 0.26, head if kind not in ("chicken", "duck") else body, segs=10, rings=6)
    if kind == "cow":
        m.ellipsoid(x - 0.1 * s, y + 0.15 * s, leg_h + s * 0.7, s * 0.25, s * 0.2, s * 0.1, head, segs=8, rings=4)
    if kind in ("chicken",):
        m.ellipsoid(hx, y, leg_h + s * 1.02, s * 0.1, s * 0.06, s * 0.1, head, segs=6, rings=4)
    if kind == "duck":
        m.ellipsoid(hx + facing * s * 0.25, y, leg_h + s * 0.7, s * 0.14, s * 0.08, s * 0.05, head, segs=6, rings=4)


# ---------------------------------------------------------------------------
# Plants and props
# ---------------------------------------------------------------------------

FRUIT = [
    (("apple",), "#d6403a"), (("cherry",), "#a8182a"), (("pear",), "#c9d24a"), (("plum",), "#6b3a8f"),
    (("lemon",), "#f2d43a"), (("orange", "mandarin", "tangerine"), "#f08a2a"), (("peach", "apricot"), "#f4a46a"),
    (("banana",), "#f2d24a"), (("cacao", "cocoa"), "#a8692e"), (("coffee",), "#8a2a2a"), (("olive",), "#6a7a32"),
    (("mango",), "#f2b03a"), (("coconut",), "#7a5432"), (("passion",), "#7a3a6a"), (("pomegranate",), "#b8283a"),
    (("lime",), "#8ac43a"), (("fig",), "#6a3a5a"), (("avocado",), "#4a6a2a"), (("kiwi",), "#8a7a3a"),
    (("raspberr",), "#d63a5a"), (("blackberr",), "#3a2a4a"), (("blueberr",), "#4a5ab8"), (("strawberr",), "#e23a3a"),
    (("grape",), "#7a3a8a"), (("cotton",), "#f8f8f4"), (("tea",), "#4a8a3a"), (("rose",), "#e0507a"),
    (("chili", "pepper"), "#d6302a"), (("pumpkin",), "#e8862a"),
]


def fruit_color(name: str):
    n = name.lower()
    for keys, col in FRUIT:
        if any(k in n for k in keys):
            return hex_rgb(col)
    return hex_rgb("#d6403a")


def round_tree(m: Mesh, cx, cy, height, radius, leaf=None, trunk=None, fruit=None, rng=None, blossom=None):
    leaf = C["leaf"] if leaf is None else leaf
    trunk = C["wood"] if trunk is None else trunk
    rng = np.random.default_rng(1) if rng is None else rng
    tz = height * 0.45
    m.cylinder(cx, cy, 0, tz + radius * 0.3, radius * 0.16, trunk, segs=10, r_top=radius * 0.11)
    cz = tz + radius * 0.75
    m.ellipsoid(cx, cy, cz, radius, radius, radius * 0.9, leaf, segs=16, rings=10)
    for a in (0.3, 2.4, 4.4):
        ox, oy = math.cos(a) * radius * 0.55, math.sin(a) * radius * 0.55
        m.ellipsoid(cx + ox, cy + oy, cz - radius * 0.15, radius * 0.62, radius * 0.62, radius * 0.55,
                    mix(leaf, C["leaf_dark"], 0.25), segs=12, rings=8)
    m.ellipsoid(cx + radius * 0.05, cy + radius * 0.1, cz + radius * 0.45, radius * 0.6, radius * 0.6, radius * 0.5,
                mix(leaf, C["leaf_light"], 0.35), segs=12, rings=8)
    dots = fruit if fruit is not None else blossom
    if dots is not None:
        # Fruit on the camera-facing side of the canopy.
        n = 9
        for i in range(n):
            a = rng.uniform(-0.2, math.pi / 2 + 0.2)   # between +x and +y
            el = rng.uniform(-0.35, 0.55)
            r = radius * 1.0
            fx = cx + math.cos(a) * math.cos(el) * r
            fy = cy + math.sin(a) * math.cos(el) * r
            fz = cz + math.sin(el) * radius * 0.85
            fr = radius * (0.13 if fruit is not None else 0.1)
            m.ellipsoid(fx, fy, fz, fr, fr, fr, dots, segs=8, rings=5)


def pine(m: Mesh, cx, cy, height, radius, leaf=None, snow=False, ornaments=False, rng=None):
    leaf = hex_rgb("#3f8a4a") if leaf is None else leaf
    m.cylinder(cx, cy, 0, height * 0.25, radius * 0.15, C["wood_dark"], segs=8)
    tiers = 3
    for i in range(tiers):
        z0 = height * (0.18 + 0.24 * i)
        r = radius * (1.0 - 0.25 * i)
        h = height * 0.42
        m.cone(cx, cy, z0, h, r, mix(leaf, C["leaf_light"], 0.12 * i), segs=14)
        if snow:
            m.cone(cx, cy, z0 + h * 0.62, h * 0.38, r * 0.4, C["snow"], segs=14)
    if ornaments:
        rng = np.random.default_rng(3) if rng is None else rng
        cols = [C["red"], C["gold"], C["blue"], C["white"]]
        for i in range(10):
            t = rng.uniform(0.15, 0.85)
            z = height * (0.2 + 0.7 * t)
            r = radius * (1.05 - t) * 0.9
            a = rng.uniform(-0.1, math.pi / 2 + 0.1)
            m.ellipsoid(cx + math.cos(a) * r, cy + math.sin(a) * r, z, 0.05, 0.05, 0.05, cols[i % 4], segs=6, rings=4)
        m.ellipsoid(cx, cy, height * 1.02, 0.09, 0.09, 0.09, C["gold"], segs=8, rings=5)


def bush(m: Mesh, cx, cy, r, leaf=None, berries=None, rng=None, n_berries=10):
    leaf = C["leaf"] if leaf is None else leaf
    rng = np.random.default_rng(2) if rng is None else rng
    m.ellipsoid(cx, cy, r * 0.55, r, r, r * 0.65, leaf, segs=14, rings=8, zmin=0)
    m.ellipsoid(cx - r * 0.45, cy - r * 0.2, r * 0.5, r * 0.6, r * 0.6, r * 0.5, mix(leaf, C["leaf_dark"], 0.3), segs=10, rings=6, zmin=0)
    m.ellipsoid(cx + r * 0.3, cy + r * 0.35, r * 0.45, r * 0.55, r * 0.55, r * 0.45, mix(leaf, C["leaf_light"], 0.2), segs=10, rings=6, zmin=0)
    if berries is not None:
        for i in range(n_berries):
            a = rng.uniform(-0.3, math.pi / 2 + 0.3)
            el = rng.uniform(0.0, 0.9)
            bx = cx + math.cos(a) * math.cos(el) * r * 0.98
            by = cy + math.sin(a) * math.cos(el) * r * 0.98
            bz = r * 0.55 + math.sin(el) * r * 0.62
            m.ellipsoid(bx, by, bz, r * 0.11, r * 0.11, r * 0.11, berries, segs=6, rings=4)


def flowers(m: Mesh, x0, y0, x1, y1, colors, rng, density=10, stem=0.12):
    w, h = x1 - x0, y1 - y0
    n = max(3, int(density * w * h))
    for i in range(n):
        fx = rng.uniform(x0 + 0.08, x1 - 0.08)
        fy = rng.uniform(y0 + 0.08, y1 - 0.08)
        col = colors[i % len(colors)]
        z = stem + rng.uniform(0, 0.08)
        m.cylinder(fx, fy, 0.05, z, 0.012, C["leaf_dark"], segs=4)
        m.ellipsoid(fx, fy, z + 0.03, 0.07, 0.07, 0.045, col, segs=8, rings=4)
        m.ellipsoid(fx, fy, z + 0.06, 0.025, 0.025, 0.02, C["yellow"], segs=6, rings=3)


def crate(m: Mesh, x, y, s=0.32, color=None):
    color = C["wood_light"] if color is None else color
    m.box(x, y, 0, x + s, y + s, s, color, top=mix(color, C["white"], 0.1))


def barrel(m: Mesh, x, y, r=0.16, h=0.38, color=None):
    color = C["wood"] if color is None else color
    m.cylinder(x, y, 0, h, r, color, segs=12, top=C["wood_dark"])
    m.cylinder(x, y, h * 0.2, h * 0.26, r * 1.04, C["metal_dark"], segs=12)
    m.cylinder(x, y, h * 0.72, h * 0.78, r * 1.04, C["metal_dark"], segs=12)


def sack(m: Mesh, x, y, color=None):
    color = C["sand"] if color is None else color
    m.ellipsoid(x, y, 0.16, 0.16, 0.14, 0.17, color, segs=10, rings=6, zmin=0)
    m.ellipsoid(x, y, 0.33, 0.06, 0.06, 0.05, mix(color, C["brown"], 0.3), segs=6, rings=4)


def fence_ring(m: Mesh, x0, y0, x1, y1, color=None, h=0.32, gap_side=None):
    """Low post-and-rail fence around a rectangle (back sides + front sides)."""
    color = C["wood_light"] if color is None else color
    posts = []
    step = 0.5
    xs = np.arange(x0, x1 + 1e-6, step)
    ys = np.arange(y0, y1 + 1e-6, step)
    for x in xs:
        posts += [(x, y0), (x, y1)]
    for y in ys[1:-1]:
        posts += [(x0, y), (x1, y)]
    for (px, py) in posts:
        m.box(px - 0.035, py - 0.035, 0, px + 0.035, py + 0.035, h, color)
    t = 0.022
    for z in (h * 0.45, h * 0.85):
        m.box(x0, y0 - t, z - t, x1, y0 + t, z + t, color)
        m.box(x0 - t, y0, z - t, x0 + t, y1, z + t, color)
        if gap_side != "+y":
            m.box(x0, y1 - t, z - t, x1, y1 + t, z + t, color)
        else:
            m.box(x0, y1 - t, z - t, x0 + (x1 - x0) * 0.35, y1 + t, z + t, color)
            m.box(x0 + (x1 - x0) * 0.65, y1 - t, z - t, x1, y1 + t, z + t, color)
        m.box(x1 - t, y0, z - t, x1 + t, y1, z + t, color)


def ground_patch(m: Mesh, x0, y0, x1, y1, color, z=0.025, inset=0.04):
    m.box(x0 + inset, y0 + inset, 0, x1 - inset, y1 - inset, z, color, top=color)
