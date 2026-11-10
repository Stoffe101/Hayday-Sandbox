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

**Pieces** (draw order: ascending `z`, then file order; ground pieces under every object, foreground pieces over
them):

| field | meaning |
|---|---|
| `id`, `kind` | name (diagnostics) and a free label: `edge`, `cliff`, `river`, `road`, `water`, `deco`, … (prototype `export` / `role` accepted) |
| `anchor_tile` / `at_tile`, `anchor_world` / `at_world`, `offset` | where the piece sits (tile corner wins over world px; offset in world px) |
| `z` | order among pieces |
| `repeat` | `{"count": n, "step_tile": [dx, dy]}` or `"step_world"`: n copies (e.g. a cliff segment along an edge) |
| `modulate` | colour multiplier |
| `layer` | `ground` (default: under every object, like the game's background art) or `foreground` (over the objects, below the editor overlays; it only draws, so a click still picks the object under it). Unknown values are reported and drawn on the ground |
| `blend` | `normal` (default), `add`, `screen`, `multiply`, or a Flash / SC blend number (0, 1, 2 normal; 3 multiply; 4 screen; 8 add). Others are reported and drawn normal |
| `variants` | `{"<variant>": {…overrides…, "hidden": true}}`, used when that variant has no piece list of its own |
| `clips` / `water_glints` | `[{"clip", "x_axis", "y_axis", "origin_world", "mul"?, "add"?}]`: clip animation instances, transform relative to the anchor; `mul` ([r, g, b, a]) and `add` ([r, g, b], 0..1) are the instance's colour transform |

Piece types (`type` may be omitted; it follows from the fields):

* **image**: `atlas` + `rect_px`, or `file`; `origin` (texture px placed on the anchor), `scale`, `flip_h`.
  Fields may also sit in an `"image": {…}` object.
* **mesh**: `"mesh": "<file>.mesh.json"` with `atlas` (an atlas id) or `texture` (file), `positions` (x, y pairs in
  world px relative to the anchor), `uvs` (0..1 pairs), `colors` (r, g, b, a per vertex, multiplied; optional),
  `indices` (triangles), `add_ops` (`[{"first_index", "index_count", "add_rgb": [r, g, b]}]`: a colour-transform add
  term, drawn with a small canvas shader). This is the research prototype's mesh-replay format. Optional and only
  informative: `blend_ops` (`[{"first_index", "index_count", "mode"}]`, Flash blend numbers; the builder turns a
  mesh with one supported mode over all of its triangles into the piece's `blend`, mixed modes draw normal),
  `bbox_world`, `vertex_count`, `triangle_count`.
* **polygon** (water areas, road strips, bridges): `rect_tiles: [x, y, w, h]`, `polygon_tiles: [[x, y], …]`
  (absolute tile coordinates) or `polygon_world` (relative to the anchor); `color`, optional `texture` (a whole
  image, repeated) and `uv_world` (world px per texture repeat; default texture width / pixels_per_world_px).
* **animated**: an image piece with `"anim": {"sheet", "frames", "columns", "fps", "frame_size"?}`. With an image
  the frames play over it; without one the frames are the piece (frame 0 when still).

**Clips file** (prototype `water_glints.json`): `{"shapes": {"<id>": {"atlas", "polygon_world", "uv"}},
"clips": {"<name>": {"fps", "frames": [[{"shape", "m": [a, b, c, d, tx, ty], "mul": [r, g, b, a], "add": [r, g, b]?}]]}}}`.
Each frame lists the shapes it shows with an affine matrix (x' = a·x + c·y + tx, y' = b·x + d·y + ty), a colour
multiplier and an optional colour-add term. The instance's transform applies on top (mul = mul_instance · mul_element,
add = add_element · mul_instance + add_instance). The add term is drawn as a second, additive pass of the same
shapes ((texture · mul + add) over the ground, without the clamp at 1; the add passes of all instances of a piece
follow their normal passes).

**Informative fields** (read by tools and people, ignored by the loader): `extent_world` (top level and per variant:
`[x0, y0, x1, y1]` world px covered by the pieces; the renderer measures the loaded pieces itself), per piece
`bbox_world` (relative to the anchor), `confidence` and `evidence` (where the placement comes from), `provenance`,
tile `size`.

**Ambient animation** (Settings → Ambient animation) applies to animated pieces and clips like it does to objects:
Off = still (clips hidden, sheets show their first frame or nothing over an image, no per-frame work at all),
Reduced = every third instance at half speed, Full = all. Only instances in view animate: each instance's bounds
come from its clip's frames (or its sheet frame), a frame change of an instance in view redraws (one small canvas
item per layer), and an instance out of view keeps the frame it had until it comes back into view.

## Rendering, caching, fallbacks

`GroundLayer` owns two children drawn behind it: the procedural `TerrainLayer`, then `PackTerrainLayer`
(background colour → ground tiles → pieces → animated pieces). Ground overlays (locked-plot tint and hatching,
blocked hatching, plot borders, labels) stay on top, then the objects. Foreground pieces (and their animations) sit
in `PackTerrainLayer.foreground`, which `main.gd` moves into the world right after the object renderer
(`attach_foreground`): over the objects, under the planning labels and the editor overlays (selection, ghosts), in
exports too. It is a plain `Node2D` (no input), so picking is unchanged.

* **Blend modes** use one shared canvas shader per combination (`PackTerrainLayer.material_for`): straight-alpha
  colour c = texture · mul (+ add); `add` = dst + c·a; `multiply` = dst · mix(1, c, a) (transparent texels leave
  the ground alone); `screen` = mix(dst, 1 − (1 − c)(1 − dst), a), read from the screen texture (it sees what was
  drawn earlier in the frame; Godot copies the screen once per canvas at the first such piece). They apply to
  image, mesh and polygon pieces; sprite-sheet animations and clips draw normal (+ the clip add pass).
* **Camera bounds**: `main.world_rect_px()` asks `PackTerrainLayer.camera_rect()`. A pack with base `color` frames
  the camera by its pieces' measured extent (+64 world px), the placement grid and the landmarks; the iso diamond of
  `world_bounds` reaches far beyond the art in its corners. Over the procedural terrain it is the union of both. The
  layer emits `extent_changed` when a map, pack or variant changes it, and the camera bounds (limits, minimum zoom)
  follow.

* Built once per map + variant (pieces) and per map + variant + plot ownership (tiles: one triangle array per
  texture, about 5-7 ms for the public map's 3,900 tiles). Camera moves never rebuild; a theme change rebuilds from
  cached textures and meshes (`TerrainPack.cache`, `AssetLibrary` texture cache), and the last tile triangles of
  each variant are kept, so switching back to a season seen with the same ownership only swaps arrays.
* **Per element**: a tile whose art key has no texture is not covered, so the app draws that tile; a piece that
  fails (missing image, bad mesh) is skipped and keeps the procedural terrain visible underneath even with base
  `color`; an unknown clip is skipped. The whole manifest failing just means procedural terrain.
* Diagnostics are never fatal: they go to `TerrainPack.errors` / `warnings`, `AssetLibrary.errors` and the Asset
  Manager's pack card (missing terrain files are listed with the pack's missing files, problems under it).
* Exports with placeholder art (the default when private art is installed) switch the ground to the placeholder
  library too, so they never show pack terrain.
* With base `color` the background colour fills a screen-aligned rectangle far beyond the world bounds (the iso
  diamond of `world_bounds` + 64 tiles left the app's clear colour in the screen corners at zoom 0.25 and below).

## Compatibility with the research prototype

The private research prototype (`research/terrain/pack_proto/terrain/`, schema 0) is read as schema 1 with a
warning: `seasons` lists, `export`/`role`, `anchor_tile` + `anchor_world`, mesh JSON, `ground` → `ground.json`
with `tile_textures`, and `water_glints` (file key and per-piece instances). Its `ground.json` cell grid is not
used: the cells come from the world's `ground` layer and `tile_types[].art` (an art key per ground type, which the
prototype calls `export`), so the map and the art stay separate.

## Building a private terrain from your own client files

`tools/private_assets/build_terrain.py` (public code, no game numbers inside; see `PRIVATE_ASSETS.md`) writes a pack
terrain from files the user extracted from their own client. Everything it writes is private.

1. Inputs: the client's background `.sc` file and its atlases, `themes.csv` (theme -> export-name postfix),
   `game_config.csv` (background colour), the private world (`world.json`: `tile_types[].art` names the ground-tile
   exports) and a **private placement file** from the terrain research (which export sits on which tile corner, in
   which order, with a confidence label; the client tables don't hold those anchors).
2. Ground tiles: one image per tile-type art key and per season postfix, cut exactly from the client atlas when the
   export is a plain axis-aligned rectangle (else rendered). Separate images, so far-zoom mipmaps never mix
   neighbouring atlas tiles. Seasons follow the suffix rule (`<art>_<variant>`).
3. Pieces: every edge export becomes a mesh ("mesh replay"): each client draw command becomes triangles (world px =
   SC units / 2 relative to the registration point), with its uvs into the client atlas, its colour multiplier and
   add term. Solid fills whose uvs name a single texel (e.g. a water body) stay exactly that. Nothing is
   rasterised, so a piece wider than any texture limit costs only vertices. `--raster EXPORT` instead renders one
   export as an image with `extract_from_apk.py`'s renderer (for comparison). Nested clips with more than one frame
   (e.g. water glints) are not baked in: they go to `clips.json` with their per-frame matrices, colour multipliers
   and add terms, and their instances (with their own colour transform) sit on the piece. A mesh whose draw
   commands all use one supported blend mode gets that piece `blend`.
4. Variants: one piece list per postfix that has art (export + postfix if it exists, else the base export); the
   `themes` table maps every `themes.csv` theme to its variant, or to `default` when its postfix has no art.
5. Output: `<root>/packs/hayday_original_terrain/terrain/` + `hashes.json` (leak guard) + `build_report.json`.
   `build_pack.py` copies it into the pack (`--terrain` runs the builder first, `--no-terrain` leaves it out),
   `acquire.py` adds `--terrain` to its build step when the client art and the placement file exist, and
   `install_pack.py` counts the files the terrain manifest references. `--install-dir` adds it to an installed pack
   directly (backup first, `-t<digest>` version suffix). `--validate` runs `check_terrain_pack.gd`.

## Real private pack: results (2026-11-10, Linux container, 4 CPUs, Mesa llvmpipe)

Rendered with the app (copied data folder, empty layouts, all four seasons, owned and locked plots, zoom 0.12 to 2)
and compared with the research composites made by an independent renderer (the extractor). Placement, ground tiles,
river, bridge, cliff and mine gap, forests, road strips and seasonal art match the composites in every view
(**strong**: same data, two renderers, checked by eye). Water glints animate (frame-to-frame difference only on the
river; **verified-in-data** clip matrices, faint by design in the art). The whole terrain uses normal blending only
and no masks (**verified-in-data**: every draw command was inspected).

| measurement | value |
|---|---|
| `build_terrain.py` (all four seasons, cached client parse) | about 3 s, ~17 MB of private output |
| manifest parse (`TerrainPack.load_file`) | 3 ms |
| first build in the app (meshes + atlases decoded + mipmaps, tiles) | 150-175 ms (pieces) + 12-15 ms (tiles) |
| season change (first time / cached) | 32-35 ms / 12-13 ms; plot ownership change 12-14 ms (T1) |
| season change through `GroundLayer.set_theme`, after the tile cache (T2) | first time 37-39 ms (one 47 ms outlier under load), back to a season seen before 2.7-3.1 ms (was ~15 ms); plot ownership change 14-15 ms |
| water clips (53 instances, 112 in winter), 1920x1080, mean / p95 over 120 frames | river view zoom 1: Off 47.2/53.9 and 47.4/51.7 ms, Reduced 47.7/52.2 and 46.8/50.3 ms (18 instances animate), Full 53.7/60.7 and 47.4/52.6 ms (53 animate); the farm without the river in view: no clip work (0 instances, 1 redraw) |
| VRAM estimate | atlases + tile images ~5.0 Mpx RGBA8 + mipmaps ~27 MB; vertex data ~2-3 MB per season variant visited |
| frame time at the whole-farm overview, empty layout (llvmpipe) | 55-100 ms with pack terrain vs 30-50 ms procedural (alternating A/B, noisy shared CPU) |
| frame time by layer (terrain alone, 1920x1080) | empty 7 ms; + tiles 13-32 ms; + pieces 38-78 ms; + clips +0-10 ms |

The software renderer is fill-rate bound (every terrain layer covers much of the screen); a real GPU won't notice.
The clips cost at most a few ms per frame on llvmpipe (within the run-to-run noise of the shared CPU).

T2 (same day): the private terrain has **no** foreground pieces, no non-normal blend modes and no clip add terms
(**verified-in-data**: a rebuild with the updated builder writes byte-identical files apart from the timestamp), so
the new features change nothing on screen there: renders of eight static views are pixel-identical to the T1
renders except for the animated river glints. Camera bounds: the camera rect shrank from the world-bounds diamond's
11,168 x 5,584 world px to 7,497 x 4,210 (the pieces' extent + margin), so zooming out stops at 22 % instead of
about 15 %, with the farm filling the view instead of a third of it. Plot ownership changes swap exactly the
expansion's tiles (checked one plot and all plots, default and winter).

## Not supported yet (what a follow-up must add)

* **Snow particles** for the winter themes (separate client art; not terrain).
* **Atmosphere / clouds** (**pending-screenshot**). The client has the art (`cloud_formation`: additive light rays
  and clouds with animated children; seasonal variants with normal blend), and the app can now draw it (a
  foreground piece with `blend: add` and clips), but no client table says where it goes: no offset, no anchor, and
  whether it follows the camera (parallax) or the map is unknown. Placing it would be invention, so the builder
  leaves it out. What would settle it: two in-game screenshots of the same farm spot, one zoomed out, one panned by
  about half a screen, both at the same zoom (look for the light shafts); with the farm's known landmarks in the
  shots the reference-image calibration (Reference images → 2- or 3-point calibration) gives the world position,
  and the pair shows whether the clouds move with the map.
* Whether any edge bush ever covers an object in the game (it would be a foreground piece): **unknown**; the client
  draws `background.sc` as one layer before the objects (**plausible**), so every main-farm piece stays `ground`.
* Mixed blend modes inside one mesh (`blend_ops` with several modes): drawn normal; not present in the main farm.
* Performance on software rendering: tile chunks as separate canvas items (culling), a cheaper filter when zoomed
  in, the background colour as the viewport clear colour.
* A thin seam where the tile area ends under an edge's soft border (the clear colour shows through at about 1 px);
  whether the game draws the same needs an in-game screenshot (**pending-screenshot**).
* A pack terrain for the public v1 frame.
