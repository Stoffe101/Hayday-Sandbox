"""Original placeholder art that no catalogue item owns, and the ambient animation sheets.

World sprites are ordinary pack entries that the map refers to as `fallback_art`
(e.g. the truck landmark). Animations are sprite sheets attached to existing
placeholder entries through an "anim" field:

  "anim": {"sheet": "items/x.anim.png", "frames": 6, "columns": 6, "fps": 6.0,
           "mode": "replace" | "overlay", "anchor": [x, y]}

  replace  the frames take the place of the static image while animating;
  overlay  the frames are drawn on top of the static image (transparent elsewhere).

Everything here is original, drawn from the same simple 3D primitives as the
rest of the placeholder set. This file is deliberately NOT part of the item
fingerprint in generate.py: adding art here must not re-render the catalogue.
"""
from __future__ import annotations

import hashlib
import math
from pathlib import Path

import numpy as np
from PIL import Image

from iso3d import Mesh, hex_rgb, render
from parts import C, crate, sack, window
import recipes

# --- world sprites ---------------------------------------------------------------------


def truck(m: Mesh, w: float, h: float) -> None:
    """A small farm flatbed: blue-green cab at the +y (screen lower-left) end, slatted wooden bed behind it."""
    body = hex_rgb("#3f9a96")
    x0, x1 = 0.17, w - 0.17
    y0, y1 = 0.14, h - 0.08
    bed_end = y0 + 0.98
    cab_end = bed_end + 0.52
    for wy in (y0 + 0.3, y1 - 0.34):
        for wx in (x0 + 0.02, x1 - 0.02):
            m.ellipsoid(wx, wy, 0.17, 0.08, 0.17, 0.17, C["black"], segs=14, rings=8)
        m.ellipsoid(x1 + 0.055, wy, 0.17, 0.02, 0.085, 0.085, C["metal"], segs=10, rings=5, flags=8)
    m.box(x0 + 0.04, y0, 0.15, x1 - 0.04, y1, 0.27, C["metal_dark"])
    # Bed with low slatted rails.
    m.box(x0, y0, 0.27, x1, bed_end, 0.34, C["wood_light"], top=C["wood"])
    rail = C["wood_light"]
    for rx0, rx1 in ((x0, x0 + 0.05), (x1 - 0.05, x1)):
        m.box(rx0, y0, 0.34, rx1, bed_end, 0.42, rail)
        m.box(rx0, y0, 0.5, rx1, bed_end, 0.58, rail)
    m.box(x0, y0, 0.34, x1, y0 + 0.05, 0.58, rail)
    for py in np.linspace(y0 + 0.02, bed_end - 0.02, 5):
        m.box(x1 - 0.055, py - 0.02, 0.34, x1 + 0.005, py + 0.02, 0.6, C["wood_dark"])
    # Load: two crates and a sack, so the bed reads at a glance.
    crate(m, x0 + 0.09, y0 + 0.12, s=0.3)
    crate(m, x0 + 0.22, y0 + 0.5, s=0.26, color=C["wood"])
    sack(m, x1 - 0.2, y0 + 0.28)
    # Cab, bonnet, roof and glass.
    m.box(x0, bed_end + 0.02, 0.27, x1, cab_end, 0.92, body)
    m.box(x0 + 0.02, cab_end, 0.27, x1 - 0.02, y1, 0.6, body, top=hex_rgb("#4cb0ab"))
    m.box(x0 - 0.02, bed_end, 0.92, x1 + 0.02, cab_end + 0.03, 0.97, C["cream"])
    window(m, "+x", x0, bed_end + 0.02, x1, cab_end, 0.2, 0.8, 0.6, 0.86)
    window(m, "+y", x0, bed_end + 0.02, x1, cab_end, 0.12, 0.88, 0.62, 0.86)
    m.box(x0 + 0.08, y1, 0.4, x0 + 0.2, y1 + 0.02, 0.5, C["lamp"], flags=2)
    m.box(x1 - 0.2, y1, 0.4, x1 - 0.08, y1 + 0.02, 0.5, C["lamp"], flags=2)
    m.box(x0, y1 - 0.02, 0.22, x1, y1 + 0.03, 0.3, C["cream"])


#: art key -> (builder, footprint). The key is what data/maps uses as fallback_art.
WORLD_SPRITES = {"ph_truck": (truck, (1, 2))}


def _source_hash(scale: float) -> str:
    src = Path(__file__).read_text(encoding="utf-8")
    return hashlib.sha1((src + str(scale)).encode()).hexdigest()[:16]


def build_world_sprites(out: Path, sprites: dict, cache: dict, scale: float, force: bool = False) -> set[str]:
    """Renders WORLD_SPRITES into `sprites` (incremental). Returns the keys that exist."""
    fp = _source_hash(scale)
    for key, (builder, size) in WORLD_SPRITES.items():
        ck = f"world:{key}"
        if not force and cache.get(ck) == fp and key in sprites and (out / sprites[key]["file"]).exists():
            continue
        m = Mesh()
        builder(m, *size)
        spr = render(m, size, scale=scale, shadow=True)
        name = f"{key}.png"
        sname = f"{key}.shadow.png"
        spr.image.save(out / "items" / name, optimize=True)
        spr.shadow.save(out / "items" / sname, optimize=True)
        sprites[key] = {"file": f"items/{name}", "anchor": list(spr.anchor),
                        "shadow": {"file": f"items/{sname}", "anchor": list(spr.shadow_anchor)},
                        "footprint": list(size), "world_art": True}
        cache[ck] = fp
    return set(WORLD_SPRITES)


# --- ambient animations ----------------------------------------------------------------

WINDMILL_FRAMES = 6
WINDMILL_FPS = 6.0
SHIMMER_FRAMES = 8
SHIMMER_FPS = 5.0
#: Items whose look gets a water shimmer. The look is shared, so every item drawn with it animates too.
SHIMMER_ITEMS = ("large_pond", "duck_pond", "fountain")


def _windmill_mesh(w: float, h: float, roof, angle: float) -> Mesh:
    """recipes.windmill with the sails turned to `angle` (the catalogue sprite is angle = 0.4)."""
    m = Mesh()
    cx, cy = w / 2, h / 2
    r = min(w, h) * 0.32
    m.cylinder(cx, cy, 0, 2.0, r, C["cream"], segs=12, r_top=r * 0.7)
    m.cone(cx, cy, 2.0, 0.6, r * 0.85, roof, segs=12)
    hub = (cx + r * 0.78, cy + r * 0.78, 1.8)
    side = np.array([0.7071, -0.7071, 0.0])
    up = np.array([0, 0, 1.0])
    for k in range(4):
        a = k * math.pi / 2 + angle
        dx, dz = math.cos(a), math.sin(a)
        u = side * dx + up * dz
        p0 = np.array(hub) + np.array([0.05, 0.05, 0])
        perp = side * (-dz) + up * dx
        q = [p0 + u * 0.15 - perp * 0.1, p0 + u * 1.1 - perp * 0.12, p0 + u * 1.1 + perp * 0.12, p0 + u * 0.15 + perp * 0.1]
        m.poly(q, C["white"], normal=(1, 1, 0), flags=1)
    m.ellipsoid(*hub, 0.1, 0.1, 0.1, C["wood_dark"], segs=8, rings=5)
    return m


def _sheet(frames: list[tuple[Image.Image, tuple]]) -> tuple[Image.Image, list[float], list[int]]:
    """Packs differently cropped frames into one strip, aligned on their anchors."""
    left = max(math.ceil(a[0]) for _im, a in frames)
    top = max(math.ceil(a[1]) for _im, a in frames)
    right = max(math.ceil(im.width - a[0]) for im, a in frames)
    bottom = max(math.ceil(im.height - a[1]) for im, a in frames)
    cw, ch = left + right, top + bottom
    sheet = Image.new("RGBA", (cw * len(frames), ch), (0, 0, 0, 0))
    for i, (im, a) in enumerate(frames):
        sheet.alpha_composite(im, (i * cw + round(left - a[0]), round(top - a[1])))
    return sheet, [float(left), float(top)], [cw, ch]


def _water_mask(rgba: np.ndarray) -> np.ndarray:
    r, g, b, a = (rgba[..., i].astype(np.float32) for i in range(4))
    return (a > 250) & (b > 150) & (b > r * 1.35) & (g > r * 1.05)


def _shimmer_frames(base: Image.Image, frames: int) -> list[Image.Image]:
    """White glints sliding over the water pixels of `base`; a seamless loop."""
    rgba = np.asarray(base.convert("RGBA"))
    mask = _water_mask(rgba)
    h, w = mask.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    # Wave fronts run along the iso axes, so the glints sit flat on the ground plane.
    u = xx * 0.5 + yy
    v = yy - xx * 0.5
    out = []
    for i in range(frames):
        t = 2 * math.pi * i / frames
        field = np.sin(u * 0.33 + t) + 0.7 * np.sin(v * 0.47 - 2 * t) + 0.5 * np.sin((u + v) * 0.19 + 3 * t)
        glint = np.clip((field - 1.6) / 0.4, 0, 1) * mask
        layer = np.zeros((h, w, 4), dtype=np.uint8)
        layer[..., :3] = 255
        layer[..., 3] = (glint * 120).astype(np.uint8)
        out.append(Image.fromarray(layer, "RGBA"))
    return out


def _windmill_groups(items: list[dict]) -> list[dict]:
    seen, out = set(), []
    for it in items:
        if it.get("category") in ("fence", "path") or (it.get("connect") or {}).get("style"):
            continue
        if recipes.deco_kind(it) != "windmill":
            continue
        sig = recipes.signature(it)
        if sig.startswith("u:") or sig in seen:
            continue
        seen.add(sig)
        out.append(it)
    return out


def _apply_anim(sprites: dict, file: str, anim: dict) -> None:
    for e in sprites.values():
        if e.get("file") == file:
            e["anim"] = dict(anim)


def build_animations(out: Path, sprites: dict, items: list[dict], cache: dict, scale: float, file_key,
                     force: bool = False) -> None:
    """Creates / attaches every animation sheet. Attaching always runs, since a re-rendered entry loses its "anim"."""
    fp = _source_hash(scale)
    items_dir = out / "items"
    by_id = {it["id"]: it for it in items}
    for it in _windmill_groups(items):
        key = it.get("art", it["id"])
        if key not in sprites:
            continue
        w, h = it["footprint"]
        stem = file_key(it)
        name = f"{stem}.anim.png"
        ck = f"anim:{stem}"
        anim = {"sheet": f"items/{name}", "frames": WINDMILL_FRAMES, "columns": WINDMILL_FRAMES, "fps": WINDMILL_FPS, "mode": "replace"}
        if force or cache.get(ck, ["", None])[0] != fp or not (items_dir / name).exists():
            cw, ccol = recipes.color_word(it.get("name", ""))
            roof = ccol if ccol is not None else recipes.hue_for(recipes.signature(it))
            frames = []
            for i in range(WINDMILL_FRAMES):
                spr = render(_windmill_mesh(w, h, roof, 0.4 - (math.pi / 2) * i / WINDMILL_FRAMES), (w, h), scale=scale, shadow=False)
                frames.append((spr.image, spr.anchor))
            sheet, anchor, _size = _sheet(frames)
            sheet.save(items_dir / name, optimize=True)
            cache[ck] = [fp, anchor]
        anim["anchor"] = cache[ck][1]
        _apply_anim(sprites, sprites[key]["file"], anim)
    for iid in SHIMMER_ITEMS:
        it = by_id.get(iid)
        if it is None:
            continue
        key = it.get("art", it["id"])
        if key not in sprites:
            continue
        stem = file_key(it)
        name = f"{stem}.anim.png"
        ck = f"anim:{stem}"
        anim = {"sheet": f"items/{name}", "frames": SHIMMER_FRAMES, "columns": SHIMMER_FRAMES, "fps": SHIMMER_FPS, "mode": "overlay"}
        if force or cache.get(ck, ["", None])[0] != fp or not (items_dir / name).exists():
            frames = _shimmer_frames(Image.open(out / sprites[key]["file"]), SHIMMER_FRAMES)
            sheet = Image.new("RGBA", (frames[0].width * SHIMMER_FRAMES, frames[0].height), (0, 0, 0, 0))
            for i, f in enumerate(frames):
                sheet.alpha_composite(f, (i * f.width, 0))
            sheet.save(items_dir / name, optimize=True)
            cache[ck] = [fp, None]
        _apply_anim(sprites, sprites[key]["file"], anim)
