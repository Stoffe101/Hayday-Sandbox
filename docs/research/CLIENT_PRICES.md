# Prices from your own game files (client-price supplement)

How Hayday Sandbox reads purchase prices from the data tables of the user's own Hay Day client, matches them to
catalogue items and layers them over the public research. This file holds the method, rules and aggregate
results only. No client table, no client-derived price and no per-item import result is in the repository: those
live in the user's private data folder (`docs/PRIVATE_ASSETS.md`).

## Where things are

| What | Where |
|---|---|
| Importer (pure, unit tested) | `src/core/planning/client_prices.gd` (`ClientPrices`) |
| Price layer | `src/core/planning/price_book.gd` (layer 3, `origin: client`, confidence `game_data`) |
| In the app | Asset manager > **Game data** (`src/ui/game_data_page.gd`) |
| Command line | `tools/private_assets/import_client_prices.gd` |
| Installed supplement | `user://private_data/client_prices.json` (previous version `client_prices.prev.json`) |
| Report | `user://private_data/client_price_report.json` and `.md` |
| Your matching decisions | `user://private_data/client_price_mapping.json` |
| Client-only items, record classification | `tools/private_assets/client_catalog.py` (private outputs, see below) |
| Tests (invented data) | `tests/unit/test_client_prices.gd`, `tests/unit/test_client_catalog.gd`, self-test journey "QA 9b" |

`user://` is `%APPDATA%\HaydaySandbox\` on Windows. The leak guard (`tools/ci/check_private_leaks.py`) refuses
these documents and large client data tables wherever they are put.

## Input

Either of these:

* **The client's data tables**: a folder with `decorations.csv`, `deco_fences.csv`, `deco_ditches.csv`,
  `processing_buildings.csv`, `animal_habitats.csv`, `fruit_trees.csv`, `gatherer_habitats.csv`, `fields.csv`,
  `modular_decorations.csv`, `customization_house.csv`, `customization_truck.csv`, `customization_rss.csv`.
  `exp_levels.csv` is optional and gives copy limits. The `assets/data` subfolder of an extraction is found
  automatically. Missing tables are skipped and listed.
* **A normalized reference file**: `"format": "hayday-client-price-reference"`, one record per source row group.

Reading rules (`ClientPrices.records_from_tables`):

* The English game texts are read from `localization/texts.csv` next to `assets/data` when present (the record's
  `text`; a reference file may carry it as `game_text`). They are only used for matching.
* Row 2 holds the column types and is skipped. A row with an empty first column continues the row above it. For
  example, a second voucher currency (`Vouchers` / `VoucherCount`) is on its own continuation row.
* `Price` is coins, `DiamondPrice` is diamonds and `PearlPrice` is pearls (`Currency.GAME_FIELDS`). Currencies are
  never converted into each other.
* `DiamondPrice = 999` is the client's "not in the regular shop" placeholder. It is never a price, and it is
  recorded as `sentinel_999`.
* `CanBuy` can be TRUE, FALSE or blank. Blank means not declared, which is not the same as buyable. Several tables
  (production buildings, animal homes, fruit trees) have no `CanBuy` column at all.
* `PriceIncrease` + `DoPriceIncreaseEveryNObject` become `step` + `step_every`.
* Extra `Price` values on continuation rows of production buildings are **not** copy prices: they are per-level
  values such as production slots. They are counted (`extra_price_rows`) and ignored.
* In `fields.csv`, only the `EmptyField` row is the field plot. The other rows are crops, and their
  `DiamondPrice` is a speed-up.
* `MaxHabitatsColumnName` / `MaxFields` point to a column of `exp_levels.csv`. Its highest value is the copy limit
  (`max_count`), and the levels where it rises are `copy_levels`.
* The three `customization_*` tables are **appearance parts** (farmhouse, truck, roadside shop). They are kept
  as `components`, never as items, so they never count as a second farmhouse. `Default` parts come with the farm.
  `ExcludeFromNormalStock` parts are event parts.

## Vouchers: numbered in the game, coloured for players

`vouchers.csv` numbers the vouchers 1–5 by rarity: common, uncommon, rare, epic, black. Players and the wiki talk
about colours. The mapping was **established by comparison, not assumed**. Over the items that both the client
data and the public research price in vouchers, the amounts agree as follows:

| Client | Colour | Items agreeing |
|---|---|---|
| Voucher1 | green | 43 |
| Voucher2 | blue | 23 |
| Voucher3 | purple | 38 |
| Voucher4 | gold | 15 |

All other pairings are at most 2 items each, which are amount coincidences. Voucher5 ("black", a Farm Pass
reward) has no colour name and no item uses it in 1.73.89. It keeps the id `voucher5`.

## Pearls

`PearlPrice` is a separate currency (`pearls`, `money.csv` `Pearl`). In 1.73.89 it is used by 8 decoration
records, all water decorations (`WaterDeco = TRUE`). The public catalogue does not have them and no public source
names them (checked against the fan wiki on 2026-11-10), so they are **private catalogue additions** (below): with the
art pack installed they are ordinary items with their client footprint, art and pearl price. The currency works
everywhere: budgets, the shopping list, balances and exports (with its own vector mark).

In the game these decorations are placed only in the river's water-decoration zones (the client level data has a
`WaterDecoZones` section: two zones along the main farm's river). The sandbox does not model those zones yet: its
placement check treats them like any other decoration (KNOWN_ISSUES).

## Matching a record to a catalogue item

Rules are tried strongest first (`ClientPrices.match_record`):

1. **Your own decision.** The mapping file maps a record key to an item id, or to `""` to ignore the record.
2. **Asset export name.** The installed art pack records, for each item whose art came from the client with an
   exact or user-verified match, the export it was taken from. The index goes export → item, and the pack whose
   art the app shows decides. When one export serves several items, the exact name picks one of them; otherwise
   the record is ambiguous.
3. A **catalogue alias**.
4. The **game text**: the English name the client shows for the record equals exactly one catalogue name. The
   catalogue's names come from the wiki, which uses the game's names, so this is as strong as an alias. When one art
   export serves several items, the game text also picks the one it names.
5. The **translation id** (`TID_DECO_WATER_DRAGON_STEPS` → `water_dragon_steps`).
6. The **exact normalized name**.

Looser similarities (a trailing number, a plural, one name containing the other) only produce **review
candidates**. They are never applied, because a wrong price on a decoration is worse than a clearly unknown one.
The same holds for **art hints**: when the installed pack shows a record's client export as some catalogue item by
name similarity only (a misspelt or Russian wiki name), that item becomes the first review candidate and the
reason says so, but nothing is applied until you choose it.

When several records claim one item with the same rule:

* If they agree, the item gets that price.
* If exactly one of them has a price, that one wins. These are shop / gift twins that share the art, e.g. a
  `…Shop` row and its prize row.
* Otherwise nothing is applied and every claim goes to the review queue.

## Reviewing a record: candidates side by side

Asset manager > **Game data** > *Review* lists every record that was not applied. Each one shows what the client
says (record name, game text, table, client size, client price, why it was not applied) and its candidates **side by
side**: picture from the active art pack, name, id, size (and whether it matches the record's size, mirrored or not)
and the price the planner uses now with its origin. *Use this* maps the record to that item, *Other item…* searches
the whole catalogue, *Ignore record* says it is not an item, *Clear decision* goes back to unassigned. Decisions are
saved in `client_price_mapping.json` at once and applied by *Re-import with my decisions* (the tables folder of the
last import is remembered, also when the import ran from the command line with `--install`). A record you have not
decided stays **unassigned**: nothing is applied. Filters: needs a choice (has candidates), with a price, ambiguous,
conflicting, unmatched, decided by you. The view-model is pure and unit tested (`ClientPrices.review_candidates`,
`decision_of`).

## Records the catalogue does not have (client-only items)

The public catalogue only holds facts with a public source. An object that exists in the client but in no public
source is **never added to the repository**; it can only become a **private catalogue addition**:

1. `python3 tools/private_assets/client_catalog.py --review <supplement or report>` classifies every record in the
   review list (rules in the tool's header, first rule wins): *duplicate* (game text equals a catalogue name or tag,
   the pack already shows its art as a catalogue item, or the catalogue has two entries with that name), *variant*
   (yearly / numbered copies, near-names), *out of scope area* (neighborhood, valley), *unreleased* (placeholder art or
   an untranslated text), *event mechanics*, *customization component*, *missing main-farm object* and *incomplete*.
   It writes a private report to `<root>/qa/<date>/client_records/` and, for the missing main-farm objects with
   complete data (English text, footprint, real art), `<root>/research/catalog/client_additions.json`.
2. `build_pack.py` matches their art like any catalogue item (by game text, so the match is exact) and merges them
   into the pack's `catalog_overrides.json` under `"additions"` (`{id: item record}`; footprint status `game_data`;
   name = the game text; category = water for water decorations, seasonal for a themed one, else the public
   catalogue's keyword rule; flippable only with a mirrored client export).
3. The app adds them while the pack is installed (`ItemDatabase.apply_overrides`; an addition never replaces a
   catalogue item or alias) and removes them with the pack (`revert_overrides`). The client-price import then matches
   them by their art export like any item, so their price comes from the supplement, never from the additions file.

Layouts that use an added item keep it by id; without the pack it shows as an unknown item, like any item the
catalogue does not know.

## Data versions

The client tables the user uploaded (`assets/data`, 400 files) were compared byte for byte with the extraction of
the 1.73.89 client in the private root: all 394 files the extraction has are identical; the upload has 6 more files
(valley mini-game boards, not used for prices). Same version.

## Precedence and merge

**your corrections > your game files > public research > catalogue > unknown** (`PriceBook.resolved`,
`PriceBook.merge_client`).

* **Priced** (the client lists a price): the client's base price, rise and rise interval replace the researched
  ones. A researched per-copy table (e.g. animal homes) is kept when the client gives no rise and agrees on
  copy 1, because the client then only knows the base price. A disagreement with research is kept in
  `client_conflict` and shown in the price dialog.
* **Not sold** (`CanBuy = FALSE`, or only the 999 placeholder):
  * An item with no price at all becomes "not sold in the shop" (`game_data`).
  * Reward, event and not-in-shop records keep their route.
  * A **researched price is kept** but marked unverified, with "your game files list no regular shop price; the
    researched price may be a limited offer". These are mostly diamond decorations sold through server-side
    offers. Removing their price would lose a real, useful number, and showing it as confirmed would be false.
* **No price**: provenance only.
* **Availability** stays from research. `CanBuy = TRUE` does not prove that the live shop sells the item today.
* **User overrides** still win. The report counts how many of your overrides hide a client price.

## Price rises

Copy *k* costs `price + step × floor((k−1) / step_every)`. A sum over copies uses a closed form
(`PriceBook.steps_before`), so large designs stay fast.

The client stores the size of the rise and its interval, but **not which counter the game uses** (copies owned,
copies ever bought, or something else). So `step_confidence` stays `unverified`. The planner counts purchases
(`profile.purchased`, default = copies owned).

To use the player's real counter, enter the price the game shows for the next copy in the price dialog ("Price
your shop shows now"). `PriceBook.copy_index_for_price` finds that copy and sets `profile.purchased`; this is one
undoable step. If the price only rises every N copies, the shown price fits a range of counters. The planner then
assumes the cheapest case and says so.

## Appearance parts (farmhouse, truck, roadside shop)

`PriceBook.skin_cost(kind, parts)` prices a set of parts (slot → part name, the same shape as the landmark skin
presets of a private world). Default parts cost nothing, and unknown parts are listed. Choosing an appearance never
moves the landmark, never adds a building and never counts as buying a second farmhouse.

The **design-customization budget** (`SkinBudget`, docs/PLANNING.md §4) uses these prices for the look a layout
chooses for the farmhouse, truck and roadside shop: optional (Plan › Budget › Design customization), whole farm only,
default and owned parts (inventory `owned_parts`) never charged, parts without a price counted as unknown.

## Import, report, rollback

In the app, go to **Asset manager > Game data**. Then:

1. Click **Import tables folder…** or **Import reference file…**.
2. Read the summary and click **Install**.
3. Review the records that were not applied, then use **Re-import with my decisions**.
4. To go back, use **Restore previous** (it swaps with the version installed before) or **Remove** (kept as the
   previous version).

From the command line (headless, isolated profile in the Windows runner):

```bash
godot --headless --path . --script res://tools/private_assets/import_client_prices.gd -- \
  --tables=<folder> --pack=<installed art pack folder> --install
```

Use `--out=<file>` instead of `--install` to write somewhere else. The tool refuses any path inside the repository.

The report (JSON + Markdown) lists:

* counts by rule;
* ambiguous, unmatched and conflicting records;
* known prices before and after;
* new, confirmed and changed prices;
* researched prices the client does not list;
* items that can't be bought;
* items still without a price;
* when replacing an older supplement, its game version and how many items differ.

### A new client version (1.74 and later)

Nothing in the app is tied to 1.73.89:

* The game version comes from the reference file, `--game-version`, or the art pack's `client_build`.
* Matching relies on export names and ids, not on version-specific tables.
* Your mapping file carries over.
* The report shows what changed against the installed supplement, and Restore previous goes back.

If the art pack and the price supplement are from different game versions, the Game data tab says so.

## Results on the user's client (1.73.89, 2026-11-10)

These are aggregate counts from the private reports; per-item values stay private. "First import" is the state
before the game-text rule, the art hints and the private additions; "now" is with them (art pack 2026.11.10).

| | First import | Now |
|---|---|---|
| Client records read | 2,454 | 2,454 |
| Object records | 2,045 | 2,045 |
| Appearance parts (kept apart, not items) | 409 (house 147, truck 116, roadside shop 146) | 409 |
| Matched by export name / game text / translation id | 1,842 / – / 2 | 1,923 / 4 / 2 |
| Ambiguous / unmatched (review) | 11 / 172 | 2 / 96 (27 of them with a candidate to choose) |
| Catalogue items with a client record | 1,844 of 1,967 | 1,857 of 1,967 public + 72 of 72 private additions |
| Known purchase prices | 447 → 455 | 447 → 467 (the 12 more are private additions: 8 pearl, 4 coin or voucher) |
| Researched prices confirmed by the client | 412 | 414 |
| Prices that differ from research (client used) | 11 | 11 |
| Researched prices the client does not list (kept, unverified) | 25 | 25 |
| Items that can't be bought | 1,507 | 1,567 (60 added event prizes without a shop price) |
| Items still without a price | 5 (planning markers) | 5 (planning markers) |

The game-text rule settled 9 of the 11 ambiguous records (an art export shared by two catalogue items, the game
text naming one) and matched 4 more records; 2 of the newly matched records confirm a researched price exactly. The
2 still ambiguous records have two catalogue entries with the same name: your choice.

Classification of the 170 records the public catalogue could not take (`client_catalog.py`):

| Class | Records |
|---|---|
| Missing main-farm object, data complete (added privately; 8 pearl water decorations, 4 sanctuary decorations, 60 event prizes and fence / path pieces) | 72 |
| Duplicate of a catalogue item (25: the pack already shows their art as a catalogue item with a misspelt or Russian name; 2: two catalogue entries with one name) | 27 |
| Variant (a yearly copy of an event building) | 1 |
| Other area (13 neighborhood, 4 valley) | 17 |
| Not released (placeholder art or untranslated text) | 46 |
| Event mechanics (seasonal event creatures; plausible, not verified) | 5 |
| Main-farm object with incomplete data (two connecting pond pieces: the client data does not say path or water) | 2 |

The coverage gain is small because most of the catalogue really is not sold in the regular shop: event prizes,
rewards, collection items. The gain in **trust** is large: 414 researched prices are confirmed by the game files and
11 outdated wiki prices are corrected. Most of these are production buildings; for one of them, the client's base
price plus its rise reproduces the wiki's second-copy price exactly.

Unverified:

* Which counter the price rise uses.
* Whether `CanBuy = TRUE` items are in the live shop today.
* Server-side offer prices.
