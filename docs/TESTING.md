# Testing

Four layers, all runnable locally and in CI (`.github/workflows/ci.yml`). All results below were produced in the
Linux cloud dev environment on 2026-11-09 with Godot 4.7.2 (llvmpipe software OpenGL for visuals).

| Layer | Command | What it covers | Result |
|---|---|---|---|
| Static | `godot --headless --path . --script res://tools/ci/check_scripts.gd` | every `.gd` compiles | 59/59 ✅ |
| Data | `python3 tools/ci/validate_data.py` | manifests, maps, asset pack refs, samples (no overlaps), **licence guard** | 1,967 items, 0 errors ✅ |
| Unit | `godot --headless --path . --script res://tests/run_tests.gd [-- --filter=x --junit=out.xml]` | core logic, art-free fixtures | 86 tests / 511 assertions ✅ |
| Integration | `godot --headless --path . -- --selftest` | the real app driven by synthetic input | 88 checks ✅ |
| Exported build | `build/linux/HaydaySandbox.x86_64 --headless -- --selftest` | packaging of data/art/samples in an export | 52 checks ✅ |
| Performance | `godot --headless --path . -- --selftest=perf` | synthetic farms 2k/5k/10k + densely packed real farm | ✅ (numbers below) |
| Visual | `tools/ci/visual_tests.sh all` | 16 UI states × 4 resolutions/scales, real rendering under Xvfb | 64 screenshots ✅ (inspected) |

## Unit tests (`tests/unit/`)
`test_iso` (projection, picking near diamond edges, negative tiles, screen↔world at several zooms, footprint
polygons, line/rect helpers) · `test_items` (parsing, unknown-footprint flagging, flip swap, aliases, invalid
records, search relevance + filters, duplicates, round-trip) · `test_placement` (map kinds, plot geometry &
adjacency, collisions with named blockers, road/water/out-of-bounds/locked land, per-tile codes, flipped
footprints, group moves, stamps, conflicts after land changes, unlockable plots) · `test_depth_sort` (incl. the
elongated-hedge regression and a 200-object randomized pairwise-consistency + determinism check) ·
`test_commands` (undo/redo with stable uids, full restore on delete, bulk move as one step, nudge merging, flip
undo, land, dirty tracking across save points, bounded history, composite order) · `test_layout_io` (round trip,
atomic save + .bak, recovery from a truncated file, missing items preserved with unknown fields, renamed and
resized items, newer/foreign files rejected, v0→v1 migration, malformed records, duplicate uids) ·
`test_planning` (fence masks, groups, degradation rules, realistic level/ownership/max/cost/budget/land/planned,
default ownership, layout diff) · `test_library_and_tools` (gallery lifecycle, trash, snapshots, autosave
recovery, affine calibration solver, importer name matching, settings type safety) · `test_asset_packs`
(overrides parsing/normalising/merging/pruning, auto-anchor maths, path safety, zip install: folder-deep pack.json,
zip-slip, atomic replace, overrides kept on update, interrupted-swap restore, bad zips; AssetLibrary: priority,
version/provenance, thumbnails without full-texture loads, variants/default variant, overrides save/reload,
reject → fallback, review queue + assign, missing files, pack stats).

## Integration self-test (`tests/integration/app_selftest.gd`)
Runs inside the real application (autoloads, UI, renderer, controller) and feeds synthetic mouse/keyboard
events: catalogue/map/art/sample integrity; click-to-place lands exactly on the previewed tiles; occupied tiles
reject; Ctrl+Z/Ctrl+Shift+Z; Shift-drag fence line = one undo step and auto-connects; Esc; drag-move = one step,
frees old tiles; drop onto the farmhouse is rejected; locked objects survive Delete; L toggles lock; Ctrl+C / Ctrl+V
stamp; R mirrors and swaps the footprint; box select; Delete + undo; Land tool unlock + undo; Creative↔Realistic
leaves objects byte-identical; unknown items render as fallbacks; save → reload matches every object; unknown
item preserved; revision snapshot written; asset importer (match, duplicate, unmatched, trimming, pack.json);
asset packs: a synthetic pack zip built at runtime from the placeholder PNGs (`tests/fixtures/synthetic_pack.gd`,
no real artwork) is installed, wins over placeholders, thumbnails don't load full textures, missing files are
detected, the inspector variant picker is one undoable command (Ctrl+Z / Ctrl+Shift+Z), Ctrl+Shift+A opens the Asset
Manager, nudged and mouse-dragged anchors / verified / wrong match / category scale / review assignment persist in overrides.json,
survive reload and a pack update, uninstall restores the previous art. The checks are written so they also pass
when other packs are installed in the data folder.

Two more self-test modes exist for a user's installed original-art pack (private; see `docs/PRIVATE_ASSETS.md`):
`--selftest=artcheck` (every catalogue item resolves to the pack and its texture loads; memory) and
`--selftest=artflow` (editing workflows with that art, with timings). They need the pack and are not run in CI.

## Performance (`--selftest=perf`, headless, this container: 4 vCPU)

| Farm | Objects | Open | Full depth sort | Edit + re-sort | Placement check | Pick | Save | Load | Realistic analysis | File |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Real map, all land, densely packed | 1,915 | 514 ms | 58 ms | – | 30 µs | 117 µs | 11 ms | 30 ms | 23 ms | 115 KB |
| Synthetic 160×160 | 2,001 | 359 ms | 30 ms | 46 ms | 22 µs | 59 µs | 12 ms | 32 ms | 27 ms | 121 KB |
| Synthetic 160×160 | 5,001 | 420 ms | 102 ms | 138 ms | 29 µs | 82 µs | 31 ms | 84 ms | 68 ms | 306 KB |
| Synthetic 160×160 | 10,001 | 783 ms | 267 ms | 398 ms | 36 µs | 149 µs | 71 ms | 188 ms | 128 ms | 612 KB |

App services boot (catalogue + maps + asset index) in ~120 ms. Static memory ≈ 210–350 MB (includes the editor
UI and thumbnails). Rendering frame times were not measured meaningfully: the only renderer available is Mesa
llvmpipe (CPU), which is not representative of any GPU. The renderer design (one culled RenderingServer item per
object, no per-frame script work while panning) is expected to be GPU-bound and light; verify on Windows.

## Visual tests (`tests/visual/capture.gd` via `tools/ci/visual_tests.sh`)
The app is launched normally under Xvfb with `--rendering-driver opengl3` and `-- --capture`; a driver node
stages each scenario and saves the real framebuffer. Scenarios: overview, place_valid, place_invalid, selection,
search, realistic, land, zoomed, gallery, help, settings, welcome, reference, compare, export (also writes a
full-farm export PNG), light theme, asset_manager / asset_review / asset_packs (Asset Manager tabs) and
original_art (variant on the farm) — the asset scenarios install the synthetic placeholder-derived pack and remove
it again. Each configuration runs with its own temporary `XDG_DATA_HOME`, so the real data folder (layouts,
private asset packs) is never touched and never appears in screenshots. Configurations: 1920×1080 @100 %, 2560×1440 @125 %, 3440×1440 @100 %
(ultrawide), 3840×2160 @200 %.

Screenshots were inspected manually for clipping, overlap, anchoring, depth order, scaling and readability. Bugs
found and fixed this way: modals anchored to the top-left (anchors set after `add_child`), a wrapped label
collapsing to one character per line, fence thumbnails showing a lone post, oversized LineEdit icons at 200 %,
Realistic Mode tinting everything red with an empty inventory, scenario state leaking between captures.
A selection is committed in `docs/screenshots/`. CI uploads the full set as an artifact.

## Windows verification checklist (manual — not possible in the cloud)
1. Unzip `HaydaySandbox-windows-x86_64.zip`, run `HaydaySandbox.exe` (SmartScreen may warn: unsigned build).
2. First run: welcome dialog, sample "Meadow showcase" farm, catalogue thumbnails load.
3. Place a bakery, drag it, Ctrl+Z/Ctrl+Shift+Z, Ctrl+S → toast "Saved"; reopen the app → same layout loads.
4. Settings → Interface size 150 %/200 % and Windows display scaling 150 %: text/icons crisp, no clipping.
5. Export image… → native save dialog → PNG opens in Photos.
6. View tab → Import screenshot… → calibrate 3 points.
7. Settings → Open data folder → `%APPDATA%\HaydaySandbox` contains `layouts/`, `history/`, `settings.cfg`.
8. Check the .exe icon and Properties → Details (product name "Hayday Sandbox", version 0.1.0.0).
9. Optional: `HaydaySandbox.exe --headless -- --selftest` is **not** available in the Windows build (tests are
   excluded from Windows exports); use a debug export with tests included if needed.
