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
* ✅ Grid fades with zoom; occupied-tile overlay (O); item name labels; notes layer; planning layers (see below)
* ✅ Original terrain details: grass tone variation, river banks, road verges, a visible boundary between owned and locked land, winter tints
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
* ✅ Notes tool (N): click adds a note; drag adds a rectangular planning area (zones of older layouts became areas)
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
* ✅ Versioned schema (v4: adds the `planning` block), migrations 0→1→2→3→4 with a load report and a backup of the original file (`<file>.v<N>-backup` on the first save), missing/renamed/resized item handling, unknown fields preserved; rename is undoable
* ✅ Compare with another layout: added/removed/moved overlay and item deltas
* ✅ Export PNG: whole farm / unlocked land / objects / view; 0.5–3×; transparent; grid; labels; tiled rendering for large images

## Screenshot reference
* ✅ Several images per layout; import (copied to user data), per-image opacity, visibility, lock and order, above/below objects, drag to move, scale/rotation; every change undoable
* ✅ Calibration from 2 to 24 points (View tab › reference image › Calibrate: 2 / 3 / 4 points, then Add point). Click a point on the screenshot, then the same tile corner on the grid; a corner or the centre of a landmark snaps to it. 2 points: position, rotation, uniform scale (exact, error not measurable). 3+: affine least squares (also fixes a stretched image). With more points than the fit needs, each point's error is listed in tiles and pixels, with a verdict (good: RMS < 0.25 tile and max < 0.5; fair: RMS < 0.5 and max < 1.0; else poor) and a 2:1 isometric check. Points can be removed (refit); every change is undoable
* ⬜ Automatic detection (computer vision) — researched only; manual alignment is the reliable path

## Farm planning

Workflow: **Design → Budget → Areas → Phases → Shop → Build → Guide** (the strip in the top bar opens each step;
on narrow windows it becomes one Plan menu). Rules, saved fields and formats: [PLANNING.md](PLANNING.md). Every
planning edit is one undoable command (`SetPlanning` / `SetProfile`); nothing here changes the design itself
unless noted.

### Price data
* ✅ `data/prices/hayday_prices.json`: 1,962 records (the 5 missing catalogue items are editor-only markers),
  each with a method, price (when known), per-copy step or schedule, maximum count, availability, confidence,
  sources and notes. Coverage (from [PRICING_RESEARCH.md](research/PRICING_RESEARCH.md) §7): 338 shop items
  (217 coins, 121 diamonds), 66 voucher, 38 event currency, 5 free; 1,514 can't be bought (1,500 not sold in
  the shop, 14 rewards); 1 unknown. 125 items have a per-copy step, 21 an explicit per-copy schedule.
* ✅ Four layers: catalogue cost fields < price file < **prices from your own game files** (private, optional)
  < your overrides. Every price shows where it came from.
* ✅ **Prices from your game files** (Asset manager > Game data; `docs/research/CLIENT_PRICES.md`): import the
  data tables of your own Hay Day client. Records are matched by verified export names, aliases, translation ids
  and exact names, and unclear ones wait in a review list for your decision. The import shows before/after
  coverage, and you can restore the previous version or remove it. Appearance parts of the farmhouse, truck and
  roadside shop are kept apart, and the skin picker shows a preset's part cost. Everything stays in your private
  data folder.
* ✅ Pearls as a currency. The game's numbered vouchers are mapped to green/blue/purple/gold (verified against
  research). Prices can rise every N copies, and the 999-diamond placeholder is never a price.
* ✅ **Price your shop shows now** (price dialog): the price the game shows for your next copy sets your purchase
  count, so later copies are priced from there (undoable).
* ✅ **Edit price…** (Shop row, Budget tab pencil, or wherever an unknown price is listed): shows the record of each
  layer with sources and confidence, previews copies 1–10, and saves your override to
  `user://price_overrides.json` (never the repository). "Remove my override" restores the researched value.
* 🟡 The rule for what the per-copy step counts (copies owned, or copies ever bought) is unverified; the app uses
  copies owned unless you record "purchased" in the inventory.

### Inventory
* ✅ **Inventory dialog** (Budget tab › Record inventory…, Shop tab › Inventory…): farm level, balances (coins,
  diamonds, vouchers, event currencies, expansion supplies) and per item the copies owned and bought so far.
  Search and filters; type a number and press Enter to go to the next row. A blank field means "not recorded",
  which the budget treats as unknown ownership (to buy, and counted), not as 0.
* ✅ "Fill from this design" and "Fill from my real farm" raise owned counts to at least what the design / the
  baseline uses (recorded counts are never lowered).
* ✅ Import CSV or JSON (tolerant: header or none, `,` `;` or tab, names or ids, aliases; unknown and ambiguous
  rows are reported, not guessed) and export CSV / JSON. Apply = one undo step; Cancel discards.

### Budget chip (canvas)
* ✅ A chip in a corner of the canvas with the cost per currency (never converted), the scope and the mode.
* ✅ Scope follows the selection, else the active area, else the active phase, else the whole farm; click the
  scope to pin it to the whole farm instead.
* ✅ Modes (click the mode to switch): **Design cost** (every object priced as a purchase, inventory ignored),
  **To buy** (owned copies deducted, plus the expansion supplies of locked plots the design stands on),
  **Remaining** (also deducts copies bought during the project).
* ✅ A warning next to the total counts unknown prices, items that can't be bought and unknown ownership; click it
  for the breakdown. The ⋮ menu shows or hides the breakdown, shrinks it to one line, moves it to another corner,
  opens the Budget tab or hides it (View tab › Planning layers › Budget chip brings it back). Size, corner,
  mode and scope are remembered in the settings.

### Plan panel (J)
* ✅ Opens in the inspector's place on the right (J, the top-bar strip, or Esc / J / X to close). Tabs: Budget,
  Areas, Phases, Shop, Build, Guide, Accuracy. Resizable; on narrow panels the tab rail shows icons only.
* ✅ **Budget tab**: "Can I build this?" card at the top; whole farm, selection, active area and active phase side
  by side; what is not in the totals (unknown prices with an edit button, can't-buy items, unknown ownership)
  with ways to fix it; land supplies; area and phase targets (over-target in red); the most expensive objects and
  areas (click to show them); the heatmap legend.
* ✅ **Can I build this?** Blocking rows (overlaps and invalid spots, objects on fixed farm buildings, locked land,
  expansions above the farm level and items above the farm level — the last two in Realistic Mode only —, over
  the maximum count, can't be bought and not owned, items from other areas) and check rows (unverified
  footprints, unknown items, no inventory record). Kept apart from costs; each row selects, frames and
  highlights its objects.

### Areas
* ✅ Draw with Plan › Areas › **Rectangle** (drag), **Polygon** (click corners; double-click, Enter or a click on
  the first corner closes it; Backspace removes the last corner; Esc or right-click cancels) or **From
  selection** (a rectangle around the selected objects). The notes tool (N) also makes a rectangle area by
  dragging. Camera input passes through while drawing.
* ✅ Rename, recolour, show / hide on the farm, coin and diamond targets, Picture… (PNG of the area, placeholder
  art), **Save as stamp** (the area's objects with their relative positions into the stamp library; fixed farm
  buildings left out; the layout is not edited), Delete (objects stay).
* ✅ Clicking a row makes it the active area (budget scope, canvas highlight) and frames it. An object belongs to
  every area that contains any tile of its footprint; when shown areas share objects, the tab says that their
  totals overlap.
* ⬜ Moving or reshaping an existing area (delete and redraw).

### Phases
* ✅ Add phase, rename, recolour, reorder (▲ ▼ = build order), attach areas (check boxes), mark done, delete.
* ✅ An object's phase is its manual assignment (**Assign selection…**, **Clear manual**), else the first phase in
  build order with an area containing it, else *Unphased*. Phase totals add up to the farm total.
* ✅ Each phase shows its objects, Design / To buy / Remaining cost, status (not started, in progress, ready to
  build, completed), target, Show (frame and highlight) and Picture… (with guide step numbers).
* ✅ **Available budget**: edit your coin and diamond balances; the tab lists which phases they pay for in build
  order (Remaining cost, summed; a lower bound once a phase has unknown prices).

### Shop
* ✅ Shopping list for the whole farm, the selection, a phase or an area, in To buy / Remaining / Design mode,
  grouped (Decorations, Fences, Paths, Trees, Bushes, Flowers, Production machines, Animal homes, Farm
  buildings, Expansion supplies, Other) with subtotals.
* ✅ Search, sort (group, name, cost, still needed, unlock level), filter chips (Unfinished, Can't buy, Unknown
  price, Over limit). Rows show still needed, next price (a range when the price rises per copy) and badges;
  a click opens details with a **bought** counter (+1 or typed), Edit price… and Show on farm.
* ✅ Expansion supplies rows: needed for the locked plots, what you have (balances), missing; supplies have no coin
  price.
* ✅ **Add bought items to inventory** moves the bought counts into owned in one undo step. **Export CSV…**
  writes the list (unknown stays "unknown").

### Build
* ✅ Checklist per phase (build order) and item group: not acquired / acquired, not placed / placed in Hay Day,
  with a progress bar per phase and overall.
* ✅ Mark selected placed / Not placed, Mark phase placed, Show remaining (highlight and frame), per-group ticks.
  A burst of ticks merges into one undo step. Objects moved after being marked placed are listed with Show,
  Placed here and Not placed.
* ✅ Header toggle for Compare with my farm.

### Guide
* ✅ Numbered steps in stages: unlock land, clear obstacles, store and move existing objects (with a baseline),
  large buildings, paths and fences, trees / bushes / flowers / fields, decorations. Within a stage: phases in
  build order, then clusters of touching copies of the same item.
* ✅ A card for the current step with directions relative to the nearest visible map landmark (empty tiles between
  them and the direction as seen on screen; flagged when the landmark position is approximate) and exact tiles;
  Previous / Next,
  Show on the farm, **Mark step done** (marks its objects placed, or ticks steps without objects).
* ✅ Export guide…: printable HTML (a section per phase, optional pictures), CSV checklist, JSON, plain text,
  an overview PNG, a PNG per phase. Pictures use the placeholder art unless you pick "Installed art (private)";
  those pictures can't be saved in the program folder and the app warns not to share them.
* ⬜ PDF export: print the HTML page to PDF from a browser.
* 🟡 Installed-art pictures were exercised with the synthetic test pack only, not with a real private pack.

### Accuracy
* ✅ Farm Accuracy Report: a one-line headline, then sections on map source, start land, expansions, landmarks,
  footprints, the layout's use of approximate data, the calibration result of every reference screenshot and
  what is still uncertain. It never calls anything exact; at best "matches a screenshot within N tiles".
* ✅ **Calibrate a screenshot** opens the View tab's reference images; **Copy report as text**.

### My real farm and Compare
* ✅ **My real farm** dialog: take a snapshot of the open layout ("Use this layout as my real farm") or read
  another saved layout without changing it. Objects are matched by id and item, so use the layout this design was
  copied from. Shows what the design keeps, moves, adds and removes; Remove snapshot. Undoable.
* ✅ The baseline counts as owned copies (a lower bound), its unchanged objects count as placed, and the guide
  stores, moves and clears from it. A removed copy is reused by a new copy of the same item (not bought again).
* ✅ **Compare with my farm** (View tab, Build tab header): unchanged objects faded, moved ones with a dashed old
  footprint and an arrow, new ones tinted, removed ones as dashed ghosts with a cross; a legend with counts.
  Progress marks and guide numbers are hidden meanwhile. Without a baseline the toggle opens the dialog.

### Canvas layers, overview map, object layers
* ✅ Planning layers (View tab): areas, progress marks, cost heatmap (coins buckets < 100, < 1,000, < 10,000,
  ≥ 10,000; other currencies only; nothing to pay; unknown and can't-buy hatched), guide step numbers, budget
  chip. Not in exported pictures unless an export asks for them.
* ✅ **Overview map** (Shift+M or View tab): owned and locked land, road, water, fixed farm buildings, objects in
  category colours (the active phase in its colour), area outlines and the camera's view; click or drag to move
  the camera. Collapsible. Shown only when the free canvas is at least 700×420 logical px.
* ✅ **Object layers** (View tab): show, dim or hide Decorations, Production buildings, Animal homes, Trees &
  bushes, Fences, Paths, Fields & other. View only, remembered in the settings; hidden objects can't be picked,
  box-selected or erased.

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
* ✅ Offline; data in `%APPDATA%\HaydaySandbox` (Windows) / `~/.local/share/HaydaySandbox` (Linux), including `price_overrides.json`
* 🟡 Windows build: produced and packaged by CI; headless checks and visual tests run on a Windows PC (`tools\ci\windows_checks.ps1`, `visual_tests.ps1`, single commands through `run_godot.ps1`); manual checklist not completed — see TESTING.md
