# Farm planning: budgets, areas, phases, shopping, checklist, guide

This is the design of the planning layer that sits on top of the editor. Every number it shows comes from
`data/prices/` (researched, with sources and confidence), the user's own price overrides, the layout's inventory
and its planning data. Nothing is estimated: an unknown price stays unknown and is counted, never treated as 0.

Workflow: **Design → Budget → Areas → Phases → Shop → Build → Guide.**

## 1. Price data (`data/prices/hayday_prices.json`)

```jsonc
{
  "format": "hayday-sandbox-prices", "schema_version": 1,
  "generated": "2026-11-10", "game_version": "",          // "" = not tied to a known client version
  "sources": [{"id": "wiki_decorations", "url": "...", "accessed": "2026-11-09", "license": "CC BY-SA 3.0"}],
  "currencies": {"coins": {"name": "Coins"}, "voucher_green": {"name": "Green vouchers"}, ...},
  "items": {
    "birdhouse": {
      "method": "shop",              // see methods below
      "price": {"coins": 349},       // price of copy #1 (one or more currencies)
      "step": {"coins": 150},        // added per copy already bought (linear progression), optional
      "step_basis": "copies_owned",  // what the step counts; the game rule is unverified -> confidence
      "schedule": [{"coins": 5}, {"coins": 3200}],  // explicit price per copy #1, #2, ...; wins over price/step
      "max_count": 2,                // purchase limit, null = none known
      "availability": "current",     // current | seasonal | event | retired | unknown
      "confidence": "community",     // confirmed | community | unverified | unknown
      "routes": ["derby"],           // how a non-shop item is obtained: derby | event | package | secret |
                                     // reward | collection | expansion | season_pass | other (optional)
      "sources": ["wiki_decorations"], "notes": ""
    }
  }
}
```

**Methods:** `shop` (coins/diamonds), `vouchers` (bought with vouchers), `event_currency` (e.g. film),
`reward` (prize / derby / collection: not purchasable), `not_in_shop` (not sold; obtained some other way),
`free`, `unknown`. Only `shop`, `vouchers`, `event_currency` and `free` produce a cost. `reward` and `not_in_shop`
are "cannot be bought" and are counted separately from "price unknown".

**Currency ids:** `coins`, `diamonds`, `voucher_green`, `voucher_blue`, `voucher_purple`, `voucher_gold`,
`film`, `golden_keys`, and expansion supplies `land_deed`, `mallet`, `marker_stake`, `expansion_permit`. Unknown
ids are kept and shown by id.

**Additional record fields** (all optional; `tools/ci/validate_data.py` rejects any other key):

* `step_confidence`: confidence of the `step` value itself (`confirmed` when the en list shows the same `+N`).
  `step_basis` is one of `copies_owned` (used everywhere for now), `copies_bought`, `unknown`.
* `schedule_repeats_last`: always written next to `schedule` (`false` in the generated data).
* `copy_levels`: experience level that unlocks each copy, one per `schedule` entry (e.g. Chicken Coop
  `[1, 12, 23]`). Realistic Mode can use it; it never changes a price.
* `removal`: `{"tool": "axe" | "saw" | "shovel" | "dynamite" | "tnt_barrel" | ...}` for natural obstacles
  (`not_in_shop`). It is what clearing costs, not a purchase price.
* `repair`: `{"coins": N}` one-time repair of a pre-placed farm building (Fishing boat, Riverboat dock, Train
  station, Neighborhood house; method `not_in_shop`). Not a purchase price; budgets must not add it to item costs.
* Items with no price information at all have no `price` key. `price` is absent (never 0) for `reward`,
  `not_in_shop` and `unknown`; `free` records carry `{"coins": 0}`.

Top level also has `generated_by`, `license`, `disclaimer`, `schema_notes`, and `rules` (`{id: {value, confidence,
sources}}`, informational: the step rule and what is known about its basis). Currency entries may carry `notes` and
`sources` (expansion supplies have no fixed coin price). Research and coverage: `docs/research/PRICING_RESEARCH.md`;
regenerate with `python3 tools/catalog/build_prices.py [--report]`.

**Layering** (`PriceBook`): catalogue `cost` fields (fallback) < `hayday_prices.json` < user overrides in
`user://price_overrides.json` (same record shape plus `"origin": "user"`, never written to the repository). Each
resolved price says where it came from.

**Progressive prices:** copy *k* (1-based) costs `schedule[k-1]` if present (the last entry repeats only if the
record says `"schedule_repeats_last": true`, otherwise copies past the table are unknown), else `price + step×(k-1)`.
Which *k* the next purchase is: `profile.purchased[item]` if recorded, else the copies owned. Both the step rule
and its basis are community data and flagged as such.

## 2. Inventory (`layout.profile`)

Existing keys stay (`level`, `owned`, `budget_coins`, `budget_diamonds`, `treat_unknown_as_owned`). New:

* `balances`: `{currency: amount}`: what the player has now (coins, diamonds, vouchers, supplies).
* `purchased`: `{item: copies bought so far}` for progressive prices (defaults to owned).

`owned[item]` = all copies the player has (on the farm and in storage). An item **without an `owned` entry has
unknown ownership**. Budgets count it as *to buy* and say how many item types that affects (upper bound,
never a silent 0). A baseline (§3) gives a lower bound: the copies standing on the real farm.

## 3. Planning document (`layout.planning`, layout schema 4)

```jsonc
"planning": {
  "next_id": 4,
  "areas":  [{"id": "a1", "name": "Flower Garden", "color": "#e58fb0", "rect": [x, y, w, h],
              "visible": true, "target": {"coins": 20000}, "notes": ""},
             {"id": "a2", "name": "Orchard", "color": "#8fc46a", "points": [[x, y], ...], "visible": true}],
  "phases": [{"id": "p1", "name": "Farm Entrance", "color": "#f2b84b", "areas": ["a1"],
              "target": {"coins": 50000}, "done": false, "notes": ""}],   // array order = build order
  "assign":   {"<uid>": "p1"},       // manual primary phase, wins over the area rule
  "placed":   {"<uid>": [x, y]},     // marked "placed in Hay Day" (origin when marked)
  "acquired": {"<item>": n},         // copies bought during this project (shopping-list progress)
  "baseline": {"name": "My farm", "taken": "2026-11-10T..Z", "source_id": "...",
               "objects": {"<uid>": ["item", x, y, w, h]},             // optional snapshot of the real farm
               "unlocked_plots": ["plot id", ...]},                    // land owned when taken (optional)
  "steps_done": {"<guide step id>": true}  // guide steps ticked by hand (optional)
}
```

Edited only through `EditCommands.SetPlanning(old, new, label, merge_key)` (undoable; consecutive commands merge
only when they carry the same non-empty merge key, e.g. rapid checklist ticks). Schema 3 files load unchanged and
get an empty `planning`; their `annotations` of kind `zone` (and annotations without a kind, which the editor draws
as zones) become rect areas (the text becomes the name, else "Area N"; colour and unknown fields kept), labels stay,
and the original file is kept as `<file>.v3-backup` on the first save. Unknown keys inside `planning` are kept.

Baseline details (`baseline.gd`): a baseline record may carry a 6th element `true` = flipped (rotating counts as
moving). Planned ghosts are not part of a snapshot. Matching is by uid **and** item (same uid, other item = removed
+ new). Items are fungible: a new copy reuses a removed copy of the same item (`reuse`, `reused`), never a purchase;
removed copies nobody reuses are `freed` (to storage).

Object identity: moving keeps the uid; paste / duplicate / repeat / stamp / mirror make new uids; undoing a delete
restores the same uid; uids are never reused (also not after save / load), so per-object plan entries of a deleted
object are harmless and become valid again on undo.

## 4. Rules

* **Area membership.** Rect areas use tile rectangles; polygon areas contain a tile when the tile centre is inside
  the polygon (even-odd rule). An object is **in** an area when *any* tile of its logical footprint is (never the
  sprite). Areas may overlap; an object can be in several areas, so area totals are not additive and the UI says
  so when the areas shown share objects.
* **Primary phase.** `assign[uid]` if set, else the first phase (build order) with an area containing the object,
  else *Unphased*. Every object has exactly one primary phase, so phase totals add up to the farm total.
* **Allocation of owned copies** (deterministic): per item, objects are ordered by (1) unchanged/moved baseline
  objects first, (2) primary phase build order (Unphased last), (3) uid. Owned copies cover objects in that order,
  then `acquired` copies, the rest are *to buy* and get purchase numbers `purchased+1, +2, …` for progressive
  prices. Reordering phases changes who gets owned copies first.
* **Cost modes.** *Design cost* (gross): every object priced as a purchase in that same order starting from copy
  #1, ignoring inventory. *To buy*: objects not covered by owned copies. *Remaining*: objects not covered by
  owned or acquired copies. Each object carries its own cost, so any scope (selection, rectangle, polygon, area,
  phase, group, whole farm) is a sum over a set of uids: nothing is counted twice.
* **Land.** Expansion plots the design needs (objects standing on locked plots) add their supplies
  (`land_deed`, `mallet`, `marker_stake`, `expansion_permit`) from the map, in the *To buy* and *Remaining* totals
  and the shopping list.
* **Checklist state per object:** *not acquired* (to buy) → *acquired, not placed* (covered by owned or acquired
  copies) → *placed* (`placed[uid]`, or an unchanged baseline object). A phase is *completed* when all its
  objects are placed or it is marked done; *ready to build* when nothing in it is still to buy; *in progress*
  when some objects are placed; else *not started*.
* **Unknowns are visible.** Every total reports objects/types with unknown price, types that can't be bought,
  and types with unknown ownership.

## 5. Modules

```
src/core/planning/
  plan_doc.gd          planning dict helpers: normalize, areas, phases, membership, primary phase (pure)
  currency.gd          currency ids, names, order, formatting
  price_book.gd        price layering, per-copy price, method/confidence, overrides IO
  budget_engine.gd     allocation + per-object costs + totals per scope; incremental per item
  shopping_list.gd     grouped rows, acquisition progress
  inventory_io.gd      owned/balances CSV and JSON import/export
  recreation_guide.gd  ordered numbered steps with landmark-relative directions, progress (stage rules: class doc)
  guide_export.gd      the guide as printable HTML (a page per phase), CSV checklist, JSON and plain text
  baseline.gd          snapshot of the real farm, diff (unchanged / moved / new / removed, fungible reuse)
  accuracy_report.gd   map provenance, landmark confidence, footprints, calibration residuals
src/core/calibration_math.gd   least-squares affine fit from N points, per-point residuals
```

UI (no logic): budget widget on the canvas, a Plan panel (Budget, Areas, Phases, Shopping, Checklist, Guide,
Accuracy), area drawing tool, inventory and price-override dialogs, canvas overlays (areas, phase highlight,
guide numbers, progress, cost heatmap).
