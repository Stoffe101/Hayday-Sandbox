# Architecture

Godot 4.7 (GDScript, statically typed), Compatibility renderer (OpenGL 3.3 / ANGLE) for maximum Windows
compatibility and so software rendering works in CI. The app is data-driven: item metadata, farm geometry, art
and layouts are all files; code never hard-codes item facts.

```
project.godot            autoload App, main scene src/app/main.tscn, import defaults (mipmaps)
src/
  core/                  PURE logic, no scene/UI/App deps — fully unit-tested
    iso.gd                 2:1 isometric projection (grid/tile/world/screen)
    item_def.gd            one item's metadata (no textures); scope (main_farm or another area), landmark link
    item_database.gd       loads data/items/*.json (+ user://items), validation, search, catalogue overrides
    farm_map.gd            map JSON (schema 2, game tile frame) → per-tile kind, plots, adjacency, unlock rules,
                           landmarks, scenery, provenance
    landmark.gd            one fixed world structure (farmhouse, truck, …): footprint, blocking tiles, states,
                           skins, themes, confidence; never movable/rotatable; approximate ones don't block
    world_loader.gd        picks the world for a map id: public map, else a valid private pack world, then
                           user://world_overrides/<map id>.json corrections
    placed_object.gd       an object instance (stores its own footprint; preserves unknown fields)
    occupancy.gd           tile → uid index (keeps stacked uids so bad data is reported, not lost)
    farm_layout.gd         the document: objects, land, profile, annotations, references, camera + bookmarks,
                           world state, migration record, signals
    placement_rules.gd     per-tile validity + human-readable reasons
    conflict_index.gd      incremental find_conflicts (rechecks only objects sharing a changed tile)
    layout_tools.gd        symmetry lines, repeat arrays, align, distribute, brush shapes, fit checks
    stamp_library.gd       reusable groups: user://stamps/*.hdstamp, import/export, generated thumbnails
    depth_sorter.gd        topological painter's order for rectangular footprints; incremental draw order
    connections.gd         fence/path auto-connection masks (derived, never stored)
    camera_math.gd         camera springs (centre + log-zoom), anchored zoom, inertia, rubber-band limits
    drag_math.gd           drag-delta hysteresis, nearest-valid search
    commands/              Command, CommandStack (bounded, merge window, dirty tracking, version counter),
                           EditCommands (AddObjects, RemoveObjects, MoveObjects, MoveEach, SetProperty,
                           SetGeometry, SetLand, SetAnnotations, SetProfile, SetMeta, SetReference,
                           SetCameraBookmark, Composite), SetWorldStateCommand (world_commands.gd)
    layout_io.gd           versioned JSON (schema 3), migrations 0→1→2→3, missing/renamed items, landmark
                           extraction, atomic save + recovery, pre-v2 backup
    layout_library.gd      user layouts: list, duplicate, rename, trash, history snapshots, autosave
    realistic_analyzer.gd  "can I build this?" report (never mutates); Cached = per-layout memo
    layout_diff.gd         geometric comparison of two layouts
    json_util.gd           JSON + crash-safe atomic writes
  assets/
    asset_library.gd       layered asset packs → SpriteInfo (texture, anchor, scale, shadow, alpha hit mask,
                           ambient animation sheet, hand-drawn mirror art), lazy textures + thumbnails,
                           variants and "theme_<season>" variants, overrides, review queue, pack world data
    pack_overrides.gd      pure overrides.json / catalogue-overrides parsing and merging + auto-anchor maths
    pack_installer.gd      .zip pack install (validation, zip-slip guard, atomic replace)
    asset_importer.gd      user art import (folders, atlases, manifests, trimming, hashing, report)
  render/                  scene nodes that draw the world
    terrain_layer.gd       original procedural ground of worlds without game terrain (grass, road, bridge,
                           river, forest, cliff), built from the map; a season change only re-tints it
    terrain_textures.gd    procedural seamless textures
    ground_layer.gd        terrain runs (game-data worlds), raised land edge, locked-plot tint and hatching,
                           level-blocked plots, plot borders/labels
    scenery_layer.gd       decorative forest around the farm (never blocks)
    reference_layer.gd     screenshot overlays (several per layout) with 2- or 3-point calibration
    grid_overlay.gd        grid + occupied-tile overlay
    object_renderer.gd     RenderingServer canvas items per object and per world entry (landmarks), draw index
                           from DepthSorter, picking, tints, ambient animation (Off/Reduced/Full)
    landmark_view.gd       landmark → world entry: state, skin preset and theme variant resolution, names
    selection_underlay.gd  selection fill + drag validity tiles, drawn under the objects
    editor_overlay.gd      hover, selection outlines, ghosts, blockers, reason chips, marquee, notes, diff, labels
    tool_overlay.gd        the symmetry mirror line (never exported)
    farm_camera.gd         Camera2D side of CameraMath: animated and immediate view changes, limits, fly-to
    exporter.gd            offscreen tiled rendering of the shared World2D → Image
  editor/
    editor_session.gd      per-document editing state + high-level operations (shared by UI & keys);
                           fixed-item rules, Realistic level rule, landmark selection, symmetry settings
    editor_controller.gd   pointer gestures → tool behaviour → Commands (one gesture = one undo step); picking
                           cycle, "Objects here", drag hysteresis and snap to valid
    layout_tool_controller.gd  stamps, mirror line, outline / fence-line brush, repeat preview (sees canvas input first)
  ui/                      theme (code-built), icons, panels, dialogs — no business logic
    catalog_panel.gd       catalogue with category rail, search, badges
    inspector_panel.gd     Selection (objects, placing card, landmark card) / Farm / View tabs; auto-hides
                           when nothing needs it
    stamps_panel.gd        floating stamps list (save, place, export, import, delete)
    panel_grip.gd          drag handle that resizes a side panel (double-click = automatic width)
    tool_dock.gd, top_bar.gd, dialogs.gd, gallery.gd, modal.gd, toasts.gd, ui.gd, ui_theme.gd, icons.gd
    asset_manager.gd       Asset Manager (Ctrl+Shift+A): footprint preview, anchor/scale edits, review queue, packs
    art_import_dialog.gd   user art import UI
  app/
    app.gd                 autoload service locator: settings, db, maps (world), assets, library, session
    settings.gd            persistent preferences (user://settings.cfg)
    main.gd                composition root: builds world + UI, panel layout, wires signals, global shortcuts
data/  items/ maps/ samples/ research/        tools/  art_generator/ catalog/ ci/ build/ samples/ ui/ private_assets/
assets/ placeholders/ (generated CC0 art) ui/ (font, icons) original/ (git-ignored, local only)
tests/ unit/ (headless, --script) integration/app_selftest.gd (in-app) visual/capture.gd (real rendering)
```

## State ownership

* **`FarmLayout`** owns document data and is mutated *only* through its methods, which keep the occupancy index
  consistent and emit `objects_added/removed/changed`, `land_changed`, `meta_changed`, `annotations_changed`,
  `planning_changed`, `reference_changed`, `world_changed`. It refuses objects whose item duplicates a fixed
  landmark (`fixed_items`), except when an undo restores exactly what was there.
* **`CommandStack`** is the only caller of those mutators during editing. Every user edit is a `Command` with
  exact `do/undo`: object edits, land, annotations, profile, the layout name (`SetMeta`), reference images
  (`SetReference`), saved views (`SetCameraBookmark`) and the world look (`SetWorldStateCommand`). Continuous
  gestures produce one command; rapid nudges merge (`merge_key`). History is bounded (300) and tracks a save point
  for the dirty flag and a `version` counter for caches.
* **`EditorSession`** owns selection, the landmark selection (mutually exclusive with the object selection), tool,
  active item, clipboard, symmetry settings, the **`ConflictIndex`** and the cached Realistic analysis
  (`RealisticAnalyzer.Cached`). UI and canvas read the same `conflicts()` and `analysis()`; widgets call session
  methods and never touch the layout directly.
* **`App`** owns long-lived services: settings, the item database (with any pack catalogue corrections), the maps
  (`maps`, `map`; chosen by `WorldLoader`), assets and the library. It swaps `session` when a layout is opened
  (`session_changed`) and emits `map_changed` when a pack changes the world; the open layout is rebound
  (`EditorSession.set_map`) but not modified.
* **`FarmMap`** is world data: regions, plots, landmarks, scenery, provenance. Landmarks are never `PlacedObject`s;
  a layout only stores how they look in this design (`world_state`: theme and per-landmark state/skin/visibility).
* **Renderers** subscribe to layout signals and update incrementally; they never mutate the model.
* **`LayoutToolController`** sees canvas input before `EditorController` and commits only through
  `EditorSession`. `StampLibrary` owns `user://stamps/`. `main.gd` owns panel widths and visibility (remembered in
  the settings) and reattaches the layout tools after a UI rebuild.

## Coordinates and rendering

`Iso` defines grid space (tile corners at integers; +x → screen down-right, +y → down-left), world pixels
(TILE 64×32) and screen space (camera). Maps and layouts (schema 2+) use the game's tile frame: X along the road,
Y from the cliff/forest to the road, starting land at X 0..31, Y 0..31. The logical grid is independent of art
resolution: each asset pack declares `pixels_per_world_px`, and each sprite an **anchor** = the texture pixel at
the footprint's ground centre. Objects are positioned by footprint centre, so mirroring (Hay Day's rotate) is a
horizontal flip around that point and simply swaps W×H; a pack may supply hand-drawn mirror art instead.

**Depth order.** A single sort key fails for elongated or differently sized neighbours (e.g. a 1×6 hedge beside a
lamp). `DepthSorter` builds "drawn-before" edges only between objects whose sprite bounds overlap (spatial hash),
deciding by footprint separation along the grid axes, then runs Kahn's algorithm with centre depth as a
deterministic tie-breaker (disjoint convex footprints always admit such an order; any cycle from bad data is
broken by depth, never crashes). Edits update the order incrementally and fall back to a full sort for big batches
or cycles. Landmarks are world entries in the same order. Flat items (paths) live in a lower layer, then shadows,
then upright objects.

**Why RenderingServer items, not Nodes:** one canvas item per object is cheap, Godot culls each by its rect, and
camera movement costs zero script time. Picking uses a spatial hash plus per-sprite alpha `BitMap`s
(pixel-accurate), falling back to the footprint tile. Sprite transparency never affects placement — validity
comes from footprints and map data only.

**Camera.** `CameraMath` is pure: critically damped springs on the centre and log-zoom, zoom anchored to the
cursor, inertia after a released pan, rubber-band limits at the world bounds. `FarmCamera` applies it to the
`Camera2D`; the view stops at the visible canvas (not under the panels).

**Terrain.** For worlds without game terrain (the public map) `TerrainLayer` draws original procedural ground
from the map's regions and scenery rectangles. If the map has no cliff area, the north edge of the world gets one;
that is a visual choice, not map data. Game-data worlds keep `GroundLayer`'s per-tile drawing.

**UI scale** uses `Window.content_scale_factor` (stretch disabled): fonts are oversampled and icons rasterised
at the scaled size with a logical size override, so 200–300 % stays crisp; the world is rendered at native
resolution.

## Files and robustness

Layouts (`.hdlayout`, JSON, `schema_version` 3) store each object's footprint, so unknown items keep their space.
Renamed ids map through `aliases`; changed footprints keep the origin (an axis-only change on a flippable item
toggles `flipped`) and are reported; overlaps are flagged, never deleted; unknown fields are preserved. Catalogue
items that duplicate a fixed landmark are taken out on every load and kept in `migration.migrated_landmarks`.
Migrations run step-wise: 0→1 (prototype shape), 1→2 (game tile frame shift, landmark extraction, starter lock
cleared), 2→3 (`reference` becomes a list of images). Saving over a pre-v2 file first keeps its bytes as
`<file>.v<N>-backup`. Writes are atomic: write `.tmp` → verify by re-reading → move old to `.bak` → rename.
`JsonUtil.recover()` falls back to `.tmp`/`.bak`. Autosave writes a separate recovery copy that a manual save
clears; `pending_recovery()` offers newer autosaves at startup. Every manual save also writes a revision snapshot
(last 30 kept). Stamps (`.hdstamp`, format `hayday-sandbox-stamp` v1) store item ids and relative offsets only;
placing takes footprints from the catalogue.

## Assets and worlds

See [ASSET_PIPELINE.md](ASSET_PIPELINE.md). Packs are layered by priority (user > developer-local > built-in);
missing art falls back to a vector block sized to the footprint. Metadata and art are fully decoupled. A pack may
also declare world data (`world`) and catalogue corrections (`catalog_overrides`); `WorldLoader` uses the
highest-priority pack world that validates and otherwise the public map. These paths are exercised by tests with
synthetic packs; they have not been checked against a real private pack in the current wave.

## Performance (measured, see TESTING.md)

Windows, this development PC, `--selftest=perf` (mean per edit, 45 edits):

| | 2,000 objects | 10,000 objects |
|---|---:|---:|
| Creative, before ConflictIndex / cached analysis | 26.2 ms | 93.4 ms |
| Creative, now | 0.29 ms | 0.36 ms |
| Realistic, before | 64.5 ms | 237 ms |
| Realistic, now | 9.9 ms | 46 ms |

Realistic edits are still dominated by re-running the analysis (see KNOWN_ISSUES.md). Catalogue cold thumbnail
pass: 2,701 → 1,266 ms, images decoded 1,474 → 741.
