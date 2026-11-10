# World validation: the private world against the game client's own tables

Public-safe summary. The inputs (the client's `assets/data` tables, the installed private pack's `world.json`,
`catalog_overrides.json`, `pack.json`) and the outputs (`world_validation.json` / `.md`) are **private**: they hold
coordinates and sizes from the user's own client. They never enter git. This page only describes the method, the
checks and the results as counts.

## What it is

* `src/core/client_level.gd` (`ClientLevel`): pure reader for the client's multi-section level CSV (`TileMap`,
  `SpecialObjects`, `Objects*`, other flat sections) and for plain data tables (continuation rows with an empty
  `Name` are grouped under the row above). No game data is embedded.
* `src/core/world_validator.gd` (`WorldValidator`): compares a parsed level (+ expansion table, tile table, object
  tables) with a world dictionary or a loaded `FarmMap`, and the catalogue footprints (after the pack's corrections)
  with the client's `TileWidth` / `TileHeight`. Returns a report dictionary
  (`format: hayday-sandbox-world-validation`, `version`, `game_version`, `generated`, per-check `status`
  pass / warn / fail, counts and the first N examples of every problem).
* `tools/private_assets/validate_world.gd`: runs it on real files and writes JSON + Markdown.
* The Farm Accuracy Report (`AccuracyReport`, Plan → Accuracy) reads `user://private_data/world_validation.json` and
  shows an **evidence ladder** (below). A report only counts when it was made for the active world: same client
  version and same world generation time; otherwise the ladder says why it does not apply.

## Checks

| Check | Compares | Fails when |
|---|---|---|
| `map_size` | TileMap width x height vs world `size` | different |
| `ground` | ground type per tile: client `raw % 100` vs the world's RLE ground layer | any tile differs |
| `expansion_tiles` | expansion id per tile: client `raw // 100` vs the union of the world's plot rects (`game_id`) | wrong id, missing, extra or out-of-map plot tiles |
| `plot_overlaps` | tiles covered by more than one plot rect; plots sharing a game id | any |
| `plot_boundaries` | empty / out-of-map rects, plots without a game id, stored tile counts | any (a plot in several pieces only warns) |
| `expansion_definitions` | expansion table rows (row k = id k) vs ids on the map vs world plots | map and world disagree, or the map uses an undefined id. Definitions without land are **listed with the reason the data gives**, not failed |
| `landmarks_present` | every `SpecialObjects` row has a world landmark (`special_object`) and vice versa | missing or extra |
| `landmark_positions` | world origin vs the origin implied by the object's **registration rule** (below) | shifted |
| `landmark_footprints` | client `TileWidth x TileHeight` (mirrored swaps) vs world footprint | different (no client size only warns) |
| `rendering_anchors` | where the app draws centre-anchored sprites vs the client registration point | never passes: rendering is not verified by data |
| `buildability` | client tile table `BlocksBuilding` per ground type vs world tile kind (buildable/plot vs road/blocked) | any tile disagrees |
| `initial_objects` | world seed objects vs the client `Objects*` sections (same tile, mirroring and section) | a world object the client does not have |
| `item_footprints` | catalogue footprint as the app uses it (pack corrections applied) vs client `TileWidth x TileHeight` | different size (axis swaps only warn) |
| `footprint_corrections` | every footprint correction in the pack's `catalog_overrides.json` is present in the catalogue the app uses | missing |

Item links: an item is linked to a client row through its override's evidence (table + `Name`) or through the pack
sprite's export name. The sprite only identifies the row; its pixel size is never used as tile occupancy.

## Results (client 1.73.89, private pack world generated 2026-11-09; run 2026-11-10)

| Check | Compared | Mismatches | Status |
|---|---|---|---|
| map size | 1 | 0 | pass |
| ground type per tile | 9,976 tiles | 0 | pass |
| expansion id per tile | 5,950 tiles | 0 (0 missing, 0 extra, 0 wrong id) | pass |
| overlapping plot rects / duplicate ids | 5,950 tiles / 223 plots | 0 | pass |
| plot boundaries | 223 plots | 0 | pass |
| expansion definitions | 227 definitions, 223 on the map = 223 world plots | 0 | pass (4 definitions without land, explained below) |
| landmarks present | 31 rows, 31 landmarks | 0 | pass |
| landmark positions | 31 | 0 (30 at the client tile, 1 through the truck rule) | pass |
| landmark footprints | 30 | 0 | warn: 1 landmark has no size in its client table (the world's 1x1 is an assumption) |
| rendering anchors | 31 | 1 measured offset (truck, below) | warn (never verified) |
| buildability | 9,976 tiles | 0 | pass |
| initial objects | 523 world objects | 0 (58 carry a display name instead of the client row name) | pass |
| item footprints | 1,927 linked items | 0 (34 not linkable, 2 ambiguous exports) | pass |
| footprint corrections | 73 of 73 present and equal to the client tables | 0 | pass |

Without the pack's corrections the same comparison finds 50 size differences and 4 axis swaps among the 1,927 linked
items; the 38 footprint fixes of the previous handoff are all among them and all present after the corrections.

### Expansion definitions without land

The client's expansion table has 4 more definitions than the map uses. None is missing land:

* 3 are **placeholders**: 1000 of every tool and no expansion-key amount, inside the id ranges of the 2021 / 2023
  special sections (numbering gaps between plots of the same section).
* 1 has a **regular cost** equal to its neighbours, sits in a numbering gap of a 2021 special section and has no
  tiles anywhere: an unused or retired definition (its purpose is not stated in the data; private research found it
  absent in an older client as well).
* None of the 4 ids appears in the other level files of the client: the train station map uses its own expansion
  table, the fishing lake map and the decoration levels have no expansion cells. They are not Fishing Lake or train
  expansions.

## The truck: what the client's (X, Y) means

The client's `SpecialObjects` row for the truck (`Car`) gives (X, Y); the private world stores the truck at
(X, Y - 1) with footprint 1 x 2 (`TileWidth` 1 along +x, `TileHeight` 2 along +y) and `draw_anchor: center`.

Conclusion (**strong**, not verified-in-data): (X, Y) is the truck's **logical position / registration point**,
not its footprint origin. The truck is a centred object: its footprint is centred on that point with integer halves,
`origin = (X - W / 2, Y - H / 2)`, which gives (X, Y - 1) for 1 x 2. The other 30 landmarks follow the ordinary
**top-corner** rule (origin = (X, Y)) and match it exactly; there is no blanket offset.

Evidence:

1. The TileMap's only non-passable road cells (`Road_01_Blocked`) on the farm side form a vertical pair of exactly the
   truck's 1 x 2 size, starting one row above the row's Y. The validator re-checks this on every run
   (`evidence_check`): the pair lies entirely under the derived footprint and only half under the top-corner one.
2. With the top-corner rule the truck would cover one ordinary passable road cell and leave one parking cell empty.
3. The parked truck art is centred on its export's registration point (opaque bounds roughly symmetric around it),
   unlike building art, which hangs below the top corner of its tile.
4. The row has the same position in the three client builds examined.

What is still open: the client's code is not read, so "centred with integer halves" is inferred from data (strong).
Placement validity does not depend on it: all candidate cells are road. **Rendering** does: the app draws a
centre-anchored sprite at the footprint centre, which is half a tile (16, 8 world px, about 18 px) along +x from the
client's registration point. That offset is reported by the `rendering_anchors` check; it is not corrected in the
world data (fixing it belongs to the pack builder / renderer).

### Where the truck art is drawn (W5 check; pending screenshot)

The logical cells stay as above (verified road cells, unchanged). Only the drawing position was examined, with the
pack's own export data and private calibration sheets (`tools/private_assets/calibration_sheet.py`, rendered at
zoom 1, 2 and 3 for both readings):

| Reading | Where the export's registration point goes | Supported by | What it looks like |
|---|---|---|---|
| B, current | the footprint centre | the parking pair lies exactly under the art; the export is centred on its registration point | the truck stands on the parking pair, on the driveway |
| A, uniform rule | the top corner of the row's tile (X, Y), as for the other 30 landmarks | one drawing rule for every SpecialObjects row | the truck moves half a tile (16, 8 world px) along -x, its rear over the verge |

Conclusion: keep B (**strong**, not verified). The two readings use the same data and differ only in the client's
drawing code, which is not read. The rendering-anchors check keeps reporting the measured offset, and the world
records the row tile as `client_registration` so a screenshot can decide. `build_world.py`
(`landmark_anchor_offset`) states the rule.

Settling it (**pending screenshot**): take an in-game screenshot with the farmhouse, order board and truck on screen
(recipe in [PRIVATE_ASSETS.md](../PRIVATE_ASSETS.md#settling-a-placement-question-with-a-real-screenshot)), calibrate
it with 4+ landmark points including the truck's centre, then Plan → Accuracy → *Write placement check*. The
report says whether the clicked truck centre is closer to the footprint centre (B) or to the registration point (A).
Only then would the pack builder change the truck's anchor (the logical cells never move).

## Evidence ladder (Plan → Accuracy)

1. Exact match to client ground data (`ground`)
2. Exact match to client expansion assignments (`expansion_tiles`, `plot_overlaps`)
3. Verified logical landmark coordinates (`landmarks_present`, `landmark_positions`; rules below "verified-in-data"
   are named; the user's own landmark corrections downgrade it)
4. Verified item footprints (`item_footprints`, `footprint_corrections`)
5. Verified rendering anchors: always "Not verified" (only measured offsets are shown)
6. Screenshot calibration results (existing calibration)
7. Visual terrain: always "Not verified"
8. Live game version: the client version of the data; the live game may have changed since

On the public approximate map rows 1-3 say "Public approximate map". With a private world but no (or a stale)
report they say "not yet compared". Nothing is ever called pixel-perfect.

## Re-running it (e.g. for a new client version)

1. Extract the new client's `assets/data` folder (see `docs/PRIVATE_ASSETS.md`), rebuild and install the private pack.
2. Run (Windows):

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 --script res://tools/private_assets/validate_world.gd -- `
     --tables <client>\assets\data `
     --world "$env:APPDATA\HaydaySandbox\asset_packs\hayday_original\world\world.json" `
     --overrides "$env:APPDATA\HaydaySandbox\asset_packs\hayday_original\catalog_overrides.json" `
     --out <private folder>\world_validation.json
   ```

   (Linux: `godot --headless --path . --script res://tools/private_assets/validate_world.gd -- ...`.) It writes the
   JSON and a `.md` next to it and prints one line per check. `--fail-on-fail` exits with 2 when a check fails.
3. Copy the JSON to `%APPDATA%\HaydaySandbox\private_data\world_validation.json` (the runner's isolated APPDATA is
   thrown away, so the default `--out user://...` is only useful when run inside the app's own user folder). The
   Accuracy tab picks it up; a report made for another world build is ignored and says so.
4. If a landmark is reported as shifted, look for evidence before adding a registration rule to
   `WorldValidator.REGISTRATION`; never add a blanket offset.

Tests: `tests/unit/test_client_level.gd`, `tests/unit/test_world_validator.gd` and the ladder tests in
`tests/unit/test_accuracy.gd` use the synthetic fixtures in `tests/fixtures/client_level/` (invented numbers).
