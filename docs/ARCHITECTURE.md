# Architecture

Godot 4.7 (GDScript, statically typed), Compatibility renderer (OpenGL 3.3 / ANGLE) for maximum Windows
compatibility and so software rendering works in CI. The app is data-driven: item metadata, farm geometry, art
and layouts are all files; code never hard-codes item facts.

```
project.godot            autoload App, main scene src/app/main.tscn, import defaults (mipmaps)
src/
  core/                  PURE logic, no scene/UI deps — fully unit-tested
    iso.gd                 2:1 isometric projection (grid/tile/world/screen)
    item_def.gd            one item's metadata (no textures)
    item_database.gd       loads data/items/*.json (+ user://items), validation, search
    farm_map.gd            data/maps/*.json → per-tile kind, plots, adjacency, unlock rules
    placed_object.gd       an object instance (stores its own footprint; preserves unknown fields)
    occupancy.gd           tile → uid index (keeps stacked uids so bad data is reported, not lost)
    farm_layout.gd         the document: objects, land, profile, annotations, reference, signals
    placement_rules.gd     per-tile validity + human-readable reasons
    depth_sorter.gd        topological painter's order for rectangular footprints
    connections.gd         fence/path auto-connection masks (derived, never stored)
    commands/              Command, CommandStack (bounded, merge window, dirty tracking), EditCommands
    layout_io.gd           versioned JSON, migrations, missing/renamed items, atomic save + recovery
    layout_library.gd      user layouts: list, duplicate, rename, trash, history snapshots, autosave
    realistic_analyzer.gd  "can I build this?" report (never mutates)
    layout_diff.gd         geometric comparison of two layouts
    json_util.gd           JSON + crash-safe atomic writes
  assets/
    asset_library.gd       layered asset packs → SpriteInfo (texture, anchor, scale, shadow, alpha hit mask)
    asset_importer.gd      user art import (folders, atlases, manifests, trimming, hashing, report)
  render/                  scene nodes that draw the world
    ground_layer.gd        terrain runs, raised land edge, locked-plot hatching, plot borders/labels
    scenery_layer.gd       decorative forest around the farm (never blocks)
    reference_layer.gd     screenshot overlay with affine calibration
    grid_overlay.gd        grid + occupied-tile overlay
    object_renderer.gd     RenderingServer canvas items per object, draw index from DepthSorter, picking
    editor_overlay.gd      hover, selection, ghosts with per-tile validity, marquee, notes, diff, labels
    farm_camera.gd         pan, smooth zoom-at-cursor, fit to the visible (un-paneled) area
    exporter.gd            offscreen tiled rendering of the shared World2D → Image
    terrain_textures.gd    procedural seamless textures
  editor/
    editor_session.gd      per-document editing state + high-level operations (shared by UI & keys)
    editor_controller.gd   pointer gestures → tool behaviour → Commands (one gesture = one undo step)
  ui/                      theme (code-built), icons, panels, dialogs — no business logic
  app/
    app.gd                 autoload service locator: settings, db, maps, assets, library, session
    main.gd                composition root: builds world + UI, wires signals, global shortcuts
data/  items/ maps/ samples/ research/        tools/  art_generator/ catalog/ ci/ build/ samples/ ui/
assets/ placeholders/ (generated CC0 art) ui/ (font, icons) original/ (git-ignored, local only)
tests/ unit/ (headless, --script) integration/app_selftest.gd (in-app) visual/capture.gd (Xvfb)
```

## State ownership

* **`FarmLayout`** owns document data and is mutated *only* through its methods, which keep the occupancy index
  consistent and emit `objects_added/removed/changed`, `land_changed`, `annotations_changed`, `planning_changed`.
* **`CommandStack`** is the only caller of those mutators during editing. Every user edit is a `Command` with
  exact `do/undo`; continuous gestures produce one command; rapid nudges merge (`merge_key`). History is bounded
  (300) and tracks a save point for the dirty flag.
* **`EditorSession`** owns selection, tool, active item, clipboard. UI widgets call session methods; they never
  touch the layout directly.
* **Renderers** subscribe to layout signals and update incrementally; they never mutate the model.
* **`App`** owns long-lived services and swaps `session` when a layout is opened (`session_changed`).

## Coordinates and rendering

`Iso` defines grid space (tile corners at integers; +x → screen down-right, +y → down-left), world pixels
(TILE 64×32) and screen space (camera). The logical grid is independent of art resolution: each asset pack
declares `pixels_per_world_px`, and each sprite an **anchor** = the texture pixel at the footprint's ground
centre. Objects are positioned by footprint centre, so mirroring (Hay Day's rotate) is a horizontal flip around
that point and simply swaps W×H.

**Depth order.** A single sort key fails for elongated or differently sized neighbours (e.g. a 1×6 hedge beside a
lamp). `DepthSorter` builds "drawn-before" edges only between objects whose sprite bounds overlap (spatial hash),
deciding by footprint separation along the grid axes, then runs Kahn's algorithm with centre depth as a
deterministic tie-breaker (disjoint convex footprints always admit such an order; any cycle from bad data is
broken by depth, never crashes). The order is applied with `RenderingServer.canvas_item_set_draw_index`. Flat
items (paths) live in a lower layer, then shadows, then upright objects — physically correct for flat things.

**Why RenderingServer items, not Nodes:** one canvas item per object is cheap, Godot culls each by its rect, and
camera movement costs zero script time. Picking uses a spatial hash plus per-sprite alpha `BitMap`s
(pixel-accurate), falling back to the footprint tile. Sprite transparency never affects placement — validity
comes from footprints only.

**UI scale** uses `Window.content_scale_factor` (stretch disabled): fonts are oversampled and icons rasterised
at the scaled size with a logical size override, so 200–300 % stays crisp; the world is rendered at native
resolution.

## Files and robustness

Layouts (`.hdlayout`, JSON, `schema_version` 1) store each object's footprint, so unknown items keep their space.
Renamed ids map through `aliases`; changed footprints use the new size and are reported; overlaps are flagged,
never deleted; unknown fields are preserved. Writes are atomic: write `.tmp` → verify by re-reading → move old to
`.bak` → rename. `JsonUtil.recover()` falls back to `.tmp`/`.bak`. Migrations run step-wise (`_migrate_0_to_1`).
Autosave writes a separate recovery copy that a manual save clears; `pending_recovery()` offers newer autosaves at
startup. Every manual save also writes a revision snapshot (last 30 kept).

## Assets

See [ASSET_PIPELINE.md](ASSET_PIPELINE.md). Packs are layered by priority (user > developer-local > built-in);
missing art falls back to a vector block sized to the footprint. Metadata and art are fully decoupled.

## Performance (measured, see TESTING.md)

Placement checks ~30 µs, pixel-accurate picks ~0.1 ms, full depth sort 58 ms for a densely packed real farm and
~100 ms at 5,000 objects; save/load 5,000 objects ~30/85 ms. Known limit: each edit triggers a full depth
re-sort (≈140 ms at 5,000, ≈400 ms at 10,000 synthetic objects) — see KNOWN_ISSUES.md for the incremental plan.
