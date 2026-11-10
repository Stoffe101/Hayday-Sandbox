# Testing

All layers run locally (Windows or Linux) and in CI (`.github/workflows/ci.yml`). The static, unit and
integration counts are from the end of the farm-planning wave (Windows development PC, Godot 4.7.2, 2026-11-10,
`tools\ci\windows_checks.ps1 -Tag final`). The Windows build (`tools\build\build.ps1`) also smoke-tests the
exported exe headless: start-up, `--smoke-plan` (opens all seven Plan tabs and the three planning dialogs; a
release export compiles scripts more strictly than the editor) and installing a synthetic pack. Rows marked † are from the earlier run with `tools\ci\windows_checks.ps1 -SkipImport -Tag docs`
on 2026-11-09 at HEAD 8c93360 (logs in `artifacts\checks\docs\`) and were not re-counted for this update.

| Layer | Command (Linux form) | What it covers | Result |
|---|---|---|---|
| Static | `godot --headless --path . --script res://tools/ci/check_scripts.gd` | every `.gd` compiles | 147 scripts, 0 failed (end of the planning wave) |
| Data | `python3 tools/ci/validate_data.py` | manifests, maps, asset pack refs, samples, price file (`data/prices/`), **licence guard** | 1,967 items, 0 errors, 0 warnings † |
| Unit | `godot --headless --path . --script res://tests/run_tests.gd [-- --filter=x --junit=out.xml]` | core logic, art-free fixtures | 427 tests / 15,243 assertions, 0 failed (end of the planning wave) |
| Integration | `godot --headless --path . -- --selftest` | the real app driven by synthetic input | 506 checks, 0 failed (end of the planning wave; adds the "QA journeys" section) |
| Performance | `godot --headless --path . -- --selftest=perf` | synthetic farms 2k/5k/10k, densely packed real map, world layer, thumbnails | 7 checks, 0 failed (numbers below) † |
| Planning perf | `godot --headless --path . --script res://tests/perf/perf_planning.gd [-- --sizes=2000,5000,10000 --reps=30]` | budget engine, scopes, phases, checklist, shopping list, guide + exports on 2k/5k/10k real-item farms | table of mean / p95 / max (numbers below) |
| Budget perf | `godot --headless --path . --script res://tests/perf/perf_budget.gd [-- --sizes=... --reps=20]` | `BudgetEngine` alone: full recompute, incremental edits | not part of the runners; run by hand |
| Leak guard | `python3 tools/ci/check_private_leaks.py [--self-test]` | private art can't enter git (see PRIVATE_ASSETS.md) | self-test 56/56; tracked tree OK † |
| Export check | `python3 tools/ci/check_export_contents.py --self-test` | PCK contents scanner | OK † |
| Coverage | `python3 tools/catalog/coverage_report.py` + `git diff --exit-code docs/CATALOG_COVERAGE.md` | report is current | OK † |
| Exported build | `build/linux/HaydaySandbox.x86_64 --headless -- --selftest` | packaging of data/art/samples in an export | CI only (no Linux export templates on the Windows PC) |
| Visual | `tools/ci/visual_tests.sh all` / `tools\ci\visual_tests.ps1 all` | 39 UI scenarios (12 of them planning), real rendering | screenshots, inspected by eye |

## Running everything

### Windows (PowerShell 5.1)

Set `GODOT` (process or user environment) to the Godot 4.7.2 executable, or put `godot` on PATH. Python comes from
the repository's `.venv\Scripts\python.exe` when it exists (Pillow and numpy), else `python` on PATH.

```powershell
$env:GODOT = 'C:\path\to\Godot_v4.7.2-stable_win64.exe'
powershell -ExecutionPolicy Bypass -File tools\ci\windows_checks.ps1                 # everything above except visuals/export
powershell -ExecutionPolicy Bypass -File tools\ci\windows_checks.ps1 -Perf           # + selftest_perf (up to 30 min timeout)
powershell -ExecutionPolicy Bypass -File tools\ci\windows_checks.ps1 -SkipImport -Tag name   # logs in artifacts\checks\name\
powershell -ExecutionPolicy Bypass -File tools\ci\visual_tests.ps1 [scenarios] [WxH:scale ...]
# One headless Godot command ("--headless --path ." is added in front):
powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 --script res://tests/run_tests.gd -- --filter=budget
powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 -- --selftest
powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 --import
powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 -TimeoutSec 1800 -Log out.log --script res://tests/perf/perf_planning.gd
```

`run_godot.ps1` is the way to run any single Godot command on Windows; don't call the Godot executable directly.
Its own options `-Log <file>` (keep the log; default: a temporary file that is printed and deleted) and
`-TimeoutSec <s>` (default 900) come first; everything else goes to Godot unchanged. It runs with a throw-away
`APPDATA`, prints the log, returns Godot's exit code (124 = timeout), refuses `--import` while
`hayday-sandbox-private-assets` is inside the repository, and restores `project.godot` after an import (an import
rewrites it).

**Shared Godot lock.** `run_godot.ps1`, `windows_checks.ps1` and `visual_tests.ps1` all take the same named
mutex (`Local\HaydaySandboxGodot`, `Enter-GodotLock` in `tools\ci\windows_common.ps1`) for the whole run, so runs
started from parallel shells or agents wait for each other instead of importing and testing at the same time (an
import rewrites the `.godot` cache that every other run reads). A run waits up to an hour for the lock; a lock
left by a crashed run is taken over.

`windows_checks.ps1` runs, in order: `import` (unless `-SkipImport`; it refuses to run if
`hayday-sandbox-private-assets` is inside the repository and restores `project.godot` afterwards), `check_scripts`,
`unit_tests`, `selftest` (must print `SELFTEST PASS`), `selftest_perf` (with `-Perf`), `validate_data`,
`leak_guard_selftest`, `export_check_selftest`, `leak_guard`, `coverage_report`, `coverage_diff`. Each step's
output goes to `artifacts\checks\[tag\]<step>.log`, and a PASS/FAIL table is printed at the end (exit 1 on any
failure).

`visual_tests.ps1` takes comma-separated scenarios (default `all`) and configurations (default `1920x1080:1
2560x1440:1.25 3440x1440:1 3840x2160:2`). PNGs go to `artifacts\screens\`, logs to
`artifacts\checks\visual_<res>_<scale>.log`.

### Linux / cloud box

The commands in the table above. `tools/ci/visual_tests.sh [scenarios] [WxH:scale ...]` runs each configuration
under `xvfb-run` with `--rendering-driver opengl3`.

## Isolation rules

* **No test touches the real user folder.** The Windows runners start each Godot child with a fresh temporary
  `APPDATA` (deleted afterwards); `visual_tests.sh` gives each configuration its own temporary `XDG_DATA_HOME`. Real
  layouts, settings and installed asset packs (including a private pack) are never read or changed and can't
  appear in screenshots.
* **No visible window.** Checks run `--headless`. Visual captures need a real renderer; on Windows
  `visual_tests.ps1` writes a temporary `override.cfg` (borderless, `no_focus`, 64×64) and `capture.gd` moves the
  window to (-20000, -20000), so it opens off-screen and never takes focus. It can't be minimised instead, because a
  minimised Godot window stops drawing. Because of that `override.cfg`, run **one visual run at a time**; the script
  refuses to start if the file already exists and removes it when done.
* Godot children run with `CreateNoWindow` and a timeout (300 s per check step, 1800 s for perf, 300 s per visual
  configuration, 900 s by default for `run_godot.ps1`); a timeout is logged and reported as exit code 124.
* **One Godot run at a time** on Windows: all three runners hold the shared Godot lock (see above). The planning
  exports in the capture scenarios use placeholder art only.
* Asset-pack tests use synthetic packs built at runtime from the placeholder PNGs
  (`tests/fixtures/synthetic_pack.gd`), never real artwork.

## Unit tests (`tests/unit/`, 33 files)

Test counts per file are the `func test_*` functions at a511d0c (417 in total).

| File | Tests | Covers |
|---|---:|---|
| `test_iso` | 7 | projection, picking near diamond edges, negative tiles, screen↔world, footprint polygons |
| `test_items` | 9 | parsing, unknown-footprint flagging, flip swap, aliases, invalid records, search, round trip |
| `test_placement` | 13 | map kinds, plot geometry and adjacency, collisions with named blockers, road/water/bounds/locked land |
| `test_depth_sort` | 17 | topological order, elongated-hedge regression, randomized consistency, incremental order |
| `test_commands` | 14 | undo/redo, merging, dirty tracking, bounded history, composite order, layout refuses fixed items |
| `test_layout_io` | 22 | round trip, atomic save, recovery, missing/renamed/resized items, migrations 0→1→2→3, v1 backup, landmark extraction |
| `test_planning` | 11 | fence masks, groups, Realistic level/ownership/max/cost/budget/land/planned, layout diff |
| `test_library_and_tools` | 8 | gallery lifecycle, trash, snapshots, autosave recovery, calibration solver, importer matching, settings |
| `test_asset_packs` | 17 | overrides parsing/merging, auto-anchor, zip install safety, AssetLibrary priority, variants, review queue |
| `test_world` | 25 | map v2, landmark validation, approximate landmarks don't block, `WorldLoader` (private candidates, user overrides), catalogue corrections, out-of-scope items |
| `test_landmark_immutability` | 14 | landmarks can't be placed/moved/hidden, import and templates strip landmark items, undo after a world change, rename/reference undo, Realistic level rule for new copies |
| `test_levels` | 12 | farm level, Creative as sandbox, item and plot level rules |
| `test_conflict_index` | 7 | incremental conflicts agree with a full scan, rechecks only what an edit touches, cached analysis never stale |
| `test_camera_math` | 24 | springs, anchored zoom, inertia, rubber-band limits, fit zoom |
| `test_drag_math` | 7 | drag hysteresis, nearest-valid search order |
| `test_layout_tools` | 29 | mirror lines, symmetry, repeat, align, distribute, brushes, stamps (`.hdstamp`) |
| `test_references` | 12 | several reference images, migration from one image, 2/3-point calibration, one undo step per edit |
| `test_terrain` | 11 | procedural terrain built from the map, only without game data, deterministic, keeps off buildable land, seamless textures, owned/locked frontier, a pack world replaces it |
| `test_terrain_pack` | 15 | pack terrain (`docs/TERRAIN_PACKS.md`) with the generated synthetic pack: manifest diagnostics, theme → variant, tile variants, piece expansion, `tile_types[].art`, AssetLibrary lookup, cached rebuilds, per-element fallback, Off/Reduced/Full |
| `test_ambient` | 12 | animation sheets, Off/Reduced modes and OS default, mirror art, theme variants only when they exist |
| `test_calibration` | 12 | N-point calibration: exact 2/3-point fits, least squares, outliers and verdicts, residual units, landmark anchors, reference layer uses the same fit |
| `test_accuracy` | 12 | Farm Accuracy Report wording (public map, private world unverified until calibrated, user overrides), renderer / picking / landmark tiles share the grid |
| `test_layout_schema4` | 8 | v3 zones → areas, v4 round trip with unknown keys, newer schema refused, `.v3-backup` on first save, `SetPlanning` undo / merge, uid identity |
| `test_plan_doc` | 3 | normalize keeps unknown keys, areas / phases / primary phase, placed / baseline / step ticks |
| `test_prices` | 13 | currency formatting, catalogue cost parsing (every real cost text), layering and origin, step / schedule prices, unknown never 0, overrides, the real price file loads |
| `test_budget` | 25 | no double counting across views, owned copies follow moves, farm = sum of phases, acquired / remaining, unknown never free, progressive and scheduled prices, vouchers / event currency, not buyable, max count, allocation order, unknown ownership and baseline, planned objects, phase status, affordability, laziness, in-place edits, batching, incremental = full after random edits |
| `test_shopping` | 8 | rows, scopes, filter / sort / search, equivalence with a reference build (random edits, real catalogue), row reuse, acquisition progress and apply to inventory |
| `test_inventory_io` | 7 | CSV / JSON round trips, tolerant and headerless CSV, replace, ambiguous names, bad JSON, quoted fields |
| `test_baseline` | 4 | snapshot shape, diff by uid and item, fungible reuse, missing baseline |
| `test_guide` | 10 | stage / phase / cluster order, no baseline, move dependencies and swap cycles, landmark directions, progress and stable ids, exports, equivalence with reference implementations |
| `test_plan_scope` | 8 | scope resolution and pin, totals = engine, shared objects / overlapping areas, heat buckets, targets, area drafts, corner placement |
| `test_plan_ui_models` | 23 | view-models of Shop, Build, Guide, Accuracy and the dialogs: currencies kept apart, unknowns in texts and CSV, checklist, moved-since-placed, inventory working copy, price overrides |
| `test_plan_context` | 3 | the session owns and disposes its budget, `set_map` rebinds it, context view state and scope |
| `test_planning_extras` | 10 | object layer groups / states / never touching the layout, readiness rows (ready, blocking, Realistic-only level, fixed landmarks), area → stamp, accuracy wording |

## Integration self-test (`tests/integration/app_selftest.gd`, 404 checks at a511d0c)

Runs inside the real application (autoloads, UI, renderer, controller) and feeds synthetic mouse/keyboard events.
Areas covered: catalogue/map/art/sample integrity; v1 and v2 layout migration (frame shift, landmarks moved to the
migration record, backups, load-report dialog); templates and default farm level; fixed landmarks (no false
conflicts from approximate ones, separate selection, every edit key refused with a hint, drawn and depth-sorted with
objects, pixel-accurate picking, hiding only transient ones, theme undo); Home and camera (wheel factor, smooth
zoom, fly-to, inertia, rubber band, limits, F / Shift+F / H, bookmarks 1–9 as undo steps); picking cycle, *Objects
here*, live drag preview, hysteresis, blocker chips, snap to valid, large drags; terrain and ambient animation;
several reference images and calibration; place/paint/line, undo/redo, drag-move, lock, copy/paste, rotate, box
select, delete, land tool, Creative↔Realistic, save/reload; asset importer and packs (install, priority, variants,
Asset Manager anchors/scale/verify/review, uninstall); a synthetic pack with world data and catalogue corrections
(world swap, provenance, landmark states); symmetry, outline and line brushes, repeat, align, distribute, stamps;
`ConflictIndex` vs full scan; session handler counts across layout switches and UI rebuilds; inspector auto-hide,
catalogue rail, panel widths, name wrapping; grouped issues; help lists the real keys. Planning (`_plan_check`,
`_plan_extras_check`): the price book loads; the planning context follows the session and its budget engine; the
budget chip updates live on place / move / delete / undo / redo and when a copy is recorded as owned; the area
tool (polygon, undo / redo, Esc, from selection); J opens the Plan panel in the inspector's place and the camera
view stops at it; phase assignment; every tab opens; area and phase pictures; no doubled handlers after layout
switches and UI rebuilds; object layers (hidden objects not pickable or box-selected, selection released, layout
and save data unchanged); compare tints and counts match `Baseline.diff`, turning it off clears them; area →
stamp keeps relative positions without editing the layout; readiness is cached and updated by undo; the overview
map appears only with room, repaints only edited tiles, round-trips coordinates and moves the camera on click.

The self-test passes when other packs are installed in the data folder, but the runners isolate it anyway. Two
more modes exist for a user's installed original-art pack (private; see `docs/PRIVATE_ASSETS.md`):
`--selftest=artcheck` and `--selftest=artflow`. They need the pack, are not run in CI and were not run in this
wave.

Expected noise at exit: an error about the deliberately missing `selftest_missing.png` reference image, and
"RIDs … leaked" / "ObjectDB instances were leaked" warnings (8 RIDs and 17 instances in the 2026-11-09 run; not
re-counted at a511d0c). These predate the planning wave.

## Performance (`--selftest=perf`, Windows development PC)

From `artifacts\checks\perf\selftest_perf.log` (2026-11-09, before the planning wave; not re-run for this update). "Edit" = mean over 45 random moves, adds and undos,
including the command, its signal handlers (conflicts, Realistic analysis in Realistic mode) and the depth order.

| Farm | Objects | Open | Full depth sort | Edit, Creative | Edit, Realistic | Placement check | Pick | Save | Load | Full analysis | File |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Real map, densely packed | 1,920 | 1,372 ms | 24 ms | – | – | 39 µs | 69 µs | 22 ms | 34 ms | 25 ms | 115 KB |
| Synthetic | 2,001 | 739 ms | 13 ms | 0.29 ms | 9.9 ms | 29 µs | 43 µs | 19 ms | 39 ms | 36 ms | 122 KB |
| Synthetic | 5,001 | 512 ms | 47 ms | 0.33 ms | 22.6 ms | 49 µs | 77 µs | 52 ms | 105 ms | 67 ms | 305 KB |
| Synthetic | 10,001 | 653 ms | 98 ms | 0.36 ms | 45.8 ms | 39 µs | 83 µs | 63 ms | 203 ms | 136 ms | 612 KB |

Before `ConflictIndex` and the cached analysis (same harness, same PC): per edit at 10k objects 93.4 ms Creative
and 237 ms Realistic; at 2k 26.2 ms and 64.5 ms. A later run just before the final commit
(`artifacts\checks\merge2\`) measured 0.46 ms / 33.0 ms at 10k, so the Realistic figure varies between runs. Catalogue cold thumbnail pass: 2,701 → 1,266 ms,
images decoded 1,474 → 741 (1,967 items). World layer: scenery build ~12 ms, ground redraw + frame ~8 ms.
Canvas share at 1920×1080 with nothing selected: 48.3 % → 71.1 % after the panel changes.

Rendering frame times are not measured: headless runs have no renderer, and CI uses Mesa llvmpipe (CPU).

## Planning performance (`tests/perf/perf_planning.gd`, Windows development PC)

Windows: `powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 -TimeoutSec 1800 --script
res://tests/perf/perf_planning.gd`. Each size: N real catalogue items from 500 item types (fixed seed) on the real
map, real price file, 5 areas (2 polygons), 4 phases, a baseline (30 % in place, 5 % moved, 2 % removed), 10 %
marked placed. Mean / p95 / max over 30 repetitions (10 or 5 for the slow cases). "Before" = HEAD b256fbc, "after" =
the changes committed as a511d0c, run back to back on 2026-11-10 while the PC was busy (expect ±30 % noise; compare columns, not runs).
Outputs were checked to be identical: 485 hashed outputs (shopping rows in every mode and scope, breakdowns, totals,
area lists, allocation order, guide JSON / CSV / HTML) on three real-catalogue layouts with edits in between, plus
the equivalence unit tests in `test_shopping.gd`, `test_budget.gd` and `test_guide.gd`.

| Case (mean ms) | 2k before | 2k after | 5k before | 5k after | 10k before | 10k after |
|---|---:|---:|---:|---:|---:|---:|
| Shop tab data, whole farm, after an edit (rows + supplies + totals) | 39.4 | 4.3 | 47.0 | 6.1 | 60.0 | 9.1 |
| Shop tab data, phase, after an edit | 29.8 | 4.2 | 48.3 | 8.1 | 54.7 | 13.7 |
| `ShoppingList.build` whole farm, after an edit (batched / unbatched) | 40.3 / 105.7 | 1.7 / 1.6 | 43.0 / 158.9 | 2.3 / 1.8 | 64.5 / 247.8 | 2.3 / 2.0 |
| `ShoppingList.sort_rows` by name (500 rows) | 7.5 | 1.0 | 7.0 | 1.4 | 6.8 | 1.0 |
| Totals of a 500-object selection | 0.90 | 0.08 | 1.27 | 0.16 | 1.17 | 0.30 |
| `area_totals` rect + polygon, after a move | 9.4 | 2.0 | 23.6 | 3.9 | 56.7 | 6.1 |
| `is_placed` for every object (overlay pattern), plain / batched | 283 / 6.9 | 282 / 1.6 | 1,140 / 17.0 | 1,213 / 4.6 | 3,755 / 29.7 | 3,671 / 10.0 |
| `placed_set()` + a lookup per object | – | 0.41 | – | 0.98 | – | 1.67 |
| `RecreationGuide.build` (1,565 / 3,714 / 7,170 steps) | 282 | 181 | 711 | 459 | 1,242 | 825 |
| Edit (place / move / delete / undo / redo) + whole-farm refresh | 1.7–1.9 | 1.8–2.2 | 3.1–3.3 | 3.3–3.5 | 5.9–7.7 | 5.5–7.7 |
| Full recompute + totals | 11.4 | 12.3 | 25.8 | 27.0 | 53.0 | 49.9 |
| Phases tab (totals + status of every phase, cold) | 4.8 | 4.5 | 10.7 | 9.3 | 21.3 | 17.2 |
| Mark 1 placed (PlanDoc + SetPlanning, engine) | 4.5, 10.3 | 4.8, 10.2 | 7.9, 20.9 | 7.3, 23.3 | 13.4, 33.0 | 12.8, 28.9 |
| Build tab model (`PlanUiModels.checklist`) | 32.7 | 30.5 | 77.1 | 67.6 | 130.5 | 105.0 |
| `GuideExport.to_html` / `to_csv` / `to_json` (10k: 2.7 / 1.4 / 7.0 MB) | 25 / 17 / 101 | 24 / 16 / 101 | 55 / 38 / 269 | 64 / 36 / 222 | 105 / 81 / 446 | 120 / 87 / 487 |

What changed: `BudgetEngine` keeps per-item breakdowns (whole farm, and the exact lists `phase_uids()` /
`area_uids()` return) and rebuilds them only for the items an edit touched; caches totals of uid lists per version;
keeps area membership and updates it per edited object (polygons rasterised once, same arithmetic as
`PlanDoc.point_in_polygon`); `begin_batch()` / `end_batch()` / `batch(f)` skip the per-query hash of the planning
document; `placed_set()` for per-object loops. `ShoppingList.build` reuses rows whose item did not change (rows are
read-only) and sorts on cached natural-order name ranks. `RecreationGuide` uses summed-area tables for "across the
road" / "along the river", native sorts for cluster order, a rect test for small cluster groups and per-plot lookups
for land; `options.primary` takes precomputed primary phases. Unchanged: the full recompute, single-edit refresh and
the phases tab are dominated by one pass over every object (`_sum`, `_derive`); `PlanDoc.objects_in_area`,
`Baseline.diff` and the guide exports are outside this change. `Baseline.diff` is not in this benchmark; it was
measured at about 70 ms at 10k objects during this wave (a one-off measurement, no log kept). The compare view
recomputes it once per edit (`PlanContext.compare_diff()`).

## Visual tests (`tests/visual/capture.gd`)

The app is launched normally with `--rendering-driver opengl3` and `-- --capture`; a driver node stages each
scenario and saves the real framebuffer. Scenarios in `all`: overview, place_valid, place_invalid, selection,
search, realistic, land, zoomed, gallery, help, settings, welcome, reference, compare, export, light,
asset_manager, asset_review, asset_packs, original_art, asset_empty, landmarks, migration, drag_blocked,
tools_symmetry, tools_repeat, winter, terrain_pack, terrain_pack_winter, terrain_pack_river (a generated
terrain pack: flat colours and patterns; they print `TERRAIN_PACK` build and frame times), and the planning scenarios:

| Scenario | Shows |
|---|---|
| `plan_budget` | budget chip expanded with a selection scope, and the Budget tab |
| `plan_areas` | Areas tab with an active area |
| `plan_phases` | Phases tab with an active, highlighted phase; also writes a phase picture with guide numbers (`export_plan_phase_1.png`, placeholder art) |
| `plan_heatmap` | cost heatmap on the farm (areas layer off) with the Budget tab legend |
| `plan_shop` | Shop tab |
| `plan_build` | Build tab |
| `plan_guide` | Guide tab |
| `plan_accuracy` | Accuracy tab |
| `plan_minimap` | overview map while zoomed in, with the active phase in its colour (log line `MINIMAP shown=… room=…`) |
| `plan_layers` | decorations hidden and trees dimmed, View tab open (log line `LAYERS hidden=…`) |
| `plan_compare` | Compare with my farm after a few edits against the baseline, legend, Build tab (log line `COMPARE {…}`) |
| `plan_ready` | "Can I build this?" card with blocking issues (log line `READY blocking=… checks=… rows=…`) |

The overview map needs a free canvas of at least 700×420 logical px, so `plan_minimap` shows no map at
1920×1080 @200 % by design. The asset scenarios install the synthetic placeholder-derived pack and remove
it again. Extra scenarios (`export2x`, `export_objects`, `at_<x>_<y>_<zoom>`, `anim_perf`) are only for a real
pack or an opened layout. Default configurations: 1920×1080 @100 %, 2560×1440 @125 %, 3440×1440 @100 %
(ultrawide), 3840×2160 @200 %.

Screenshots are inspected by eye for clipping, overlap, anchoring, depth order, scaling and readability. A
selection is committed in `docs/screenshots/`; CI uploads the full set as an artifact after a leak-guard check of
`artifacts/screens/`.

## Windows verification checklist (manual)
1. Unzip `HaydaySandbox-windows-x86_64.zip`, run `HaydaySandbox.exe` (SmartScreen may warn: unsigned build).
2. First run: welcome dialog, sample "Meadow showcase" farm, catalogue thumbnails load.
3. Place a bakery, drag it, Ctrl+Z/Ctrl+Shift+Z, Ctrl+S → toast "Saved"; reopen the app → same layout loads.
4. Settings → Interface size 150 %/200 % and Windows display scaling 150 %: text/icons crisp, no clipping.
5. Export image… → native save dialog → PNG opens in Photos.
6. View tab → Import screenshot… → calibrate 3 points.
7. Settings → Open data folder → `%APPDATA%\HaydaySandbox` contains `layouts/`, `history/`, `settings.cfg`.
8. Check the .exe icon and Properties → Details (product name "Hayday Sandbox", version 0.1.0.0).
9. Press J: the Plan panel opens; Guide › Export guide… › Printable page (HTML) saves to Documents and opens in a
   browser; Shift+M shows the overview map.
10. `HaydaySandbox.exe --headless -- --selftest` is **not** available in the Windows build (tests are excluded from
   Windows exports); use a debug export with tests included if needed.
