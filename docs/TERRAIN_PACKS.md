# Terrain packs (format `hayday-sandbox-terrain`, schema 1)

An asset pack can bring its own terrain art: ground tile textures (with seasonal variants), background pieces
(edges, forests, cliffs, rivers, roads, bridges), water areas, animated pieces and clip animations. The app draws
it instead of, or on top of, its own procedural terrain. The format and the code are public; the art inside a pack
is the pack owner's business. **Original game art only ever lives in a privately installed pack**
(`%APPDATA%\HaydaySandbox\asset_packs\<id>\`, see `PRIVATE_ASSETS.md`); public CI and the visual tests use the
generated synthetic pack (`tests/fixtures/synthetic_terrain.gd`).

Code: `src/core/terrain_pack.gd` (`TerrainPack`: parse, validate, themes, tile and piece resolution; pure),
`src/render/pack_terrain_layer.gd` (`PackTerrainLayer`: loading and drawing), `AssetLibrary.terrain_for()` /
`pack_terrain()` / `terrain_texture()`, wiring in `GroundLayer` and `SceneryLayer`. Checker for authors:
`godot --headless --path . --script res://tools/ci/check_terrain_pack.gd -- <path/to/terrain.json>`.

## Where a pack declares it

* `pack.json`: `"terrain": "terrain/terrain.json"` (a pack-relative path). It applies to the world the same pack
  provides (`"world"`), to the map ids listed in the manifest's `maps`, or, with no `maps`, to any map in the
  game tile frame (map schema 2, `"frame": "game"`).
* `world.json`: `"terrain": "<path next to the world file>"` applies to that world only and wins over pack terrain.
* Several packs: the highest pack priority wins (one terrain at a time).
* `world.json` `tile_types[<id>].art` names the tile texture key of that ground type (string or `null`; `null`
  means the app draws that type itself). An expansion type's `unlocked_type` gives the look once the plot is owned.

## Frame and units

Game tile frame = app tile frame. Tile corner `(x, y)` is at world px `((x - y) * 32, (x + y) * 16)` (`Iso`).
`anchor_tile` values are tile corners (fractions allowed); `anchor_world` / `offset` / `polygon_world` are world px.
Image sizes convert with `scale` (world px per texture px) or the manifest's `pixels_per_world_px`.

## Manifest (`terrain.json`)

```jsonc
{
  "format": "hayday-sandbox-terrain", "schema_version": 1,
  "id": "my_terrain", "name": "…",
  "frame": "game_tile",                 // or {"name": "game_tile", …} (prototype); others are refused
  "maps": ["hayday_farm"],              // optional, see above
  "base": "color",                      // "procedural" (default): drawn over the app's terrain;
                                        // "color": replaces it (background colour + the pack's art)
  "background_color": "#698e1c",        // base "color": fills the world (+64 tiles); per variant too
  "scatter": false,                     // placeholder trees/rocks in forest areas (default: base == "procedural")
  "land_edge": false,                   // the app's soil edge along the land (default: base == "procedural")
  "alpha_bleed": true,                  // images already carry colour under transparent edges (skips a fix-up)
  "pixels_per_world_px": 2.0,           // default scale of image pieces
  "atlases": {"bg0": {"file": "atlas/background_0.png"}},
  "tiles": { … } | "ground.json",       // tile textures, or a file holding {"tiles"| "tile_textures": {…}}
  "kind_tiles": { … },                  // per-kind fallbacks (maps or tiles without ground data)
  "themes": {"christmas": "winter"},    // world theme -> variant
  "variants": {"winter": {"background_color": "#…", "pieces": [ … ]}},
  "seasons": {"winter": [ … ]},         // prototype spelling of variants.<v>.pieces (a full list per variant)
  "pieces": [ … ],                      // the default variant's pieces
  "clips": "water_glints.json"          // clip animations used by pieces (prototype key "water_glints" accepted)
}
```

**Tiles.** `"<art key>": {"atlas": "bg2", "rect_px": [x, y, w, h]}` or `{"file": "tiles/grass.png"}` (whole image).
A square texture is mapped onto the tile diamond with **u along +x and v along +y**: texel (0, 0) at the tile's top
corner, (w, 0) at the right, (w, h) at the bottom. Half a texel is kept off the rect border. Seasonal look,
first match wins: `tiles[art].variants[<variant>]`, then a key `"<art>_<variant>"` (the game's export-name suffix
rule), then the base texture. `kind_tiles` keys: `buildable`, `plot`, `plot_locked`, `road`, `blocked`, `water`,
`scenery` (a missing `plot` uses `buildable`, a missing `plot_locked` uses `plot`). Tiles with ground data use
`tile_types[].art` first and fall back to the kind of their map tile.

**Themes -> variants.** The `themes` table (case-insensitive), else a variant with the theme's own name, else
`default`. Nothing is guessed: a theme without art shows the default art.

**Pieces** (draw order: ascending `z`, then file order; all of them under every object):

| field | meaning |
|---|---|
| `id`, `kind` | name (diagnostics) and a free label: `edge`, `cliff`, `river`, `road`, `water`, `deco`, … (prototype `export` / `role` accepted) |
| `anchor_tile` / `at_tile`, `anchor_world` / `at_world`, `offset` | where the piece sits (tile corner wins over world px; offset in world px) |
| `z` | order among pieces |
| `repeat` | `{"count": n, "step_tile": [dx, dy]}` or `"step_world"`: n copies (e.g. a cliff segment along an edge) |
| `modulate` | colour multiplier |
| `variants` | `{"<variant>": {…overrides…, "hidden": true}}`, used when that variant has no piece list of its own |
| `clips` / `water_glints` | `[{"clip", "x_axis", "y_axis", "origin_world"}]`: clip animation instances, transform relative to the anchor |

Piece types (`type` may be omitted; it follows from the fields):

* **image**: `atlas` + `rect_px`, or `file`; `origin` (texture px placed on the anchor), `scale`, `flip_h`.
  Fields may also sit in an `"image": {…}` object.
* **mesh**: `"mesh": "<file>.mesh.json"` with `atlas` (an atlas id) or `texture` (file), `positions` (x, y pairs in
  world px relative to the anchor), `uvs` (0..1 pairs), `colors` (r, g, b, a per vertex, multiplied; optional),
  `indices` (triangles), `add_ops` (`[{"first_index", "index_count", "add_rgb": [r, g, b]}]`: a colour-transform add
  term, drawn with a small canvas shader). This is the research prototype's mesh-replay format.
* **polygon** (water areas, road strips, bridges): `rect_tiles: [x, y, w, h]`, `polygon_tiles: [[x, y], …]`
  (absolute tile coordinates) or `polygon_world` (relative to the anchor); `color`, optional `texture` (a whole
  image, repeated) and `uv_world` (world px per texture repeat; default texture width / pixels_per_world_px).
* **animated**: an image piece with `"anim": {"sheet", "frames", "columns", "fps", "frame_size"?}`. With an image
  the frames play over it; without one the frames are the piece (frame 0 when still).

**Clips file** (prototype `water_glints.json`): `{"shapes": {"<id>": {"atlas", "polygon_world", "uv"}},
"clips": {"<name>": {"fps", "frames": [[{"shape", "m": [a, b, c, d, tx, ty], "mul": [r, g, b, a]}]]}}}`. Each
frame lists the shapes it shows with an affine matrix (x' = a·x + c·y + tx, y' = b·x + d·y + ty) and a colour
multiplier; `add` terms are ignored for clips.

**Ambient animation** (Settings → Ambient animation) applies to animated pieces and clips like it does to objects:
Off = still (clips hidden, sheets show their first frame or nothing over an image), Reduced = every third instance
at half speed, Full = all. Only a frame change of an instance in view redraws (one small canvas item).

## Rendering, caching, fallbacks

`GroundLayer` owns two children drawn behind it: the procedural `TerrainLayer`, then `PackTerrainLayer`
(background colour → ground tiles → pieces → animated pieces). Ground overlays (locked-plot tint and hatching,
blocked hatching, plot borders, labels) stay on top, objects above everything.

* Built once per map + variant (pieces) and per map + variant + plot ownership (tiles: one triangle array per
  texture, about 7 ms for the public map's 3,900 tiles). Camera moves never rebuild; a theme change rebuilds from
  cached textures and meshes (`TerrainPack.cache`, `AssetLibrary` texture cache).
* **Per element**: a tile whose art key has no texture is not covered, so the app draws that tile; a piece that
  fails (missing image, bad mesh) is skipped and keeps the procedural terrain visible underneath even with base
  `color`; an unknown clip is skipped. The whole manifest failing just means procedural terrain.
* Diagnostics are never fatal: they go to `TerrainPack.errors` / `warnings`, `AssetLibrary.errors` and the Asset
  Manager's pack card (missing terrain files are listed with the pack's missing files, problems under it).
* Exports with placeholder art (the default when private art is installed) switch the ground to the placeholder
  library too, so they never show pack terrain.

## Compatibility with the research prototype

The private research prototype (`research/terrain/pack_proto/terrain/`, schema 0) is read as schema 1 with a
warning: `seasons` lists, `export`/`role`, `anchor_tile` + `anchor_world`, mesh JSON, `ground` → `ground.json`
with `tile_textures`, and `water_glints` (file key and per-piece instances). Its `ground.json` cell grid is not
used: the cells come from the world's `ground` layer and `tile_types[].art` (an art key per ground type, which the
prototype calls `export`), so the map and the art stay separate.

## Not supported yet

Foreground pieces drawn over objects, per-piece blend modes, the colour-add term on clips, camera bounds from the
pieces' extent (the world's `world_bounds` still decides), snow / cloud particles, and a pack terrain for the
public v1 frame. Real private packs have not been rendered with this code yet (only the synthetic one).
