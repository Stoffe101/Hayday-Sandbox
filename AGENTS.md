# AGENTS.md — guide for AI coding agents (and humans)

## Vision
Hayday Sandbox is an offline Windows-first **Hay Day farm layout designer** (unofficial fan tool). Creative Mode =
unlimited design; Realistic Mode = non-destructive "can I build this?" checks. Accuracy matters: users rebuild
these layouts in the real game, so **never invent facts** — unknown data stays visibly unknown.

## Hard rules
1. **No proprietary art in git, ever.** Only original/generated art (`assets/placeholders/`, `assets/ui/`) and
   screenshots of this app (`docs/screenshots/`) may be committed. `assets/original/` is git-ignored and local.
   `tools/ci/validate_data.py` enforces this (CI fails otherwise). Read `docs/research/LEGAL_AND_LICENSING.md`.
2. **Don't fabricate item facts.** Unknown footprints → `"footprint": null` + `provisional_footprint` in
   `data/research/item_overrides.json`; unknown prices stay null. Cite sources.
3. **All layout mutation goes through Commands** (`src/core/commands/`). One user gesture = one undo step.
4. **Placement validity = footprints + map data only**, never sprite pixels.
5. **Keep `src/core/` free of scene/UI/`App` dependencies** so it stays unit-testable in `--script` mode.
6. Don't break saved layouts: bump `LayoutIO.SCHEMA_VERSION` + add a migration for format changes; add `aliases`
   when renaming item ids.
7. **Private original art never enters git.** The user's private Hay Day art lives only in
   `/root/hayday-sandbox-private-assets` (Windows: `%USERPROFILE%\hayday-sandbox-private-assets`) and
   `user://asset_packs/hayday_original`. This covers raw files, indexes, packs, zips and screenshots that show it.
   Run `tools/ci/install_git_hooks.sh` once per clone (pre-commit/pre-push leak guard). Never bypass it for art.
   `python3 tools/ci/check_private_leaks.py` must pass. See `docs/PRIVATE_ASSETS.md`.

## Commands
Linux / cloud box (counts at the end of W5, 2026-11-10; refreshed at the end of each wave):
```bash
godot --headless --path . --import                                   # after adding class_name scripts / assets
godot --headless --path . --script res://tools/ci/check_scripts.gd   # compile every script (178)
godot --headless --path . --script res://tests/run_tests.gd          # unit tests (543 tests / 16,403 assertions)
godot --headless --path . -- --selftest                              # in-app integration test (597 checks)
godot --headless --path . -- --selftest=perf                         # benchmarks (7 checks)
godot --headless --path . --script res://tests/perf/perf_planning.gd # planning benchmarks (2k/5k/10k)
godot --headless --path . --script res://tools/ci/check_terrain_pack.gd [-- <terrain.json>] # terrain pack check
godot --headless --path . -- --selftest=packcycle [--pack=<id>]      # UNINSTALLS a pack and checks the revert:
#   only on a copied data dir (XDG_DATA_HOME) holding a full copy of the pack; see docs/TESTING.md "Private pack"
godot --path . -- --install-pack=<zip> [--quit-after-install]        # install an asset pack into user://asset_packs
tools/ci/visual_tests.sh all [1920x1080:1 ...]                       # Xvfb screenshots → artifacts/screens (isolated data dir)
python3 tools/ci/validate_data.py                                    # data + licence guard (1,967 items)
python3 tools/ci/check_private_leaks.py [--staged|--include-untracked] # private-art leak guard (+ --self-test)
tools/ci/install_git_hooks.sh                                        # once per clone: pre-commit/pre-push guard
godot --path .                                                       # run the app
tools/build/build.sh                                                 # Windows portable build (+ verified Linux export)
```
Windows (PowerShell 5.1; set `$env:GODOT` to the Godot 4.7.2 exe or put `godot` on PATH):
```powershell
powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 [-Log f] [-TimeoutSec s] <godot args>
#   ONE headless Godot command ("--headless --path ." added), e.g. --script res://tests/run_tests.gd -- --filter=budget,
#   -- --selftest, --import (restores project.godot afterwards). Use this instead of calling Godot directly.
powershell -ExecutionPolicy Bypass -File tools\ci\windows_checks.ps1 [-Perf] [-SkipImport] [-Tag name]
#   import, check_scripts, unit_tests, selftest, terrain_pack_check[, selftest_perf], validate_data, leak guard
#   (+ self-test; tracked + untracked), export-check self-test, coverage report + diff. Logs: artifacts\checks\[name\]<step>.log
powershell -ExecutionPolicy Bypass -File tools\ci\visual_tests.ps1 [scenarios] [WxH:scale ...]
#   real OpenGL screenshots → artifacts\screens\ (one run at a time: it writes a temporary override.cfg)
```
All three Windows runners start every Godot child with a fresh temporary `APPDATA` (real user data and installed
packs are never touched), headless for checks and off-screen without focus for captures, and hold one shared Godot
lock (a named mutex), so parallel shells or agents wait for each other instead of importing and testing at once. Python comes from `.venv\` in
the repository when present, else `python` on PATH. See `docs/TESTING.md`.
Data regeneration: `python3 tools/catalog/build_catalog.py` (items), `python3 tools/catalog/build_map.py` (maps),
`python3 tools/catalog/build_prices.py [--report]` (prices),
`python3 tools/art_generator/generate.py` (placeholder art, incremental), `godot --headless --path . --script
res://tools/samples/generate_samples.gd` (sample layouts), `python3 tools/catalog/coverage_report.py`.

## Conventions
* Typed GDScript, tabs, `class_name` for reusable classes. UI is built in code (no .tscn except main).
* Item ids: lowercase snake_case slugs, stable forever. Categories in `data/items/categories.json`.
* New UI: use `UI.*` helpers and `UiTheme.c("token")` colours; icons from `assets/ui/icons.json` (Lucide).
* Scripts referencing the `App` autoload cannot be compiled in `--script` mode — test them via `--selftest`.
* Lambdas: don't end a lambda with `)` right after a `match` branch (parser limitation) — use a method.
* `set_anchors_preset` after `add_child` keeps the old size — use `set_anchors_and_offsets_preset`.
* Fixed landmarks (`src/core/landmark.gd`) are world data, never `PlacedObject`s; catalogue items that duplicate
  one are refused by `FarmLayout.add_objects`. Only landmarks whose confidence is not `approximate` block placement.
* The layout name, reference images and camera bookmarks are edited through commands too (`SetMeta`,
  `SetReference`, `SetCameraBookmark`); world look (theme, landmark state/skin/visibility) through
  `SetWorldStateCommand`.
* Tests must not touch the real user folder: the Windows runners and `visual_tests.sh` isolate it; never launch a
  visible Godot window on the user's machine (headless checks, off-screen captures).
* **Planning** (`docs/PLANNING.md`): pure logic in `src/core/planning/` (PlanDoc, Currency, PriceBook,
  BudgetEngine, ShoppingList, InventoryIO, Baseline, RecreationGuide, GuideExport, AccuracyReport, Readiness);
  UI in `src/ui/plan/` (PlanContext = `App.plan_ctx`, PlanTab, PlanPanel, tabs; PlanScope / PlanUiModels are pure
  and unit-tested), plus `budget_widget.gd`, `minimap.gd`, the planning dialogs, `src/render/plan_overlay.gd` and
  `src/editor/plan_controller.gd`. The `BudgetEngine` belongs to the `EditorSession` (`session.budget`); prices are
  `App.prices`. Planning data changes only through `EditCommands.SetPlanning` (inventory: `SetProfile`); tabs act
  through `PlanContext`, never on main.gd or the layout directly.
* **Prices and unknowns**: an unknown price is `null`, never 0; currencies are never converted; "can't be bought"
  is counted apart from "price unknown"; items without an inventory record are unknown ownership. User price
  overrides live in `user://price_overrides.json`, never in the repository.
* Exports with installed (private) art: placeholder art is the default; never write such pictures inside the
  repository.

## Where things are
See `docs/ARCHITECTURE.md` (module map, state ownership), `docs/PLANNING.md` (planning data, rules, exports),
`docs/research/PRICING_RESEARCH.md`, `docs/ASSET_PIPELINE.md`, `docs/ITEM_DATABASE.md`, `docs/TESTING.md`,
`docs/KNOWN_ISSUES.md`, `docs/ROADMAP.md`.

## Priorities (next)
See `docs/ROADMAP.md` (main farm only; no separate-region editors). Open problems are in `docs/KNOWN_ISSUES.md`.
Asset packs: see the Asset Manager (`src/ui/asset_manager.gd`) and `PackOverrides` / `PackInstaller` in
`src/assets/`; world data from a pack is chosen by `WorldLoader` (`src/core/world_loader.gd`).
