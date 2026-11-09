# Testing

All layers run locally (Windows or Linux) and in CI (`.github/workflows/ci.yml`). Counts below are from
`tools\ci\windows_checks.ps1 -SkipImport -Tag docs` on the Windows development PC on 2026-11-09 at HEAD 8c93360
(Godot 4.7.2); logs in `artifacts\checks\docs\`.

| Layer | Command (Linux form) | What it covers | Result |
|---|---|---|---|
| Static | `godot --headless --path . --script res://tools/ci/check_scripts.gd` | every `.gd` compiles | 92 scripts, 0 failed |
| Data | `python3 tools/ci/validate_data.py` | manifests, maps, asset pack refs, samples, **licence guard** | 1,967 items, 0 errors, 0 warnings |
| Unit | `godot --headless --path . --script res://tests/run_tests.gd [-- --filter=x --junit=out.xml]` | core logic, art-free fixtures | 266 tests / 11,239 assertions, 0 failed |
| Integration | `godot --headless --path . -- --selftest` | the real app driven by synthetic input | 329 checks, 0 failed |
| Performance | `godot --headless --path . -- --selftest=perf` | synthetic farms 2k/5k/10k, densely packed real map, world layer, thumbnails | 7 checks, 0 failed (numbers below) |
| Leak guard | `python3 tools/ci/check_private_leaks.py [--self-test]` | private art can't enter git (see PRIVATE_ASSETS.md) | self-test 56/56; tracked tree OK |
| Export check | `python3 tools/ci/check_export_contents.py --self-test` | PCK contents scanner | OK |
| Coverage | `python3 tools/catalog/coverage_report.py` + `git diff --exit-code docs/CATALOG_COVERAGE.md` | report is current | OK |
| Exported build | `build/linux/HaydaySandbox.x86_64 --headless -- --selftest` | packaging of data/art/samples in an export | CI only (no Linux export templates on the Windows PC) |
| Visual | `tools/ci/visual_tests.sh all` / `tools\ci\visual_tests.ps1 all` | 27 UI scenarios, real rendering | screenshots, inspected by eye |

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
```

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
  configuration); a timeout is logged and reported as exit code 124.
* Asset-pack tests use synthetic packs built at runtime from the placeholder PNGs
  (`tests/fixtures/synthetic_pack.gd`), never real artwork.

## Unit tests (`tests/unit/`, 19 files)

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
| `test_references` | 11 | several reference images, migration from one image, 2/3-point calibration, one undo step per edit |
| `test_terrain` | 7 | procedural terrain built from the map, only without game data, deterministic, keeps off buildable land |
| `test_ambient` | 12 | animation sheets, Off/Reduced modes and OS default, mirror art, theme variants only when they exist |

## Integration self-test (`tests/integration/app_selftest.gd`, 329 checks)

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
catalogue rail, panel widths, name wrapping; grouped issues; help lists the real keys.

The self-test passes when other packs are installed in the data folder, but the runners isolate it anyway. Two
more modes exist for a user's installed original-art pack (private; see `docs/PRIVATE_ASSETS.md`):
`--selftest=artcheck` and `--selftest=artflow`. They need the pack, are not run in CI and were not run in this
wave.

Expected noise at exit: an error about the deliberately missing `selftest_missing.png` reference image, and
"RIDs … leaked" / "ObjectDB instances were leaked" warnings (8 RIDs and 17 instances in this run). These predate
this wave.

## Performance (`--selftest=perf`, Windows development PC)

From `artifacts\checks\perf\selftest_perf.log` (2026-11-09). "Edit" = mean over 45 random moves, adds and undos,
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

## Visual tests (`tests/visual/capture.gd`)

The app is launched normally with `--rendering-driver opengl3` and `-- --capture`; a driver node stages each
scenario and saves the real framebuffer. Scenarios in `all`: overview, place_valid, place_invalid, selection,
search, realistic, land, zoomed, gallery, help, settings, welcome, reference, compare, export, light,
asset_manager, asset_review, asset_packs, original_art, asset_empty, landmarks, migration, drag_blocked,
tools_symmetry, tools_repeat, winter. The asset scenarios install the synthetic placeholder-derived pack and remove
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
9. `HaydaySandbox.exe --headless -- --selftest` is **not** available in the Windows build (tests are excluded from
   Windows exports); use a debug export with tests included if needed.
