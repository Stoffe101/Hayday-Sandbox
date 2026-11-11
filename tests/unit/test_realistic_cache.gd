extends TestCase
## The incremental Realistic analysis (RealisticAnalyzer.Cached) must equal a
## fresh RealisticAnalyzer.analyze() field by field after any sequence of edits
## (only the key order of `issues` may differ). Randomized over synthetic
## layouts, with and without a budget engine.

const Budget := preload("res://tests/unit/test_budget.gd")


static func report_diff(a: RealisticAnalyzer.Report, b: RealisticAnalyzer.Report) -> String:
	## "" when equal, else the first differing field.
	if a.issues.size() != b.issues.size():
		return "issues: %d vs %d objects" % [a.issues.size(), b.issues.size()]
	for u in a.issues:
		if not b.issues.has(u):
			return "issues: uid %d missing" % u
		if a.issues[u] != b.issues[u]:
			return "issues of uid %d: %s vs %s" % [u, str(a.issues[u]), str(b.issues[u])]
	var fields := ["required_level", "shortages", "over_max", "level_locked", "level_unknown_items", "plots_needed",
		"required_land_level", "land_level_locked", "land_level_unknown", "unverified", "unknown_items", "planned_count",
		"coins_needed", "diamonds_needed", "unknown_cost_items", "cost_source", "unknown_ownership_types",
		"over_budget_coins", "over_budget_diamonds", "blocking_count"]
	for f: String in fields:
		var va: Variant = a.get(f)
		var vb: Variant = b.get(f)
		if typeof(va) != typeof(vb) or va != vb:
			return "%s: %s vs %s" % [f, str(va), str(vb)]
	if a.can_recreate() != b.can_recreate():
		return "can_recreate"
	return ""


func _random_object(rng: RandomNumberGenerator, db: ItemDatabase, ids: Array, map: FarmMap) -> PlacedObject:
	var id: String = ids[rng.randi() % ids.size()]
	var it := db.get_item(id)
	var o := PlacedObject.new()
	o.item_id = id
	o.size = it.footprint if it != null and it.footprint != Vector2i.ZERO else Vector2i.ONE
	o.origin = Vector2i(rng.randi_range(-2, map.size.x + 1), rng.randi_range(-2, map.size.y + 1))
	o.planned = rng.randf() < 0.12
	return o


func _run(seed_value: int, with_budget: bool, steps: int) -> bool:
	var db := Budget.make_db()
	var pb := Budget.make_prices(db) if with_budget else null
	var map := fixture_map()
	var ids: Array = []
	for it: ItemDef in db.ordered:
		if it.can_place():
			ids.append(it.id)
	ids.append("x_not_in_catalogue")   # unknown item type
	var l := FarmLayout.new()
	l.set_unlocked(["plot_a"], false)
	l.mode = FarmLayout.MODE_REALISTIC
	var rng := RandomNumberGenerator.new()
	rng.seed = 5000 + seed_value
	for i in 25:
		l.add_objects([_random_object(rng, db, ids, map)], false)   # before the session: no signals
	l.profile["owned"] = {"t_lamp": 2, "t_fence": 3}
	l.profile["treat_unknown_as_owned"] = rng.randf() < 0.5
	var s := EditorSession.new(l, db, map, pb)
	var cache: RealisticAnalyzer.Cached = s._analysis
	for step in steps:
		var keys := l.objects.keys()
		var roll := rng.randi() % 14
		match roll:
			0, 1, 2:
				var objs: Array = []
				for k in rng.randi_range(1, 3):
					objs.append(_random_object(rng, db, ids, map))
				s.execute(EditCommands.AddObjects.new(objs))
			3:
				if not keys.is_empty():
					s.execute(EditCommands.RemoveObjects.new([keys[rng.randi() % keys.size()]]))
			4, 5:
				if not keys.is_empty():
					s.execute(EditCommands.MoveObjects.new([keys[rng.randi() % keys.size()]], Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3))))
			6:
				if not keys.is_empty():
					var u: int = keys[rng.randi() % keys.size()]
					s.execute(EditCommands.SetProperty.new([u], "planned", [not l.get_obj(u).planned]))
			7:
				if not keys.is_empty():
					var u: int = keys[rng.randi() % keys.size()]
					s.execute(EditCommands.SetProperty.new([u], "item_id", [ids[rng.randi() % ids.size()]]))
			8:
				var p := l.profile.duplicate(true)
				match rng.randi() % 4:
					0: p["level"] = rng.randi_range(1, 40)
					1: (p["owned"] as Dictionary)[ids[rng.randi() % ids.size()]] = rng.randi_range(0, 4)
					2: p["treat_unknown_as_owned"] = not bool(p.get("treat_unknown_as_owned", true))
					3: p["budget_coins"] = rng.randi_range(0, 3000)
				s.execute(EditCommands.SetProfile.new(l.profile, p))
			9:
				var land: Array = [] if rng.randf() < 0.4 else ["plot_a", "plot_b"]
				s.execute(EditCommands.SetLand.new(l.unlocked_plots.keys(), land))
			10, 11:
				s.stack.undo()
			12:
				s.stack.redo()
			13:
				if keys.size() > 2:
					s.execute(EditCommands.MoveObjects.new([keys[0], keys[1]], Vector2i(1, 0)))
		var got := s.analysis()
		var want := RealisticAnalyzer.analyze(l, db, map, null, s.budget)
		var d := report_diff(got, want)
		if not d.is_empty():
			fail("seed %d (budget %s) step %d op %d: %s" % [seed_value, str(with_budget), step, roll, d])
			return false
	assert_true(cache.full_builds < steps / 4 + 2, "mostly incremental: %d full rebuilds in %d steps" % [cache.full_builds, steps])
	s.dispose()
	return true


func test_incremental_report_equals_fresh_analysis() -> void:
	for seed_value in 6:
		if not _run(seed_value, false, 220):
			return


func test_incremental_report_equals_fresh_analysis_with_budget() -> void:
	for seed_value in 4:
		if not _run(100 + seed_value, true, 160):
			return


func test_single_edit_is_not_a_full_rebuild() -> void:
	var db := fixture_db()
	var map := FarmMap.make_simple(80, 80)
	var l := FarmLayout.new()
	l.mode = FarmLayout.MODE_REALISTIC
	var lamp := db.get_item("t_lamp")
	for y in 20:
		for x in 20:
			l.add_objects([make_obj(lamp, Vector2i(x * 2, y * 2))], false)
	var s := EditorSession.new(l, db, map)
	var c: RealisticAnalyzer.Cached = s._analysis
	s.analysis()
	assert_eq(c.full_builds, 1)
	s.execute(EditCommands.MoveObjects.new([l.objects.keys()[3]], Vector2i(1, 0)))
	var r := s.analysis()
	assert_eq(c.full_builds, 1, "a move updates the state in place")
	assert_eq(report_diff(r, RealisticAnalyzer.analyze(l, db, map)), "")
	s.execute(EditCommands.AddObjects.new([make_obj(lamp, Vector2i(1, 1))]))
	assert_eq(report_diff(s.analysis(), RealisticAnalyzer.analyze(l, db, map)), "", "after an add")
	s.stack.undo()
	s.stack.undo()
	assert_eq(report_diff(s.analysis(), RealisticAnalyzer.analyze(l, db, map)), "", "after undo")
	assert_eq(c.full_builds, 1)
	# An earlier report is not changed by later edits (reports are shared, read-only).
	var before := s.analysis()
	var n := before.issues.size()
	s.execute(EditCommands.AddObjects.new([make_obj(lamp, Vector2i(1, 1))]))
	s.analysis()
	assert_eq(before.issues.size(), n, "old report kept")
	# The non-incremental path is the reference.
	c.incremental = false
	s.execute(EditCommands.MoveObjects.new([l.objects.keys()[7]], Vector2i(0, 1)))
	assert_eq(report_diff(s.analysis(), RealisticAnalyzer.analyze(l, db, map)), "")
