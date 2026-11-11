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

**W5: authentic visual fidelity + real-world verification (7ce14cc and the W5b commit; 2026-11-10):**
* Private pipeline from the user's own game files (never in git): pack terrain (ground per season, edge meshes,
  foreground, blend modes, water clips, camera limits from the pieces), object animations and glow layers
  (`build_anims.py`), 72 client-only catalogue additions (incl. the pearl water decorations), client prices,
  pack QA and calibration sheets.
* World check against the client's level data (ground, plots, landmarks, water-decoration zones; Plan → Accuracy
  evidence ladder) and water decorations limited to the river's zones.
* Faster planning at 10k objects: incremental Realistic report, cached readiness card, Build tab model and guide
  steps (equivalence-tested against fresh computations).
* Editor feel: lift / drop motion, fence junctions, theme and mirror art in ghosts, catalogue thumbnails below the
  badges.
* Verification with the real pack: self-test with the pack installed, `--selftest=packcycle` (uninstall reverts
  everything), private captures at 4 resolutions × 4 UI scales, installed-art exports; Windows and Linux exports
  built and content-checked on the cloud box.

**Farm planning wave (817748c, b256fbc, a511d0c; 2026-11-10):**
* Researched price data (`data/prices/hayday_prices.json`, 1,962 records with sources and confidence;
  `docs/research/PRICING_RESEARCH.md`), price layers with user overrides, inventory with CSV/JSON import/export.
* `BudgetEngine`: owned-copy allocation by build order, Design / To buy / Remaining per object, any scope, land
  supplies, unknowns counted; incremental and batched (planning perf table in TESTING.md).
* Layout schema 4 (`planning`: areas, phases, assignments, placed / acquired marks, baseline, guide ticks); zones
  become areas; every planning edit undoable (`SetPlanning`).
* Budget chip; Plan panel (J) with Budget, Areas, Phases, Shop, Build, Guide and Accuracy; area tool; inventory,
  price and "My real farm" dialogs; plan overlay (areas, progress, guide numbers, heatmap).
* Recreation guide with landmark-relative directions and HTML / CSV / JSON / text / PNG exports (placeholder art
  unless the user picks installed art).
* Farm Accuracy Report and N-point screenshot calibration with residuals.
* Overview map (Shift+M), object layers, Compare with my farm, area → stamp, "Can I build this?" card.
* Terrain polish (grass tones, banks, road verges, owned-land boundary, winter fixes); mirrored items without art
  get the right hit area.
* `tools\ci\run_godot.ps1` and a shared Godot lock for all Windows runners.

**Editor wave (up to HEAD 8c93360):**
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
* Several reference images per layout with 2/3-point calibration (N points since the planning wave); layout
  schema 3.
* UI: resizable and collapsible panels, auto-hiding inspector, catalogue category rail, badges, grouped issues,
  help built from the key bindings.
* Eight verification fixes, each with a regression test (see the commit message of 8c93360).

## Not done yet

Snow particles and clouds / light rays (their placement is not in the client data), per-mesh mixed blend modes,
map authoring for the upper and across-the-road plots, and the questions that need an in-game screenshot
([KNOWN_ISSUES.md](KNOWN_ISSUES.md#pending-a-real-screenshot-and-how-to-settle-each-one)).

## Next (highest value)
1. **Settle the price-step basis in game** (buy, delete and re-check a cheap coin decoration such as a fence;
   PRICING_RESEARCH.md §1) and the open price conflicts (fence step, Sanctuary prices, the swapped pair).
2. **Verify geometry in-game** and update `data/research` → maps: real plot shapes of the main section, the 13
   upper plots and the across-the-road sections (the N-point calibration and its residuals can be used to trace
   and check them). No unlock rule is invented for plots whose adjacency is unknown. Better geometry also makes
   the guide's directions more trustworthy.
3. **Verify the Windows build** on real hardware (checklist in TESTING.md, now with planning steps); fix any
   DPI/IME/dialog issues.
4. **Settle the pending-screenshot items** (truck anchor, farmhouse art, tile seam, clouds, camera limits, water-zone
   rule; KNOWN_ISSUES.md) with the user's own screenshots and the placement check.
5. **Remaining slow planning paths at 10k objects**: the guide (~450 ms after an edit while its tab is open), guide
   JSON export (~230 ms), `Baseline.diff` while comparing (~50 ms per edit, not incremental).
6. **Run the Windows smoke test** of the exported `.exe` on the PC (`tools\build\build.ps1`) and watch the Linux
   export self-test for the one-off crash seen in W5b.
7. Items from KNOWN_ISSUES.md: moving / reshaping areas, stamp rotation while placing, the library's map choice,
   framing full-land exports by the pack terrain's extent.
8. **More dedicated placeholder art:** recipes for the most common "monument" fallbacks, production-building
   silhouettes beyond plaques.

## Later
* Distance measurement tool.
* Layout diff side-by-side view.
* Direct PDF export of the guide (today: print the HTML).
* Installer (Inno Setup) and auto-update check (opt-in, offline by default).
* Optional computer-vision assist for screenshot import (detect grid and large buildings; always user-confirmed).
* Localisation (strings are centralised in UI code; extract to translation tables).
