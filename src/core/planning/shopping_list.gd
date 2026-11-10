class_name ShoppingList
extends RefCounted
## Shopping list rows for a scope (docs/PLANNING.md §4–5): one row per item with
## what is used, owned, acquired and still missing, the price of the next copy
## (and the range when prices rise per copy), the known total and every unknown,
## plus rows for the expansion supplies the scope's locked plots need.
## Pure: acquisition progress lives in plan.acquired and is changed by the UI
## through an undoable SetPlanning command with the dictionaries made here.

const GROUP_DECORATIONS := "Decorations"
const GROUP_SUPPLIES := "Expansion supplies"
const GROUP_OTHER := "Other"
const GROUPS := ["Decorations", "Fences", "Paths", "Trees", "Bushes", "Flowers", "Production machines",
	"Animal homes", "Farm buildings", "Expansion supplies", "Other"]
## ItemDef.category -> group (unlisted categories: Other).
const CATEGORY_GROUPS := {
	"decoration": "Decorations", "furniture": "Decorations", "structures": "Decorations",
	"seasonal": "Decorations", "water": "Decorations",
	"fence": "Fences", "path": "Paths", "nature": "Trees", "fruit_tree": "Trees", "bush": "Bushes",
	"flowers": "Flowers", "production": "Production machines", "animal_home": "Animal homes",
	"farm_building": "Farm buildings",
}
const KIND_ITEM := "item"
const KIND_SUPPLY := "supply"

## filter_rows() states.
const STATE_MISSING := "missing"          ## something still to pay for in this mode
const STATE_COMPLETE := "complete"        ## nothing left to pay for
const STATE_UNKNOWN_PRICE := "unknown_price"
const STATE_NOT_BUYABLE := "not_buyable"
const STATE_OVER_MAX := "over_max"


static func group_of_category(category: String) -> String:
	return str(CATEGORY_GROUPS.get(category, GROUP_OTHER))


static func build(engine: BudgetEngine, uids: Variant = null, mode: String = BudgetEngine.MODE_REMAINING,
		include_land: bool = true) -> Array:
	## Rows (Dictionaries) for `uids` (null = whole farm) in `mode`, sorted by
	## group order then name. Item row keys:
	##   kind "item", item, name, category, group, used, owned, acquired, missing
	##   (still to buy), placed, charged (objects paid for in this mode),
	##   owned_total (effective inventory), owned_known, acquired_total (plan.acquired),
	##   next_price (Cost of the first charged copy or null), price_min / price_max
	##   (Cost or null; differ when progressive), progressive, total (known cost),
	##   unknown_copies, not_buyable_copies, currencies, method, method_text,
	##   buyable, routes, unlock_level (-1 unknown), availability, confidence,
	##   verified, origin, max_count (-1), count_total (whole design), over_max,
	##   sources, notes, info.
	## Supply rows (kind "supply", group "Expansion supplies"): item = currency id,
	##   name, needed, have (balance), missing, plots (ids), unknown_plots.
	## Rows are read-only: an item row is reused by later builds while nothing
	## about its item changed (kept in engine.view_cache), so never modify one.
	## Speed: one engine batch for the whole build; per-item breakdowns from
	## BudgetEngine.item_rollups() (kept per item for the whole farm); rows rebuilt
	## only for items whose breakdown or revision changed; the sort uses cached
	## natural name ranks instead of a script comparator.
	engine.begin_batch()
	var rows: Array = []
	var cache := _row_cache(engine, mode)
	for r: Array in engine.item_rollups(uids, mode):
		var id: String = r[0]
		var e: Dictionary = r[1]
		var c: Variant = cache.get(id)
		if c != null and c[1] == r[2] and (is_same(c[0], e) or c[0] == e):
			rows.append(c[2])
			continue
		var row := _item_row(engine, id, e)
		cache[id] = [e, r[2], row]
		rows.append(row)
	if include_land:
		rows.append_array(supply_rows(engine, uids, mode))
	var out := _sorted_by_group(rows)
	engine.end_batch()
	return out


static func _row_cache(engine: BudgetEngine, mode: String) -> Dictionary:
	## item id -> [breakdown entry, item revision, row] for this engine and mode.
	var pv := engine.prices.version if engine.prices != null else -1
	var key := "shopping_rows/" + mode
	var c: Variant = engine.view_cache.get(key)
	if c == null or int(c["prices"]) != pv or (c["rows"] as Dictionary).size() > 4096:
		c = {"prices": pv, "rows": {}}
		engine.view_cache[key] = c
	return c["rows"]


static func _item_row(engine: BudgetEngine, id: String, e: Dictionary) -> Dictionary:
	## One item row (see build()) from its breakdown entry.
	var pb := engine.prices
	var it: ItemDef = engine.db.get_item(id) if engine.db != null else null
	var st := engine.item_state(id)
	var rec: Dictionary = pb.resolved(id) if pb != null else PriceBook.empty_record()
	var known_item := it != null
	var k_min := int(e["k_min"])
	var k_max := int(e["k_max"])
	var next: Variant = null
	var lo: Variant = null
	var hi: Variant = null
	# PriceBook.record_copy_price(rec, k) == pb.copy_price(id, k) (rec is resolved(id)).
	if known_item and pb != null and int(e["charged"]) > 0:
		next = PriceBook.record_copy_price(rec, k_min)
		lo = next
		hi = PriceBook.record_copy_price(rec, k_max)
	elif known_item and pb != null:
		# Nothing to pay in this scope: show what the next purchase would cost.
		var nk := int(st["purchased"]) + maxi(0, int(st["count"]) - int(st["owned"])) + 1
		next = PriceBook.record_copy_price(rec, nk)
	var total: Dictionary = e["cost"]
	var mc := int(st["max_count"])
	var method_s: String = rec["method"] if known_item else PriceBook.METHOD_UNKNOWN
	return {
		"kind": KIND_ITEM, "item": id, "name": it.name if it != null else id,
		"category": it.category if it != null else "", "group": group_of_category(it.category) if it != null else GROUP_OTHER,
		"used": e["used"], "owned": e["owned"], "acquired": e["acquired"], "missing": e["to_buy"],
		"placed": e["placed"], "charged": e["charged"],
		"owned_total": st["owned"], "owned_known": st["owned_known"], "acquired_total": st["acquired"],
		"next_price": next, "price_min": lo, "price_max": hi, "progressive": bool(rec.get("progressive", false)),
		"total": total, "unknown_copies": e["unknown"], "not_buyable_copies": e["not_buyable"],
		"currencies": Currency.currencies_of(total if not total.is_empty() else next),
		"method": method_s, "method_text": PriceBook.record_method_text(rec) if (pb != null and known_item) else "Unknown item",
		"buyable": known_item and method_s in PriceBook.COST_METHODS,
		"routes": rec.get("routes", []), "unlock_level": it.unlock_level if it != null else -1,
		"availability": rec.get("availability", "unknown"), "confidence": rec.get("confidence", "unknown"),
		"verified": str(rec.get("confidence", "")) in ["confirmed", "game_data"], "origin": rec.get("origin", PriceBook.ORIGIN_NONE),
		"max_count": mc, "count_total": st["count"], "over_max": mc > 0 and int(st["count"]) > mc,
		"sources": rec.get("sources", []), "notes": rec.get("notes", ""), "info": rec.get("info", ""),
	}


static func supply_rows(engine: BudgetEngine, uids: Variant = null, mode: String = BudgetEngine.MODE_REMAINING) -> Array:
	## One row per expansion supply the scope's locked plots need (land is not
	## part of the Design cost, so mode Design gives the plots' supplies too).
	var t := engine.totals(uids, mode)
	var out: Array = []
	if t.plots.is_empty():
		return out
	var bal: Dictionary = engine.layout.profile.get("balances", {}) if engine.layout.profile.get("balances") is Dictionary else {}
	for cur in Currency.sorted_ids(t.land_cost.keys()):
		var needed := int(t.land_cost[cur])
		var have := int(bal.get(cur, 0))
		var plots: Array = []
		for pid in t.plots:
			var c: Variant = engine.plot_cost(pid)
			if c != null and (c as Dictionary).has(cur):
				plots.append(pid)
		out.append({"kind": KIND_SUPPLY, "item": cur, "name": Currency.name_of(cur), "group": GROUP_SUPPLIES,
			"needed": needed, "have": have, "have_known": bal.has(cur), "missing": maxi(0, needed - have),
			"plots": plots, "unknown_plots": t.unknown_cost_plots, "total": {cur: needed},
			"unknown_copies": 0, "currencies": [cur]})
	if t.land_cost.is_empty() and not t.unknown_cost_plots.is_empty():
		out.append({"kind": KIND_SUPPLY, "item": "", "name": "Expansion supplies (unknown)", "group": GROUP_SUPPLIES,
			"needed": 0, "have": 0, "have_known": false, "missing": 0, "plots": t.plots,
			"unknown_plots": t.unknown_cost_plots, "total": {}, "unknown_copies": t.unknown_cost_plots.size(), "currencies": []})
	return out


static func plot_rows(engine: BudgetEngine, uids: Variant = null) -> Array:
	## The locked plots a scope needs: {plot, name, number, cost (Cost|null), phase}.
	var out: Array = []
	for pid in engine.plots_needed(uids):
		var p := engine.map.plot(pid)
		out.append({"plot": pid, "name": str(p.get("name", pid)), "number": int(p.get("number", 0)),
			"cost": engine.plot_cost(pid), "phase": engine.plot_phase(pid)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["number"]) < int(b["number"]))
	return out


# --- group / sort / filter / search -------------------------------------------------------------

static func group_rows(rows: Array) -> Array:
	## [{group, rows, total (known cost), unknown_copies}] in GROUPS order (empty groups left out).
	var by := {}
	for r in rows:
		var g := str(r.get("group", GROUP_OTHER))
		if not by.has(g):
			by[g] = []
		by[g].append(r)
	var out: Array = []
	var order: Array = GROUPS.duplicate()
	for g in by:
		if not g in order:
			order.append(g)
	for g in order:
		if not by.has(g):
			continue
		var total := {}
		var unknown := 0
		for r in by[g]:
			Currency.add_into(total, r.get("total", {}))
			unknown += int(r.get("unknown_copies", 0))
		out.append({"group": g, "rows": by[g], "total": total, "unknown_copies": unknown})
	return out


static func sort_rows(rows: Array, key: String = "group", descending: bool = false) -> Array:
	## Sorted copy. Keys: group (group order, then name), name, missing, used,
	## total (first currency in display order), unlock_level, next_price.
	## Same order as comparing rows with _compare(key), then _compare("name")
	## (rows equal on both keep their input order); sorted natively on
	## precomputed keys (names by their cached natural-order rank).
	if key == "group" and not descending:
		return _sorted_by_group(rows)
	var ranks := _name_ranks(rows)
	var keys: Array = []
	keys.resize(rows.size())
	for i in rows.size():
		var r: Dictionary = rows[i]
		var v: Variant
		match key:
			"group":
				v = [GROUPS.find(str(r.get("group", GROUP_OTHER))), 0 if r.get("kind") == KIND_ITEM else 1]
			"name":
				v = 0
			"total", "next_price":
				v = _cost_key(r.get(key))
			_:
				v = r.get(key, 0)
		keys[i] = [v, ranks[i], i]
	keys.sort()
	var out: Array = []
	out.resize(rows.size())
	var n := rows.size()
	for i in n:
		out[n - 1 - i if descending else i] = rows[int(keys[i][2])]
	return out


static func _sorted_by_group(rows: Array) -> Array:
	## sort_rows(rows, "group"): group order, items before supplies, then name.
	var ranks := _name_ranks(rows)
	var keys := PackedInt64Array()
	keys.resize(rows.size())
	for i in rows.size():
		var r: Dictionary = rows[i]
		var g := GROUPS.find(str(r.get("group", GROUP_OTHER))) + 1   # -1 (unknown group) sorts first, as before
		keys[i] = (g << 52) | ((0 if r.get("kind") == KIND_ITEM else 1) << 51) | (ranks[i] << 24) | i
	keys.sort()
	var out: Array = []
	out.resize(rows.size())
	for i in keys.size():
		out[i] = rows[keys[i] & 0xFFFFFF]
	return out


# Natural, case-insensitive order of row names (String.naturalnocasecmp_to), as a
# rank per name: names are added to one sorted list by binary search the first
# time they are seen, so sorting rows needs no script comparator. Names that
# compare equal share a rank.
static var _rank_list := PackedStringArray()
static var _rank_of: Dictionary = {}


static func _name_ranks(rows: Array) -> PackedInt32Array:
	var added := false
	for r: Dictionary in rows:
		var nm := str(r.get("name", ""))
		if _rank_of.has(nm):
			continue
		if _rank_list.size() >= 65536:
			_rank_list = PackedStringArray()
			_rank_of.clear()
		var lo := 0
		var hi := _rank_list.size()
		while lo < hi:
			var mid := (lo + hi) >> 1
			if _rank_list[mid].naturalnocasecmp_to(nm) <= 0:
				lo = mid + 1
			else:
				hi = mid
		_rank_list.insert(lo, nm)
		_rank_of[nm] = -1
		added = true
	if added:
		var rank := 0
		for i in _rank_list.size():
			if i > 0 and _rank_list[i - 1].naturalnocasecmp_to(_rank_list[i]) != 0:
				rank += 1
			_rank_of[_rank_list[i]] = rank
	var out := PackedInt32Array()
	out.resize(rows.size())
	for i in rows.size():
		out[i] = _rank_of[str((rows[i] as Dictionary).get("name", ""))]
	return out


static func _compare(a: Dictionary, b: Dictionary, key: String) -> int:
	## Reference row comparison (sort_rows() orders exactly like it).
	var va: Variant
	var vb: Variant
	match key:
		"group":
			va = GROUPS.find(str(a.get("group", GROUP_OTHER)))
			vb = GROUPS.find(str(b.get("group", GROUP_OTHER)))
			if va == vb:
				va = 0 if a.get("kind") == KIND_ITEM else 1
				vb = 0 if b.get("kind") == KIND_ITEM else 1
		"name":
			return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", "")))
		"total", "next_price":
			va = _cost_key(a.get(key))
			vb = _cost_key(b.get(key))
		_:
			va = a.get(key, 0)
			vb = b.get(key, 0)
	if va == vb:
		return 0
	return -1 if va < vb else 1


static func _cost_key(c: Variant) -> Array:
	## Sort key of a cost: [currency order, amount]; unknown sorts last.
	if not c is Dictionary:
		return [999, 0]
	if (c as Dictionary).is_empty():
		return [-1, 0]
	var ids := Currency.sorted_ids((c as Dictionary).keys())
	return [Currency.sort_index(ids[0]), int(c[ids[0]])]


static func filter_rows(rows: Array, filters: Dictionary) -> Array:
	## filters (all optional): group: String, state: STATE_*, currency: String,
	## kind: "item" | "supply", query: String (see search_rows).
	var out: Array = []
	for r in rows:
		if filters.has("group") and str(r.get("group")) != str(filters["group"]):
			continue
		if filters.has("kind") and str(r.get("kind")) != str(filters["kind"]):
			continue
		if filters.has("currency") and not str(filters["currency"]) in r.get("currencies", []):
			continue
		if filters.has("state") and not row_has_state(r, str(filters["state"])):
			continue
		out.append(r)
	if filters.has("query"):
		out = search_rows(out, str(filters["query"]))
	return out


static func row_has_state(r: Dictionary, state: String) -> bool:
	match state:
		STATE_MISSING: return int(r.get("missing", 0)) > 0
		STATE_COMPLETE: return int(r.get("missing", 0)) == 0 and int(r.get("unknown_copies", 0)) == 0
		STATE_UNKNOWN_PRICE: return int(r.get("unknown_copies", 0)) > 0
		STATE_NOT_BUYABLE: return int(r.get("not_buyable_copies", 0)) > 0
		STATE_OVER_MAX: return bool(r.get("over_max", false))
	return true


static func search_rows(rows: Array, query: String) -> Array:
	## Case-insensitive match of every word against name, item id, group and method.
	var tokens := query.strip_edges().to_lower().split(" ", false)
	if tokens.is_empty():
		return rows.duplicate()
	var out: Array = []
	for r in rows:
		var hay := " ".join([str(r.get("name", "")), str(r.get("item", "")).replace("_", " "),
			str(r.get("group", "")), str(r.get("method_text", ""))]).to_lower()
		var ok := true
		for t in tokens:
			if hay.find(t) < 0:
				ok = false
				break
		if ok:
			out.append(r)
	return out


static func totals_of(rows: Array) -> Dictionary:
	## {cost (known), unknown_copies, not_buyable_copies, missing} over rows.
	var cost := {}
	var unknown := 0
	var nb := 0
	var missing := 0
	for r in rows:
		Currency.add_into(cost, r.get("total", {}))
		unknown += int(r.get("unknown_copies", 0))
		nb += int(r.get("not_buyable_copies", 0))
		missing += int(r.get("missing", 0))
	return {"cost": cost, "unknown_copies": unknown, "not_buyable_copies": nb, "missing": missing}


# --- acquisition progress (pure) ---------------------------------------------------------------

static func with_bought(plan: Dictionary, item_id: String, copies: int) -> Dictionary:
	## New plan with `copies` more (negative: fewer) copies of an item acquired.
	var cur := int((plan.get("acquired", {}) as Dictionary).get(item_id, 0))
	return PlanDoc.with_acquired(plan, item_id, maxi(0, cur + copies))


static func with_row_bought(plan: Dictionary, row: Dictionary) -> Dictionary:
	## New plan marking every missing copy of a row as acquired.
	if str(row.get("kind")) != KIND_ITEM or int(row.get("missing", 0)) <= 0:
		return plan.duplicate(true)
	return with_bought(plan, str(row["item"]), int(row["missing"]))


static func progress(rows: Array) -> Dictionary:
	## {needed: copies not owned (acquired + missing), acquired, missing, fraction 0..1}.
	var acq := 0
	var miss := 0
	for r in rows:
		if str(r.get("kind")) != KIND_ITEM:
			continue
		acq += int(r.get("acquired", 0))
		miss += int(r.get("missing", 0))
	var needed := acq + miss
	return {"needed": needed, "acquired": acq, "missing": miss, "fraction": 1.0 if needed == 0 else float(acq) / needed}


static func apply_acquired_to_inventory(profile: Dictionary, plan: Dictionary) -> Dictionary:
	## Explicit user action: moves plan.acquired into the inventory. Returns
	## {profile, plan, applied: {item: n}, assumed: [items without an owned entry
	## (their recorded baseline copies, else 0, are taken as the starting count)]}.
	## owned[item] += n, purchased[item] = (purchased or owned before) + n,
	## plan.acquired emptied. Nothing else changes.
	var prof := profile.duplicate(true)
	var p := plan.duplicate(true)
	var owned: Dictionary = prof.get("owned", {}) if prof.get("owned") is Dictionary else {}
	var purch: Dictionary = prof.get("purchased", {}) if prof.get("purchased") is Dictionary else {}
	var base_counts := {}
	var bl: Variant = p.get("baseline")
	if bl is Dictionary and bl.get("objects") is Dictionary:
		for k in bl["objects"]:
			var e: Variant = bl["objects"][k]
			if e is Array and not (e as Array).is_empty():
				base_counts[str(e[0])] = int(base_counts.get(str(e[0]), 0)) + 1
	var applied := {}
	var assumed: Array = []
	var acq: Dictionary = p.get("acquired", {}) if p.get("acquired") is Dictionary else {}
	var ids := acq.keys()
	ids.sort()
	for id in ids:
		var n := int(acq[id])
		if n <= 0:
			continue
		var had: int
		if owned.has(id):
			had = maxi(int(owned[id]), int(base_counts.get(id, 0)))
		else:
			had = int(base_counts.get(id, 0))
			assumed.append(str(id))
		var bought_before := int(purch[id]) if purch.has(id) else had
		owned[id] = had + n
		purch[id] = bought_before + n
		applied[id] = n
	prof["owned"] = owned
	prof["purchased"] = purch
	p["acquired"] = {}
	return {"profile": prof, "plan": p, "applied": applied, "assumed": assumed}
