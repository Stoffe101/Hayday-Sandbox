# Hay Day farm geometry and placement rules: research notes

**Verified: 2026-11-09**. The game version at that date is v1.73 (5 Oct 2026 update).

> This material is unofficial and is not endorsed by Supercell. For more information see Supercell's
> Fan Content Policy: www.supercell.com/fan-content-policy.

Data tables taken from the Hay Day Wiki are CC BY-SA, so see the attribution in
`data/research/expansions_research.json`. No game artwork was copied into this repo. Wiki map images
were analysed in a scratch directory outside the repo.

## Confidence labels

| Label | Meaning |
|---|---|
| **Confirmed** | From an official Supercell source: the support portal, or patch notes (the wiki's *Update* page copies them word for word). |
| **Community-reported** | From the Hay Day Fandom wiki, forums or player Q&A. Usually right, but sometimes stale. |
| **Approximation** | Our own derivation, for example measuring wiki map images or inferring from old client data. The method is stated each time. |
| **Unverified** | A plausible guess, a genre convention, or a source we could not check. Check it in-game before relying on it. |

---

## 0. TL;DR for implementers

| Topic | Best available answer | Confidence |
|---|---|---|
| Projection | Isometric diamond grid, 2:1. Wiki maps measure edge slopes of ±0.50. | Approximation (measured) |
| Axes | **X** runs parallel to the main road, from the river end to the far end, and goes down-right on screen. **Y** runs from the forest/cliff to the road and goes down-left on screen. The origin is the top corner. | Approximation |
| Base tile map | **48 × 32** (`TileMapWidth=48`, `TileMapHeight=32`) in v1.5.42 client data from 2013. | Unverified for the current game |
| Starting land | Either **32 × 32** (H2, slightly favoured) or **48 × 32** (H1). See §1.4. | Unverified |
| Main expansion strip | **53 × 32** tiles holding 52 plots. Measured subsections are 16/8/15/14 columns; the wiki says 17/8/15/13. | Approximation / Community |
| Total plots | **179** = 83 regular + 96 special. That is 52 main + 13 "upper" + 18 regular across the road + 96 special across the road. | Community |
| Unlock rule | A plot unlocks when it shares an edge with land you already own and you pay N land deeds + N mallets + N marker stakes. Special plots also need permits. | Community |
| Levels | Expansion from **22**. Special areas and permits from **25** (the wiki and the 2017 patch notes say 29). Edit Mode from **23**. | Confirmed |
| Overlap | **Never.** Items go onto *free* owned tiles only. | Confirmed / Community |
| Rotate | "Rotate" is a **mirror flip**, a boolean per object. It swaps a W×H footprint to H×W: in 2013 data, mirrored 1×2 bushes must be 2×1 to avoid overlaps. Most items can do it. Path tiles, the Mine and fixed scenery cannot. | Approximation (data, high) + Confirmed (rotate button exists) |
| Fences / paths | 1×1 tiles. They **auto-connect** to orthogonal neighbours of the same kind: a lone fence is a post, and a corner needs 3 pieces. | Community (2015 Q&A), with partly contradicting 2013 data. See §4.4 |
| Footprints | Field 1×1, fruit tree 1×1, path/fence 1×1. Most bushes are 1×1, but two bush types are **1×2** (Raspberry and Blackberry per `items_research.json`). Production buildings are 2×2 (40), 3×3 (8), 4×4 (Dairy) or 3×2 (Ice Cream Maker). Barn and silo are at most 4×4. | Community + Approximation |
| Storage | Decorations go to the Shop "Storage" tab. Buildings can only be stored in an Edit Mode layout. | Confirmed |
| Fixed scenery | Farmhouse, truck and order board, roadside shop, mailboxes, event board, river dock and boats, everything across the road, the Mine on the cliff, the helpers' house. | Community / Approximation |
| Movable | Barn, silo, fields, trees, bushes, animal homes, production machines, decorations. | Community / Approximation |

---

## 1. The farm tile grid

### 1.1 Projection and orientation (Approximation, high confidence)

* All official and wiki farm maps use a **2:1 isometric diamond** grid. We measured edge slopes on
  `File:Farm_Expansions.png` (1500×789): -0.499 and +0.504. One tile measures about 34.8 × 17.4 px on that
  downscaled image. A plot border that runs along one axis covers 17.42 px per tile on each iso axis.
* The camera never rotates in Hay Day. Players can only pan and zoom, so every sprite is drawn for one
  fixed view.
* **Axis meaning.** We combined the official farm map (`File:Farm_Map2.png`) with the object coordinates
  in the 2013 client data (§1.3):
  * **X** runs parallel to the **main road**. Low X is the river/fishing-boat end, which is screen
    upper-left. High X is the end where the main expansion strip continues "further down the road",
    which is screen lower-right.
  * **Y** runs from the **forest/cliff edge** (Y=0, screen upper-right, where the Mine and helpers'
    house are) to the **main road** (Y=32 and beyond, screen lower-left).
  * In the old data, objects across the road (roadside shop row, Wheel of Fortune truck) have Y = 32…37.
    River objects such as the riverboat have X ≈ -5. The Mine has Y = -3.
* Screen transform (origin at the top corner): `sx = (X - Y) * TW/2`, `sy = (X + Y) * TH/2`, with
  `TW = 2*TH`. "Rows" of constant Y run down-right parallel to the road. "Columns" of constant X run
  down-left from the forest to the road.

### 1.2 Units

The 2013 data gives positions as integer tile coordinates. In that data:

* the 6 starter **fields** sit in a 2×3 block at unit spacing, so each field is **1×1**;
* **fruit trees** sit in solid 1-tile-spaced blocks, so each is **1×1**. Two bush types sit 2 tiles
  apart along one axis, so they are **1×2**, and they become **2×1** when mirrored (see §4.3);
* **path tiles** (one object type with 466 instances in Greg's farm) and **fence pieces** form
  1-tile-wide lines, so each is **1×1**;
* a production building anchored at (16,6) in Greg's farm has exactly 3×3 free tiles before the
  neighbouring paths. This matches the wiki infobox size "3×3". Anchors are the **minimum (X,Y)
  corner**, which is the top corner on screen.

The wiki infobox `size` values (2×2, 3×3, 4×4) therefore use the same unit as fields and paths.
**One tile = one field = one path tile.** (Approximation, consistent across several checks.)

### 1.3 Base tile map: 48 × 32 (Unverified for the current game)

`JSON/home.json` (a brand-new farm) and `JSON/ai.json` (Greg's farm) come from the Hay Day **1.5.42**
client (January 2013), published in a third-party private-server repo
(<https://raw.githubusercontent.com/frmnnet/HayDay-1.5.42/master/JSON/home.json>). Both declare
`"TileMapWidth":48,"TileMapHeight":32`. **We cite only these two facts**, because importing client data
is off-limits per `docs/research/LEGAL_AND_LICENSING.md`. Confirm them in-game.
The height of **32** independently matches the wiki's expansion table, where every main subsection is
"… × 32". That agreement is why we trust the 32.

### 1.4 Starting buildable area: open question (Unverified)

Farm expansions already existed in v1.5.42 (first land expansion: v1.3, 15 Nov 2012), so the 48-wide
map may already contain the first expansion subsection:

* **H2 (slightly favoured): starting land = 32 × 32**, plus subsection 1 (16 wide by our measurement)
  = 48. Evidence for it:
  1. 48 − 16 = 32 = TileMapHeight, which gives a square start, the usual Supercell pattern.
  2. In the new-farm data the starting cluster (barn (15,14), silo (20,12), fields (19–20, 20–22)) is
     centred on a 32×32 square, not on a 48×32 one.
  3. A new farm and Greg's farm declare the same map size.

  Under H2 the full main strip is **85 × 32** (X = 0…84).
* **H1: starting land = 48 × 32**, and the main section is appended at X = 48…100, giving a full main strip
  of **101 × 32**.
* No community source states the starting size in tiles. We searched the wiki, Reddit, forums and
  general web, and found nothing. **Keep the map size data-driven.** The fastest in-game check is to
  count the path tiles along one edge of a fresh farm in Edit Mode.

### 1.5 Whole-farm extents (best estimate)

| Region | Size (tiles) | Position | Confidence |
|---|---|---|---|
| Starting land | 32×32 (H2) or 48×32 (H1) | X from 0, Y 0…31 | Unverified |
| Main expansion strip, 52 plots | 53×32 | X = start width … +53, Y 0…31, same side of the road | Approximation |
| "Upper" plots (2021), 13 plots | ≈14×32 from image proportions. Long axis runs road→forest. | One X-end of the farm. The far end of the main strip is most likely; the river end is possible. | Unverified |
| Main road + driveway | fixed terrain | along Y ≈ 32…36 | Approximation |
| Across-road sections: 18 regular + 96 special plots | unknown | "across the main road", "at the bottom of your Farm" | Confirmed (location) / unknown (size) |

---
## 2. Expansion plots

### 2.1 Rules

* **Level.** Farm expansion opens at **level 22** (Confirmed: Supercell support *Expanding your Farm*;
  wiki). Special areas and expansion permits open at **level 25** (Confirmed: same article; wiki
  *Expansion Permit*). The wiki *Expansion/Farm* page and the March 2017 patch note say **29**, which is
  the historic value. Use 25.
* **Cost.** Regular plot = N land deeds + N mallets + N marker stakes, with the same N for all three
  ("LEMs"). Special plot = P expansion permits + N of each LEM. (Community: wiki tables. Confirmed in
  principle by Supercell support: "Expanding regular Farm areas requires Land Deeds, Mallets, and Marker
  Stakes. The number of supplies required varies depending on the area.")
* **Order and adjacency.** "All plots can be unlocked starting at the top. Once a section has been
  unlocked all adjacent ones become unlockable." (Community: wiki.) For the planner: a plot can be
  unlocked if it **shares an edge** with owned land, meaning the start farm or an unlocked plot. In the
  main strip the plots touching the start farm are **1–9**, the column u = 0 (Approximation).
* **No placement on locked land.** Locked plots are scenery full of natural trees, rocks and ponds.
  Items can only be dragged "onto a free space on your Farm" (Confirmed: support *The Shop*).
  Unlocking a plot adds its natural obstacles to the farm, and they can then be cleared with
  axes/saws/dynamite/TNT/shovels (Community; the wiki maps show the plots' trees and rocks). Supercell
  support warns that tapping obstacles near a plot can unlock a different plot than intended
  (Confirmed).
* **Special-plot rewards.** Each special plot holds one exclusive *expansion decoration*, which the player
  receives when the plot is unlocked. It can then be moved or stored like any decoration (Community:
  wiki *Decorations/Expansion*, 28 decorations listed).
* **Out of scope.** *Expansion/Town* (town plots plus 15 beach plots near the Sanctuary added July 2026)
  and *Expansion/Fishing_Lake* (fishing spots) also exist.

### 2.2 Section inventory (Community: wiki *Expansion/Farm*, rev. 2025-09-21; totals re-added and all match)

| Section id (JSON) | Plots | Supplies | Added | Where |
|---|---:|---|---|---|
| `main` | 52 | 802 of each LEM | subsections: 1-17 ≈ Nov 2012 (inferred), 18-26 Mar 2014, 27-39 Apr 2015, 40-52 **Mar 2017** (wiki text says Dec 2018; see §2.6) | beside the farmhouse, same side of the road |
| `main_upper_2021` | 13 | 448 | Jun 2021 (v1.51) | listed under the main section; exact location unverified (§1.5) |
| `across_road_regular_2015` | 9 | 239 | Apr 2015 (v1.24) | across the main road |
| `across_road_regular_2018` | 9 | 355 | Dec 2018 (v1.41) | across the road |
| `special_2017` | 9 | 59 permits + 280 | Mar 2017 (v1.33) | across the road |
| `special_2018` | 15 | 169 permits + 609 | Dec 2018 (v1.41) | across the road (L-shaped: 11-plot block + 4-plot strip) |
| `special_lower_2019_2021` | 41 | 587 permits + 1973 | #1-24 Oct 2019 (v1.44), #25-41 Jun 2021 | across the road ("bottom of your Farm") |
| `special_spring_2023` | 31 | 530 permits + 1865 | Mar 2023 (v1.57) | across the road, "adhere second-section plots … at left-hand side" |
| **Total** | **179** | 1844 LEM-each regular, 4727 special; **1345 permits** | | |

The 1345 permits total equals the wiki *Expansion Permit* statement "After the Spring 2023 update, a
total of 1345 permits are needed".

### 2.3 Main section: reconstructed tile map (Approximation)

Method: we took the dark plot-border lines of `File:Farm_Expansions.png` in a scratch directory and fitted
an iso grid. The internal borders snap to integer tile lines with a residual below 0.2 tile. Each tile
centre was then assigned to the plot polygon containing it. Each subsection comes out as an exact full-height
rectangle (512 / 256 / 480 / 448 tiles), which is a strong consistency check. Coordinates: `u` = column
along the road (u=0 touches the starting land), `v` = row from the forest edge (v=0) to the road edge
(v=31). On screen, u runs down-right and v runs down-left.

```
u ->   0  .  .  .  .  5  .  .  .  . 10  .  .  .  . 15  .  .  .  . 20  .  .  .  . 25  .  .  .  . 30  .  .  .  . 35  .  .  .  . 40  .  .  .  . 45  .  .  .  . 50  .  .
v= 0   9  9  9  9  9 14 14 14 14 14 14 14 14 13 13 13 22 22 22 22 22 22 22 22 30 30 30 30 30 30 30 34 34 34 34 34 34 39 39 45 45 45 45 45 45 51 51 51 51 51 51 51 51
v= 1   9  9  9  9  9 14 14 14 14 14 14 14 14 13 13 13 22 22 22 22 22 22 22 22 30 30 30 30 30 30 30 34 34 34 34 34 34 39 39 45 45 45 45 45 45 51 51 51 51 51 51 51 51
v= 2   9  9  9  9  9 14 14 14 14 14 14 14 14 13 13 13 22 22 22 22 22 22 22 22 30 30 30 30 30 30 30 34 34 34 34 34 34 39 39 45 45 45 45 45 45 51 51 51 51 51 51 51 51
v= 3   9  9  9  9  9 14 14 14 14 14 14 14 14 13 13 13 22 22 22 22 22 22 22 22 30 30 30 30 30 30 30 34 34 34 34 34 34 39 39 45 45 45 45 45 45 51 51 51 51 51 51 51 51
v= 4   9  9  9  9  9 14 14 14 14 14 14 14 14 13 13 13 22 22 22 26 26 26 26 26 30 30 30 30 30 30 30 34 34 34 34 34 34 39 39 45 45 45 45 45 45 50 50 50 50 50 50 50 50
v= 5   8  8  8  8  8  8  8 13 13 13 13 13 13 13 13 13 22 22 22 26 26 26 26 26 30 30 30 30 33 33 33 33 33 39 39 39 39 39 39 45 45 45 45 45 45 50 50 50 50 50 50 50 50
v= 6   8  8  8  8  8  8  8 13 13 13 13 13 13 13 13 13 22 22 22 26 26 26 26 26 30 30 30 30 33 33 33 33 33 39 39 39 39 39 39 44 44 44 44 44 44 44 44 50 50 50 50 50 50
v= 7   8  8  8  8  8  8  8 13 13 13 13 13 13 13 13 13 21 21 21 21 21 26 26 26 30 30 30 30 33 33 33 33 33 39 39 39 39 39 39 44 44 44 44 44 44 44 44 50 50 50 50 50 50
v= 8   7  7  7  7  8  8  8 13 13 13 17 17 17 17 17 17 21 21 21 21 21 26 26 26 30 30 30 30 33 33 33 33 33 39 39 39 39 39 39 44 44 44 44 44 44 44 44 49 49 49 49 49 49
v= 9   7  7  7  7  8  8  8 13 13 13 17 17 17 17 17 17 21 21 21 21 21 26 26 26 30 30 30 30 33 33 33 33 33 39 39 39 39 39 39 43 43 43 43 43 43 49 49 49 49 49 49 49 49
v=10   7  7  7  7  8  8  8 13 13 13 17 17 17 17 17 17 21 21 21 21 21 26 26 26 29 29 29 29 33 33 33 33 33 39 39 39 39 39 39 43 43 43 43 43 43 49 49 49 49 49 49 49 49
v=11   7  7  7  7  8  8  8 13 13 13 17 17 17 16 16 16 21 21 21 21 21 26 26 26 29 29 29 29 29 29 29 38 38 38 38 38 38 38 38 43 43 43 43 43 43 49 49 49 49 49 49 49 49
v=12   6  6  6  6  6  6  6 12 12 12 12 12 12 16 16 16 20 20 20 20 20 20 20 20 29 29 29 29 29 29 29 38 38 38 38 38 38 38 38 43 43 43 43 43 43 48 48 48 48 52 52 52 52
v=13   6  6  6  6  6  6  6 12 12 12 12 12 12 16 16 16 20 20 20 20 20 20 20 20 29 29 29 29 29 29 29 38 38 38 38 38 38 38 38 43 43 43 48 48 48 48 48 48 48 52 52 52 52
v=14   6  6  6  6  6  6  6 12 12 12 12 12 12 16 16 16 20 20 20 20 20 20 20 20 29 29 29 29 29 29 29 37 37 37 37 37 37 37 37 43 43 43 48 48 48 48 48 48 48 52 52 52 52
v=15   5  5  5  5  5  5  5 12 12 12 16 16 16 16 16 16 20 20 20 20 25 25 25 25 29 29 29 32 32 32 32 37 37 37 37 37 37 37 37 42 42 42 48 48 48 48 48 48 48 52 52 52 52
v=16   5  5  5  5  5  5  5 12 12 12 16 16 16 16 16 16 20 20 20 20 25 25 25 25 29 29 29 32 32 32 32 37 37 37 37 37 37 37 37 42 42 42 48 48 48 48 48 48 48 52 52 52 52
v=17   5  5  5  5  5  5  5 12 12 12 16 16 16 16 16 16 19 19 19 19 25 25 25 25 29 29 29 32 32 32 32 37 37 37 37 37 37 37 37 42 42 42 48 48 48 48 48 48 48 52 52 52 52
v=18   4  4  4  4  4  4  4 12 12 12 12 12 12 16 16 16 19 19 19 19 25 25 25 25 29 29 29 32 32 32 32 37 37 37 37 37 37 37 37 42 42 42 42 42 47 47 47 47 47 47 47 47 47
v=19   4  4  4  4  4  4  4 12 12 12 12 12 12 16 16 16 19 19 19 19 25 25 25 25 28 28 28 32 32 32 32 37 37 37 37 37 37 37 37 42 42 42 42 42 47 47 47 47 47 47 47 47 47
v=20   4  4  4  4  4  4  4 12 12 12 12 12 12 16 16 16 19 19 19 19 25 25 25 25 28 28 28 28 28 28 28 28 28 37 37 37 37 37 37 42 42 42 42 42 47 47 47 47 47 47 47 47 47
v=21   3  3  3  3  3  3  3 11 11 11 11 11 11 16 16 16 19 19 19 24 24 24 24 24 28 28 28 28 28 28 28 28 28 37 37 37 37 37 37 41 41 41 41 41 41 41 41 41 41 47 47 47 47
v=22   3  3  3  3  3  3  3 11 11 11 11 11 11 16 16 16 19 19 19 24 24 24 24 24 28 28 28 28 28 28 28 28 28 36 36 36 36 36 36 41 41 41 41 41 41 41 41 41 41 47 47 47 47
v=23   3  3  3  3  3  3  3 11 11 11 11 11 11 15 15 15 19 19 19 24 24 24 24 24 28 28 28 28 28 28 28 28 28 36 36 36 36 36 36 41 41 41 41 41 41 41 41 41 41 47 47 47 47
v=24   2  2  2  2  3  3  3 11 11 11 11 11 11 15 15 15 18 18 18 18 18 24 24 24 28 28 28 28 31 31 31 31 31 36 36 36 36 36 36 41 41 41 41 41 41 41 41 41 41 47 47 47 47
v=25   2  2  2  2  3  3  3  3  3  3  3  3  3 15 15 15 18 18 18 18 18 23 23 23 27 27 27 31 31 31 31 31 31 36 36 36 36 36 36 40 40 40 40 46 46 46 46 46 46 46 46 46 46
v=26   2  2  2  2  3  3  3  3  3  3  3  3  3 15 15 15 18 18 18 18 18 23 23 23 27 27 27 31 31 31 31 31 31 36 36 36 36 36 36 40 40 40 40 46 46 46 46 46 46 46 46 46 46
v=27   2  2  2  2  3  3  3  3  3  3  3  3  3 15 15 15 18 18 18 18 18 23 23 23 27 27 27 31 31 31 31 31 31 35 35 35 35 35 35 40 40 40 40 46 46 46 46 46 46 46 46 46 46
v=28   1  1  1  1  1 10 10 10 10 10 10 10 10 15 15 15 18 18 18 18 18 23 23 23 27 27 27 31 31 31 31 31 31 35 35 35 35 35 35 40 40 40 40 40 40 40 40 40 46 46 46 46 46
v=29   1  1  1  1  1 10 10 10 10 10 10 10 10 15 15 15 18 18 18 23 23 23 23 23 27 27 27 27 27 27 27 31 31 35 35 35 35 35 35 40 40 40 40 40 40 40 40 40 46 46 46 46 46
v=30   1  1  1  1  1 10 10 10 10 10 10 10 10 15 15 15 18 18 18 23 23 23 23 23 27 27 27 27 27 27 27 31 31 35 35 35 35 35 35 40 40 40 40 40 40 40 40 40 46 46 46 46 46
v=31   1  1  1  1  1 10 10 10 10 10 10 10 10 15 15 15 18 18 18 23 23 23 23 23 27 27 27 27 27 27 27 31 31 35 35 35 35 35 35 40 40 40 40 40 40 40 40 40 46 46 46 46 46
```

Per-plot data (costs: Community; geometry: Approximation). Machine-readable copy:
`data/research/expansions_research.json → sections[id=main]`.

| Plot | Supplies (each of deed/mallet/stake) | Sub | Tiles | BBox u | BBox v | Neighbours | Edges |
|---:|---:|---:|---:|---|---|---|---|
| 1 | 6 | 1 | 20 | 0-4 | 28-31 | 2, 3, 10 | start_farm_side, road_side |
| 2 | 5 | 1 | 16 | 0-3 | 24-27 | 1, 3 | start_farm_side |
| 3 | 16 | 1 | 51 | 0-12 | 21-27 | 1, 2, 4, 10, 11, 15 | start_farm_side |
| 4 | 6 | 1 | 21 | 0-6 | 18-20 | 3, 5, 12 | start_farm_side |
| 5 | 6 | 1 | 21 | 0-6 | 15-17 | 4, 6, 12 | start_farm_side |
| 6 | 6 | 1 | 21 | 0-6 | 12-14 | 5, 7, 8, 12 | start_farm_side |
| 7 | 5 | 1 | 16 | 0-3 | 8-11 | 6, 8 | start_farm_side |
| 8 | 15 | 1 | 33 | 0-6 | 5-11 | 6, 7, 9, 13, 14 | start_farm_side |
| 9 | 7 | 1 | 25 | 0-4 | 0-4 | 8, 14 | start_farm_side, forest_side |
| 10 | 10 | 1 | 32 | 5-12 | 28-31 | 1, 3, 15 | road_side |
| 11 | 7 | 1 | 24 | 7-12 | 21-24 | 3, 12, 15, 16 |  |
| 12 | 12 | 1 | 45 | 7-12 | 12-20 | 4, 5, 6, 11, 13, 16, 17 |  |
| 13 | 15 | 1 | 54 | 7-15 | 0-11 | 8, 12, 14, 17, 21, 22 | forest_side |
| 14 | 11 | 1 | 40 | 5-12 | 0-4 | 8, 9, 13 | forest_side |
| 15 | 8 | 1 | 27 | 13-15 | 23-31 | 3, 10, 11, 16, 18, 19 | road_side |
| 16 | 12 | 1 | 45 | 10-15 | 11-22 | 11, 12, 15, 17, 19, 20, 21 |  |
| 17 | 6 | 1 | 21 | 10-15 | 8-11 | 12, 13, 16, 21 |  |
| 18 | 12 | 2 | 34 | 16-20 | 24-31 | 15, 19, 23, 24 | road_side |
| 19 | 7 | 2 | 25 | 16-19 | 17-23 | 15, 16, 18, 20, 24, 25 |  |
| 20 | 13 | 2 | 32 | 16-23 | 12-16 | 16, 19, 21, 25, 26, 29 |  |
| 21 | 9 | 2 | 25 | 16-20 | 7-11 | 13, 16, 17, 20, 22, 26 |  |
| 22 | 15 | 2 | 41 | 16-23 | 0-6 | 13, 21, 26, 30 | forest_side |
| 23 | 9 | 2 | 27 | 19-23 | 25-31 | 18, 24, 27 | road_side |
| 24 | 6 | 2 | 18 | 19-23 | 21-24 | 18, 19, 23, 25, 28 |  |
| 25 | 8 | 2 | 24 | 20-23 | 15-20 | 19, 20, 24, 28, 29 |  |
| 26 | 10 | 2 | 30 | 19-23 | 4-11 | 20, 21, 22, 29, 30 |  |
| 27 | 15 | 3 | 33 | 24-30 | 25-31 | 23, 28, 31 | road_side |
| 28 | 15 | 3 | 43 | 24-32 | 19-24 | 24, 25, 27, 29, 31, 32, 36, 37 |  |
| 29 | 18 | 3 | 44 | 24-30 | 10-18 | 20, 25, 26, 28, 30, 32, 33, 37, 38 |  |
| 30 | 24 | 3 | 55 | 24-30 | 0-9 | 22, 26, 29, 33, 34 | forest_side |
| 31 | 15 | 3 | 35 | 27-32 | 24-31 | 27, 28, 35, 36 | road_side |
| 32 | 8 | 3 | 20 | 27-30 | 15-19 | 28, 29, 37 |  |
| 33 | 12 | 3 | 30 | 28-32 | 5-10 | 29, 30, 34, 38, 39 |  |
| 34 | 12 | 3 | 30 | 31-36 | 0-4 | 30, 33, 39 | forest_side |
| 35 | 12 | 3 | 30 | 33-38 | 27-31 | 31, 36, 40 | road_side |
| 36 | 12 | 3 | 30 | 33-38 | 22-26 | 28, 31, 35, 37, 40, 41 |  |
| 37 | 24 | 3 | 60 | 31-38 | 14-21 | 28, 29, 32, 36, 38, 41, 42, 43 |  |
| 38 | 10 | 3 | 24 | 31-38 | 11-13 | 29, 33, 37, 39, 43 |  |
| 39 | 19 | 3 | 46 | 33-38 | 0-10 | 33, 34, 38, 43, 44, 45 | forest_side |
| 40 | 39 | 4 | 48 | 39-47 | 25-31 | 35, 36, 41, 46 | road_side |
| 41 | 32 | 4 | 40 | 39-48 | 21-24 | 36, 37, 40, 42, 46, 47 |  |
| 42 | 20 | 4 | 24 | 39-43 | 15-20 | 37, 41, 43, 47, 48 |  |
| 43 | 24 | 4 | 30 | 39-44 | 9-14 | 37, 38, 39, 42, 44, 48, 49 |  |
| 44 | 20 | 4 | 24 | 39-46 | 6-8 | 39, 43, 45, 49, 50 |  |
| 45 | 29 | 4 | 36 | 39-44 | 0-5 | 39, 44, 50, 51 | forest_side |
| 46 | 40 | 4 | 50 | 43-52 | 25-31 | 40, 41, 47 | road_side, far_end |
| 47 | 35 | 4 | 43 | 44-52 | 18-24 | 41, 42, 46, 48, 52 | far_end |
| 48 | 32 | 4 | 39 | 42-48 | 12-17 | 42, 43, 47, 49, 52 |  |
| 49 | 24 | 4 | 30 | 45-52 | 8-11 | 43, 44, 48, 50, 52 | far_end |
| 50 | 23 | 4 | 28 | 45-52 | 4-7 | 44, 45, 49, 51 | far_end |
| 51 | 26 | 4 | 32 | 45-52 | 0-3 | 45, 50 | forest_side, far_end |
| 52 | 20 | 4 | 24 | 49-52 | 12-17 | 47, 48, 49 | far_end |

### 2.4 Upper plots (2021), 13 plots (Community costs; Approximation adjacency)

Costs (LEM each): #1: 48, #2: 40, #3: 24, #4: 30, #5: 24, #6: 36, #7: 50, #8: 43, #9: 39, #10: 24, #11: 30, #12: 28, #13: 32.
Arrangement from the wiki image: two staggered rows along a strip whose long axis runs road→forest. Plots
1-6 run along one long side and 7-13 along the other. Adjacency: 1: 2,7; 2: 1,3,7,8; 3: 2,4,8,9; 4: 3,5,9,11; 5: 4,6,11,12; 6: 5,12,13; 7: 1,2,8; 8: 2,3,7,9,10; 9: 3,4,8,10,11; 10: 8,9,11; 11: 4,5,9,10,12; 12: 5,6,11,13; 13: 6,12.

### 2.5 Across-road sections

* **Regular 2015** (LEM each): #1: 15, #2: 15, #3: 34, #4: 34, #5: 22, #6: 29, #7: 22, #8: 39, #9: 29. Adjacency (from image): 1: 2,4; 2: 1,3,5; 3: 2,5,6; 4: 1,5,7,8; 5: 2,3,4,6,7; 6: 3,5,7,9; 7: 4,5,6,8,9; 8: 4,7,9; 9: 6,7,8.
* **Regular 2018** (LEM each): #1: 36, #2: 47, #3: 44, #4: 35, #5: 36, #6: 47, #7: 27, #8: 47, #9: 36. Adjacency (from image): 1: 2,4; 2: 1,3,4,5,6; 3: 2,6; 4: 1,2,5,7,8; 5: 2,4,6,8,9; 6: 2,3,5,9; 7: 4,8; 8: 4,5,7,9; 9: 5,6,8.
* **Special 2017** (permits P + LEM each): #1: 1P+30, #2: 2P+32, #3: 6P+29, #4: 4P+20, #5: 10P+39, #6: 8P+39, #7: 10P+36, #8: 8P+29, #9: 10P+26.
* **Special Dec 2018** (no wiki table, values read from the labelled image `File:Permits_vs_Lems.jpg`; they
  add up to exactly 169 P / 609 LEM; the numbering is ours): left block, near top-left edge = 10P+33; left block, top corner = 10P+49; left block, upper-left = 10P+40; left block, left corner = 11P+36; left block, centre = 11P+45; left block, right corner (where the strip joins) = 10P+44; left block, lower-left = 12P+44; left block, centre-bottom = 13P+38; left block, bottom-left edge = 15P+27; left block, bottom-right edge = 15P+42; left block, bottom corner = 15P+36; strip, segment next to the block = 13P+49; strip, 2nd segment = 10P+45; strip, 3rd segment = 10P+36; strip, far end = 4P+45.
* **Special "lower" 2019/2021**: #1: 4P+48, #2: 10P+52, #3: 10P+40, #4: 12P+24, #5: 15P+24, #6: 16P+56, #7: 4P+52, #8: 6P+40, #9: 10P+38, #10: 13P+56, #11: 15P+44, #12: 16P+36, #13: 17P+40, #14: 5P+40, #15: 10P+52, #16: 10P+30, #17: 14P+64, #18: 18P+48, #19: 5P+40, #20: 8P+54, #21: 12P+54, #22: 15P+50, #23: 18P+40, #24: 18P+50, #25: 17P+50, #26: 23P+68, #27: 15P+45, #28: 21P+63, #29: 22P+65, #30: 19P+55, #31: 17P+50, #32: 20P+60, #33: 12P+35, #34: 28P+83, #35: 18P+53, #36: 14P+40, #37: 15P+42, #38: 15P+46, #39: 16P+48, #40: 14P+40, #41: 20P+58.
* **Special Spring 2023**: #1: 4P+50, #2: 6P+55, #3: 10P+44, #4: 12P+62, #5: 12P+48, #6: 14P+56, #7: 16P+58, #8: 13P+50, #9: 16P+53, #10: 18P+65, #11: 20P+60, #12: 16P+40, #13: 17P+50, #14: 18P+63, #15: 17P+60, #16: 19P+68, #17: 18P+44, #18: 19P+56, #19: 20P+64, #20: 19P+55, #21: 22P+70, #22: 19P+58, #23: 20P+64, #24: 21P+74, #25: 19P+60, #26: 20P+70, #27: 19P+68, #28: 22P+80, #29: 22P+70, #30: 21P+73, #31: 21P+77.

Tile sizes and exact relative placement of the across-road sections are **unknown**. Their maps have no
common scale reference. Adjacency for the special sections is not provided: line extraction on those
images was unreliable.

### 2.6 Disagreements found

| Topic | Source A | Source B | Our call |
|---|---|---|---|
| Main subsection widths | wiki "Area" row: 17/8/15/13 × 32 | wiki map image measured: 16/8/15/14 × 32 | both total 53; the JSON follows the image |
| Subsection 4 (plots 40-52) date | wiki text: Dec 2018 | the map showing 52 plots was uploaded 2017-03-28; Mar 2017 patch: "many new regular farm expansion areas" | Mar 2017 |
| Special-area level | wiki *Expansion/Farm*, 2017 patch note: 29 | Supercell support + wiki *Expansion Permit*: 25 | 25 (current) |
| Special-area count | wiki *Expansion Permit*: "47 special areas", "643 permits … 50 areas through summer 2021" | sum of the wiki tables: 96 areas, 1345 permits (and the same page says 1345 after Spring 2023) | 96 / 1345; older sentences are stale |
| Edit Mode level | wiki *Edit_Mode*: 37 (town 34) | Supercell support *Edit Mode* + wiki *Farm*: 23 (town 34) | 23 |
| First decoration level | wiki *Farm*: 8 "(tbc)" | wiki *Decorations*: 1 (paths are level 1) | 1 |

---
## 3. Permanent scenery: fixed or movable

The official farm maps are `File:Farm_Map.png` and `File:Farm_Map2.png`. The wiki *Farm* page lists the
buildings.

| Object | Where | Movable? | Confidence / evidence |
|---|---|---|---|
| Main road | runs along the lower-left (road) edge of the farm, parallel to X; continues to the fishing-lake end (river side) and "further down the road" | fixed terrain | Approximation (maps) |
| Driveway from road to farmhouse; truck + **order board** at its end | inside the farm area, near the farmhouse | **fixed** | Community: wiki *Truck* says the truck "is parked next to the order board near the farmhouse"; never sold in the shop |
| **Farmhouse** | near the cliff, on the main-expansion side ("the main [expansion] is on the side of the farmhouse") | **fixed** (customizable look only, via Maggie at level 31) | Community: German forum 2015 says "except the farmhouse and the field borders there are no hard constraints". Not an object in the 2013 data. Not storable. |
| **Barn**, **Silo** | farm area | **movable** (cannot be sold or stored in normal play) | Approximation: they are ordinary objects in the 2013 data, and the silo is at different coordinates in two farms. Community: wiki *Buildings* says "once bought and placed, buildings cannot be sold or stored" |
| Roadside shop, event board ("next to your roadside shop"), Tom's waiting spot ("I'll wait by your roadside shop"), mailbox, newspaper mailbox, neighborhood mailbox | along the road edge | fixed | Community (wiki *Tom*, *Mailbox*; patch notes for the event board) |
| River, riverboat dock + boat, leaderboard, fishing boat (to the Fishing Lake) | river at the X-min (upper-left) end | fixed | Community/Approximation (maps; river objects at X ≈ -5 in the 2013 data) |
| Neighborhood house, Derby stand, train station (to the Town), Wheel of Fortune truck | **across** the road | fixed | Approximation (maps; Y ≈ 33-37 in the 2013 data) |
| Mine | on the cliff (Y < 0) | **cannot be moved or rotated** | Community: wiki *Mine* |
| Helpers' house (Rose and Ernest) | "above the mine, up on the cliff" | fixed | Community: wiki *Helpers' House* |
| Maggie's workbench | "near the Town Request Board" | fixed | Confirmed: support *The Basics* |
| Valley board | not on the wiki map | fixed | Community |
| Lure Workbench, Net Maker, Lobster Pool, Duck Salon, Tackle Box | in the **Fishing Lake** scene, not on the farm | cannot be moved | Community: wiki pages |
| Natural trees, rocks, ponds | everywhere, especially on locked plots | removable with axe/saw/dynamite/TNT/shovel; **cannot be re-bought once removed**; natural trees change with seasons | Community: wiki *Farm*, *Buildings* |

---

## 4. Placement rules

### 4.1 Footprints

* Every placeable object occupies an axis-aligned **rectangle of W×H tiles**, anchored at its minimum
  (X,Y) corner (Approximation, 2013 data).
* Sizes in tile units (the same unit as a field):

| Kind | Footprint | Confidence |
|---|---|---|
| Field | 1×1 | Approximation (data) |
| Fruit tree | 1×1 | Approximation (data) + Community |
| Fruit bush | 1×1, except Raspberry and Blackberry bushes at 1×2 (2×1 when mirrored) | Approximation (data) + Community (`items_research.json`) |
| Decorative tree | varies | per item |
| Path / road / tile decorations | 1×1 | Approximation (data) |
| Fence / wall / hedge piece | 1×1 | Approximation (data) |
| Production buildings: 40 machines | 2×2 | Community (wiki infobox) |
| Bakery, Cake Oven, Feed Mill, Pie Oven, Popcorn Pot, Salad Bar, Sandwich Bar, Sauce Maker | 3×3 | Community |
| Dairy | 4×4 | Community |
| Ice Cream Maker | 3×2 (rotating swaps it to 2×3) | Community |
| Temporary event machines (Easter Egg Maker, Birthday Balloon Maker, Gift Wrapping Station, Halloween Treats Maker, Enchanted Workshop) | not documented | Unverified |
| Barn, Silo | at most 4×4 (free space around them in the 2013 data) | Approximation (upper bound) |
| Animal homes (coop, pastures, pens, pet houses) | at most 3×3 to 4×4 by our 2013 upper bounds (chicken-coop type at most 3×3). The sibling item research reports Chicken Coop 3×3, other farm-animal pens 4×4, and Beehive Tree and Squirrel House 2×2, which is consistent with those bounds. | Approximation / Community (`items_research.json`) |
| Decorations | per item, from 1×1 up to large multi-tile pieces | per-item research (see `data/research/items_research.json`) |

### 4.2 Overlap and bounds

* **No overlap, ever.** Support *The Shop*: "You can purchase an item by dragging it onto a *free*
  space." Every layout we examined (2013 data) has non-overlapping footprints. (Confirmed + Approximation)
* Items must lie fully on **owned** tiles: unlocked land, not locked plots, not the road, not fixed scenery
  and not natural obstacles (Community).
* Decorative animals and pets need free tiles to walk on. Support *Farm Animals*: "It is possible for
  Decorative Animals to get stuck. If your Farm is crowded, consider reorganizing". (Confirmed.) A
  planner might warn about fully enclosed areas, but this is not required.

### 4.3 Rotation is a mirror flip (per object)

* The UI has a rotate button. Wiki *Glossary*: the switch icon means "Rotate the item". Wiki
  *Decorations*: decorations "can be moved, stored, and/or rotated by holding a finger over the item".
  Wiki *Farm*: fields, trees and bushes "can be rotated". A rotating tool has existed since v0.4 (2012
  patch note "Customize your farm with the new rotating tool"). (Confirmed / Community)
* **Data model:** each placed object stores only a boolean **`Mirrored`**. There is no 4-way angle.
  Mirroring an isometric sprite horizontally swaps the two ground axes, so a W×H footprint becomes H×W.
  Treat "rotate" as a toggle between two facings. (Approximation, 2013 data)
* **Evidence that mirroring swaps the footprint:** Greg's 2013 farm has 23 instances of two 1×2 bush
  types, 13 of them mirrored. If mirrored instances are treated as 2×1, the layout has **0** overlapping
  cells. If every instance is treated as 1×2, there are **6** overlapping cells. Unmirrored ones sit 2
  tiles apart along Y, and mirrored ones sit 2 tiles apart along X. (Approximation, high confidence)
* **Which items:** in Greg's 2013 farm the flag appears on decorations (incl. fences), fields, production
  buildings, animal homes and fruit trees. It **never** appears on path tiles (466 instances). The Mine
  "cannot be moved or rotated". Fixed scenery cannot rotate. Store per item a `rotatable` flag (default
  true for movable items, false for path/ground tiles). (Approximation / Community)
* **Dec 2025 (v1.68) patch note** (Confirmed): "Rotate decorations, bushes, and trees even if they don't
  fit yet, perfect for planning layouts!". A rotation can make an item temporarily invalid. The planner
  should allow the rotation and then show the item as blocked, rather than refusing the rotation.

### 4.4 Fences, walls, hedges and paths: connections

* **Community (2015 player Q&A, chaptercheats):** "When I buy a fence section it comes as a post…" →
  "you need at least two posts to create a fence… to create a corner you will need three posts… the same
  applies with the hedges and paths." So pieces **auto-connect** to orthogonal neighbours of the same
  item: a lone piece is a post, two in a row form a rail, and an L of three forms a corner. (Community-reported)
* **2013 client data** (Approximation) is mixed. In Greg's farm the fence pieces carry a `Mirrored` flag
  that mostly follows the run direction: pieces in runs along X are unmirrored and pieces in runs along Y
  are mirrored.
  * Fence type A: 24 of 26 straight-run pieces follow this pattern.
  * Fence type B: all 9 X-run pieces are unmirrored, but only 6 of 14 Y-run pieces are mirrored.

  So the flag may have been set by hand in old versions, or it may be ignored once auto-connect draws the
  piece. Rectangle corners are often occupied by a *different* decoration (a post or ornament item). Path
  tiles never have a mirror flag, which suggests auto-tiling for paths.
* **Recommendation:** implement **auto-connect for fence-type and path-type items** using a 4-neighbour
  bitmask (16 variants: end, straight, corner, T, cross) over items of the **same type**. Derive the
  facing automatically. Don't connect across different fence types (Unverified). Verify T and cross
  junctions in-game.
* Fence & path items on the wiki (*Decorations/Fences & Paths*, 25 permanent shop items): Brown Path,
  White Path, Bright Path, Fence, Stone Path, Stone Wall, Ditch, Trail, Rose Fence (White, Yellow,
  Orange, Pink, Red), Rope Fence, Hedge, Trail Path, Flower Hedge, Brick Wall, Golden Wall, Limestone
  Road, Stone Road, Gravel Path, Pebble Road, Cobblestone Path, Golden Path. Later or seasonal additions
  include Railroad Fence and Flower Tile (May 2023 patch), train track (2021, "design your railroad path"),
  Festive Fence, Poolside Fence, and Star/Checkered/Lemon/Disco tiles (collections/packages).
* **Animals on paths:** "Now all your pets can walk on paths" (v1.18 patch, May 2014: Confirmed). Pets
  roam over free tiles and paths. Farm animals stay inside their home. Decorative animals (butterflies,
  frogs, birds, foxes) spawn near flowers, ponds, birdhouses and bushes (Confirmed: support *Farm Animals*).

### 4.5 Storage

* **Decorations:** hold the item, tap the cardboard icon, and it goes to the Shop's **"Storage"
  subcategory** in the Decorations tab. Multiple copies stack with a count. "You cannot buy Decorations
  that are being stored… Stored Decorations must be placed before you can purchase more of them."
  (Confirmed: support *The Shop*.) Decorations don't use barn space (Community).
* **Buildings / fields / trees / animal homes:** they cannot be sold or stored during normal play
  (Community: wiki *Buildings*). They *can* be stored inside an Edit Mode layout (below).

### 4.6 Edit Mode (layout editor)

* Unlocks at **farm level 23** (town edit mode at level 34). (Confirmed: support *Edit Mode*; the wiki
  *Edit_Mode* page saying 37 is wrong.)
* 2 layout slots per area to start with. More slots cost diamonds (wiki: 20 / 40 / 80). Farm and town
  slots are bought separately. One layout is **Active**. A layout can only be set active once **all
  essential items are placed**: buildings, machines, trees, fields, bushes, pets and animal habitats.
  Decorations are optional. New layouts start with everything in storage. Unfinished layouts can be
  saved. (Confirmed: support; Community: wiki)
* Tools: **paintbrush** to place repeated copies of the same item in rows (fields, trees, bushes,
  decorations), **eraser** to store each item you tap or swipe over, **undo**, **"store all"** by
  category (all fields & animal homes; all production buildings; all trees & bushes; all decorations),
  and buying from the shop inside Edit Mode. (Confirmed: support *Edit Mode*)
* Placement highlight: we found **no source** for the colour of the valid/invalid footprint. Showing a
  green/red tile overlay is the genre convention (Unverified).
* Related official feature: the **Design Festival** (level 23) gives each player a separate "canvas area"
  to decorate with owned decorations, which stay where they are on the farm. At least 5 decorations are
  needed to submit, and other players vote on the designs. (Confirmed: support *Design Festival*.) It is a
  useful precedent for a "sandbox" outside the real farm.
* **Scenic Mode** hides all UI for screenshots (Confirmed). Useful as a reference for a "clean render"
  export.

---

## 5. Existing third-party Hay Day planners and tools

We found **no interactive Hay Day farm-layout planner** on the web, in app stores or on GitHub
(searched 2026-11-09).

| Tool | What it is | Status |
|---|---|---|
| In-game **Edit Mode** | official multi-layout editor (§4.6) | current |
| In-game **Design Festival** | official decorate-a-canvas contest | current, periodic |
| "Planner for HayDay" (iOS, id956773253) | production/barn planner, not layout | App Store page returns 404 (delisted) |
| "Layouts of Hay Day" (Android, com.csem.layoutsofhayday) | gallery of sample layout pictures (2015) | not an editor |
| Supercell Make "Creating a Farm Design" (<https://make.supercell.com/en/create/hayday/farm-design>) | official community-creation brief for farm designs | JS-only page; content not retrievable here |
| German Hay Day forum thread (2015) | users asked for an online planner and were told "there is nothing that does this for you" | <https://hayday-forum.de/thread/107685-online-farm-gestalten-planer-f%C3%BCr-hay-day/> |
| GitHub: JJCUBER/HayDayImageGeneratorSite, RaghavMaskara21/HayDayPriceCalculator, castroavila/hayday (item dependency graph), Th1nhNg0/hayday (schedule) | trading/listing/production helpers | none do layout |
| GitHub: Blueve/HayDayDecoder, proydakov/supercell-resource-decoder, sc-workshop/SupercellFlash, frmnnet/HayDay-1.5.42 | client-file decoders / private server | **do not use**: data extraction breaches the ToS (see LEGAL_AND_LICENSING.md) |

Generic farm planners exist for other games, such as Stardew Valley Planner (stardew.info). Their feature
set is a useful baseline: grid overlay, paint tools, save/share links, item counts, and screenshot export.

---

## 6. Visual conventions

| Topic | Observation | Confidence |
|---|---|---|
| Camera | single fixed isometric view, no rotation, pan and zoom only | Community/Approximation |
| Sprite facing | every sprite is drawn for that one view. The default facing shows the "front" toward the viewer: farmhouse porch and barn door on the lower-left face. A mirrored object is the same bitmap flipped horizontally, so baked lighting flips too. | Approximation (images + data model) |
| Light / shadow | soft painterly light from the upper-left. Rocks and trees are darker on their right/lower-right side, with soft contact shadows under objects offset slightly toward the lower-right. No hard cast shadows. | Approximation (wiki map images) |
| Depth order | standard painter's order for a 2:1 iso grid: draw by increasing front-corner depth `(X+W-1)+(Y+H-1)`, ties broken by X. Tall sprites (trees, silo, farmhouse) overlap the tiles behind them, toward the top of the screen. Ground layers (grass, paths, fields) are drawn before standing objects. | Approximation (genre standard; consistent with screenshots) |
| Locked land | trees, rocks and logs on grass, outlined by a low stone border per plot (2014 map) | Community (wiki images) |

---

## 7. Biggest uncertainties (check in-game)

1. **Starting land 32×32 or 48×32** (and therefore the main strip 85 vs 101 tiles long). Test: in Edit
   Mode on a fresh account, lay a path along each edge and count.
2. **Main subsection widths** 16/8/15/14 (image) vs 17/8/15/13 (wiki). This affects only the u-offsets
   of plots 1-17 and 40-52.
3. **Location and size of the 13 "upper" plots** (≈14×32, one X-end of the farm).
4. **Across-road geometry:** tile sizes and relative placement of the 18 regular and 96 special plots,
   and where the main road and its tiles lie in coordinates.
5. **Fence/path auto-connect details:** T and cross junctions, mixed fence types, gates.
6. **Exact footprints** of barn, silo, animal homes, event machines and most decorations.
7. Whether the **current** game still uses the 2013 tile unit and anchoring. It almost certainly does,
   given the wiki sizes, but this is unverified.

---

## 8. Sources (all accessed 2026-11-09)

Official (Supercell):
* Support: Expanding your Farm: <https://support.supercell.com/hay-day/en/articles/expanding-your-farm.html>
* Support: Edit Mode: <https://support.supercell.com/hay-day/en/articles/edit-mode.html>
* Support: The Shop (storing decorations): <https://support.supercell.com/hay-day/en/articles/the-shop.html>
* Support: Farm Animals (pets, decorative animals): <https://support.supercell.com/hay-day/en/articles/farm-animals.html>
* Support: Decorations / Custom Decorations / Decoration Collection: <https://support.supercell.com/hay-day/en/articles/decorations-3.html>, <https://support.supercell.com/hay-day/en/articles/custom-decorations.html>, <https://support.supercell.com/hay-day/en/articles/decoration-collection.html>
* Support: Design Festival, Scenic Mode, The Basics (Maggie): <https://support.supercell.com/hay-day/en/articles/design-festival-2.html>, <https://support.supercell.com/hay-day/en/articles/scenic-mode.html>, <https://support.supercell.com/hay-day/en/articles/the-basics.html>
* Patch notes (transcribed on the wiki): <https://hayday.fandom.com/wiki/Update>

Community (Hay Day Fandom wiki, CC BY-SA, fetched via the MediaWiki API):
* <https://hayday.fandom.com/wiki/Expansion/Farm> (rev. 108499, 2025-09-21), <https://hayday.fandom.com/wiki/Expansion>, <https://hayday.fandom.com/wiki/Expansion_Permit>
* Maps: <https://hayday.fandom.com/wiki/File:Farm_Expansions.png> (+ older revisions 2014/2015), <https://hayday.fandom.com/wiki/File:Hay_Day_Upper_plots.jpg>, <https://hayday.fandom.com/wiki/File:Farm_Expansions_2.png>, <https://hayday.fandom.com/wiki/File:Farm_Expansions_3.jpeg>, <https://hayday.fandom.com/wiki/File:Farm_Expansions_Special.png>, <https://hayday.fandom.com/wiki/File:Permits_vs_Lems.jpg>, <https://hayday.fandom.com/wiki/File:Hay_Day_Lower_plots.jpg>, <https://hayday.fandom.com/wiki/File:Farm_expansion_Spring_2023_(2).png>, <https://hayday.fandom.com/wiki/File:Farm_Map.png>, <https://hayday.fandom.com/wiki/File:Farm_Map2.png>
* <https://hayday.fandom.com/wiki/Farm>, <https://hayday.fandom.com/wiki/Edit_Mode>, <https://hayday.fandom.com/wiki/Decorations>, <https://hayday.fandom.com/wiki/Decorations/Fences_%26_Paths>, <https://hayday.fandom.com/wiki/Decorations/Expansion>, <https://hayday.fandom.com/wiki/Glossary>, <https://hayday.fandom.com/wiki/Buildings>, <https://hayday.fandom.com/wiki/Mine>, <https://hayday.fandom.com/wiki/Truck>, <https://hayday.fandom.com/wiki/Helpers%27_House>, <https://hayday.fandom.com/wiki/Tom>, <https://hayday.fandom.com/wiki/Mailbox>, production-building pages (infobox `size`)

Other community:
* Fence/hedge/path Q&A (2015): <https://www.chaptercheats.com/qna/iphone-ipod/105465/Hay-Day-Answers.htm?qid=128069>
* German Hay Day forum, "Online Farm gestalten – Planer für Hay Day?" (2015): <https://hayday-forum.de/thread/107685-online-farm-gestalten-planer-f%C3%BCr-hay-day/>

Old client data (only individual facts cited, Unverified):
* <https://raw.githubusercontent.com/frmnnet/HayDay-1.5.42/master/JSON/home.json> and `.../JSON/ai.json` (Hay Day 1.5.42, January 2013)
