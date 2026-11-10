# Hay Day item metadata research

Verified: 2026-11-09

Dataset: [`data/research/items_research.json`](../../data/research/items_research.json) (1,962 records).
Everything in it comes from public community sources (fan wikis and a fan calculator site), read through their APIs or pre-rendered HTML. No game files were decompiled, and no images or artwork were downloaded.

Prices are structured separately in [`data/prices/hayday_prices.json`](../../data/prices/hayday_prices.json) (generated from this dataset plus hand checks by `tools/catalog/build_prices.py`); see [`PRICING_RESEARCH.md`](PRICING_RESEARCH.md) for methods, per-copy schedules, the price-step rule and coverage counts. Same licence: CC BY-SA 3.0, Hay Day Wiki (Fandom) contributors.

## TL;DR

- Production buildings are well covered. 58 of the 60 have a footprint, and for 50 of them the English and Russian fan wikis give the same size. Most are 2x2 (46). The early-game bakery-style ovens and bars are 3x3 (10). The Dairy is 4x4, and the Ice Cream Maker is 3x2.
- Decoration footprints come from one source: the Russian Hay Day wiki's Lua data module (`Модуль:Все украшения`), which lists 1,818 decorations with `size`, `level`, `price` and currency. The English wiki has no decoration sizes except on two single-item pages, and both of those agree with the module.
- No source states a footprint for **fields**, **farm/core buildings** (farmhouse, barn, silo, truck, roadside shop, mailbox and so on) or the **pet houses**. Those records keep `footprint: null` with `confidence: "unverified"`. The planner should make these sizes configurable and check them in-game.
- In the wiki's size unit, fruit trees are 1x1. Raspberry and Blackberry bushes are 1x2, while Blueberry and Coffee bushes are 1x1. Fences, hedges, walls and paths are 1x1, apart from one 1x2 special fence piece. Chicken Coop is 3x3, the other farm-animal pens are 4x4, and Beehive Tree and Squirrel House are 2x2.

## Units and conventions

- `footprint.w` × `footprint.h` is in **wiki size units ("tiles")**. Both wikis use the same unit for production buildings: on all 50 buildings that both list, the sizes match. The Russian wiki uses that same `размер` (size) unit for animal pens, trees, bushes and decorations, so all footprints in the dataset are on one grid. No source says how big a crop field is in this unit (see Gaps).
- Orientation: the ru module says of `size`, "width by height, order doesn't matter". All footprints can be rotated. Supercell's App Store release notes say: "Rotate decorations, bushes, and trees even if they don't fit yet, perfect for planning layouts!" A WxH value is the orientation the source gave, not a fixed one.
- `cost.coins` is the price of the first purchase. When the source says the price goes up with each purchase, `cost.other` holds `+N coins per additional purchase` (for example, Fence: 5 coins, +2 for each additional one).
- `cost.other` also holds vouchers (for example `5 green voucher + 3 blue voucher`), event currencies (`film (event currency)`, `golden keys`) and the text `not sold in shop (source lists 999-diamond placeholder)`. The ru module gives 1,458 decorations (all obtained outside the regular shop: Farm Pass, derby, valley, events, offers) the price `999` diamonds. The English wiki's Garden Tent page does the same, so this is a placeholder meaning "not for sale", not a real price.
- `max_count`: for production buildings it is the number of copies a player can build (Feed Mill 2, Sugar Mill 2, Smelter 5, otherwise 1). For animal homes it is the number of houses from the en "Animal Shelters" table. For decorations, fields and trees it is `null`, because no source gives a limit. Fields are limited by level: 6 at the start, then 3 more every second level up to L49, 2 more up to L99, then 1 more.
- `unlock_level`: experience level. For decorations, the ru module records `level = 1` on items that have no level gate (prize and event items). Those records say `level 1 = no level gate recorded` in `notes`. Town decorations have `level = 0` in the module and are stored as `null` with a note.
- `rotatable`:
  - `false` for Mine, Lure Workbench, Net Maker, Lobster Pool and Duck Salon. The en wiki says each of these "cannot be moved or rotated".
  - `true` for other production buildings and animal homes. The en Decorations page says "As with most buildings and animal shelters, decorations can be moved, stored, and/or rotated".
  - `true` for trees, bushes, fields and decorations, based on the App Store notes and the en Farm page.
  - `null` for farm/core buildings, whose movability is not documented.
- `notes` is a semicolon-separated list of extra facts and every disagreement between sources, for example `build_time=`, `game_id=`, `seasonal=`, `obtained via:`, `en list: …`, `… differs: …` and `CONFLICT: …`.
- Names are unique across the file. Where two different items share an in-game name, the record name gets a suffix: ` (collection prize)` for the prize variants, ` [<game id>]` when an internal id exists, ` [ru: <Russian name>]` otherwise, and ` (decoration)` when a decoration has the same name as a non-decoration (for example the decorative `Orange tree (decoration)`).

## Confidence levels

`confidence` mainly describes how reliable the footprint is, because that is the value a layout planner depends on.

| value | meaning |
|---|---|
| `confirmed` | Footprint present, and the en and ru wikis (maintained separately) give the same size, allowing for orientation. No source conflicts. |
| `community` | Footprint present from one community source (usually the ru-wiki module), with no conflict. |
| `approximation` | Reserved for derived values. No record currently uses it. |
| `unverified` | Footprint missing, or sources give different areas. Level and cost may still be well sourced; see `notes`. |

Both wikis are fan-maintained. "Confirmed" means two sources agree; nobody checked the values against game files. The ru module's `id` field looks like the internal game identifier (for example `Flowerpot`, `Barrel_1`), which suggests some of its data came from game data, but this research could not check that.

## Sources

| Source | Used for | Access | Revision / fetched |
|---|---|---|---|
| en wiki `Production Buildings List` | levels, prices, build time, XP, size, number of copies | MediaWiki API, wikitext | rev 2026-10-29 |
| en wiki building / shelter / tree pages (`{{Infobox}}`) | level, price, time, slots, size, houses | API, batched `prop=revisions` (50 titles/request) | e.g. Bakery rev 2026-07-04 |
| en wiki `Animal Shelters`, `Farm`, `Edit Mode`, `Decorations`, farm-building pages, supply pages | house counts, rotation statements, unlock levels, repair costs, obstacle types | API | Animal Shelters rev 2026-06-08, Farm rev 2026-07-19 |
| en wiki `Decorations/*` (16 list subpages) | decoration names, levels and costs for cross-checking (no sizes) | API + table/gallery parser | e.g. Fences & Paths rev 2025-03-24 |
| ru wiki `Модуль:Все украшения` | decoration size, level, price, currency, type (fence/path/ditch), theme, sources, game id | API, Lua table parsed in Python | rev 2026-09-29 (1,818 entries) |
| ru wiki `Модуль:Все деревья и кусты` | tree/bush size, price, harvest minutes, game id | API, Lua | rev 2026-06-07 (17 entries) |
| ru wiki `Модуль:Названия на разных языках` | official in-game English name for each Russian name | API, Lua | rev 2026-10-13 (2,552 entries) |
| ru wiki building / pen pages (`{{Инфбокс}}`) | `размер` (size), level, price, build time | API | e.g. Пекарня rev 2026-07-04, Курятник rev 2026-02-28 |
| de wiki `Feld` | crop fields cost 1 coin each | API | rev 2022-05-23 |
| shootingspeed.com `/productionBuildingsList/`, `/treesAndBushesList/` | cross-check of levels, prices, times, sizes | pre-rendered HTML via curl | fetched 2026-11-09 |
| Apple App Store "Hay Day" page (release notes) | rotation of decorations, bushes and trees | looked up by hand | fetched 2026-11-09 |

shootingspeed.com takes its building sizes and images from the en wiki (its bundle links to `static.wikia.nocookie.net`), so it does not count as an independent source for sizes. It is used only to show where it differs on levels, prices and times.

Sources tried and not useful: plain web search, which found no farm-planner or game-data source with footprints. hayday.info has no item metadata. The German, French, Spanish, Italian and Portuguese wikis have no size data beyond what the en and ru wikis already give.

## Method

1. Fetch: list members of the relevant en and ru wiki categories, then batch-download current wikitext (50 titles per API call, 1.5 s apart) together with the three ru Lua data modules, the de `Feld` page and two shootingspeed pages. Cache everything in a raw directory, kept apart from the scripts.
2. Parse:
   - `{{Infobox}}` and `{{Инфбокс}}` templates, using a balanced-brace parser.
   - The en production list table, including rowspans for buildings with several copies.
   - en decoration card tables (image row, name row, `Lvl` row, cost row) and `<gallery>` lists.
   - The ru Lua modules, with a small Lua table-constructor parser.
   - shootingspeed text, with regexes.
3. Join:
   - Production buildings and animal pens: an explicit en→ru page-name table in the script. The ru interlanguage links have mistakes (for example, ru `Вязальщик сетей`, which is the Net Maker, links to "Stew Pot").
   - Trees: en name with the spaces removed equals the ru `id` (for example `AppleTree`).
   - Decorations: matched to en-wiki list entries in this order:
     1. In-game English name from the names module, plus 19 documented spelling fixes (`EN_ALIAS`, e.g. en wiki "Halloween Alter" is in-game "Halloween altar"). 597 entries matched this way.
     2. Internal game id: 24 entries.
     3. Valley season number: 4 entries.
     Where several items share a name, the shop-sold, non-prize item is preferred.
4. Reconcile: the first source in priority order supplies each value.
   - Production: en infobox → en list → ru infobox.
   - Decorations and trees: ru module, with the en lists used only to cross-check.
   Every disagreement is written to `notes`.
5. Classify decorations:
   - The ru `type` field gives `Забор` (fence), `Дорожка` (path) and `Ров` (ditch-type connectable piece). Each `Ров` piece is assigned to fence, water or path by its name.
   - English-name keywords pick out water features (pond, fountain, pool, well, creek, ...).
   - The ru `theme` field, or a holiday description, marks seasonal items. These go to `decoration_seasonal` unless they are already a fence, path or water piece.
   - Plant-name keywords pick out flowers.
   - Everything else is `decoration_other`.
   This classification is a heuristic and can be wrong for edge cases. The seasonal tag is also kept in `notes` (`seasonal=Christmas`).

## Counts per category

| Category | Items | With footprint | With unlock level | confirmed / community / unverified | Footprints (WxH: count) |
|---|---|---|---|---|---|
| production | 60 | 58 | 60 | 50 / 8 / 2 | 2x2: 46, 3x3: 10, 4x4: 1, 3x2: 1 |
| farm_building | 18 | 0 | 16 | 0 / 0 / 18 | — |
| animal_home | 18 | 8 | 18 | 0 / 8 / 10 | 4x4: 5, 2x2: 2, 3x3: 1 |
| field | 1 | 0 | 1 | 0 / 0 / 1 | — |
| fruit_tree | 13 | 13 | 13 | 0 / 13 / 0 | 1x1: 13 |
| bush | 6 | 4 | 6 | 0 / 4 / 2 | 1x2: 2, 1x1: 2 |
| decoration_fence | 126 | 126 | 126 | 0 / 126 / 0 | 1x1: 125, 1x2: 1 |
| decoration_path | 88 | 88 | 88 | 0 / 88 / 0 | 1x1: 88 |
| decoration_water | 72 | 72 | 70 | 0 / 72 / 0 | 2x2: 35, 1x1: 12, 2x1: 8, 3x3: 5, 1x2: 4, 2x3: 3, 3x2: 3, 4x4: 1, 4x3: 1 |
| decoration_flower | 56 | 55 | 51 | 0 / 55 / 1 | 1x1: 39, 2x2: 7, 2x1: 4, 1x2: 3, 3x2: 2 |
| decoration_seasonal | 246 | 246 | 246 | 0 / 246 / 0 | 1x1: 100, 2x2: 65, 2x1: 35, 1x2: 31, 3x1: 5, 2x3: 4, 3x3: 3, 3x2: 2, 1x3: 1 |
| decoration_other | 1253 | 1231 | 1205 | 2 / 1229 / 22 | 1x1: 504, 2x2: 264, 2x1: 202, 1x2: 113, 3x3: 42, 2x3: 36, 3x2: 35, 3x1: 14, 1x3: 10, 3x4: 4, 2x4: 2, 4x3: 2, 4x4: 1, 4x1: 1, 5x5: 1 |
| scenery | 5 | 0 | 0 | 0 / 0 / 5 | — |
| **total** | **1962** | **1901** | **1900** | | |

Notes on the counts:
- 1,841 decoration records: 1,818 from the ru module plus 23 that appear only on the en-wiki lists, which have no footprint.
- Decorations "with unlock level" includes 1,460 records with `level 1 = no level gate recorded`. Only 113 decorations have a real level gate above 1.
- 312 decorations have a real price in coins, diamonds or vouchers. 1,458 carry the 999-diamond "not for sale" placeholder. 37 cost film (event currency) and 1 costs golden keys. The other 33 have no usable price: 23 en-only records whose list gives no cost, and 10 prize variants with no price in the source.
- 186 decorations are connectable pieces (fences, hedges, walls, paths, ditches) that join up with their neighbours. 292 have a seasonal tag: Christmas 91, Halloween 58, Lunar New Year 34, Easter 31, Valentine's 26, New Year 24, other 28. 74 are from the Sanctuary tab, and 32 are town decorations (ru level 0). Filter these out if the planner only covers the farm.
- Decoration names:
  - 1,749 use the in-game English name from the names module.
  - 32 use the name from an en-wiki list: 9 ru items whose English name was taken from a matched list entry, plus the 23 en-only records.
  - 25 use the internal game id.
  - 35 have only the Russian in-game name (new items not yet in the names module).

### Typical sizes

- Fields: unknown. No source states a size.
- Fruit trees: 1x1 (all 13).
- Bushes: Raspberry and Blackberry 1x2, Blueberry and Coffee 1x1. Nectar Bush and Peanut Bush have no size.
- Fences, hedges and walls: 1x1 (125 of 126). The one exception is the special `Lunar obstacle` fence piece, which is 1x2. The valley decoration `Stone wall [Valley China]` (ru "Великая стена", 1x2) is a separate, non-connectable item, not the shop "Stone Wall" fence.
- Paths and roads: 1x1 (all 88).
- Water: ponds and fountains are mostly 2x2 (35 of 72). Ditch and Creek pieces are 1x1. The largest water items are 4x4 and 4x3.
- Flowers: mostly 1x1 (39 of 55).
- Decorations overall (1,818 with a size), counting WxH and HxW together: 1x1 868, 1x2 401, 2x2 371, 2x3 85, 3x3 50, 1x3 30, 3x4 7, 2x4 2, 4x4 2, 1x4 1, 5x5 1.

## Production buildings

There are 55 rows from the en Production Buildings List and 5 temporary or event machines. The Mine and the four Fishing Lake buildings (Lure Workbench, Net Maker, Lobster Pool, Duck Salon) cannot be moved. The four Fishing Lake buildings are not on the farm grid.

| Building | Unlock lvl | Coins (1st) | Footprint | Max | Conf. |
|---|---|---|---|---|---|
| Feed Mill | 2 | 5 | 3x3 | 2 | confirmed |
| Bakery | 4 | 20 | 3x3 | 1 | confirmed |
| Dairy | 6 | 50 | 4x4 | 1 | confirmed |
| Sugar Mill | 7 | 350 | 2x2 | 2 | confirmed |
| Popcorn Pot | 8 | 650 | 3x3 | 1 | confirmed |
| BBQ Grill | 9 | 730 | 2x2 | 1 | confirmed |
| Pie Oven | 14 | 2,200 | 3x3 | 1 | confirmed |
| Loom | 17 | 3,200 | 2x2 | 1 | confirmed |
| Sewing Machine | 19 | 4,500 | 2x2 | 1 | confirmed |
| Cake Oven | 21 | 12,100 | 3x3 | 1 | confirmed |
| Mine | 24 | 21,000 | 3x3 | 1 | community |
| Smelter | 24 | 12,500 | 2x2 | 5 | confirmed |
| Juice Press | 26 | 31,000 | 2x2 | 1 | confirmed |
| Lure Workbench | 27 | 0 | 2x2 | 1 | community |
| Ice Cream Maker | 29 | 38,000 | 3x2 | 1 | confirmed |
| Net Maker | 30 | 28,000 | 2x2 | 1 | community |
| Döner Kebab Stand | 32 | 22,000 | 2x2 | 1 | confirmed |
| Jam Maker | 35 | 59,000 | 2x2 | 1 | confirmed |
| Jeweler | 38 | 68,000 | 2x2 | 1 | confirmed |
| Honey Extractor | 39 | 35,000 | 2x2 | 1 | confirmed |
| Coffee Kiosk | 42 | 75,000 | 2x2 | 1 | confirmed |
| Lobster Pool | 44 | 80,000 | 3x3 | 1 | community |
| Soup Kitchen | 46 | 115,000 | 2x2 | 1 | confirmed |
| Candle Maker | 48 | 118,000 | 2x2 | 1 | confirmed |
| Flower Shop | 49 | 120,000 | 2x2 | 1 | confirmed |
| Duck Salon | 50 | 90,000 | — | 1 | unverified |
| Candy Machine | 51 | 120,000 | 2x2 | 1 | confirmed |
| Sauce Maker | 54 | 135,000 | 3x3 | 1 | confirmed |
| Sushi Bar | 56 | 150,000 | 2x2 | 1 | confirmed |
| Salad Bar | 58 | 165,000 | 3x3 | 1 | confirmed |
| Sandwich Bar | 61 | 180,000 | 3x3 | 1 | confirmed |
| Smoothie Mixer | 64 | 220,000 | 2x2 | 1 | confirmed |
| Pasta Maker | 67 | 400,000 | 2x2 | 1 | confirmed |
| Essential Oils Lab | 68 | 85,000 | 2x2 | 1 | confirmed |
| Wok Kitchen | 69 | 350,000 | 2x2 | 1 | confirmed |
| Hat Maker | 70 | 260,000 | 2x2 | 1 | confirmed |
| Pasta Kitchen | 72 | 550,000 | 2x2 | 1 | confirmed |
| Hot Dog Stand | 75 | 650,000 | 2x2 | 1 | confirmed |
| Donut Maker | 76 | 680,000 | 2x2 | 1 | confirmed |
| Taco Kitchen | 77 | 700,000 | 2x2 | 1 | confirmed |
| Omelet Station | 77 | 600,000 | 2x2 | 1 | confirmed |
| Tea Stand | 80 | 750,000 | 2x2 | 1 | confirmed |
| Fondue Pot | 81 | 800,000 | 2x2 | 1 | confirmed |
| Bath Kiosk | 84 | 850,000 | 2x2 | 1 | confirmed |
| Deep Fryer | 87 | 900,000 | 2x2 | 1 | confirmed |
| Preservation Station | 91 | 950,000 | 2x2 | 1 | confirmed |
| Pottery Studio | 94 | 1,000,000 | 2x2 | 1 | confirmed |
| Fudge Shop | 99 | 1,050,000 | 2x2 | 1 | confirmed |
| Yogurt Maker | 103 | 1,100,000 | 2x2 | 1 | confirmed |
| Stew Pot | 106 | 1,150,000 | 2x2 | 1 | confirmed |
| Cupcake Maker | 109 | 1,200,000 | 2x2 | 1 | confirmed |
| Perfumerie | 110 | 1,000,000 | 2x2 | 1 | confirmed |
| Waffle Maker | 114 | 1,250,000 | 2x2 | 1 | confirmed |
| Porridge Bar | 119 | 1,300,000 | 2x2 | 1 | confirmed |
| Milkshake Bar | 124 | 1,350,000 | 2x2 | 1 | confirmed |
| Gift Wrapping Station | 17 | 0 | 2x2 | 1 | community |
| Easter Egg Maker | 17 | 0 | 2x2 | 1 | community |
| Halloween Treats Maker | 17 | 0 | 2x2 | 1 | community |
| Birthday Balloon Maker | 17 | 0 | 2x2 | 1 | community |
| Enchanted Workshop | 17 | — | — | 1 | unverified |

## Animal homes

The 8 farm-animal and producer homes have their size from the ru wiki infobox (`размер`). The 10 pet houses have no size in either wiki. Unlock levels and prices come from the en infoboxes, and the number of houses from the en "Animal Shelters" table.

| Animal home | Unlock lvl | Coins | Footprint | Max houses | Conf. |
|---|---|---|---|---|---|
| Alpaca House | 34 | 25,000 | — | 2 | unverified |
| Beehive Tree | 39 | 4,000 | 2x2 | 1 | community |
| Bird House | 20 | 10,000 | — | 1 | unverified |
| Bunny House | 31 | 20,000 | — | 2 | unverified |
| Cat House | 21 | 500 | — | 2 | unverified |
| Chicken Coop | 1 | 5 | 3x3 | 3 | community |
| Cow Pasture | 6 | 20 | 4x4 | 3 | community |
| Dog House | 20 | 1,000 | — | 2 | unverified |
| Donkey Stable | 43 | 25,000 | — | 2 | unverified |
| Goat Yard | 32 | 1,000 | 4x4 | 3 | community |
| Guinea Pig House | 60 | 25,000 | — | 2 | unverified |
| Horse Stable | 27 | 10,000 | — | 4 | unverified |
| Kitten House | 49 | 35,000 | — | 2 | unverified |
| Lamb Pasture | 25 | 500 | 4x4 | 2 | community |
| Pig Pen | 10 | 150 | 4x4 | 3 | community |
| Puppy House | 35 | 23,000 | — | 2 | unverified |
| Sheep Pasture | 16 | 300 | 4x4 | 3 | community |
| Squirrel House | 62 | 45,000 | 2x2 | 1 | community |

## Fruit trees and bushes

Sizes come from the ru module. Levels and prices come from the en infoboxes, and the ru module and shootingspeed give the same values.

| Tree / bush | Category | Unlock lvl | Coins | Footprint | Conf. |
|---|---|---|---|---|---|
| Apple Tree | fruit_tree | 15 | 160 | 1x1 | community |
| Raspberry Bush | bush | 19 | 220 | 1x2 | community |
| Cherry Tree | fruit_tree | 22 | 410 | 1x1 | community |
| Blackberry Bush | bush | 26 | 530 | 1x2 | community |
| Blueberry Bush | bush | 30 | 550 | 1x1 | community |
| Cacao Tree | fruit_tree | 36 | 550 | 1x1 | community |
| Nectar Bush | bush | 39 | 120 | — | unverified |
| Coffee Bush | bush | 42 | 375 | 1x1 | community |
| Olive Tree | fruit_tree | 57 | 620 | 1x1 | community |
| Peanut Bush | bush | 62 | 1,200 | — | unverified |
| Lemon Tree | fruit_tree | 66 | 670 | 1x1 | community |
| Orange Tree | fruit_tree | 71 | 720 | 1x1 | community |
| Peach Tree | fruit_tree | 76 | 750 | 1x1 | community |
| Banana Tree | fruit_tree | 88 | 800 | 1x1 | community |
| Plum Tree | fruit_tree | 94 | 600 | 1x1 | community |
| Mango Tree | fruit_tree | 97 | 770 | 1x1 | community |
| Coconut Tree | fruit_tree | 101 | 810 | 1x1 | community |
| Guava Tree | fruit_tree | 104 | 860 | 1x1 | community |
| Pomegranate Tree | fruit_tree | 107 | 910 | 1x1 | community |

## Farm/core buildings (footprint unknown)

There are 18 `farm_building` records:
- Farmhouse, Barn and Silo (all pre-placed)
- Truck and order board (L3)
- Roadside Shop (L7)
- Mailbox (newspaper L7, neighborhood L10, letters L15) and the newspaper
- Wheel of Fortune truck (L8)
- Event board (L9)
- Neighborhood house (L10, 200 coins)
- Riverboat dock (L17, 7,000 coins)
- Derby stand (L18)
- Valley board (L25)
- Fishing boat (L27, 10,000 coins)
- Tackle Box (L27)
- Helpers' House (L33)
- Farm train station (L34, 20,000 coins)
- Leaderboard

None of the en, ru or de wikis gives a size for any of these, and none says whether they can be moved. They are recorded with `footprint: null`, `rotatable: null` and `confidence: "unverified"`.

## Discrepancies found

Production buildings:
- Bakery unlock level: en and ru wikis L4, shootingspeed L2.
- Feed Mill unlock level: en and ru wikis L2, shootingspeed L3.
- Pasta Maker price: en infobox and ru 400,000, en list and shootingspeed 410,000.
- Second Sugar Mill: en list 200,000 (L76), en infobox and ru 199,750.
- Ice Cream Maker: en 3x2, ru 2x3. This is the same footprint in the other orientation.
- Sizes for the Mine, Lure Workbench, Net Maker and Lobster Pool are "N/A" on the en wiki. The ru wiki gives 3x3, 2x2, 2x2 and 3x3, and the dataset uses those, marked `community`. Duck Salon and Enchanted Workshop have no size in any source.
- Build times differ (en infobox / en list / ru / shootingspeed):
  - Dairy: 30 s / 2 h / 30 s / 2 h
  - Candy Machine: 1 d 8 h / 1 d / 1 d / 1 d
  - Lobster Pool: 2 d / 2 d / 20 h / 2 d
  - Small differences of about an hour for Coffee Kiosk, Flower Shop, Hat Maker, Ice Cream Maker, Pasta Maker, Essential Oils Lab, Mine and Deep Fryer.
- Layout Edit Mode unlock level: the en Farm page says L23, the en Edit Mode page says L37 (and L34 for the town).

Animal homes:
- Goat Yard price: en 1,000 coins, ru 20.
- Sheep Pasture price: en 300, ru 150.
- Alpaca House: the infobox lists levels 34 and 44, but the en shelter table says "2 houses unlocked at level 34".
- Guinea Pig House: the infobox lists L60, the shelter table L60 and L64.

Decorations, comparing the ru module with the en lists for the 625 matched entries:
- 17 unlock levels differ:
  - Town decorations are 0 in ru and L34 in en (the town unlocks at L34).
  - Yellow and Blue flower bucket: ru L20, en L1.
  - Gravel Path: ru L41, en L40.
  - Frog King and Tortoise (shop versions): ru L15 and L13, en L34.
- 21 coin prices differ. All are Sanctuary decorations, and the ru module is lower each time: 4,500 against 5,000, 5,500 against 6,000, 7,500 against 8,000. These may be prices from different points in time.
- Spelling differences between the en wiki and the in-game English names are listed in `EN_ALIAS` in the script.

Trees and bushes: the en wiki, ru module and shootingspeed agree on every level and price.

Wiki interlanguage links are not reliable for joining records. Several ru pages link to the wrong en page (for example Свинарник, the Pig Pen, links to "Cow Pasture"), so the script uses explicit name tables.

## Gaps and data-quality concerns

1. **Field footprint is unknown.** This matters most for a layout planner. Trees, fences and paths are all 1x1 in the wiki unit, but no source states a field's size. Treat it as a configurable constant until it has been measured in-game, for example by laying a fence along one field edge.
2. Farm/core buildings, the 10 pet and bird houses, Nectar Bush, Peanut Bush, Duck Salon, Enchanted Workshop and natural obstacles (trees, rocks, ponds) have no footprint.
3. Every decoration and tree/bush footprint comes from a single community source, the ru module. Production-building sizes agree across the en and ru wikis, which supports the module's unit, but they are still not game-verified.
4. It is surprising that Blueberry and Coffee bushes are 1x1 while Raspberry and Blackberry are 1x2. Check this in-game before relying on it.
5. Decoration categories come from keyword heuristics. Expect a few to be in the wrong category: water versus other, and flower versus other.
6. 35 newer decorations have only Russian names, and 25 are named by internal game id.
7. The ru module's `level = 1` on prize and event items is a default value, not a level gate.
8. Prices change over time (see the Sanctuary decorations and the second Sugar Mill). The values here are what the sources said on 2026-11-09.

## Wiki infobox / data field names

- en `{{Infobox}}` (Template:Infobox): `title`, `level`, `price`, `time`, `slots`, `size`, `dia`, `xp`, `houses` (shelters), `gives` (trees and animals), `seats` (Duck Salon, Lobster Pool), `rlevel` (reputation level, town buildings), `needs`, `base`, `source` (crops and supplies). Only production-building pages (49) and two decoration pages (Garden Tent `2×2`, Green future `1×2`) use `size`. Formats vary: `3×3`, `2 x 2`, `2×2`. Multi-value fields look like `1 • 12 • 23`, `2-12`, `7 (first) / 76 (second)` or `12,500 to 50,500`.
- en list pages: the `Production Buildings List` table has the columns Name | Level | Price | Time | XP | Size, with rowspans for buildings that have several copies. The `Decorations/*` card tables repeat four rows: image, `'''Name'''`, `Lvl N`, cost (`5 {{Infoicon|coin}}+2 per purchase`, `8 {{Infoicon|dia}}`, `5 {{Infoicon|greenv}} 3 {{Infoicon|bluev}}`). Gallery pages have `File.png|Name (detail)`.
- ru `{{Инфбокс}}` (Шаблон:Инфбокс): `заголовок` (title), `уровень` (level), `цена` (price), `xp`, `время` (time), `слоты` (slots), `размер` (size, e.g. `3×3` or Cyrillic `2х2`), `алмазы` (diamonds), `жильцы` (occupants), `колвожильцов` (number of occupants).
- ru `Модуль:Все украшения`, one Lua table per decoration:
  - `name` (Russian in-game name), `desc`, `id` (internal game id), `game_version`
  - `price` (`{base, increment}` for coins; `{a, b}` amounts for two voucher colours) and `cur` (`Монеты` coins, `Алмазы` diamonds, `Зелёный`/`Голубой`/`Фиолетовый`/`Золотой` green/blue/purple/gold vouchers, `Фотоплёнка` film, `Ключи` keys)
  - `level`, `disp_level`, `sound`, `size` (`{w, h}`; "order does not matter")
  - `sources`, `tags` (`nature`/`farm`/`statue`/`special`/`sanctuary`), `xp`, `animal`, `collections`, `rep` (reputation level)
  - `theme` (`Christmas`, `Halloween`, `ChineseNewYear`, `Valentines`, `Easter`, `NewYear`, `Summer`, `Winter`, `Ramadan`)
  - `wild_animal`, `type` (`Забор` fence / `Дорожка` path / `Ров` ditch), `gif`
- ru `Модуль:Все деревья и кусты`: `id`, `name`, `tip` (`Дерево` tree / `Куст` bush / `Пальма` palm), `size`, `vrema` (harvest interval in minutes), `clear_xp`, `price`.
- ru `Модуль:Названия на разных языках`: `["<Russian name>"] = {en=…, de=…, fr=…, es=…, it=…, pt=…, nl=…, …}` (21 languages).

## Reproducing the extraction

The script below has no dependencies beyond the Python 3 standard library. It downloads everything into a raw cache directory and then builds the dataset from that cache. The fetch step makes about 30 HTTP requests, 1.5 s apart, and does not download any images.

```bash
mkdir -p /tmp/hayday-raw /tmp/hayday-scripts
# save the script below as /tmp/hayday-scripts/hayday_items_research.py
python3 -I /tmp/hayday-scripts/hayday_items_research.py fetch /tmp/hayday-raw
python3 -I /tmp/hayday-scripts/hayday_items_research.py build /tmp/hayday-raw \
    data/research/items_research.json /tmp/hayday-raw/stats.json
```

The fetch step only downloads pages that are not already in the cache. To refresh the data, delete the cache directory. Run with `python3 -I` and keep the cache in a different directory from the script, because downloaded content is untrusted. The build step prints and saves a statistics summary (counts per category, footprint distributions, match statistics) that was used for this document.

### `hayday_items_research.py`

```python
#!/usr/bin/env python3
"""Hay Day placeable-item research: fetch community sources and build items_research.json.

Usage (always run with `python3 -I`, keep the raw cache in its own directory):
    python3 -I hayday_items_research.py fetch RAW_DIR
    python3 -I hayday_items_research.py build RAW_DIR OUT_JSON [STATS_JSON]

Sources (facts only; no images are downloaded):
  * en wiki  https://hayday.fandom.com/api.php       (MediaWiki API, batched 50 titles/request)
  * ru wiki  https://hayday.fandom.com/ru/api.php    (Lua data modules + infoboxes with sizes)
  * de wiki  https://hayday.fandom.com/de/api.php    (field page only)
  * https://www.shootingspeed.com/productionBuildingsList/ and /treesAndBushesList/ (pre-rendered HTML)
"""
import html as htmlmod
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict

UA = "HaydaySandboxResearch/1.0 (offline layout planner; polite batch fetch)"
EN_API = "https://hayday.fandom.com/api.php"
RU_API = "https://hayday.fandom.com/ru/api.php"
DE_API = "https://hayday.fandom.com/de/api.php"
DELAY = 1.5

# --------------------------------------------------------------------------- fetching

def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except Exception as e:  # retry with backoff
            print("retry", attempt, url[:120], e, file=sys.stderr)
            time.sleep(3 * (attempt + 1))
    raise SystemExit("request failed: " + url)


def api(base, params):
    params = dict(params, format="json", formatversion="2")
    return json.loads(http_get(base + "?" + urllib.parse.urlencode(params)))


def safe(t):
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in t)[:150]


def fetch_pages(base, titles, outdir):
    """Batch-fetch current wikitext (50 titles/request). Cache: outdir/<title>.wiki + _index.json."""
    os.makedirs(outdir, exist_ok=True)
    idx_path = os.path.join(outdir, "_index.json")
    idx = json.load(open(idx_path, encoding="utf-8")) if os.path.exists(idx_path) else {}
    todo = [t for t in dict.fromkeys(titles) if t and t not in idx]
    for i in range(0, len(todo), 50):
        batch = todo[i:i + 50]
        d = api(base, {"action": "query", "prop": "revisions", "rvprop": "content|timestamp",
                       "rvslots": "main", "titles": "|".join(batch), "redirects": "1"})
        q = d.get("query", {})
        norm = {n["from"]: n["to"] for n in q.get("normalized", [])}
        redir = {r["from"]: r["to"] for r in q.get("redirects", [])}
        pages = {p["title"]: p for p in q.get("pages", [])}
        for t in batch:
            t3 = redir.get(norm.get(t, t), norm.get(t, t))
            p = pages.get(t3)
            if not p or p.get("missing") or "revisions" not in p:
                idx[t] = {"missing": True}
                continue
            rev = p["revisions"][0]
            fn = safe(p["title"]) + ".wiki"
            with open(os.path.join(outdir, fn), "w", encoding="utf-8") as f:
                f.write(rev["slots"]["main"]["content"])
            idx[t] = {"file": fn, "title": p["title"], "timestamp": rev.get("timestamp"),
                      "redirect_to": t3 if t3 != t else None}
        json.dump(idx, open(idx_path, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
        time.sleep(DELAY)
    return idx


def category_members(base, cat):
    out, cont = [], {}
    while True:
        d = api(base, dict({"action": "query", "list": "categorymembers", "cmtitle": cat,
                            "cmlimit": "500", "cmnamespace": "0"}, **cont))
        out += [m["title"] for m in d["query"]["categorymembers"]]
        if "continue" not in d:
            return out
        cont = d["continue"]
        time.sleep(1)


EN_CATS = ["Production Buildings", "Farm Buildings", "Animal Shelters", "Trees and Bushes",
           "Storage Buildings", "Fishing Lake Buildings", "Decorations", "Expansion"]
EN_EXTRA = ["Production Buildings List", "Farm", "Mailbox", "Daily Dirt", "Truck", "Edit Mode",
            "Buildings", "Wheel of Fortune", "Neighborhood", "Events", "Derby", "Leaderboard",
            "Train Station", "Town", "Fishing Lake", "Valley", "Sanctuary", "Shop", "Tackle Box",
            "Helpers' House", "Axe", "Saw", "Dynamite", "TNT Barrel", "Shovel", "Pickaxe",
            "Garden Tent", "Green future", "Decoration Collections"]
RU_CATS = ["Производственные здания", "Жилища для животных", "Деревья и кусты", "Ферма",
           "Здания для хранения", "Прочие объекты", "Город", "Рыболовное озеро"]
RU_EXTRA = ["Беличье дерево", "Поле", "Утиный салон", "Рудник"]
RU_MODULES = ["Модуль:Все украшения", "Модуль:Все деревья и кусты",
              "Модуль:Все производственные здания", "Модуль:Все животные",
              "Модуль:Названия на разных языках"]
WEB = {"ss_production.html": "https://www.shootingspeed.com/productionBuildingsList/",
       "ss_trees.html": "https://www.shootingspeed.com/treesAndBushesList/"}


def cmd_fetch(raw):
    os.makedirs(raw, exist_ok=True)
    cats = {}
    titles = []
    for c in EN_CATS:
        cats[c] = category_members(EN_API, "Category:" + c)
        titles += cats[c]
        time.sleep(1)
    json.dump(cats, open(os.path.join(raw, "en_categories.json"), "w"), indent=1, ensure_ascii=False)
    fetch_pages(EN_API, titles + EN_EXTRA, os.path.join(raw, "en"))
    rcats, rtitles = {}, []
    for c in RU_CATS:
        rcats[c] = category_members(RU_API, "Категория:" + c)
        rtitles += rcats[c]
        time.sleep(1)
    json.dump(rcats, open(os.path.join(raw, "ru_categories.json"), "w"), indent=1, ensure_ascii=False)
    fetch_pages(RU_API, rtitles + RU_EXTRA, os.path.join(raw, "ru"))
    fetch_pages(RU_API, RU_MODULES, os.path.join(raw, "ru_modules"))
    fetch_pages(DE_API, ["Feld"], os.path.join(raw, "de"))
    for fn, url in WEB.items():
        p = os.path.join(raw, fn)
        if not os.path.exists(p):
            open(p, "wb").write(http_get(url))
            time.sleep(DELAY)
    print("fetch complete:", raw)

# --------------------------------------------------------------------------- parsing helpers

def find_template(text, name):
    """Bodies of {{name ...}} (balanced braces)."""
    out = []
    for m in re.finditer(r"\{\{\s*" + re.escape(name) + r"\s*(\||\}\})", text, re.I):
        depth, j = 0, m.start()
        while j < len(text):
            if text.startswith("{{", j):
                depth += 1; j += 2; continue
            if text.startswith("}}", j):
                depth -= 1; j += 2
                if depth == 0:
                    break
                continue
            j += 1
        out.append(text[m.start() + 2: j - 2])
    return out


def split_params(body):
    parts, depth, cur, k = [], 0, "", 0
    while k < len(body):
        two = body[k:k + 2]
        if two in ("{{", "[["):
            depth += 1; cur += two; k += 2; continue
        if two in ("}}", "]]"):
            depth -= 1; cur += two; k += 2; continue
        if body[k] == "|" and depth == 0:
            parts.append(cur); cur = ""; k += 1; continue
        cur += body[k]; k += 1
    parts.append(cur)
    params, pos = {}, 1
    for p in parts[1:]:
        if "=" in p:
            a, b = p.split("=", 1)
            params[a.strip().lower()] = b.strip()
        else:
            params[str(pos)] = p.strip(); pos += 1
    return params


def clean(v):
    if v is None:
        return None
    v = re.sub(r"\{\{\s*Infoicon\s*\|\s*([^|}]+)[^}]*\}\}", r" [\1] ", v, flags=re.I)
    v = re.sub(r"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]", r"\1", v)
    v = re.sub(r"<br\s*/?>", " / ", v)
    v = re.sub(r"<[^>]+>", "", v)
    v = re.sub(r"'{2,}", "", v)
    v = re.sub(r"\{\{[^}]*\}\}", "", v)
    return re.sub(r"\s+", " ", v).strip()


def first_int(v):
    """First number; accepts '1,350,000' / '1 350 000' thousands groups but not lists like '5, 3200'."""
    if v is None:
        return None
    m = re.search(r"\d{1,3}(?:[, ]\d{3})+(?!\d)|\d+", str(v).replace(" ", " "))
    return int(re.sub(r"[^\d]", "", m.group(0))) if m else None


def all_ints(v):
    """Small integers in a list such as '1 • 12 • 23', '2, 12', '6, 15 и 27' (levels)."""
    return [int(x) for x in re.findall(r"\d+", v or "")]


def to_seconds(v):
    """'1 d 11 h' / '1 д. 12 ч.' / '35 hrs' / '40 sec' / '10 с.' -> seconds (None if no duration)."""
    if not v:
        return None
    units = [(r"d|д", 86400), (r"hrs?|h|ч|час\w*", 3600), (r"min|мин\w*|m", 60), (r"sec|s|с|сек\w*", 1)]
    total, found = 0, False
    for m in re.finditer(r"(\d+)\s*([a-zа-я]+)", v.lower()):
        for pat, mult in units:
            if re.fullmatch(pat, m.group(2)):
                total += int(m.group(1)) * mult
                found = True
                break
    return total if found else None


def parse_size(v):
    """'3×3', '2 x 2', '2х2' (Cyrillic) -> (w, h); anything else -> None."""
    if not v:
        return None
    m = re.search(r"(\d+)\s*[x×хX]\s*(\d+)", clean(v))
    return (int(m.group(1)), int(m.group(2))) if m else None


def table_rows(table):
    rows, cur = [], None
    for line in table.split("\n"):
        s = line.strip()
        if s.startswith("{|"):
            continue
        if s.startswith("|-") or s.startswith("|}"):
            if cur:
                rows.append(cur)
            cur = []
            continue
        if s.startswith("!") or s.startswith("|"):
            cur = cur if cur is not None else []
            for c in re.split(r"\|\||!!", s[1:]):
                m = re.match(r'^\s*(?:[a-z-]+="[^"]*"\s*)+\|(?!\|)(.*)$', c)
                cur.append((m.group(1) if m else c).strip())
    if cur:
        rows.append(cur)
    return rows


def parse_lua_module(src):
    """Minimal Lua table-constructor parser for wiki data modules."""
    tok_re = re.compile(r"""
      (?P<ws>\s+) | (?P<lcomment>--\[(?P<e1>=*)\[.*?\](?P=e1)\]) | (?P<comment>--[^\n]*)
    | (?P<lstr>\[(?P<e2>=*)\[.*?\](?P=e2)\]) | (?P<str>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')
    | (?P<num>-?\d+\.?\d*(?:[eE][-+]?\d+)?) | (?P<name>[A-Za-z_][A-Za-z0-9_]*) | (?P<op>.)""", re.S | re.X)
    toks = []
    for m in tok_re.finditer(src):
        k = m.lastgroup
        if k in ("ws", "comment", "lcomment"):
            continue
        k = "lstr" if m.group("lstr") else ("str" if m.group("str") else k)
        toks.append((k, m.group(k)))
    pos = [0]

    def nxt():
        t = toks[pos[0]]; pos[0] += 1; return t

    def peek(o=0):
        return toks[pos[0] + o] if pos[0] + o < len(toks) else (None, None)

    def unesc(s):
        return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s[1:-1])

    def value():
        k, v = nxt()
        if k == "str":
            return unesc(v)
        if k == "lstr":
            return re.sub(r"^\[=*\[\n?|\]=*\]$", "", v)
        if k == "num":
            return int(v) if re.fullmatch(r"-?\d+", v) else float(v)
        if k == "name":
            return {"true": True, "false": False, "nil": None}.get(v, {"__ident__": v})
        if v == "{":
            arr, d = [], {}
            while True:
                k2, v2 = peek()
                if v2 == "}":
                    nxt(); break
                if v2 in (",", ";"):
                    nxt(); continue
                if k2 == "name" and peek(1)[1] == "=":
                    nxt(); nxt(); d[v2] = value()
                elif v2 == "[":
                    nxt(); key = value(); nxt(); nxt(); d[key] = value()
                else:
                    arr.append(value())
            if d and arr:
                d["__array__"] = arr
            return d if d else arr
        raise ValueError("unexpected token %r" % (v,))

    out = {}
    while pos[0] < len(toks):
        k, v = nxt()
        if k == "name" and peek()[1] == "=" and peek(1)[1] == "{":
            nxt(); out[v] = value()
        elif k == "name" and v == "return":
            break
    return out


def html_text(raw_html):
    t = re.sub(r"<script.*?</script>|<style.*?</style>", "", raw_html, flags=re.S)
    t = htmlmod.unescape(re.sub(r"<[^>]+>", " ", t))
    return re.sub(r"\s+", " ", t)


def norm(s):
    s = (s or "").lower().replace("’", "'").replace("&", " and ")
    s = s.replace("ö", "o").replace("é", "e").replace("è", "e")
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def compact(s):
    return norm(s).replace(" ", "")

# --------------------------------------------------------------------------- source loaders

class Wiki:
    def __init__(self, d, base_url):
        self.d, self.base_url = d, base_url
        p = os.path.join(d, "_index.json")
        self.idx = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}

    def text(self, title):
        v = self.idx.get(title)
        if not v or v.get("missing"):
            return None
        return open(os.path.join(self.d, v["file"]), encoding="utf-8").read()

    def infobox(self, title, name="Infobox"):
        t = self.text(title)
        if not t:
            return None
        b = find_template(t, name)
        return split_params(b[0]) if b else None

    def url(self, title):
        return self.base_url + urllib.parse.quote(title.replace(" ", "_"), safe="/():'&,")


def load_sources(raw):
    S = {}
    S["en"] = Wiki(os.path.join(raw, "en"), "https://hayday.fandom.com/wiki/")
    S["ru"] = Wiki(os.path.join(raw, "ru"), "https://hayday.fandom.com/ru/wiki/")
    S["de"] = Wiki(os.path.join(raw, "de"), "https://hayday.fandom.com/de/wiki/")
    mods = Wiki(os.path.join(raw, "ru_modules"), "https://hayday.fandom.com/ru/wiki/")
    S["ru_mod_url"] = mods.url
    S["decos"] = parse_lua_module(mods.text("Модуль:Все украшения"))["all"]
    S["trees"] = parse_lua_module(mods.text("Модуль:Все деревья и кусты"))["all"]
    S["names"] = parse_lua_module(mods.text("Модуль:Названия на разных языках"))["all"]
    S["ss_prod"] = html_text(open(os.path.join(raw, "ss_production.html"), encoding="utf-8", errors="replace").read())
    S["ss_trees"] = html_text(open(os.path.join(raw, "ss_trees.html"), encoding="utf-8", errors="replace").read())
    return S

# --------------------------------------------------------------------------- record helpers

VERIFIED = "2026-11-09"


def rec(name, wiki_page, category, footprint, unlock_level, coins=None, diamonds=None, other=None,
        max_count=None, rotatable=None, source=None, confidence="unverified", notes=""):
    return {"name": name, "wiki_page": wiki_page, "category": category,
            "footprint": {"w": footprint[0], "h": footprint[1]} if footprint else None,
            "unlock_level": unlock_level,
            "cost": {"coins": coins, "diamonds": diamonds, "other": other},
            "max_count": max_count, "rotatable": rotatable, "source": source,
            "confidence": confidence, "notes": notes.strip("; ")}


def reconcile_fp(cands):
    """cands: [(family, label, (w,h)|None)] in priority order -> (fp, confidence, note)."""
    vals = [(f, l, v) for f, l, v in cands if v]
    if not vals:
        return None, "unverified", "footprint not stated by any source"
    fp = vals[0][2]
    notes, families, conflict = [], set(), False
    for f, l, v in vals:
        if v == fp:
            families.add(f)
        elif sorted(v) == sorted(fp):
            families.add(f); notes.append("%s gives %dx%d (same footprint, other orientation)" % (l, v[0], v[1]))
        else:
            conflict = True; notes.append("CONFLICT: %s gives %dx%d" % (l, v[0], v[1]))
    for f, l, v in cands:
        if not v:
            notes.append("%s: size not stated" % l)
    if conflict:
        conf = "unverified"
    elif len(families & {"en", "ru"}) >= 2:
        conf = "confirmed"
    else:
        conf = "community"
    return fp, conf, "; ".join(notes)


def compare(label_vals, what):
    """Return note listing disagreeing values (first non-None is primary)."""
    vals = [(l, v) for l, v in label_vals if v is not None]
    if len({v for _, v in vals}) <= 1:
        return ""
    return "%s differs: %s" % (what, ", ".join("%s=%s" % (l, v) for l, v in vals))

# --------------------------------------------------------------------------- production buildings

PROD_RU = {
    "Feed Mill": "Дробилка", "Bakery": "Пекарня", "Dairy": "Молокозавод", "Sugar Mill": "Сахарный завод",
    "Popcorn Pot": "Попкорница", "BBQ Grill": "Гриль", "Pie Oven": "Печь для пирогов", "Loom": "Ткацкий станок",
    "Sewing Machine": "Швейная машинка", "Cake Oven": "Печь для тортов", "Mine": "Рудник", "Smelter": "Плавильня",
    "Juice Press": "Соковыжималка", "Lure Workbench": "Станок для приманок", "Ice Cream Maker": "Мороженица",
    "Net Maker": "Вязальщик сетей", "Döner Kebab Stand": "Киоск для шаурмы", "Jam Maker": "Вареньеварка",
    "Jeweler": "Ювелир", "Honey Extractor": "Медогонка", "Coffee Kiosk": "Кофейный киоск",
    "Lobster Pool": "Бассейн с раками", "Soup Kitchen": "Суповая кухня", "Candle Maker": "Свечник",
    "Flower Shop": "Цветочный магазин", "Duck Salon": "Утиный салон", "Candy Machine": "Конфетный автомат",
    "Sauce Maker": "Соусоварня", "Sushi Bar": "Суши-бар", "Salad Bar": "Салатный бар",
    "Sandwich Bar": "Бутербродная", "Smoothie Mixer": "Смузи-машина", "Pasta Maker": "Машинка для лапши",
    "Essential Oils Lab": "Лаборатория масел", "Wok Kitchen": "Вок-кухня", "Hat Maker": "Шляпник",
    "Pasta Kitchen": "Макаронная кухня", "Hot Dog Stand": "Киоск для хот-догов", "Donut Maker": "Пончиковая",
    "Taco Kitchen": "Тако-кухня", "Omelet Station": "Омлетница", "Tea Stand": "Чайная", "Fondue Pot": "Фондюшница",
    "Bath Kiosk": "Мыловарня", "Deep Fryer": "Фритюрница", "Preservation Station": "Консервный завод",
    "Pottery Studio": "Гончарная печь", "Fudge Shop": "Магазин ириса", "Yogurt Maker": "Йогуртница",
    "Stew Pot": "Рагушница", "Cupcake Maker": "Кондитерская", "Perfumerie": "Парфюмерная лавка",
    "Waffle Maker": "Вафельница", "Porridge Bar": "Кашеварня", "Milkshake Bar": "Милкшейк-бар",
    "Gift Wrapping Station": "Стол для упаковки подарков", "Easter Egg Maker": "Стол для украшения яиц",
    "Halloween Treats Maker": "Хеллоуинский конфетный автомат", "Birthday Balloon Maker": "Машина для воздушных шаров",
}
FIXED_PROD = {"Mine", "Lure Workbench", "Net Maker", "Lobster Pool", "Duck Salon"}  # en wiki: cannot be moved or rotated
LAKE_PROD = {"Lure Workbench", "Net Maker", "Lobster Pool", "Duck Salon"}           # en Category:Fishing Lake Buildings
TEMP_PROD = ["Gift Wrapping Station", "Easter Egg Maker", "Halloween Treats Maker", "Birthday Balloon Maker",
             "Enchanted Workshop"]


def parse_prod_list(text):
    table = re.search(r"\{\|.*?\n\|\}", text, re.S).group(0)
    out = []
    for r in table_rows(table):
        if r and "'''[[" in r[0]:
            m = re.search(r"\[\[([^|\]]+)(?:\|([^\]]+))?\]\]", r[0])
            v = r[1:] + [""] * 5
            out.append({"page": m.group(1), "levels": [v[0]], "prices": [v[1]], "time": clean(v[2]),
                        "xp": clean(v[3]), "size": clean(v[4])})
        elif out and r and not r[0].startswith("!") and "scope=" not in r[0]:
            if len(r) == 2:
                out[-1]["levels"].append(r[0]); out[-1]["prices"].append(r[1])
            elif len(r) == 1:
                out[-1]["prices"].append(r[0])
    return out


def parse_ss_prod(text):
    out = {}
    for m in re.finditer(r"LV ([\d /]+?) ([A-Z][A-Za-z' ]+?) (\d+) (\d+)xp ⏱ (.+?) Size: (\S+)", text):
        out[norm(m.group(2))] = {"level": first_int(m.group(1)), "levels": all_ints(m.group(1)),
                                 "price": int(m.group(3)), "xp": int(m.group(4)), "time": m.group(5).strip(),
                                 "size": parse_size(m.group(6))}
    return out


def build_production(S, stats):
    en, ru = S["en"], S["ru"]
    ss = parse_ss_prod(S["ss_prod"])
    rows = parse_prod_list(en.text("Production Buildings List"))
    out = []
    for b in rows + [{"page": t, "levels": [], "prices": [], "time": None, "xp": None, "size": None, "temp": True}
                     for t in TEMP_PROD]:
        page = b["page"]
        ib = en.infobox(page) or {}
        ru_title = PROD_RU.get(page)
        rib = ru.infobox(ru_title, "Инфбокс") if ru_title else None
        rib = rib or {}
        s = ss.get(norm(page)) or ss.get(norm(page.replace("Döner", "Doner"))) or {}
        fp, conf, fpnote = reconcile_fp([
            ("en", "en infobox", parse_size(ib.get("size"))),
            ("en", "en list", parse_size(b.get("size"))),
            ("ru", "ru infobox", parse_size(rib.get("размер"))),
            ("ss", "shootingspeed", s.get("size")),
        ])
        lv_en = first_int(clean(ib.get("level"))) if ib.get("level") else None
        lv_list = first_int(b["levels"][0]) if b["levels"] else None
        lv_ru = first_int(clean(rib.get("уровень"))) if rib.get("уровень") else None
        level = next((x for x in (lv_en, lv_list, lv_ru) if x is not None), None)
        pr_en = first_int(clean(ib.get("price"))) if ib.get("price") else None
        pr_list = first_int(b["prices"][0]) if b["prices"] and first_int(b["prices"][0]) is not None else None
        pr_ru = first_int(clean(rib.get("цена"))) if rib.get("цена") else None
        coins = next((x for x in (pr_en, pr_list, pr_ru) if x is not None), None)
        notes = []
        if page in LAKE_PROD:
            notes.append("located at the Fishing Lake, not on the farm grid")
        if page in FIXED_PROD:
            notes.append("en wiki: cannot be moved or rotated (fixed position)")
        if b.get("temp"):
            notes.append("temporary/seasonal event machine (en Production Buildings: Temporary buildings)")
        count = max(len(b["prices"]), len(b["levels"])) if b["prices"] else 1
        if count > 1:
            per = []
            lvls = [first_int(x) for x in b["levels"]] + [None] * count
            for i, p in enumerate(b["prices"]):
                per.append("#%d: L%s, %s coins" % (i + 1, lvls[i] if lvls[i] is not None else lvls[0], first_int(clean(p))))
            notes.append("instances: " + ", ".join(per))
        tm = clean(ib.get("time")) or b.get("time")
        if tm:
            notes.append("build_time=" + tm)
        xp = clean(ib.get("xp")) or b.get("xp")
        if xp and xp != "N/A":
            notes.append("build_xp=" + xp)
        if ib.get("slots"):
            notes.append("start_slots=" + clean(ib["slots"]))
        if ib.get("dia"):
            notes.append("skip_build_diamonds=" + clean(ib["dia"]))
        for n in (fpnote,
                  compare([("en infobox", lv_en), ("en list", lv_list), ("ru", lv_ru), ("shootingspeed", s.get("level"))], "unlock level"),
                  compare([("en infobox", pr_en), ("en list", pr_list), ("ru", pr_ru), ("shootingspeed", s.get("price"))], "coin cost")):
            if n:
                notes.append(n)
        tnote = compare([("en infobox", to_seconds(clean(ib.get("time")))), ("en list", to_seconds(b.get("time"))),
                         ("ru", to_seconds(clean(rib.get("время")))), ("shootingspeed", to_seconds(s.get("time")))],
                        "build time (seconds)")
        if tnote:
            notes.append(tnote)
        if not ru_title or not rib:
            notes.append("no ru-wiki infobox found")
        rotatable = False if page in FIXED_PROD else True
        if page not in FIXED_PROD:
            notes.append("rotatable: en Decorations page says most buildings can be moved/stored/rotated")
        out.append(rec(page, page, "production", fp, level, coins=coins,
                       other="free" if page == "Lure Workbench" else None,
                       max_count=count, rotatable=rotatable, source=en.url(page), confidence=conf,
                       notes="; ".join(notes)))
    stats["production_rows_in_en_list"] = len(rows)
    return out

# --------------------------------------------------------------------------- farm / core buildings

FARM_BUILDINGS = [
    # name, en page, level, coins, notes
    ("Farmhouse", "Farmhouse", None, None, "pre-placed at game start; achievements from L6; customization from L31"),
    ("Barn", "Barn", 1, None, "pre-placed; repaired in tutorial; storage capacity upgrades with supplies"),
    ("Silo", "Silo", 1, None, "pre-placed; repaired in tutorial; crop storage"),
    ("Truck and order board", "Truck", 3, None, "truck parked next to the order board near the farmhouse; unlocked L3"),
    ("Roadside Shop", "Roadside Shop", 7, None, "unlocked L7; does not need to be repaired or bought"),
    ("Mailbox (newspaper / neighborhood / letters)", "Mailbox", 7, None,
     "newspaper mailbox L7, neighborhood mailbox L10, letter mailbox L15"),
    ("Newspaper (Daily Dirt)", "Daily Dirt", 7, None, "read via the newspaper mailbox; unlocked L7"),
    ("Wheel of Fortune truck", "Wheel of Fortune", 8, None, "unlocked L8"),
    ("Event board", "Events", 9, None, "events unlocked L9"),
    ("Neighborhood house", "Neighborhood", 10, 200, "repair 200 coins, 1 min (or 10 diamonds); unlocked L10"),
    ("Riverboat dock", "Boat", 17, 7000, "repair 7,000 coins, 2 min; 27 XP; unlocked L17"),
    ("Derby stand", "Derby", 18, None, "derbies from L18; unlocks with the neighborhood house"),
    ("Valley board", "Valley", 25, None, "valley unlocked L25 (no coin cost)"),
    ("Fishing boat", "Fishing Lake", 27, 10000, "repair 10,000 coins, 5 min; 47 XP; gateway to the Fishing Lake"),
    ("Tackle Box", "Tackle Box", 27, None, "Fishing Lake storage; already standing, no repair"),
    ("Helpers' House", "Helpers' House", 33, None, "unlocked L33"),
    ("Train station (farm)", "Train Station", 34, 20000, "repair 20,000 coins, 5 min; 39 XP; gateway to the town"),
    ("Leaderboard", "Leaderboard", None, None, "boat leaderboard sign on the farm"),
]


def build_farm(S):
    en = S["en"]
    out = []
    for name, page, lvl, coins, note in FARM_BUILDINGS:
        out.append(rec(name, page, "farm_building", None, lvl, coins=coins, max_count=1, rotatable=None,
                       source=en.url(page), confidence="unverified",
                       notes=note + "; footprint not stated by any source; movability not documented"))
    return out

# --------------------------------------------------------------------------- animal homes

HOME_RU = {"Chicken Coop": "Курятник", "Cow Pasture": "Пастбище для коров", "Pig Pen": "Свинарник",
           "Sheep Pasture": "Пастбище для овец", "Lamb Pasture": "Пастбище для ягнят", "Goat Yard": "Загон для коз",
           "Beehive Tree": "Дерево с ульем", "Squirrel House": "Беличье дерево"}


def shelter_counts(text):
    """From en 'Animal Shelters' page: '3 houses unlocked at level 1,12,23' rows aligned to names."""
    out = {}
    for t in re.findall(r"\{\|.*?\n\|\}", text or "", re.S):
        names = None
        for r in table_rows(t):
            if all(c.startswith("[[") and "File:" not in c for c in r if c):
                names = [clean(c) for c in r]
            elif names and any("unlocked at level" in c.lower() for c in r):
                for n, c in zip(names, r):
                    out[n] = clean(c)
                names = None
    return out


def build_animal_homes(S):
    en, ru = S["en"], S["ru"]
    pages = [t for t in json.load(open(os.path.join(os.path.dirname(en.d), "en_categories.json")))["Animal Shelters"]
             if t != "Animal Shelters"]
    counts = shelter_counts(en.text("Animal Shelters"))
    out = []
    for page in pages:
        ib = en.infobox(page) or {}
        lv_txt = clean(ib.get("level") or "")
        lv = all_ints(lv_txt)
        rib = ru.infobox(HOME_RU[page], "Инфбокс") if page in HOME_RU else None
        rib = rib or {}
        fp, conf, fpnote = reconcile_fp([("ru", "ru infobox", parse_size(rib.get("размер")))])
        notes = []
        cnt_txt = counts.get(page)
        m = re.match(r"(\d+) houses?", cnt_txt or "")
        max_count = int(m.group(1)) if m else (1 if "Unlocked at level" in (cnt_txt or "") else (len(lv) or None))
        if cnt_txt:
            notes.append("en Animal Shelters: " + cnt_txt)
            lv2 = all_ints(cnt_txt.split("level")[-1]) if "level" in cnt_txt else []
            if lv2 and lv and lv2 != lv:
                notes.append("unlock levels differ: infobox %s vs shelter table %s" % (lv, lv2))
        if len(lv) > 1:
            notes.append("one more house unlocks at each level " + ", ".join(map(str, lv)))
        houses = clean(ib.get("houses") or "")
        cap = re.search(r"x(\d+)", houses)
        if cap:
            notes.append("capacity=%s animals" % cap.group(1))
        price_en = first_int(clean(ib.get("price"))) if ib.get("price") else None
        price_ru = first_int(clean(rib.get("цена"))) if rib.get("цена") else None
        c = compare([("en", price_en), ("ru", price_ru)], "coin cost")
        if c:
            notes.append(c)
        lv_ru = all_ints(clean(rib.get("уровень") or ""))
        if lv_ru and lv and lv_ru != lv:
            notes.append("ru unlock levels %s" % lv_ru)
        if fpnote:
            notes.append(fpnote)
        if not fp:
            notes.append("no size in en or ru wiki")
        notes.append("rotatable: en Decorations page says most buildings and animal shelters can be moved/stored/rotated")
        out.append(rec(page, page, "animal_home", fp, lv[0] if lv else None, coins=price_en if price_en is not None else price_ru,
                       max_count=max_count, rotatable=True, source=en.url(page),
                       confidence=conf, notes="; ".join(notes)))
    return out

# --------------------------------------------------------------------------- fields, trees, bushes

def build_field(S):
    de = S["de"]
    return [rec("Field", "Farm", "field", None, 1, coins=1, max_count=None, rotatable=True,
                source=S["en"].url("Farm"), confidence="unverified",
                notes="footprint not stated by en/ru/de wiki (ru wiki gives trees 1x1 and fences/paths 1x1 in the same "
                      "unit, but no source states a field's size); cost 1 coin each per de wiki (" + de.url("Feld") + "); "
                      "count is level-gated: 6 at start, +3 every 2nd level until L49, +2 until L99, then +1 "
                      "(ru wiki: from L701 every 4 levels, from L801 every 10; max 473 at L1000); "
                      "en Farm page: 'Both [fields and trees/bushes] can be rotated'; no limit on fields owned beyond level gate")]


def parse_ss_trees(text):
    out = {}
    for m in re.finditer(r"([A-Z][A-Za-z ]+?(?:Tree|Bush)) Level: (\d+) Price: (\d+) Time: (.+?) Fruit:", text):
        out[norm(m.group(1))] = {"level": int(m.group(2)), "price": int(m.group(3)), "time": m.group(4)}
    return out


def build_trees(S):
    en = S["en"]
    ss = parse_ss_trees(S["ss_trees"])
    ru = {t["id"]: t for t in S["trees"]}
    pages = [t for t in json.load(open(os.path.join(os.path.dirname(en.d), "en_categories.json")))["Trees and Bushes"]
             if t != "Trees and Bushes"]
    out = []
    for page in pages:
        ib = en.infobox(page) or {}
        r = ru.get(page.replace(" ", ""))
        fp, conf, fpnote = reconcile_fp([("ru", "ru module", tuple(r["size"]) if r else None)])
        lv = first_int(ib.get("level"))
        price = first_int(clean(ib.get("price") or ""))
        s = ss.get(norm(page), {})
        notes = []
        for n in (compare([("en", lv), ("shootingspeed", s.get("level"))], "unlock level"),
                  compare([("en", price), ("ru", r.get("price") if r else None), ("shootingspeed", s.get("price"))], "coin cost")):
            if n:
                notes.append(n)
        t = clean(ib.get("time") or "")
        if t:
            notes.append("harvest_interval=" + t)
        if r:
            notes.append("ru: type=%s, interval=%s min, game_id=%s" % (
                {"Дерево": "tree", "Куст": "bush", "Пальма": "palm"}.get(r["tip"], r["tip"]), r["vrema"], r["id"]))
        if fpnote:
            notes.append(fpnote)
        if page in ("Nectar Bush", "Peanut Bush"):
            notes.append("feeds bees/squirrels (" + ("Beehive Tree" if page == "Nectar Bush" else "Squirrel House") + ")")
        notes.append("rotatable: App Store release notes + en Farm page")
        cat = "bush" if "Bush" in page else "fruit_tree"
        out.append(rec(page, page, cat, fp, lv, coins=price, max_count=None, rotatable=True,
                       source=en.url(page), confidence=conf, notes="; ".join(notes)))
    return out

# --------------------------------------------------------------------------- decorations

CUR = {"Монеты": "coins", "Алмазы": "diamonds", "Зелёный": "green voucher", "Фиолетовый": "purple voucher",
       "Голубой": "blue voucher", "Золотой": "gold voucher", "Фотоплёнка": "film (event currency)",
       "Ключи": "golden keys"}
THEME = {"Christmas": "Christmas", "Halloween": "Halloween", "ChineseNewYear": "Lunar New Year",
         "Valentines": "Valentine's Day", "Easter": "Easter", "NewYear": "New Year", "Summer": "Summer",
         "Winter": "Winter", "Ramadan": "Ramadan"}
DESC_SEASON = {"Делает праздники ярче": "Christmas/holidays", "Хеллоуинское украшение": "Halloween",
               "Пасхальное украшение": "Easter", "Зимнее украшение": "Winter",
               "Украшения к китайскому Новому году": "Lunar New Year", "Новогоднее украшение": "New Year",
               "Осеннее украшение": "Autumn"}
SRC = [("Магазин валют", "currency-shop offer"), ("Магазин", "shop"), ("Farm Pass", "Farm Pass"),
       ("События с особой валютой", "special-currency event"), ("Скачки", "derby"),
       ("Глобальные события", "global event"), ("События с заданиями", "task event"), ("Долина", "valley"),
       ("Ночь в кино", "movie night (ads)"), ("Тематический ящик", "themed box"), ("Расширение", "expansion plot"),
       ("Каталог", "catalogue"), ("Колесо фортуны", "Wheel of Fortune"), ("Окружная ярмарка", "county fair"),
       ("Набор украшений", "decoration set"), ("Конкурс проектов", "design contest"), ("Коллекции", "collection"),
       ("Ежемесячные украшения", "monthly decoration"), ("Подарок", "gift"), ("Ящик", "box"),
       ("Сундуки", "decoration chest"), ("Событие", "event"), ("Особое", "special")]
WATER = re.compile(r"(?i)\b(ponds?|fountains?|pool|lake|canal|river|waterfall|creek|ditch|lagoon|well|puddle|"
                   r"aquarium|moat|brook|stream|hot spring|watering hole|water wheel|watermill|bird bath|bath)\b")
FLOWER = re.compile(r"(?i)(flower|tulip|\broses?\b|dais(y|ies)|lupine|dahlia|hydrangea|daffodil|\blil(y|ies)\b|"
                    r"sunflower|popp(y|ies)|bouquet|orchid|peon(y|ies)|lavender|blossom|petunia|violet|\biris\b|"
                    r"marigold|camellia|crocus|hyacinth|geranium|magnolia|lotus|azalea|wisteria|zinnia|planter)")
FLOWER_NOT = re.compile(r"(?i)\b(girl|seller|painting|truck|goat|gnome|boots|cart|wagon|crown|shrine|gate|arch|"
                        r"bridge|pagoda|shelf|stand|crate|key|balloons?|basket|eggs?|bulbs|shoes|tire|heart|"
                        r"bathtub|hunt|surprise|topiary|tree|bucket)\b")
EN_ALIAS = {  # en-wiki list spelling -> in-game English name used by the ru names module
    "blue flower bouquet": "blue flower bucket", "yellow flower bouquet": "yellow flower bucket",
    "pineapple lilies": "pineapple lily", "african lilly": "african lily", "golden placard": "gold placard",
    "hay bales and guitar": "hay and guitar", "miners lunch": "miner s lunch", "birthday toipary": "birthday topiary",
    "bubbling caldron": "bubbling cauldron", "halloween alter": "halloween altar", "snow loyalty": "snow royalty",
    "pinwheels": "pinwheel", "bee lighting": "bee lights", "sugar skull alter": "sugar skull altar",
    "busy market": "busy marketplace", "colourful hut": "colorful hut", "bean bonanza": "bean bananza",
    "prized pig painting statue": "prized pig painting", "chinese lantern flowers": "chinese lantern flower",
}


def parse_en_deco_pages(en):
    items = []
    for title in sorted(t for t in en.idx if t.startswith("Decorations/")):
        text = en.text(title)
        if not text:
            continue
        section = None
        for tok in re.split(r"(\{\|.*?\n\|\}|<gallery[^>]*>.*?</gallery>|^=+[^=\n]+=+\s*$)", text, flags=re.S | re.M):
            if not tok:
                continue
            h = re.match(r"^=+\s*(.*?)\s*=+\s*$", tok.strip())
            if h and "\n" not in tok.strip():
                section = clean(h.group(1)); continue
            if tok.startswith("<gallery"):
                for line in tok.split("\n")[1:]:
                    line = line.strip()
                    if not line or line.startswith("</"):
                        continue
                    parts = line.split("|")
                    cap = clean(parts[-1]) if len(parts) > 1 else re.sub(r"^(File:)?(.*)\.\w+$", r"\2", parts[0])
                    m = re.match(r"^(.*?)\s*(?:x(\d+))?\s*(?:\((.*)\))?$", cap)
                    items.append({"page": title, "section": section, "name": m.group(1).replace("★", "").strip(),
                                  "level": None, "cost": None, "detail": m.group(3)})
            elif tok.startswith("{|"):
                block = None
                for r in table_rows(tok):
                    ne = [c for c in r if c]
                    if not ne:
                        continue
                    if all(c.startswith("[[File:") and re.search(r"\|\s*(90|100|125)px", c) for c in ne):
                        block = {}; continue
                    if all(c.startswith("'''") for c in ne):
                        block = {"name": r}; continue
                    if block is None or "name" not in block:
                        continue
                    if all(re.match(r"^(Lvl|Level)\s*\d+", c) for c in ne):
                        block["level"] = r; continue
                    if all(c.startswith("[[File:") for c in ne):
                        block["animal"] = r; continue
                    for i, nm in enumerate(block["name"]):
                        nm = clean(nm)
                        if not nm:
                            continue
                        lvl = first_int(block.get("level", [""] * 9)[i]) if i < len(block.get("level", [])) else None
                        items.append({"page": title, "section": section, "name": nm.replace("★", "").strip(),
                                      "level": lvl, "cost": clean(r[i]) if i < len(r) else None, "detail": None})
                    block = None
    return items


def en_cost(c):
    """'5 [coin] +2 per purchase' -> (coins, diamonds, other)."""
    if not c:
        return None, None, None
    m = re.match(r"^([\d,]+) \[coin\]\s*(?:\+\s*([\d,]+) per purchase)?", c)
    if m:
        return int(m.group(1).replace(",", "")), None, ("+%s coins per additional purchase" % m.group(2) if m.group(2) else None)
    m = re.match(r"^([\d,]+) \[dia\]", c)
    if m:
        return None, int(m.group(1).replace(",", "")), None
    v = re.findall(r"([\d,]+) \[(\w+)\]", c)
    names = {"bluev": "blue voucher", "greenv": "green voucher", "purplev": "purple voucher", "goldv": "gold voucher"}
    return None, None, " + ".join("%s %s" % (n, names.get(k, k)) for n, k in v) or c


def deco_category(name, x, en_page=None):
    t = (x or {}).get("type")
    desc = (x or {}).get("desc", "")
    nm = name or ""
    if t == "Забор" or "ограда" in desc or "живая изгородь" in desc:
        return "decoration_fence"
    if t == "Дорожка" or "дорожка" in desc:
        return "decoration_path"
    if t == "Ров":
        if re.search(r"(?i)fence", nm):
            return "decoration_fence"
        if re.search(r"(?i)ditch|canal|creek", nm):
            return "decoration_water"
        return "decoration_path"
    if en_page == "Decorations/Fences & Paths":
        return "decoration_path" if re.search(r"(?i)path|road|trail", nm) else (
            "decoration_water" if re.search(r"(?i)ditch", nm) else "decoration_fence")
    if WATER.search(nm) and not re.search(r"(?i)water (tower|pump)", nm):
        return "decoration_water"
    season = THEME.get((x or {}).get("theme")) or DESC_SEASON.get(desc.rstrip(".")) or (
        "seasonal list" if en_page == "Decorations/Seasonal" else None)
    if season:
        return "decoration_seasonal"
    if FLOWER.search(nm) and not FLOWER_NOT.search(nm):
        return "decoration_flower"
    return "decoration_other"


def ru_cost(x):
    price, cur = x.get("price") or [], x.get("cur") or []
    if not price or not cur:
        return None, None, "no price in source (reward/prize item)"
    if cur == ["Монеты"]:
        return price[0], None, ("+%d coins per additional purchase" % price[1] if len(price) > 1 else None)
    if cur == ["Алмазы"]:
        if price[0] == 999:
            return None, None, "not sold in shop (source lists 999-diamond placeholder)"
        return None, price[0], None
    parts = ["%s %s" % (p, CUR.get(c, c)) for p, c in zip(price, cur)]
    return None, None, " + ".join(parts)


def match_en_to_ru(en_items, decos, names):
    """Assign each en-wiki list entry to at most one ru-module decoration.
    Order: in-game English name (names module, with EN_ALIAS spelling fixes) -> internal game id ->
    valley season number. Among several candidates prefer non-prize, then shop-sold items."""
    by_name, by_id, by_season = defaultdict(list), defaultdict(list), defaultdict(list)
    for i, x in enumerate(decos):
        e = names.get(x["name"], {}).get("en")
        if e:
            by_name[norm(e)].append(i)
        if x.get("id"):
            by_id[compact(x["id"])].append(i)
        for s in x.get("sources") or []:
            m = re.match(r"Долина\|(\d+) сезон", s)
            if m:
                by_season[int(m.group(1))].append(i)
    assign = {}
    for k, e in enumerate(en_items):
        key = EN_ALIAS.get(norm(e["name"]), norm(e["name"]))
        cand, how = by_name.get(key, []), "name"
        if not cand:
            cand, how = by_id.get(compact(key), []), "game id"
        if not cand and e["page"].endswith("Valley"):
            m = re.match(r"season (\d+)", e.get("detail") or "")
            if m and len(by_season.get(int(m.group(1)), [])) == 1:
                cand, how = by_season[int(m.group(1))], "valley season"
        if not cand:
            continue
        def score(i):
            x = decos[i]
            shop = any(s == "Магазин" or s.startswith("Магазин#") for s in x.get("sources") or [])
            return (("(приз)" in x["name"]), not (shop and (e["level"] is not None or e["cost"])))
        assign[k] = (sorted(cand, key=score)[0], how)
    return assign


def build_decorations(S, stats):
    en, names, decos = S["en"], S["names"], S["decos"]
    en_items = parse_en_deco_pages(en)
    assign = match_en_to_ru(en_items, decos, names)
    per_ru = defaultdict(list)
    for k, (i, how) in assign.items():
        per_ru[i].append((en_items[k], how))
    out, disc = [], Counter()
    for i, x in enumerate(decos):
        matches = per_ru.get(i, [])
        en_name = names.get(x["name"], {}).get("en")
        name_note = None
        if not en_name:
            if matches:
                en_name = matches[0][0]["name"]
                name_note = "English name from en-wiki list (matched by %s)" % matches[0][1]
            elif x.get("id"):
                en_name, name_note = x["id"], "English name unavailable; using internal game id"
            else:
                en_name, name_note = x["name"], "English name unavailable; Russian in-game name"
        en_name = re.sub(r"\s+", " ", en_name).strip()
        e0 = next((m for m, _ in matches if m["level"] is not None or m["cost"]), matches[0][0] if matches else None)
        size = tuple(x["size"]) if x.get("size") else None
        coins, dia, other = ru_cost(x)
        lvl = x.get("level")
        notes = []
        if name_note:
            notes.append(name_note)
        if "(приз)" in x["name"]:
            notes.append("collection-prize variant")
        if x.get("id"):
            notes.append("game_id=" + x["id"])
        if lvl == 0:
            notes.append("ru level=0 (town decoration / no farm level gate)")
            lvl = None
        elif lvl == 1 and other and ("placeholder" in other or "no price" in other):
            notes.append("level 1 = no level gate recorded (non-shop item)")
        if x.get("rep"):
            notes.append("requires reputation level %s" % x["rep"])
        if x.get("wild_animal"):
            notes.append("unlocked by sanctuary animal: " + (names.get(x["wild_animal"], {}).get("en") or x["wild_animal"]))
        season = THEME.get(x.get("theme")) or DESC_SEASON.get((x.get("desc") or "").rstrip("."))
        if season:
            notes.append("seasonal=" + season)
        if (x.get("desc") or "").startswith("Соедини части"):
            notes.append("connectable piece (auto-joins neighbours)")
        if (x.get("desc") or "").startswith("Украшение для города"):
            notes.append("town decoration")
        if "special" in (x.get("tags") or []):
            notes.append("reward/special decoration")
        if "sanctuary" in (x.get("tags") or []):
            notes.append("sanctuary tab")
        srcs = []
        for s in x.get("sources") or []:
            lab = next((v for k, v in SRC if s.startswith(k)), "other")
            if lab not in srcs:
                srcs.append(lab)
        if srcs:
            notes.append("obtained via: " + ", ".join(srcs))
        if x.get("game_version"):
            gv = x["game_version"]
            for a, b in (("Весеннее", "Spring"), ("Летнее", "Summer"), ("Осеннее", "Autumn"), ("Зимнее", "Winter"),
                         ("обновление", "update")):
                gv = gv.replace(a, b)
            notes.append("added: " + gv)
        if e0:
            ec, ed, eo = en_cost(e0["cost"])
            pages = sorted({m["page"].split("/")[-1] for m, _ in matches})
            notes.append("en list: " + "/".join(pages) + (" L%s" % e0["level"] if e0["level"] else "") +
                         (" cost '%s'" % e0["cost"] if e0["cost"] else ""))
            if e0["name"] and norm(e0["name"]) != norm(en_name):
                notes.append("en wiki spells it '%s'" % e0["name"])
            if e0["level"] is not None and x.get("level") not in (None, e0["level"]):
                notes.append("unlock level differs: ru=%s en=%s" % (x.get("level"), e0["level"])); disc["level"] += 1
            if ec is not None and coins is not None and ec != coins:
                notes.append("coin cost differs: ru=%s en=%s" % (coins, ec)); disc["coins"] += 1
            if ed is not None and dia is not None and ed != dia:
                notes.append("diamond cost differs: ru=%s en=%s" % (dia, ed)); disc["diamonds"] += 1
        conf = "community" if size else "unverified"
        en_page_title = e0["page"] if e0 else None
        for t in dict.fromkeys((en_name, en_name.capitalize(), en_name.title())):
            ib = en.infobox(t) if t in en.idx else None
            if ib and ib.get("size"):  # standalone en page with a size (Garden Tent, Green future)
                fp, conf, fn = reconcile_fp([("ru", "ru module", size), ("en", "en infobox", parse_size(ib["size"]))])
                if fn:
                    notes.append(fn)
                en_page_title = t
                break
        cat = deco_category(en_name, x, e0["page"] if e0 else None)
        out.append(rec(en_name, en_page_title or ("ru:" + x["name"]), cat, size, lvl, coins=coins, diamonds=dia,
                       other=other, max_count=None, rotatable=True, source=S["ru"].url(x["name"]),
                       confidence=conf, notes="; ".join(notes)))
    # en-wiki list entries with no ru counterpart (footprint unknown)
    seen, extra = set(), 0
    for k, e in enumerate(en_items):
        key = norm(e["name"])
        if k in assign or key in seen or not key:
            continue
        seen.add(key)
        ec, ed, eo = en_cost(e["cost"])
        notes = ["not found in ru-wiki decoration module; footprint unknown",
                 "en list: " + e["page"].split("/")[-1] + (" / " + e["section"] if e["section"] else "")]
        if e.get("detail"):
            notes.append("detail: " + e["detail"].split("|")[-1])
        out.append(rec(e["name"], e["page"], deco_category(e["name"], None, e["page"]), None, e["level"],
                       coins=ec, diamonds=ed, other=eo, rotatable=True, source=en.url(e["page"]),
                       confidence="unverified", notes="; ".join(notes)))
        extra += 1
    # make names unique (prize variants and same-named different items)
    nkey = lambda n: re.sub(r"\s+", " ", n.casefold()).strip()
    cnt = Counter(nkey(r["name"]) for r in out)
    for r, x in zip(out, decos):
        if cnt[nkey(r["name"])] > 1:
            if "(приз)" in x["name"]:
                r["name"] += " (collection prize)"
            elif x.get("id") and compact(x["id"]) != compact(r["name"]):
                r["name"] += " [%s]" % x["id"]
    cnt2 = Counter(nkey(r["name"]) for r in out)
    for r, x in zip(out, decos):
        if cnt2[nkey(r["name"])] > 1 and not r["name"].endswith(")"):
            r["name"] += " [ru: %s]" % x["name"]
    stats["deco_ru_module"] = len(decos)
    stats["deco_en_list_entries"] = len(en_items)
    stats["deco_en_entries_matched"] = len(assign)
    stats["deco_en_match_methods"] = dict(Counter(h for _, h in assign.values()))
    stats["deco_en_only_added"] = extra
    stats["deco_discrepancies_en_vs_ru"] = dict(disc)
    stats["deco_duplicate_names_after_dedupe"] = sum(1 for v in Counter(nkey(r["name"]) for r in out).values() if v > 1)
    return out

# --------------------------------------------------------------------------- scenery

def build_scenery(S):
    en = S["en"]
    rows = [("Small decorative tree (leaf/pine)", "Axe", "removed with an axe; also decorative bushes"),
            ("Big decorative tree (leaf/pine)", "Saw", "removed with a saw"),
            ("Small rock", "Dynamite", "blown up with dynamite"),
            ("Rock cluster", "TNT Barrel", "blown up with a TNT barrel"),
            ("Pond (natural)", "Shovel", "removed with a shovel")]
    return [rec(n, p, "scenery", None, None, other="removal tool: " + p, rotatable=False, source=en.url(p),
                confidence="unverified",
                notes=d + "; pre-placed natural obstacle (cannot be bought back once removed, en Farm page); "
                          "footprint not stated by any source")
            for n, p, d in rows]

# --------------------------------------------------------------------------- main

def cmd_build(raw, out_json, stats_json=None):
    S = load_sources(raw)
    stats = {}
    items = []
    items += build_production(S, stats)
    items += build_farm(S)
    items += build_animal_homes(S)
    items += build_field(S)
    items += build_trees(S)
    items += build_decorations(S, stats)
    items += build_scenery(S)
    # globally unique names: a decoration that shares a name with a non-decoration gets a suffix
    taken = Counter(i["name"].casefold() for i in items if not i["category"].startswith("decoration"))
    for i in items:
        if i["category"].startswith("decoration") and taken[i["name"].casefold()]:
            i["name"] += " (decoration)"
    stats["duplicate_names"] = [n for n, c in Counter(i["name"].casefold() for i in items).items() if c > 1]
    cats = Counter(i["category"] for i in items)
    stats["counts"] = {c: {"total": n,
                           "with_footprint": sum(1 for i in items if i["category"] == c and i["footprint"]),
                           "with_unlock_level": sum(1 for i in items if i["category"] == c and i["unlock_level"] is not None),
                           "confidence": dict(Counter(i["confidence"] for i in items if i["category"] == c))}
                       for c, n in sorted(cats.items())}
    stats["footprints_by_category"] = {c: dict(Counter("%dx%d" % (i["footprint"]["w"], i["footprint"]["h"])
                                                       for i in items if i["category"] == c and i["footprint"]).most_common())
                                       for c in sorted(cats)}
    stats["total"] = len(items)
    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
        f.write("\n")
    if stats_json:
        json.dump(stats, open(stats_json, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(stats, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "fetch":
        cmd_fetch(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "build":
        cmd_build(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    else:
        print(__doc__)
        sys.exit(2)
```
