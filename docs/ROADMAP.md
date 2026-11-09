# Roadmap

Done in milestone 1 (this branch): research + legal policy, data model, full catalogue from research, map with 52
plots, original art pipeline, complete editor (place/paint/line/fill/select/move/copy/group/lock/rotate/erase/
eyedropper/notes), undo/redo, Realistic Mode, layouts (gallery, templates, autosave, recovery, revisions,
import/export), screenshot reference + calibration, comparison, PNG export, art importer, themes/scaling, unit +
in-app + visual + performance tests, CI, Windows build.

## Next (highest value)
1. **Verify geometry in-game** and update `data/research` → maps: starting land 32×32 vs 48×32; real plot shapes;
   map the 13 upper plots and across-road sections (the screenshot calibration tool can be used to trace them).
2. **Verify the Windows build** on real hardware (checklist in TESTING.md); fix any DPI/IME/dialog issues.
3. **Incremental depth sorting** (only re-sort objects overlapping changed rects) for instant edits on 10k farms.
4. **Imported-art workflow:** in-app anchor/scale/shadow editor with live preview over the footprint; per-pack
   enable/disable and priority in Settings.
5. **More dedicated placeholder art:** recipes for the most common "monument" fallbacks (statues by animal,
   seasonal props), production-building silhouettes beyond plaques; variants (seasonal skins).

## Later
* Minimap / overview navigator for large farms; bookmarks of camera views.
* Reusable "stamps" library (save a selection as a named group, place it in any layout).
* Symmetry/mirror painting, alignment guides and distance measurement tool.
* Layout diff side-by-side view and printable shopping list (missing items with known costs).
* Layer visibility per category (hide decorations, show only production, etc.).
* Variant/season picker; seasonal re-skin of a whole layout.
* Installer (Inno Setup) and auto-update check (opt-in, offline by default).
* Optional computer-vision assist for screenshot import (detect grid and large buildings; always user-confirmed).
* Localisation (strings are centralised in UI code; extract to translation tables).
