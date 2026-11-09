# Development

## Requirements
* Godot **4.7.2** (standard build, not .NET). Other 4.7.x should work; 4.4+ is required for `match` guards and `.uid` files.
* Python 3.11+ with Pillow and NumPy (only for regenerating data/art; not needed to run the app).
* For screenshots in Linux CI/cloud: Xvfb + Mesa (`xvfb-run`), run Godot with `--rendering-driver opengl3`.

## Run
```bash
godot --path .                    # app
godot --path . -- --open=path/to/farm.hdlayout
godot -e --path .                 # editor
```
First checkout: run `godot --headless --path . --import` once (imports PNGs, registers `class_name` scripts).

## Project layout
See [ARCHITECTURE.md](ARCHITECTURE.md). UI is built in code (`src/ui/*`), theme in `src/ui/ui_theme.gd`.

## Windows build (portable)
```bash
tools/build/build.sh            # release; `debug` for a debug build
```
* Downloads export templates for the installed Godot version if missing (`~/.local/share/godot/export_templates/4.7.2.stable`).
* Exports `build/windows/HaydaySandbox.exe` (PCK embedded, single file, ~125 MB), copies licences, zips
  `build/HaydaySandbox-windows-x86_64.zip` (~50 MB).
* Also exports `build/linux/HaydaySandbox.x86_64` from the same data and runs `--selftest` against it — this
  proves the exported pack contains the catalogue, maps, samples and art (the Windows build uses identical filters).
* Preset: `export_presets.cfg` → "Windows Desktop" (x86_64, embed PCK, icon `assets/ui/app_icon.ico`,
  `application/modify_resources=true`). Excludes tests/tools/docs/research and `assets/original/`.
* Building on Windows: open the project in Godot 4.7.2 → Editor → Manage Export Templates → Download, then
  Project → Export → Windows Desktop → Export Project.

User data: Windows `%APPDATA%\HaydaySandbox\` (`layouts/`, `history/`, `autosave/`, `trash/`, `asset_packs/`,
`references/`, `settings.cfg`); Linux `~/.local/share/HaydaySandbox/`. Settings → *Open data folder*.

No installer yet (portable zip is the primary format). No telemetry, no network access at runtime.

## Regenerating data
| What | Command |
|---|---|
| Item manifests | `python3 tools/catalog/build_catalog.py` |
| Farm maps | `python3 tools/catalog/build_map.py` |
| Placeholder art (incremental) | `python3 tools/art_generator/generate.py [--force] [--sheet out.png]` |
| Sample layouts | `godot --headless --path . --script res://tools/samples/generate_samples.gd` |
| Coverage report | `python3 tools/catalog/coverage_report.py` |
| UI font/icons (rarely) | `python3 tools/ui/fetch_ui_assets.py` |
After art changes: `godot --headless --path . --import`.

## Gotchas
* New `class_name` scripts need `--import` (or opening the editor) before `--script` runs can see them.
* Scripts referencing the `App` autoload don't compile in `--script` mode; test them with `-- --selftest`.
* Lambdas can't end with `)` right after a `match` branch — move the body into a method.
* After `add_child`, use `set_anchors_and_offsets_preset` (plain `set_anchors_preset` keeps the old size).
