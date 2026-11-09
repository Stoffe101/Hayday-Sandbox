# Known uncertainties (research)

Verified: 2026-11-09. Ranked by impact on layout accuracy. Each has a concrete way to resolve it.

| # | Uncertainty | Current handling | Confidence | How to resolve |
|---|---|---|---|---|
| 1 | Starting land 32×32 (H2) or 48×32 (H1) | Two maps; H2 default | Approximation (H2 mildly favoured by 2013 start-object positions) | Count tiles along the road edge of an unexpanded farm in-game |
| 2 | Main-section plot shapes/widths (16/8/15/14 measured vs 17/8/15/13 text) | Tile map from wiki image | Approximation | Trace a full-expansion screenshot with the reference tool |
| 3 | Location/shape of 13 upper plots (≈14×32) | Listed, not drawn | Unverified | Screenshot of an expanded farm |
| 4 | Across-road sections (18 regular + 96 special plots) geometry | Listed, area shown restricted | Unknown (costs are community) | Screenshots; wiki images give rough layout only |
| 5 | Footprints of Barn, Silo, Farmhouse, truck/order board, roadside shop, pet houses | Flagged provisional sizes | Unknown | Count tiles in edit mode |
| 6 | Field footprint 1×1 | From 2013 client data | Unverified | Edit-mode tile count |
| 7 | Decoration footprints (≈1,800) | Single Russian-wiki data module | Community | Spot-check common items in edit mode |
| 8 | Unlock level / price conflicts (e.g. Bakery L4 vs L2, Feed Mill L2 vs L3, Goat Yard 1,000 vs 20 coins) | Wiki infobox value kept; disagreement in notes | Community | In-game shop |
| 9 | Fence/path connection shapes (T/cross for all types?) | All 16 shapes rendered for placeholders | Community (2015 Q&A) | Place a cross of each type in-game |
| 10 | Which items are flippable | Wiki "most items" + exceptions (paths, Mine) | Community | In-game rotate button |
| 11 | Fixed vs movable buildings (farmhouse, truck, roadside shop, mailbox fixed) | `movable:false` + locked by default | Community | Edit mode |
| 12 | Max counts per item (only production buildings recorded) | `max_count` where known | Community | Shop |

See `PLACEMENT_RESEARCH.md` (§7) and `ITEM_DATA_RESEARCH.md` (Discrepancies) for evidence and sources.
