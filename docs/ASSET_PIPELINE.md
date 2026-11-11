# Asset pipeline

Item **metadata** (`data/items/*.json`) and item **art** (asset packs) are separate. An item points at art by
`art` key (default = its id). Swapping or adding art never touches metadata or saved layouts.

## Asset packs

A pack is a folder with `pack.json`:

```json
{
  "format": "hayday-sandbox-asset-pack", "schema_version": 1,
  "id": "my_art", "name": "My art", "license": "user-provided (private use)",
  "version": "2026.11.1",                       // optional, shown in Settings / Asset Manager
  "provenance": {"source": "…", "date": "…"},   // optional (object or text), shown in Asset Manager → Packs
  "art_kind": "original",                       // optional: "original" (default) | "placeholder"
  "priority": 10, "pixels_per_world_px": 2.0,
  "alpha_bleed": false,                         // optional: true if images already carry colour under transparent edges
  "sprites": {
    "bakery": {
      "file": "items/bakery.png",
      "thumb": "thumbs/bakery.png",             // optional small image for catalogue/lists (never loads the full art)
      "anchor": [148.0, 276.0],                 // texture px at the footprint's ground centre
      "pixels_per_world_px": 2.0,               // optional per-sprite override
      "scale": 1.0,                             // optional fine-tune multiplier
      "verified": true,                         // optional: art + anchor checked in the app
      "auto_anchor": true,                      // optional: anchor/scale were estimated (shown as "needs review")
      "default_variant": "winter",              // optional: appearance for objects without a chosen variant
      "shadow": {"file": "items/bakery.shadow.png", "anchor": [130, 120]},
      "variants": {"winter": {"file": "items/bakery__winter.png", "anchor": [148, 276], "thumb": "…"}},
      "connections": {"5": {"file": "items/fence__m05.png", "anchor": [64, 70]}},  // fences/paths
      "anim": {"sheet": "items/bakery.anim.png", "frames": 6, "fps": 6.0, "mode": "overlay",  // optional, see below
               "columns": 6, "anchor": [148, 276]},
      "glow": {"file": "items/bakery.glow.png", "blend": "add"},                // optional, see below
      "mirror": {"file": "items/bakery__mirror.png", "anchor": [120, 276]}      // optional, see below
    }
  }
}
```

`anim` is an ambient animation: a sprite sheet of `frames` cells, read left to right in `columns` rows (default: one
row). `mode` is `overlay` (frames over the static image, which must not contain the moving part) or `replace` (frames
instead of it). `anchor` is the frame pixel at the ground centre and defaults to the sprite's. All sprites share one
clock, only sprites in view change frame, and Settings → *Ambient animation* can reduce or stop them.

**Patch animations.** With `"rect": [x, y, w, h]` (static-image pixels) and `"cell": [cw, ch]` the frames *replace that
rectangle* of the static image: every cell is a complete re-render of the rectangle (unchanged pixels included), drawn
stretched over it, while the rest of the static image is drawn around it. Nothing is drawn twice, the static image
itself is frame 0 (thumbnails, ghosts, exports and *Off* use it unchanged), and cells may be smaller than the
rectangle (lower-resolution frames). `"cell_padding": p` = p px of each cell's edge pixels repeated around it in the
sheet (no filtering bleed between frames); `"glow_sheet"` holds the frames' glow (same cells, additive, below). Such
sheets load the first time the sprite is in view with animation on, never for objects that are not looked at.
`mode`/`anchor` are ignored; `fps` is the playback rate (the private builder also records `source_fps`,
`frame_step` and `loop_s`, which the app ignores).

**Glow.** `glow` is an additive layer: an image of the same size as the sprite (same anchor) whose colour × alpha is
*added* over the drawn sprite (`"blend": "add"`, the only blend accepted; a glow of another size is refused and
reported). The app draws it on an additive child canvas item of the object (it follows the object's transform, tint,
fade and visibility), on placement ghosts and in PNG exports. Catalogue thumbnails and UI previews cannot add light:
packs bake the glow into the thumbnail instead (`thumb`, alpha = brightest channel); the inspector / Asset Manager
preview show the sprite without it. It exists because add, screen and multiply blending (lights, flames, lanterns)
cannot be carried by one straight-alpha image: drawn as normal alpha they look dull or show black boxes. The private
builder composites such art exactly over an opaque backdrop: R(G) = C + T·G per channel (C = colour, T =
transmittance), normal image alpha A = 1 − mean(T), colour min(C, A), glow = C − min(C, A). Add is exact; screen and
multiply over pixels the art does not cover use the mean transmittance (error (T_c − mean T)·G). A flipped
object whose sprite has `mirror` draws that image unflipped (`mirror` takes `shadow` too; without one, the base
shadow is reused flipped). A variant named `theme_<theme>` is used for objects without a chosen variant while the
layout's world theme is `<theme>`; so is `<look>__<theme>`, the client's own seasonal skin of a look (`__winter` =
the base image's winter skin, `lvl_2__winter` = level 2's), which is how the private builder names them. A theme with
no such variant leaves the object as it is (`AssetLibrary.themed_variant`; placement ghosts, previews and the
renderer all go through it).

Variants inherit `pixels_per_world_px`/`scale` from their base sprite unless they set them. Variant id `@base`
means "the base image" even when a `default_variant` is set. Textures load lazily on first use and are shared by
path; `get_thumbnail()` uses `thumb` when present, so browsing thousands of items never decodes full-size art.

Connection keys are 4-bit masks: 1 = NE (−y), 2 = SE (+x), 4 = SW (+y), 8 = NW (−x). If a pack lacks a
shape, `Connections.best_variant` uses the richest available subset (it drops connections, never invents them),
falling back to the base sprite.

**Resolution order** (`AssetLibrary.load_all`): `user://asset_packs/*` (priority 100 + pack `priority`) →
`res://assets/original/*` (50 + pack `priority`; developer-local, git-ignored, *never exported*) → built-in
placeholders (priority 0); ties are broken by pack id, folders starting with `.` are ignored. Missing art → a shaded
vector block exactly the size of the footprint, with "?" for unknown items. Nothing ever crashes on missing files:
a sprite whose image is missing falls through to the next pack, and `missing_files()` / `pack_stats()` list them.

World size of a sprite = texture size / `pixels_per_world_px` × `scale`. One world tile is 64×32 px; the
built-in art is rendered at 2 px per world px, crisp up to ~200 % zoom, with mipmaps for zoomed-out views.

Pack images are loaded raw (straight alpha). Many encoders store black under fully transparent pixels, which
mipmapping pulls into the edges (dark fringes when zoomed out), so `AssetLibrary.prepare_image()` runs Godot's
`fix_alpha_edges()` before building mipmaps (~1 ms per sprite; skipped for thumbnails). A pack whose images
already carry the edge colour under transparency declares `"alpha_bleed": true` and skips that step
(`tools/private_assets/build_pack.py` does this at build time).

## Built-in placeholder art (original, CC0)

`tools/art_generator/` renders every item from simple 3D primitives with one camera, light, outline and shadow
model, so the whole catalogue is visually coherent and exactly grid-aligned:

* `iso3d.py` — numpy triangle rasteriser: z-buffer, 3× supersampling, deferred shading (sun + sky + fill +
  specular), contact occlusion, part outlines, silhouette outline, separate soft ground shadow projected along the
  sun.
* `parts.py` — palette, sign glyphs (bread, drop, gear, flame…), stylised animals, trees, bushes, flowers, props.
* `recipes.py` — category/keyword recipes: workshops with function plaques, barn, silo, farmhouse, market stall,
  pens with animals, beehives, fields, fruit trees (fruit colour by name), palms, connection-aware fences and paths,
  ponds, fountains, benches, lamps, statues, gazebos, windmills, balloons, swings, ferris wheels, cakes…
* `generate.py` — reads the catalogue, groups items by **visual signature** (kind + colour cue + footprint) so
  identical-looking placeholders are rendered once and shared (1,967 items → ~740 renders, 14 MB), renders fences
  and paths in all 16 connection shapes, writes `assets/placeholders/pack.json`, and caches by content hash so only
  changed items re-render. `--sheet out.png` writes a contact sheet for review.

```bash
python3 tools/art_generator/generate.py            # incremental
python3 tools/art_generator/generate.py --force --sheet /tmp/sheet.png
godot --headless --path . --import                 # re-import PNGs (mipmaps on via project import defaults)
```

These are deliberately *not* imitations of Hay Day artwork: they reproduce footprints, scale and function, not
designs. `docs/CATALOG_COVERAGE.md` counts how many items have their own vs. a shared generic placeholder.

## Installing a prepared pack (.zip)

Settings → **Install asset pack (.zip)…** (also in the Asset Manager), or at startup:

```bash
godot --path . -- --install-pack=/path/to/pack.zip [--quit-after-install]   # prints INSTALL-PACK …; exit 0/1
```

`PackInstaller.install_zip()` requires `pack.json` at the zip root or exactly one folder deep, validates its format,
skips unsafe entries (absolute paths, `..`), extracts into a hidden temp folder under `user://asset_packs/` and
renames it into place (`user://asset_packs/<pack id>/`), so an interrupted install never leaves a half-written
pack; an older version is only removed once the new one is complete (and is restored if the swap is interrupted).
Your `overrides.json` is carried over when the zip ships none, so updating a pack keeps your review work.

## Local fine-tuning: `overrides.json` and `review.json`

Per-pack, next to `pack.json` (which is never modified):

```json
{"version": 1,
 "sprites": {"bakery": {"anchor": [150, 270], "pixels_per_world_px": 2.0, "scale": 1.05, "default_variant": "winter",
                        "verified": true, "rejected": false, "variants": {"winter": {"anchor": [151, 270]}}}},
 "assign":  {"review/unmatched_0042.png": "sugar_mill"}}
```

Applied at load by the pure helper `PackOverrides` (unit-tested): `assign` creates/replaces the item's sprite with
that image and an anchor + scale estimated from its alpha bounding box and the item's footprint (flagged
`auto_anchor`); `sprites` override fields; `rejected` removes the sprite from that pack so the next pack (normally
the placeholder) shows. Unknown fields are preserved. `AssetLibrary.save_overrides(pack, key, changes[, variant])`
(null removes a field), `save_overrides_many()` and `assign_image(pack, file, item)` write it atomically and only
invalidate the affected sprites. `review.json` = `{"items": [{"file", "suggestions": [item ids], "reason"}]}` lists
images a pack builder could not match; they appear in the Asset Manager's review queue.

## Asset Manager (Ctrl+Shift+A)

Opened from the top bar, the catalogue header, Settings, or Ctrl+Shift+A (on the selected/active item):

* **Items** — search + filters with counts (All / Original art / Placeholder only / Needs review / Rejected / Size
  unverified) and category; a preview that draws the item's footprint tiles (64×32 per tile) with the sprite at its
  anchor: Original / Placeholder / Onion skin, sprite bounds, anchor cross, zoom/fit/pan. Drag the art (or use the
  arrow keys, Shift = 10 px) to move it onto its tiles; anchor X/Y, pixels per world px and scale fields; Reset;
  **Apply scale to category**; variant dropdown + "Make default"; **Mark verified** / **Wrong match (use
  placeholder)** / Restore. Edits are debounced, saved to `overrides.json` and the farm redraws only those sprites.
* **Review queue** — each image from `review.json` with its reason and suggested items; assign with one click or
  a search; skip / unassign; progress counter.
* **Packs** — every pack with version, provenance, licence, priority, folder, contents and missing files.

Placed objects whose art has variants get a **Variant** dropdown in the inspector (an undoable command), and the
catalogue/inspector cards show an *Original art* / *Placeholder art* badge and the variant count.

## Importing your own artwork (in the app)

Settings → **Import artwork…**, or programmatically `AssetImporter.run(folder, pack_id, db)`. Imports go to
`user://asset_packs/<pack>/` (Windows: `%APPDATA%\HaydaySandbox\asset_packs\`), never into the project.

* Accepts PNG, WebP, JPG, nested folders.
* **Matching:** by normalised file name against item names, ids and aliases (`Feed Mill.png`, `feed_mill.webp`),
  or explicit `manifest.json` / `manifest.csv` (`file,item,anchor_x,anchor_y,scale,variant,mask,shadow`).
  Suffixes: `__mNN` = connection shape, `_shadow` = shadow image.
* **Sprite sheets:** `sheet.png` + `sheet.json` in TexturePacker *hash* or *array* format → frames are cut out
  (rotation and trimmed source sizes handled) and matched like files.
* **Processing:** transparency detection (opaque images are reported — they would hide the ground), transparent
  padding trimmed (anchors re-expressed), SHA-256 duplicate detection, dimensions; anchor + scale estimated from
  the footprint when not given (`auto_anchor: true` in the pack so they are easy to find and fine-tune).
* **Report:** `import_report.json` + an in-app summary of matched / unmatched / duplicate / opaque files.
* Re-importing a pack replaces it; layouts are unaffected because they reference item ids.

You must have the right to use any images you import. Without Supercell's permission, extracting art from the game
client breaches Supercell's Terms of Service (see `docs/research/LEGAL_AND_LICENSING.md`). The app itself never
downloads art, reads game files or contacts game servers. The separate, optional scripts in `tools/private_assets/`
build a private pack for a user who has that permission for personal use; see [PRIVATE_ASSETS.md](PRIVATE_ASSETS.md).

## Guard rails

`tools/ci/validate_data.py` fails CI if: anything besides README/.gdignore is in `assets/original/`; game
archive/texture formats (`.sc`, `.ktx`, `.sctx`, `.zktx`, `.apk`, …) appear; images exist outside
`assets/placeholders/items/`, `assets/ui/`, `docs/screenshots/`; files exceed 5 MB; pack references are broken or
orphaned. Export presets exclude `assets/original/`, `tests/`, `tools/`, `docs/` and research data. The private
original-art pack and its leak guard (`tools/ci/check_private_leaks.py`, git hooks, export checks) are described in
[PRIVATE_ASSETS.md](PRIVATE_ASSETS.md).
