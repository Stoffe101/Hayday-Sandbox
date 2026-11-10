#!/usr/bin/env python3
"""Build the structured price database data/prices/hayday_prices.json from researched facts.

Inputs
  data/items/*.json                    the catalogue (ids, `cost` {coins, diamonds, other}, `notes`, `max_count`)
  data/research/items_research.json    fan-wiki research records (per-copy "instances:" schedules)
  VERIFIED_* tables below              facts re-checked by hand on the wikis on 2026-11-10
                                       (see docs/research/PRICING_RESEARCH.md for every finding)
Output
  data/prices/hayday_prices.json       schema "hayday-sandbox-prices" v1 (docs/PLANNING.md section 1)

Rules
  * Never invent a price. Unknown stays unknown (no `price`), "cannot be bought" is a method
    (`reward`, `not_in_shop`), never a 0.
  * The ru-wiki "999 diamonds" value is a placeholder meaning "not sold": method `not_in_shop`, no price.
  * Removal tools (obstacles) and repair costs (pre-placed farm buildings) are not purchase prices: they go to
    `removal` / `repair`, never to `price`.
  * Routes come only from the catalogue hints ("en list: <group>", "obtained via: ...") and are mapped
    conservatively; anything that does not map cleanly becomes "other".
  * Deterministic: same inputs -> byte-identical output (sorted ids, fixed `generated` date).

Usage: python3 tools/catalog/build_prices.py [--report]
  --report  also print the Markdown coverage tables used in docs/research/PRICING_RESEARCH.md
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ITEMS_DIR = ROOT / "data/items"
RESEARCH = ROOT / "data/research/items_research.json"
OUT = ROOT / "data/prices/hayday_prices.json"

GENERATED = "2026-11-10"
RESEARCH_DATE = "2026-11-09"   # items_research.json verification date
VERIFY_DATE = "2026-11-10"     # hand checks for this file
LICENSE = "CC BY-SA 3.0"
W = "https://hayday.fandom.com/wiki/"
RU = "https://hayday.fandom.com/ru/wiki/"
DE = "https://hayday.fandom.com/de/wiki/"

METHODS = ("shop", "vouchers", "event_currency", "reward", "not_in_shop", "free", "unknown")

# --------------------------------------------------------------------------- sources

SOURCES = [
    # research inputs (via data/research/items_research.json, see ITEM_DATA_RESEARCH.md)
    {"id": "ru_module_decorations", "url": RU + "Модуль:Все_украшения", "accessed": RESEARCH_DATE,
     "license": LICENSE, "used_for": "decoration price, increment, currency, sources (obtained via), theme",
     "via": "items_research.json (module rev 2026-09-29)"},
    {"id": "ru_module_trees", "url": RU + "Модуль:Все_деревья_и_кусты", "accessed": RESEARCH_DATE,
     "license": LICENSE, "used_for": "tree and bush prices (cross-check)", "via": "items_research.json"},
    {"id": "en_item_pages", "url": W + "Category:Production_Buildings", "accessed": RESEARCH_DATE,
     "license": LICENSE, "used_for": "infobox prices of production buildings, animal homes, trees, farm buildings "
     "(each item's own page is in the catalogue `sources`)", "via": "items_research.json"},
    {"id": "en_production_list", "url": W + "Production_Buildings_List", "accessed": RESEARCH_DATE,
     "license": LICENSE, "used_for": "per-copy prices and levels of multi-copy buildings (instances)",
     "via": "items_research.json (rev 2026-10-29)"},
    {"id": "en_animal_shelters", "url": W + "Animal_Shelters", "accessed": RESEARCH_DATE, "license": LICENSE,
     "used_for": "number of houses per shelter and the level of each house", "via": "items_research.json"},
    {"id": "en_decoration_lists", "url": W + "Decorations", "accessed": RESEARCH_DATE, "license": LICENSE,
     "used_for": "en list group (shop tab or how obtained) and cost of each decoration, for cross-checks "
     "(subpages Decorations/Fences_&_Paths, /Nature, /Farming, /Ornaments, /Seasonal, /Sanctuary, /Derby, ...)",
     "via": "items_research.json"},
    {"id": "de_feld", "url": DE + "Feld", "accessed": RESEARCH_DATE, "license": LICENSE,
     "used_for": "crop field price (1 coin each)", "via": "items_research.json (rev 2022-05-23)"},
    {"id": "en_farm", "url": W + "Farm", "accessed": RESEARCH_DATE, "license": LICENSE,
     "used_for": "natural obstacles: removed with tools, cannot be bought back", "via": "items_research.json"},
    # hand checks for this file
    {"id": "en_decorations_page", "url": W + "Decorations", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "storing: a stored decoration goes back to the shop and no more of that type can be bought "
     "while one is stored", "revision": 109109},
    {"id": "en_shop", "url": W + "Shop", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "stored items must be used before buying another; shop tabs", "revision": 106752},
    {"id": "ru_decorations_page", "url": RU + "Украшения", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "decorations bought with coins get more expensive after every purchase", "revision": 28189},
    {"id": "ru_shop", "url": RU + "Магазин", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "what the shop sells (fields, animals, pens, trees and bushes, production buildings, decorations)",
     "revision": 22175},
    {"id": "de_dekorationen", "url": DE + "Dekorationen", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "coin decorations get more expensive the more of them you buy; storing blocks buying",
     "revision": 41351},
    {"id": "de_zaun", "url": DE + "Zaun", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "fence step (+5 per fence, disagrees with en/ru +2)", "revision": 40506},
    {"id": "en_feed_mill", "url": W + "Feed_Mill", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "1st 5 coins, 2nd 3,200 coins", "revision": 110762},
    {"id": "en_sugar_mill", "url": W + "Sugar_Mill", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "1st 350 coins (L7), 2nd 199,750 coins (L76)", "revision": 110894},
    {"id": "en_smelter", "url": W + "Smelter", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "5 smelters: 12,500 / 22,000 / 31,500 / 41,000 / 50,500 coins (+9,500 each)", "revision": 105622},
    {"id": "en_animal_home_pages", "url": W + "Category:Animal_Shelters", "accessed": VERIFY_DATE,
     "license": LICENSE, "used_for": "'Each <house> costs N coins' on all 18 shelter pages (revisions 2026-06-08 "
     "to 2026-09-03)"},
    {"id": "en_tree_pages", "url": W + "Trees_and_Bushes", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "'can be purchased in the shop for N coins each' on the tree/bush pages (Apple, Cherry, "
     "Raspberry, Blueberry, Coffee, Banana, Nectar, Peanut); no progression stated", "revision": 109601},
    {"id": "en_temporary_machines", "url": W + "Gift_Wrapping_Station", "accessed": VERIFY_DATE,
     "license": LICENSE, "used_for": "seasonal machines 'do not need to be repaired or bought' and are given for "
     "free (Gift Wrapping Station rev 109015, Easter Egg Maker rev 109704)"},
    {"id": "en_supplies", "url": W + "Land_Deed", "accessed": VERIFY_DATE, "license": LICENSE,
     "used_for": "expansion supplies: no fixed coin price (roadside shops 1-403 coins, 12-diamond packet, random "
     "drops); permits cannot be bought or sold (pages Land Deed, Mallet, Marker Stake, Expansion Permit)"},
]
SOURCE_IDS = {s["id"] for s in SOURCES}

CURRENCIES = {
    "coins": {"name": "Coins"},
    "diamonds": {"name": "Diamonds"},
    "voucher_green": {"name": "Green vouchers"},
    "voucher_blue": {"name": "Blue vouchers"},
    "voucher_purple": {"name": "Purple vouchers"},
    "voucher_gold": {"name": "Gold vouchers"},
    "film": {"name": "Film (event currency)"},
    "golden_keys": {"name": "Golden keys"},
    "land_deed": {"name": "Land deeds", "notes": "Expansion supply. No fixed coin price: bought from other "
                  "players' roadside shops (1-403 coins each), as a 12-diamond packet, or found randomly.",
                  "sources": ["en_supplies"]},
    "mallet": {"name": "Mallets", "notes": "Expansion supply; same ways to get as land deeds.",
               "sources": ["en_supplies"]},
    "marker_stake": {"name": "Marker stakes", "notes": "Expansion supply; same ways to get as land deeds.",
                     "sources": ["en_supplies"]},
    "expansion_permit": {"name": "Expansion permits", "notes": "Cannot be bought or sold (Wheel of Fortune, "
                         "derby checkpoints, ...).", "sources": ["en_supplies"]},
}

RULES = {
    "step": {
        "value": "Decorations bought with coins cost more with every copy: copy k costs price + step x (k-1). "
                 "The wikis word it as 'per purchase' (en), 'after every purchase' (ru), 'the more you buy' (de).",
        "confidence": "community", "sources": ["en_decoration_lists", "ru_decorations_page", "de_dekorationen"]},
    "step_basis": {
        "value": "Stored copies cannot be the reason a price drops: while any copy of a decoration is stored, no "
                 "more of it can be bought, so at every purchase owned = placed. Not established: whether "
                 "deleting a copy, or copies received for free (rewards), change the next price. step_basis "
                 "'copies_owned' is therefore an assumption.",
        "confidence": "unverified", "sources": ["en_decorations_page", "en_shop", "de_dekorationen"]},
    "flat_prices": {
        "value": "Fruit trees, bushes and animal homes: the wiki pages say each copy costs the same ('N coins "
                 "each', 'Each house costs N'). Diamond- and voucher-priced decorations have no step in any source.",
        "confidence": "community", "sources": ["en_tree_pages", "en_animal_home_pages", "ru_decorations_page"]},
    "expansion_supplies": {
        "value": "Expansion supplies have no fixed shop price; plot costs in supplies are in data/maps.",
        "confidence": "community", "sources": ["en_supplies"]},
}

# --------------------------------------------------------------------------- hand-verified facts (2026-11-10)

# Explicit per-copy prices. `instances:` notes in the research give the same Feed Mill and Smelter values; for the
# 2nd Sugar Mill the en list says 200,000 but the en infobox, the page text and the ru infobox say 199,750.
VERIFIED_SCHEDULES = {
    "feed_mill": {"schedule": [5, 3200], "copy_levels": [2, 12], "sources": ["en_feed_mill"],
                  "confidence": "community"},
    "sugar_mill": {"schedule": [350, 199750], "copy_levels": [7, 76], "sources": ["en_sugar_mill"],
                   "confidence": "community",
                   "note": "2nd copy: en infobox, page text and ru infobox 199,750; en Production Buildings List "
                           "200,000"},
    "smelter": {"schedule": [12500, 22000, 31500, 41000, 50500], "copy_levels": [24, 24, 24, 24, 24],
                "sources": ["en_smelter"], "confidence": "community",
                "note": "en page: each smelter costs 9,500 coins more than the previous one"},
}
# Shelter pages checked on 2026-11-10: "Each <house> costs N coins" (or a single house) with N = catalogue price.
VERIFIED_FLAT_HOMES = {
    "alpaca_house", "beehive_tree", "bird_house", "bunny_house", "cat_house", "chicken_coop", "cow_pasture",
    "dog_house", "donkey_stable", "goat_yard", "guinea_pig_house", "horse_stable", "kitten_house", "lamb_pasture",
    "pig_pen", "puppy_house", "sheep_pasture", "squirrel_house",
}
VERIFIED_FLAT_TREES = {"apple_tree", "cherry_tree", "raspberry_bush", "blueberry_bush", "coffee_bush",
                       "banana_tree", "nectar_bush", "peanut_bush"}
VERIFIED_FREE_MACHINES = {"gift_wrapping_station", "easter_egg_maker"}
STEP_NOTES = {
    "fence": "de wiki (Zaun, 2024) says each fence makes the next one 5 coins dearer; en list and ru module say +2",
}

# --------------------------------------------------------------------------- hint maps

SHOP_TABS = {"Nature", "Farming", "Ornaments", "Fences & Paths", "Seasonal", "Sanctuary"}
PERMANENT_TABS = {"Nature", "Farming", "Ornaments", "Fences & Paths", "Sanctuary"}
EN_GROUP_ROUTE = {
    "Derby": "derby", "Events": "event", "Packages": "package", "Secrets": "secret", "Rewards": "reward",
    "Expansion": "expansion", "Pass Road": "season_pass",
    "Valley": "other", "Calendar": "other", "Catalogue": "other", "Custom": "other",
}
OBTAINED_ROUTE = {
    "derby": "derby", "special-currency event": "event", "global event": "event", "task event": "event",
    "county fair": "event", "event": "event", "currency-shop offer": "package", "Farm Pass": "season_pass",
    "expansion plot": "expansion", "collection": "collection",
}
ROUTE_ORDER = ["derby", "event", "package", "secret", "reward", "collection", "expansion", "season_pass", "other"]
VOUCHER = {"green": "voucher_green", "blue": "voucher_blue", "purple": "voucher_purple", "gold": "voucher_gold"}
EN_ICON = {"coin": "coins", "dia": "diamonds", "greenv": "voucher_green", "bluev": "voucher_blue",
           "purplev": "voucher_purple", "goldv": "voucher_gold"}
TOOLS = {"axe": "axe", "saw": "saw", "shovel": "shovel", "dynamite": "dynamite", "tnt barrel": "tnt_barrel",
         "pickaxe": "pickaxe"}


# --------------------------------------------------------------------------- helpers

def note_parts(notes: str) -> list[str]:
    return [p.strip() for p in re.split(r";\s|\s\|\s", notes or "") if p.strip()]


def to_int(s: str) -> int:
    return int(s.replace(",", ""))


def parse_en_list(parts: list[str]) -> tuple[str | None, str | None, dict | None, int | None]:
    """'en list: <Group>[ / Sub][ L<n>][ cost '<cost>']' -> (group, raw cost, cost dict, step)."""
    for p in parts:
        if not p.startswith("en list: ") or p.startswith("en list: size not stated"):
            continue
        m = re.match(r"en list: (?P<g>.+?)(?: L\d+)?(?: cost '(?P<c>[^']*)')?$", p)
        if not m:
            continue
        group = re.split(r"\s*/\s*", m.group("g"))[0].strip()
        raw = m.group("c")
        if raw is None or raw.strip() in ("", "?"):
            return group, raw, None, None
        step = None
        sm = re.search(r"\+\s*([\d,]+)\s*per purchase", raw)
        if sm:
            step = to_int(sm.group(1))
        cost = {}
        for cm in re.finditer(r"([\d,]+)\s*\[(\w+)\]", raw):
            cost[EN_ICON.get(cm.group(2), cm.group(2))] = to_int(cm.group(1))
        return group, raw, (cost or None), step
    return None, None, None, None


def obtained_via(parts: list[str]) -> list[str]:
    for p in parts:
        if p.startswith("obtained via: "):
            return [t.strip() for t in p[len("obtained via: "):].split(",") if t.strip()]
    return []


def parse_instances(notes: str) -> list[tuple[int, int]]:
    m = re.search(r"instances: ((?:#\d+: L\d+, \d+ coins(?:, )?)+)", notes or "")
    if not m:
        return []
    return [(int(a), int(b)) for a, b in re.findall(r"#\d+: L(\d+), (\d+) coins", m.group(1))]


def sort_routes(routes: set[str]) -> list[str]:
    return [r for r in ROUTE_ORDER if r in routes]


def load_catalogue() -> list[dict]:
    items = []
    for f in sorted(ITEMS_DIR.glob("*.json")):
        if f.name == "categories.json":
            continue
        items += json.loads(f.read_text(encoding="utf-8")).get("items", [])
    return items


def load_research_instances() -> dict[str, list[tuple[int, int]]]:
    """research name -> instances (the catalogue notes carry the same text; used as a consistency check)."""
    out = {}
    for r in json.loads(RESEARCH.read_text(encoding="utf-8")):
        inst = parse_instances(r.get("notes", ""))
        if inst:
            out[r["name"].lower()] = inst
    return out


# --------------------------------------------------------------------------- record builder

def build_record(it: dict, research_inst: dict) -> dict | None:
    iid, cat = it["id"], it["category"]
    if cat == "planning":
        return None   # editor-only markers, not game items
    cost = it.get("cost") or {}
    coins, dias = cost.get("coins"), cost.get("diamonds")
    other = (cost.get("other") or "").strip()
    notes_txt = it.get("notes", "")
    parts = note_parts(notes_txt)
    group, en_raw, en_cost, en_step = parse_en_list(parts)
    via = obtained_via(parts)
    theme = next((p.split("=", 1)[1] for p in parts if p.startswith("seasonal=")), None)
    temp_machine = any(p.startswith("temporary/seasonal event machine") for p in parts)
    from_ru = any("hayday.fandom.com/ru/" in s for s in it.get("sources", [])) and \
        "not found in ru-wiki decoration module" not in notes_txt
    cost_conflict = next((p for p in parts if p.startswith("coin cost differs")), None)
    is_deco = cat in ("fence", "path", "water", "flowers", "nature", "furniture", "structures", "seasonal",
                      "decoration")

    rec: dict = {"method": "unknown"}
    price: dict | None = None
    step: dict | None = None
    notes: list[str] = []
    sources: list[str] = []
    conf = "community"
    availability = "unknown"
    routes: set[str] = set()

    # ---- method + price
    removal = re.match(r"removal tool: (.+)$", other, re.I)
    if removal:
        rec["method"] = "not_in_shop"
        tool = removal.group(1).strip().lower()
        rec["removal"] = {"tool": TOOLS.get(tool, re.sub(r"\W+", "_", tool))}
        notes.append("pre-placed natural obstacle: removed with a tool, cannot be bought back")
        sources.append("en_farm")
    elif cat == "farm_building":
        rec["method"] = "not_in_shop"
        sources += ["en_item_pages", "ru_shop"]
        rep = next((p for p in parts if p.startswith("repair ")), None)
        if coins is not None and rep:
            rec["repair"] = {"coins": int(coins)}
            dm = re.search(r"or ([\d,]+) diamonds", rep)
            notes.append("one-time repair of a pre-placed building, not a shop purchase" +
                         (f" (or {to_int(dm.group(1))} diamonds to finish at once)" if dm else ""))
        else:
            notes.append("part of the farm (pre-placed or unlocked by level); the shop does not sell farm buildings")
    elif "placeholder" in other:
        rec["method"] = "not_in_shop"
        notes.append("source lists 999 diamonds, a placeholder for 'not sold in the shop'")
    elif other.startswith("no price in source"):
        rec["method"] = "reward"
        notes.append("prize/reward variant without a price")
    elif other == "free" or coins == 0:
        rec["method"] = "free"
        price = {"coins": 0}
        if iid in VERIFIED_FREE_MACHINES:
            notes.append("given for free during its season (does not need to be repaired or bought)")
            sources.append("en_temporary_machines")
        elif temp_machine:
            notes.append("price 0 in the en production list (not re-checked)")
    elif re.search(r"\bfilm\b", other):
        rec["method"] = "event_currency"
        price = {"film": to_int(re.search(r"([\d,]+)\s*film", other).group(1))}
    elif "golden key" in other:
        rec["method"] = "event_currency"
        price = {"golden_keys": to_int(re.search(r"([\d,]+)\s*golden key", other).group(1))}
    elif "voucher" in other:
        rec["method"] = "vouchers"
        price = {VOUCHER[c]: int(n) for n, c in re.findall(r"(\d+) (green|blue|purple|gold) voucher", other)}
    elif coins is not None or dias is not None:
        rec["method"] = "shop"
        price = {}
        if coins is not None:
            price["coins"] = int(coins)
        if dias is not None:
            price["diamonds"] = int(dias)
        sm = re.match(r"\+(\d+) coins per additional purchase$", other)
        if sm:
            step = {"coins": int(sm.group(1))}
        elif other:
            notes.append("catalogue cost note: " + other)
    elif group in ("Derby", "Rewards"):
        rec["method"] = "reward"
    elif group in EN_GROUP_ROUTE:
        rec["method"] = "not_in_shop"
    elif temp_machine:
        notes.append("temporary event machine; no price in any source")

    # ---- routes (non-purchase methods only)
    if rec["method"] not in ("shop", "vouchers", "free"):
        if group in EN_GROUP_ROUTE:
            routes.add(EN_GROUP_ROUTE[group])
        for t in via:
            if t != "shop":
                routes.add(OBTAINED_ROUTE.get(t, "other"))
        if rec["method"] == "event_currency":
            routes.add("event")
    hints = ([f"en list: {group}"] if group and group not in SHOP_TABS else []) + \
            ([f"obtained via: {', '.join(via)}"] if via else [])
    if hints and rec["method"] not in ("shop", "vouchers"):
        notes.append("; ".join(hints))

    # ---- sources and confidence per family
    if cat in ("production",):
        sources += ["en_item_pages", "en_production_list"]
    elif cat == "animal_home":
        sources += ["en_item_pages", "en_animal_shelters"]
        if iid in VERIFIED_FLAT_HOMES:
            sources.append("en_animal_home_pages")
    elif cat in ("fruit_tree", "bush"):
        sources += ["en_item_pages"]
        if from_ru or iid not in ("nectar_bush", "peanut_bush"):
            sources.append("ru_module_trees")
            conf = "confirmed"   # en infobox and ru module agree on every tree/bush price (ITEM_DATA_RESEARCH.md)
        if iid in VERIFIED_FLAT_TREES:
            sources.append("en_tree_pages")
    elif cat == "field":
        sources.append("de_feld")
        notes.append("price per field; number of fields is level-gated")
    elif is_deco:
        if from_ru:
            sources.append("ru_module_decorations")
        if group:
            sources.append("en_decoration_lists")

    if is_deco and price and rec["method"] in ("shop", "vouchers") and en_cost is not None:
        if en_cost == price:
            conf = "confirmed"
            notes.append("en list price agrees")
        else:
            conf = "unverified"
            notes.append(f"en list cost differs: '{en_raw}'")
    if cost_conflict:
        conf = "unverified"
        notes.append(cost_conflict)
    if rec["method"] == "unknown":
        conf = "unknown"

    # ---- progressive prices
    sched = None
    copy_levels = None
    if iid in VERIFIED_SCHEDULES:
        v = VERIFIED_SCHEDULES[iid]
        sched = [{"coins": c} for c in v["schedule"]]
        copy_levels = list(v["copy_levels"])
        sources += v["sources"]
        conf = v["confidence"]
        if v.get("note"):
            notes.append(v["note"])
        inst = parse_instances(notes_txt) or research_inst.get(it["name"].lower(), [])
        if inst and [c for _, c in inst] != v["schedule"]:
            notes.append("research instances note: " + ", ".join(f"#{k + 1} {c}" for k, (_, c) in enumerate(inst)))
    else:
        inst = parse_instances(notes_txt) or research_inst.get(it["name"].lower(), [])
        if inst:
            sched = [{"coins": c} for _, c in inst]
            copy_levels = [lv for lv, _ in inst]
    if cat == "animal_home" and price and it.get("max_count") and iid in VERIFIED_FLAT_HOMES:
        n = int(it["max_count"])
        sched = [dict(price) for _ in range(n)]
        lv = next((p for p in parts if p.startswith("one more house unlocks at each level ")), None)
        if lv:
            levels = [int(x) for x in re.findall(r"\d+", lv)]
            if len(levels) == n:
                copy_levels = levels
        notes.append("each house costs the same")
    if sched:
        price = dict(sched[0])
    if step:
        rec_step_conf = "confirmed" if (en_step is not None and en_step == step.get("coins")) else "community"
        if en_cost is not None and en_step is None and en_cost == price:
            notes.append("en list shows no step")
        if en_step is not None and en_step != step.get("coins"):
            rec_step_conf = "unverified"
            notes.append(f"en list step +{en_step} differs")
        if iid in STEP_NOTES:
            rec_step_conf = "unverified"
            notes.append(STEP_NOTES[iid])
            sources.append("de_zaun")

    # ---- availability (evidence only)
    if rec["method"] == "event_currency":
        availability = "event"
    elif temp_machine:
        availability = "seasonal"
    elif rec["method"] in ("shop", "free") and cat in ("production", "animal_home", "fruit_tree", "bush", "field"):
        availability = "current"
    elif rec["method"] in ("shop", "vouchers") and is_deco:
        if group == "Seasonal":
            availability = "seasonal"
        elif theme is None and "monthly decoration" not in via and (
                ("shop" in via and from_ru) or group in PERMANENT_TABS):
            availability = "current"
    elif rec["method"] in ("not_in_shop", "reward") and routes == {"event"}:
        availability = "event"
    if "monthly decoration" in via:
        notes.append("monthly decoration (limited-time shop slot)")
    if theme and rec["method"] in ("shop", "vouchers"):
        notes.append(f"holiday theme: {theme}")

    # ---- assemble (fixed key order)
    out: dict = {"method": rec["method"]}
    if price is not None:
        out["price"] = price
    if step:
        out["step"] = step
        out["step_basis"] = "copies_owned"
        out["step_confidence"] = rec_step_conf
    if sched:
        out["schedule"] = sched
        out["schedule_repeats_last"] = False
        if copy_levels and len(copy_levels) == len(sched):
            out["copy_levels"] = copy_levels
    mc = it.get("max_count")
    out["max_count"] = int(mc) if mc is not None else (len(sched) if sched else None)
    out["availability"] = availability
    out["confidence"] = conf
    if routes:
        out["routes"] = sort_routes(routes)
    for k in ("removal", "repair"):
        if k in rec:
            out[k] = rec[k]
    out["sources"] = list(dict.fromkeys(s for s in sources))
    out["notes"] = "; ".join(dict.fromkeys(notes))
    for s in out["sources"]:
        assert s in SOURCE_IDS, (iid, s)
    return out


# --------------------------------------------------------------------------- coverage

def coverage(items: dict[str, dict], cats: dict[str, str]) -> dict:
    def flags(r):
        p = r.get("price") or {}
        return {
            "coin_price": r["method"] == "shop" and "coins" in p,
            "diamond_price": r["method"] == "shop" and "diamonds" in p,
            "voucher_price": r["method"] == "vouchers" and bool(p),
            "event_price": r["method"] == "event_currency" and bool(p),
            "step": "step" in r,
            "schedule": "schedule" in r,
            "no_price": r["method"] in ("shop", "vouchers", "event_currency", "free", "unknown") and not p,
            "cannot_buy": r["method"] in ("reward", "not_in_shop"),
        }
    by_method = Counter(r["method"] for r in items.values())
    by_cat: dict[str, Counter] = defaultdict(Counter)
    tot = Counter()
    for iid, r in items.items():
        f = flags(r)
        c = by_cat[cats[iid]]
        c["items"] += 1
        c[r["method"]] += 1
        for k, v in f.items():
            if v:
                c[k] += 1
                tot[k] += 1
    return {"by_method": by_method, "by_cat": by_cat, "totals": tot,
            "availability": Counter(r["availability"] for r in items.values()),
            "confidence": Counter(r["confidence"] for r in items.values()),
            "routes": Counter(x for r in items.values() for x in r.get("routes", [])),
            "step_confidence": Counter(r["step_confidence"] for r in items.values() if "step" in r)}


def report(cov: dict, total_catalogue: int, n: int) -> str:
    L = [f"Catalogue items: {total_catalogue}; price records: {n} (the {total_catalogue - n} editor-only planning "
         "markers have none).", "", "| Method | Items |", "|---|---|"]
    for m in METHODS:
        L.append(f"| `{m}` | {cov['by_method'].get(m, 0)} |")
    t = cov["totals"]
    L += ["", "| Known value | Items |", "|---|---|",
          f"| coin price (`shop`) | {t['coin_price']} |", f"| diamond price (`shop`) | {t['diamond_price']} |",
          f"| voucher price | {t['voucher_price']} |", f"| event currency price | {t['event_price']} |",
          f"| free (price 0) | {cov['by_method'].get('free', 0)} |",
          f"| progressive step | {t['step']} |", f"| explicit per-copy schedule | {t['schedule']} |",
          f"| cannot be bought (`reward` + `not_in_shop`) | {t['cannot_buy']} |",
          f"| price unknown (`unknown`, or a buyable method without price) | {t['no_price']} |"]
    cols = ["items", "shop", "vouchers", "event_currency", "free", "reward", "not_in_shop", "unknown",
            "coin_price", "diamond_price", "voucher_price", "event_price", "step", "schedule", "no_price"]
    L += ["", "| Category | " + " | ".join(cols) + " |", "|---" * (len(cols) + 1) + "|"]
    for cat in sorted(cov["by_cat"]):
        c = cov["by_cat"][cat]
        L.append(f"| {cat} | " + " | ".join(str(c.get(k, 0)) for k in cols) + " |")
    L.append("| **total** | " + " | ".join(str(sum(cov["by_cat"][x].get(k, 0) for x in cov["by_cat"]))
                                         for k in cols) + " |")
    for key, title in (("availability", "Availability"), ("confidence", "Confidence"), ("routes", "Route"),
                       ("step_confidence", "Step confidence")):
        L += ["", f"| {title} | Items |", "|---|---|"]
        for k, v in sorted(cov[key].items(), key=lambda kv: (-kv[1], kv[0])):
            L.append(f"| `{k}` | {v} |")
    return "\n".join(L)


def main() -> int:
    catalogue = load_catalogue()
    research_inst = load_research_instances()
    items: dict[str, dict] = {}
    cats: dict[str, str] = {}
    for it in catalogue:
        r = build_record(it, research_inst)
        if r is not None:
            items[it["id"]] = r
            cats[it["id"]] = it["category"]
    doc = {
        "format": "hayday-sandbox-prices", "schema_version": 1,
        "generated": GENERATED, "game_version": "",
        "generated_by": "tools/catalog/build_prices.py",
        "license": "Prices, levels and acquisition hints are facts adapted from the Hay Day Wiki (Fandom) en/ru/de "
                   "pages listed in `sources` (contributors: see each page history), licensed CC BY-SA "
                   "(https://www.fandom.com/licensing). This file is therefore shared under CC BY-SA 3.0.",
        "disclaimer": "This material is unofficial and is not endorsed by Supercell. For more information see "
                      "Supercell's Fan Content Policy: www.supercell.com/fan-content-policy.",
        "schema_notes": "See docs/PLANNING.md section 1 and docs/research/PRICING_RESEARCH.md. confidence: "
                        "confirmed (two independently maintained wiki sources agree) | community (one community "
                        "source) | unverified (sources disagree or rule not established) | unknown.",
        "sources": SOURCES,
        "currencies": CURRENCIES,
        "rules": RULES,
        "items": {k: items[k] for k in sorted(items)},
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    cov = coverage(items, cats)
    print(json.dumps({"records": len(items), "methods": dict(cov["by_method"])}, sort_keys=True))
    if "--report" in sys.argv:
        print(report(cov, len(catalogue), len(items)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
