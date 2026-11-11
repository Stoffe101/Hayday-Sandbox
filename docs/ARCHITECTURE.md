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
                           landmarks, scenery, water-decoration zones, provenance
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
                           SetGeometry, SetLand, SetAnnotations, SetProfile, SetPlanning, SetMeta, SetReference,
                           SetCameraBookmark, Composite), SetWorldStateCommand (world_commands.gd)
    layout_io.gd           versioned JSON (schema 4), migrations 0→1→2→3→4 (3→4: zones become planning areas),
                           missing/renamed items, landmark extraction, atomic save + recovery, backup of any
                           older-schema file before the first save
    calibration_math.gd    screenshot calibration from N ≥ 2 points (similarity / least-squares affine),
                           per-point residuals in tiles and pixels, verdict, isometric check, landmark anchors
    object_layers.gd       view layers by category group (show / dim / hide); never touches the layout
    planning/              the planning layer (docs/PLANNING.md), pure like the rest of core/
      plan_doc.gd            planning dict: normalize, areas, phases, membership, primary phase; with_* edits
      currency.gd            currency ids, names, order, formatting; Cost = {currency: int}, unknown = null
      price_book.gd          price layers (catalogue < data/prices < user overrides), per-copy prices, methods
      budget_engine.gd       owned-copy allocation, per-object cost in 3 modes, totals per scope, land supplies,
                             phase status, affordability; incremental per item, lazy, batch API, caches per version
      shopping_list.gd       grouped rows from per-item rollups (rows reused while their item is unchanged)
      inventory_io.gd        owned / purchased / balances as CSV and JSON
      baseline.gd            snapshot of the real farm, diff (unchanged / moved / new / removed, fungible reuse)
      recreation_guide.gd    ordered steps (7 stages), clusters, landmark-relative directions, stable step ids
      guide_export.gd        guide as HTML / CSV / JSON / text (strings only, no file IO, no art)
      accuracy_report.gd     map provenance, landmark and footprint confidence, calibration results
      readiness.gd           "Can I build this?" rows from conflicts, the Realistic report, can't-buy counts
      client_prices.gd       private client-price supplement from the user's own client tables
      placement_check.gd     calibrated screenshot vs world: per-point errors, truck anchor readings
      skin_budget.gd         design-customization budget (farmhouse / truck / shop looks)
    layout_library.gd      user layouts: list, duplicate, rename, trash, history snapshots, autosave
    realistic_analyzer.gd  "can I build this?" report (never mutates); Cached = per-layout memo
    layout_diff.gd         geometric comparison of two layouts
    json_util.gd           JSON + crash-safe atomic writes
    terrain_pack.gd        pack terrain manifest ("hayday-sandbox-terrain", docs/TERRAIN_PACKS.md): variants per
                           theme, ground tiles, pieces, diagnostics
    client_level.gd        reader for the client's level CSV and tables (layout only; the files stay private)
    world_validator.gd     compares world data with the client's level data (rules only, no coordinates)
  assets/
    asset_library.gd       layered asset packs → SpriteInfo (texture, anchor, scale, shadow, alpha hit mask,
                           ambient animation sheet or lazily loaded patch sheet, additive glow layer,
                           hand-drawn mirror art), lazy textures + thumbnails,
                           variants and "theme_<season>" variants, overrides, review queue, pack world data
    pack_overrides.gd      pure overrides.json / catalogue-overrides parsing and merging + auto-anchor maths
    pack_installer.gd      .zip pack install (validation, zip-slip guard, atomic replace)
    asset_importer.gd      user art import (folders, atlases, manifests, trimming, hashing, report)
  render/                  scene nodes that draw the world
    terrain_layer.gd       original procedural ground of worlds without game terrain (grass, road, bridge,
                           river, forest, cliff), built from the map; a season change only re-tints it
    terrain_textures.gd    procedural seamless textures
    pack_terrain_layer.gd  terrain art from a pack: background colour, ground tiles, pieces (meshes, blend modes,
                           foreground), animated water clips in view; camera rect from the pieces
    ground_layer.gd        terrain runs (game-data worlds), raised land edge, locked-plot tint and hatching,
                           level-blocked plots, plot borders/labels
    scenery_layer.gd       decorative forest around the farm (never blocks)
    reference_layer.gd     screenshot overlays (several per layout) with 2- or 3-point calibration
    grid_overlay.gd        grid + occupied-tile overlay
    object_renderer.gd     RenderingServer canvas items per object and per world entry (landmarks), draw index
                           from DepthSorter, picking, tints, ambient animation (Off/Reduced/Full), object
                           layers (hidden objects are not drawn and not pickable; dimmed ones are faded)
    landmark_view.gd       landmark → world entry: state, skin preset and theme variant resolution, names
    selection_underlay.gd  selection fill + drag validity tiles, drawn under the objects
    editor_overlay.gd      hover, selection outlines, ghosts, blockers, reason chips, marquee, notes, diff, labels
    tool_overlay.gd        the symmetry mirror line (never exported)
    plan_overlay.gd        planning marks: area fills (an `under` item below the objects) and outlines / names,
                           active area / phase, highlights, progress checks, guide numbers, cost heatmap, compare
                           tints, arrows and ghosts, area-tool draft; own visibility layer, exported only on request
    farm_camera.gd         Camera2D side of CameraMath: animated and immediate view changes, limits, fly-to
    exporter.gd            offscreen tiled rendering of the shared World2D → Image
  editor/
    editor_session.gd      per-document editing state + high-level operations (shared by UI & keys);
                           fixed-item rules, Realistic level rule, landmark selection, symmetry settings
    editor_controller.gd   pointer gestures → tool behaviour → Commands (one gesture = one undo step); picking
                           cycle, "Objects here", drag hysteresis and snap to valid
    layout_tool_controller.gd  stamps, mirror line, outline / fence-line brush, repeat preview (sees canvas input first)
    plan_controller.gd     area tool: rectangle, polygon, from selection → one SetPlanning (sees canvas input first)
  ui/                      theme (code-built), icons, panels, dialogs — no business logic
    plan/                  the Plan panel and its framework
      plan_context.gd        PlanContext: what tabs and dialogs talk to (models, view state, request_* signals,
                             coalesced `changed`, cached guide / compare diff / readiness)
      plan_tab.gd            PlanTab base: _build() once, refresh() only when visible and the context changed
      plan_panel.gd          tab rail + lazily built tabs: plan_budget/areas/phases/shop/build/guide/accuracy_tab.gd
      plan_scope.gd, plan_ui_models.gd  pure view-models (scope, heatmap buckets, rows, texts; unit-tested)
      plan_ui.gd, plan_ui_kit.gd        shared widgets, PagedList, file dialogs that refuse the program folder
      plan_dialog.gd, readiness_card.gd dialog base (modal contract), the "Can I build this?" card
    budget_widget.gd       budget chip on the canvas (scope, mode, unknowns, breakdown, corner)
    minimap.gd             overview map: two 1-pixel-per-tile images under the iso transform, view rectangle
    compare_legend.gd      legend and counts of "Compare with my farm"
    inventory_dialog.gd, price_dialog.gd, baseline_dialog.gd   planning dialogs (PlanDialog)
    catalog_panel.gd       catalogue with category rail, search, badges
    inspector_panel.gd     Selection (objects, placing card, landmark card) / Farm / View tabs; auto-hides
                           when nothing needs it
    stamps_panel.gd        floating stamps list (save, place, export, import, delete)
    panel_grip.gd          drag handle that resizes a side panel (double-click = automatic width)
    tool_dock.gd, top_bar.gd, dialogs.gd, gallery.gd, modal.gd, toasts.gd, ui.gd, ui_theme.gd, icons.gd
    asset_manager.gd       Asset Manager (Ctrl+Shift+A): footprint preview, anchor/scale edits, review queue, packs
    art_import_dialog.gd   user art import UI
  app/
    app.gd                 autoload service locator: settings, db, maps (world), assets, library, session,
                           prices (PriceBook), plan_ctx (PlanContext)
    settings.gd            persistent preferences (user://settings.cfg)
    main.gd                composition root: builds world + UI, panel layout, wires signals, global shortcuts
data/  items/ maps/ prices/ samples/ research/   tools/  art_generator/ catalog/ ci/ build/ samples/ ui/ private_assets/
assets/ placeholders/ (generated CC0 art) ui/ (font, icons) original/ (git-ignored, local only)
tests/ unit/ (headless, --script) integration/app_selftest.gd (in-app) visual/capture.gd (real rendering)
       perf/ (headless benchmarks: perf_planning.gd, perf_budget.gd, perf_depth.gd)
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
  `water_deco_zones` (`[{id, name, rect: [x, y, w, h], enabled}]`, usually off the placement grid in the river) are
  the only tiles where items tagged `water_deco` may stand: `PlacementRules.tile_code(…, zone_item)` /
  `check_rect(…, zone_item)`; per object the flag comes from `FarmLayout.zone_items` (set by `EditorSession` from the
  catalogue, like `fixed_items`), so `ConflictIndex`, `find_conflicts`, moves, pastes and `LayoutTools.fit_mask`
  agree. The editor overlay draws the zones while such an item is armed or dragged.
* **Renderers** subscribe to layout signals and update incrementally; they never mutate the model.
* **`LayoutToolController`** sees canvas input before `EditorController` and commits only through
  `EditorSession`. `StampLibrary` owns `user://stamps/`. `main.gd` owns panel widths and visibility (remembered in
  the settings) and reattaches the layout tools after a UI rebuild.

### Planning state

* **The planning document** is `FarmLayout.planning` (schema 4), changed only by `EditCommands.SetPlanning`
  (signal `planning_changed`); inventory and balances live in `FarmLayout.profile` (`SetProfile`). Both are
  undoable and saved with the layout.
* **`PriceBook`** is one long-lived service, `App.prices` (catalogue < `data/prices/hayday_prices.json` <
  `user://price_overrides.json`). It is reloaded from the catalogue when a pack changes the catalogue; its `changed`
  signal reaches the engine and the context.
* **`BudgetEngine`** is owned by the `EditorSession` (`session.budget`): created with the session from the
  layout, the catalogue, `App.prices` and the map; `dispose()`d when the session is replaced (it lets go of the
  layout's signals); `set_map()` rebinds and invalidates it. It listens to the layout and only marks work; the
  next query recomputes what changed (per item; a move re-runs area / phase membership for the moved uids only).
  Queries also detect planning / profile dictionaries edited in place (a hash per query) unless inside
  `begin_batch()` / `end_batch()` / `batch(f)`. Results returned from caches are shared and read-only.
* **`PlanContext`** is one object for the whole app, `App.plan_ctx`. `App` rebinds it to every new session
  (`bind(session, session.budget, prices, db, map)`) and connects the session's budget, planning, selection and
  history signals to `notify_changed()`, which emits `changed` at most once per frame. It owns view state that is
  never saved in the layout (cost mode, scope pin, active area / phase, guide step, planning layers, compare on /
  off; `main.gd` mirrors the persistent parts in the settings) and caches the guide, the compare diff and the
  readiness rows per command-stack version. Tabs (`PlanTab`) and dialogs (`PlanDialog`) read it and ask for canvas
  or file actions through its `request_*` signals, which `main.gd` and `PlanController` implement.
* **`PlanOverlay`**, the **budget chip**, the **overview map** and the **compare legend** only read the context
  and redraw when told; none of them mutates the layout. The overlay draws in two canvas items (fills under the
  objects, marks above them) on a visibility layer that no exporter mask includes, so the plan appears in a
  picture only when the export asks for it (`main.gd` switches the layer for that one capture).
* **Object layers** are a setting (`object_layers`), applied by `ObjectRenderer`; they never touch the layout.
* **Exports with installed art**: `main.gd` renders with the placeholder library unless the caller asks for
  `"installed"` art, refuses to save such pictures inside the program folder and warns not to share them. Text
  exports (`PlanUiKit.write_text`) refuse the program folder.

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

Layouts (`.hdlayout`, JSON, `schema_version` 4) store each object's footprint, so unknown items keep their space.
Renamed ids map through `aliases`; changed footprints keep the origin (an axis-only change on a flippable item
toggles `flipped`) and are reported; overlaps are flagged, never deleted; unknown fields are preserved. Catalogue
items that duplicate a fixed landmark are taken out on every load and kept in `migration.migrated_landmarks`.
Migrations run step-wise: 0→1 (prototype shape), 1→2 (game tile frame shift, landmark extraction, starter lock
cleared), 2→3 (`reference` becomes a list of images), 3→4 (`planning` block; zone annotations become rectangle
areas, labels stay annotations). Saving over a file of any older schema first keeps its bytes as
`<file>.v<N>-backup` (e.g. `.v3-backup`); if that copy fails, the save is refused. A file of a newer schema is
refused with a message. The planning block keeps unknown keys. Writes are atomic: write `.tmp` → verify by re-reading → move old to `.bak` → rename.
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

Planning (`tests/perf/perf_planning.gd`, same PC, 2026-11-10, mean ms after the a511d0c changes; real catalogue
items from 500 types on the real map, 5 areas, 4 phases, a baseline; the PC was busy, expect ±30 %; full table and
method in TESTING.md):

| | 2,000 objects | 10,000 objects |
|---|---:|---:|
| Edit + whole-farm budget refresh | 1.8–2.2 | 5.5–7.7 |
| Full recompute + totals | 12.3 | 49.9 |
| Shop tab data, whole farm, after an edit | 4.3 | 9.1 |
| `area_totals` (rect + polygon) after a move | 2.0 | 6.1 |
| Phases tab, cold | 4.5 | 17.2 |
| Build tab model (`PlanUiModels.checklist`) | 30.5 | 105.0 |
| `RecreationGuide.build` (1,565 / 7,170 steps) | 181 | 825 |
| `GuideExport.to_json` | 101 | 487 |

Per-object loops (overlay progress marks, heatmap) use `placed_set()` / batches: checking `is_placed` per object
without batching took 3.7 s at 10k objects, which is what made camera moves slow before a511d0c.
