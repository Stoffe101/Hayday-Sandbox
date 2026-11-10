# Farm planning: budgets, areas, phases, shopping, checklist, guide

This is the design of the planning layer that sits on top of the editor, as implemented at a511d0c. Every number
it shows comes from `data/prices/` (researched, with sources and confidence; the catalogue's own cost fields are used
only for items without a price record), the user's own price overrides, the layout's inventory and its planning data. Nothing is estimated: an unknown price stays unknown and is counted, never treated as 0.

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

**Layering** (`PriceBook`, one shared instance `App.prices`): catalogue `cost` fields (used only when the price
file has no record for the item) < `hayday_prices.json` < user overrides. The override file is `user://price_overrides.json`
(`{"format": "hayday-sandbox-price-overrides", "schema_version": 1, "items": {id: record}}`, each record in the
price-file shape plus `"origin": "user"`); it is never written to the repository. Keys an override leaves out fall
back to the lower layers, except that setting any of `price`, `step`, `schedule`, `schedule_repeats_last`
replaces all four (so an old schedule never hides a new price). An override that gives a price to an item whose
method is `unknown`, `reward` or `not_in_shop`, without naming a method, makes it `shop`. When a price record has
no `max_count`, the catalogue's maximum is used (an item fact, not a price). Each resolved record says where it
came from (`origin`: `catalogue`, `price_db`, `user`, `none`).

**Progressive prices:** copy *k* (1-based) costs `schedule[k-1]` if present (the last entry repeats only if the
record says `"schedule_repeats_last": true`, otherwise copies past the table are unknown), else `price + step×(k-1)`.
Which *k* the next purchase is: `profile.purchased[item]` if recorded, else the copies owned. Both the step rule
and its basis are community data and flagged as such (`rules.step_basis` is `unverified`).

## 2. Inventory (`layout.profile`)

Existing keys stay (`level`, `owned`, `budget_coins`, `budget_diamonds`, `treat_unknown_as_owned`). New:

* `balances`: `{currency: amount}`: what the player has now (coins, diamonds, vouchers, supplies).
* `purchased`: `{item: copies bought so far}` for progressive prices (defaults to the effective owned count).

`owned[item]` = all copies the player has (on the farm and in storage). An item **without an `owned` entry has
unknown ownership**. Budgets count it as *to buy* and say how many item types that affects (upper bound,
never a silent 0). A baseline (§3) gives a lower bound: the budget uses `max(owned, copies in the baseline)` as
the owned count, and an item with baseline copies has known ownership.

`treat_unknown_as_owned` is read by Realistic Mode only; the budget ignores it. `budget_coins` /
`budget_diamonds`, when set, cap the coin / diamond balances used for phase affordability
(`BudgetEngine.spendable()`).

**Inventory files** (`InventoryIO`, Inventory dialog › Import / Export): CSV with columns
`item_id,name,owned,purchased`; balances are rows whose `item_id` is `currency:<id>` (amount in `owned`). JSON:
`{"format": "hayday-sandbox-inventory", "schema_version": 1, "owned": {}, "purchased": {}, "balances": {}}`.
Import accepts a header or none, `,` `;` or tab separators and quoted fields, and matches ids exactly, through
aliases or by item name (case-insensitive). Unknown and ambiguous names are reported, not imported. Import
returns a new profile; the dialog applies it with one undoable `SetProfile`.

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

Notes on the fields as the code saves them (`PlanDoc.normalize`):

* Areas and phases share one id counter (`next_id`): ids look like `a1`, `p2`, `a3`. Records with a missing or
  duplicate id, and areas without a usable rect (4 numbers) or polygon (3+ points), are dropped on load.
* `target` is a Cost (`{currency: amount}`); the Areas and Phases tabs edit coins and diamonds. `notes` is kept if
  present but the UI does not edit it. New areas get `color` and `visible: true`; new phases get `color` and
  `areas: []`.
* `placed[uid]` stores the object's origin when it was marked, so the Build tab can list objects moved after
  marking.
* `steps_done` and `baseline` are omitted when empty. `acquired` keeps only counts > 0.

Edited only through `EditCommands.SetPlanning(old, new, label, merge_key)` (undoable; consecutive commands merge
only when they carry the same non-empty merge key, e.g. rapid checklist ticks or a target being typed). When a
schema 3 file is loaded, its `annotations` of kind `zone` (and annotations without a kind, which the editor drew as
zones) become rect areas (the text becomes the name, else "Area N"; colour and unknown fields kept) and labels
stay annotations; a file without zones gets an empty `planning`. The original file is kept as
`<file>.v3-backup` on the first save. Unknown keys inside `planning` are kept.

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
* **Planned objects.** Planned (ghost) objects are part of the design: budgets, the shopping list and the guide
  include them. A baseline snapshot leaves them out, and the "can't be bought" / "no inventory" readiness rows
  count only real objects.
* **Checklist state per object:** *not acquired* (to buy) → *acquired, not placed* (covered by owned or acquired
  copies) → *placed* (`placed[uid]`, or a baseline object still at its baseline origin). Phase status, checked in
  this order: *completed* when marked done or every object is placed; *not started* when it has no objects;
  *ready to build* when nothing in it is still to buy and it needs no locked plot; *in progress* when some
  objects are placed; else *not started*.
* **Affordability** (Phases tab): phases in build order, *Remaining* cost summed cumulatively per currency,
  compared with the spendable balances (§2); a phase is affordable when the running total is covered.
  Currencies are never converted. Once a phase has an unknown or unbuyable price, the running total is marked as
  a lower bound. Currencies needed without a balance entry count as 0 and are listed.
* **Unknowns are visible.** Every total reports objects/types with unknown price, types that can't be bought,
  types with unknown ownership, and plots whose supplies are unknown. `Totals.is_exact()` is true only when none
  of these is left out.

## 5. Modules

```
src/core/planning/                (pure: no scene / UI / App; unit-tested)
  plan_doc.gd          planning dict helpers: normalize, areas, phases, membership, primary phase
  currency.gd          currency ids, names, order, formatting; a Cost is {currency: int}, unknown = null
  price_book.gd        price layering, per-copy price, method/confidence, overrides IO
  budget_engine.gd     allocation + per-object costs + totals per scope; incremental per item, batch API
  shopping_list.gd     grouped rows (reused while their item is unchanged), supply rows, acquisition progress
  inventory_io.gd      owned / purchased / balances CSV and JSON import/export
  recreation_guide.gd  ordered numbered steps with landmark-relative directions, progress (stage rules: class doc)
  guide_export.gd      the guide as printable HTML (a page per phase), CSV checklist, JSON and plain text
  baseline.gd          snapshot of the real farm, diff (unchanged / moved / new / removed, fungible reuse)
  accuracy_report.gd   map provenance, landmark confidence, footprints, calibration residuals
  readiness.gd         "Can I build this?" rows from conflicts, the Realistic report and can't-buy counts
src/core/calibration_math.gd   N-point calibration (similarity for 2, least-squares affine for 3+), residuals
src/core/object_layers.gd      view layers by category (show / dim / hide)
src/ui/plan/                   PlanContext, PlanTab, PlanPanel and its tabs, PlanScope / PlanUiModels (pure
                               view-models, unit-tested), PlanUI / PlanUiKit widgets, PlanDialog, ReadinessCard
src/ui/budget_widget.gd, minimap.gd, compare_legend.gd, inventory_dialog.gd, price_dialog.gd, baseline_dialog.gd
src/render/plan_overlay.gd     areas, phase highlight, progress ticks, guide numbers, heatmap, compare tints
src/editor/plan_controller.gd  area tool (rectangle / polygon / from selection)
```

UI: the budget chip on the canvas; the Plan panel (J) with the tabs Budget, Areas, Phases, Shop, Build, Guide and
Accuracy; the area tool; the inventory, price and "My real farm" dialogs; the canvas overlays (areas, phase
highlight, guide numbers, progress, cost heatmap, compare tints); the overview map. Tabs act only through
`PlanContext` (`App.plan_ctx`), which emits `changed` at most once per frame; every document edit is one
`SetPlanning` or `SetProfile` command.

**Guide and shopping-list exports** (native save dialogs that start in Documents; text files written through
`PlanUiKit.write_text` are refused inside the program folder):

* Guide (`GuideExport`, Guide tab › Export guide…): printable HTML (one section per phase, each starting on a new
  printed page; optional overview and per-phase PNG pictures written next to the HTML file), CSV checklist
  (`number,done,stage,phase,title,items,count,tiles,from_tiles,description,id`), JSON
  (`{"format": "hayday-sandbox-guide", "version": 1, ...}`) and plain text. PNG: an overview picture, or one
  picture per phase into a folder. There is no PDF export: print the HTML page to PDF from a browser.
* Pictures use the placeholder art unless the user picks "Installed art (private)"; such pictures can't be saved
  inside the program folder and the app warns not to share them.
* Shopping list (Shop tab › Export CSV…): `group,item_id,name,used,owned,bought,still_needed,next_price,
  price_range,known_total,unknown_price_copies,cant_buy_copies,how_to_get,unlock_level,availability,confidence,
  price_origin`; unknown prices and unknown ownership are written as `unknown`, never 0.

## 6. Planning extras (view only unless noted)

* **Object layers** (`src/core/object_layers.gd`, View tab): show / dim / hide Decorations, Production
  buildings, Animal homes, Trees & bushes, Fences, Paths, Fields & other. Remembered in the settings
  (`object_layers`); hidden objects are not drawn and not pickable (click, box select, erase drag). Never changes
  the layout or its file.
* **Overview map** (`src/ui/minimap.gd`, View tab / Shift+M): owned land, locked plots, road, water, fixed
  buildings, objects in category colours (the active phase in its colour), area outlines and the camera's view;
  click / drag moves the camera. Only shown when the free canvas is at least 700×420 logical px (so not at
  1920×1080 with 200 % UI scale). Two one-pixel-per-tile images; object edits repaint only their tiles.
* **Compare with my farm** (`PlanContext.compare`, View tab / Build tab header / canvas legend): tints from
  `Baseline.diff` — unchanged faded, moved blue with a thin arrow from the old footprint, new green, removed as a
  red dashed ghost with a cross. Progress checks and guide numbers are hidden meanwhile. Without a baseline the
  toggle opens “My real farm” (BaselineDialog).
* **Area → stamp** (Areas tab › Save as stamp, `StampLibrary.from_area`): the area's objects with their relative
  positions into the stamp library (landmarks / fixed items refused like any stamp); placed with the normal stamp
  tool. The layout is not edited.
* **Can I build this?** (`src/core/planning/readiness.gd`, top of Plan › Budget): blocking rows (overlaps /
  invalid placement, fixed landmarks, locked land, expansions above the farm level, items above the farm level —
  Realistic only —, over the maximum count, can't be bought, other areas) and checks (unverified footprints,
  unknown items, no inventory record). Built from the ConflictIndex, the cached Realistic report and the budget's
  can't-buy counts, cached per edit; each row selects and frames its objects.
