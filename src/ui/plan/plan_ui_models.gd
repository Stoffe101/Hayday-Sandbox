class_name PlanUiModels
extends RefCounted
## Pure view-models behind the Plan panel tabs and planning dialogs (Shop,
## Build, Guide, Accuracy, inventory / price / baseline dialogs). No scene, UI
## or App dependencies: everything here takes core objects and returns plain
## dictionaries and strings, so it is unit-tested in --script mode
## (tests/unit/test_plan_ui_models.gd). Unknown prices stay unknown: no helper
## turns null into 0 or merges currencies.

# --- engine batching ---------------------------------------------------------------------

static func batch(engine: BudgetEngine, f: Callable) -> Variant:
	## Runs `f` with the engine's in-place change detection paused. Every engine
	## query hashes the whole planning dictionary when auto_detect is on; a view
	## that asks hundreds of questions about one unchanged state syncs once
	## first and then skips the hash. Restores the previous setting.
	if engine == null:
		return f.call()
	engine.phase_ids(false)   # one full sync (detects in-place edits once)
	var prev := engine.auto_detect
	engine.auto_detect = false
	var out: Variant = f.call()
	engine.auto_detect = prev
	return out


# --- small text helpers ------------------------------------------------------------------

static func plural(n: int, one: String, many: String = "") -> String:
	return "%s %s" % [Currency.format_amount(n), one if n == 1 else (many if not many.is_empty() else one + "s")]


static func pct_text(f: float) -> String:
	return "%d%%" % int(f) if is_equal_approx(f, roundf(f)) else "%.1f%%" % f


static func percent(done: int, total: int) -> float:
	return 100.0 if total <= 0 else snappedf(100.0 * done / total, 0.1)


static func cost_words(c: Variant) -> String:
	## "150,000 coins and 90 diamonds" (currencies kept apart, display order).
	## null -> "unknown"; {} -> "nothing".
	if not c is Dictionary:
		return "unknown"
	var parts: PackedStringArray = []
	for k in Currency.sorted_ids((c as Dictionary).keys()):
		var a := int(c[k])
		if a != 0:
			parts.append("%s %s" % [Currency.format_amount(a), Currency.unit_name(k, a)])
	if parts.is_empty():
		return "nothing"
	if parts.size() == 1:
		return parts[0]
	return "%s and %s" % [", ".join(parts.slice(0, parts.size() - 1)), parts[parts.size() - 1]]


static func csv_field(s: String) -> String:
	if s.contains(",") or s.contains("\"") or s.contains("\n") or s.contains("\r") or s.contains(";"):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s


static func safe_file_stem(name: String, fallback: String = "farm") -> String:
	## A file-name stem GuideExport accepts as a relative image name
	## ([A-Za-z0-9_ .-], first character a letter, digit or underscore).
	var out := ""
	for ch in name.strip_edges():
		var ok := (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch in ["_", "-", " ", "."]
		out += ch if ok else "_"
	out = out.strip_edges().replace(" ", "_")
	while out.begins_with(".") or out.begins_with("-"):
		out = out.substr(1)
	return out if not out.is_empty() else fallback


# --- scopes (Shop tab) -------------------------------------------------------------------

const SCOPE_FARM := "farm"
const SCOPE_SELECTION := "selection"
const SCOPE_PHASE := "phase"
const SCOPE_AREA := "area"


static func scope_options(plan: Dictionary, selection_count: int) -> Array:
	## [{key, kind, id, label}] for the scope dropdown: whole farm, selection,
	## each phase (build order), each area.
	var out: Array = [{"key": SCOPE_FARM, "kind": SCOPE_FARM, "id": "", "label": "Whole farm"}]
	out.append({"key": SCOPE_SELECTION, "kind": SCOPE_SELECTION, "id": "",
		"label": "Selection (%s)" % plural(selection_count, "object") if selection_count > 0 else "Selection (nothing selected)"})
	for p in PlanDoc.phases(plan):
		var pid := str(p.get("id"))
		out.append({"key": "phase:" + pid, "kind": SCOPE_PHASE, "id": pid, "label": "Phase: %s" % str(p.get("name", pid))})
	for a in PlanDoc.areas(plan):
		var aid := str(a.get("id"))
		out.append({"key": "area:" + aid, "kind": SCOPE_AREA, "id": aid, "label": "Area: %s" % str(a.get("name", aid))})
	return out


static func scope_uids(engine: BudgetEngine, scope: Dictionary, selection: Array) -> Variant:
	## null = whole farm, else the uids of the scope.
	match str(scope.get("kind", SCOPE_FARM)):
		SCOPE_SELECTION:
			return selection.duplicate()
		SCOPE_PHASE:
			return engine.phase_uids(str(scope.get("id", "")))
		SCOPE_AREA:
			return engine.area_uids(str(scope.get("id", "")))
	return null


# --- shopping list view ------------------------------------------------------------------

const SORTS := ["group", "name", "cost", "missing", "level"]
const SORT_NAMES := {"group": "Group", "name": "Name", "cost": "Cost", "missing": "Still needed", "level": "Unlock level"}
const FILTER_KEYS := ["unfinished", "cant_buy", "unknown_price", "over_limit"]
const FILTER_NAMES := {"unfinished": "Unfinished", "cant_buy": "Can't buy", "unknown_price": "Unknown price", "over_limit": "Over limit"}


static func shop_filter(rows: Array, f: Dictionary) -> Array:
	## Every active filter must hold (AND). f: {query, unfinished, cant_buy,
	## unknown_price, over_limit} (all optional).
	var out: Array = []
	for r: Dictionary in rows:
		if bool(f.get("unfinished", false)) and int(r.get("missing", 0)) <= 0:
			continue
		if bool(f.get("cant_buy", false)) and not row_cant_buy(r):
			continue
		if bool(f.get("unknown_price", false)) and not row_price_unknown(r):
			continue
		if bool(f.get("over_limit", false)) and not bool(r.get("over_max", false)):
			continue
		out.append(r)
	var q := str(f.get("query", ""))
	if not q.strip_edges().is_empty():
		out = ShoppingList.search_rows(out, q)
	return out


static func row_cant_buy(r: Dictionary) -> bool:
	return int(r.get("not_buyable_copies", 0)) > 0 or str(r.get("method", "")) in PriceBook.NOT_BUYABLE_METHODS


static func row_price_unknown(r: Dictionary) -> bool:
	if int(r.get("unknown_copies", 0)) > 0:
		return true
	if str(r.get("method", "")) == PriceBook.METHOD_UNKNOWN:
		return true
	return bool(r.get("buyable", false)) and r.get("next_price") == null


static func shop_sort(rows: Array, key: String) -> Array:
	## Sorted copy. group: group order, items before supplies, then name;
	## name; cost: by first currency (display order; currencies are never
	## compared with each other), dearest first, nothing to pay last; missing:
	## most still needed first; level: lowest unlock level first, unknown last.
	## Sorts precomputed key arrays natively (no script comparator: a few
	## hundred rows sort in well under a millisecond).
	var keys: Array = []
	keys.resize(rows.size())
	for i in rows.size():
		var r: Dictionary = rows[i]
		var nm := str(r.get("name", "")).to_lower()
		match key:
			"name":
				keys[i] = [nm, i]
			"cost":
				var ck := _cost_sort_key(r.get("total"))
				keys[i] = [ck[0], ck[1], nm, i]
			"missing":
				keys[i] = [-int(r.get("missing", 0)), nm, i]
			"level":
				var lv := int(r.get("unlock_level", -1))
				keys[i] = [lv if lv >= 0 else 1 << 30, nm, i]
			_:
				var gi := ShoppingList.GROUPS.find(str(r.get("group", ShoppingList.GROUP_OTHER)))
				keys[i] = [gi if gi >= 0 else ShoppingList.GROUPS.size(), 0 if r.get("kind", "item") == ShoppingList.KIND_ITEM else 1, nm, i]
	keys.sort()
	var out: Array = []
	out.resize(rows.size())
	for i in keys.size():
		var k: Array = keys[i]
		out[i] = rows[int(k[k.size() - 1])]
	return out


static func _cost_sort_key(c: Variant) -> Array:
	if not c is Dictionary or Currency.is_zero(c):
		return [1 << 20, 0]
	var ids := Currency.sorted_ids((c as Dictionary).keys())
	return [Currency.sort_index(ids[0]), -int(c[ids[0]])]


static func shop_entries(rows: Array, sort_key: String) -> Array:
	## Flat list for the (paged) list view: grouped with a header per group when
	## sorting by group ({type: "group", group, total, unknown_copies, count,
	## missing, text}), else rows only ({type: "row", row}).
	var out: Array = []
	var sorted := shop_sort(rows, sort_key)
	if sort_key != "group":
		for r in sorted:
			out.append({"type": "row", "row": r})
		return out
	for g: Dictionary in ShoppingList.group_rows(sorted):
		var missing := 0
		for r in g["rows"]:
			missing += int(r.get("missing", 0))
		out.append({"type": "group", "group": g["group"], "total": g["total"], "unknown_copies": g["unknown_copies"],
			"count": (g["rows"] as Array).size(), "missing": missing, "text": group_text(g)})
		for r in g["rows"]:
			out.append({"type": "row", "row": r})
	return out


static func group_text(g: Dictionary) -> String:
	## "4 items · 1,250 coins + 2 with unknown price"
	var parts: PackedStringArray = [plural((g.get("rows", []) as Array).size() if g.has("rows") else int(g.get("count", 0)), "item")]
	var total: Dictionary = g.get("total", {})
	var unknown := int(g.get("unknown_copies", 0))
	if not total.is_empty():
		parts.append(Currency.format_line(total))
	if unknown > 0:
		parts.append("%d with unknown price" % unknown)
	return " · ".join(parts)


static func row_counts_text(r: Dictionary) -> String:
	## "Used 5 · owned 1 · bought 1 · still needed 3" (owned "?" = not recorded).
	var owned := str(int(r.get("owned", 0))) if bool(r.get("owned_known", true)) else "?"
	return "Used %d · owned %s · bought %d · still needed %d" % [int(r.get("used", 0)), owned,
		int(r.get("acquired", 0)), int(r.get("missing", 0))]


static func row_price_text(r: Dictionary) -> String:
	## Price of the next copy, or the range when prices rise per copy; the
	## how-to-get text for items that can't be bought; "Price unknown" otherwise.
	if str(r.get("kind", "item")) == ShoppingList.KIND_SUPPLY:
		return "Expansion supply"
	if not bool(r.get("buyable", false)):
		return str(r.get("method_text", "Price unknown"))
	var lo: Variant = r.get("price_min")
	var hi: Variant = r.get("price_max")
	if int(r.get("charged", 0)) > 0:
		if lo == null and hi == null:
			return "Price unknown"
		if lo == null or hi == null:
			return "%s, later copies: price unknown" % Currency.format_line(lo if lo != null else hi)
		if Currency.equal(lo, hi):
			return "%s each" % Currency.format_line(lo) if int(r.get("charged", 0)) > 1 else Currency.format_line(lo)
		return "%s (rises per copy)" % Currency.format_range(lo, hi)
	var nx: Variant = r.get("next_price")
	return "Next copy: %s" % Currency.format_line(nx)


static func row_total_text(r: Dictionary) -> String:
	## Known total of the row plus what is not in it.
	if int(r.get("charged", 0)) <= 0:
		return "Nothing to pay"
	var total: Dictionary = r.get("total", {})
	var unknown := int(r.get("unknown_copies", 0))
	var nb := int(r.get("not_buyable_copies", 0))
	var parts: PackedStringArray = []
	if not total.is_empty():
		parts.append(Currency.format_line(total))
	if unknown > 0:
		parts.append("%d with unknown price" % unknown)
	if nb > 0:
		parts.append("%d can't be bought" % nb)
	if parts.is_empty():
		return "Free"
	return " + ".join(parts)


static func row_badges(r: Dictionary, farm_level: int) -> Array:
	## [[text, tone]] for the compact row. tone: danger | warn | info | accent | faint.
	var out: Array = []
	var lvl := int(r.get("unlock_level", -1))
	if lvl > 0:
		out.append(["Level %d" % lvl, "danger" if farm_level > 0 and lvl > farm_level else "faint"])
	if row_cant_buy(r):
		out.append(["Can't buy", "warn"])
	elif row_price_unknown(r):
		out.append(["Price unknown", "danger"])
	if bool(r.get("over_max", false)):
		out.append(["Over limit %d/%d" % [int(r.get("count_total", 0)), int(r.get("max_count", 0))], "danger"])
	match str(r.get("availability", "unknown")):
		"seasonal": out.append(["Seasonal", "info"])
		"event": out.append(["Event", "info"])
		"retired": out.append(["Retired", "warn"])
	if str(r.get("origin", "")) == PriceBook.ORIGIN_USER:
		out.append(["Your price", "info"])
	else:
		var conf := confidence_badge(str(r.get("confidence", "unknown")))
		if not conf.is_empty() and not row_price_unknown(r) and not row_cant_buy(r):
			out.append(conf)
	return out


static func confidence_badge(conf: String) -> Array:
	match conf:
		"confirmed": return ["Verified", "accent"]
		"community": return ["Community data", "info"]
		"unverified": return ["Unverified", "warn"]
	return []


static func availability_text(av: String) -> String:
	match av:
		"current": return "Available now"
		"seasonal": return "Seasonal"
		"event": return "Event only"
		"retired": return "Retired (no longer sold)"
	return "Availability unknown"


static func origin_text(origin: String) -> String:
	match origin:
		PriceBook.ORIGIN_CATALOGUE: return "Item catalogue"
		PriceBook.ORIGIN_PRICE_DB: return "Researched price file"
		PriceBook.ORIGIN_USER: return "Your override"
	return "No price information"


static func totals_text(t: Dictionary) -> String:
	## One sentence (or a few short ones) about a BudgetEngine.Totals.to_dict():
	## "Known cost: 150,000 coins and 90 diamonds. 12 items have unknown prices."
	var out: PackedStringArray = []
	var cost: Dictionary = t.get("cost", {})
	if int(t.get("charged_objects", 0)) == 0 and cost.is_empty() and (t.get("plots", []) as Array).is_empty():
		out.append("Nothing left to pay for.")
	else:
		out.append("Known cost: %s." % (cost_words(cost) if not cost.is_empty() else "nothing yet"))
	var unk := int(t.get("unknown_price_objects", 0))
	if unk > 0:
		out.append("%s %s unknown price%s." % [plural(unk, "item"), "has an" if unk == 1 else "have", "" if unk == 1 else "s"])
	var nb := int(t.get("not_buyable_objects", 0))
	if nb > 0:
		out.append("%s can't be bought (rewards / not sold)." % plural(nb, "item"))
	var uo := (t.get("unknown_ownership_types", []) as Array).size()
	if uo > 0:
		out.append("%s without a recorded inventory %s counted as to buy." % [plural(uo, "item type"), "is" if uo == 1 else "are"])
	var up := (t.get("unknown_cost_plots", []) as Array).size()
	if up > 0:
		out.append("Supplies for %s are unknown." % plural(up, "plot"))
	return " ".join(out)


static func supply_text(r: Dictionary) -> String:
	## "Land deeds: need 6, have 1 → 5 more" (supply rows).
	if str(r.get("item", "")).is_empty():
		return "Expansion supplies for %s are unknown" % plural((r.get("unknown_plots", []) as Array).size(), "plot")
	var have := str(int(r.get("have", 0))) if bool(r.get("have_known", false)) else "?"
	var txt := "%s: need %s, have %s" % [str(r.get("name", "")), Currency.format_amount(int(r.get("needed", 0))), have]
	if int(r.get("missing", 0)) > 0:
		txt += " → %s more" % Currency.format_amount(int(r.get("missing", 0)))
	return txt


static func shop_csv(rows: Array, supplies: Array = []) -> String:
	## Spreadsheet export of the shopping list (prices as text, unknown stays "unknown").
	var cols := ["group", "item_id", "name", "used", "owned", "bought", "still_needed", "next_price", "price_range",
		"known_total", "unknown_price_copies", "cant_buy_copies", "how_to_get", "unlock_level", "availability",
		"confidence", "price_origin"]
	var lines: PackedStringArray = [",".join(PackedStringArray(cols))]
	for r: Dictionary in rows:
		if str(r.get("kind", "item")) != ShoppingList.KIND_ITEM:
			continue
		var owned := str(int(r.get("owned", 0))) if bool(r.get("owned_known", true)) else "unknown"
		var cells: Array = [str(r.get("group", "")), str(r.get("item", "")), str(r.get("name", "")), str(int(r.get("used", 0))),
			owned, str(int(r.get("acquired", 0))), str(int(r.get("missing", 0))),
			Currency.format_line(r.get("next_price"), "free", "unknown"),
			Currency.format_range(r.get("price_min"), r.get("price_max")) if (r.get("price_min") != null and r.get("price_max") != null) else "",
			Currency.format_line(r.get("total", {}), "", "unknown"), str(int(r.get("unknown_copies", 0))),
			str(int(r.get("not_buyable_copies", 0))), str(r.get("method_text", "")),
			str(int(r.get("unlock_level", -1))) if int(r.get("unlock_level", -1)) >= 0 else "unknown",
			str(r.get("availability", "unknown")), str(r.get("confidence", "unknown")), str(r.get("origin", ""))]
		var out: PackedStringArray = []
		for c in cells:
			out.append(csv_field(str(c)))
		lines.append(",".join(out))
	for s: Dictionary in supplies:
		var have := str(int(s.get("have", 0))) if bool(s.get("have_known", false)) else "unknown"
		var cells2: Array = [ShoppingList.GROUP_SUPPLIES, str(s.get("item", "")), str(s.get("name", "")), str(int(s.get("needed", 0))),
			have, "", str(int(s.get("missing", 0))), "", "", "", str(int(s.get("unknown_copies", 0))), "", "expansion supply", "", "", "", "map"]
		var out2: PackedStringArray = []
		for c in cells2:
			out2.append(csv_field(str(c)))
		lines.append(",".join(out2))
	return "\n".join(lines) + "\n"


# --- construction checklist (Build tab) ----------------------------------------------------

const ST_NOT_ACQUIRED := "not_acquired"
const ST_ACQUIRED := "acquired"     ## acquired / owned, not placed yet
const ST_PLACED := "placed"
const STATE_NAMES := {ST_NOT_ACQUIRED: "Not acquired", ST_ACQUIRED: "Acquired, not placed", ST_PLACED: "Placed in Hay Day"}
const PHASE_STATUS_NAMES := {
	BudgetEngine.PHASE_NOT_STARTED: "Not started", BudgetEngine.PHASE_IN_PROGRESS: "In progress",
	BudgetEngine.PHASE_READY: "Ready to build", BudgetEngine.PHASE_COMPLETED: "Completed",
}


static func placed_uids(layout: FarmLayout, plan: Dictionary, db: ItemDatabase = null) -> Dictionary:
	## uid -> true for objects counted as placed in Hay Day: marked in
	## plan.placed, or a baseline object (same uid and item) still at its
	## baseline origin. Same rule as BudgetEngine (is_placed()).
	var out := {}
	var placed: Dictionary = plan.get("placed", {}) if plan.get("placed") is Dictionary else {}
	var bl: Variant = plan.get("baseline")
	var base: Dictionary = (bl as Dictionary).get("objects", {}) if (bl is Dictionary and (bl as Dictionary).get("objects") is Dictionary) else {}
	for o: PlacedObject in layout.objects.values():
		if placed.has(str(o.uid)):
			out[o.uid] = true
			continue
		var e: Variant = base.get(str(o.uid))
		if e is Array and (e as Array).size() >= 3:
			var bid := str(e[0])
			var same := bid == o.item_id or (db != null and db.resolve_id(bid) == db.resolve_id(o.item_id))
			if same and int(e[1]) == o.origin.x and int(e[2]) == o.origin.y:
				out[o.uid] = true
	return out


static func object_states(engine: BudgetEngine, layout: FarmLayout, db: ItemDatabase, plan: Dictionary) -> Dictionary:
	## uid -> ST_* for every object. Ownership comes from the engine's
	## allocation (owned and acquired copies cover objects in allocation order),
	## two engine queries per item type, never per object.
	var out := {}
	var items := {}
	for o: PlacedObject in layout.objects.values():
		items[db.resolve_id(o.item_id) if db != null else o.item_id] = true
	for id: String in items:
		var st := engine.item_state(id)
		var covered := int(st["owned"]) + int(st["acquired"])
		var order := engine.alloc_order(id)
		for j in order.size():
			out[int(order[j])] = ST_ACQUIRED if j < covered else ST_NOT_ACQUIRED
	var placed := placed_uids(layout, plan, db)
	for u in placed:
		out[u] = ST_PLACED
	return out


static func moved_since_placed(layout: FarmLayout, plan: Dictionary) -> Array:
	## Sorted uids marked placed whose current origin differs from the origin
	## remembered when they were marked.
	var out: Array = []
	var placed: Dictionary = plan.get("placed", {}) if plan.get("placed") is Dictionary else {}
	for k in placed:
		var o: PlacedObject = layout.objects.get(int(k))
		var p: Variant = placed[k]
		if o == null or not p is Array or (p as Array).size() != 2:
			continue
		if int(p[0]) != o.origin.x or int(p[1]) != o.origin.y:
			out.append(o.uid)
	out.sort()
	return out


static func _counts() -> Dictionary:
	return {"total": 0, ST_NOT_ACQUIRED: 0, ST_ACQUIRED: 0, ST_PLACED: 0, "uids": [], "open_uids": []}


static func _count_into(acc: Dictionary, uid: int, state: String) -> void:
	acc["total"] += 1
	acc[state] += 1
	(acc["uids"] as Array).append(uid)
	if state != ST_PLACED:
		(acc["open_uids"] as Array).append(uid)


static func checklist(engine: BudgetEngine, layout: FarmLayout, db: ItemDatabase, plan: Dictionary) -> Dictionary:
	## Construction checklist: {phases: [{phase, name, color, status, status_text,
	## marked_done, total, not_acquired, acquired, placed, percent, uids,
	## open_uids, groups: [{group, total, not_acquired, acquired, placed, percent,
	## uids, open_uids}]}] (build order, Unphased last, empty phases left out
	## except named ones), overall: {total, not_acquired, acquired, placed, percent},
	## moved: uids marked placed that were moved since, skipped: editor markers}.
	## Editor planning markers (category "planning") are not game objects and are left out.
	var states := object_states(engine, layout, db, plan)
	var phases: Array = []
	var overall := _counts()
	var skipped := 0
	for pid in engine.phase_ids(true):
		var ph := PlanDoc.phase(plan, pid)
		var acc := _counts()
		var groups := {}
		for u in engine.phase_uids(pid):
			var o: PlacedObject = layout.objects.get(int(u))
			if o == null:
				continue
			var it: ItemDef = db.get_item(o.item_id) if db != null else null
			if it != null and it.category in RecreationGuide.SKIP_CATEGORIES:
				skipped += 1
				continue
			var g := ShoppingList.group_of_category(it.category) if it != null else ShoppingList.GROUP_OTHER
			var st: String = states.get(int(u), ST_NOT_ACQUIRED)
			if not groups.has(g):
				groups[g] = _counts()
			_count_into(groups[g], int(u), st)
			_count_into(acc, int(u), st)
			_count_into(overall, int(u), st)
		if acc["total"] == 0 and pid == BudgetEngine.UNPHASED:
			continue
		var glist: Array = []
		for g in ShoppingList.GROUPS + (groups.keys().filter(func(k): return not k in ShoppingList.GROUPS)):
			if not groups.has(g):
				continue
			var gc: Dictionary = groups[g]
			gc["group"] = g
			gc["percent"] = percent(int(gc[ST_PLACED]), int(gc["total"]))
			glist.append(gc)
		var status := engine.phase_status(pid) if pid != BudgetEngine.UNPHASED else _unphased_status(acc)
		acc["phase"] = pid
		acc["name"] = "Unphased" if pid == BudgetEngine.UNPHASED else str(ph.get("name", pid))
		acc["color"] = str(ph.get("color", "")) if pid != BudgetEngine.UNPHASED else ""
		acc["status"] = status
		acc["status_text"] = str(PHASE_STATUS_NAMES.get(status, status))
		acc["marked_done"] = bool(ph.get("done", false))
		acc["percent"] = percent(int(acc[ST_PLACED]), int(acc["total"]))
		acc["groups"] = glist
		phases.append(acc)
	overall["percent"] = percent(int(overall[ST_PLACED]), int(overall["total"]))
	return {"phases": phases, "overall": overall, "moved": moved_since_placed(layout, plan), "skipped": skipped}


static func _unphased_status(acc: Dictionary) -> String:
	if int(acc["total"]) > 0 and int(acc[ST_PLACED]) == int(acc["total"]):
		return BudgetEngine.PHASE_COMPLETED
	if int(acc[ST_NOT_ACQUIRED]) == 0 and int(acc["total"]) > 0:
		return BudgetEngine.PHASE_READY
	if int(acc[ST_PLACED]) > 0:
		return BudgetEngine.PHASE_IN_PROGRESS
	return BudgetEngine.PHASE_NOT_STARTED


static func counts_text(c: Dictionary) -> String:
	## "3 not acquired · 2 to place · 10 placed"
	var parts: PackedStringArray = []
	if int(c.get(ST_NOT_ACQUIRED, 0)) > 0:
		parts.append("%d not acquired" % int(c[ST_NOT_ACQUIRED]))
	if int(c.get(ST_ACQUIRED, 0)) > 0:
		parts.append("%d to place" % int(c[ST_ACQUIRED]))
	parts.append("%d of %d placed" % [int(c.get(ST_PLACED, 0)), int(c.get("total", 0))])
	return " · ".join(parts)


static func filter_unfinished(cl: Dictionary) -> Dictionary:
	## The checklist without fully placed phases and groups (Build tab filter).
	var out := cl.duplicate()
	var phases: Array = []
	for p: Dictionary in cl.get("phases", []):
		if int(p.get("total", 0)) > 0 and int(p.get(ST_PLACED, 0)) >= int(p.get("total", 0)):
			continue
		var q := p.duplicate()
		q["groups"] = (p.get("groups", []) as Array).filter(func(g: Dictionary) -> bool: return int(g[ST_PLACED]) < int(g["total"]))
		phases.append(q)
	out["phases"] = phases
	return out


# --- recreation guide (Guide tab) -----------------------------------------------------------

## Step kinds ticked by hand (plan.steps_done): nothing to mark placed.
const MANUAL_STEP_KINDS := ["unlock", "clear", "store", "store_temp"]


static func step_is_manual(step: Dictionary) -> bool:
	return str(step.get("kind", "")) in MANUAL_STEP_KINDS or (step.get("uids", []) as Array).is_empty()


static func plan_with_step(plan: Dictionary, layout: FarmLayout, step: Dictionary, done: bool) -> Dictionary:
	## New plan with a guide step done / not done: manual steps via
	## plan.steps_done, the others by marking their objects placed. Undoing also
	## clears a hand tick.
	var id := str(step.get("id", ""))
	if step_is_manual(step):
		return PlanDoc.with_step_done(plan, id, done)
	var p := PlanDoc.with_placed(plan, layout, step.get("uids", []), done)
	if not done:
		p = PlanDoc.with_step_done(p, id, false)
	return p


static func guide_entries(guide: Dictionary, unfinished_only: bool = false) -> Array:
	## Flat list for the step list: a header per phase (progress.phases order:
	## build order, Unphased last) then its steps. {type: "phase", phase, name,
	## total, completed, percent} / {type: "step", index, step}.
	var steps: Array = guide.get("steps", [])
	var by_phase := {}
	for i in steps.size():
		var s: Dictionary = steps[i]
		if unfinished_only and bool(s.get("done", false)):
			continue
		var ph := str(s.get("phase", ""))
		if not by_phase.has(ph):
			by_phase[ph] = []
		by_phase[ph].append(i)
	var out: Array = []
	var prog: Dictionary = guide.get("progress", {})
	for pp: Dictionary in prog.get("phases", []):
		var ph := str(pp.get("phase", ""))
		if not by_phase.has(ph):
			continue
		out.append({"type": "phase", "phase": ph, "name": str(pp.get("name", ph)), "total": int(pp.get("total", 0)),
			"completed": int(pp.get("completed", 0)), "percent": float(pp.get("percent", 0.0))})
		for i in by_phase[ph]:
			out.append({"type": "step", "index": i, "step": steps[i]})
	return out


static func progress_text(progress: Dictionary) -> String:
	## "Step 5 of 40 · 4 done (10%) · then step 6" / "All 40 steps done".
	var total := int(progress.get("total", 0))
	if total == 0:
		return "No steps: the design has nothing to build."
	var done := int(progress.get("completed", 0))
	if done >= total:
		return "All %s done." % plural(total, "step")
	var parts: PackedStringArray = []
	if int(progress.get("current_number", -1)) > 0:
		parts.append("Now: step %d of %d" % [int(progress["current_number"]), total])
	parts.append("%d done (%s)" % [done, pct_text(float(progress.get("percent", 0.0)))])
	parts.append("%d to go" % int(progress.get("remaining", total - done)))
	if int(progress.get("next_number", -1)) > 0:
		parts.append("then step %d" % int(progress["next_number"]))
	return " · ".join(parts)


static func step_meta_text(step: Dictionary) -> String:
	## "Stage 4 · Large buildings · 3 objects · Phase First"
	var parts: PackedStringArray = ["Stage %d · %s" % [int(step.get("stage", 0)), str(step.get("stage_name", ""))]]
	var n := (step.get("uids", []) as Array).size()
	if n > 0 and str(step.get("kind", "")) != "unlock":
		parts.append(plural(n, "object"))
	parts.append("Phase: %s" % str(step.get("phase_name", "Unphased")))
	return " · ".join(parts)


static func step_list_text(step: Dictionary) -> String:
	return "%d. %s" % [int(step.get("number", 0)), str(step.get("title", ""))]


static func step_where_text(step: Dictionary) -> String:
	## Tile text, "to … (from …)" for moves.
	var tiles := str(step.get("tiles_text", ""))
	if not str(step.get("from_tiles_text", "")).is_empty():
		tiles = "to %s (from %s)" % [tiles, str(step["from_tiles_text"])]
	return tiles


static func guide_image_names(stem: String, phase_ids: Array) -> Dictionary:
	## Relative PNG file names written next to an exported HTML guide:
	## {overview: "<stem>_overview.png", phases: {phase id: "<stem>_phase_<n>.png"}}.
	var s := safe_file_stem(stem, "guide")
	var phases := {}
	var n := 0
	for pid in phase_ids:
		n += 1
		phases[str(pid)] = "%s_phase_%d.png" % [s, n]
	return {"overview": "%s_overview.png" % s, "phases": phases}


# --- accuracy report ---------------------------------------------------------------------

const STATUS_TONES := {"ok": "accent", "info": "info", "warn": "warn", "unknown": "danger"}
const STATUS_WORDS := {"ok": "OK", "info": "Info", "warn": "Check", "unknown": "Unknown"}


static func calibration_rows(report: Dictionary) -> Array:
	## [{name, verdict, verdict_text, tone, text}] one per reference image.
	var out: Array = []
	for c: Dictionary in report.get("calibration", []):
		var v := str(c.get("verdict", "none"))
		var tone := "faint"
		match v:
			"good": tone = "accent"
			"fair": tone = "warn"
			"poor", "invalid": tone = "danger"
			"unverified", "legacy": tone = "info"
		var nm := str(c.get("name", ""))
		out.append({"name": nm if not nm.is_empty() else "Screenshot %s" % str(c.get("id", "")), "verdict": v,
			"verdict_text": str(c.get("verdict_text", "")), "tone": tone, "text": str(c.get("text", "")),
			"applied": bool(c.get("applied", false))})
	return out


# --- inventory dialog -------------------------------------------------------------------

const INV_FILTERS := ["used", "not_recorded", "recorded", "all"]
const INV_FILTER_NAMES := {"used": "Used in this design", "not_recorded": "Used, not recorded", "recorded": "Recorded",
	"all": "Whole catalogue"}


static func design_counts(layout: FarmLayout, db: ItemDatabase = null, include_planned: bool = false) -> Dictionary:
	## item -> objects of it in the design (catalogue ids; editor markers left out).
	var out := {}
	for o: PlacedObject in layout.objects.values():
		if o.planned and not include_planned:
			continue
		var id := db.resolve_id(o.item_id) if db != null else o.item_id
		var it: ItemDef = db.get_item(id) if db != null else null
		if it != null and it.category in RecreationGuide.SKIP_CATEGORIES:
			continue
		out[id] = int(out.get(id, 0)) + 1
	return out


static func baseline_counts(plan: Dictionary, db: ItemDatabase = null) -> Dictionary:
	## item -> copies standing on the real farm (plan.baseline), {} without one.
	var out := {}
	var bl: Variant = plan.get("baseline")
	if not Baseline.is_valid(bl):
		return out
	for u in Baseline.entries(bl, db).values():
		var id := str(u["item"])
		out[id] = int(out.get(id, 0)) + 1
	return out


static func inventory_rows(db: ItemDatabase, profile: Dictionary, used: Dictionary, filter: String = "used", query: String = "") -> Array:
	## Rows {item, name, category, used, owned (-1 = not recorded), purchased (-1)}
	## for the inventory dialog, sorted used-first then by name.
	var owned: Dictionary = profile.get("owned", {}) if profile.get("owned") is Dictionary else {}
	var purch: Dictionary = profile.get("purchased", {}) if profile.get("purchased") is Dictionary else {}
	var ids := {}
	match filter:
		"used", "not_recorded":
			for k in used:
				ids[str(k)] = true
		"recorded":
			for k in owned:
				ids[str(k)] = true
			for k in purch:
				ids[str(k)] = true
		_:
			if db != null:
				for it: ItemDef in db.ordered:
					ids[it.id] = true
			for k in owned:
				ids[str(k)] = true
	var tokens := query.strip_edges().to_lower().split(" ", false)
	var out: Array = []
	for id: String in ids:
		var it: ItemDef = db.get_item(id) if db != null else null
		if it != null and it.category in RecreationGuide.SKIP_CATEGORIES:
			continue
		var has_owned := owned.has(id) and (owned[id] is int or owned[id] is float)
		if filter == "not_recorded" and has_owned:
			continue
		var nm := it.name if it != null else id
		if not tokens.is_empty():
			var hay := (nm + " " + id.replace("_", " ")).to_lower()
			var ok := true
			for t in tokens:
				if hay.find(t) < 0:
					ok = false
					break
			if not ok:
				continue
		out.append({"item": id, "name": nm, "category": it.category if it != null else "", "used": int(used.get(id, 0)),
			"owned": int(owned[id]) if has_owned else -1,
			"purchased": int(purch[id]) if (purch.has(id) and (purch[id] is int or purch[id] is float)) else -1,
			"known": it != null})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ua := int(a["used"]) > 0
		var ub := int(b["used"]) > 0
		if ua != ub:
			return ua
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out


static func set_count(profile: Dictionary, key: String, item: String, value: int) -> void:
	## In place on a working copy: profile[key][item] = value (-1 removes it:
	## "not recorded", which is NOT the same as 0).
	var d: Dictionary = profile.get(key, {}) if profile.get(key) is Dictionary else {}
	if value < 0:
		d.erase(item)
	else:
		d[item] = value
	profile[key] = d


static func fill_owned(profile: Dictionary, counts: Dictionary, raise_only: bool) -> int:
	## In place: owned[item] = counts[item] (raise_only: never lower a recorded
	## count; baseline copies are a lower bound). Returns the entries changed.
	var owned: Dictionary = profile.get("owned", {}) if profile.get("owned") is Dictionary else {}
	var n := 0
	for id in counts:
		var c := int(counts[id])
		var has := owned.has(id) and (owned[id] is int or owned[id] is float)
		var v := maxi(c, int(owned[id])) if (raise_only and has) else c
		if not has or int(owned[id]) != v:
			owned[id] = v
			n += 1
	profile["owned"] = owned
	return n


static func parse_count(text: String) -> int:
	## Whole number >= 0 from a field; -1 = empty (not recorded); -2 = invalid.
	var s := text.strip_edges().replace(",", "").replace(" ", "")
	if s.is_empty():
		return -1
	if s.is_valid_int() and s.to_int() >= 0:
		return s.to_int()
	return -2


static func import_report_lines(rep: Dictionary) -> Array:
	## Plain lines about an InventoryIO import report.
	var out: Array = []
	if not bool(rep.get("ok", true)):
		out.append("Nothing imported.")
	else:
		out.append("Read %d owned, %d purchased and %d balance entries." % [int(rep.get("owned", 0)), int(rep.get("purchased", 0)), int(rep.get("balances", 0))])
	var unknown: Array = rep.get("unknown", [])
	if not unknown.is_empty():
		out.append("Not recognised (%d): %s" % [unknown.size(), _list(unknown)])
	var amb: Array = rep.get("ambiguous", [])
	if not amb.is_empty():
		var parts: PackedStringArray = []
		for a: Dictionary in amb:
			parts.append("“%s” (%s)" % [str(a.get("name", "")), ", ".join(PackedStringArray(a.get("items", [])))])
		out.append("Ambiguous names, skipped (%d): %s" % [amb.size(), _list(Array(parts))])
	var bn: Array = rep.get("by_name", [])
	if not bn.is_empty():
		out.append("Matched by name: %d" % bn.size())
	var al: Array = rep.get("aliases", [])
	if not al.is_empty():
		out.append("Old item ids renamed: %d" % al.size())
	for e in rep.get("errors", []):
		out.append("Problem: %s" % str(e))
	return out


static func _list(a: Array, max_n: int = 8) -> String:
	var parts: PackedStringArray = []
	for i in mini(a.size(), max_n):
		parts.append(str(a[i]))
	var t := ", ".join(parts)
	if a.size() > max_n:
		t += " +%d more" % (a.size() - max_n)
	return t


# --- price dialog --------------------------------------------------------------------------

## Currencies offered in the override form (others stay readable, shown by id).
const FORM_CURRENCIES := ["coins", "diamonds", "voucher_green", "voucher_blue", "voucher_purple", "voucher_gold", "film", "golden_keys"]
const STEP_CURRENCIES := ["coins", "diamonds"]
const FORM_METHODS := ["shop", "vouchers", "event_currency", "free", "reward", "not_in_shop", "unknown"]


static func copy_price_of(rec: Dictionary, k: int) -> Variant:
	## Price of copy #k for a normalized record (PriceBook.normalize_record /
	## resolved shape): same rule as PriceBook.copy_price. null = unknown.
	var m := str(rec.get("method", PriceBook.METHOD_UNKNOWN))
	if not m in PriceBook.COST_METHODS or k < 1:
		return null
	if m == PriceBook.METHOD_FREE:
		return {}
	var sch: Variant = rec.get("schedule")
	if sch is Array:
		var a: Array = sch
		if k <= a.size():
			return a[k - 1]
		if bool(rec.get("schedule_repeats_last", false)) and not a.is_empty():
			return a[a.size() - 1]
		return null
	var p: Variant = rec.get("price")
	if not p is Dictionary:
		return null
	var st: Variant = rec.get("step")
	if not st is Dictionary or k == 1:
		return p
	var out: Dictionary = (p as Dictionary).duplicate()
	Currency.add_into(out, st, k - 1)
	return out


static func preview_copies(rec: Dictionary, n: int = 10, first_k: int = 1) -> Array:
	## [{copy, cost (Cost|null), text}] for copies first_k .. first_k + n - 1.
	var out: Array = []
	for i in n:
		var k := first_k + i
		var c: Variant = copy_price_of(rec, k)
		out.append({"copy": k, "cost": c, "text": Currency.format_line(c)})
	return out


static func base_record(pb: PriceBook, item: String) -> Dictionary:
	## The record below the user's layer (price file, else catalogue, else empty).
	var r := pb.layer(item, PriceBook.ORIGIN_PRICE_DB)
	if r.is_empty():
		r = pb.layer(item, PriceBook.ORIGIN_CATALOGUE)
	return r if not r.is_empty() else PriceBook.empty_record()


static func resolve_with_override(base: Dictionary, ov: Dictionary) -> Dictionary:
	## What PriceBook.resolved() would give with `ov` as the user's override on
	## top of `base` (same layering rule: setting any of price / step / schedule
	## replaces all of them). Used for the live preview before saving.
	var rec := base.duplicate(true) if not base.is_empty() else PriceBook.empty_record()
	if not ov.is_empty():
		var n := PriceBook.normalize_record(ov, PriceBook.ORIGIN_USER)
		var sets_price := false
		for k in PriceBook.PRICE_KEYS:
			if ov.has(k):
				sets_price = true
		for k in n:
			if ov.has(k) or (sets_price and k in PriceBook.PRICE_KEYS):
				rec[k] = n[k]
		if not ov.has("method") and sets_price and rec["method"] in [PriceBook.METHOD_UNKNOWN, PriceBook.METHOD_REWARD, PriceBook.METHOD_NOT_IN_SHOP] and n["price"] != null:
			rec["method"] = PriceBook.METHOD_SHOP
		rec["origin"] = PriceBook.ORIGIN_USER
	rec["progressive"] = rec.get("schedule") != null or (rec.get("step") != null and not Currency.is_zero(rec["step"]))
	return rec


static func override_record(form: Dictionary) -> Dictionary:
	## The user's override record from the price dialog form, or an error.
	## form: {method, price: {cur: int}, step: {cur: int}, notes, source,
	## confidence, availability}. Empty price = keep the researched price (no
	## price keys in the override). Returns {record, error}.
	var rec := {}
	var m := str(form.get("method", ""))
	if not m.is_empty():
		rec["method"] = m
	var price: Dictionary = form.get("price", {})
	var step: Dictionary = form.get("step", {})
	if not step.is_empty() and price.is_empty() and m in [PriceBook.METHOD_SHOP, PriceBook.METHOD_VOUCHERS, PriceBook.METHOD_EVENT]:
		return {"record": {}, "error": "Enter the price of the first copy too (a step alone replaces the researched price with an unknown one)."}
	if m in [PriceBook.METHOD_SHOP, PriceBook.METHOD_VOUCHERS, PriceBook.METHOD_EVENT] and not price.is_empty():
		rec["price"] = price.duplicate()
		if not step.is_empty():
			rec["step"] = step.duplicate()
			rec["step_basis"] = "copies_owned"
	var conf := str(form.get("confidence", ""))
	if conf in PriceBook.CONFIDENCE:
		rec["confidence"] = conf
	var av := str(form.get("availability", ""))
	if av in PriceBook.AVAILABILITY and av != "unknown":
		rec["availability"] = av
	var notes := str(form.get("notes", "")).strip_edges()
	if not notes.is_empty():
		rec["notes"] = notes
	var src := str(form.get("source", "")).strip_edges()
	if not src.is_empty():
		rec["sources"] = [src]
	return {"record": rec, "error": ""}


static func record_lines(rec: Dictionary, pb: PriceBook = null) -> Array:
	## [[key, value]] describing a resolved (or layer) record for the dialog.
	var out: Array = []
	var m := str(rec.get("method", PriceBook.METHOD_UNKNOWN))
	out.append(["How to get", str(PriceBook.METHOD_NAMES.get(m, m))])
	if not (rec.get("routes", []) as Array).is_empty():
		var names: PackedStringArray = []
		for r in rec["routes"]:
			names.append(str(PriceBook.ROUTE_NAMES.get(r, r)))
		out.append(["Routes", ", ".join(names)])
	if m in PriceBook.COST_METHODS:
		if rec.get("schedule") is Array:
			var parts: PackedStringArray = []
			for c in rec["schedule"]:
				parts.append(Currency.format_line(c))
			out.append(["Price per copy", " → ".join(parts) + (" (last repeats)" if bool(rec.get("schedule_repeats_last", false)) else " (later copies unknown)")])
		else:
			out.append(["First copy", Currency.format_line(rec.get("price"))])
			if rec.get("step") is Dictionary and not Currency.is_zero(rec["step"]):
				out.append(["Each extra copy", "+ %s" % Currency.format_line(rec["step"])])
	if int(rec.get("max_count", -1)) > 0:
		out.append(["Purchase limit", str(int(rec["max_count"]))])
	out.append(["Availability", availability_text(str(rec.get("availability", "unknown")))])
	out.append(["Confidence", str(rec.get("confidence", "unknown")).capitalize()])
	var srcs: PackedStringArray = []
	for s in rec.get("sources", []):
		var sid := str(s)
		var info: Dictionary = pb.sources.get(sid, {}) if pb != null else {}
		srcs.append(str(info.get("url", sid)) if not str(info.get("url", "")).is_empty() else sid)
	if not srcs.is_empty():
		out.append(["Sources", ", ".join(srcs)])
	if not str(rec.get("notes", "")).is_empty():
		out.append(["Notes", str(rec["notes"])])
	if not str(rec.get("info", "")).is_empty():
		out.append(["Info", str(rec["info"])])
	return out


# --- baseline dialog -----------------------------------------------------------------------

static func baseline_lines(diff: Dictionary) -> Array:
	## Plain lines about Baseline.diff().
	var t: Dictionary = diff.get("totals", {})
	var out: Array = []
	out.append("%d unchanged · %d moved · %d new · %d removed" % [int(t.get("unchanged", 0)), int(t.get("moved", 0)),
		int(t.get("new", 0)), int(t.get("removed", 0))])
	if int(t.get("reused", 0)) > 0:
		out.append("Reused from removed copies (storage, not a purchase): %d" % int(t["reused"]))
	if int(t.get("extra_needed", 0)) > 0:
		out.append("New copies from storage, your inventory or the shop: %d" % int(t["extra_needed"]))
	if int(t.get("freed", 0)) > 0:
		out.append("Removed objects that go to storage: %d" % int(t["freed"]))
	return out
