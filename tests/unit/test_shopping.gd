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
