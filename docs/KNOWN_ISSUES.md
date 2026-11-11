# Known issues and limitations

Editor UX pass (2026-11-11): tile selection, the budget card, costs in the inspector and catalogue. Its own
limits are listed under "Editor"; everything below still applies.

State at the end of W5 (authentic visual fidelity + real-world verification; W5a = 7ce14cc, W5b = the commit after
it), 2026-11-10. Checks at that state (cloud box, Godot 4.7.2): see the table in [TESTING.md](TESTING.md); with the
private pack installed (copied data folder) the self-test passes too, and `--selftest=packcycle` shows that
uninstalling the pack reverts everything it brought. Items that only a real in-game screenshot can settle are
collected under [Pending a real screenshot](#pending-a-real-screenshot-and-how-to-settle-each-one).

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
* **Unlock levels** of most decorations are a wiki default of 1, not a verified gate. Prices: see "Planning and
  prices" below.
* Fence/path connection rules assume every fence/path joins only identical items in 4 directions; whether the game
  renders T/cross junctions for every type is unverified.

## Planning and prices
* **The basis of the per-copy price step is unverified.** The wikis say "+N per purchase" but nobody documents
  whether deleting a copy or getting one as a reward changes the next price. The data uses `copies_owned`
  (`rules.step_basis` and `step_confidence` mark it); recording "purchased" in the inventory overrides it. The
  fence step itself is disputed (+2 in en/ru, +5 in de 2024). See PRICING_RESEARCH.md §1 and §8.
* **Most items can't be bought.** 1,500 items are recorded as not sold in the shop (1,458 of them carry the wiki's
  "999 diamonds" not-for-sale placeholder) and 14 as rewards; 1 price is unknown (Enchanted Workshop). Only 447
  items have a known purchase price. Whether "not sold" items reappear in limited-time offers is not known. Budgets
  count these items separately; they never become 0.
* **Price records disagree in places**: 26 records are `unverified` (e.g. 21 Sanctuary prices that differ by 500
  coins between wikis, two items whose prices appear swapped). Prices change over time; the file is not tied to a
  game version (`game_version` is empty).
* **Expansion supplies have no coin price** (land deeds, mallets, marker stakes, expansion permits). Budgets and
  the shopping list count supplies, not coins; plots whose supplies the map doesn't know are counted as unknown.
* **1,331 price records have unknown availability**; nothing is marked retired because no source says so.
* **Realistic Mode counts shortages with its own inventory rule.** In the app every Realistic coin / diamond figure
  is the budget's To-buy total (PriceBook, overrides, per-copy steps; `cost_source` "budget"), so the verdict, the
  inspector's "To buy" and the budget chip agree. The *shortage list* (which copies are "not owned") still honours
  "assume unlisted items owned", while the budget counts items without an inventory record as to buy (an upper
  bound, listed as unknown ownership). Without a price book (some unit tests) the report falls back to the
  catalogue's flat `cost` fields.
* **The public map is an approximation**, so the recreation guide's directions are only as good as it is: they are
  relative to the five mapped landmarks (farmhouse, order board, truck, roadside shop, newspaper mailbox), all at
  approximate positions and flagged as such. Landmarks that are not in the map data (for example the Mine) are
  never used or invented. The Accuracy tab states this; calibrate a screenshot to measure it.
* **Water-decoration zones need world data with them.** Items tagged `water_deco` (the pearl-priced water
  decorations, private catalogue additions) may stand only inside the world's `water_deco_zones` (client level data
  `WaterDecoZones`, written by `tools/private_assets/build_world.py`; the private world's two zones match the client
  rows: WorldValidator check `water_deco_zones`, verified-in-data). That the *whole* footprint must lie inside one
  zone's tiles (the union of enabled zones) is the app's reading (plausible), not stated by the data. A world
  without zones (the public map, older private worlds) refuses them everywhere with that reason. Pastes, brushes,
  moves and the layout tools pass the per-object flag; `App.new_layout` templates check initial objects with land
  rules (no water decoration is an initial object in the client data seen so far). The zone overlay was checked in
  private captures only (no public item carries the tag).
* **Client records still waiting for your choice.** With the user's 1.73.89 data, 2 records are ambiguous (two
  catalogue entries share the name) and 27 unmatched records have a candidate (mostly catalogue items with misspelt
  or Russian wiki names whose art the pack already shows): they stay unpriced until chosen in Asset manager > Game
  data. Two connecting pond pieces are listed but not added (the client data does not say path or water).
* **Design customization is whole-farm only and charged per part.** The game's own counting for looks bought as a
  style-guide bundle (if any discount applies) is unknown; the budget sums the parts.
* **No PDF export.** Print the exported HTML guide to PDF from a browser.
* **Full-land PNG exports with a pack terrain reach past the terrain's art.** Exports with installed art and the
  private pack terrain work (checked by eye in W5b: whole land at 1×, objects at 1×, a phase picture), but the
  "whole land" frame is the map's land rectangle, which is wider than the client's background pieces: outside them
  the export shows the plain background colour, and the river's water ends in a soft dark smear at both map edges.
  The north end of the river is also visible in the app's default view (a dark fade into the background above
  the barn). Export "Objects" or crop the picture; framing exports by the terrain's extent is not implemented.
  Whether the game covers these ends (for example with its cloud art) is part of the clouds question below.
* **Slow parts at 10,000 objects** (cloud box, 4-CPU container with llvmpipe, 2026-11-10, `perf_planning.gd`, same
  scenario before/after the W5b caches, ms mean / p95): the guide is still the slowest view: `RecreationGuide.build`
  from scratch about 465–530 ms, `ctx.guide()` after an edit 587 / 587 → 447 / 465 (step memo, engine phases, shared
  compare diff; only while the Guide / Build tab, a guide picture or an export needs it). `GuideExport.to_json`
  about 230–240 ms (export only; most of it is `JSON.stringify` and the rect conversion, unchanged). Build tab
  model 67 / 70 → 52 / 53 after an edit; "Can I build this?" 157 / 179 → 65 / 73 after an edit (the perf layout has
  every object overlapping: worst case); `Baseline.diff` about 47–54 ms, recomputed after every edit while "Compare
  with my farm" is on (not incremental). Budget chip data about 4–5 ms after an edit.
* **Planning areas can't be moved or reshaped**; delete and redraw. Area and phase `notes` are kept in the file but
  not editable in the app.
* **Baselines from another saved layout** match objects by uid and item. A layout that was not copied from the
  design's source has unrelated uids, so most objects show as removed + new (copies are still reused, not bought).

## Visual
* All art is original **placeholder** art; about 76 % of items share a generic sprite with similar items (same
  kind, colour cue and size). Names, footprints and thumbnails still differ.
* **1920×1080 at 200 % UI scale leaves a small canvas** (960×540 logical px). Mitigated, not solved: while the
  inspector or the Plan panel is open the catalogue shows only its rail, the Plan panel's tab rail shows icons
  only, the dock's rows no longer cover the side panels, and the overview map is not shown (it needs 700×420
  logical px of free canvas). Re-checked by eye in W5b (public and private captures of the main scenarios at
  1920×1080, 2560×1440, 3440×1440 and 3840×2160, each at 100 / 125 / 150 / 200 %): usable, cramped at 1920×1080
  @200 %. Plan panels are slightly translucent, so a canvas label can show faintly through them.
* Catalogue thumbnails are drawn below the badge row (footprint, level, size-source dot, favourite star), so they
  are about 20 % smaller than the tile's icon box; the badges no longer cover them.
* **Theme and mirror art in ghosts**: checked with a private pack (scenario `ghost_art`: the ghost's texture equals
  the placed object's, for a winter skin and a hand-drawn mirror; also by eye). Public packs have neither, so public
  runs only exercise the code path.
* **Lift / drop motion** (drag pick-up, drop, new placements) is a short eased offset with one 1.5 px rebound at
  Ambient animation Full. Its timing is a design choice, not taken from the game (the game's own pick-up animation
  is pending a screen recording).
* The cliff along the north edge of the procedural terrain is a visual choice, not map data.
* Scenery forest is decorative only and identical for every layout on a map.

## Editor
* **Tile selection is a rectangle per drag.** Irregular areas are built with Shift/Ctrl drags; there is no tile
  brush. The selected ground can't be dragged by its empty tiles: drag one of the selected objects to move them.
  A press on ground that an object's art covers picks that object (pixel-accurate picking), so start a tile drag
  on visible ground.
* **Catalogue price chips sit on the bottom of the thumbnail** and can cover a little of the art; the name below
  stays clear.
* **Realistic Mode costs about 27 ms per edit at 10,000 objects** (`--selftest=perf`, cloud box 4-CPU llvmpipe,
  45 edits: mean 62.5 / p95 74.3 ms before the incremental report, 27.1 / 31.2 ms after; Creative about 0.6–0.8 ms).
  The report is incremental now (docs/PLANNING.md §7); what is left is mostly the issue list and marks main.gd
  rebuilds from the whole report after every edit.
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
* Popup menus/file dialogs use native dialogs where available; their placement at non-100 % UI scales was only
  checked on Linux.
* The self-test leaks a few `CanvasItem` RIDs and ObjectDB instances at exit (end of W5: 8 RIDs and 17 instances
  with a fresh data folder, 13 RIDs and 27 instances with the private pack installed). This predates the planning wave; the
  process exits while UI nodes are still alive.

## Private art and world data
* **Verified with the user's real private pack in W5** (never in git; screenshots in the private root only): the
  self-test passes with the pack installed (copied data folder; it failed 8 placeholder-specific checks before
  W5), the world matches the client's level data (WorldValidator, Plan → Accuracy), pack terrain, object
  animations and glow, water-decoration zones, client prices, installed-art exports, and uninstalling: with
  `--selftest=packcycle` (copied data folder) art, the 72 catalogue additions, the 81 catalogue corrections, the
  world, the water zones and the pack terrain all revert, the procedural ground returns, and the open layout keeps
  every object (a pack-only object stays as an unknown item and survives save / load).
* Still synthetic-only: packs other than the user's own (third-party art packs), and the Windows build with a
  private pack (the Windows checks run against a throw-away `APPDATA` by design).

* **Object animations and glow (W5 A1, private pack).** Ambient animations are the client's own nested-clip and idle
  loops, re-rendered by `build_anims.py`; clips that code controls (frame labels, < 3 frames, HUD) are held, and
  loops longer than the caps (12 s, 120 frames, 1.2 Mpx per sheet) keep only the clips that move most, so some
  objects play part of their motion and long character/sway loops stay still. Frames are drawn at 2 px per world px
  (statics are 2–3), so animated parts are slightly softer above ~200 % zoom. Production buildings, trees and
  animals in pastures stay static (their idle frame holds no ambient loop, or it is code-controlled). Blend ids
  8/4 = add/screen are strong (visual), 3 = multiply plausible, 64 unknown (drawn as normal). Screen / multiply
  over pixels the art does not cover are approximated (docs/ASSET_PIPELINE.md, Glow).
* **Power-line wires end over the river** next to the neighbourhood house: the wires are part of the client's own
  house export and end where that export ends; no other main-farm export continues them (strong; how the game
  hides the end is pending a screenshot). **The helpers' collection area** shows soft glows: its export holds only
  runtime slots (collect markers + their glows) that the game shows while something waits to be collected; with
  nothing else to draw they are kept as the zone's marker (the donations area hides them).
* **Modular decorations** (Gardener's / Stonemason's / Pedestal / Yard decoration) and Flamingo Statue / Rose
  Bouquet have no pack art: the modular ones are assembled from options the player picks (only a level-0 base
  exists) and the catalogue has no footprint for them; the other two have no client row with that name.

## Platform / verification
* **Windows:** the headless checks and the visual runner run on the development PC (Windows 11, Godot 4.7.2). A
  local Windows export passed `check_export_contents.py` there (no private paths). The manual checklist in
  TESTING.md has not been completed.
* **Exports built on the cloud box (W5b, export templates 4.7.2.stable):** the Windows Desktop preset exports a
  single 127.8 MB `.exe` whose PCK holds 4,590 entries and passes `check_export_contents.py` (no private or
  original-art paths); it **cannot be executed there** (no Wine), so the Windows smoke test (`tools\build\build.ps1`)
  still has to run on the PC. The Linux verification preset (92.4 MB) passes the same check and its headless
  `--selftest` passed (539 checks, 0 failed) in three of four runs; the first run **crashed with a segmentation
  fault** mid-way through the planning QA checks (no backtrace from the release template; screenshot runs shared
  the CPU in all four). Not reproduced since; watch for it in CI.
* Visual tests in CI use Mesa llvmpipe (software OpenGL); frame-time numbers from CI are not representative of
  real GPUs.
* The executable icon/version resources rely on Godot's built-in PE resource editing (`modify_resources`);
  verify the icon on Windows.

## Pending a real screenshot (and how to settle each one)

These questions cannot be settled from the client's data; a screenshot (or a short screen recording) of your own
farm can. Until then the app keeps the stated reading and labels it. Screenshots stay private (your private
folder or `user://`), never in the repository.

**How to take and use one** (details: [PRIVATE_ASSETS.md](PRIVATE_ASSETS.md#settling-a-placement-question-with-a-real-screenshot)):
close every menu in Hay Day, do not tap objects (a tap moves the camera), and take the shot named below. In the app:
inspector → View → *Screenshot reference* → add it → *Calibrate* with 4 or more points (landmark corners snap),
then Plan → Accuracy → *Write placement check*. The report (`user://private_data/placement_checks/`) gives each
point's error in tiles; tell the next session which item the screenshot is for.

| Item | Current reading (label) | Screenshot that settles it |
|---|---|---|
| Truck draw anchor | footprint centre, half a tile from the client row's registration point (strong; [WORLD_VALIDATION.md](research/WORLD_VALIDATION.md)) | fully zoomed in, farmhouse + order board + parked truck on screen; click the truck's visual centre (between the wheels, on the ground) as one calibration point |
| Farmhouse art vs its 4×4 footprint | the art covers about 82 % of the footprint's width (pack QA, plausible) | same shot; calibrate on the order board, truck and road edge only, then compare the farmhouse walls with the drawn art at 50 % reference opacity: a shifted house = drawing anchor, a house smaller than the footprint lines = footprint question |
| 1 px tile seam under the soft terrain edges | the app shows the clear colour for about 1 px where the tile area ends under an edge's soft border (pending) | fully zoomed in on a farm edge where grass meets the forest border; compare with the app at the same spot |
| Clouds / light rays, and what hides the river's ends | not drawn: no client table says where they go (pending; [TERRAIN_PACKS.md](TERRAIN_PACKS.md)); the app shows the river fading out at the map edge | two shots of the same spot zoomed fully out, the second panned by about half a screen; one more of the river's north end (where it leaves the farm) |
| Camera limits | zoom-out stops at about 22 %; panning stops at the terrain pieces' extent + a margin (app choice) | zoomed fully out, panned as far as the game allows towards each of the four corners (four shots) |
| Water-decoration zones | a decoration's whole footprint must lie inside a zone (plausible); zone positions are verified-in-data | while placing a 2×2 pearl decoration, hold it half outside a zone and take the shot (green or red tint) |
| Power-line wire end over the river | the wires end where the house export ends (strong) | the neighbourhood house and the river bank next to the bridge |
| Lift / drop motion | the app's timing is a design choice | a short screen recording of picking up and dropping a decoration |
