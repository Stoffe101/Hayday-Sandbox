extends TestCase
## Planning speed-ups must not change any result. Current code is compared
## with reference copies of the pre-W5b implementations
## (tests/fixtures/plan_reference.gd) and cached results with fresh ones, on
## randomized synthetic layouts: Readiness.build and PlanUiModels.checklist
## (rewritten in W5b), Baseline.diff and GuideExport step dictionaries / JSON
## (guards for future rewrites), and the recreation guide built with
## PlanContext's options (engine primary phases, shared compare diff, step
## memo) against a plain build.

const Ref := preload("res://tests/fixtures/plan_reference.gd")
const Budget := preload("res://tests/unit/test_budget.gd")
const Guide := preload("res://tests/unit/test_guide.gd")

var db: ItemDatabase
var pb: PriceBook
var map: FarmMap


func before_each() -> void:
	db = Budget.make_db()
	db.load_file("res://tests/fixtures/planning_items.json")
	db.finalize()
	pb = Budget.make_prices(db)
	map = Guide.guide_map()


func _ids() -> Array:
	var out: Array = []
	for it: ItemDef in db.ordered:
		if it.placeable:
			out.append(it.id)
	out.append("x_not_in_catalogue")
	return out


func _obj(rng: RandomNumberGenerator, ids: Array) -> PlacedObject:
	var id: String = ids[rng.randi() % ids.size()]
	var it := db.get_item(id)
	var o := PlacedObject.new()
	o.item_id = id
	o.size = it.footprint if it != null and it.footprint != Vector2i.ZERO else Vector2i.ONE
	o.origin = Vector2i(rng.randi_range(-1, map.size.x), rng.randi_range(-1, map.size.y))
	o.flipped = it != null and it.flippable and rng.randf() < 0.2
	o.planned = rng.randf() < 0.08
	return o


func _layout(seed_value: int, n: int) -> FarmLayout:
	## Random design with areas, phases, a baseline (unchanged / moved / removed
	## copies), placed marks, inventory and acquired copies.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var ids := _ids()
	var l := FarmLayout.new()
	l.set_unlocked(["plot_a"] if rng.randf() < 0.5 else [], false)
	for i in n:
		l.add_objects([_obj(rng, ids)], false)
	var plan := PlanDoc.empty()
	plan["areas"] = [{"id": "a1", "name": "West", "rect": [0, 0, 12, 20]},
		{"id": "a2", "name": "East", "points": [[12, 0], [30, 0], [30, 14], [16, 20]]}, {"id": "a3", "name": "South", "rect": [0, 18, 30, 12]}]
	plan["phases"] = [{"id": "p1", "name": "One", "areas": ["a2"]}, {"id": "p2", "name": "Two", "areas": ["a1", "a3"]}]
	var bl := {}
	var placed := {}
	var nid := 900000
	for u in l.objects.keys():
		var o: PlacedObject = l.objects[u]
		if o.planned:
			continue
		var r := rng.randf()
		if r < 0.35:
			bl[str(u)] = [o.item_id, o.origin.x, o.origin.y, o.size.x, o.size.y]
		elif r < 0.45:
			bl[str(u)] = [o.item_id, o.origin.x + rng.randi_range(-3, 3), o.origin.y + rng.randi_range(-3, 3), o.size.x, o.size.y]
		elif r < 0.55:
			bl[str(nid)] = [o.item_id, rng.randi() % map.size.x, rng.randi() % map.size.y, o.size.x, o.size.y]
			nid += 1
		if rng.randf() < 0.15:
			placed[str(u)] = [o.origin.x, o.origin.y]
	plan["baseline"] = {"name": "real", "objects": bl, "unlocked_plots": []}
	plan["placed"] = placed
	var owned := {}
	var acquired := {}
	for id: String in ids:
		if rng.randf() < 0.5:
			owned[id] = rng.randi() % 3
		if rng.randf() < 0.2:
			acquired[id] = 1
	plan["acquired"] = acquired
	l.set_planning(PlanDoc.normalize(plan), false)
	l.profile["owned"] = owned
	l.profile["treat_unknown_as_owned"] = rng.randf() < 0.5
	l.mode = FarmLayout.MODE_REALISTIC if rng.randf() < 0.7 else FarmLayout.MODE_CREATIVE
	return l


func test_readiness_equals_reference() -> void:
	for seed_value in 12:
		var l := _layout(300 + seed_value, 60)
		var eng := BudgetEngine.new(l, db, pb, map)
		var conflicts := PlacementRules.find_conflicts(l, map)
		var report := RealisticAnalyzer.analyze(l, db, map, conflicts, eng)
		var nb := {}
		var br := eng.item_breakdown(null, BudgetEngine.MODE_TO_BUY)
		for item: String in br:
			if int((br[item] as Dictionary).get("not_buyable", 0)) > 0:
				nb[item] = int(br[item]["not_buyable"])
		var got := Readiness.build(l, db, conflicts, report, nb)
		var want: Dictionary = Ref.readiness_build(l, db, conflicts, report, nb)
		assert_eq(str(got), str(want), "readiness seed %d" % seed_value)
		assert_true(got == want)
		eng.dispose()


func test_baseline_diff_equals_reference() -> void:
	for seed_value in 12:
		var l := _layout(400 + seed_value, 70)
		var bl: Dictionary = l.planning["baseline"]
		for d: ItemDatabase in [db, null]:
			var got := Baseline.diff(l, bl, d)
			var want: Dictionary = Ref.baseline_diff(l, bl, d)
			assert_eq(str(got), str(want), "diff seed %d" % seed_value)
	# Ties in the reuse pairing (equal distances) are broken the same way.
	var l2 := FarmLayout.new()
	var lamp := db.get_item("t_lamp")
	for x in [2, 4, 6]:
		l2.add_objects([make_obj(lamp, Vector2i(x, 5))], false)
	var bl2 := {"objects": {"77": ["t_lamp", 3, 5, 1, 1], "78": ["t_lamp", 5, 5, 1, 1]}}
	assert_eq(str(Baseline.diff(l2, bl2, db)), str(Ref.baseline_diff(l2, bl2, db)), "tied distances")


func test_checklist_equals_reference() -> void:
	for seed_value in 10:
		var l := _layout(500 + seed_value, 80)
		var eng := BudgetEngine.new(l, db, pb, map)
		var got := PlanUiModels.checklist(eng, l, db, l.planning)
		var want: Dictionary = Ref.checklist(eng, l, db, l.planning)
		assert_eq(str(got), str(want), "checklist seed %d" % seed_value)
		eng.dispose()


func test_guide_json_equals_reference() -> void:
	for seed_value in 6:
		var l := _layout(600 + seed_value, 70)
		var g := RecreationGuide.build(l, map, l.planning, {"db": db})
		for s: Dictionary in g["steps"]:
			var a := GuideExport.step_to_dict(s)
			var b: Dictionary = Ref.step_to_dict(s)
			if str(a) != str(b) or JSON.stringify(a, "\t", false) != JSON.stringify(b, "\t", false):
				fail("step_to_dict differs for step %d (seed %d)" % [int(s["number"]), seed_value])
				return
		# Nested and typed values keep the old conversion.
		var odd := {"r": Rect2i(1, 2, 3, 4), "v": Vector2i(5, 6), "a": [Rect2i(0, 0, 1, 1), [1, "x"], {"k": Vector2(0.5, 1)}],
			"p": PackedStringArray(["a", "b"]), "t": [1, 2.5, true, "s", null]}
		assert_eq(str(GuideExport.step_to_dict(odd)), str(Ref.step_to_dict(odd)))
	assert_true(true)


func _guide_text(g: Dictionary) -> String:
	return GuideExport.to_json(g) + "|" + str(g["steps"]) + "|" + str(g["progress"])


func test_guide_with_context_options_equals_plain_build() -> void:
	## PlanContext.guide() passes the engine's primary phases, the compare diff
	## and a step memo kept between builds; after any edit the guide must equal a
	## build from scratch.
	for seed_value in 4:
		var l := _layout(700 + seed_value, 45)
		var s := EditorSession.new(l, db, map, pb)
		var memo := {}
		var rng := RandomNumberGenerator.new()
		rng.seed = 7700 + seed_value
		var ids := _ids()
		for step in 40:
			var keys := l.objects.keys()
			match rng.randi() % 8:
				0, 1:
					if not keys.is_empty():
						s.execute(EditCommands.MoveObjects.new([keys[rng.randi() % keys.size()]], Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))))
				2:
					s.execute(EditCommands.AddObjects.new([_obj(rng, ids)]))
				3:
					if not keys.is_empty():
						s.execute(EditCommands.RemoveObjects.new([keys[rng.randi() % keys.size()]]))
				4:
					if not keys.is_empty():
						var u: int = keys[rng.randi() % keys.size()]
						s.execute(EditCommands.SetPlanning.new(l.planning, PlanDoc.with_placed(l.planning, l, [u], rng.randf() < 0.7), "Mark"))
				5:
					var p := l.planning.duplicate(true)
					(p["phases"] as Array).reverse()
					s.execute(EditCommands.SetPlanning.new(l.planning, p, "Reorder phases"))
				6:
					var p := l.planning.duplicate(true)
					(p["phases"][0] as Dictionary)["name"] = "Renamed %d" % step
					s.execute(EditCommands.SetPlanning.new(l.planning, p, "Rename phase"))
				7:
					s.stack.undo()
			var bl: Dictionary = l.planning["baseline"]
			var opts := {"db": db, "memo": memo, "primary": s.budget.primary_phases(), "baseline": bl,
				"diff": Baseline.diff(l, bl, db)}
			var got := RecreationGuide.build(l, map, l.planning, opts)
			var want := RecreationGuide.build(l, map, l.planning, {"db": db, "baseline": bl})
			if _guide_text(got) != _guide_text(want):
				fail("guide differs (seed %d, step %d)" % [seed_value, step])
				s.dispose()
				return
		assert_true(not (memo.get("steps", {}) as Dictionary).is_empty(), "the memo is used")
		s.dispose()


func test_guide_memo_follows_world_and_catalogue() -> void:
	var l := _layout(800, 40)
	var memo := {}
	var bl: Dictionary = l.planning["baseline"]
	var a := RecreationGuide.build(l, map, l.planning, {"db": db, "memo": memo})
	# Hide a landmark: directions change, the memo must not answer with the old text.
	l.set_world_value("landmark_visible", "farmhouse", false, false)
	var b := RecreationGuide.build(l, map, l.planning, {"db": db, "memo": memo})
	var fresh := RecreationGuide.build(l, map, l.planning, {"db": db, "baseline": bl})
	assert_eq(_guide_text(b), _guide_text(fresh), "landmark visibility")
	assert_ne(_guide_text(a), _guide_text(b), "the hidden landmark matters here")
	# Another map: memo dropped.
	var m2 := Guide.guide_map()
	var c := RecreationGuide.build(l, m2, l.planning, {"db": db, "memo": memo})
	assert_eq(_guide_text(c), _guide_text(RecreationGuide.build(l, m2, l.planning, {"db": db})), "other map")
