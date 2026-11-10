extends TestCase
## PlanScope: budget scope resolution, scope totals, area overlaps, heatmap
## buckets, targets, number formatting, area drafts and widget placement.
## Synthetic items and prices only (tests/fixtures).

const Budget := preload("res://tests/unit/test_budget.gd")

var db: ItemDatabase
var pb: PriceBook
var layout: FarmLayout
var eng: BudgetEngine


func before_each() -> void:
	db = Budget.make_db()
	pb = Budget.make_prices(db)
	layout = FarmLayout.new()
	eng = BudgetEngine.new(layout, db, pb, fixture_map())


func after_each() -> void:
	eng.dispose()


func _place(id: String, at: Vector2i) -> int:
	return int(layout.add_objects([make_obj(db.get_item(id), at)])[0])


func test_resolve_order_and_pin() -> void:
	var plan := Budget.two_phase_plan()
	var r := PlanScope.resolve([3, 4], "a1", "p1", "auto", plan)
	assert_eq(r["kind"], PlanScope.SCOPE_SELECTION, "the selection wins")
	assert_eq(r["uids"], [3, 4])
	assert_eq(r["label"], "Selection · 2 objects")
	r = PlanScope.resolve([], "a1", "p1", "auto", plan)
	assert_eq([r["kind"], r["id"]], [PlanScope.SCOPE_AREA, "a1"], "then the active area")
	assert_eq(r["label"], "Area · West")
	r = PlanScope.resolve([], "", "p2", "auto", plan)
	assert_eq([r["kind"], r["id"], r["label"]], [PlanScope.SCOPE_PHASE, "p2", "Phase · Second"], "then the active phase")
	r = PlanScope.resolve([], "gone", "gone", "auto", plan)
	assert_eq(r["kind"], PlanScope.SCOPE_FARM, "unknown ids fall back to the farm")
	r = PlanScope.resolve([1], "a1", "p1", "farm", plan)
	assert_eq([r["kind"], r["uids"]], [PlanScope.SCOPE_FARM, null], "pinned: always the whole farm")
	assert_eq(PlanScope.resolve([5], "", "", "auto", plan)["label"], "Selection · 1 object")


func test_scope_totals_match_engine() -> void:
	layout.set_planning(Budget.two_phase_plan())
	var west := _place("t_bakery", Vector2i(1, 1))
	var east := _place("t_long", Vector2i(6, 1))
	_place("t_prize", Vector2i(7, 3))
	var plan := layout.planning
	var mode := BudgetEngine.MODE_DESIGN
	var sel := PlanScope.totals(eng, PlanScope.resolve([west], "", "", "auto", plan), mode)
	assert_eq(sel.cost, {"coins": 50}, "selection = that object's own cost")
	var area := PlanScope.totals(eng, PlanScope.resolve([], "a2", "", "auto", plan), mode)
	assert_eq(area.objects, 2)
	assert_eq(area.not_buyable_objects, 1, "the reward counts as can't be bought, not as 0")
	assert_eq(area.cost, eng.area_totals("a2", mode).cost)
	var ph := PlanScope.totals(eng, PlanScope.resolve([], "", "p1", "auto", plan), mode)
	assert_eq(ph.cost, eng.phase_totals("p1", mode).cost)
	var farm := PlanScope.totals(eng, PlanScope.resolve([], "", "", "farm", plan), mode)
	assert_eq(farm.objects, 3)
	assert_eq(PlanScope.scope_uids(eng, PlanScope.resolve([], "a2", "", "auto", plan)), [east, east + 1])
	assert_null(PlanScope.scope_uids(eng, {"kind": "farm"}))
	assert_eq(PlanScope.unknown_text(area), "1 can't be bought")


func test_shared_objects_and_overlapping_areas() -> void:
	var sh := PlanScope.shared_objects({"a1": [1, 2, 3], "a2": [3, 4], "a3": [5]})
	assert_eq(sh["objects"], 1)
	assert_eq(sh["pairs"], [["a1", "a2", 1]])
	assert_eq(PlanScope.shared_objects({"a": [1], "b": [2]})["objects"], 0, "disjoint areas share nothing")
	var plan := PlanDoc.empty()
	plan["areas"] = [{"id": "a1", "name": "A", "rect": [0, 0, 4, 4]}, {"id": "a2", "name": "B", "rect": [3, 3, 4, 4]},
		{"id": "a3", "name": "C", "rect": [10, 10, 2, 2]},
		{"id": "a4", "name": "Tri", "points": [[4, 0], [8, 0], [8, 2]]}]
	assert_eq(PlanScope.overlapping_areas(PlanDoc.normalize(plan)), [["a1", "a2"]], "bounds touching a polygon's empty corner is no overlap")


func test_heat_buckets() -> void:
	assert_eq(PlanScope.heat_bucket(null, "unknown"), PlanScope.HEAT_UNKNOWN)
	assert_eq(PlanScope.heat_bucket(null, "not_buyable"), PlanScope.HEAT_NOT_BUYABLE)
	assert_eq(PlanScope.heat_bucket({}, "known"), PlanScope.HEAT_NONE, "owned / free: nothing to pay")
	assert_eq(PlanScope.heat_bucket({"coins": 99}, "known"), PlanScope.HEAT_LOW)
	assert_eq(PlanScope.heat_bucket({"coins": 100}, "known"), PlanScope.HEAT_MID)
	assert_eq(PlanScope.heat_bucket({"coins": 9999}, "known"), PlanScope.HEAT_HIGH)
	assert_eq(PlanScope.heat_bucket({"coins": 10000}, "known"), PlanScope.HEAT_TOP)
	assert_eq(PlanScope.heat_bucket({"diamonds": 35}, "known"), PlanScope.HEAT_OTHER, "diamonds are never converted to coins")
	assert_eq(PlanScope.heat_bucket({"coins": 10, "diamonds": 3}, "known"), PlanScope.HEAT_LOW, "the coin part decides when there is one")
	var seen := {}
	for e: Array in PlanScope.HEAT_LEGEND:
		seen[PlanScope.heat_color(int(e[0])).to_html()] = true
	assert_eq(seen.size(), PlanScope.HEAT_LEGEND.size(), "every legend entry has its own colour")


func test_targets_and_ranking() -> void:
	assert_eq(PlanScope.over_target({"coins": 120, "diamonds": 5}, {"coins": 100}), {"coins": 20}, "only named currencies compared")
	assert_eq(PlanScope.over_target({"coins": 80}, {"coins": 100, "diamonds": 0}), {})
	assert_eq(PlanScope.over_target({"coins": 80}, null), {})
	var a := _place("t_bakery", Vector2i(1, 1))
	var b := _place("t_long", Vector2i(5, 1))
	_place("t_prize", Vector2i(8, 1))
	var top := PlanScope.most_expensive(eng, null, BudgetEngine.MODE_DESIGN, 5)
	assert_eq(top.map(func(e): return e["uid"]), [a, b], "known costs only, most coins first")
	assert_eq(PlanScope.most_expensive(eng, [b], BudgetEngine.MODE_DESIGN, 5).size(), 1, "within a scope")


func test_abbreviate() -> void:
	assert_eq(PlanScope.abbreviate(950), "950")
	assert_eq(PlanScope.abbreviate(9999), "9,999")
	assert_eq(PlanScope.abbreviate(12345), "12.3k")
	assert_eq(PlanScope.abbreviate(123456), "123k")
	assert_eq(PlanScope.abbreviate(1234567), "1.23M")
	assert_eq(PlanScope.abbreviate(45600000), "45.6M")
	assert_eq(PlanScope.abbreviate(-12345), "-12.3k")


func test_area_drafts() -> void:
	assert_eq(PlanScope.snap_corner(Vector2(2.4, 3.6)), Vector2i(2, 4))
	assert_eq(PlanScope.rect_area(Rect2i(1, 2, 3, 4), "R")["rect"], [1, 2, 3, 4])
	var pts := [Vector2i(0, 0), Vector2i(0, 0), Vector2i(4, 0), Vector2i(4, 3), Vector2i(0, 0)]
	assert_eq(PlanScope.clean_polygon(pts), [Vector2i(0, 0), Vector2i(4, 0), Vector2i(4, 3)])
	assert_true(PlanScope.polygon_ok(pts))
	assert_false(PlanScope.polygon_ok([Vector2i(0, 0), Vector2i(2, 0), Vector2i(4, 0)]), "collinear corners enclose nothing")
	assert_false(PlanScope.polygon_ok([Vector2i(0, 0), Vector2i(2, 0)]))
	var poly := PlanScope.polygon_area([Vector2i(0, 0), Vector2i(4, 0), Vector2i(4, 3)], "Flower Garden")
	assert_eq(poly["points"], [[0, 0], [4, 0], [4, 3]])
	var plan := PlanDoc.with_area(PlanDoc.empty(), poly)
	assert_eq(PlanDoc.area(plan, "a1")["name"], "Flower Garden", "valid input for PlanDoc")
	assert_eq(PlanScope.next_area_name(plan), "Area 2")
	plan = PlanDoc.with_area(plan, {"name": "Area 2", "rect": [0, 0, 1, 1]})
	assert_eq(PlanScope.next_area_name(plan), "Area 3", "never repeats a name in use")
	assert_eq(PlanScope.next_phase_name(PlanDoc.empty()), "Phase 1")
	var u1 := _place("t_lamp", Vector2i(2, 2))
	var u2 := _place("t_bakery", Vector2i(5, 6))
	var r := PlanScope.selection_rect(layout, [u1, u2, 999])
	assert_eq(r, layout.bounds_of([u1, u2]), "bounding rectangle of the selected footprints")
	assert_eq(PlanScope.selection_rect(layout, [999]), Rect2i())


func test_corner_position() -> void:
	var canvas := Rect2(100, 50, 800, 500)
	var sz := Vector2(200, 40)
	assert_eq(PlanScope.corner_position("bl", canvas, sz, 8.0), Vector2(108, 502))
	assert_eq(PlanScope.corner_position("br", canvas, sz, 8.0), Vector2(692, 502))
	assert_eq(PlanScope.corner_position("tl", canvas, sz, 8.0), Vector2(108, 58))
	assert_eq(PlanScope.corner_position("tr", canvas, sz, 8.0), Vector2(692, 58))
	assert_eq(PlanScope.corner_position("bl", Rect2(0, 0, 150, 30), sz, 8.0), Vector2(0, 0), "kept inside a canvas smaller than the box")
