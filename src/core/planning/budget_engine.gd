class_name BudgetEngine
extends RefCounted
## Budget of a layout (docs/PLANNING.md §4): allocates the player's owned and
## acquired copies to objects, gives every object its own cost in three modes and
## sums any scope (selection, area, phase, whole farm) without counting anything
## twice. Unknown prices are counted, never treated as 0; currencies are never
## converted into each other.
##
## Allocation (deterministic, per item): objects ordered by (1) baseline objects
## (same uid and item as in plan.baseline) first, (2) primary phase build order,
## Unphased last, (3) uid. Owned copies cover objects in that order, then
## plan.acquired copies; the rest are to buy with purchase numbers
## profile.purchased[item] (else owned) + 1, + 2, ...
##
## Modes: MODE_DESIGN (gross: every object priced as copy #1, #2, ... in that same
## order, inventory ignored), MODE_TO_BUY (objects not covered by owned copies,
## plus the expansion plots the design needs), MODE_REMAINING (objects not
## covered by owned or acquired copies, plus plots).
##
## Incremental: listens to the layout's signals and only re-allocates the item
## ids an edit touched (a move re-runs phase membership for the moved uids
## only). Everything is lazy: signal handlers just mark work and bump `version`
## (+ `changed`); the next query does the work once. recompute_full() forces the
## full path (tests compare both).
##
## Batching: every query first checks for changes made without a signal (it
## hashes the planning / profile dictionaries, see auto_detect). A view that asks
## many questions about one state wraps them in batch(f) (or begin_batch() /
## end_batch()): one full check at the start, then each query only applies
## signalled changes. Per-object loops (overlays, checklists) should batch or use
## the bulk getters (placed_set(), primary_phases()).
##
## Caches derived per version: whole-farm / phase / area / uid-list totals,
## per-item breakdowns (whole farm: kept per item and rebuilt only for the items
## an edit touched), area membership (updated per edited object). Everything a
## query returns from a cache is shared: read it, never modify it.

signal changed

const MODE_DESIGN := "design"
const MODE_TO_BUY := "to_buy"
const MODE_REMAINING := "remaining"
const MODES := [MODE_DESIGN, MODE_TO_BUY, MODE_REMAINING]
const MODE_NAMES := {MODE_DESIGN: "Design cost", MODE_TO_BUY: "Still to buy", MODE_REMAINING: "Remaining cost"}

const STATUS_OWNED := "owned"
const STATUS_ACQUIRED := "acquired"
const STATUS_TO_BUY := "to_buy"
const STATUSES := [STATUS_OWNED, STATUS_ACQUIRED, STATUS_TO_BUY]   ## index = internal code

const PHASE_NOT_STARTED := "not_started"
const PHASE_IN_PROGRESS := "in_progress"
const PHASE_READY := "ready"
const PHASE_COMPLETED := "completed"
const UNPHASED := ""

const CID_UNKNOWN := -1
const CID_NOT_BUYABLE := -2
const _UNSET := -100
const _K_PRICED := 0
const _K_UNKNOWN := 1
const _K_NOT_BUYABLE := 2
const _ST_OWNED := 0
const _ST_ACQUIRED := 1
const _ST_TO_BUY := 2


## Result of a sum over a scope. Read-only (shared through the cache).
class Totals:
	var mode: String = "to_buy"
	## Known cost in this mode: objects + land (land only in To buy / Remaining).
	var cost: Dictionary = {}
	var object_cost: Dictionary = {}
	## Supplies of the plots below (also filled in Design mode, but not added to `cost` there).
	var land_cost: Dictionary = {}
	var objects: int = 0                 ## objects in the scope
	var types: int = 0                   ## distinct item ids in the scope
	var charged_objects: int = 0         ## objects that need paying for in this mode
	var unknown_price_objects: int = 0   ## charged objects without a known price
	var unknown_price_types: Array = []
	var not_buyable_objects: int = 0     ## charged objects that can't be bought (reward / not in shop)
	var not_buyable_types: Array = []
	## Items without a profile.owned entry and no baseline copies (counted as to buy).
	var unknown_ownership_types: Array = []
	var owned_objects: int = 0
	var acquired_objects: int = 0
	var to_buy_objects: int = 0
	var placed_objects: int = 0
	var plots: Array = []                ## locked expansion plots the scope needs (canonical ids)
	var unknown_cost_plots: Array = []   ## of those, plots whose supplies are unknown
	var over_max: Array = []             ## {item, count (whole design), max}

	func is_exact() -> bool:
		## True when `cost` is the full amount (nothing unknown or unbuyable left out).
		return unknown_price_objects == 0 and not_buyable_objects == 0 and unknown_cost_plots.is_empty()

	func to_dict() -> Dictionary:
		return {"mode": mode, "cost": cost, "object_cost": object_cost, "land_cost": land_cost,
			"objects": objects, "types": types, "charged_objects": charged_objects,
			"unknown_price_objects": unknown_price_objects, "unknown_price_types": unknown_price_types,
			"not_buyable_objects": not_buyable_objects, "not_buyable_types": not_buyable_types,
			"unknown_ownership_types": unknown_ownership_types, "owned_objects": owned_objects,
			"acquired_objects": acquired_objects, "to_buy_objects": to_buy_objects,
			"placed_objects": placed_objects, "plots": plots, "unknown_cost_plots": unknown_cost_plots,
			"over_max": over_max, "exact": is_exact()}


var layout: FarmLayout
var db: ItemDatabase
var prices: PriceBook
var map: FarmMap
## Bumped on every change that can affect a result (signal or detected change).
var version: int = 0
## Also detect planning/profile dictionaries edited in place without a signal
## (a hash per query; see _sync_context()).
var auto_detect: bool = true
## Diagnostics (tests, perf).
var full_recomputes: int = 0
var item_recomputes: int = 0
## Scratch storage for views derived from this engine (ShoppingList keeps its
## reusable rows here). The engine never reads it; emptied when prices change.
var view_cache: Dictionary = {}

var _batch_depth := 0
var _synced := false                  ## up to date since the last signal (batch fast path)

# --- per object (slot arrays; uid -> slot) ---
var _slot: Dictionary = {}
var _free: PackedInt32Array = PackedInt32Array()
var _s_uid := PackedInt32Array()
var _s_item := PackedInt32Array()     ## item index, -1 = free slot
var _s_phase := PackedInt32Array()    ## phase index, phases.size() = Unphased
var _s_status := PackedInt32Array()
var _s_dcid := PackedInt32Array()     ## design cost id
var _s_bcid := PackedInt32Array()     ## purchase cost id (0 for owned)
var _s_dk := PackedInt32Array()       ## design copy number
var _s_bk := PackedInt32Array()       ## purchase number (0 = owned)
var _s_placed := PackedByteArray()
var _s_base := PackedByteArray()
var _s_plot := PackedInt32Array()     ## first plot index under the footprint, -1 = none
var _s_plots: Dictionary = {}         ## slot -> all plot indices, only for footprints on 2+ plots

# --- per item ---
var _items := PackedStringArray()
var _item_idx: Dictionary = {}
var _raw_idx: Dictionary = {}         ## item id as stored on objects (maybe an alias) -> idx
var _bucket: Array = []               ## idx -> PackedInt32Array of slots (allocation order after a full pass)
var _i_kind := PackedInt32Array()
var _i_const := PackedInt32Array()    ## cost id of every copy, _UNSET when progressive
var _i_owned := PackedInt32Array()    ## effective owned (max(owned, baseline copies))
var _i_owned_known := PackedByteArray()
var _i_acquired := PackedInt32Array()
var _i_purchased := PackedInt32Array()
var _i_max := PackedInt32Array()
var _i_rev := PackedInt32Array()      ## bumped when anything about the item may have changed (see item_revision())
var _rev_counter: int = 0
var _kcid: Dictionary = {}            ## idx * 2^20 + k -> cost id
var _roll: Dictionary = {}            ## idx -> [design, to_buy, remaining] whole-farm breakdown entries (lazy)

# --- interned costs ---
var _costs: Array = [{}]
var _cost_index: Dictionary = {}

# --- context ---
var _empty_plan: Dictionary = PlanDoc.empty()
var _plan: Dictionary = {}
var _profile_ref: Dictionary = {}
var _phase_ids := PackedStringArray()
var _phase_index: Dictionary = {}
var _phase_areas: Array = []
var _grid := PackedInt32Array()       ## per tile: first phase | (plot + 1) << 16 (see _build_grid)
var _g_rect := Rect2i()
var _gx := 0
var _gy := 0
var _gw := 0
var _gex := 0
var _gey := 0
var _grid_key: int = 0
var _tp_ok := true
var _assign_u: Dictionary = {}        ## int uid -> manual phase index (known phases only)
var _placed_u: Dictionary = {}        ## int uid -> true
var _base_u: Dictionary = {}          ## int uid -> baseline entry ["item", x, y, w, h]
var _assign: Dictionary = {}
var _placed: Dictionary = {}
var _baseline: Dictionary = {}
var _baseline_counts: Dictionary = {}
var _snap_owned: Dictionary = {}
var _snap_purchased: Dictionary = {}
var _snap_acquired: Dictionary = {}
var _snap_placed: Dictionary = {}
var _snap_assign: Dictionary = {}
var _struct_hash: int = 0
var _ctx_hash: int = 0
var _prices_version: int = -1
var _locked := PackedByteArray()      ## per plot index: 1 = locked
var _unlocked_hash: int = 0

# --- dirty state / caches ---
var _need_full := true
var _ctx_dirty := false
var _land_dirty := false
var _pending: Dictionary = {}
var _dirty_items: Dictionary = {}
var _cache: Dictionary = {}
var _phase_slots: Array = []          ## phase index -> PackedInt32Array (built lazily)
var _plot_phase: Dictionary = {}      ## locked plot index -> earliest phase index (built lazily)
var _derived_ok := false
var _areas: Dictionary = {}           ## area id -> membership entry (see _area_entry()), kept across edits


func _init(l: FarmLayout, item_db: ItemDatabase, price_book: PriceBook, farm_map: FarmMap = null) -> void:
	layout = l
	db = item_db
	prices = price_book
	map = farm_map
	_cost_index[{}] = 0
	l.objects_added.connect(_on_objects)
	l.objects_removed.connect(_on_objects)
	l.objects_changed.connect(_on_objects)
	l.land_changed.connect(_on_land)
	l.planning_changed.connect(_on_context)
	l.meta_changed.connect(_on_context)
	for extra_sig in ["plan_changed", "profile_changed", "baseline_changed"]:
		if l.has_signal(extra_sig):
			l.connect(extra_sig, _on_context_args)
	if prices != null:
		prices.changed.connect(_on_context)


func dispose() -> void:
	## Disconnects from the layout (call before dropping an engine whose layout lives on).
	for pair in [[layout.objects_added, _on_objects], [layout.objects_removed, _on_objects],
			[layout.objects_changed, _on_objects], [layout.land_changed, _on_land],
			[layout.planning_changed, _on_context], [layout.meta_changed, _on_context]]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])
	for extra_sig in ["plan_changed", "profile_changed", "baseline_changed"]:
		if layout.has_signal(extra_sig) and layout.is_connected(extra_sig, _on_context_args):
			layout.disconnect(extra_sig, _on_context_args)
	if prices != null and prices.changed.is_connected(_on_context):
		prices.changed.disconnect(_on_context)


# --- signal handlers (only mark work) -----------------------------------------------------

func _on_objects(uids: Array) -> void:
	for u in uids:
		_pending[int(u)] = true
	_bump()


func _on_land() -> void:
	_land_dirty = true
	_bump()


func _on_context() -> void:
	_ctx_dirty = true
	_bump()


func _on_context_args(_a: Variant = null, _b: Variant = null) -> void:
	_on_context()


func invalidate() -> void:
	## Forces a full recompute on the next query.
	_need_full = true
	_bump()


func _bump() -> void:
	version += 1
	_synced = false
	_cache.clear()
	_derived_ok = false
	changed.emit()


func recompute_full() -> void:
	## Full recompute now (the reference path the incremental one must match).
	_full(_current_plan())


# --- batching -------------------------------------------------------------------------------

func begin_batch() -> void:
	## Starts a batch of queries about one state: brings the engine up to date
	## now (including the check for dictionaries edited in place), then skips that
	## check (a hash of the whole planning document per query) and the other
	## per-query checks until the matching end_batch(). Changes that come with a
	## signal still apply at once. Nestable; always pair with end_batch() (or use
	## batch()). Replaces toggling auto_detect around a view's queries.
	if _batch_depth == 0:
		_ensure()
	_batch_depth += 1


func end_batch() -> void:
	if _batch_depth > 0:
		_batch_depth -= 1


func in_batch() -> bool:
	return _batch_depth > 0


func batch(f: Callable) -> Variant:
	## Calls `f` between begin_batch() and end_batch(); returns what it returns.
	begin_batch()
	var out: Variant = f.call()
	end_batch()
	return out


func sync() -> int:
	## Brings everything up to date now (normally done by the first query);
	## returns `version`.
	_ensure()
	return version


# --- public queries -----------------------------------------------------------------------

func plan() -> Dictionary:
	return _current_plan()


func phase_ids(include_unphased: bool = true) -> Array:
	## Phase ids in build order (+ UNPHASED last).
	_ensure()
	var out: Array = Array(_phase_ids)
	if include_unphased:
		out.append(UNPHASED)
	return out


func status_of(uid: int) -> String:
	_ensure()
	var s: int = _slot.get(uid, -1)
	return "" if s < 0 else STATUSES[_s_status[s]]


func primary_phase(uid: int) -> String:
	_ensure()
	var s: int = _slot.get(uid, -1)
	return UNPHASED if s < 0 else _phase_id(_s_phase[s])


func primary_phases() -> Dictionary:
	## uid -> phase id ("" = Unphased) for every object (same rule as PlanDoc.primary_phases).
	_ensure()
	var out := {}
	for u: int in _slot:
		out[u] = _phase_id(_s_phase[_slot[u]])
	return out


func is_placed(uid: int) -> bool:
	_ensure()
	var s: int = _slot.get(uid, -1)
	return s >= 0 and _s_placed[s] == 1


func object_cost(uid: int, mode: String = MODE_TO_BUY) -> Variant:
	## This object's own cost in `mode`: a Cost ({} = nothing to pay), or null
	## when unknown / not purchasable (see object_info()["price_state"]).
	_ensure()
	var s: int = _slot.get(uid, -1)
	if s < 0:
		return null
	var cid := _mode_cid(s, mode)
	return _costs[cid] if cid >= 0 else null


func object_info(uid: int) -> Dictionary:
	## {uid, item, status, phase, placed, baseline, design_copy, purchase_number,
	##  cost: {design, to_buy, remaining} (Cost or null), price_state: "known"|"unknown"|"not_buyable",
	##  plots: locked plots under it}; {} for an unknown uid.
	_ensure()
	var s: int = _slot.get(uid, -1)
	if s < 0:
		return {}
	var costs := {}
	for m in MODES:
		var c := _mode_cid(s, m)
		costs[m] = _costs[c] if c >= 0 else null
	var dc := _s_dcid[s]
	var plots: Array = []
	for p in _slot_plots(s):
		if _locked[p] == 1:
			plots.append(str(map.plots[p]["id"]))
	return {"uid": uid, "item": _items[_s_item[s]], "status": STATUSES[_s_status[s]],
		"phase": _phase_id(_s_phase[s]), "placed": _s_placed[s] == 1, "baseline": _s_base[s] == 1,
		"design_copy": _s_dk[s], "purchase_number": _s_bk[s], "cost": costs,
		"price_state": "not_buyable" if dc == CID_NOT_BUYABLE else ("unknown" if dc == CID_UNKNOWN else "known"),
		"plots": plots}


func item_state(item_id: String) -> Dictionary:
	## Inventory view of one item: {item, count (objects in the design), owned
	## (effective), owned_recorded (profile entry or -1), owned_known, baseline,
	## acquired, purchased (base for purchase numbers), max_count (-1), kind:
	## "priced"|"unknown"|"not_buyable"}.
	_ensure()
	var id := _item_key(item_id)
	var prof := layout.profile
	var owned_d: Dictionary = prof.get("owned", {}) if prof.get("owned") is Dictionary else {}
	var idx: int = _item_idx.get(id, -1)
	if idx < 0:
		var tmp := _intern_item(id)   # not in the design: compute the same way
		idx = tmp
	return {"item": id, "count": (_bucket[idx] as PackedInt32Array).size(), "owned": _i_owned[idx],
		"owned_recorded": int(owned_d[id]) if owned_d.has(id) else -1, "owned_known": _i_owned_known[idx] == 1,
		"baseline": int(_baseline_counts.get(id, 0)), "acquired": _i_acquired[idx],
		"purchased": _i_purchased[idx], "max_count": _i_max[idx],
		"kind": ["priced", "unknown", "not_buyable"][_i_kind[idx]]}


func item_revision(item_id: String) -> int:
	## A number that changes whenever anything about the item may have changed
	## (inventory, allocation, placed marks, prices); -1 for an item not seen yet.
	## Views use it to reuse per-item results (ShoppingList rows).
	_ensure()
	var idx: int = _item_idx.get(_item_key(item_id), -1)
	return -1 if idx < 0 else _i_rev[idx]


func alloc_order(item_id: String) -> Array:
	## uids of an item's objects in allocation order.
	_ensure()
	var idx: int = _item_idx.get(_item_key(item_id), -1)
	if idx < 0:
		return []
	# Every bucket is kept in allocation order (copy numbers 1, 2, ... = position).
	var out: Array = []
	for s: int in _bucket[idx]:
		out.append(_s_uid[s])
	return out


func placed_set() -> Dictionary:
	## uid -> true for every object counted as placed (is_placed()), cached per
	## version: one call per redraw instead of is_placed() per object. Shared: don't modify.
	_ensure()
	if not _cache.has("placed_set"):
		var out := {}
		for s in _s_uid.size():
			if _s_placed[s] == 1 and _s_item[s] >= 0:
				out[_s_uid[s]] = true
		_cache["placed_set"] = out
	return _cache["placed_set"]


func totals(uids: Variant = null, mode: String = MODE_TO_BUY) -> Totals:
	## Sum over `uids` (Array of uids) or the whole farm (null). Each plot needed
	## is counted once within the scope. Results are cached per version (whole
	## farm, and the last uid lists asked for).
	_ensure()
	if uids == null:
		var key := "farm/" + mode
		if _cache.has(key):
			return _cache[key]
		var t := _sum(_live_slots(), mode, null)
		_cache[key] = t
		return t
	var ukey := "uids/%s/%d" % [mode, uids.hash()]
	var hit: Variant = _cache.get(ukey)
	if hit != null and hit[0] == uids:
		return hit[1]
	var slots := PackedInt32Array()
	for u in uids:
		var s: int = _slot.get(int(u), -1)
		if s >= 0:
			slots.append(s)
	var res := _sum(slots, mode, null)
	_cache[ukey] = [(uids as Array).duplicate() if uids is Array else uids, res]
	return res


func phase_totals(phase_id: String, mode: String = MODE_TO_BUY) -> Totals:
	## Objects whose primary phase is `phase_id` (UNPHASED = ""), plus the plots
	## attributed to it (each plot goes to the earliest phase needing it), so the
	## phase totals add up exactly to the whole-farm total.
	_ensure()
	var key := "phase/%s/%s" % [phase_id, mode]
	if _cache.has(key):
		return _cache[key]
	_derive()
	var pi := _phase_idx_of(phase_id)
	var t: Totals
	if pi < 0:
		t = _sum(PackedInt32Array(), mode, [])
	else:
		var plots: Array = []
		for p: int in _plot_phase:
			if _plot_phase[p] == pi:
				plots.append(p)
		t = _sum(_phase_slots[pi], mode, plots)
	_cache[key] = t
	return t


func phase_uids(phase_id: String) -> Array:
	## Sorted uids of the phase's objects (a new array; cached per version).
	_ensure()
	_derive()
	var pi := _phase_idx_of(phase_id)
	if pi < 0:
		return []
	var key := "phase_uids/%d" % pi
	var l: Variant = _cache.get(key)
	if l == null:
		var out: Array = []
		for s in _phase_slots[pi]:
			out.append(_s_uid[s])
		out.sort()
		l = out
		_cache[key] = out
		# item_rollups() recognises this list (the Shop tab passes it back).
		_cache["scope/%d" % out.hash()] = pi
	return (l as Array).duplicate()


func area_uids(area_id: String) -> Array:
	## Sorted uids of the objects with a footprint tile in the area (the
	## PlanDoc.objects_in_area rule). Membership is kept per area and updated
	## per edited object; the list is shared (don't modify it).
	_ensure()
	var a := PlanDoc.area(_plan, area_id)
	if a.is_empty():
		return []
	var e: Dictionary = _areas.get(area_id, {})
	if e.is_empty() or e["def"] != a:
		e = _area_entry(a)
		_areas[area_id] = e
	if e["list"] == null:
		var l: Array = (e["members"] as Dictionary).keys()
		l.sort()
		e["list"] = l
	return e["list"]


func area_totals(area_id: String, mode: String = MODE_TO_BUY) -> Totals:
	## Objects with any footprint tile in the area. Areas may overlap, so area
	## totals are not additive (the UI says so).
	_ensure()
	var key := "area/%s/%s" % [area_id, mode]
	if not _cache.has(key):
		_cache[key] = totals(area_uids(area_id), mode)
	return _cache[key]


func phase_status(phase_id: String) -> String:
	## completed (marked done, or every object placed) > ready (nothing still to
	## buy and no locked plot to open) > in_progress (some placed) > not_started.
	_ensure()
	var ph := PlanDoc.phase(_plan, phase_id)
	if bool(ph.get("done", false)):
		return PHASE_COMPLETED
	var t := phase_totals(phase_id, MODE_REMAINING)
	if t.objects == 0:
		return PHASE_NOT_STARTED
	if t.placed_objects == t.objects:
		return PHASE_COMPLETED
	if t.to_buy_objects == 0 and t.plots.is_empty():
		return PHASE_READY
	if t.placed_objects > 0:
		return PHASE_IN_PROGRESS
	return PHASE_NOT_STARTED


func affordability(balances: Dictionary, mode: String = MODE_REMAINING, include_unphased: bool = true) -> Dictionary:
	## Which phases the balances pay for, in build order, with the cost summed
	## cumulatively (currencies are never converted). Returns
	## {phases: [{phase, name, cost, cumulative, affordable, exact, shortfall}],
	##  affordable_count (leading affordable phases), missing_balances (currencies
	##  needed without a balance entry: treated as 0)}. `exact` is false once any
	## phase so far has unknown / unbuyable prices: the cumulative cost is then a
	## lower bound.
	_ensure()
	var rows: Array = []
	var cum := {}
	var exact := true
	var leading := 0
	var still := true
	var missing := {}
	for pid in phase_ids(include_unphased):
		var t := phase_totals(pid, mode)
		if pid == UNPHASED and t.objects == 0 and t.plots.is_empty():
			continue
		Currency.add_into(cum, t.cost)
		exact = exact and t.is_exact()
		var ok := Currency.covers(balances, cum)
		for k in cum:
			if not balances.has(k):
				missing[k] = true
		if ok and still:
			leading += 1
		else:
			still = false
		rows.append({"phase": pid, "name": _phase_name(pid), "cost": t.cost, "cumulative": cum.duplicate(),
			"affordable": ok, "exact": exact, "shortfall": Currency.shortfall(balances, cum)})
	return {"phases": rows, "affordable_count": leading, "missing_balances": Currency.sorted_ids(missing.keys())}


static func spendable(profile: Dictionary) -> Dictionary:
	## profile.balances capped by the old budget_coins / budget_diamonds limits
	## (a budget without a balance counts as the balance).
	var out: Dictionary = (profile.get("balances", {}) as Dictionary).duplicate() if profile.get("balances") is Dictionary else {}
	for pair in [[Currency.COINS, "budget_coins"], [Currency.DIAMONDS, "budget_diamonds"]]:
		var b := int(profile.get(pair[1], -1)) if (profile.get(pair[1]) is int or profile.get(pair[1]) is float) else -1
		if b >= 0:
			out[pair[0]] = mini(int(out[pair[0]]), b) if out.has(pair[0]) else b
	return out


func plots_needed(uids: Variant = null) -> Array:
	return totals(uids, MODE_TO_BUY).plots


func plot_cost(plot_id: String) -> Variant:
	## Supplies to unlock a plot (Cost) or null when the map doesn't know them.
	if map == null or not map.has_plot(plot_id):
		return null
	return _plot_cost(int(map.plot_index[map.resolve_plot_id(plot_id)]))


func plot_phase(plot_id: String) -> String:
	## The earliest phase (build order) needing a locked plot; "" = Unphased or not needed.
	_ensure()
	_derive()
	if map == null or not map.has_plot(plot_id):
		return UNPHASED
	var p := int(map.plot_index[map.resolve_plot_id(plot_id)])
	return _phase_id(int(_plot_phase.get(p, _phase_ids.size())))


func item_breakdown(uids: Variant = null, mode: String = MODE_TO_BUY) -> Dictionary:
	## Per item for a scope: item -> {used, owned, acquired, to_buy, placed,
	## charged, known (charged with a price), unknown, not_buyable, cost (known
	## part), k_min, k_max (copy / purchase numbers of the charged objects, 0 = none)}.
	## The entries are the caller's own copies (item_rollups() shares them).
	var out := {}
	for r: Array in item_rollups(uids, mode):
		out[r[0]] = (r[1] as Dictionary).duplicate(true)
	return out


func item_rollups(uids: Variant = null, mode: String = MODE_TO_BUY) -> Array:
	## item_breakdown() for views that list items: [[item id, entry, revision]]
	## (revision = item_revision()). For the whole farm, and for the exact lists
	## phase_uids() / area_uids() return, the entries are kept per item and
	## rebuilt only for the items an edit touched (items in catalogue-id order);
	## other uid lists are summed per call (items in order of first appearance)
	## and cached per version. Entries are SHARED: read them, never modify them.
	_ensure()
	var mi: int = MODES.find(mode)
	if mi < 0:
		mi = 1   # same as To buy (any other mode charges like To buy)
	if uids == null:
		return _kept_entries(mi, mode, -1, {})
	for aid: String in _areas:
		var ae: Dictionary = _areas[aid]
		if is_same(uids, ae["list"]):
			return _kept_entries(mi, mode, -2, ae)
	var h: int = uids.hash()
	var pv: Variant = _cache.get("scope/%d" % h)
	if pv != null and _cache.get("phase_uids/%d" % int(pv)) == uids:
		_derive()
		return _kept_entries(mi, mode, int(pv), {})
	var key := "rollups/%s/%d" % [mode, h]
	var hit: Variant = _cache.get(key)
	if hit != null and hit[0] == uids:
		return hit[1]
	var slots := PackedInt32Array()
	for u in uids:
		var s: int = _slot.get(int(u), -1)
		if s >= 0:
			slots.append(s)
	var out := _entries_of(slots, mode)
	_cache[key] = [(uids as Array).duplicate() if uids is Array else uids, out]
	return out


func _kept_entries(mi: int, mode: String, phase: int, area: Dictionary) -> Array:
	## Per-item entries kept across versions (dropped per item by _touch()) for
	## the whole farm (phase -1), one phase (its index) or one area (phase -2,
	## `area` = its membership entry). Items without objects in the scope are left out.
	var out: Array = []
	var members: Dictionary = area.get("members", {})
	var sk: Variant = mi if phase == -1 else ("%d/%d" % [phase, mi] if phase >= 0 else "a:%s/%d" % [str(area["def"].get("id")), mi])
	for idx in _items.size():
		var b: PackedInt32Array = _bucket[idx]
		if b.is_empty():
			continue
		var per: Variant = _roll.get(idx)
		if per == null:
			per = {}
			_roll[idx] = per
		var e: Variant = per.get(sk, false)
		if e is bool:
			var slots := b
			if phase != -1:
				slots = PackedInt32Array()
				for s in b:
					if (phase >= 0 and _s_phase[s] == phase) or (phase == -2 and members.has(_s_uid[s])):
						slots.append(s)
			e = _entry_of(slots, mode) if not slots.is_empty() else null
			per[sk] = e
		if e != null:
			out.append([_items[idx], e, _i_rev[idx]])
	return out


func _entry_of(slots: PackedInt32Array, mode: String) -> Dictionary:
	## Breakdown entry of one item's slots (see item_breakdown()).
	var design := mode == MODE_DESIGN
	var remaining := mode == MODE_REMAINING
	var n_st := PackedInt32Array([0, 0, 0])
	var placed := 0
	var charged := 0
	var known := 0
	var unknown := 0
	var nb := 0
	var k_min := 0
	var k_max := 0
	var per_cid := {}
	var ss := _s_status
	for s in slots:
		var st := ss[s]
		n_st[st] += 1
		placed += _s_placed[s]
		var cid: int
		var k: int
		if design:
			cid = _s_dcid[s]
			k = _s_dk[s]
		elif st == _ST_OWNED or (remaining and st == _ST_ACQUIRED):
			continue
		else:
			cid = _s_bcid[s]
			k = _s_bk[s]
		charged += 1
		k_min = k if k_min == 0 else mini(k_min, k)
		k_max = maxi(k_max, k)
		if cid == CID_UNKNOWN:
			unknown += 1
		elif cid == CID_NOT_BUYABLE:
			nb += 1
		else:
			known += 1
			per_cid[cid] = int(per_cid.get(cid, 0)) + 1
	var cost := {}
	for cid: int in per_cid:
		Currency.add_into(cost, _costs[cid], per_cid[cid])
	return {"used": slots.size(), "owned": n_st[_ST_OWNED], "acquired": n_st[_ST_ACQUIRED], "to_buy": n_st[_ST_TO_BUY],
		"placed": placed, "charged": charged, "known": known, "unknown": unknown, "not_buyable": nb, "cost": cost,
		"k_min": k_min, "k_max": k_max}


func _entries_of(slots: PackedInt32Array, mode: String) -> Array:
	## [[item id, entry, revision]] for any slots, items in order of first appearance.
	var ni := _items.size()
	var design := mode == MODE_DESIGN
	var remaining := mode == MODE_REMAINING
	# per item: used, owned, acquired, to_buy, placed, charged, known, unknown, not_buyable, k_min, k_max
	var acc := PackedInt32Array()
	acc.resize(ni * 11)
	acc.fill(0)
	var order := PackedInt32Array()
	var per_cid := {}   ## idx * 2^24 + cost id -> count (first-appearance order)
	var si := _s_item
	var ss := _s_status
	var sp := _s_placed
	for s in slots:
		var idx := si[s]
		var b := idx * 11
		if acc[b] == 0:
			order.append(idx)
		acc[b] += 1
		var st := ss[s]
		acc[b + 1 + st] += 1
		acc[b + 4] += sp[s]
		var cid: int
		var k: int
		if design:
			cid = _s_dcid[s]
			k = _s_dk[s]
		elif st == _ST_OWNED or (remaining and st == _ST_ACQUIRED):
			continue
		else:
			cid = _s_bcid[s]
			k = _s_bk[s]
		acc[b + 5] += 1
		acc[b + 9] = k if acc[b + 9] == 0 else mini(acc[b + 9], k)
		acc[b + 10] = maxi(acc[b + 10], k)
		if cid == CID_UNKNOWN:
			acc[b + 7] += 1
		elif cid == CID_NOT_BUYABLE:
			acc[b + 8] += 1
		else:
			acc[b + 6] += 1
			var ck := idx * 16777216 + cid
			per_cid[ck] = int(per_cid.get(ck, 0)) + 1
	var costs := {}
	for ck: int in per_cid:
		@warning_ignore("integer_division")
		var idx := ck / 16777216
		if not costs.has(idx):
			costs[idx] = {}
		Currency.add_into(costs[idx], _costs[ck - idx * 16777216], per_cid[ck])
	var out: Array = []
	for idx in order:
		var b := idx * 11
		out.append([_items[idx], {"used": acc[b], "owned": acc[b + 1], "acquired": acc[b + 2], "to_buy": acc[b + 3],
			"placed": acc[b + 4], "charged": acc[b + 5], "known": acc[b + 6], "unknown": acc[b + 7],
			"not_buyable": acc[b + 8], "cost": costs.get(idx, {}), "k_min": acc[b + 9], "k_max": acc[b + 10]},
			_i_rev[idx]])
	return out


# --- context / recompute ---------------------------------------------------------------------

func _current_plan() -> Dictionary:
	var p: Variant = layout.get("planning")
	return p if p is Dictionary else _empty_plan


func _ensure() -> void:
	## Brings everything up to date (does nothing when nothing changed). Changes
	## found without a signal (dictionaries edited in place, objects added with
	## emit = false) also bump `version`. Inside a batch, nothing to do until the
	## next signal (only the object count is still compared).
	if _synced and _batch_depth > 0 and layout.objects.size() == _slot.size():
		return
	var silent := false
	if map != null and _locked.size() != map.plots.size():
		_need_full = true
	if prices != null and prices.version != _prices_version:
		_need_full = true
	if layout.objects.size() != _slot.size() + _pending_net():
		_need_full = true   # objects added/removed without a signal
		silent = true
	if not _need_full:
		var had_signal := _ctx_dirty
		var before := _pending.size() + _dirty_items.size()
		_sync_context()
		if not had_signal and (_need_full or _land_dirty or _pending.size() + _dirty_items.size() != before):
			silent = true
	if _need_full:
		_full(_current_plan())
	else:
		var work := _land_dirty or not _pending.is_empty() or not _dirty_items.is_empty()
		if _land_dirty:
			_refresh_locked()
		if not _pending.is_empty():
			if _pending.size() * 3 > maxi(30, _slot.size()):
				_full(_current_plan())
			else:
				_apply_pending()
		if not _dirty_items.is_empty():
			for idx: int in _dirty_items:
				_alloc(idx)
			_dirty_items.clear()
		if work:
			_cache.clear()
			_derived_ok = false
	if silent:
		version += 1
	_synced = true


func _pending_net() -> int:
	## Pending adds minus pending removals (so the size check above stays exact).
	var n := 0
	for u: int in _pending:
		var has_obj := layout.objects.has(u)
		var has_slot := _slot.has(u)
		if has_obj and not has_slot:
			n += 1
		elif has_slot and not has_obj:
			n -= 1
	return n


func _sync_context() -> void:
	var plan := _current_plan()
	var prof := layout.profile
	var check := _ctx_dirty or not is_same(plan, _plan) or not is_same(prof, _profile_ref)
	if not check and auto_detect and _batch_depth == 0:
		check = _context_hash(plan, prof) != _ctx_hash
	if check:
		_diff_context(plan, prof)
	if not _land_dirty and layout.unlocked_plots.hash() != _unlocked_hash:
		_land_dirty = true
	_ctx_dirty = false


func _context_hash(plan: Dictionary, prof: Dictionary) -> int:
	return [plan, prof.get("owned"), prof.get("purchased")].hash()


static func _struct_of(plan: Dictionary, with_baseline: bool = true) -> Array:
	## What phase membership and allocation order depend on (not names, colours, notes, done).
	var out: Array = []
	for a in plan.get("areas", []):
		out.append([a.get("id"), a.get("rect"), a.get("points")])
	out.append("|")
	for p in plan.get("phases", []):
		out.append([p.get("id"), p.get("areas")])
	if with_baseline:
		out.append(plan.get("baseline"))
	return out


func _diff_context(plan: Dictionary, prof: Dictionary) -> void:
	if _struct_of(plan).hash() != _struct_hash:
		_need_full = true
		return
	_plan = plan
	_profile_ref = prof
	var assign: Dictionary = plan.get("assign", {})
	var placed: Dictionary = plan.get("placed", {})
	var touched := false
	for k in _changed_keys(assign, _snap_assign) + _changed_keys(placed, _snap_placed):
		if str(k).is_valid_int():
			_pending[int(k)] = true
		touched = true
	_assign = assign
	_placed = placed
	if touched:
		_rebuild_uid_maps()
	var acq: Dictionary = plan.get("acquired", {})
	var owned: Dictionary = prof.get("owned", {}) if prof.get("owned") is Dictionary else {}
	var purch: Dictionary = prof.get("purchased", {}) if prof.get("purchased") is Dictionary else {}
	var inv := [owned, purch, acq]
	var items := {}
	for src in [_changed_keys(acq, _snap_acquired), _changed_keys(owned, _snap_owned), _changed_keys(purch, _snap_purchased)]:
		for k in src:
			items[str(k)] = true
	for id: String in items:
		var idx: int = _item_idx.get(id, -1)
		if idx >= 0:
			_setup_inv(idx, inv)
			_dirty_items[idx] = true
	_take_snapshots(plan, prof)


static func _changed_keys(a: Dictionary, b: Dictionary) -> Array:
	var out: Array = []
	for k in a:
		if not b.has(k) or b[k] != a[k]:
			out.append(k)
	for k in b:
		if not a.has(k):
			out.append(k)
	return out


func _take_snapshots(plan: Dictionary, prof: Dictionary) -> void:
	_snap_assign = (plan.get("assign", {}) as Dictionary).duplicate(true)
	_snap_placed = (plan.get("placed", {}) as Dictionary).duplicate(true)
	_snap_acquired = (plan.get("acquired", {}) as Dictionary).duplicate(true)
	_snap_owned = (prof.get("owned", {}) as Dictionary).duplicate(true) if prof.get("owned") is Dictionary else {}
	_snap_purchased = (prof.get("purchased", {}) as Dictionary).duplicate(true) if prof.get("purchased") is Dictionary else {}
	_ctx_hash = _context_hash(plan, prof) if auto_detect else 0


func _load_context(plan: Dictionary) -> void:
	_plan = plan
	_profile_ref = layout.profile
	_phase_ids = PackedStringArray()
	_phase_index.clear()
	_phase_areas.clear()
	for p in PlanDoc.phases(plan):
		var pid := str(p.get("id"))
		_phase_index[pid] = _phase_ids.size()
		_phase_ids.append(pid)
		var al: Array = []
		for aid in p.get("areas", []):
			var a := PlanDoc.area(plan, str(aid))
			if not a.is_empty():
				al.append([a, PlanDoc.area_bounds(a)])
		_phase_areas.append(al)
	_assign = plan.get("assign", {})
	_placed = plan.get("placed", {})
	_baseline = {}
	var bl: Variant = plan.get("baseline")
	if bl is Dictionary and bl.get("objects") is Dictionary:
		_baseline = bl["objects"]
	_rebuild_uid_maps()
	_rebuild_base()
	var gk := [_struct_of(plan, false), map.get_instance_id() if map != null else 0, map.plots.size() if map != null else 0].hash()
	if gk != _grid_key or _grid.is_empty():
		_build_grid()
		_grid_key = gk
	_struct_hash = _struct_of(plan).hash()
	_take_snapshots(plan, layout.profile)


func _rebuild_uid_maps() -> void:
	## int-keyed copies of the per-object planning maps (no str(uid) per object).
	## (uid keys are positive ints saved as strings; anything else is ignored).
	_assign_u = {}
	for k in _assign:
		var pid := str(_assign[k])
		var u := int(k)
		if u > 0 and _phase_index.has(pid):
			_assign_u[u] = int(_phase_index[pid])
	_placed_u = {}
	for k in _placed:
		var u := int(k)
		if u > 0:
			_placed_u[u] = true


func _rebuild_base() -> void:
	## int-keyed baseline entries and baseline copies per item.
	_base_u = {}
	_baseline_counts = {}
	var raw_counts := {}
	for k in _baseline:
		var e: Variant = _baseline[k]
		var u := int(k)
		if u > 0 and e is Array and not (e as Array).is_empty():
			_base_u[u] = e
			var raw := str(e[0])
			raw_counts[raw] = int(raw_counts.get(raw, 0)) + 1
	for raw: String in raw_counts:
		var id := _item_key(raw)
		_baseline_counts[id] = int(_baseline_counts.get(id, 0)) + int(raw_counts[raw])


func _build_grid() -> void:
	## One value per tile over the map grid and every phase area:
	##   low 16 bits  = the first phase in build order with an area containing the
	##                  tile (phases.size() = none), so an object's area-rule phase
	##                  is the minimum over its footprint (PlanDoc.primary_phases rule);
	##   high bits    = expansion plot index + 1 (0 = not plot land).
	_grid = PackedInt32Array()
	_tp_ok = true
	var unph := _phase_ids.size()
	var bounds := Rect2i(Vector2i.ZERO, map.size) if map != null else Rect2i()
	var have := map != null
	var area_bounds := Rect2i()
	var any_area := false
	for al in _phase_areas:
		for pair in al:
			var b: Rect2i = pair[1]
			if b.size.x <= 0 or b.size.y <= 0:
				continue
			area_bounds = b if not any_area else area_bounds.merge(b)
			any_area = true
	if any_area:
		if area_bounds.get_area() > 4000000:
			_tp_ok = false   # absurdly large areas: per-object geometry instead
		else:
			bounds = area_bounds if not have else bounds.merge(area_bounds)
			have = true
	_g_rect = bounds
	if not have or bounds.get_area() <= 0:
		_g_rect = Rect2i()
	_gx = _g_rect.position.x
	_gy = _g_rect.position.y
	_gw = _g_rect.size.x
	_gex = _g_rect.end.x
	_gey = _g_rect.end.y
	if _g_rect.size.x <= 0:
		return
	_grid.resize(bounds.get_area())
	_grid.fill(unph)
	var w := bounds.size.x
	if map != null:
		var po := map.plot_of
		for y in map.size.y:
			var row := (y - bounds.position.y) * w - bounds.position.x
			var mrow := y * map.size.x
			for x in map.size.x:
				var p := po[mrow + x]
				if p >= 0:
					_grid[row + x] = unph | ((p + 1) << 16)
	if not any_area or not _tp_ok:
		return
	for i in range(_phase_areas.size() - 1, -1, -1):   # earlier phases overwrite later ones
		for pair in _phase_areas[i]:
			var a: Dictionary = pair[0]
			var b: Rect2i = pair[1]
			var is_rect: bool = a.get("rect") is Array
			var pts := PackedVector2Array() if is_rect else PlanDoc.polygon(a)
			for y in range(b.position.y, b.end.y):
				var row := (y - bounds.position.y) * w - bounds.position.x
				for x in range(b.position.x, b.end.x):
					if is_rect or PlanDoc.point_in_polygon(Vector2(x + 0.5, y + 0.5), pts):
						var j := row + x
						_grid[j] = (_grid[j] & ~0xFFFF) | i


func _reset_items() -> void:
	_items = PackedStringArray()
	_item_idx.clear()
	_raw_idx.clear()
	_bucket.clear()
	_i_kind = PackedInt32Array()
	_i_const = PackedInt32Array()
	_i_owned = PackedInt32Array()
	_i_owned_known = PackedByteArray()
	_i_acquired = PackedInt32Array()
	_i_purchased = PackedInt32Array()
	_i_max = PackedInt32Array()
	_i_rev = PackedInt32Array()
	_roll.clear()
	view_cache.clear()
	_kcid.clear()
	_costs = [{}]
	_cost_index.clear()
	_cost_index[{}] = 0


func _full(plan: Dictionary) -> void:
	full_recomputes += 1
	_slot.clear()
	_free = PackedInt32Array()
	_s_plots.clear()
	_roll.clear()
	_areas.clear()
	var pv := prices.version if prices != null else 0
	if pv != _prices_version:
		_reset_items()   # the item table and interned prices survive a full recompute otherwise
		_prices_version = pv
	else:
		for b in _bucket.size():
			_bucket[b] = PackedInt32Array()
	_load_context(plan)
	_refresh_locked()
	var inv := _inventory_dicts()
	for idx in _items.size():
		_setup_inv(idx, inv)
	var n := layout.objects.size()
	_s_uid = PackedInt32Array()
	_s_item = PackedInt32Array()
	_s_phase = PackedInt32Array()
	_s_status = PackedInt32Array()
	_s_dcid = PackedInt32Array()
	_s_bcid = PackedInt32Array()
	_s_dk = PackedInt32Array()
	_s_bk = PackedInt32Array()
	_s_plot = PackedInt32Array()
	_s_placed = PackedByteArray()
	_s_base = PackedByteArray()
	_reserve(n)
	# One global sort instead of per-item buckets: key = item | not-baseline |
	# phase | uid, so each item's run is already in allocation order.
	var sorted := _phase_ids.size() < 2047
	var keys := PackedInt64Array()
	keys.resize(n if sorted else 0)
	# Hot loop: _is_base(), _is_placed() and _scan() inlined (function calls
	# dominate GDScript cost at 10k objects); keep the three in sync.
	var raw_idx := _raw_idx
	var slot := _slot
	var base_u := _base_u
	var placed_u := _placed_u
	var assign_u := _assign_u
	var has_base := not base_u.is_empty()
	var has_placed := not placed_u.is_empty()
	var has_assign := not assign_u.is_empty()
	var unph := _phase_ids.size()
	var tp_ok := _tp_ok
	var g := _grid
	var gx := _gx
	var gy := _gy
	var gw := _gw
	var gex := _gex
	var gey := _gey
	var i := 0
	for o: PlacedObject in layout.objects.values():
		var idx: int = raw_idx.get(o.item_id, -1)
		if idx < 0:
			idx = _idx_of_raw(o.item_id)
		var u := o.uid
		var org := o.origin
		var sz := o.size
		_s_uid[i] = u
		_s_item[i] = idx
		var base := false
		var placed := false
		if has_base:
			var e: Variant = base_u.get(u)
			if e != null:
				var bid := str(e[0])
				base = bid == o.item_id or _item_key(bid) == _items[idx]
				placed = base and same_spot(e, o)
		if has_placed and not placed:
			placed = placed_u.has(u)
		_s_base[i] = 1 if base else 0
		_s_placed[i] = 1 if placed else 0
		var ph := unph
		var by_tiles := tp_ok
		if has_assign:
			var m: int = assign_u.get(u, -1)
			if m >= 0:
				ph = m
				by_tiles = false
		if by_tiles == false and ph == unph and not tp_ok:
			ph = _phase_slow(o.rect())
		var x0 := maxi(org.x, gx)
		var y0 := maxi(org.y, gy)
		var x1 := mini(org.x + sz.x, gex)
		var y1 := mini(org.y + sz.y, gey)
		var p1 := -1
		var multi := false
		if x0 < x1 and y0 < y1:
			var row := (y0 - gy) * gw - gx
			for y in range(y0, y1):
				for x in range(x0, x1):
					var v := g[row + x]
					if by_tiles and (v & 0xFFFF) < ph:
						ph = v & 0xFFFF
					if v >= 65536:
						var p := (v >> 16) - 1
						if p1 < 0:
							p1 = p
						elif p != p1:
							multi = true
				row += gw
		_s_phase[i] = ph
		_s_plot[i] = p1
		if multi:
			_s_plots[i] = _plots_under(x0, y0, x1, y1)
		if sorted:
			keys[i] = (idx << 44) | ((0 if base else 1) << 43) | (ph << 32) | u
		else:
			_bucket_add(idx, i)
		slot[u] = i
		i += 1
	if sorted:
		keys.sort()
		var j := 0
		while j < n:
			var idx := keys[j] >> 44
			var start := j
			while j < n and (keys[j] >> 44) == idx:
				j += 1
			_bucket[idx] = _assign_copies(idx, keys, start, j - start)
	else:
		for idx in _items.size():
			_alloc(idx)
	_pending.clear()
	_dirty_items.clear()
	_need_full = false
	_ctx_dirty = false
	_land_dirty = false
	_cache.clear()
	_derived_ok = false


func _reserve(n: int) -> void:
	_s_uid.resize(n)
	_s_item.resize(n)
	_s_phase.resize(n)
	_s_status.resize(n)
	_s_dcid.resize(n)
	_s_bcid.resize(n)
	_s_dk.resize(n)
	_s_bk.resize(n)
	_s_plot.resize(n)
	_s_placed.resize(n)
	_s_base.resize(n)


func _new_slot() -> int:
	if not _free.is_empty():
		var s := _free[_free.size() - 1]
		_free.resize(_free.size() - 1)
		return s
	var n := _s_uid.size()
	_reserve(n + 1)
	return n


func _apply_pending() -> void:
	var track_areas := not _areas.is_empty()
	for u: int in _pending:
		var o: PlacedObject = layout.objects.get(u)
		var s: int = _slot.get(u, -1)
		if track_areas:
			_area_update(u, o)
		if o == null:
			if s >= 0:
				var old := _s_item[s]
				_bucket_remove(old, s)
				_dirty_items[old] = true
				_touch(old)
				_s_item[s] = -1
				_s_plot[s] = -1
				_s_plots.erase(s)
				_slot.erase(u)
				_free.append(s)
			continue
		var idx := _idx_of_raw(o.item_id)
		var base := _is_base(o, idx)
		_touch(idx)   # placed marks change without a re-allocation
		if s < 0:
			s = _new_slot()
			_s_uid[s] = o.uid
			_s_item[s] = idx
			_s_status[s] = _ST_TO_BUY
			_bucket_add(idx, s)
			_slot[u] = s
			_dirty_items[idx] = true
		else:
			var prev := _s_item[s]
			if idx != prev:
				_bucket_remove(prev, s)
				_bucket_add(idx, s)
				_s_item[s] = idx
				_dirty_items[prev] = true
				_dirty_items[idx] = true
			if (1 if base else 0) != _s_base[s]:
				_dirty_items[idx] = true
		var old_phase := _s_phase[s]
		_scan(s, o)
		if _s_phase[s] != old_phase:
			_dirty_items[idx] = true
		_s_base[s] = 1 if base else 0
		_s_placed[s] = 1 if _is_placed(o, base) else 0
	_pending.clear()


func _bucket_add(idx: int, s: int) -> void:
	var a: PackedInt32Array = _bucket[idx]
	a.append(s)
	_bucket[idx] = a


func _bucket_remove(idx: int, s: int) -> void:
	var a: PackedInt32Array = _bucket[idx]
	var i := a.find(s)
	if i >= 0:
		a.remove_at(i)
		_bucket[idx] = a


func _idx_of_raw(raw: String) -> int:
	var idx: int = _raw_idx.get(raw, -1)
	if idx < 0:
		idx = _intern_item(_item_key(raw))
		_raw_idx[raw] = idx
	return idx


func _intern_item(id: String) -> int:
	var idx: int = _item_idx.get(id, -1)
	if idx >= 0:
		return idx
	idx = _items.size()
	_items.append(id)
	_item_idx[id] = idx
	_bucket.append(PackedInt32Array())
	_i_kind.append(_K_UNKNOWN)
	_i_const.append(CID_UNKNOWN)
	_i_owned.append(0)
	_i_owned_known.append(0)
	_i_acquired.append(0)
	_i_purchased.append(0)
	_i_max.append(-1)
	_i_rev.append(0)
	_setup_price(idx)
	_setup_inv(idx, _inventory_dicts())
	return idx


func _setup_price(idx: int) -> void:
	## Price kind, constant price and max count of one item (depends on prices only).
	var id := _items[idx]
	var it: ItemDef = db.get_item(id) if db != null else null
	var known_item := db == null or it != null
	var kind := _K_UNKNOWN
	var cst := CID_UNKNOWN
	var mx := it.max_count if it != null else -1
	if prices != null and known_item:
		var r := prices.resolved(id)
		mx = int(r.get("max_count", -1))
		if r["method"] in PriceBook.NOT_BUYABLE_METHODS:
			kind = _K_NOT_BUYABLE
			cst = CID_NOT_BUYABLE
		elif r["method"] in PriceBook.COST_METHODS:
			kind = _K_PRICED
			if bool(r["progressive"]):
				cst = _UNSET   # per copy, cached in _kcid
			else:
				var c: Variant = prices.copy_price(id, 1)
				cst = CID_UNKNOWN if c == null else _intern_cost(c)
	_i_kind[idx] = kind
	_i_const[idx] = cst
	_i_max[idx] = mx
	_touch(idx)


func _inventory_dicts() -> Array:
	var prof := layout.profile
	return [prof.get("owned") if prof.get("owned") is Dictionary else {},
		prof.get("purchased") if prof.get("purchased") is Dictionary else {},
		_plan.get("acquired") if _plan.get("acquired") is Dictionary else {}]


func _setup_inv(idx: int, inv: Array) -> void:
	## Owned (effective), acquired and purchase base of one item.
	var id := _items[idx]
	var owned_d: Dictionary = inv[0]
	var base_n: int = _baseline_counts.get(id, 0)
	var ov: Variant = owned_d.get(id)
	var has_owned := ov is int or ov is float
	var owned := maxi(maxi(0, int(ov)), base_n) if has_owned else base_n
	_i_owned[idx] = owned
	_i_owned_known[idx] = 1 if (has_owned or base_n > 0) else 0
	var acq: Variant = (inv[2] as Dictionary).get(id)
	_i_acquired[idx] = maxi(0, int(acq)) if (acq is int or acq is float) else 0
	var pv: Variant = (inv[1] as Dictionary).get(id)
	_i_purchased[idx] = maxi(0, int(pv)) if (pv is int or pv is float) else owned
	_touch(idx)


func _touch(idx: int) -> void:
	## The item may have changed: new revision, drop its whole-farm breakdown.
	_rev_counter += 1
	_i_rev[idx] = _rev_counter
	if not _roll.is_empty():
		_roll.erase(idx)


func _alloc(idx: int) -> void:
	## Allocation of one item (see the class doc).
	var b: PackedInt32Array = _bucket[idx]
	var n := b.size()
	if n == 0:
		item_recomputes += 1
		_touch(idx)
		return
	var keys := PackedInt64Array()
	keys.resize(n)
	var i := 0
	for s in b:
		keys[i] = ((1 - _s_base[s]) << 52) | (_s_phase[s] << 32) | _s_uid[s]
		i += 1
	keys.sort()
	_bucket[idx] = _assign_copies(idx, keys, 0, n)


func _assign_copies(idx: int, keys: PackedInt64Array, start: int, n: int) -> PackedInt32Array:
	## Gives the n objects keys[start..] (one item, allocation order; uid in the
	## low 32 bits) their status, copy numbers and costs. Returns their slots in
	## that order.
	item_recomputes += 1
	_touch(idx)
	var out := PackedInt32Array()
	out.resize(n)
	var owned := _i_owned[idx]
	var covered := owned + _i_acquired[idx]
	var pb := _i_purchased[idx]
	var cst := _i_const[idx]
	for j in n:
		var s: int = _slot[keys[start + j] & 0xFFFFFFFF]
		out[j] = s
		_s_dk[s] = j + 1
		_s_dcid[s] = cst if cst != _UNSET else _cid(idx, j + 1)
		if j < owned:
			_s_status[s] = _ST_OWNED
			_s_bk[s] = 0
			_s_bcid[s] = 0
		else:
			var k := pb + (j - owned) + 1
			_s_status[s] = _ST_ACQUIRED if j < covered else _ST_TO_BUY
			_s_bk[s] = k
			_s_bcid[s] = cst if cst != _UNSET else _cid(idx, k)
	return out


func _cid(idx: int, k: int) -> int:
	var c := _i_const[idx]
	if c != _UNSET:
		return c
	var key := idx * 1048576 + k
	var v: int = _kcid.get(key, _UNSET)
	if v != _UNSET:
		return v
	var cost: Variant = prices.copy_price(_items[idx], k)
	v = CID_UNKNOWN if cost == null else _intern_cost(cost)
	_kcid[key] = v
	return v


func _intern_cost(c: Dictionary) -> int:
	var v: int = _cost_index.get(c, -1)
	if v >= 0:
		return v
	v = _costs.size()
	var copy := c.duplicate()
	_costs.append(copy)
	_cost_index[copy] = v
	return v


func _item_key(id: String) -> String:
	return db.resolve_id(id) if db != null else id


func _scan(s: int, o: PlacedObject) -> void:
	## Primary phase (manual assignment, else the first phase in build order with
	## an area containing any footprint tile) and the expansion plots under the
	## footprint, in one pass over the footprint tiles of the grid.
	var ph := -1
	if not _assign_u.is_empty():
		ph = _assign_u.get(o.uid, -1)
	var by_tiles := ph < 0 and _tp_ok
	if ph < 0:
		ph = _phase_ids.size() if _tp_ok else _phase_slow(o.rect())
	var org := o.origin
	var sz := o.size
	var x0 := maxi(org.x, _gx)
	var y0 := maxi(org.y, _gy)
	var x1 := mini(org.x + sz.x, _gex)
	var y1 := mini(org.y + sz.y, _gey)
	var p1 := -1
	var multi := false
	if x0 < x1 and y0 < y1:
		var g := _grid
		var gw := _gw
		var row := (y0 - _gy) * gw - _gx
		for y in range(y0, y1):
			for x in range(x0, x1):
				var v := g[row + x]
				if by_tiles and (v & 0xFFFF) < ph:
					ph = v & 0xFFFF
				if v >= 65536:
					var p := (v >> 16) - 1
					if p1 < 0:
						p1 = p
					elif p != p1:
						multi = true
			row += gw
	_s_phase[s] = ph
	_s_plot[s] = p1
	if multi:
		_s_plots[s] = _plots_under(x0, y0, x1, y1)
	elif not _s_plots.is_empty():
		_s_plots.erase(s)


func _plots_under(x0: int, y0: int, x1: int, y1: int) -> PackedInt32Array:
	## Every plot index in a (grid-clipped) footprint (rare: objects across plot borders).
	var out := PackedInt32Array()
	for y in range(y0, y1):
		for x in range(x0, x1):
			var v := _grid[(y - _gy) * _gw - _gx + x]
			if v >= 65536 and not out.has((v >> 16) - 1):
				out.append((v >> 16) - 1)
	return out


func _phase_slow(r: Rect2i) -> int:
	for i in _phase_areas.size():
		for pair in _phase_areas[i]:
			if (pair[1] as Rect2i).intersects(r) and PlanDoc.rect_in_area(pair[0], r):
				return i
	return _phase_ids.size()


func _slot_plots(s: int) -> PackedInt32Array:
	## Plot indices under a slot's footprint.
	var p1 := _s_plot[s]
	if p1 < 0:
		return PackedInt32Array()
	return _s_plots[s] if _s_plots.has(s) else PackedInt32Array([p1])


func _is_base(o: PlacedObject, idx: int) -> bool:
	## Same uid and item as in the baseline snapshot (unchanged or moved).
	var e: Variant = _base_u.get(o.uid)
	if e == null:
		return false
	var bid := str(e[0])
	return bid == o.item_id or _item_key(bid) == _items[idx]


func _is_placed(o: PlacedObject, base: bool) -> bool:
	## Marked placed, or a baseline object still at its baseline origin.
	if _placed_u.has(o.uid):
		return true
	if base:
		return same_spot(_base_u[o.uid], o)
	return false


static func same_spot(e: Array, o: PlacedObject) -> bool:
	## A baseline record ["item", x, y, w, h(, flipped)] and the object stand on the
	## same tiles the same way round: Baseline.diff's "unchanged" (rotating in
	## place is a move). Records without a size compare the origin only.
	if e.size() < 3 or int(e[1]) != o.origin.x or int(e[2]) != o.origin.y:
		return false
	if e.size() < 5:
		return true
	if maxi(1, int(e[3])) != o.size.x or maxi(1, int(e[4])) != o.size.y:
		return false
	return (e.size() > 5 and e[5] is bool and bool(e[5])) == o.flipped


func _refresh_locked() -> void:
	_land_dirty = false
	_unlocked_hash = layout.unlocked_plots.hash()
	_locked = PackedByteArray()
	if map == null:
		return
	_locked.resize(map.plots.size())
	for i in map.plots.size():
		_locked[i] = 0 if map.is_plot_unlocked(str(map.plots[i]["id"]), layout.unlocked_plots) else 1
	_derived_ok = false
	_cache.clear()


func _derive() -> void:
	## Per-phase slot lists and the earliest phase of every needed plot.
	if _derived_ok:
		return
	_phase_slots.clear()
	_plot_phase.clear()
	var np := _phase_ids.size() + 1
	var n := _s_uid.size()
	var si := _s_item
	var sph := _s_phase
	var spl := _s_plot
	var counts := PackedInt32Array()
	counts.resize(np)
	counts.fill(0)
	for s in n:
		if si[s] >= 0:
			counts[sph[s]] += 1
	# Counting sort by phase into one array, then one slice per phase.
	var start := PackedInt32Array()
	start.resize(np + 1)
	start[0] = 0
	for i in np:
		start[i + 1] = start[i] + counts[i]
	var at := start.duplicate()
	var all := PackedInt32Array()
	all.resize(start[np])
	var locked := _locked
	for s in n:
		if si[s] < 0:
			continue
		var ph := sph[s]
		all[at[ph]] = s
		at[ph] += 1
		if spl[s] >= 0:
			for p in _slot_plots(s):
				if locked[p] == 1:
					_plot_phase[p] = mini(int(_plot_phase.get(p, 1 << 30)), ph)
	for i in np:
		_phase_slots.append(all.slice(start[i], start[i + 1]))
	_derived_ok = true


func _live_slots() -> PackedInt32Array:
	return PackedInt32Array(_slot.values())


# --- area membership ---------------------------------------------------------------------

func _area_entry(a: Dictionary) -> Dictionary:
	## Membership of one area: every object with a footprint tile in it
	## (PlanDoc.objects_in_area / rect_in_area rule). Polygon tiles are
	## rasterised once with the same even-odd test and arithmetic as
	## PlanDoc.point_in_polygon (tile centres, row by row).
	var b := PlanDoc.area_bounds(a)
	var is_rect: bool = a.get("rect") is Array
	var mask := PackedByteArray()
	if not is_rect and b.size.x > 0 and b.size.y > 0:
		mask = _polygon_mask(PlanDoc.polygon(a), b)
	var e := {"def": a.duplicate(true), "bounds": b, "rect": is_rect, "mask": mask, "members": {}, "list": null}
	var members: Dictionary = e["members"]
	for o: PlacedObject in layout.objects.values():
		if _in_area(e, o):
			members[o.uid] = true
	return e


static func _polygon_mask(pts: PackedVector2Array, b: Rect2i) -> PackedByteArray:
	## 1 per tile of `b` whose centre is inside the polygon (even-odd rule).
	var mask := PackedByteArray()
	mask.resize(b.get_area())
	mask.fill(0)
	var n := pts.size()
	if n < 3:
		return mask
	var w := b.size.x
	for y in range(b.position.y, b.end.y):
		var py: float = Vector2(0.0, y + 0.5).y
		var xs := PackedFloat64Array()
		var j := n - 1
		for i in n:
			var pa := pts[i]
			var pb := pts[j]
			if (pa.y > py) != (pb.y > py):
				xs.append(pa.x + (py - pa.y) * (pb.x - pa.x) / (pb.y - pa.y))
			j = i
		if xs.is_empty():
			continue
		xs.sort()
		var cnt := xs.size()
		var k := 0   # crossings at or left of the tile centre
		var row := (y - b.position.y) * w - b.position.x
		for x in range(b.position.x, b.end.x):
			var px: float = Vector2(x + 0.5, 0.0).x
			while k < cnt and xs[k] <= px:
				k += 1
			if ((cnt - k) & 1) == 1:
				mask[row + x] = 1
	return mask


static func _in_area(e: Dictionary, o: PlacedObject) -> bool:
	var r := Rect2i(o.origin, o.size)
	var b: Rect2i = e["bounds"]
	if not r.intersects(b):
		return false
	if e["rect"]:
		return true
	var c := r.intersection(b)
	var mask: PackedByteArray = e["mask"]
	var w := b.size.x
	for y in range(c.position.y, c.end.y):
		var row := (y - b.position.y) * w - b.position.x
		for x in range(c.position.x, c.end.x):
			if mask[row + x] == 1:
				return true
	return false


func _area_update(u: int, o: PlacedObject) -> void:
	## One object added / moved / removed: update every kept area membership.
	for id: String in _areas:
		var e: Dictionary = _areas[id]
		var members: Dictionary = e["members"]
		var now := o != null and _in_area(e, o)
		if now != members.has(u):
			if now:
				members[u] = true
			else:
				members.erase(u)
			e["list"] = null


func _phase_idx_of(phase_id: String) -> int:
	if phase_id == UNPHASED:
		return _phase_ids.size()
	return int(_phase_index.get(phase_id, -1))


func _phase_id(pi: int) -> String:
	return _phase_ids[pi] if pi < _phase_ids.size() else UNPHASED


func _phase_name(pid: String) -> String:
	if pid == UNPHASED:
		return "Unphased"
	return str(PlanDoc.phase(_plan, pid).get("name", pid))


func _charged(s: int, mode: String) -> bool:
	if mode == MODE_DESIGN:
		return true
	var st := _s_status[s]
	if st == _ST_OWNED:
		return false
	return not (mode == MODE_REMAINING and st == _ST_ACQUIRED)


func _mode_cid(s: int, mode: String) -> int:
	if mode == MODE_DESIGN:
		return _s_dcid[s]
	return _s_bcid[s] if _charged(s, mode) else 0


func _plot_cost(p: int) -> Variant:
	var c: Variant = Currency.normalize(map.plots[p].get("cost"))
	return null if c == null or (c as Dictionary).is_empty() else c


func _sum(slots: PackedInt32Array, mode: String, plot_list: Variant) -> Totals:
	## `plot_list` null = the locked plots under the scope's objects (union).
	## Counts per item and per interned cost in packed arrays, then expands.
	var t := Totals.new()
	t.mode = mode
	var design := mode == MODE_DESIGN
	var remaining := mode == MODE_REMAINING
	var ni := _items.size()
	var per_item := PackedInt32Array()
	per_item.resize(ni)
	per_item.fill(0)
	var flags := PackedByteArray()      ## bit 1 = unknown price charged, bit 2 = not buyable charged
	flags.resize(ni)
	flags.fill(0)
	var per_cost := PackedInt32Array()
	per_cost.resize(_costs.size())
	per_cost.fill(0)
	var st_n := PackedInt32Array([0, 0, 0])
	var placed := 0
	var charged := 0
	var unknown_n := 0
	var nb_n := 0
	var plots := {}
	var collect_plots := plot_list == null and map != null
	var si := _s_item
	var ss := _s_status
	var sp := _s_placed
	var sd := _s_dcid
	var sb := _s_bcid
	var spl := _s_plot
	var locked := _locked
	var seen_items := PackedInt32Array()   ## items / costs met, so the expansion below skips the zeros
	var seen_costs := PackedInt32Array()
	var has_multi := not _s_plots.is_empty()
	for s in slots:
		var idx := si[s]
		if per_item[idx] == 0:
			seen_items.append(idx)
		per_item[idx] += 1
		var st := ss[s]
		st_n[st] += 1
		placed += sp[s]
		if collect_plots and spl[s] >= 0:
			if has_multi and _s_plots.has(s):
				for p in _s_plots[s]:
					if locked[p] == 1:
						plots[p] = true
			elif locked[spl[s]] == 1:
				plots[spl[s]] = true
		var cid: int
		if design:
			cid = sd[s]
		elif st == _ST_OWNED or (remaining and st == _ST_ACQUIRED):
			continue
		else:
			cid = sb[s]
		charged += 1
		if cid >= 0:
			if per_cost[cid] == 0:
				seen_costs.append(cid)
			per_cost[cid] += 1
		elif cid == CID_NOT_BUYABLE:
			nb_n += 1
			flags[idx] |= 2
		else:
			unknown_n += 1
			flags[idx] |= 1
	t.objects = slots.size()
	t.owned_objects = st_n[_ST_OWNED]
	t.acquired_objects = st_n[_ST_ACQUIRED]
	t.to_buy_objects = st_n[_ST_TO_BUY]
	t.placed_objects = placed
	t.charged_objects = charged
	t.unknown_price_objects = unknown_n
	t.not_buyable_objects = nb_n
	seen_costs.sort()   # ascending: same order as a scan of every cost id
	for cid in seen_costs:
		Currency.add_into(t.object_cost, _costs[cid], per_cost[cid])
	var types := 0
	var over: Array = []
	seen_items.sort()
	for idx in seen_items:
		types += 1
		var f := flags[idx]
		if (f & 1) != 0:
			t.unknown_price_types.append(_items[idx])
		if (f & 2) != 0:
			t.not_buyable_types.append(_items[idx])
		if not design and _i_owned_known[idx] == 0:
			t.unknown_ownership_types.append(_items[idx])
		var mx := _i_max[idx]
		if mx > 0:
			var total := (_bucket[idx] as PackedInt32Array).size()
			if total > mx:
				over.append({"item": _items[idx], "count": total, "max": mx})
	t.types = types
	t.unknown_price_types.sort()
	t.not_buyable_types.sort()
	t.unknown_ownership_types.sort()
	over.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["item"]) < str(b["item"]))
	t.over_max = over
	var plot_idx: Array = plots.keys() if plot_list == null else plot_list
	var unknown_plots: Array = []
	var pids: Array = []
	for p: int in plot_idx:
		var pid := str(map.plots[p]["id"])
		pids.append(pid)
		var c: Variant = _plot_cost(p)
		if c == null:
			unknown_plots.append(pid)
		else:
			Currency.add_into(t.land_cost, c)
	pids.sort()
	unknown_plots.sort()
	t.plots = pids
	t.cost = t.object_cost.duplicate()
	if not design:
		t.unknown_cost_plots = unknown_plots
		Currency.add_into(t.cost, t.land_cost)
	return t
