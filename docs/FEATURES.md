# Features (implemented)

Status: ✅ implemented & tested · 🟡 implemented, partially verified · ⬜ not implemented (see ROADMAP).

## Canvas & rendering
* ✅ 2:1 isometric grid, tile picking, pan (Space/middle/right-drag, H tool, arrows when nothing selected), smooth zoom at cursor (12–400 %), fit farm (F)
* ✅ Terrain: buildable land, locked plots (hatched, numbered), road, river, forest edge, raised land edge; decorative forest scenery
* ✅ Topological depth sorting, flat layer for paths, separate soft shadow layer
* ✅ Pixel-accurate picking with footprint fallback (large objects select reliably)
* ✅ Grid fades with zoom; occupied-tile overlay (O); item name labels; notes & zones layer
* ✅ Missing/unknown art → footprint-sized vector fallback; unknown items kept and shown with "?"

## Catalogue
* ✅ 1,967 items, 17 categories, instant search (name/id/category/tags, relevance scoring), category chips
* ✅ Favourites (right-click), recently placed, sort by relevance/name/level/size
* ✅ Filters: fits my level, trusted sizes only, hide reference-only, only items with their own art
* ✅ Thumbnail grid with progressive loading, detail card with size/level/price/status badges
* ✅ Variant picker for placed objects whose art has variants (inspector, undoable); art badges + variant counts

## Editing tools
* ✅ Select, box select (marquee), Shift/Ctrl add, double-click selects all of a type, select all
* ✅ Drag-move single/multi/groups with ghost preview + per-tile validity; invalid drops snap back with a reason
* ✅ Place: click, paint strokes, Shift line, Ctrl/“Fill” rectangle, repeat placement; per-tile green/red/orange preview with reasons
* ✅ Erase click/stroke, Shift-drag area clear; eyedropper (I / Alt+click)
* ✅ Rotate (mirror, swaps W×H) only for items the game allows; rotating into a conflict is allowed and flagged (matches the game's Dec 2025 behaviour)
* ✅ Copy / cut / paste stamp / duplicate; group / ungroup (clicking a member selects the group); lock / unlock
* ✅ Planned (future) objects; editor-only reserved-space markers
* ✅ Fences and paths auto-connect per item (16 shapes), graceful degradation for packs with fewer shapes
* ✅ Notes and zones (create, edit, delete) on the farm
* ✅ Command-based undo/redo, gesture = one step, nudges merge, bounded history, dirty tracking
* ✅ Context menu, full keyboard shortcuts, F1 cheat-sheet

## Land & modes
* ✅ Data-driven map with 52 main-section plots, adjacency and unlock rule; two start-land hypotheses (Settings)
* ✅ Land tool: click plots to lock/unlock, Shift-click all; unlock all / starting land only
* ✅ Creative ↔ Realistic switch never changes the layout
* ✅ Realistic report: required level, level-locked items, shortages vs. inventory, max-per-farm, land needed, cost from known prices only, budgets, unverified sizes, planned exclusions; click entries to select the objects
* ✅ "I own everything placed now" inventory snapshot; "assume unlisted items owned" default
* ⬜ Upper plots and across-road sections (geometry unknown — listed, not drawn)

## Layouts
* ✅ Create from templates (starter with locked core buildings, fully expanded, empty), 5 original sample designs
* ✅ Gallery with thumbnails, filter, open, duplicate, rename, delete→trash, revision restore, import/export `.hdlayout`
* ✅ Atomic saves + .bak, recovery from corrupted files, autosave + crash recovery prompt, revision snapshots, Save / Don't save / Cancel prompt when closing with unsaved changes
* ✅ Versioned schema, migrations, missing/renamed/resized item handling, unknown fields preserved
* ✅ Compare with another layout: added/removed/moved overlay and item deltas
* ✅ Export PNG: whole farm / unlocked land / objects / view; 0.5–3×; transparent; grid; labels; tiled rendering for large images

## Screenshot reference
* ✅ Import (copied to user data), opacity, visibility, lock, above/below objects, drag to move, scale/rotation
* ✅ 3-point affine calibration to tile corners
* ⬜ Automatic detection (computer vision) — researched only; manual alignment is the reliable path

## Art & data
* ✅ Original CC0 placeholder art for all items (474 dedicated + shared generic), 16 connection shapes for fences/paths
* ✅ In-app art importer (folders, sprite sheets, manifests, trimming, hashing, report) into private packs
* ✅ Layered asset packs, hot reload after import; `.zip` pack install (Settings or `-- --install-pack=`)
* ✅ Asset Manager (Ctrl+Shift+A): footprint preview with original/placeholder/onion skin, drag/arrow anchor
  editing, scale (per item or whole category), verify / reject, variants, review queue, pack overview — all saved
  to per-pack `overrides.json`

## App
* ✅ Dark/light themes, UI scale auto/100–300 %, collapsible panels, Tab = full canvas, toasts, welcome onboarding
* ✅ Offline; data in `%APPDATA%\HaydaySandbox` (Windows) / `~/.local/share/HaydaySandbox` (Linux)
* 🟡 Windows build: produced and packaged by CI; not executed in the cloud (no Windows/Wine) — see TESTING.md
