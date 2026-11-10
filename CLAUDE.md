# CLAUDE.md

Read **AGENTS.md** first — it contains the project rules, commands and conventions. Key points:

* Godot 4.7.2 project (`godot --path .`). Core logic in `src/core/` (pure, unit-tested); UI in `src/ui/`;
  composition in `src/app/main.gd`; autoload `App` in `src/app/app.gd`.
* Before claiming success run: `godot --headless --path . --import`, `--script res://tools/ci/check_scripts.gd`,
  `--script res://tests/run_tests.gd`, `-- --selftest`, and `python3 tools/ci/validate_data.py`. For visual
  changes run `tools/ci/visual_tests.sh <scenarios> 1920x1080:1` and *look at* the PNGs in `artifacts/screens/`.
* Never commit game artwork or files into `assets/original/`. Never invent item facts; mark unknowns.
* Every edit to a layout must be an undoable Command (planning data: `SetPlanning`; inventory: `SetProfile`).
* Planning (docs/PLANNING.md): pure logic in `src/core/planning/`, UI in `src/ui/plan/` through `PlanContext`
  (`App.plan_ctx`); the `BudgetEngine` belongs to the `EditorSession`. Unknown prices are `null`, never 0.
* The cloud dev box has Xvfb + Mesa llvmpipe: real screenshots work with `--rendering-driver opengl3` (not
  `--headless`). Windows `.exe` builds can be produced but not executed here (no Wine) — say so.

## Local Windows dev

* `GODOT` (process or user environment variable) points at the Godot 4.7.2 executable
  (`Godot_v4.7.2-stable_win64.exe`); the runners fall back to `godot` on PATH.
* Single Godot commands: `powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 <godot args>` (adds
  `--headless --path .`; e.g. `--script res://tests/run_tests.gd -- --filter=budget`, `-- --selftest`, `--import`).
  Use it instead of calling Godot directly.
* Checks: `powershell -ExecutionPolicy Bypass -File tools\ci\windows_checks.ps1 [-Perf] [-SkipImport] [-Tag name]`
  (logs in `artifacts\checks\[name\]`). Screenshots: `tools\ci\visual_tests.ps1 [scenarios] [WxH:scale ...]`
  (PNGs in `artifacts\screens\`; look at them).
* All runners give each Godot child a fresh temporary `APPDATA`, so the real `%APPDATA%\HaydaySandbox` (layouts,
  settings, installed packs) is never read or written and private art can't reach a screenshot. They share one
  Godot lock, so parallel runs wait instead of overlapping.
* Captures open off-screen and never take focus. Run only one visual run at a time (it writes a temporary
  `override.cfg` and refuses to start if one exists).
* **Never launch a visible Godot window while the user is working** (no `godot --path .` without `--headless`,
  no editor). Use the headless checks and the off-screen capture runner.
* Python: a repository `.venv\` with Pillow and numpy; the runners use `.venv\Scripts\python.exe` when it exists.
* Git hooks: run `tools/ci/install_git_hooks.sh` once in Git Bash.
* PowerShell 5.1 quoting mangles quotes in `git commit -m`; write the message to a file and use
  `git commit -F <file>`.
