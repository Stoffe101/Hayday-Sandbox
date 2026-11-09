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
const OUT_OF_SCOPE := "out_of_scope"

const SEVERITY := {LEVEL_LOCKED: 2, NOT_OWNED: 2, OVER_MAX: 2, LOCKED_LAND: 2, PLACEMENT: 2, OUT_OF_SCOPE: 2, UNKNOWN_ITEM: 1, UNVERIFIED_SIZE: 1, PLANNED: 0}

## Item / plot availability at a farm level (see level_state()).
const AVAILABLE := "unlocked"
const ABOVE_LEVEL := "locked"
const LEVEL_UNKNOWN := "unknown"


class Report:
	var issues: Dictionary = {}          ## uid -> Array[String codes]
	var required_level: int = 0          ## max of item unlock levels and land min levels (known ones only)
	var shortages: Array[Dictionary] = []  ## {item, name, placed, owned, missing, coins, diamonds}
	var over_max: Array[Dictionary] = []   ## {item, name, placed, max}
	var level_locked: Array[Dictionary] = [] ## {item, name, level, count}
	var level_unknown_items: Dictionary = {} ## item id -> placed count (unlock level unknown: not checked)
	var plots_needed: Array = []
	var required_land_level: int = 0     ## highest known min_level among plots the layout uses
	var land_level_locked: Array[Dictionary] = [] ## {plot, name, number, min_level} above the farm level
	var land_level_unknown: Array = []   ## used plot ids whose required level is unknown (allowed, flagged)
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
		return blocking_count == 0 and land_level_locked.is_empty() and not over_budget_coins and not over_budget_diamonds


class Cached:
	## The analysis of one layout, recomputed only when something it depends on
	## changed: layout signals plus the command stack's version catch every edit,
	## the key below everything else (mode, map, catalogue corrections, and
	## profile / land edited without a signal). Reports are shared: read-only.
	var layout: FarmLayout
	var stack: CommandStack
	var conflict_index: ConflictIndex
	var computed := 0                ## recomputations so far (tests, diagnostics)
	var _report: Report = null
	var _key: Array = []
	var _dirty := true

	func _init(l: FarmLayout, s: CommandStack, idx: ConflictIndex = null) -> void:
		layout = l
		stack = s
		conflict_index = idx
		for sig: Signal in [l.objects_added, l.objects_removed, l.objects_changed]:
			sig.connect(_on_objects)
		for sig: Signal in [l.land_changed, l.planning_changed, l.meta_changed]:
			sig.connect(invalidate)

	func _on_objects(_uids: Array) -> void:
		_dirty = true

	func invalidate() -> void:
		_dirty = true

	func report(db: ItemDatabase, map: FarmMap) -> Report:
		var key := [stack.version if stack else 0, layout.mode, map.get_instance_id() if map else 0,
			layout.objects.size(), layout.profile.hash(), layout.unlocked_plots.hash(),
			db.overrides_pack if db else "", str(db.overrides_report.get("hash", "")) if db else ""]
		if _report == null or _dirty or key != _key:
			var conflicts: Variant = conflict_index.conflicts() if conflict_index != null and conflict_index.map == map else null
			_report = RealisticAnalyzer.analyze(layout, db, map, conflicts)
			_key = key
			_dirty = false
			computed += 1
		return _report


static func analyze(layout: FarmLayout, db: ItemDatabase, map: FarmMap, conflicts: Variant = null) -> Report:
	## `conflicts` (PlacementRules.find_conflicts' result, or ConflictIndex's)
	## saves re-checking every object's tiles; the report is identical either way.
	var r := Report.new()
	var prof := layout.profile
	var level := farm_level(layout)
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
		if not it.is_in_scope():
			_add(r, o.uid, OUT_OF_SCOPE)
		if it.unlock_level > 0:
			r.required_level = maxi(r.required_level, it.unlock_level)
			if it.unlock_level > level:
				_add(r, o.uid, LEVEL_LOCKED)
		else:
			r.level_unknown_items[o.item_id] = int(r.level_unknown_items.get(o.item_id, 0)) + 1
		if not it.is_footprint_trusted():
			r.unverified += 1
			_add(r, o.uid, UNVERIFIED_SIZE)
	# Land and placement validity.
	var plots := {}
	var bad: Dictionary = conflicts if conflicts is Dictionary else PlacementRules.find_conflicts(layout, map)
	for u: int in bad:
		var o: PlacedObject = layout.objects.get(u)
		if o == null:
			continue
		var res: PlacementRules.Result = bad[u]
		if res.reason_counts.has(PlacementRules.LOCKED_LAND):
			plots.merge(res.locked_plots)
			if not o.planned:
				_add(r, o.uid, LOCKED_LAND)
		if res.reason_counts.size() > (1 if res.reason_counts.has(PlacementRules.LOCKED_LAND) else 0):
			_add(r, o.uid, PLACEMENT)
	r.plots_needed = plots.keys()
	r.plots_needed.sort()
	_check_land_levels(r, layout, map, level)
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
	r.required_level = maxi(r.required_level, r.required_land_level)
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


static func _check_land_levels(r: Report, layout: FarmLayout, map: FarmMap, level: int) -> void:
	## Plots the design uses (unlocked ones + those objects stand on) against
	## their required farm level. Unknown requirements are allowed but listed.
	if map == null:
		return
	var used := map.canonical_unlocked(layout.unlocked_plots)
	for p in r.plots_needed:
		used[map.resolve_plot_id(str(p))] = true
	var ids := used.keys()
	ids.sort()
	for pid in ids:
		if not map.has_plot(str(pid)):
			continue   # an id of another map: nothing to say about it here
		var info := plot_level_info(map, str(pid), level)
		var ml: int = info["min_level"]
		if ml <= 0:
			r.land_level_unknown.append(pid)
			continue
		r.required_land_level = maxi(r.required_land_level, ml)
		if not bool(info["ok"]):
			var p := map.plot(str(pid))
			r.land_level_locked.append({"plot": pid, "name": str(p.get("name", pid)), "number": p.get("number", 0), "min_level": ml})
	r.land_level_locked.sort_custom(func(a, b):
		if a["min_level"] == b["min_level"]:
			return str(a["plot"]) < str(b["plot"])
		return a["min_level"] < b["min_level"])


# ---------------------------------------------------------------------------
# Farm level: Realistic = "my farm at level N"; Creative = sandbox (all unlocked)
# ---------------------------------------------------------------------------

static func farm_level(layout: FarmLayout) -> int:
	## The layout's farm level (profile.level), never below 1.
	return maxi(1, int(layout.profile.get("level", 1))) if layout else 1


static func level_state(it: ItemDef, level: int) -> String:
	## AVAILABLE / ABOVE_LEVEL / LEVEL_UNKNOWN for an item on a farm at `level`.
	## Unknown (or unset, <= 0) unlock levels are never guessed.
	if it == null or it.unlock_level <= 0:
		return LEVEL_UNKNOWN
	return AVAILABLE if it.unlock_level <= level else ABOVE_LEVEL


static func mode_level_state(it: ItemDef, mode: String, level: int) -> String:
	## Like level_state(), but Creative mode is the full sandbox: every item is
	## available there whatever its unlock level.
	if mode != FarmLayout.MODE_REALISTIC:
		return AVAILABLE
	return level_state(it, level)


static func item_level_block(it: ItemDef, mode: String, level: int) -> String:
	## "" when `it` may be placed in this mode at this level, else a friendly
	## reason. Only Realistic mode limits by level; unknown levels never block.
	if mode_level_state(it, mode, level) != ABOVE_LEVEL:
		return ""
	return "%s unlocks at level %d — your farm is level %d. Raise your farm level or switch to Creative (sandbox) to place it." % [it.name, it.unlock_level, level]


static func filter_by_level(items: Array, mode: String, level: int, show_locked: bool) -> Dictionary:
	## Catalogue level filter (pure). Returns
	##   {"items": Array[ItemDef] to show (input order kept), "total": n,
	##    "unlocked": n, "unknown": n, "locked": n}
	## Realistic: items above `level` are left out unless `show_locked`;
	## unknown levels always stay visible. Creative: everything, all "unlocked".
	var out: Array[ItemDef] = []
	var counts := {AVAILABLE: 0, ABOVE_LEVEL: 0, LEVEL_UNKNOWN: 0}
	for it: ItemDef in items:
		var st := mode_level_state(it, mode, level)
		counts[st] += 1
		if st == ABOVE_LEVEL and not show_locked:
			continue
		out.append(it)
	return {"items": out, "total": items.size(), "unlocked": counts[AVAILABLE],
		"unknown": counts[LEVEL_UNKNOWN], "locked": counts[ABOVE_LEVEL]}


static func plot_required_level(map: FarmMap, plot_id: String) -> int:
	## Farm level a plot needs before it can be unlocked (canonical id or
	## alias); -1 when unknown (or the plot isn't on this map).
	if map == null:
		return -1
	var p := map.plot(plot_id)
	var ml := int(p.get("min_level", -1)) if not p.is_empty() else -1
	return ml if ml > 0 else -1


static func plot_level_ok(map: FarmMap, plot_id: String, level: int) -> bool:
	## True when a farm at `level` may unlock the plot. Unknown requirements are
	## allowed (flagged by plot_level_info); a negative level means "no limit".
	var ml := plot_required_level(map, plot_id)
	return level < 0 or ml < 0 or ml <= level


static func plot_level_info(map: FarmMap, plot_id: String, level: int) -> Dictionary:
	## {"plot": canonical id, "min_level": int (-1 unknown), "known": bool,
	##  "ok": bool, "reason": "" | "Requires level 45" | "Required level unknown"}
	var ml := plot_required_level(map, plot_id)
	var ok := plot_level_ok(map, plot_id, level)
	var reason := ""
	if not ok:
		reason = "Requires level %d" % ml
	elif ml < 0:
		reason = "Required level unknown"
	return {"plot": map.resolve_plot_id(plot_id) if map else plot_id, "min_level": ml, "known": ml > 0, "ok": ok, "reason": reason}


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
		OUT_OF_SCOPE: return "Belongs to another area, not the main farm"
		PLANNED: return "Planned (future) object"
		PLACEMENT: return "Invalid placement"
	return code
