class_name RealisticAnalyzer
extends RefCounted
## Non-destructive "can I actually build this?" analysis for Realistic Mode.
## Never modifies the layout; only reports. Unknown prices are reported as
## unknown — never estimated.

const LEVEL_LOCKED := "level"
const NOT_OWNED := "not_owned"
const OVER_MAX := "over_max"
const LOCKED_LAND := "locked_land"
const UNVERIFIED_SIZE := "unverified_size"
const UNKNOWN_ITEM := "unknown_item"
const PLANNED := "planned"
const PLACEMENT := "placement"

const SEVERITY := {LEVEL_LOCKED: 2, NOT_OWNED: 2, OVER_MAX: 2, LOCKED_LAND: 2, PLACEMENT: 2, UNKNOWN_ITEM: 1, UNVERIFIED_SIZE: 1, PLANNED: 0}


class Report:
	var issues: Dictionary = {}          ## uid -> Array[String codes]
	var required_level: int = 0
	var shortages: Array[Dictionary] = []  ## {item, name, placed, owned, missing, coins, diamonds}
	var over_max: Array[Dictionary] = []   ## {item, name, placed, max}
	var level_locked: Array[Dictionary] = [] ## {item, name, level, count}
	var plots_needed: Array = []
	var unverified: int = 0
	var unknown_items: Dictionary = {}
	var planned_count: int = 0
	var coins_needed: int = 0
	var diamonds_needed: int = 0
	var unknown_cost_items: Array = []
	var over_budget_coins: bool = false
	var over_budget_diamonds: bool = false
	var blocking_count: int = 0          ## objects with a severity-2 issue

	func can_recreate() -> bool:
		return blocking_count == 0 and not over_budget_coins and not over_budget_diamonds


static func analyze(layout: FarmLayout, db: ItemDatabase, map: FarmMap) -> Report:
	var r := Report.new()
	var prof := layout.profile
	var level := int(prof.get("level", 1))
	var owned: Dictionary = prof.get("owned", {})
	var unknown_owned := bool(prof.get("treat_unknown_as_owned", true))
	var counts := {}
	var by_item := {}
	for o: PlacedObject in layout.objects.values():
		if o.planned:
			r.planned_count += 1
			_add(r, o.uid, PLANNED)
			continue
		counts[o.item_id] = counts.get(o.item_id, 0) + 1
		if not by_item.has(o.item_id):
			by_item[o.item_id] = []
		by_item[o.item_id].append(o.uid)
		var it := db.get_item(o.item_id)
		if it == null:
			r.unknown_items[o.item_id] = r.unknown_items.get(o.item_id, 0) + 1
			_add(r, o.uid, UNKNOWN_ITEM)
			continue
		if it.unlock_level > 0:
			r.required_level = maxi(r.required_level, it.unlock_level)
			if it.unlock_level > level:
				_add(r, o.uid, LEVEL_LOCKED)
		if not it.is_footprint_trusted():
			r.unverified += 1
			_add(r, o.uid, UNVERIFIED_SIZE)
	# Land and placement validity.
	var plots := {}
	for o: PlacedObject in layout.objects.values():
		var res := PlacementRules.check_rect(layout, map, o.rect(), {o.uid: true})
		if res.ok:
			continue
		if res.reason_counts.has(PlacementRules.LOCKED_LAND):
			plots.merge(res.locked_plots)
			if not o.planned:
				_add(r, o.uid, LOCKED_LAND)
		if res.reason_counts.size() > (1 if res.reason_counts.has(PlacementRules.LOCKED_LAND) else 0):
			_add(r, o.uid, PLACEMENT)
	r.plots_needed = plots.keys()
	r.plots_needed.sort()
	# Inventory, max counts, cost.
	var ids := counts.keys()
	ids.sort()
	for id in ids:
		var it := db.get_item(id)
		if it == null:
			continue
		var placed: int = counts[id]
		if it.unlock_level > level:
			r.level_locked.append({"item": id, "name": it.name, "level": it.unlock_level, "count": placed})
		if it.max_count > 0 and placed > it.max_count:
			r.over_max.append({"item": id, "name": it.name, "placed": placed, "max": it.max_count})
			var extra_uids: Array = by_item[id].slice(it.max_count)
			for u in extra_uids:
				_add(r, u, OVER_MAX)
		var have := placed if (unknown_owned and not owned.has(id)) else int(owned.get(id, 0))
		if placed > have:
			var missing := placed - have
			var entry := {"item": id, "name": it.name, "placed": placed, "owned": have, "missing": missing,
				"coins": -1, "diamonds": -1}
			if it.cost_coins >= 0:
				entry["coins"] = it.cost_coins * missing
				r.coins_needed += it.cost_coins * missing
			if it.cost_diamonds >= 0:
				entry["diamonds"] = it.cost_diamonds * missing
				r.diamonds_needed += it.cost_diamonds * missing
			if not it.has_known_cost():
				r.unknown_cost_items.append(id)
			r.shortages.append(entry)
			var short_uids: Array = by_item[id].slice(have)
			for u in short_uids:
				_add(r, u, NOT_OWNED)
	r.level_locked.sort_custom(func(a, b): return a["level"] < b["level"])
	var bc := int(prof.get("budget_coins", -1))
	var bd := int(prof.get("budget_diamonds", -1))
	r.over_budget_coins = bc >= 0 and r.coins_needed > bc
	r.over_budget_diamonds = bd >= 0 and r.diamonds_needed > bd
	for u in r.issues:
		for c in r.issues[u]:
			if SEVERITY.get(c, 0) >= 2:
				r.blocking_count += 1
				break
	return r


static func _add(r: Report, uid: int, code: String) -> void:
	if not r.issues.has(uid):
		r.issues[uid] = []
	if not code in r.issues[uid]:
		r.issues[uid].append(code)


static func issue_text(code: String) -> String:
	match code:
		LEVEL_LOCKED: return "Requires a higher farm level"
		NOT_OWNED: return "You don't own enough of these"
		OVER_MAX: return "More than the game allows"
		LOCKED_LAND: return "Stands on locked expansion land"
		UNVERIFIED_SIZE: return "Footprint not verified"
		UNKNOWN_ITEM: return "Unknown item type"
		PLANNED: return "Planned (future) object"
		PLACEMENT: return "Invalid placement"
	return code
