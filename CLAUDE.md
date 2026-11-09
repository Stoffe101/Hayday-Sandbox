# CLAUDE.md

Read **AGENTS.md** first — it contains the project rules, commands and conventions. Key points:

* Godot 4.7.2 project (`godot --path .`). Core logic in `src/core/` (pure, unit-tested); UI in `src/ui/`;
  composition in `src/app/main.gd`; autoload `App` in `src/app/app.gd`.
* Before claiming success run: `godot --headless --path . --import`, `--script res://tools/ci/check_scripts.gd`,
  `--script res://tests/run_tests.gd`, `-- --selftest`, and `python3 tools/ci/validate_data.py`. For visual
  changes run `tools/ci/visual_tests.sh <scenarios> 1920x1080:1` and *look at* the PNGs in `artifacts/screens/`.
* Never commit game artwork or files into `assets/original/`. Never invent item facts; mark unknowns.
* Every edit to a layout must be an undoable Command.
* The cloud dev box has Xvfb + Mesa llvmpipe: real screenshots work with `--rendering-driver opengl3` (not
  `--headless`). Windows `.exe` builds can be produced but not executed here (no Wine) — say so.
