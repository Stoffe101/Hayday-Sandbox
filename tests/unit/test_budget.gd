extends TestCase
## BudgetEngine (docs/PLANNING.md §4): allocation, cost modes, scopes, land,
## phase status, affordability and incremental == full. Synthetic prices only
## (tests/fixtures/prices.json).

const TO_BUY := BudgetEngine.MODE_TO_BUY
const REMAINING := BudgetEngine.MODE_REMAINING
const DESIGN := BudgetEngine.MODE_DESIGN

var db: ItemDatabase
var pb: PriceBook
var map: FarmMap
var layout: FarmLayout
var eng: BudgetEngine


## Fixture items + a few synthetic items for the price methods (shared by the
## planning tests: preload("res://tests/unit/test_budget.gd").make_db()).
static func make_db() -> ItemDatabase:
	var d := TestCase.fixture_db()
	var extra := [
		{"id": "t_voucher", "name": "Voucher Tree", "category": "nature", "footprint": [1, 1], "footprint_status": "confirmed"},
		{"id": "t_film", "name": "Film Statue", "category": "seasonal", "footprint": [2, 2], "footprint_status": "confirmed"},
		{"id": "t_prize", "name": "Derby Trophy", "category": "decoration", "footprint": [1, 1], "footprint_status": "confirmed"},
		{"id": "t_rare", "name": "Rare Relic", "category": "decoration", "footprint": [1, 1], "footprint_status": "confirmed"},
		{"id": "t_free", "name": "Free Bench", "category": "furniture", "footprint": [1, 1], "footprint_status": "confirmed"},
		{"id": "t_limited", "name": "Limited Lamp", "category": "furniture", "footprint": [1, 1], "footprint_status": "confirmed"},
		{"id": "t_odd", "name": "Odd Thing", "category": "structures", "footprint": [1, 1], "footprint_status": "confirmed"},
	]
	for rec in extra:
		d.add_item(ItemDef.from_dict(rec, []))
	d.finalize()
	return d


static func make_prices(d: ItemDatabase) -> PriceBook:
	var p := PriceBook.new()
	p.overrides_path = "user://__no_price_overrides__.json"
	p.set_catalogue(d)
	p.load_file("res://tests/fixtures/prices.json")
	return p


static func ref_breakdown(e: BudgetEngine, l: FarmLayout, uids: Variant, mode: String) -> Dictionary:
	## Slow reference for BudgetEngine.item_breakdown() from the per-object API
	## (object_info), the way the first implementation summed it slot by slot.
	var list: Array = l.objects.keys() if uids == null else uids
	var acc := {}
	for u in list:
		var info := e.object_info(int(u))
		if info.is_empty():
			continue
		var id: String = info["item"]
		if not acc.has(id):
			acc[id] = {"used": 0, "owned": 0, "acquired": 0, "to_buy": 0, "placed": 0, "charged": 0, "known": 0,
				"unknown": 0, "not_buyable": 0, "cost": {}, "k_min": 0, "k_max": 0}
		var en: Dictionary = acc[id]
		en["used"] += 1
		var st: String = info["status"]
		en[st] += 1
		if info["placed"]:
			en["placed"] += 1
		var charged := mode == BudgetEngine.MODE_DESIGN or (st != BudgetEngine.STATUS_OWNED
			and not (mode == BudgetEngine.MODE_REMAINING and st == BudgetEngine.STATUS_ACQUIRED))
		if not charged:
			continue
		en["charged"] += 1
		var k: int = info["design_copy"] if mode == BudgetEngine.MODE_DESIGN else info["purchase_number"]
		en["k_min"] = k if int(en["k_min"]) == 0 else mini(int(en["k_min"]), k)
		en["k_max"] = maxi(int(en["k_max"]), k)
		var c: Variant = info["cost"][mode]
		if c == null:
			if info["price_state"] == "not_buyable":
				en["not_buyable"] += 1
			else:
				en["unknown"] += 1
		else:
			en["known"] += 1
			Currency.add_into(en["cost"], c)
	return acc


static func two_phase_plan() -> Dictionary:
	## a1 = x 0..4, a2 = x 5..9 (both y 0..9); p1 builds a1 first, then p2 builds a2.
	var plan := PlanDoc.empty()
	plan["areas"] = [{"id": "a1", "name": "West", "rect": [0, 0, 5, 10]}, {"id": "a2", "name": "East", "rect": [5, 0, 5, 10]}]
	plan["phases"] = [{"id": "p1", "name": "First", "areas": ["a1"]}, {"id": "p2", "name": "Second", "areas": ["a2"]}]
	return PlanDoc.normalize(plan)


func before_each() -> void:
	db = make_db()
	pb = make_prices(db)
	map = fixture_map()
	layout = FarmLayout.new()
	eng = BudgetEngine.new(layout, db, pb, map)


func after_each() -> void:
	eng.dispose()


func _place(id: String, at: Vector2i, planned: bool = false) -> int:
	var o := make_obj(db.get_item(id), at)
	o.planned = planned
	return layout.add_objects([o])[0]


func _owned(d: Dictionary, purchased: Dictionary = {}) -> void:
	var p := layout.profile.duplicate(true)
	p["owned"] = d
	p["purchased"] = purchased
	layout.profile = p
	layout.planning_changed.emit()


func _plan_edit(f: Callable) -> void:
	layout.set_planning(f.call(layout.planning.duplicate(true)))


func _coins(t: BudgetEngine.Totals) -> int:
	return int(t.cost.get("coins", 0))


# --- §15.3 ---------------------------------------------------------------------------------------

func test_item_bought_once_not_charged_twice_across_views() -> void:
	var plan := two_phase_plan()
	plan["areas"].append({"id": "a3", "name": "Overlap", "rect": [0, 0, 10, 10]})
	layout.set_planning(PlanDoc.normalize(plan))
	_owned({"t_bakery": 0})
	var u := _place("t_bakery", Vector2i(1, 1))
	assert_eq(_coins(eng.totals(null, TO_BUY)), 50)
	assert_eq(_coins(eng.phase_totals("p1", TO_BUY)), 50)
	assert_eq(_coins(eng.phase_totals("p2", TO_BUY)), 0, "only the primary phase pays")
	assert_eq(_coins(eng.area_totals("a1", TO_BUY)), 50)
	assert_eq(_coins(eng.area_totals("a3", TO_BUY)), 50)
	assert_eq(_coins(eng.totals([u], TO_BUY)), 50, "selection")
	# Bought (acquired) once: nothing remains in any view, To buy still shows the purchase once.
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, "t_bakery", 1))
	for scope in [eng.totals(null, REMAINING), eng.phase_totals("p1", REMAINING), eng.area_totals("a1", REMAINING),
			eng.area_totals("a3", REMAINING), eng.totals([u], REMAINING)]:
		assert_true(Currency.is_zero((scope as BudgetEngine.Totals).cost), "acquired copy is not charged again")
	assert_eq(_coins(eng.totals(null, TO_BUY)), 50)
	assert_eq(eng.status_of(u), BudgetEngine.STATUS_ACQUIRED)


func test_owned_item_moved_between_areas_stays_owned() -> void:
	layout.set_planning(two_phase_plan())
	_owned({"t_long": 1})
	var a := _place("t_long", Vector2i(1, 1))
	assert_eq(eng.primary_phase(a), "p1")
	assert_eq(eng.status_of(a), BudgetEngine.STATUS_OWNED)
	layout.move_objects([a], Vector2i(6, 0))
	assert_eq(eng.primary_phase(a), "p2", "moved into the second area")
	assert_eq(eng.status_of(a), BudgetEngine.STATUS_OWNED)
	assert_true(Currency.is_zero(eng.totals(null, TO_BUY).cost))
	assert_eq(_coins(eng.phase_totals("p2", DESIGN)), 10)
	# A second copy in the same phase is the one to buy (uid order).
	var b := _place("t_long", Vector2i(8, 1))
	assert_eq(eng.status_of(b), BudgetEngine.STATUS_TO_BUY)
	assert_eq(_coins(eng.totals(null, TO_BUY)), 15, "purchase #2 (owned 1)")
	layout.move_objects([a], Vector2i(-6, 0))
	assert_eq(eng.status_of(a), BudgetEngine.STATUS_OWNED, "moved back: still owned")
	assert_eq(_coins(eng.totals(null, TO_BUY)), 15, "the copy is never paid twice")
	assert_eq(eng.totals(null, TO_BUY).owned_objects, 1)


func _assert_reconciles(mode: String) -> void:
	var farm := eng.totals(null, mode)
	var sum := {}
	var objects := 0
	var unknown := 0
	var nb := 0
	var plots: Array = []
	var unknown_plots: Array = []
	for pid in eng.phase_ids():
		var t := eng.phase_totals(pid, mode)
		Currency.add_into(sum, t.cost)
		objects += t.objects
		unknown += t.unknown_price_objects
		nb += t.not_buyable_objects
		plots.append_array(t.plots)
		unknown_plots.append_array(t.unknown_cost_plots)
	plots.sort()
	unknown_plots.sort()
	assert_true(Currency.equal(sum, farm.cost), "%s: phases %s == farm %s" % [mode, str(sum), str(farm.cost)])
	assert_eq(objects, farm.objects, mode + " objects")
	assert_eq(unknown, farm.unknown_price_objects, mode + " unknown")
	assert_eq(nb, farm.not_buyable_objects, mode + " not buyable")
	assert_eq(plots, farm.plots, mode + " plots counted once")
	assert_eq(unknown_plots, farm.unknown_cost_plots, mode + " unknown plots")


func test_whole_farm_equals_sum_of_phases_with_land() -> void:
	layout.set_planning(two_phase_plan())
	_owned({"t_long": 1, "t_fence": 0, "t_lamp": 0, "t_path": 0})
	_place("t_long", Vector2i(1, 1))
	_place("t_long", Vector2i(6, 1))
	_place("t_fence", Vector2i(2, 12))       # Unphased (below the areas)
	_place("t_lamp", Vector2i(13, 2))        # Unphased, locked plot_a (3 land deeds)
	_place("t_path", Vector2i(14, 12))       # Unphased, plot_b (supplies unknown), no price
	_place("t_prize", Vector2i(3, 3))
	# Objects of two phases on the same locked plot: the plot is counted once.
	var plan := layout.planning.duplicate(true)
	plan["areas"].append({"id": "a3", "name": "Plot A", "rect": [12, 0, 4, 10]})
	plan["phases"].append({"id": "p3", "name": "Third", "areas": ["a3"]})
	layout.set_planning(PlanDoc.normalize(plan))
	_place("t_fence", Vector2i(16, 3))
	var t := eng.totals(null, TO_BUY)
	assert_eq(t.plots, ["plot_a", "plot_b"])
	assert_eq(t.unknown_cost_plots, ["plot_b"])
	assert_eq(int(t.land_cost.get("land_deed", 0)), 3, "plot_a's deeds once")
	assert_eq(int(t.cost.get("land_deed", 0)), 3)
	assert_eq(eng.plot_phase("plot_a"), "p3", "earliest phase needing the plot")
	assert_eq(eng.phase_totals("p3", TO_BUY).plots, ["plot_a"])
	assert_eq(eng.phase_totals(BudgetEngine.UNPHASED, TO_BUY).plots, ["plot_b"])
	assert_true(eng.totals(null, DESIGN).cost.get("land_deed") == null, "land is not part of the design cost")
	for m in BudgetEngine.MODES:
		_assert_reconciles(m)
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, "t_fence", 1))
	for m in BudgetEngine.MODES:
		_assert_reconciles(m)
	layout.set_unlocked(["plot_a"])
	assert_eq(eng.totals(null, TO_BUY).plots, ["plot_b"], "unlocked plots cost nothing")
	_assert_reconciles(TO_BUY)


func test_acquired_copies_reduce_remaining() -> void:
	_owned({"t_long": 0})
	for x in 3:
		_place("t_long", Vector2i(x, 0))
	assert_eq(_coins(eng.totals(null, TO_BUY)), 45, "10 + 15 + 20")
	assert_eq(_coins(eng.totals(null, REMAINING)), 45)
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, "t_long", 1))
	assert_eq(_coins(eng.totals(null, TO_BUY)), 45, "To buy includes what was bought during the project")
	assert_eq(_coins(eng.totals(null, REMAINING)), 35, "purchases #2 and #3 remain")
	var t := eng.totals(null, REMAINING)
	assert_eq(t.acquired_objects, 1)
	assert_eq(t.to_buy_objects, 2)
	assert_eq(t.charged_objects, 2)


func test_phase_does_not_charge_for_previously_acquired() -> void:
	layout.set_planning(two_phase_plan())
	_owned({"t_long": 0})
	var a := _place("t_long", Vector2i(6, 1))   # p2
	var b := _place("t_long", Vector2i(1, 1))   # p1 (builds first)
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, "t_long", 1))
	assert_eq(eng.status_of(b), BudgetEngine.STATUS_ACQUIRED, "first phase gets the acquired copy")
	assert_true(Currency.is_zero(eng.phase_totals("p1", REMAINING).cost))
	assert_eq(_coins(eng.phase_totals("p2", REMAINING)), 15, "purchase #2")
	assert_eq(eng.status_of(a), BudgetEngine.STATUS_TO_BUY)
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_phase_moved(p, "p2", 0))
	assert_eq(eng.status_of(a), BudgetEngine.STATUS_ACQUIRED, "reordering phases changes who gets copies first")
	assert_true(Currency.is_zero(eng.phase_totals("p2", REMAINING).cost))
	assert_eq(_coins(eng.phase_totals("p1", REMAINING)), 15)


func test_overlapping_areas_do_not_inflate_grand_total() -> void:
	var plan := PlanDoc.empty()
	plan["areas"] = [{"id": "a1", "name": "Big", "rect": [0, 0, 8, 8]}, {"id": "a2", "name": "Mid", "rect": [2, 2, 8, 8]}]
	plan["phases"] = [{"id": "p1", "name": "One", "areas": ["a1"]}, {"id": "p2", "name": "Two", "areas": ["a2"]}]
	layout.set_planning(PlanDoc.normalize(plan))
	_owned({"t_long": 0, "t_bakery": 0})
	_place("t_long", Vector2i(3, 3))
	_place("t_long", Vector2i(4, 3))
	_place("t_bakery", Vector2i(8, 8))   # only in a2
	var farm := _coins(eng.totals(null, TO_BUY))
	assert_eq(farm, 10 + 15 + 50)
	assert_eq(_coins(eng.area_totals("a1", TO_BUY)), 25)
	assert_eq(_coins(eng.area_totals("a2", TO_BUY)), 75)
	assert_true(_coins(eng.area_totals("a1", TO_BUY)) + _coins(eng.area_totals("a2", TO_BUY)) > farm, "areas overlap")
	assert_eq(_coins(eng.phase_totals("p1", TO_BUY)) + _coins(eng.phase_totals("p2", TO_BUY)), farm)
	var all: Array = layout.objects.keys()
	assert_eq(_coins(eng.totals(all, TO_BUY)), farm)


func test_missing_price_never_counts_as_free() -> void:
	_owned({"t_path": 0, "t_mystery": 0, "ghost": 0})
	var p := _place("t_path", Vector2i(0, 0))
	_place("t_mystery", Vector2i(2, 0))
	var g := PlacedObject.new()
	g.item_id = "ghost"
	g.origin = Vector2i(5, 5)
	g.missing = true
	layout.add_objects([g])
	_place("t_long", Vector2i(8, 0))
	_owned({"t_path": 0, "t_mystery": 0, "ghost": 0, "t_long": 0})
	var t := eng.totals(null, TO_BUY)
	assert_eq(_coins(t), 10, "only the known price is summed")
	assert_eq(t.unknown_price_objects, 3)
	assert_eq(t.unknown_price_types, ["ghost", "t_mystery", "t_path"])
	assert_false(t.is_exact())
	assert_null(eng.object_cost(p, TO_BUY), "unknown is null, not {}")
	assert_eq(eng.object_info(p)["price_state"], "unknown")
	assert_eq(eng.totals(null, DESIGN).unknown_price_objects, 3)
	_owned({"t_path": 1, "t_mystery": 1, "ghost": 1, "t_long": 1})
	assert_true(eng.totals(null, TO_BUY).is_exact(), "owned copies need no price")


func test_progressive_step_and_purchased_offset() -> void:
	_owned({"t_long": 1}, {"t_long": 4})
	var a := _place("t_long", Vector2i(0, 0))
	var b := _place("t_long", Vector2i(1, 0))
	assert_eq(eng.status_of(a), BudgetEngine.STATUS_OWNED)
	assert_eq(eng.object_info(b)["purchase_number"], 5, "purchased 4 -> next is #5")
	assert_eq(_coins(eng.totals(null, TO_BUY)), 30, "10 + 5 x 4")
	assert_eq(_coins(eng.totals(null, DESIGN)), 25, "design: copies #1 and #2")
	_owned({"t_long": 1})
	assert_eq(_coins(eng.totals(null, TO_BUY)), 15, "purchased defaults to owned")


func test_schedule_and_schedule_past_end() -> void:
	_owned({"t_fence": 0, "t_fence_stone": 1})
	for x in 5:
		_place("t_fence", Vector2i(x, 0))
	for x in 4:
		_place("t_fence_stone", Vector2i(x, 2))
	var t := eng.totals(null, TO_BUY)
	assert_eq(_coins(t), 5 + 7 + 9 + 30 + 30 + 30, "stone fence repeats its last entry; purchases #2-#4")
	assert_eq(t.unknown_price_objects, 2, "wood fence copies past the schedule are unknown")
	assert_eq(t.unknown_price_types, ["t_fence"])


func test_vouchers_and_event_currency() -> void:
	_owned({"t_voucher": 0, "t_film": 0, "t_odd": 0, "t_free": 0, "t_lamp": 0})
	_place("t_voucher", Vector2i(0, 0))
	_place("t_voucher", Vector2i(1, 0))
	_place("t_film", Vector2i(3, 0))
	_place("t_odd", Vector2i(6, 0))
	_place("t_free", Vector2i(8, 0))
	_place("t_lamp", Vector2i(9, 0))   # catalogue fallback: 5 diamonds
	var c := eng.totals(null, TO_BUY).cost
	assert_eq(c, {"voucher_green": 10, "voucher_purple": 2, "film": 400, "coins": 100, "moon_rocks": 2, "diamonds": 5})
	assert_true(eng.totals(null, TO_BUY).is_exact())
	assert_eq(Currency.format_line(c), "100 coins · 5 diamonds · 10 green vouchers · 2 purple vouchers · 400 film · 2 moon_rocks")


func test_reward_and_not_in_shop_are_not_buyable() -> void:
	_owned({"t_prize": 0, "t_rare": 0})
	var p := _place("t_prize", Vector2i(0, 0))
	_place("t_rare", Vector2i(1, 0))
	var t := eng.totals(null, TO_BUY)
	assert_eq(t.not_buyable_objects, 2)
	assert_eq(t.not_buyable_types, ["t_prize", "t_rare"])
	assert_eq(t.unknown_price_objects, 0, "can't-buy is counted apart from price-unknown")
	assert_true(Currency.is_zero(t.cost), "999-diamond placeholder never counts")
	assert_eq(eng.object_info(p)["price_state"], "not_buyable")
	_owned({"t_prize": 1, "t_rare": 1})
	assert_eq(eng.totals(null, TO_BUY).not_buyable_objects, 0, "owned rewards need nothing")
	assert_eq(eng.totals(null, DESIGN).not_buyable_objects, 2)


func test_max_count() -> void:
	_owned({"t_limited": 0, "t_bakery": 0})
	for x in 3:
		_place("t_limited", Vector2i(x, 0))
	_place("t_bakery", Vector2i(0, 4))
	var t := eng.totals(null, TO_BUY)
	assert_eq(t.over_max, [{"item": "t_limited", "count": 3, "max": 2}])
	_place("t_bakery", Vector2i(4, 4))
	assert_eq(eng.totals(null, TO_BUY).over_max.size(), 2)
	assert_eq(eng.item_state("t_bakery")["max_count"], 1)


func test_allocation_priority_follows_phase_order_and_baseline() -> void:
	layout.set_planning(two_phase_plan())
	_owned({"t_long": 1})
	var a := _place("t_long", Vector2i(6, 1))   # lower uid, phase p2
	var b := _place("t_long", Vector2i(1, 1))   # phase p1
	assert_eq(eng.status_of(b), BudgetEngine.STATUS_OWNED, "phase order beats uid")
	assert_eq(eng.alloc_order("t_long"), [b, a])
	var c := _place("t_long", Vector2i(1, 15))   # Unphased: last
	assert_eq(eng.alloc_order("t_long"), [b, a, c])
	# A baseline object (standing on the real farm) is covered first.
	_plan_edit(func(p: Dictionary) -> Dictionary:
		p["baseline"] = {"name": "Real", "objects": {str(c): ["t_long", 1, 15, 1, 4]}}
		return p)
	assert_eq(eng.status_of(c), BudgetEngine.STATUS_OWNED)
	assert_eq(eng.alloc_order("t_long"), [c, b, a])
	assert_true(eng.is_placed(c), "unchanged baseline object counts as placed")
	layout.move_objects([c], Vector2i(1, 0))
	assert_false(eng.is_placed(c), "moved: no longer placed")
	assert_eq(eng.status_of(c), BudgetEngine.STATUS_OWNED, "moved baseline object keeps its copy")


func test_unknown_ownership_and_baseline_lower_bound() -> void:
	_place("t_long", Vector2i(0, 0))
	var b := _place("t_long", Vector2i(1, 0))
	var t := eng.totals(null, TO_BUY)
	assert_eq(t.unknown_ownership_types, ["t_long"])
	assert_eq(t.to_buy_objects, 2, "unknown ownership counts as to buy (upper bound)")
	_plan_edit(func(p: Dictionary) -> Dictionary:
		p["baseline"] = {"name": "Real", "objects": {str(b): ["t_long", 1, 0, 1, 4]}}
		return p)
	t = eng.totals(null, TO_BUY)
	assert_eq(t.unknown_ownership_types, [], "a baseline copy makes ownership known (lower bound)")
	assert_eq(t.owned_objects, 1)
	assert_eq(eng.status_of(b), BudgetEngine.STATUS_OWNED)
	assert_eq(_coins(t), 15, "purchase #2")
	assert_eq(eng.totals(null, DESIGN).unknown_ownership_types, [], "design mode ignores inventory")


func test_planned_objects_are_included() -> void:
	_owned({"t_bakery": 0})
	_place("t_bakery", Vector2i(0, 0), true)
	assert_eq(_coins(eng.totals(null, TO_BUY)), 50)


func test_phase_status() -> void:
	layout.set_planning(two_phase_plan())
	_owned({"t_long": 0})
	var a := _place("t_long", Vector2i(1, 1))
	var b := _place("t_long", Vector2i(2, 1))
	assert_eq(eng.phase_status("p1"), BudgetEngine.PHASE_NOT_STARTED)
	assert_eq(eng.phase_status("p2"), BudgetEngine.PHASE_NOT_STARTED, "empty phase")
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, "t_long", 2))
	assert_eq(eng.phase_status("p1"), BudgetEngine.PHASE_READY)
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_placed(p, layout, [a], true))
	assert_eq(eng.phase_status("p1"), BudgetEngine.PHASE_READY, "ready wins over in progress")
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, "t_long", 1))
	assert_eq(eng.phase_status("p1"), BudgetEngine.PHASE_IN_PROGRESS)
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_placed(p, layout, [b], true))
	assert_eq(eng.phase_status("p1"), BudgetEngine.PHASE_COMPLETED, "every object placed")
	assert_eq(eng.totals(null, TO_BUY).placed_objects, 2)
	_plan_edit(func(p: Dictionary) -> Dictionary:
		var ph := PlanDoc.phase(p, "p2").duplicate(true)
		ph["done"] = true
		return PlanDoc.with_phase(p, ph))
	assert_eq(eng.phase_status("p2"), BudgetEngine.PHASE_COMPLETED, "marked done")


func test_affordability_in_build_order() -> void:
	layout.set_planning(two_phase_plan())
	_owned({"t_long": 0, "t_lamp": 0})
	_place("t_long", Vector2i(1, 1))     # p1: 10 coins
	_place("t_long", Vector2i(6, 1))     # p2: 15 coins
	_place("t_lamp", Vector2i(6, 5))     # p2: 5 diamonds
	var r := eng.affordability({"coins": 20, "diamonds": 100})
	assert_eq(r["affordable_count"], 1)
	assert_eq(r["phases"].size(), 2, "empty Unphased left out")
	assert_true(r["phases"][0]["affordable"])
	assert_false(r["phases"][1]["affordable"])
	assert_eq(r["phases"][1]["cumulative"], {"coins": 25, "diamonds": 5})
	assert_eq(r["phases"][1]["shortfall"], {"coins": 5}, "diamonds never pay for coins")
	r = eng.affordability({"coins": 1000})
	assert_eq(r["affordable_count"], 1)
	assert_eq(r["missing_balances"], ["diamonds"])
	var s := BudgetEngine.spendable({"balances": {"coins": 500}, "budget_coins": 200, "budget_diamonds": 7})
	assert_eq(s, {"coins": 200, "diamonds": 7})


func test_lazy_and_once_per_change() -> void:
	_owned({"t_long": 0})
	for x in 5:
		_place("t_long", Vector2i(x, 0))
	eng.totals()
	var v := eng.version
	var full := eng.full_recomputes
	var items := eng.item_recomputes
	eng.totals()
	eng.totals(null, REMAINING)
	assert_eq(eng.item_recomputes, items, "queries without a change do no work")
	var fired := [0]
	eng.changed.connect(func() -> void: fired[0] += 1)
	layout.move_objects([layout.objects.keys()[0]], Vector2i(0, 3))
	assert_true(eng.version > v)
	assert_eq(fired[0], 1)
	eng.totals()
	eng.totals()
	eng.phase_totals("")
	assert_eq(eng.full_recomputes, full, "an object edit is incremental")
	assert_true(eng.item_recomputes - items <= 1, "only the touched item is re-allocated")


func test_in_place_edit_without_signal_is_detected() -> void:
	_owned({"t_long": 0})
	_place("t_long", Vector2i(0, 0))
	assert_eq(_coins(eng.totals(null, REMAINING)), 10)
	layout.planning["acquired"]["t_long"] = 1
	assert_true(Currency.is_zero(eng.totals(null, REMAINING).cost))
	layout.profile["owned"]["t_long"] = 1
	assert_eq(eng.status_of(layout.objects.keys()[0]), BudgetEngine.STATUS_OWNED)
	var o := make_obj(db.get_item("t_long"), Vector2i(3, 0))
	layout.add_objects([o], false)
	assert_eq(eng.totals().objects, 2, "added without a signal")


func test_batch_skips_in_place_detection_until_end() -> void:
	_owned({"t_long": 0})
	var u := _place("t_long", Vector2i(0, 0))
	assert_eq(_coins(eng.totals(null, REMAINING)), 10)
	var out: Variant = eng.batch(func() -> Variant:
		assert_true(eng.in_batch())
		layout.planning["acquired"]["t_long"] = 1      # in place, no signal
		assert_eq(_coins(eng.totals(null, REMAINING)), 10, "in-place edits wait for the end of the batch")
		eng.begin_batch()                               # nested
		var b := _place("t_long", Vector2i(2, 0))       # with a signal: applies at once
		assert_eq(eng.status_of(b), BudgetEngine.STATUS_TO_BUY)
		eng.end_batch()
		assert_true(eng.in_batch(), "still inside the outer batch")
		return 42)
	assert_eq(out, 42, "batch() returns what the callable returns")
	assert_false(eng.in_batch())
	assert_eq(eng.status_of(u), BudgetEngine.STATUS_ACQUIRED, "found by the first query after the batch")
	assert_eq(_coins(eng.totals(null, REMAINING)), 15, "copy #2 remains")
	# A batch starts with one full check: an in-place edit made before it is seen.
	layout.profile["owned"]["t_long"] = 2
	eng.begin_batch()
	assert_eq(eng.totals(null, TO_BUY).owned_objects, 2)
	eng.end_batch()
	eng.end_batch()   # unbalanced end is harmless
	assert_false(eng.in_batch())
	# The old way (auto_detect off) keeps working.
	eng.auto_detect = false
	layout.profile["owned"]["t_long"] = 0
	assert_eq(eng.totals(null, TO_BUY).owned_objects, 2, "auto_detect off: in-place edit not seen")
	eng.auto_detect = true
	assert_eq(eng.totals(null, TO_BUY).owned_objects, 0)


func test_area_uids_match_plan_doc_after_random_edits() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7311
	var plan := two_phase_plan()
	plan["areas"].append({"id": "poly", "name": "Concave", "points": [[1, 1], [12.5, 2.25], [6, 6], [13, 13.7], [0.5, 11]]})
	plan["areas"].append({"id": "tri", "name": "Thin", "points": [[3.2, 0], [3.9, 19.6], [4.1, 0.3]]})
	plan["areas"].append({"id": "flat", "name": "Two points", "points": [[0, 0], [5, 5]]})
	plan["phases"].append({"id": "p3", "name": "Third", "areas": ["poly"]})
	layout.set_planning(PlanDoc.normalize(plan))
	var ids := ["t_long", "t_fence", "t_bakery", "t_lamp", "t_path", "t_film"]
	for i in 40:
		_place(ids[rng.randi() % ids.size()], Vector2i(rng.randi_range(-2, 18), rng.randi_range(-2, 18)))
	var bad := 0
	for step in 120:
		var keys: Array = layout.objects.keys()
		var u: int = keys[rng.randi() % keys.size()]
		match rng.randi() % 4:
			0:
				_place(ids[rng.randi() % ids.size()], Vector2i(rng.randi_range(-2, 18), rng.randi_range(-2, 18)))
			1:
				if keys.size() > 10:
					layout.remove_objects([u])
			_:
				layout.move_objects([u], Vector2i(rng.randi_range(-5, 5), rng.randi_range(-5, 5)))
		for a in PlanDoc.areas(layout.planning):
			var want := PlanDoc.objects_in_area(layout, a)
			var got := eng.area_uids(str(a["id"]))
			if got != want:
				bad += 1
				if bad <= 3:
					fail("step %d area %s: %s != %s" % [step, a["id"], str(got), str(want)])
			if step % 10 == 0:
				assert_eq(eng.area_totals(str(a["id"]), DESIGN).to_dict(), eng.totals(want, DESIGN).to_dict())
	assert_eq(bad, 0, "area membership == PlanDoc.objects_in_area after every edit")
	assert_eq(eng.area_uids("nope"), [])


func test_rollups_and_bulk_getters_match_per_object_reference() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99017
	var plan := two_phase_plan()
	plan["areas"].append({"id": "poly", "name": "P", "points": [[0, 0], [14, 3], [9, 16]]})
	plan["phases"].append({"id": "p3", "name": "Third", "areas": ["poly"]})
	layout.set_planning(PlanDoc.normalize(plan))
	_owned({"t_long": 2, "t_fence": 1, "t_bakery": 0, "t_voucher": 1, "t_prize": 0}, {"t_long": 3})
	var ids := ["t_long", "t_fence", "t_fence_stone", "t_bakery", "t_lamp", "t_path", "t_voucher", "t_prize", "t_limited"]
	for i in 30:
		_place(ids[rng.randi() % ids.size()], Vector2i(rng.randi() % 20, rng.randi() % 20))
	var bad := 0
	for step in 80:
		var keys: Array = layout.objects.keys()
		var u: int = keys[rng.randi() % keys.size()]
		match rng.randi() % 7:
			0:
				_place(ids[rng.randi() % ids.size()], Vector2i(rng.randi() % 20, rng.randi() % 20))
			1:
				if keys.size() > 8:
					layout.remove_objects([u])
			2:
				layout.move_objects([u], Vector2i(rng.randi_range(-6, 6), rng.randi_range(-6, 6)))
			3:
				_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_placed(p, layout, [u], rng.randf() < 0.6))
			4:
				var it: String = ids[rng.randi() % ids.size()]
				var n := rng.randi() % 3
				_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, it, n))
			5:
				var ph := ["", "p1", "p2", "p3"][rng.randi() % 4] as String
				_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_assignment(p, [u], ph))
			6:
				layout.set_property([u], "item_id", [ids[rng.randi() % ids.size()]])
		keys = layout.objects.keys()
		var sel: Array = keys.slice(0, rng.randi_range(1, keys.size()))
		var scopes: Array = [null, sel, eng.phase_uids("p1"), eng.phase_uids(""), eng.area_uids("poly"), eng.area_uids("a2")]
		for m in BudgetEngine.MODES:
			for sc in scopes:
				var got := eng.item_breakdown(sc, m)
				var want := ref_breakdown(eng, layout, sc, m)
				if got != want:
					bad += 1
					if bad <= 3:
						fail("step %d mode %s scope %s: %s != %s" % [step, m, str(sc), str(got), str(want)])
				var t := eng.totals(sc, m)
				assert_true(is_same(t, eng.totals(sc, m)), "uid-list totals cached per version")
		var ps := eng.placed_set()
		for k in keys:
			if ps.has(k) != eng.is_placed(k):
				bad += 1
		for id in ids:
			var order := eng.alloc_order(id)
			for j in order.size():
				if int(eng.object_info(order[j])["design_copy"]) != j + 1:
					bad += 1
	assert_eq(bad, 0, "kept per-item entries == per-object reference after every edit")


func test_item_revision_changes_with_the_item() -> void:
	_owned({"t_long": 0, "t_lamp": 0})
	var a := _place("t_long", Vector2i(0, 0))
	_place("t_lamp", Vector2i(3, 0))
	var r_long := eng.item_revision("t_long")
	var r_lamp := eng.item_revision("t_lamp")
	assert_true(r_long >= 0)
	assert_eq(eng.item_revision("not_in_design"), -1)
	layout.move_objects([a], Vector2i(0, 2))
	assert_true(eng.item_revision("t_long") != r_long, "moved object: its item changed")
	assert_eq(eng.item_revision("t_lamp"), r_lamp, "other items keep their revision")
	r_long = eng.item_revision("t_long")
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_placed(p, layout, [a], true))
	assert_true(eng.item_revision("t_long") != r_long, "placed mark")
	r_lamp = eng.item_revision("t_lamp")
	_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, "t_lamp", 1))
	assert_true(eng.item_revision("t_lamp") != r_lamp, "acquired copies")


func test_prices_change_updates_engine() -> void:
	_owned({"t_path": 0})
	_place("t_path", Vector2i(0, 0))
	assert_eq(eng.totals().unknown_price_objects, 1)
	var v := eng.version
	pb.set_override("t_path", {"price": {"coins": 7}})
	assert_true(eng.version > v)
	assert_eq(_coins(eng.totals()), 7)
	assert_eq(eng.totals().unknown_price_objects, 0)


# --- incremental == full ---------------------------------------------------------------------------

func _snapshot(e: BudgetEngine) -> Dictionary:
	var out := {}
	for u in layout.objects:
		out["obj%d" % u] = e.object_info(u)
	for m in BudgetEngine.MODES:
		out["farm/" + m] = e.totals(null, m).to_dict()
		for pid in e.phase_ids():
			out["phase/%s/%s" % [pid, m]] = e.phase_totals(pid, m).to_dict()
		for a in PlanDoc.areas(layout.planning):
			out["area/%s/%s" % [a["id"], m]] = e.area_totals(str(a["id"]), m).to_dict()
	for pid in e.phase_ids():
		out["status/" + pid] = e.phase_status(pid)
	return out


func test_incremental_equals_full_after_random_edits() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261110
	var ids := ["t_long", "t_fence", "t_fence_stone", "t_bakery", "t_lamp", "t_path", "t_voucher", "t_prize", "t_limited"]
	var plan := two_phase_plan()
	plan["areas"].append({"id": "a3", "name": "Plot", "rect": [12, 0, 6, 12]})
	plan["phases"].append({"id": "p3", "name": "Third", "areas": ["a3"]})
	layout.set_planning(PlanDoc.normalize(plan))
	_owned({"t_long": 2, "t_fence": 3, "t_bakery": 0, "t_voucher": 1})
	for i in 25:
		_place(ids[rng.randi() % ids.size()], Vector2i(rng.randi() % 20, rng.randi() % 20))
	eng.totals()
	var steps := 160
	var mismatches := 0
	for step in steps:
		var keys: Array = layout.objects.keys()
		var u: int = keys[rng.randi() % keys.size()] if not keys.is_empty() else 0
		match rng.randi() % 12:
			0, 1:
				_place(ids[rng.randi() % ids.size()], Vector2i(rng.randi() % 20, rng.randi() % 20))
			2:
				if u != 0 and keys.size() > 5:
					layout.remove_objects([u])
			3, 4:
				if u != 0:
					layout.move_objects([u], Vector2i(rng.randi_range(-6, 6), rng.randi_range(-6, 6)))
			5:
				if u != 0:
					var nid: String = ids[rng.randi() % ids.size()]
					layout.set_property([u], "item_id", [nid])
			6:
				var ph := ["", "p1", "p2", "p3"][rng.randi() % 4] as String
				_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_assignment(p, [u], ph))
			7:
				var it: String = ids[rng.randi() % ids.size()]
				var n := rng.randi() % 3
				_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_acquired(p, it, n))
			8:
				var on := rng.randf() < 0.6
				_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_placed(p, layout, [u], on))
			9:
				var pid := ["p1", "p2", "p3"][rng.randi() % 3] as String
				var to := rng.randi() % 3
				_plan_edit(func(p: Dictionary) -> Dictionary: return PlanDoc.with_phase_moved(p, pid, to))
			10:
				var prof := layout.profile.duplicate(true)
				var it2: String = ids[rng.randi() % ids.size()]
				if rng.randf() < 0.3:
					(prof["owned"] as Dictionary).erase(it2)
				else:
					prof["owned"][it2] = rng.randi() % 4
				if rng.randf() < 0.3:
					if not prof.has("purchased"):
						prof["purchased"] = {}
					prof["purchased"][it2] = rng.randi() % 6
				layout.profile = prof
				layout.planning_changed.emit()
			11:
				if rng.randf() < 0.5:
					layout.set_unlocked([] if not layout.unlocked_plots.is_empty() else ["plot_a"])
				else:
					var bl := {}
					for k in keys.slice(0, 4):
						var o: PlacedObject = layout.objects[k]
						bl[str(k)] = [o.item_id, o.origin.x, o.origin.y, o.size.x, o.size.y]
					_plan_edit(func(p: Dictionary) -> Dictionary:
						p["baseline"] = {"name": "Real", "objects": bl}
						return p)
		var inc := _snapshot(eng)
		var ref := BudgetEngine.new(layout, db, pb, map)
		ref.recompute_full()
		var full := _snapshot(ref)
		ref.dispose()
		if inc != full:
			mismatches += 1
			if mismatches <= 3:
				for k in full:
					if inc.get(k) != full[k]:
						fail("step %d: %s incremental %s != full %s" % [step, k, str(inc.get(k)), str(full[k])])
						break
		# PlanDoc's primary phases are the reference for membership.
		var pp := PlanDoc.primary_phases(layout, layout.planning)
		var mine := eng.primary_phases()
		if pp != mine:
			mismatches += 1
			fail("step %d: primary phases differ from PlanDoc" % step)
	assert_eq(mismatches, 0, "incremental == full over %d random edits" % steps)
	assert_true(eng.full_recomputes < steps / 2, "most edits were incremental (%d full)" % eng.full_recomputes)
