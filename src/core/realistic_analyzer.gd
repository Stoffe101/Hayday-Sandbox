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

## Cached: an item without OVER_MAX / NOT_OWNED copies (see _item_rows()).
const NO_GROUP := [null, null]

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
	## "catalogue" (flat catalogue cost fields × missing copies, the old rule) or
	## "budget" (the budget engine's To-buy totals: price file, overrides,
	## progressive prices; the same figures as the budget chip). See analyze().
	var cost_source: String = "catalogue"
	## With cost_source "budget": item types counted as to buy because no owned
	## count is recorded (the budget's upper bound; the shortage list skips them
	## while treat_unknown_as_owned is on).
	var unknown_ownership_types: Array = []
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
	##
	## Incremental (the default): an edit re-derives only what it can change.
	## Per object the codes are static (item, planned: same for every copy of an
	## item at this farm level) + placement (the ConflictIndex verdict) + the
	## item's group codes (OVER_MAX / NOT_OWNED: which copies, in layout order,
	## lie beyond the maximum / the owned count). So an edit recomputes the codes
	## of the objects it touched, of objects whose conflict verdict changed and of
	## every copy of an item whose count, order, maximum or owned count changed;
	## the per-item rows (shortages, maximum, level) are rebuilt from per-item
	## counts. Anything else (mode, map, level, inventory, prices, catalogue
	## corrections, unsignalled edits) rebuilds the state from scratch. The
	## report equals analyze() field by field (tests/unit/test_realistic_cache.gd);
	## only the key order of `issues` may differ.
	var layout: FarmLayout
	var stack: CommandStack
	var conflict_index: ConflictIndex
	var computed := 0                ## recomputations so far (tests, diagnostics)
	var full_builds := 0             ## of which rebuilt the incremental state from scratch
	## false: every recomputation is a plain analyze() (the reference; tests).
	var incremental := true
	## When set (EditorSession does), costs come from this budget (see analyze()).
	var budget: BudgetEngine = null
	var _report: Report = null
	var _key: Array = []
	var _dirty := true
	# --- incremental state (valid while _env_key holds) ---
	var _env_key: Array = []
	var _state_ok := false
	var _seq := {}                   ## uid -> insertion serial (= layout.objects order)
	var _next_seq := 0
	var _obj_item := {}              ## uid -> raw item id (real objects) | "" (planned)
	var _items := {}                 ## raw item id -> {uid: true} (real objects only)
	var _order := {}                 ## raw item id -> Array of uids in layout order
	var _index := {}                 ## uid -> position in _order[item]
	var _groups := {}                ## raw item id -> [over_from, short_from] (-1 = none)
	var _static := {}                ## raw item id -> Array static codes of a real copy
	var _conf := {}                  ## uid -> PlacementRules.Result last applied
	var _conf_builds := -1           ## conflict_index.full_rebuilds when _conf was taken
	var _conf_pos := -1              ## conflict_index.log_end() when _conf was taken
	var _plot_refs := {}             ## plot id -> conflicts naming it
	var _issues := {}                ## uid -> Array codes (master; reports get a copy)
	var _blocking := {}              ## uid -> true: a severity-2 code
	var _dirty_uids := {}
	var _dirty_items := {}
	var _tracked := 0                ## objects the state knows (unsignalled edits -> rebuild)
	var _planned_n := 0              ## planned objects among them

	func _init(l: FarmLayout, s: CommandStack, idx: ConflictIndex = null) -> void:
		layout = l
		stack = s
		conflict_index = idx
		l.objects_added.connect(_on_added)
		l.objects_changed.connect(_on_changed)
		l.objects_removed.connect(_on_removed)
		for sig: Signal in [l.land_changed, l.planning_changed, l.meta_changed]:
			sig.connect(invalidate)

	func _on_added(uids: Array) -> void:
		_dirty = true
		if not _state_ok:
			return
		for u in uids:
			var o: PlacedObject = layout.objects.get(u)
			if o == null:
				continue
			_seq[u] = _next_seq
			_next_seq += 1
			_tracked += 1
			_set_membership(u, o)

	func _on_changed(uids: Array) -> void:
		_dirty = true
		if not _state_ok:
			return
		for u in uids:
			var o: PlacedObject = layout.objects.get(u)
			if o == null or not _obj_item.has(u):
				continue
			var now := "" if o.planned else o.item_id
			if now != str(_obj_item[u]):
				_drop_membership(u)
				_set_membership(u, o)
			else:
				_dirty_uids[u] = true

	func _on_removed(uids: Array) -> void:
		_dirty = true
		if not _state_ok:
			return
		for u in uids:
			if not _obj_item.has(u):
				continue
			_drop_membership(u)
			_obj_item.erase(u)
			_seq.erase(u)
			_tracked -= 1
			if _issues.has(u):
				_issues.erase(u)
			_blocking.erase(u)
			_dirty_uids.erase(u)
			# Its conflict entry is retired by the conflict diff (plots too).

	func _set_membership(u: int, o: PlacedObject) -> void:
		_obj_item[u] = "" if o.planned else o.item_id
		_dirty_uids[u] = true
		if o.planned:
			_planned_n += 1
			return
		if not _items.has(o.item_id):
			_items[o.item_id] = {}
		(_items[o.item_id] as Dictionary)[u] = true
		_dirty_items[o.item_id] = true

	func _drop_membership(u: int) -> void:
		var was := str(_obj_item.get(u, ""))
		if was.is_empty() and _obj_item.has(u):
			_planned_n -= 1
		if not was.is_empty() and _items.has(was):
			var m: Dictionary = _items[was]
			m.erase(u)
			if m.is_empty():
				_items.erase(was)
			_dirty_items[was] = true
		_index.erase(u)
		_dirty_uids[u] = true

	func invalidate() -> void:
		_dirty = true

	func report(db: ItemDatabase, map: FarmMap) -> Report:
		var key := [stack.version if stack else 0, layout.mode, map.get_instance_id() if map else 0,
			layout.objects.size(), layout.profile.hash(), layout.unlocked_plots.hash(),
			db.overrides_pack if db else "", str(db.overrides_report.get("hash", "")) if db else "",
			# prices / overrides / inventory edits bump the budget's version
			budget.get_instance_id() if budget != null else 0, budget.sync() if budget != null else 0]
		if _report == null or _dirty or key != _key:
			var conflicts: Variant = conflict_index.conflicts() if conflict_index != null and conflict_index.map == map else null
			if incremental:
				_report = _incremental(db, map, conflicts)
			else:
				_report = RealisticAnalyzer.analyze(layout, db, map, conflicts, budget)
			_key = key
			_dirty = false
			computed += 1
		return _report

	# --- incremental ---------------------------------------------------------------------

	func _incremental(db: ItemDatabase, map: FarmMap, conflicts: Variant) -> Report:
		var level := RealisticAnalyzer.farm_level(layout)
		var prof := layout.profile
		var env := [layout.mode, map.get_instance_id() if map else 0, db.get_instance_id() if db else 0,
			db.overrides_pack if db else "", str(db.overrides_report.get("hash", "")) if db else "",
			prof.hash(), budget.get_instance_id() if budget != null else 0,
			budget.prices.version if budget != null and budget.prices != null else -1]
		var bad: Dictionary = conflicts if conflicts is Dictionary else PlacementRules.find_conflicts(layout, map)
		if not _state_ok or env != _env_key or _tracked != layout.objects.size():
			_rebuild_state(db)
			_env_key = env
		# Placement verdicts that changed since the last report.
		var changed: Variant = null
		if conflicts is Dictionary and conflict_index != null and conflict_index.full_rebuilds == _conf_builds:
			changed = conflict_index.changed_since(_conf_pos)
		if changed == null:
			for u in _conf:
				_dirty_uids[u] = true
			for u in bad:
				_dirty_uids[u] = true
			_plot_refs.clear()
			_conf = {}
			for u: int in bad:
				if layout.objects.has(u):
					_conf_apply(u, bad[u])
			_conf_builds = conflict_index.full_rebuilds if conflict_index != null else -1
		else:
			# Only the uids the index re-checked or dropped since the last report.
			for u: int in changed:
				var res: Variant = bad.get(u) if layout.objects.has(u) else null
				if _conf.get(u) == res:
					continue
				if _conf.has(u):
					_conf_retire(u)
				if res != null:
					_conf_apply(u, res)
				_dirty_uids[u] = true
		_conf_pos = conflict_index.log_end() if conflict_index != null else -1
		# Per-item rows (counts in layout order) and which copies get group codes.
		var r := Report.new()
		var counts := {}
		for id: String in _items:
			counts[id] = (_items[id] as Dictionary).size()
		for id: String in _dirty_items:
			if not _items.has(id):
				_order.erase(id)
				continue
			var keys := PackedInt64Array()
			for u: int in _items[id]:
				keys.append((int(_seq[u]) << 32) | u)
			keys.sort()
			var ord: Array = []
			ord.resize(keys.size())
			for i in keys.size():
				var u := int(keys[i] & 0xFFFFFFFF)
				ord[i] = u
				if int(_index.get(u, -1)) != i:
					_index[u] = i
					_dirty_uids[u] = true
			_order[id] = ord
		var groups := RealisticAnalyzer._item_rows(r, db, counts, prof, level, budget)
		for id: String in counts:
			var g: Array = groups.get(id, NO_GROUP)
			if _dirty_items.has(id) or g != _groups.get(id, NO_GROUP):
				for u in _order.get(id, []):
					_dirty_uids[u] = true
		for id: String in _groups.keys():
			if not counts.has(id):
				_groups.erase(id)
		for id: String in counts:
			_groups[id] = groups.get(id, NO_GROUP)
		_dirty_items = {}
		# Codes of the objects whose answer may have changed.
		for u: int in _dirty_uids:
			_recode(u, db)
		_dirty_uids = {}
		# Report-level figures from per-item counts.
		r.issues = _issues.duplicate()
		r.planned_count = _planned_n
		RealisticAnalyzer._item_aggregates(r, db, counts, level)
		var plots: Array = _plot_refs.keys()
		plots.sort()
		r.plots_needed = plots
		RealisticAnalyzer._check_land_levels(r, layout, map, level)
		RealisticAnalyzer._finish(r, layout, budget, _blocking.size())
		return r

	func _rebuild_state(db: ItemDatabase) -> void:
		full_builds += 1
		_seq = {}
		_next_seq = 0
		_obj_item = {}
		_items = {}
		_order = {}
		_index = {}
		_groups = {}
		_issues = {}
		_blocking = {}
		_dirty_uids = {}
		_dirty_items = {}
		_conf = {}
		_conf_builds = -2
		_conf_pos = -1
		_plot_refs = {}
		_static = {}
		_planned_n = 0
		var level := RealisticAnalyzer.farm_level(layout)
		for o: PlacedObject in layout.objects.values():
			_seq[o.uid] = _next_seq
			_next_seq += 1
			_set_membership(o.uid, o)
		for id: String in _items:
			_static[id] = RealisticAnalyzer._static_codes(db.get_item(id) if db else null, level)
		_tracked = layout.objects.size()
		_state_ok = true

	func _conf_apply(u: int, res: PlacementRules.Result) -> void:
		_conf[u] = res
		if res.reason_counts.has(PlacementRules.LOCKED_LAND):
			for p in res.locked_plots:
				_plot_refs[p] = int(_plot_refs.get(p, 0)) + 1

	func _conf_retire(u: int) -> void:
		var res: PlacementRules.Result = _conf.get(u)
		_conf.erase(u)
		if res != null and res.reason_counts.has(PlacementRules.LOCKED_LAND):
			for p in res.locked_plots:
				var n := int(_plot_refs.get(p, 0)) - 1
				if n <= 0:
					_plot_refs.erase(p)
				else:
					_plot_refs[p] = n

	func _recode(u: int, db: ItemDatabase) -> void:
		var o: PlacedObject = layout.objects.get(u)
		if o == null:
			_issues.erase(u)
			_blocking.erase(u)
			return
		var codes: Array = []
		var known := false
		if o.planned:
			codes.append(PLANNED)
		else:
			var id := o.item_id
			if not _static.has(id):
				_static[id] = RealisticAnalyzer._static_codes(db.get_item(id) if db else null, RealisticAnalyzer.farm_level(layout))
			codes.append_array(_static[id])
			known = db != null and db.get_item(id) != null
		var res: PlacementRules.Result = _conf.get(u)
		if res != null:
			var locked := res.reason_counts.has(PlacementRules.LOCKED_LAND)
			if locked and not o.planned:
				codes.append(LOCKED_LAND)
			if res.reason_counts.size() > (1 if locked else 0):
				codes.append(PLACEMENT)
		if known:
			var g: Array = _groups.get(o.item_id, NO_GROUP)
			if g != NO_GROUP:
				var i := int(_index.get(u, -1))
				var n := (_items[o.item_id] as Dictionary).size()
				if g[0] != null and i >= RealisticAnalyzer._slice_start(int(g[0]), n):
					codes.append(OVER_MAX)
				if g[1] != null and i >= RealisticAnalyzer._slice_start(int(g[1]), n):
					codes.append(NOT_OWNED)
		if codes.is_empty():
			_issues.erase(u)
			_blocking.erase(u)
			return
		_issues[u] = codes
		var blocking := false
		for c in codes:
			if SEVERITY.get(c, 0) >= 2:
				blocking = true
				break
		if blocking:
			_blocking[u] = true
		else:
			_blocking.erase(u)


static func analyze(layout: FarmLayout, db: ItemDatabase, map: FarmMap, conflicts: Variant = null,
		budget: BudgetEngine = null) -> Report:
	## `conflicts` (PlacementRules.find_conflicts' result, or ConflictIndex's)
	## saves re-checking every object's tiles; the report is identical either way.
	##
	## Cost rule: without `budget`, coins_needed / diamonds_needed are the
	## catalogue's flat cost fields × the missing copies of the shortage list
	## (inventory per treat_unknown_as_owned). With `budget` (what the app passes),
	## every coin / diamond figure is the budget engine's whole-farm To-buy total
	## and per-item To-buy cost instead (price file + the user's overrides +
	## progressive prices, unknown ownership counted as to buy), so the Realistic
	## verdict, "Est. cost" and the budget chip never disagree. The issue codes
	## (NOT_OWNED etc.) and the shortage counts keep the inventory rule above.
	var r := Report.new()
	var level := farm_level(layout)
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
	var groups := _item_rows(r, db, counts, layout.profile, level, budget)
	var ids := groups.keys()
	ids.sort()
	for id in ids:
		var g: Array = groups[id]
		if g[0] != null:
			for u in (by_item[id] as Array).slice(int(g[0])):
				_add(r, u, OVER_MAX)
		if g[1] != null:
			for u in (by_item[id] as Array).slice(int(g[1])):
				_add(r, u, NOT_OWNED)
	var blocking := 0
	for u in r.issues:
		for c in r.issues[u]:
			if SEVERITY.get(c, 0) >= 2:
				blocking += 1
				break
	_finish(r, layout, budget, blocking)
	return r


static func _static_codes(it: ItemDef, level: int) -> Array:
	## Codes every real (not planned) copy of the item gets, in analyze() order.
	if it == null:
		return [UNKNOWN_ITEM]
	var out: Array = []
	if not it.is_in_scope():
		out.append(OUT_OF_SCOPE)
	if it.unlock_level > 0 and it.unlock_level > level:
		out.append(LEVEL_LOCKED)
	if not it.is_footprint_trusted():
		out.append(UNVERIFIED_SIZE)
	return out


static func _item_aggregates(r: Report, db: ItemDatabase, counts: Dictionary, _level: int) -> void:
	## required_level, unknown_items, level_unknown_items and unverified from
	## per-item counts of real objects (what analyze() sums object by object).
	for id: String in counts:
		var n := int(counts[id])
		var it := db.get_item(id) if db else null
		if it == null:
			r.unknown_items[id] = n
			continue
		if it.unlock_level > 0:
			r.required_level = maxi(r.required_level, it.unlock_level)
		else:
			r.level_unknown_items[id] = n
		if not it.is_footprint_trusted():
			r.unverified += n


static func _item_rows(r: Report, db: ItemDatabase, counts: Dictionary, prof: Dictionary, level: int,
		budget: BudgetEngine) -> Dictionary:
	## The per-item rows (level_locked, over_max, shortages, the catalogue cost
	## estimate) in item-id order. Returns {item: [over_from, short_from]} for
	## items with group codes: the copies in layout order sliced from that index
	## (Array.slice rules) are over the maximum / not owned (null = none).
	var owned: Dictionary = prof.get("owned", {})
	var unknown_owned := bool(prof.get("treat_unknown_as_owned", true))
	var out := {}
	var ids := counts.keys()
	ids.sort()
	for id in ids:
		var it := db.get_item(id)
		if it == null:
			continue
		var placed: int = counts[id]
		var g: Array = [null, null]
		if it.unlock_level > level:
			r.level_locked.append({"item": id, "name": it.name, "level": it.unlock_level, "count": placed})
		var mx := it.max_count
		if budget != null and budget.prices != null:
			var rm := int(budget.prices.resolved(id).get("max_count", -1))   # same limit as the budget (client data, research)
			if rm > 0:
				mx = rm
		if mx > 0 and placed > mx:
			r.over_max.append({"item": id, "name": it.name, "placed": placed, "max": mx})
			g[0] = mx
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
			g[1] = have
		if g[0] != null or g[1] != null:
			out[id] = g
	return out


static func _slice_start(from: int, n: int) -> int:
	## First index Array.slice(from) keeps of an n-element array.
	return maxi(0, n + from) if from < 0 else from


static func _finish(r: Report, layout: FarmLayout, budget: BudgetEngine, blocking: int) -> void:
	r.level_locked.sort_custom(func(a, b): return a["level"] < b["level"])
	r.required_level = maxi(r.required_level, r.required_land_level)
	if budget != null:
		_costs_from_budget(r, budget)
	var prof := layout.profile
	var bc := int(prof.get("budget_coins", -1))
	var bd := int(prof.get("budget_diamonds", -1))
	r.over_budget_coins = bc >= 0 and r.coins_needed > bc
	r.over_budget_diamonds = bd >= 0 and r.diamonds_needed > bd
	r.blocking_count = blocking


static func _costs_from_budget(r: Report, budget: BudgetEngine) -> void:
	## The budget's To-buy figures replace the catalogue estimate (see analyze()).
	var t := budget.totals(null, BudgetEngine.MODE_TO_BUY)
	r.cost_source = "budget"
	r.coins_needed = int(t.cost.get(Currency.COINS, 0))
	r.diamonds_needed = int(t.cost.get(Currency.DIAMONDS, 0))
	r.unknown_cost_items = t.unknown_price_types.duplicate()
	r.unknown_ownership_types = t.unknown_ownership_types.duplicate()
	var br := {}   # item -> entry (shared, read only: item_rollups, no copies)
	for row: Array in budget.item_rollups(null, BudgetEngine.MODE_TO_BUY):
		br[row[0]] = row[1]
	for e: Dictionary in r.shortages:
		var b: Dictionary = br.get(budget.db.resolve_id(str(e["item"])) if budget.db != null else str(e["item"]), {})
		var c: Dictionary = b.get("cost", {})
		var exact := int(b.get("unknown", 0)) == 0 and int(b.get("not_buyable", 0)) == 0
		e["coins"] = int(c.get(Currency.COINS, 0)) if (exact or c.has(Currency.COINS)) else -1
		e["diamonds"] = int(c.get(Currency.DIAMONDS, 0)) if (exact or c.has(Currency.DIAMONDS)) else -1


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
