extends TestCase
## PlanDoc: normalisation, areas / phases, membership, primary phase, edits.

var db: ItemDatabase
var layout: FarmLayout


func before_each() -> void:
	db = fixture_db()
	layout = FarmLayout.new()


func _place(id: String, at: Vector2i) -> int:
	return int(layout.add_objects([make_obj(db.get_item(id), at)])[0])


func test_empty_and_normalize_keep_unknown_keys() -> void:
	assert_true(PlanDoc.is_empty_plan(PlanDoc.empty()))
	var n := PlanDoc.normalize({"areas": [{"id": "a1", "name": "A", "rect": [0, 0, 2, 2], "future": 1},
		{"id": "a1", "rect": [1, 1, 1, 1]}, {"id": "bad"}, "junk"],
		"phases": [{"id": "p7", "name": "P", "areas": ["a1", 3]}],
		"assign": {"5": "p7", "x": "p7"}, "placed": {"5": [1, 2], "6": "no"}, "acquired": {"t_lamp": 2, "t_long": 0},
		"steps_done": {"place-abc": true, "x": 1}, "plugin": {"keep": [1, 2]}, "next_id": 2})
	assert_eq((n["areas"] as Array).size(), 1, "duplicate id and shapeless area dropped")
	assert_eq(n["areas"][0]["future"], 1, "unknown area fields kept")
	assert_eq(n["phases"][0]["areas"], ["a1", "3"])
	assert_eq(n["assign"], {"5": "p7"})
	assert_eq(n["placed"], {"5": [1, 2]})
	assert_eq(n["acquired"], {"t_lamp": 2})
	assert_eq(n["steps_done"], {"place-abc": true})
	assert_eq(n["plugin"], {"keep": [1, 2]}, "unknown top-level planning keys kept")
	assert_eq(int(n["next_id"]), 8, "next id above every used number")
	assert_eq(PlanDoc.normalize(n), n, "idempotent")
	assert_eq(PlanDoc.normalize("junk"), PlanDoc.empty())


func test_areas_phases_and_primary_phase() -> void:
	var lamp := _place("t_lamp", Vector2i(1, 1))
	var bakery := _place("t_bakery", Vector2i(5, 5))
	var lone := _place("t_lamp", Vector2i(15, 15))
	var p := PlanDoc.empty()
	p = PlanDoc.with_area(p, {"name": "North", "rect": [0, 0, 3, 3]})
	p = PlanDoc.with_area(p, {"name": "Tri", "points": [[4, 4], [10, 4], [4, 10]]})
	assert_eq(PlanDoc.areas(p).size(), 2)
	var a1 := str(PlanDoc.areas(p)[0]["id"])
	var a2 := str(PlanDoc.areas(p)[1]["id"])
	assert_eq(PlanDoc.objects_in_area(layout, PlanDoc.area(p, a1)), [lamp])
	assert_eq(PlanDoc.objects_in_area(layout, PlanDoc.area(p, a2)), [bakery], "polygon contains a footprint tile centre")
	p = PlanDoc.with_phase(p, {"name": "One", "areas": [a2]})
	p = PlanDoc.with_phase(p, {"name": "Two", "areas": [a1, a2]})
	var p1 := str(PlanDoc.phases(p)[0]["id"])
	var p2 := str(PlanDoc.phases(p)[1]["id"])
	var prim := PlanDoc.primary_phases(layout, p)
	assert_eq(prim[bakery], p1, "first phase in build order wins")
	assert_eq(prim[lamp], p2)
	assert_eq(prim[lone], PlanDoc.UNPHASED)
	p = PlanDoc.with_phase_moved(p, p2, 0)
	assert_eq(PlanDoc.primary_phases(layout, p)[bakery], p2, "reordering phases changes the primary phase")
	p = PlanDoc.with_assignment(p, [lone], p1)
	assert_eq(PlanDoc.primary_phases(layout, p)[lone], p1, "manual assignment wins")
	assert_eq(PlanDoc.area_phase_for_rect(p, Rect2i(1, 1, 1, 1)), p2)
	assert_eq(PlanDoc.area_phase_for_rect(p, Rect2i(15, 15, 1, 1)), PlanDoc.UNPHASED, "area rule only, no assignment")
	p = PlanDoc.without_phase(p, p1)
	assert_false((p["assign"] as Dictionary).has(str(lone)), "assignments to a removed phase are dropped")
	p = PlanDoc.without_area(p, a1)
	assert_eq(PlanDoc.phases(p)[0]["areas"], [a2])


func test_placed_baseline_and_step_ticks() -> void:
	var lamp := _place("t_lamp", Vector2i(3, 4))
	var p := PlanDoc.with_placed(PlanDoc.empty(), layout, [lamp], true)
	assert_true(PlanDoc.is_placed(p, lamp))
	assert_eq(p["placed"][str(lamp)], [3, 4])
	var base := Baseline.snapshot(layout, "Real", "src", "2026-11-10T00:00:00Z")
	var pb := PlanDoc.with_baseline(p, base)
	assert_eq(pb["baseline"], base)
	assert_false(PlanDoc.is_empty_plan(pb))
	assert_false(PlanDoc.with_baseline(pb, {}).has("baseline"))
	var t := PlanDoc.with_step_done(p, "move-123", true)
	assert_true(PlanDoc.is_step_done(t, "move-123"))
	assert_false(PlanDoc.is_step_done(p, "move-123"), "edits return copies")
	assert_false(PlanDoc.with_step_done(t, "move-123", false).has("steps_done"))
	var gone := PlanDoc.without_objects(p, [lamp])
	assert_false(PlanDoc.is_placed(gone, lamp))
