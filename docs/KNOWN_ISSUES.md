# Known issues and limitations

## Accuracy / data
* **Starting land size is unresolved** (32×32 favoured vs 48×32). Both maps ship (Settings → Farm geometry); a
  layout remembers its map. One in-game count of path tiles along an edge would settle it.
* **Main-section plot shapes are approximations** reconstructed from the wiki's expansion image (subsection widths
  16/8/15/14 measured vs 17/8/15/13 in wiki text). Plot costs are from wiki tables (community).
* **Upper plots (13) and all across-the-road sections (114 plots) are not drawn** — their tile geometry is unknown.
  They are listed (with costs) in the map file's `unmapped_sections`; the across-road strip is shown as restricted.
* **Footprints:** 60 items have no sourced size (farm buildings incl. Barn/Silo/Farmhouse, pet houses, two
  production buildings, some decorations) and use flagged provisional sizes. The field is 1×1 from 2013 client
  data (unverified). Most decoration footprints come from a single (Russian wiki) source.
* **Unlock levels** of most decorations are a wiki default of 1, not a verified gate; **prices** are known for only
  347 items; Realistic Mode lists unknown prices instead of estimating them.
* **Core building positions** in new layouts are approximate (locked by default; unlock and move to match your farm).
* Fence/path connection rules assume every fence/path joins only identical items in 4 directions; whether the game
  renders T/cross junctions for every type is unverified.

## Visual
* All art is original **placeholder** art; ~76 % of items share a generic sprite with similar items (same kind,
  colour cue and size). Names, footprints and thumbnails still differ.
* Fallback "monument" sculpture is used for ~630 decorations whose names match no recipe.
* Scenery forest is decorative only and identical for every layout on a map.

## Editor
* Each edit triggers a **full depth re-sort**: ~60 ms on a densely packed real farm, ~140 ms at 5,000 and ~400 ms
  at 10,000 synthetic objects. Planned fix: incremental insertion using the existing edge model (re-sort only
  objects whose sprite bounds overlap the changed rects).
* No in-app anchor/scale editor for imported sprites (auto-estimated anchors are marked `auto_anchor` in
  `pack.json` for manual fine-tuning).
* Variants (alternate appearances) are supported in data and packs but no catalogue item defines variants yet, so
  there is no variant picker UI.
* Annotation zones can be created, edited and deleted but not moved/resized (delete and redraw).
* Popup menus/file dialogs use native dialogs where available; their placement at non-100 % UI scales was only
  checked on Linux.
* Godot prints "ObjectDB instances leaked at exit" when quitting from automated tests — harmless (the process
  exits while UI nodes are still alive).

## Platform / verification
* **The Windows executable has not been run** in the development environment (Linux cloud, no Windows/Wine). It
  is built by CI with the official templates and the identical export is verified on Linux via `--selftest`. A
  manual Windows checklist is in TESTING.md.
* Visual tests use Mesa llvmpipe (software OpenGL); frame-time numbers from CI are not representative of real GPUs.
* The executable icon/version resources rely on Godot's built-in PE resource editing (`modify_resources`);
  verify the icon on Windows.
