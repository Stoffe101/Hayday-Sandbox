extends TestCase
## ConflictIndex must always agree with PlacementRules.find_conflicts; the
## cached analysis must never be stale. Randomized over synthetic layouts.


func _same(idx: ConflictIndex, l: FarmLayout, map: FarmMap, msg: String) -> bool:
	var want := PlacementRules.find_conflicts(l, map)
	var got := idx.conflicts()
	var ks: Array = want.keys()
	var kg: Array = got.keys()
	ks.sort()
	kg.sort()
	if ks != kg:
		fail("%s: conflict set differs, expected %s got %s" % [msg, str(ks), str(kg)])
		return false
	for u in want:
		var a: PlacementRules.Result = want[u]
		var b: PlacementRules.Result = got[u]
		if a.ok != b.ok or a.reason_counts != b.reason_counts or a.blocking_uids.keys().size() != b.blocking_uids.keys().size() \
				or a.tiles != b.tiles or a.codes != b.codes or a.locked_plots != b.locked_plots:
			fail("%s: result differs for uid %d" % [msg, u])
			return false
		for k in a.blocking_uids:
			if not b.blocking_uids.has(k):
				fail("%s: blockers differ for uid %d" % [msg, u])
				return false
	return true


func _reports_equal(a: RealisticAnalyzer.Report, b: RealisticAnalyzer.Report) -> bool:
	if a.issues.size() != b.issues.size() or a.required_level != b.required_level or a.plots_needed != b.plots_needed:
		return false
	for u in a.issues:
		if not b.issues.has(u) or str(a.issues[u]) != str(b.issues[u]):
			return false
	return a.blocking_count == b.blocking_count and a.coins_needed == b.coins_needed and a.diamonds_needed == b.diamonds_needed \
		and str(a.shortages) == str(b.shortages) and str(a.land_level_locked) == str(b.land_level_locked) and str(a.over_max) == str(b.over_max)


func _session(db: ItemDatabase, map: FarmMap) -> EditorSession:
	var l := FarmLayout.new()
	l.set_unlocked(["plot_a"], false)
	return EditorSession.new(l, db, map)


func _ids(db: ItemDatabase) -> Array:
	var out: Array = []
	for it: ItemDef in db.ordered:
		if it.can_place():
			out.append(it.id)
	return out


func _random_object(rng: RandomNumberGenerator, db: ItemDatabase, ids: Array, map: FarmMap) -> PlacedObject:
	var it := db.get_item(ids[rng.randi() % ids.size()])
	# Anywhere, including off-map, roads, water, locked land and on other objects.
	return make_obj(it, Vector2i(rng.randi_range(-2, map.size.x + 1), rng.randi_range(-2, map.size.y + 1)), it.flippable and rng.randf() < 0.5)


func test_index_matches_full_scan_after_random_commands() -> void:
	var db := fixture_db()
	var map := fixture_map()
	var ids := _ids(db)
	for seed_value in 8:
		var s := _session(db, map)
		var l := s.layout
		var idx := s.conflict_index
		var rng := RandomNumberGenerator.new()
		rng.seed = 1000 + seed_value
		for i in 30:
			l.add_objects([_random_object(rng, db, ids, map)], false)   # no signal: must still be seen
		assert_true(_same(idx, l, map, "initial %d" % seed_value))
		for step in 400:
			var keys := l.objects.keys()
			var roll := rng.randi() % 9
			match roll:
				0, 1:
					s.execute(EditCommands.AddObjects.new([_random_object(rng, db, ids, map)]))
				2:
					if not keys.is_empty():
						s.execute(EditCommands.RemoveObjects.new([keys[rng.randi() % keys.size()]]))
				3, 4:
					if not keys.is_empty():
						var u: Array = [keys[rng.randi() % keys.size()]]
						s.execute(EditCommands.MoveObjects.new(u, Vector2i(rng.randi_range(-4, 4), rng.randi_range(-4, 4))))
				5:
					if keys.size() > 1:
						var a: int = keys[rng.randi() % keys.size()]
						var o := l.get_obj(a)
						s.execute(EditCommands.SetProperty.new([a], "flipped", [not o.flipped]))
				6:
					var land: Array = [] if rng.randf() < 0.5 else ["plot_a", "plot_b"]
					s.execute(EditCommands.SetLand.new(l.unlocked_plots.keys(), land))
				7:
					s.stack.undo()
				8:
					s.stack.redo()
			if not _same(idx, l, map, "seed %d step %d (op %d)" % [seed_value, step, roll]):
				return


func test_index_rechecks_only_what_an_edit_touches() -> void:
	var db := fixture_db()
	var map := FarmMap.make_simple(100, 100)
	var l := FarmLayout.new()
	var lamp := db.get_item("t_lamp")
	for y in 40:
		for x in 40:
			l.add_objects([make_obj(lamp, Vector2i(x * 2, y * 2))], false)
	var idx := ConflictIndex.new(l, map)
	idx.conflicts()
	var before := idx.rechecks
	assert_eq(idx.full_rebuilds, 1)
	l.move_objects([l.objects.keys()[5]], Vector2i(1, 0))
	idx.conflicts()
	assert_eq(idx.full_rebuilds, 1, "a single move is no rebuild")
	assert_true(idx.rechecks - before <= 3, "rechecked %d objects" % (idx.rechecks - before))


func test_index_reports_neighbour_freed_by_move_and_land_lock() -> void:
	var db := fixture_db()
	var map := fixture_map()
	var l := FarmLayout.new()
	l.set_unlocked(["plot_a"], false)
	var a := make_obj(db.get_item("t_lamp"), Vector2i(2, 2))
	var b := make_obj(db.get_item("t_lamp"), Vector2i(2, 2))
	l.add_objects([a, b], false)
	var idx := ConflictIndex.new(l, map)
	assert_eq(idx.conflicts().size(), 2, "both overlapping")
	l.move_objects([b.uid], Vector2i(1, 0))
	assert_eq(idx.conflicts().size(), 0, "moving one away frees both")
	var p := make_obj(db.get_item("t_lamp"), Vector2i(13, 2))
	l.add_objects([p])
	assert_eq(idx.conflicts().size(), 0, "stands on unlocked land")
	l.set_unlocked([])
	assert_true(idx.conflicts().has(p.uid), "locked land is noticed")
	idx.set_map(FarmMap.make_simple(5, 5))
	assert_true(idx.conflicts().has(p.uid), "off the new map")
	assert_false(idx.conflicts().has(a.uid), "still fine on the new map")


func test_index_notices_land_set_without_a_signal() -> void:
	var db := fixture_db()
	var map := fixture_map()
	var l := FarmLayout.new()
	l.set_unlocked(["plot_a"], false)
	l.add_objects([make_obj(db.get_item("t_lamp"), Vector2i(13, 2))], false)
	var idx := ConflictIndex.new(l, map)
	assert_true(idx.conflicts().is_empty())
	l.set_unlocked([], false)
	assert_eq(idx.conflicts().size(), 1, "no signal, still current")


func test_analyzer_with_conflicts_equals_full_analysis() -> void:
	var db := fixture_db()
	var map := fixture_map()
	var ids := _ids(db)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for k in 12:
		var l := FarmLayout.new()
		l.set_unlocked(["plot_a"], false)
		l.profile["level"] = rng.randi_range(1, 40)
		for i in 40:
			l.add_objects([_random_object(rng, db, ids, map)], false)
		var idx := ConflictIndex.new(l, map)
		var full := RealisticAnalyzer.analyze(l, db, map)
		var fast := RealisticAnalyzer.analyze(l, db, map, idx.conflicts())
		assert_true(_reports_equal(full, fast), "same report, round %d" % k)


func test_cached_analysis_is_never_stale() -> void:
	var db := fixture_db()
	var map := fixture_map()
	var s := _session(db, map)
	var l := s.layout
	var check := func(what: String) -> void:
		assert_true(_reports_equal(s.analysis(), RealisticAnalyzer.analyze(l, db, map)), what)
	check.call("empty")
	s.execute(EditCommands.AddObjects.new([make_obj(db.get_item("t_bakery"), Vector2i(1, 1))]))
	check.call("after add")
	assert_eq(s.analysis().issues.size(), 1, "level-1 bakery reported")
	var hits := s._analysis.computed
	s.analysis()
	s.analysis()
	assert_eq(s._analysis.computed, hits, "no recomputation without a change")
	# profile change
	var p := l.profile.duplicate(true)
	p["level"] = 5
	s.execute(EditCommands.SetProfile.new(l.profile, p))
	check.call("after profile change")
	assert_eq(s.analysis().issues.size(), 0, "bakery no longer locked at level 5")
	# undo / redo
	s.stack.undo()
	check.call("after undo")
	assert_eq(s.analysis().issues.size(), 1)
	s.stack.redo()
	check.call("after redo")
	# profile edited directly, without a signal
	l.profile["level"] = 1
	check.call("after direct profile edit")
	assert_eq(s.analysis().issues.size(), 1)
	# land change: an object on Plot A
	var q := make_obj(db.get_item("t_lamp"), Vector2i(13, 2))
	s.execute(EditCommands.AddObjects.new([q]))
	s.execute(EditCommands.SetLand.new(l.unlocked_plots.keys(), []))
	check.call("after locking land")
	assert_true(RealisticAnalyzer.LOCKED_LAND in s.analysis().issues[q.uid], "land lock noticed")
	# mode change recomputes (result equal, but the cache must not survive it)
	var n := s._analysis.computed
	s.set_mode(FarmLayout.MODE_REALISTIC)
	s.analysis()
	assert_eq(s._analysis.computed, n + 1, "recomputed after a mode change")
	# map change
	var other := FarmMap.make_simple(50, 50)
	s.set_map(other)
	assert_true(_reports_equal(s.analysis(), RealisticAnalyzer.analyze(l, db, other)), "after map change")
	assert_false(RealisticAnalyzer.LOCKED_LAND in s.analysis().issues.get(q.uid, []), "no locked land on the open map")


func test_stack_version_counts_every_change() -> void:
	var db := fixture_db()
	var s := _session(db, fixture_map())
	assert_eq(s.stack.version, 0)
	s.execute(EditCommands.AddObjects.new([make_obj(db.get_item("t_lamp"), Vector2i(1, 1))]))
	assert_eq(s.stack.version, 1)
	s.stack.undo()
	assert_eq(s.stack.version, 2)
	s.stack.redo()
	assert_eq(s.stack.version, 3)
