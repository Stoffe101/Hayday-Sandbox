# Features (implemented)

Status: ✅ implemented & tested · 🟡 implemented, partially verified · ⬜ not implemented (see ROADMAP).

## Canvas & rendering
* ✅ 2:1 isometric grid in the game's tile frame, tile picking, pan (Space/middle/right-drag, D pan tool, arrows when nothing selected) with inertia, smooth zoom at cursor (12–400 %), world limits with rubber band
* ✅ F fits the selection or the farm, Shift+F the whole world, H / Home centres the farmhouse; 1–9 / Ctrl+1–9 go to / save views (stored in the layout, undoable)
* ✅ Original procedural terrain for the public map (grass, road, bridge, river, forest, cliff along the north edge as a visual choice); locked plots (hatched, numbered), level-locked plots in Realistic mode; decorative forest scenery
* ✅ Fixed landmarks (farmhouse, order board, truck, roadside shop, newspaper mailbox) drawn as world entries; selectable, never movable; approximate public positions don't block placement
* ✅ Topological depth sorting (incremental per edit), flat layer for paths, separate soft shadow layer
* ✅ Ambient animation of a few placeholder decorations, setting Off / Reduced / Full (default follows the OS reduce-motion preference)
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
* ✅ Select, box select (marquee), Shift/Ctrl add, double-click selects all of a type, select all; click again to select the object behind; right-click "Objects here"
* ✅ Drag-move single/multi/groups with live preview, hysteresis, per-tile validity and blocker outlines; invalid drops snap back with a reason, or (Alt / setting) jump to the nearest free spot
* ✅ Layout tools: symmetry placement (3 mirror lines), repeat arrays, align, equal spacing, fence/path line and outline brushes, stamps (`.hdstamp`, export/import)
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
* ✅ Data-driven map (schema 2, game tile frame) with 32×32 starting land, 52 main-section plots, adjacency and unlock rule (the 48×32 map is retired; its layouts migrate)
* ✅ Land tool: click plots to lock/unlock, Shift-click all; unlock all / starting land only; in Realistic mode plots above the farm level are refused
* ✅ Farm level per layout (default in Settings); Creative is the full sandbox, Realistic limits by level (brush, eyedropper, paste, duplicate)
* ✅ Creative ↔ Realistic switch never changes the layout
* ✅ Realistic report: required level, level-locked items, shortages vs. inventory, max-per-farm, land needed, cost from known prices only, budgets, unverified sizes, items from other areas, planned exclusions; issues grouped by reason, click to select the objects
* ✅ "I own everything placed now" inventory snapshot; "assume unlisted items owned" default
* ⬜ Upper plots and across-road sections (geometry unknown — listed, not drawn)

## Layouts
* ✅ Create from templates (starter with movable barn and silo, fully expanded, empty; "brand-new game farm" only with private world data), 5 original sample designs
* ✅ Gallery with thumbnails, filter, open, duplicate, rename, delete→trash, revision restore, import/export `.hdlayout`
* ✅ Atomic saves + .bak, recovery from corrupted files, autosave + crash recovery prompt, revision snapshots, Save / Don't save / Cancel prompt when closing with unsaved changes
* ✅ Versioned schema (v3), migrations with a load report and a backup of the original file, missing/renamed/resized item handling, unknown fields preserved; rename is undoable
* ✅ Compare with another layout: added/removed/moved overlay and item deltas
* ✅ Export PNG: whole farm / unlocked land / objects / view; 0.5–3×; transparent; grid; labels; tiled rendering for large images

## Screenshot reference
* ✅ Several images per layout; import (copied to user data), per-image opacity, visibility, lock and order, above/below objects, drag to move, scale/rotation; every change undoable
* ✅ 2- or 3-point calibration to tile corners
* ⬜ Automatic detection (computer vision) — researched only; manual alignment is the reliable path

## Art & data
* ✅ Original CC0 placeholder art for all items (475 dedicated + shared generic), 16 connection shapes for fences/paths, truck landmark placeholder
* 🟡 Private packs can carry world data (landmark positions, initial objects) and catalogue corrections; tested with synthetic packs only, not with a real private pack
* ✅ In-app art importer (folders, sprite sheets, manifests, trimming, hashing, report) into private packs
* ✅ Layered asset packs, hot reload after import; `.zip` pack install (Settings or `-- --install-pack=`)
* ✅ Asset Manager (Ctrl+Shift+A): footprint preview with original/placeholder/onion skin, drag/arrow anchor
  editing, scale (per item or whole category), verify / reject, variants, review queue, pack overview — all saved
  to per-pack `overrides.json`

## App
* ✅ Dark/light themes, UI scale auto/100–300 %, resizable panels with remembered widths, catalogue collapses to a category rail ([), auto-hiding inspector (]), Tab = full canvas, toasts, welcome onboarding, help built from the key bindings
* ✅ Offline; data in `%APPDATA%\HaydaySandbox` (Windows) / `~/.local/share/HaydaySandbox` (Linux)
* 🟡 Windows build: produced and packaged by CI; headless checks and visual tests run on a Windows PC (`tools\ci\windows_checks.ps1`, `visual_tests.ps1`); manual checklist not completed — see TESTING.md
