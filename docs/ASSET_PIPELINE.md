# Asset pipeline

Item **metadata** (`data/items/*.json`) and item **art** (asset packs) are separate. An item points at art by
`art` key (default = its id). Swapping or adding art never touches metadata or saved layouts.

## Asset packs

A pack is a folder with `pack.json`:

```json
{
  "format": "hayday-sandbox-asset-pack", "schema_version": 1,
  "id": "my_art", "name": "My art", "license": "user-provided (private use)",
  "priority": 10, "pixels_per_world_px": 2.0,
  "sprites": {
    "bakery": {
      "file": "items/bakery.png",
      "anchor": [148.0, 276.0],                 // texture px at the footprint's ground centre
      "pixels_per_world_px": 2.0,               // optional per-sprite override
      "scale": 1.0,                             // optional fine-tune multiplier
      "shadow": {"file": "items/bakery.shadow.png", "anchor": [130, 120]},
      "variants": {"winter": {"file": "items/bakery__winter.png", "anchor": [148, 276]}},
      "connections": {"5": {"file": "items/fence__m05.png", "anchor": [64, 70]}}   // fences/paths
    }
  }
}
```

Connection keys are 4-bit masks: 1 = NE (−y), 2 = SE (+x), 4 = SW (+y), 8 = NW (−x). If a pack lacks a
shape, `Connections.best_variant` uses the richest available subset (it drops connections, never invents them),
falling back to the base sprite.

**Resolution order** (`AssetLibrary.load_all`): `user://asset_packs/*` (priority 100+) → `res://assets/original/*`
(developer-local, git-ignored, *never exported*) → built-in placeholders (priority 0). Missing art → a shaded
vector block exactly the size of the footprint, with "?" for unknown items. Nothing ever crashes on missing files.

World size of a sprite = texture size / `pixels_per_world_px` × `scale`. One world tile is 64×32 px; the
built-in art is rendered at 2 px per world px, crisp up to ~200 % zoom, with mipmaps for zoomed-out views.

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

You must have the right to use any images you import. Extracting art from the game client or its servers
breaches Supercell's Terms of Service (see `docs/research/LEGAL_AND_LICENSING.md`); the app neither does that nor
helps with it.

## Guard rails

`tools/ci/validate_data.py` fails CI if: anything besides README/.gdignore is in `assets/original/`; game
archive/texture formats (`.sc`, `.ktx`, `.sctx`, `.zktx`, `.apk`, …) appear; images exist outside
`assets/placeholders/items/`, `assets/ui/`, `docs/screenshots/`; files exceed 5 MB; pack references are broken or
orphaned. Export presets exclude `assets/original/`, `tests/`, `tools/`, `docs/` and research data.
