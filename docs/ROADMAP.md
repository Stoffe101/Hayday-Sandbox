# Roadmap

Scope: the **main farm** only (starting land, main expansion section and, once their geometry is known, the upper
and across-the-road plots). Separate areas of the game get no editors or maps; their catalogue items stay
reference-only and are flagged when they appear in a layout.

## Done

**Milestone 1:** research + legal policy, data model, catalogue from research, map with 52 plots, original art
pipeline, editor (place/paint/line/fill/select/move/copy/group/lock/rotate/erase/eyedropper/notes), undo/redo,
Realistic Mode, layouts (gallery, templates, autosave, recovery, revisions, import/export), screenshot reference +
calibration, comparison, PNG export, art importer, themes/scaling, unit + in-app + visual + performance tests, CI,
Windows build.

**World layer and private packs:** map schema 2 in the game tile frame (starting land 32×32; the 48×32 map is
retired and its layouts migrate), fixed landmarks as world data, layout schema 2 with migration, private asset
packs with Asset Manager, pack world data and catalogue corrections, leak guard and git hooks, incremental depth
order, farm level with Creative as the full sandbox.

**This wave (up to HEAD 8c93360):**
* Windows runners `tools\ci\windows_checks.ps1` and `visual_tests.ps1` (isolated `APPDATA`, off-screen captures
  without focus).
* Approximate public landmarks no longer block placement.
* Rename, reference images and saved views are undoable commands (`SetMeta`, `SetReference`,
  `SetCameraBookmark`); `MoveEach` for per-object moves (align, distribute).
* Realistic farm-level rule for the eyedropper, paste and duplicate; objects from other areas are flagged.
* Camera: springs, inertia, world limits, F / Shift+F / H / Home, nine saved views, D = pan tool.
* Picking and drag: click-again cycling, *Objects here*, hysteresis, live lifted preview, blocker outlines, snap to
  the nearest free spot, selection fill under the objects.
* Layout tools: symmetry, repeat, align, distribute, stamps (`.hdstamp`), fence/path line and outline brushes.
* `ConflictIndex` and cached Realistic analysis (per-edit figures in ARCHITECTURE.md).
* Original procedural terrain for the public map, truck placeholder, placeholder ambient animation with an
  Off/Reduced/Full setting, theme and mirror art resolution.
* Several reference images per layout with 2/3-point calibration; layout schema 3.
* UI: resizable and collapsible panels, auto-hiding inspector, catalogue category rail, badges, grouped issues,
  help built from the key bindings.
* Eight verification fixes, each with a regression test (see the commit message of 8c93360).

## Not done in this wave

Left out on purpose, with no commitment either way: client-file (XAPK) extraction, Fan Kit / wiki downloads,
private terrain mesh replay, animation-sheet extraction from game files, map authoring against game data,
screenshots with private art, and verification with the installed private pack. The existing tools in
`tools/private_assets/` were not changed.

## Next (highest value)
1. **Verify geometry in-game** and update `data/research` → maps: real plot shapes of the main section, the 13
   upper plots and the across-road sections (the screenshot calibration tool can be used to trace them). No
   unlock rule is invented for plots whose adjacency is unknown.
2. **Verify the Windows build** on real hardware (checklist in TESTING.md); fix any DPI/IME/dialog issues.
3. **Realistic analysis per edit** at 10k objects (see KNOWN_ISSUES.md).
4. Items from KNOWN_ISSUES.md: 200 % UI at 1920×1080, stamp rotation while placing, the library's map choice.
5. **More dedicated placeholder art:** recipes for the most common "monument" fallbacks, production-building
   silhouettes beyond plaques.

## Later
* Minimap / overview navigator for large farms.
* Distance measurement tool.
* Layout diff side-by-side view and printable shopping list (missing items with known costs).
* Layer visibility per category (hide decorations, show only production, etc.).
* Installer (Inno Setup) and auto-update check (opt-in, offline by default).
* Optional computer-vision assist for screenshot import (detect grid and large buildings; always user-confirmed).
* Localisation (strings are centralised in UI code; extract to translation tables).
