extends TestCase
## ShoppingList rows, groups, filters, acquisition progress and applying
## acquired copies to the inventory.

const Fx := preload("res://tests/unit/test_budget.gd")
const REMAINING := BudgetEngine.MODE_REMAINING
const TO_BUY := BudgetEngine.MODE_TO_BUY

var db: ItemDatabase
var pb: PriceBook
var layout: FarmLayout
var eng: BudgetEngine


func before_each() -> void:
	db = Fx.make_db()
	pb = Fx.make_prices(db)
	layout = FarmLayout.new()
	eng = BudgetEngine.new(layout, db, pb, fixture_map())


func after_each() -> void:
	eng.dispose()


func _place(id: String, at: Vector2i) -> int:
	return layout.add_objects([make_obj(db.get_item(id), at)])[0]


func _row(rows: Array, item: String) -> Dictionary:
	for r in rows:
		if r["item"] == item:
			return r
	return {}


func _setup() -> void:
	var p := layout.profile.duplicate(true)
	p["owned"] = {"t_long": 1, "t_fence": 0, "t_prize": 0, "t_bakery": 0, "t_voucher": 0}
	p["balances"] = {"land_deed": 1, "coins": 100}
	layout.profile = p
	for x in 4:
		_place("t_long", Vector2i(x, 0))
	for x in 5:
		_place("t_fence", Vector2i(x, 5))
	_place("t_prize", Vector2i(0, 8))
	_place("t_bakery", Vector2i(13, 2))   # on locked plot_a (3 land deeds)
	_place("t_voucher", Vector2i(6, 8))
	_place("t_lamp", Vector2i(8, 8))       # no owned entry: unknown ownership
	layout.set_planning(PlanDoc.with_acquired(layout.planning, "t_long", 1))


func test_rows_counts_prices_and_groups() -> void:
	_setup()
	var rows := ShoppingList.build(eng, null, REMAINING)
	var long := _row(rows, "t_long")
	assert_eq(long["group"], "Decorations")
	assert_eq(long["used"], 4)
	assert_eq(long["owned"], 1)
	assert_eq(long["acquired"], 1)
	assert_eq(long["missing"], 2)
	assert_true(long["progressive"])
	# owned 1 -> purchases #2 (acquired), #3, #4 (remaining)
	assert_eq(long["next_price"], {"coins": 20})
	assert_eq(long["price_min"], {"coins": 20})
	assert_eq(long["price_max"], {"coins": 25})
	assert_eq(long["total"], {"coins": 45})
	var fence := _row(rows, "t_fence")
	assert_eq(fence["group"], "Fences")
	assert_eq(fence["total"], {"coins": 21})
	assert_eq(fence["unknown_copies"], 2, "schedule ends after 3 copies")
	assert_null(fence["price_max"])
	var prize := _row(rows, "t_prize")
	assert_false(prize["buyable"])
	assert_eq(prize["method_text"], "Can't be bought: derby reward")
	assert_eq(prize["not_buyable_copies"], 1)
	assert_eq(_row(rows, "t_bakery")["group"], "Production machines")
	assert_eq(_row(rows, "t_bakery")["unlock_level"], 2)
	assert_eq(_row(rows, "t_bakery")["verified"], true)
	assert_eq(_row(rows, "t_voucher")["group"], "Trees")
	assert_eq(_row(rows, "t_voucher")["currencies"], ["voucher_green", "voucher_purple"])
	assert_false(_row(rows, "t_lamp")["owned_known"])
	var deed := _row(rows, "land_deed")
	assert_eq(deed["kind"], ShoppingList.KIND_SUPPLY)
	assert_eq(deed["group"], "Expansion supplies")
	assert_eq(deed["needed"], 3)
	assert_eq(deed["have"], 1)
	assert_eq(deed["missing"], 2)
	assert_eq(deed["plots"], ["plot_a"])
	# Rows add up to the engine total.
	var sum := ShoppingList.totals_of(rows)
	assert_true(Currency.equal(sum["cost"], eng.totals(null, REMAINING).cost), "%s vs %s" % [str(sum["cost"]), str(eng.totals(null, REMAINING).cost)])
	var groups := ShoppingList.group_rows(rows)
	var names: Array = groups.map(func(g: Dictionary) -> String: return g["group"])
	assert_eq(names, ["Decorations", "Fences", "Trees", "Production machines", "Expansion supplies"])
	assert_eq(ShoppingList.plot_rows(eng)[0]["cost"], {"land_deed": 3})


func test_scoped_rows() -> void:
	_setup()
	var uids: Array = []
	for u in layout.objects:
		if layout.objects[u].item_id == "t_long" and layout.objects[u].origin.x >= 2:
			uids.append(u)
	var rows := ShoppingList.build(eng, uids, REMAINING)
	assert_eq(rows.size(), 1, "no land in this scope")
	assert_eq(rows[0]["used"], 2)
	assert_eq(rows[0]["total"], {"coins": 45}, "the last two copies are the remaining purchases")


func test_filter_sort_search() -> void:
	_setup()
	var rows := ShoppingList.build(eng, null, REMAINING)
	assert_eq(ShoppingList.filter_rows(rows, {"group": "Fences"}).size(), 1)
	assert_eq(ShoppingList.filter_rows(rows, {"state": ShoppingList.STATE_UNKNOWN_PRICE}).map(func(r): return r["item"]), ["t_fence"])
	assert_eq(ShoppingList.filter_rows(rows, {"state": ShoppingList.STATE_NOT_BUYABLE}).size(), 1)
	assert_eq(ShoppingList.filter_rows(rows, {"currency": "voucher_purple"}).size(), 1)
	assert_eq(ShoppingList.filter_rows(rows, {"kind": "supply"}).size(), 1)
	assert_eq(ShoppingList.search_rows(rows, "WOOD fen").size(), 1)
	assert_eq(ShoppingList.search_rows(rows, "derby").size(), 1, "method text is searchable")
	var by_missing := ShoppingList.sort_rows(rows, "missing", true)
	assert_eq(by_missing[0]["item"], "t_fence")
	var by_name := ShoppingList.sort_rows(rows, "name")
	assert_eq(by_name[0]["name"], "Derby Trophy")


# --- fast build == slow reference ------------------------------------------------------------

static func ref_build(e: BudgetEngine, l: FarmLayout, uids: Variant, mode: String, include_land: bool) -> Array:
	## The first ShoppingList.build(): per-object breakdown, PriceBook lookups per
	## row, script-comparator sort. The fast build must give the same rows in
	## the same order (rows that tie on group and name may come in any order).
	var rows: Array = []
	var bd := Fx.ref_breakdown(e, l, uids, mode)
	var pb := e.prices
	for id: String in bd:
		var en: Dictionary = bd[id]
		var it: ItemDef = e.db.get_item(id) if e.db != null else null
		var st := e.item_state(id)
		var rec: Dictionary = pb.resolved(id) if pb != null else PriceBook.empty_record()
		var known_item := it != null
		var next: Variant = null
		var lo: Variant = null
		var hi: Variant = null
		if known_item and pb != null and int(en["charged"]) > 0:
			next = pb.copy_price(id, int(en["k_min"]))
			lo = next
			hi = pb.copy_price(id, int(en["k_max"]))
		elif known_item and pb != null:
			next = pb.copy_price(id, int(st["purchased"]) + maxi(0, int(st["count"]) - int(st["owned"])) + 1)
		var total: Dictionary = en["cost"]
		var mc := int(st["max_count"])
		var method_s: String = rec["method"] if known_item else PriceBook.METHOD_UNKNOWN
		rows.append({
			"kind": ShoppingList.KIND_ITEM, "item": id, "name": it.name if it != null else id,
			"category": it.category if it != null else "",
			"group": ShoppingList.group_of_category(it.category) if it != null else ShoppingList.GROUP_OTHER,
			"used": en["used"], "owned": en["owned"], "acquired": en["acquired"], "missing": en["to_buy"],
			"placed": en["placed"], "charged": en["charged"],
			"owned_total": st["owned"], "owned_known": st["owned_known"], "acquired_total": st["acquired"],
			"next_price": next, "price_min": lo, "price_max": hi, "progressive": bool(rec.get("progressive", false)),
			"total": total, "unknown_copies": en["unknown"], "not_buyable_copies": en["not_buyable"],
			"currencies": Currency.currencies_of(total if not total.is_empty() else next),
			"method": method_s, "method_text": pb.method_text(id) if (pb != null and known_item) else "Unknown item",
			"buyable": known_item and method_s in PriceBook.COST_METHODS,
			"routes": rec.get("routes", []), "unlock_level": it.unlock_level if it != null else -1,
			"availability": rec.get("availability", "unknown"), "confidence": rec.get("confidence", "unknown"),
			"verified": str(rec.get("confidence", "")) == "confirmed", "origin": rec.get("origin", PriceBook.ORIGIN_NONE),
			"max_count": mc, "count_total": st["count"], "over_max": mc > 0 and int(st["count"]) > mc,
			"sources": rec.get("sources", []), "notes": rec.get("notes", ""), "info": rec.get("info", ""),
		})
	if include_land:
		rows.append_array(ShoppingList.supply_rows(e, uids, mode))
	return ref_sort(rows, "group")


static func ref_sort(rows: Array, key: String, descending: bool = false) -> Array:
	var out := rows.duplicate()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var c := ShoppingList._compare(a, b, key)
		if c == 0:
			c = ShoppingList._compare(a, b, "name")
		return c > 0 if descending else c < 0)
	return out


static func same_rows(got: Array, want: Array, key: String = "group", descending: bool = false) -> String:
	## "" when `got` is `want`, or the same rows in an order the reference
	## comparator also accepts (only rows tying on key and name may swap).
	if got == want:
		return ""
	if got.size() != want.size():
		return "%d rows != %d" % [got.size(), want.size()]
	for i in range(1, got.size()):
		var c := ShoppingList._compare(got[i - 1], got[i], key)
		if c == 0:
			c = ShoppingList._compare(got[i - 1], got[i], "name")
		if (c < 0 if descending else c > 0):
			return "out of order at %d: %s / %s" % [i, got[i - 1]["item"], got[i]["item"]]
	var by := func(a: Dictionary, b: Dictionary) -> bool: return str(a["kind"]) + str(a["item"]) < str(b["kind"]) + str(b["item"])
	var g2 := got.duplicate()
	var w2 := want.duplicate()
	g2.sort_custom(by)
	w2.sort_custom(by)
	for i in g2.size():
		if g2[i] != w2[i]:
			return "row %s: %s != %s" % [w2[i]["item"], str(g2[i]), str(w2[i])]
	return ""


func _random_edit(rng: RandomNumberGenerator, ids: Array) -> void:
	var keys: Array = layout.objects.keys()
	var u: int = keys[rng.randi() % keys.size()]
	match rng.randi() % 9:
		0, 1:
			_place(ids[rng.randi() % ids.size()], Vector2i(rng.randi() % 20, rng.randi() % 20))
		2:
			if keys.size() > 8:
				layout.remove_objects([u])
		3, 4:
			layout.move_objects([u], Vector2i(rng.randi_range(-6, 6), rng.randi_range(-6, 6)))
		5:
			layout.set_planning(PlanDoc.with_placed(layout.planning, layout, [u], rng.randf() < 0.6))
		6:
			layout.set_planning(PlanDoc.with_acquired(layout.planning, ids[rng.randi() % ids.size()], rng.randi() % 3))
		7:
			var prof := layout.profile.duplicate(true)
			prof["owned"][ids[rng.randi() % ids.size()]] = rng.randi() % 4
			layout.profile = prof
			layout.planning_changed.emit()
		8:
			layout.set_property([u], "item_id", [ids[rng.randi() % ids.size()]])


func test_build_matches_reference_after_random_edits() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var plan := Fx.two_phase_plan()
	plan["areas"].append({"id": "poly", "name": "P", "points": [[0, 0], [16, 4], [8, 18]]})
	plan["phases"].append({"id": "p3", "name": "Third", "areas": ["poly"]})
	layout.set_planning(PlanDoc.normalize(plan))
	var p := layout.profile.duplicate(true)
	p["owned"] = {"t_long": 1, "t_fence": 2, "t_prize": 0, "t_bakery": 0}
	p["purchased"] = {"t_long": 3}
	p["balances"] = {"land_deed": 1}
	layout.profile = p
	var ids := ["t_long", "t_fence", "t_fence_stone", "t_bakery", "t_lamp", "t_path", "t_voucher", "t_prize",
		"t_limited", "t_free", "t_film", "t_rare", "t_odd", "t_mystery"]
	for i in 30:
		_place(ids[rng.randi() % ids.size()], Vector2i(rng.randi() % 20, rng.randi() % 20))
	var bad := 0
	for step in 70:
		_random_edit(rng, ids)
		var keys: Array = layout.objects.keys()
		var scopes: Array = [null, keys.slice(0, rng.randi_range(1, keys.size())), eng.phase_uids("p1"),
			eng.phase_uids(""), eng.area_uids("poly")]
		for m in BudgetEngine.MODES:
			for sc in scopes:
				var land := rng.randf() < 0.5
				var err := same_rows(ShoppingList.build(eng, sc, m, land), ref_build(eng, layout, sc, m, land))
				if not err.is_empty():
					bad += 1
					if bad <= 3:
						fail("step %d mode %s: %s" % [step, m, err])
	assert_eq(bad, 0, "fast build == reference after every edit, every mode and scope")


func test_build_matches_reference_with_real_catalogue() -> void:
	var rdb := ItemDatabase.new()
	rdb.load_default()
	var rpb := PriceBook.load_default(rdb, "user://__no_price_overrides__.json")
	var rmap := FarmMap.load_file("res://data/maps/hayday_farm.json")
	var rl := FarmLayout.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var pool: Array = []
	for it: ItemDef in rdb.ordered:
		if it.can_place() and it.footprint.x <= 4 and it.footprint.y <= 4 and rng.randf() < 0.05:
			pool.append(it)
	var objs: Array = []
	for i in 400:
		var it: ItemDef = pool[rng.randi() % pool.size()]
		var o := PlacedObject.new()
		o.item_id = it.id
		o.size = it.footprint
		o.origin = Vector2i(rng.randi() % rmap.size.x, rng.randi() % rmap.size.y)
		objs.append(o)
	rl.add_objects(objs)
	var plan := PlanDoc.empty()
	plan["areas"] = [{"id": "a1", "name": "A", "rect": [0, 0, 40, 25]}, {"id": "a2", "name": "B", "points": [[40, 0], [90, 12], [60, 45]]}]
	plan["phases"] = [{"id": "p1", "name": "One", "areas": ["a2"]}, {"id": "p2", "name": "Two", "areas": ["a1"]}]
	var owned := {}
	var acq := {}
	for it: ItemDef in pool:
		if rng.randf() < 0.5:
			owned[it.id] = rng.randi() % 4
		if rng.randf() < 0.2:
			acq[it.id] = rng.randi() % 3
	plan["acquired"] = acq
	rl.set_planning(PlanDoc.normalize(plan))
	rl.profile["owned"] = owned
	var re := BudgetEngine.new(rl, rdb, rpb, rmap)
	var bad := 0
	for round in 3:
		var keys: Array = rl.objects.keys()
		for m in BudgetEngine.MODES:
			for sc in [null, keys.slice(0, 150), re.phase_uids("p1"), re.area_uids("a1")]:
				var err := same_rows(ShoppingList.build(re, sc, m, true), ref_build(re, rl, sc, m, true))
				if not err.is_empty():
					bad += 1
					if bad <= 3:
						fail("round %d mode %s: %s" % [round, m, err])
		for i in 15:
			var u: int = keys[rng.randi() % keys.size()]
			if rl.objects.has(u):
				rl.move_objects([u], Vector2i(rng.randi_range(-5, 5), rng.randi_range(-5, 5)))
		rl.set_planning(PlanDoc.with_placed(rl.planning, rl, keys.slice(0, 20), true))
	re.dispose()
	assert_eq(bad, 0, "real items and prices: fast build == reference")


func test_rows_are_reused_while_their_item_is_unchanged() -> void:
	_setup()
	var a := ShoppingList.build(eng, null, REMAINING, false)
	var b := ShoppingList.build(eng, null, REMAINING, false)
	assert_eq(a, b)
	for i in a.size():
		assert_true(is_same(a[i], b[i]), "unchanged: same row object (%s)" % a[i]["item"])
	var lamp := _row(a, "t_lamp")
	var long := _row(a, "t_long")
	for u in layout.objects:
		if layout.objects[u].item_id == "t_lamp":
			layout.move_objects([u], Vector2i(0, 1))
	var c := ShoppingList.build(eng, null, REMAINING, false)
	assert_false(is_same(_row(c, "t_lamp"), lamp), "edited item: new row")
	assert_true(is_same(_row(c, "t_long"), long), "other items: reused")
	assert_eq(_row(c, "t_lamp"), lamp, "same content (a move changes no count)")
	pb.set_override("t_long", {"price": {"coins": 3}})
	var d := ShoppingList.build(eng, null, REMAINING, false)
	assert_false(is_same(_row(d, "t_long"), long), "prices changed: rows rebuilt")
	assert_eq(_row(d, "t_long")["total"], {"coins": 6})


func test_sort_rows_matches_reference_comparator() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	var names := ["Bench", "bench 2", "Bench 10", "apple", "Äpple", "Zebra", "zebra", "10 Lamps", "9 Lamps", ".hidden", "", "Stone Wall"]
	var rows: Array = []
	for i in 60:
		var r := {"kind": ShoppingList.KIND_ITEM if rng.randf() < 0.85 else ShoppingList.KIND_SUPPLY,
			"item": "i%d" % i, "name": names[rng.randi() % names.size()] + ("" if rng.randf() < 0.5 else " %d" % (rng.randi() % 30)),
			"group": ShoppingList.GROUPS[rng.randi() % ShoppingList.GROUPS.size()],
			"missing": rng.randi() % 4, "used": rng.randi() % 5, "unlock_level": rng.randi_range(-1, 30)}
		match rng.randi() % 4:
			0: r["total"] = {}
			1: r["total"] = {"coins": rng.randi() % 500}
			2: r["total"] = {"diamonds": rng.randi() % 9, "coins": rng.randi() % 3}
		r["next_price"] = r.get("total")
		rows.append(r)
	for key in ["group", "name", "missing", "used", "total", "unlock_level", "next_price"]:
		for desc in [false, true]:
			var err := same_rows(ShoppingList.sort_rows(rows, key, desc), ref_sort(rows, key, desc), key, desc)
			assert_eq(err, "", "sort_rows(%s, %s)" % [key, str(desc)])


func test_acquisition_progress_and_apply_to_inventory() -> void:
	_setup()
	var before := eng.totals(null, REMAINING).cost
	var rows := ShoppingList.build(eng, null, REMAINING)
	var prog := ShoppingList.progress(rows)
	assert_eq(prog["acquired"], 1)
	var plan2 := ShoppingList.with_bought(layout.planning, "t_fence", 2)
	assert_eq(plan2["acquired"]["t_fence"], 2)
	assert_false(layout.planning["acquired"].has("t_fence"), "pure: the layout is untouched")
	var res := ShoppingList.apply_acquired_to_inventory(layout.profile, layout.planning)
	assert_eq(res["applied"], {"t_long": 1})
	assert_eq(res["profile"]["owned"]["t_long"], 2)
	assert_eq(res["profile"]["purchased"]["t_long"], 2)
	assert_eq(res["plan"]["acquired"], {})
	assert_eq(layout.profile["owned"]["t_long"], 1, "input not mutated")
	layout.profile = res["profile"]
	layout.set_planning(res["plan"])
	assert_true(Currency.equal(eng.totals(null, REMAINING).cost, before), "remaining cost unchanged by applying")
	var r2 := ShoppingList.with_row_bought(layout.planning, _row(ShoppingList.build(eng), "t_fence"))
	assert_eq(r2["acquired"]["t_fence"], 5)
	var unk := ShoppingList.apply_acquired_to_inventory({"owned": {}}, PlanDoc.with_acquired(PlanDoc.empty(), "t_lamp", 2))
	assert_eq(unk["assumed"], ["t_lamp"])
	assert_eq(unk["profile"]["owned"]["t_lamp"], 2)
