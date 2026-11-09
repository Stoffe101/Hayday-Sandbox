# Known issues and limitations

State at HEAD 8c93360 (2026-11-09).

## Accuracy / data
* **Starting land** is 32×32 in the public map (`data/maps/hayday_farm.json` notes: concluded from client-data
  research). The 48×32 alternative map was retired; its layouts migrate and objects in the shifted area are flagged
  for review. This was not re-checked in this wave.
* **Main-section plot shapes are approximations** reconstructed from the wiki's expansion image (subsection widths
  16/8/15/14 measured vs 17/8/15/13 in wiki text). Plot costs are from wiki tables (community).
* **Upper plots (13) and all across-the-road sections (114 plots) are not drawn**: their tile geometry is unknown.
  They are listed (with costs) in the map file's `unmapped_sections`; the across-road strip is blocked ground.
  There is no unlock (adjacency) seed rule for the across-road plots, and none will be invented.
* **Public landmark positions are approximate** (farmhouse, order board, truck, roadside shop, newspaper mailbox).
  They are drawn as a guide and do not block placement, so a layout can put objects where the real landmark
  stands. Private world data can supply real positions; see "Private art and world data" below.
* **Footprints:** 60 items have no sourced size (farm buildings incl. Barn/Silo, pet houses, two production
  buildings, some decorations) and use flagged provisional sizes. The field is 1×1 from 2013 client data
  (unverified). Most decoration footprints come from a single (Russian wiki) source.
* **Unlock levels** of most decorations are a wiki default of 1, not a verified gate; **prices** are known for only
  347 items; Realistic Mode lists unknown prices instead of estimating them.
* Fence/path connection rules assume every fence/path joins only identical items in 4 directions; whether the game
  renders T/cross junctions for every type is unverified.

## Visual
* All art is original **placeholder** art; about 76 % of items share a generic sprite with similar items (same
  kind, colour cue and size). Names, footprints and thumbnails still differ.
* **1920×1080 at 200 % UI scale is crowded** once something is selected: the inspector and catalogue leave little
  canvas.
* **Tile badges cover the corners of catalogue thumbnails.**
* **Theme and mirror art in ghosts and previews** (`UI.resolve_sprite`) is not visually verified: no public pack
  has seasonal variants or hand-drawn mirror art, so the path only runs in code and tests.
* The cliff along the north edge of the procedural terrain is a visual choice, not map data.
* Scenery forest is decorative only and identical for every layout on a map.

## Editor
* **Realistic Mode still costs about 33–46 ms per edit at 10,000 objects** (mean over 45 edits in different
  `--selftest=perf` runs on this PC; Creative is about 0.4 ms). The analysis is cached between edits but
  recomputed after each one.
* **Stamps can't be rotated while placing**; mirror the source objects before saving the stamp.
* **`LayoutLibrary` loads layouts against `App.map`**, not the map the layout names. With a single public map this
  makes no difference; it matters only if several maps are installed.
* **Objects that become landmark copies after a world change** (for example a private world whose landmark
  replaces a catalogue item) stay in the open layout until it is loaded again; the load then moves them to
  `migration.migrated_landmarks`.
* **Old sample copies keep barn and silo locked.** The first (schema 1) samples locked them without the starter
  note, and the 1→2 migration clears only the starter template's automatic lock, so library copies made from those
  samples stay locked after the upgrade. Unlock with L. The current samples have no lock.
* **Inertia and smooth zoom are tested with synthetic input events only**, not with a real mouse, touchpad or
  pen.
* No in-app anchor/scale editor for imported sprites beyond the Asset Manager (auto-estimated anchors are marked
  `auto_anchor` in `pack.json` for manual fine-tuning).
* The placeholder pack defines no variants, so the variant picker only appears with an installed pack that has
  them.
* Annotation zones can be created, edited and deleted but not moved/resized (delete and redraw).
* Popup menus/file dialogs use native dialogs where available; their placement at non-100 % UI scales was only
  checked on Linux.
* The self-test leaks a few `CanvasItem` RIDs and ObjectDB instances at exit (8 RIDs and 17 instances in the
  2026-11-09 run; earlier runs reported 10 RIDs). This predates this wave; the process exits while UI nodes are
  still alive.

## Private art and world data
* The pack loader, pack world data (`WorldLoader`), landmarks from game data, catalogue corrections, the
  "Brand-new game farm" template and theme/skin resolution exist in code and are covered by tests with
  **synthetic** packs. Nothing in this wave verified them against a real private pack.
* Not done in this wave: client-file (XAPK) extraction, Fan Kit / wiki downloads, private terrain mesh replay,
  animation-sheet extraction from game files, map authoring against game data, screenshots with private art, and
  checks with the installed pack. `tools/private_assets/` was left unchanged.

## Platform / verification
* **Windows:** the headless checks and the visual runner run on the development PC (Windows 11, Godot 4.7.2). A
  local Windows export passed `check_export_contents.py` there (no private paths). The manual checklist in
  TESTING.md has not been completed.
* **The Linux export was not built locally** (no export templates on the Windows PC); CI builds and self-tests it.
* Visual tests in CI use Mesa llvmpipe (software OpenGL); frame-time numbers from CI are not representative of
  real GPUs.
* The executable icon/version resources rely on Godot's built-in PE resource editing (`modify_resources`);
  verify the icon on Windows.
