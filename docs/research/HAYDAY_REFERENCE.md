# Hay Day reference overview (for Hayday Sandbox)

**Verified: 2026-11-09** (game version v1.73, update of 5 Oct 2026)

> This material is unofficial and is not endorsed by Supercell. For more information see Supercell's
> Fan Content Policy: www.supercell.com/fan-content-policy.

This is a short overview of the game, as background for the layout planner. Geometry and placement rules
are covered in **`docs/research/PLACEMENT_RESEARCH.md`**. Expansion plot data is in
**`data/research/expansions_research.json`**. Per-item metadata is in
`data/research/items_research.json`, which another research task maintains.

Confidence labels: **Confirmed** (official Supercell support pages or patch notes), **Community-reported**
(Hay Day Fandom wiki and forums), **Approximation** (our own derivation), **Unverified**. Wiki-derived
facts are CC BY-SA. See the source list at the end.

---

## 1. The game

| Fact | Value | Confidence |
|---|---|---|
| Developer | Supercell (Helsinki) | Confirmed |
| Release | Canada May 2012, worldwide 21 Jun 2012 (iOS); Android 20 Nov 2013 | Community (wiki *Update*) |
| Current version (2026-11-09) | v1.73, released 5 Oct 2026. Recent changes: Fishing Area mussel beaches, Angus as helper, favourite-decoration tabs | Community (wiki *Update*) + Confirmed (support "What's New?") |
| Camera | fixed 2:1 isometric view; pan and zoom only | Approximation |
| Experience level cap | **No hard cap.** The wiki tabulates levels 1-300. After level 126 the only level-up rewards are diamonds and fields. Videos report players above level 500. | Community |

## 2. Play areas (scenes)

| Area | Unlock | Notes for the planner |
|---|---|---|
| **Farm** | start | The planner's scope. Holds fields, trees and bushes, animal homes, production machines, barn and silo, decorations, plus fixed scenery. |
| Town | level 34 (repair the farm train station) | separate map with its own expansion plots, service buildings and decorations. Separate Edit Mode from level 34. Out of scope. |
| Fishing Lake | level 27 (repair the fishing boat) | separate map with fishing spots and fixed machines (Lure Workbench, Net Maker, Lobster Pool, Duck Salon). Out of scope. |
| Valley | level 25 (valley board) | seasonal multiplayer driving map. Out of scope. |
| Wildlife Sanctuary | town, reputation 3 | inside the town. Sanctuary animals and decorations. Out of scope. |
| Design Festival canvas | level 23, during events | a separate decoration "canvas" for contests (Confirmed). A useful model for a sandbox mode. |

## 3. Farm structure (summary)

For details, see PLACEMENT_RESEARCH.md §1-3.

* The grid is a 2:1 isometric diamond. **X** runs along the main road and **Y** runs from the
  forest/cliff (top-right) to the road (bottom-left). One tile is the size of one field.
* The base tile map in 2013 client data is **48 × 32**. The starting land is **32 × 32 or 48 × 32**
  (unresolved).
* The **main expansion strip** is **53 × 32** tiles with 52 plots. It continues the farm along the road,
  on the farmhouse side.
* There are also **13 "upper" plots** (2021, about 14 × 32, location unverified) and, across the main
  road, **18 regular plots** and **96 special plots**. Special plots need expansion permits and each holds
  an exclusive decoration. That makes **179 plots** in total.
* **Fixed scenery:**
  * the farmhouse, the driveway with the truck and order board, the roadside shop, the event board and
    the mailboxes;
  * the river with the riverboat dock, leaderboard and fishing boat;
  * across the road: the neighborhood house, Derby stand, train station and Wheel of Fortune truck;
  * the Mine and the helpers' house on the cliff, and Maggie's workbench.
* **Movable:** the barn, silo, fields, trees and bushes, animal homes, production machines and
  decorations.

## 4. What players can place on the farm: categories and rough counts

| Category | Count (approx.) | Footprint (tiles) | Notes | Confidence |
|---|---:|---|---|---|
| Fields | unlimited. New fields come every other level: 3 per level-up until level 49, 2 until 99, then 1. Level 157 gives 157 fields. | 1×1 | rotatable; paintbrush placement in Edit Mode | Community (wiki *Farm*) / Approximation (size) |
| Field crops | about 40 | none (grown in fields) | | Community (wiki category) |
| Fruit trees | 13 (Apple, Banana, Cacao, Cherry, Coconut, Guava, Lemon, Mango, Olive, Orange, Peach, Plum, Pomegranate) | 1×1 | they die after 4 harvests (revivable after the 3rd); removed with a saw | Community / Approximation (size) |
| Bushes | 6 (Raspberry, Blackberry, Blueberry, Coffee, Nectar, Peanut) | mostly 1×1. Raspberry and Blackberry are 1×2 (2×1 when mirrored). | removed with an axe | Community / Approximation (size) |
| Decorative trees | many (pine and leafy trees in several sizes) | varies | never seasonal-themed, unlike natural trees | Community |
| Production machines (farm, permanent) | **50**: 40 are 2×2, 8 are 3×3 (Bakery, Cake Oven, Feed Mill, Pie Oven, Popcorn Pot, Salad Bar, Sandwich Bar, Sauce Maker), Dairy is 4×4, Ice Cream Maker is 3×2 | see left | usually one of each; Feed Mill and Sugar Mill allow 2. The Mine (cliff, fixed) and 5 temporary event machines are separate. | Community (wiki infobox `size`) |
| Storage buildings | 2 on the farm (Barn, Silo). The Tackle Box is in the Fishing Lake. | at most 4×4 each (upper bound) | movable, not storable in normal play | Community / Approximation |
| Animal homes | 18 types: Chicken Coop, Cow Pasture, Pig Pen, Sheep Pasture, Goat Yard, Beehive Tree, Squirrel House, Lamb Pasture, Horse Stable, Donkey Stable, Dog House, Puppy House, Cat House, Kitten House, Bunny House, Alpaca House, Guinea Pig House, Bird House | Chicken Coop 3×3, other farm-animal pens 4×4, Beehive Tree and Squirrel House 2×2 (per `items_research.json`). Pet houses: see that file. | several are multi-instance. For example Chicken Coop ×3 (levels 1/12/23); Horse Stable ×4. | Community / Approximation |
| Farm animals | 10 types in the wiki category (chicken, cow, pig, sheep, goat, honey bee, squirrel, plus fishing-area duck, Pekin duck and lobster) | none (live inside homes) | | Community |
| Pets | 18 kinds (dogs, puppies, cats, kittens, horses, donkeys, bunnies, alpacas, guinea pigs, hedgehogs, cockatoos, macaws, toucans, peacocks, flamingos, herons, pelicans, swans) | none (they roam) | pets walk on paths (2014 patch) | Community / Confirmed |
| Products | **355** (Oct 2026, excluding limited-time ones) | none | stored in the barn (crops in the silo) | Community (wiki *Products*) |
| Supplies | about 25 (expansion, barn/silo upgrade, land-clearing and mining supplies) | none | | Community |
| **Decorations** | **800+ distinct items** across the wiki lists. These overlap and are incomplete: Fences & Paths ≈25, Nature ≈51, Ornaments ≈53, Farming ≈24, Seasonal ≈57, Derby ≈59, Events ≈27, Expansion 28, Packages ≈113, Valley ≈84, Holiday Calendar ≈10, Catalogue ≈6, Rewards ≈10, Decoration Collections ≈258, Sanctuary ≈75 (town) | 1×1 up to large | Sources: shop (coins, diamonds, vouchers), events, Derby, Farm Pass, Valley shop, expansion plots, Wheel of Fortune, level rewards. Can be stored in the shop "Storage" tab. | Community (counts) / Confirmed (sources, storage) |
| Custom decorations | 4 types (Gardener's, Stonemason's, Pedestal, Yard), up to 7 levels each | per type | rewards only (top-3 in a Derby, Farm Pass); first one delivered at level 71 | Confirmed (support) |

Prices rise with each purchase for most coin decorations: "most decorations cost at least 2 coins more
after each purchase" (Community: wiki).

## 5. Unlock levels relevant to layout planning

| Feature | Level | Confidence |
|---|---|---|
| First decorations (paths) | 1 (the wiki *Farm* page says 8, marked "tbc") | Community |
| Decoration Collection | 13 | Confirmed |
| Farm expansion | 22 | Confirmed |
| Edit Mode (farm) | 23 (the wiki *Edit_Mode* page says 37, which is stale) | Confirmed |
| Design Festival | 23 | Confirmed |
| Special expansion areas / expansion permits | 25 (2017 value: 29) | Confirmed |
| Valley | 25 | Community |
| Fishing Lake | 27 | Confirmed |
| Customization by Maggie (farmhouse roof/walls/porch, roadside-shop awning/crates/base, truck cabin/trailer/wheels) | 31 + 20 achievements | Confirmed |
| Town, and Edit Mode (town) | 34 | Confirmed |
| First custom decoration | 71 | Confirmed |

Maggie's customizations change appearance only. Nothing indicates that a footprint changes
(Unverified). The farmhouse has 88 look options: 38 roofs, 34 walls, 16 porches (Community: wiki
*Customization/Farmhouse*).

## 6. Glossary

* **LEM:** the land deed + mallet + marker stake triple used for expansion. A plot costs the same N of
  each.
* **Plot / area:** one unlockable piece of expansion land. **Special area:** a plot that also needs
  **expansion permits** and contains an exclusive decoration.
* **Layout:** a saved arrangement in Edit Mode. One is *Active*. A layout can only become active when all
  essential items are placed.
* **Mirrored:** the per-object boolean behind the in-game "rotate" button. See PLACEMENT_RESEARCH §4.3.

## 7. Sources (accessed 2026-11-09)

* Supercell support portal (Hay Day):
  * Expanding your Farm: <https://support.supercell.com/hay-day/en/articles/expanding-your-farm.html>
  * Edit Mode: <https://support.supercell.com/hay-day/en/articles/edit-mode.html>
  * The Shop: <https://support.supercell.com/hay-day/en/articles/the-shop.html>
  * Decorations: <https://support.supercell.com/hay-day/en/articles/decorations-3.html>
  * Custom Decorations: <https://support.supercell.com/hay-day/en/articles/custom-decorations.html>
  * Decoration Collection: <https://support.supercell.com/hay-day/en/articles/decoration-collection.html>
  * Farm Animals: <https://support.supercell.com/hay-day/en/articles/farm-animals.html>
  * The Basics: <https://support.supercell.com/hay-day/en/articles/the-basics.html>
  * Design Festival: <https://support.supercell.com/hay-day/en/articles/design-festival-2.html>
  * What's New (Oct 2026): <https://support.supercell.com/hay-day/en/articles/hd-whats-new-oct-26.html>
* Hay Day Fandom wiki (CC BY-SA; fetched via the MediaWiki API):
  * Game overview and history: <https://hayday.fandom.com/wiki/Update>, <https://hayday.fandom.com/wiki/Experience_Levels>
  * Farm and buildings: <https://hayday.fandom.com/wiki/Farm>, <https://hayday.fandom.com/wiki/Production_Buildings_List>, <https://hayday.fandom.com/wiki/Animal_Shelters>, <https://hayday.fandom.com/wiki/Trees_and_Bushes>, <https://hayday.fandom.com/wiki/Storage_Buildings>
  * Goods: <https://hayday.fandom.com/wiki/Products>, <https://hayday.fandom.com/wiki/Crops>
  * Decorations: <https://hayday.fandom.com/wiki/Decorations> (and its sub-pages), <https://hayday.fandom.com/wiki/Decoration_Collections>, <https://hayday.fandom.com/wiki/Customization/Farmhouse>
  * Expansion: <https://hayday.fandom.com/wiki/Expansion>, <https://hayday.fandom.com/wiki/Expansion/Farm>, <https://hayday.fandom.com/wiki/Expansion/Town>, <https://hayday.fandom.com/wiki/Expansion/Fishing_Lake>, <https://hayday.fandom.com/wiki/Expansion_Permit>
  * Other areas: <https://hayday.fandom.com/wiki/Town>, <https://hayday.fandom.com/wiki/Fishing_Lake>, <https://hayday.fandom.com/wiki/Valley>, <https://hayday.fandom.com/wiki/Sanctuary>
* Category counts come from the MediaWiki API `list=categorymembers` for these categories: Production
  Buildings, Animal Shelters, Trees and Bushes, Field Crops, Tree Crops, Bush Crops, Farm Animals, Pets,
  Sanctuary Animals, Supplies and Fish.
