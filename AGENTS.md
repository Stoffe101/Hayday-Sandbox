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

## Commands
```bash
godot --headless --path . --import                                   # after adding class_name scripts / assets
godot --headless --path . --script res://tools/ci/check_scripts.gd   # compile every script
godot --headless --path . --script res://tests/run_tests.gd          # unit tests (69)
godot --headless --path . -- --selftest                              # in-app integration test (52 checks)
godot --headless --path . -- --selftest=perf                         # benchmarks
tools/ci/visual_tests.sh all [1920x1080:1 ...]                       # Xvfb screenshots → artifacts/screens
python3 tools/ci/validate_data.py                                    # data + licence guard
godot --path .                                                       # run the app
tools/build/build.sh                                                 # Windows portable build (+ verified Linux export)
```
Data regeneration: `python3 tools/catalog/build_catalog.py` (items), `python3 tools/catalog/build_map.py` (maps),
`python3 tools/art_generator/generate.py` (placeholder art, incremental), `godot --headless --path . --script
res://tools/samples/generate_samples.gd` (sample layouts), `python3 tools/catalog/coverage_report.py`.

## Conventions
* Typed GDScript, tabs, `class_name` for reusable classes. UI is built in code (no .tscn except main).
* Item ids: lowercase snake_case slugs, stable forever. Categories in `data/items/categories.json`.
* New UI: use `UI.*` helpers and `UiTheme.c("token")` colours; icons from `assets/ui/icons.json` (Lucide).
* Scripts referencing the `App` autoload cannot be compiled in `--script` mode — test them via `--selftest`.
* Lambdas: don't end a lambda with `)` right after a `match` branch (parser limitation) — use a method.
* `set_anchors_preset` after `add_child` keeps the old size — use `set_anchors_and_offsets_preset`.

## Where things are
See `docs/ARCHITECTURE.md` (module map, state ownership), `docs/ASSET_PIPELINE.md`, `docs/ITEM_DATABASE.md`,
`docs/TESTING.md`, `docs/KNOWN_ISSUES.md`, `docs/ROADMAP.md`.

## Priorities (next)
See `docs/ROADMAP.md`. Top: verify uncertain geometry in-game (starting land 32×32 vs 48×32, across-road plots),
incremental depth sorting, in-app sprite anchor editor for imported art, more item-specific placeholder art.
