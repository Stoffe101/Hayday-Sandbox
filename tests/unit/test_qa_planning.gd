extends TestCase
## QA regressions for the planning layer (docs/PLANNING.md): bugs found while
## playing the planning journeys, pinned with the smallest pure reproduction.
## Synthetic items and prices only (tests/fixtures).

const TO_BUY := BudgetEngine.MODE_TO_BUY
const REMAINING := BudgetEngine.MODE_REMAINING
const DESIGN := BudgetEngine.MODE_DESIGN
const Budget := preload("res://tests/unit/test_budget.gd")
const Guide := preload("res://tests/unit/test_guide.gd")

var db: ItemDatabase
var pb: PriceBook
var map: FarmMap
var layout: FarmLayout
var eng: BudgetEngine


func before_each() -> void:
	db = Budget.make_db()
	pb = Budget.make_prices(db)
	map = fixture_map()
	layout = FarmLayout.new()
	eng = BudgetEngine.new(layout, db, pb, map)


func after_each() -> void:
	eng.dispose()


func _place(id: String, at: Vector2i) -> int:
	return int(layout.add_objects([make_obj(db.get_item(id), at)])[0])


func _coins(t: BudgetEngine.Totals) -> int:
	return int(t.cost.get("coins", 0))


static func parse_csv(text: String) -> Array:
	## Minimal RFC 4180 reader (quoted fields, doubled quotes, commas and newlines inside quotes).
	var rows: Array = []
	var row: Array = []
	var field := ""
	var quoted := false
	var i := 0
	while i < text.length():
		var ch := text[i]
		if quoted:
			if ch == "\"":
				if i + 1 < text.length() and text[i + 1] == "\"":
					field += "\""
					i += 1
				else:
					quoted = false
			else:
				field += ch
		elif ch == "\"":
			quoted = true
		elif ch == ",":
			row.append(field)
			field = ""
		elif ch == "\n":
			row.append(field)
			rows.append(row)
			row = []
			field = ""
		elif ch != "\r":
			field += ch
		i += 1
	if not field.is_empty() or not row.is_empty():
		row.append(field)
		rows.append(row)
	return rows


# --- rotating a baseline object in place is a move, not "still placed" -----------------------

func test_rotated_baseline_object_is_not_counted_as_placed() -> void:
	var u := _place("t_long", Vector2i(2, 2))          # 1 × 4, flippable
	var v := _place("t_long", Vector2i(6, 2))
	layout.set_planning(PlanDoc.with_baseline(layout.planning, Baseline.snapshot(layout, "Real", "real", "t")))
	assert_true(eng.is_placed(u) and eng.is_placed(v), "unchanged baseline objects count as placed")
	EditCommands.SetProperty.new([u], "flipped", [true], "Rotate").do(layout)   # same origin, 4 × 1 now
	var d := Baseline.diff(layout, layout.planning["baseline"], db)
	assert_eq(d["status"][u], "moved", "the comparison calls a rotation a move")
	assert_false(eng.is_placed(u), "…so the checklist must not count it as still standing there")
	assert_true(eng.is_placed(v))
	assert_false(PlanUiModels.placed_uids(layout, layout.planning, db).has(u), "same rule in the UI model")
	assert_false(eng.placed_set().has(u))
	eng.recompute_full()
	assert_false(eng.is_placed(u), "full recompute agrees with the incremental path")
	EditCommands.SetProperty.new([u], "flipped", [false], "Rotate back").do(layout)
	assert_true(eng.is_placed(u), "rotated back: unchanged again")
	assert_eq(BudgetEngine.same_spot(["t_long", 2, 2], layout.get_obj(u)), true, "old 3-element records compare the origin only")


# --- Baseline.diff resolves item aliases on both sides -----------------------------------

func test_baseline_diff_matches_objects_saved_under_an_alias() -> void:
	var o := make_obj(db.get_item("t_fence"), Vector2i(4, 4))
	o.item_id = "old_fence"   # an object from an older file, saved under the alias
	var u: int = layout.add_objects([o])[0]
	var plan := PlanDoc.with_baseline(PlanDoc.empty(), Baseline.snapshot(layout, "Real", "real", "t"))
	var d := Baseline.diff(layout, plan["baseline"], db)
	assert_eq(d["unchanged"], [u], "same uid, same item (alias resolved): unchanged, not removed + new")
	assert_true((d["removed"] as Array).is_empty() and (d["new"] as Array).is_empty())
	assert_true((d["items"] as Dictionary).has("t_fence") and not (d["items"] as Dictionary).has("old_fence"), "counted under the catalogue id")
	layout.set_planning(plan)
	assert_true(eng.is_placed(u), "the engine agrees (it resolves aliases too)")


# --- areas that share objects without sharing a tile ---------------------------------------

func test_overlap_notice_for_objects_standing_across_two_areas() -> void:
	var plan := PlanDoc.empty()
	plan = PlanDoc.with_area(plan, {"name": "West", "rect": [0, 0, 3, 4]})
	plan = PlanDoc.with_area(plan, {"name": "East", "rect": [3, 0, 3, 4]})
	assert_true(PlanScope.overlapping_areas(plan).is_empty(), "the shapes don't share a tile")
	layout.set_planning(plan)
	var u := _place("t_long", Vector2i(1, 1))
	EditCommands.SetProperty.new([u], "flipped", [true], "Rotate").do(layout)   # 4 × 1 across x = 1..4
	var per := {"a1": eng.area_uids("a1"), "a2": eng.area_uids("a2")}
	assert_eq(per["a1"], [u])
	assert_eq(per["a2"], [u], "the object stands in both areas")
	var txt := PlanScope.overlap_notice(plan, per)
	assert_true(txt.contains("West + East") and txt.contains("1 object count in more than one area") and txt.contains("not additive"),
		"the Areas tab warns although the shapes don't overlap: %s" % txt)
	assert_eq(_coins(eng.area_totals("a1", DESIGN)) + _coins(eng.area_totals("a2", DESIGN)), 2 * _coins(eng.totals(null, DESIGN)),
		"(why it matters: the object is in both area totals)")
	layout.move_objects([u], Vector2i(0, 5))
	per = {"a1": eng.area_uids("a1"), "a2": eng.area_uids("a2")}
	assert_eq(PlanScope.overlap_notice(plan, per), "", "no shared tile, no shared object: no notice")
	var over := PlanDoc.with_area(plan, {"name": "Middle", "rect": [2, 0, 2, 2]})
	assert_true(PlanScope.overlap_notice(over, per).begins_with("Overlapping areas: "), "shapes sharing tiles still say so")


# --- guide: break a cycle by storing a cycle member, not one waiting behind it ----------------

func test_cycle_break_stores_only_a_member_of_the_cycle() -> void:
	var gdb := Guide.fixture_db()
	gdb.load_file("res://tests/fixtures/planning_items.json")
	gdb.finalize()
	var gmap := Guide.guide_map()
	var l := FarmLayout.new()
	var x: int = l.add_objects([make_obj(gdb.get_item("g_bench"), Vector2i(0, 0))])[0]    # 1 × 2: (0,0) (0,1)
	var y: int = l.add_objects([make_obj(gdb.get_item("g_apple"), Vector2i(5, 5))])[0]
	var z: int = l.add_objects([make_obj(gdb.get_item("g_rose"), Vector2i(15, 15))])[0]
	var plan := PlanDoc.with_baseline(PlanDoc.empty(), Baseline.snapshot(l, "", "", "t"))
	l.set_object_rect(y, Vector2i(0, 1), Vector2i.ONE)       # apple onto the bench's lower tile
	l.set_object_rect(z, Vector2i(0, 0), Vector2i.ONE)       # rose onto its upper tile (sorts first)
	l.set_object_rect(x, Vector2i(5, 4), Vector2i(1, 2))     # bench onto the apple's old tile: apple <-> bench cycle
	var g := RecreationGuide.build(l, gmap, plan, {"db": gdb})
	var titles: Array = []
	var kinds: Array = []
	for s: Dictionary in g["steps"]:
		titles.append(str(s["title"]))
		kinds.append(str(s["kind"]))
	assert_eq(kinds.count("store_temp"), 1, "one temporary storage breaks the cycle: %s" % str(titles))
	assert_eq(titles, ["Put Test Apple Tree in storage for now", "Move Test Bench", "Move Test Rose", "Place Test Apple Tree from storage"],
		"the rose only waits for the bench: it is moved, never stored")
	assert_eq(g["steps"][0]["then_step"], 4)


# --- unknown prices are never 0 in totals, rows, exports and the heatmap ---------------------

func test_unknown_prices_stay_unknown_everywhere() -> void:
	var fences: Array = []
	for i in 4:
		fences.append(_place("t_fence", Vector2i(i, 0)))   # schedule of 3 prices, no repeat: copy #4 unknown
	var m := _place("t_mystery", Vector2i(0, 4))           # no price information at all
	var prize := _place("t_prize", Vector2i(4, 4))         # reward: can't be bought
	for mode in [DESIGN, TO_BUY, REMAINING]:
		var t := eng.totals(null, mode)
		assert_eq(_coins(t), 21, mode + ": only the known copies are summed")
		assert_eq(t.unknown_price_objects, 2, mode + ": fence #4 and the statue are unknown")
		assert_eq(t.not_buyable_objects, 1, mode)
		assert_false(t.is_exact(), mode + ": the total is a lower bound")
	assert_eq(eng.object_cost(fences[3], TO_BUY), null, "copy #4 has no price (not 0)")
	assert_eq(PlanScope.heat_bucket(eng.object_cost(m, TO_BUY), str(eng.object_info(m)["price_state"])), PlanScope.HEAT_UNKNOWN)
	assert_eq(PlanScope.heat_bucket(eng.object_cost(prize, TO_BUY), str(eng.object_info(prize)["price_state"])), PlanScope.HEAT_NOT_BUYABLE)
	assert_ne(PlanScope.heat_bucket(eng.object_cost(fences[3], TO_BUY), "unknown"), PlanScope.HEAT_NONE, "never the 'nothing to pay' bucket")
	var rows := ShoppingList.build(eng, null, TO_BUY)
	var fr: Dictionary = {}
	var mr: Dictionary = {}
	for r: Dictionary in rows:
		if r["item"] == "t_fence":
			fr = r
		elif r["item"] == "t_mystery":
			mr = r
	assert_eq(int(fr["total"].get("coins", 0)), 21)
	assert_eq(int(fr["unknown_copies"]), 1)
	assert_eq(fr["price_max"], null, "the last copy's price is unknown")
	assert_true(PlanUiModels.row_price_text(fr).contains("price unknown"), PlanUiModels.row_price_text(fr))
	assert_true(PlanUiModels.row_total_text(fr).contains("1 with unknown price"), PlanUiModels.row_total_text(fr))
	assert_eq(PlanUiModels.row_price_text(mr), "Price unknown")
	var csv := parse_csv(PlanUiModels.shop_csv(rows))
	var head: Array = csv[0]
	var by_item := {}
	for i in range(1, csv.size()):
		assert_eq((csv[i] as Array).size(), head.size(), "every CSV row has every column")
		by_item[csv[i][head.find("item_id")]] = csv[i]
	assert_eq(by_item["t_mystery"][head.find("next_price")], "unknown")
	assert_eq(by_item["t_mystery"][head.find("unknown_price_copies")], "1")
	assert_ne(by_item["t_mystery"][head.find("known_total")], "0", "an unknown total is never written as 0")
	assert_eq(by_item["t_fence"][head.find("unknown_price_copies")], "1")
	var txt := PlanUiModels.totals_text(eng.totals(null, TO_BUY).to_dict())
	assert_true(txt.contains("2 items have unknown prices") and txt.contains("can't be bought"), txt)


# --- inventory: "add bought items" keeps purchase numbers and never double counts --------------

func test_bought_into_inventory_keeps_progressive_numbers() -> void:
	var p := layout.profile.duplicate(true)
	p["owned"] = {"t_long": 1}
	p["purchased"] = {"t_long": 4}   # bought 4 over the years, 1 left
	layout.profile = p
	layout.planning_changed.emit()
	for i in 6:
		_place("t_long", Vector2i(i, 0))
	# owned 1; purchase numbers start after 4: #5..#9 = 30, 35, 40, 45, 50
	assert_eq(_coins(eng.totals(null, TO_BUY)), 200)
	layout.set_planning(PlanDoc.with_acquired(layout.planning, "t_long", 2))
	assert_eq(_coins(eng.totals(null, REMAINING)), 135, "two bought (#5, #6): #7..#9 remain")
	assert_eq(_coins(eng.totals(null, TO_BUY)), 200, "To buy still shows the purchases")
	var res := ShoppingList.apply_acquired_to_inventory(layout.profile, layout.planning)
	layout.profile = res["profile"]
	layout.set_planning(res["plan"])
	assert_eq(int(layout.profile["owned"]["t_long"]), 3)
	assert_eq(int(layout.profile["purchased"]["t_long"]), 6, "purchase count moves on with the copies")
	assert_eq(_coins(eng.totals(null, REMAINING)), 135, "nothing counted twice after moving them into the inventory")
	assert_eq(_coins(eng.totals(null, TO_BUY)), 135)
	assert_eq(_coins(eng.totals(null, DESIGN)), 10 + 15 + 20 + 25 + 30 + 35, "design cost never depends on the inventory")


# --- guide CSV export parses back with every column ---------------------------------------

func test_guide_csv_round_trips_awkward_names() -> void:
	db.add_item(ItemDef.from_dict({"id": "q_comma", "name": "Bench, \"Big\"\nTwo lines", "category": "decoration",
		"footprint": [1, 1], "footprint_status": "confirmed"}, []))
	db.finalize()
	_place("q_comma", Vector2i(2, 2))
	_place("t_fence", Vector2i(5, 5))
	var g := RecreationGuide.build(layout, map, layout.planning, {"db": db})
	var rows := parse_csv(GuideExport.to_csv(g, {"title": "QA, \"farm\""}))
	assert_eq((rows[0] as Array), GuideExport.CSV_COLUMNS)
	assert_eq(rows.size(), (g["steps"] as Array).size() + 1)
	var titles: Array = []
	for i in range(1, rows.size()):
		assert_eq((rows[i] as Array).size(), GuideExport.CSV_COLUMNS.size(), "row %d keeps every column" % i)
		titles.append(rows[i][GuideExport.CSV_COLUMNS.find("title")])
	assert_true("Place Bench, \"Big\"\nTwo lines" in titles, str(titles))
	var js: Variant = JSON.parse_string(GuideExport.to_json(g, {"title": "QA"}))
	assert_true(js is Dictionary and (js["steps"] as Array).size() == (g["steps"] as Array).size())
	var html := GuideExport.to_html(g, {"title": "<QA & farm>", "overview_image": "../../etc/x.png"})
	assert_true(html.contains("&lt;QA &amp; farm&gt;") and not html.contains("<QA & farm>"), "the title is escaped")
	assert_false(html.contains("etc/x.png"), "a picture path leaving the folder is not embedded")
	assert_eq(html.count("<li class=\"step"), (g["steps"] as Array).size())


# --- Realistic "Can I build this?" costs agree with the budget ----------------------------

func test_realistic_costs_follow_the_budget_engine() -> void:
	var p := layout.profile.duplicate(true)
	p["owned"] = {"t_long": 0}
	p["budget_coins"] = 200
	layout.profile = p
	layout.planning_changed.emit()
	for i in 3:
		_place("t_long", Vector2i(i, 0))
	var old := RealisticAnalyzer.analyze(layout, db, map)
	assert_eq(old.cost_source, "catalogue")
	assert_eq(old.coins_needed, 30, "without a budget: the catalogue's flat 10 coins × 3 (the old rule, kept for pure callers)")
	var r := RealisticAnalyzer.analyze(layout, db, map, null, eng)
	assert_eq(r.cost_source, "budget")
	assert_eq(r.coins_needed, _coins(eng.totals(null, TO_BUY)), "same figure as the budget chip")
	assert_eq(r.coins_needed, 45, "price file with its rising price: 10 + 15 + 20")
	assert_eq(int(r.shortages[0]["coins"]), 45)
	assert_false(r.over_budget_coins)
	pb.set_override("t_long", {"price": {"coins": 100}})
	r = RealisticAnalyzer.analyze(layout, db, map, null, eng)
	assert_eq(r.coins_needed, 300, "the user's price override reaches the Realistic verdict")
	assert_true(r.over_budget_coins and not r.can_recreate(), "over the 200-coin budget")
	pb.remove_override("t_long")
	# Unknown prices stay out of the figure and are listed; unknown ownership is listed too.
	_place("t_mystery", Vector2i(0, 6))
	r = RealisticAnalyzer.analyze(layout, db, map, null, eng)
	assert_eq(r.coins_needed, 45)
	assert_true("t_mystery" in r.unknown_cost_items and "t_mystery" in r.unknown_ownership_types)
	# The session cache follows price changes (the budget's version is part of its key).
	var stack := CommandStack.new(layout)
	var cached := RealisticAnalyzer.Cached.new(layout, stack)
	cached.budget = eng
	assert_eq(cached.report(db, map).coins_needed, 45)
	pb.set_override("t_long", {"price": {"coins": 1}})
	assert_eq(cached.report(db, map).coins_needed, 3, "a price edit (no layout edit) refreshes the cached report")


# --- exports never go into the program folder ----------------------------------------------

func test_program_folder_paths_are_refused() -> void:
	assert_true(PlanUiKit.is_inside_repo("res://artifacts/x.png"), "res:// paths are the program folder")
	assert_true(PlanUiKit.is_inside_repo(ProjectSettings.globalize_path("res://docs/x.png")))
	assert_false(PlanUiKit.is_inside_repo(ProjectSettings.globalize_path("user://x.png")))
	assert_true(PlanUiKit.write_text("res://qa_should_not_exist.txt", "x").begins_with("Choose a folder"))
	assert_false(FileAccess.file_exists("res://qa_should_not_exist.txt"))


func test_csv_text_cells_never_start_a_formula() -> void:
	assert_eq(GuideExport.csv_text_guard("=HYPERLINK(1)"), "'=HYPERLINK(1)")
	assert_eq(GuideExport.csv_text_guard("@SUM"), "'@SUM")
	assert_eq(GuideExport.csv_text_guard("+cmd"), "'+cmd")
	assert_eq(GuideExport.csv_text_guard("-5"), "-5", "numbers stay numbers")
	assert_eq(GuideExport.csv_text_guard("White Fence"), "White Fence")
	assert_eq(PlanUiModels.csv_field("=1+1"), "'=1+1")
