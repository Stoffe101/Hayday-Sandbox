extends TestCase
## Farm level (Realistic = "my farm at level N") vs Creative sandbox: catalogue
## level filter, placement block, plot level requirements and the analyzer's
## land checks. Synthetic fixtures only (no game data).

var db: ItemDatabase


func before_each() -> void:
	db = ItemDatabase.new()
	for d in [
		{"id": "l_early", "name": "Early", "category": "decoration", "footprint": [1, 1], "unlock_level": 5},
		{"id": "l_mid", "name": "Mid", "category": "decoration", "footprint": [1, 1], "unlock_level": 60},
		{"id": "l_late", "name": "Late", "category": "decoration", "footprint": [2, 2], "unlock_level": 72},
		{"id": "l_unknown", "name": "Unknown", "category": "decoration", "footprint": [1, 1]},
		{"id": "l_zero", "name": "Zero", "category": "decoration", "footprint": [1, 1], "unlock_level": 0},
	]:
		var errs: Array = []
		var it := ItemDef.from_dict(d, errs)
		assert_true(errs.is_empty(), "fixture item %s parses: %s" % [d["id"], str(errs)])
		db.add_item(it)
	db.finalize()


func _items() -> Array:
	return db.search("", {}, "level")


static func _ids(items: Array) -> Array:
	var out: Array = []
	for it: ItemDef in items:
		out.append(it.id)
	return out


func _map() -> FarmMap:
	return FarmMap.from_data({"format": "hayday-sandbox-map", "schema_version": 2, "id": "lv_map", "name": "Level map",
		"frame": "game", "size": [30, 10],
		"regions": [
			{"id": "start", "kind": "buildable", "rects": [[0, 0, 10, 10]]},
			{"id": "p_low", "kind": "plot", "name": "Low", "number": 1, "rects": [[10, 0, 5, 10]], "min_level": 10, "aliases": ["exp_101"]},
			{"id": "p_high", "kind": "plot", "name": "High", "number": 2, "rects": [[15, 0, 5, 10]], "min_level": 45},
			{"id": "p_unknown", "kind": "plot", "name": "Unknown", "number": 3, "rects": [[20, 0, 5, 10]]},
			{"id": "p_bad", "kind": "plot", "name": "Bad level", "number": 4, "rects": [[25, 0, 5, 10]], "min_level": 0},
		]})


# --- items -------------------------------------------------------------------

func test_level_state_never_guesses() -> void:
	assert_eq(RealisticAnalyzer.level_state(db.get_item("l_early"), 60), RealisticAnalyzer.AVAILABLE)
	assert_eq(RealisticAnalyzer.level_state(db.get_item("l_mid"), 60), RealisticAnalyzer.AVAILABLE, "unlock level == farm level is unlocked")
	assert_eq(RealisticAnalyzer.level_state(db.get_item("l_late"), 60), RealisticAnalyzer.ABOVE_LEVEL)
	assert_eq(RealisticAnalyzer.level_state(db.get_item("l_unknown"), 60), RealisticAnalyzer.LEVEL_UNKNOWN)
	assert_eq(RealisticAnalyzer.level_state(db.get_item("l_zero"), 60), RealisticAnalyzer.LEVEL_UNKNOWN, "unset (0) levels are unknown, not 'level 0'")
	assert_eq(RealisticAnalyzer.level_state(db.get_item("l_unknown"), 1), RealisticAnalyzer.LEVEL_UNKNOWN, "unknown stays unknown at any level")
	assert_eq(RealisticAnalyzer.level_state(null, 60), RealisticAnalyzer.LEVEL_UNKNOWN)


func test_creative_is_the_full_sandbox() -> void:
	for it: ItemDef in _items():
		assert_eq(RealisticAnalyzer.mode_level_state(it, FarmLayout.MODE_CREATIVE, 1), RealisticAnalyzer.AVAILABLE, "%s available in Creative" % it.id)
		assert_eq(RealisticAnalyzer.item_level_block(it, FarmLayout.MODE_CREATIVE, 1), "", "%s placeable in Creative" % it.id)
	var f := RealisticAnalyzer.filter_by_level(_items(), FarmLayout.MODE_CREATIVE, 1, false)
	assert_eq(f["items"].size(), 5, "Creative lists everything")
	assert_eq(f["unlocked"], 5)
	assert_eq(f["locked"], 0)


func test_realistic_filter_default_hides_locked_keeps_unknown() -> void:
	var f := RealisticAnalyzer.filter_by_level(_items(), FarmLayout.MODE_REALISTIC, 60, false)
	var ids := _ids(f["items"])
	assert_has(ids, "l_early")
	assert_has(ids, "l_mid")
	assert_has(ids, "l_unknown", "unknown unlock level stays visible")
	assert_has(ids, "l_zero")
	assert_false("l_late" in ids, "level 72 item hidden at level 60")
	assert_eq(f["total"], 5)
	assert_eq(f["unlocked"], 2)
	assert_eq(f["unknown"], 2)
	assert_eq(f["locked"], 1)


func test_realistic_filter_show_locked_keeps_order_and_counts() -> void:
	var items := _items()
	var f := RealisticAnalyzer.filter_by_level(items, FarmLayout.MODE_REALISTIC, 60, true)
	assert_eq(_ids(f["items"]), _ids(items), "show locked lists every item in the original order")
	assert_eq(f["locked"], 1, "counts don't depend on the toggle")
	assert_eq(f["unlocked"], 2)
	var low := RealisticAnalyzer.filter_by_level(items, FarmLayout.MODE_REALISTIC, 1, false)
	assert_eq(_ids(low["items"]), ["l_zero", "l_unknown"], "level 1 shows only unknown-level items (search order kept)")
	assert_eq(low["locked"], 3)


func test_item_level_block_message() -> void:
	var late := db.get_item("l_late")
	var why := RealisticAnalyzer.item_level_block(late, FarmLayout.MODE_REALISTIC, 60)
	assert_has(why, "level 72")
	assert_has(why, "level 60")
	assert_has(why, "Creative")
	assert_eq(RealisticAnalyzer.item_level_block(late, FarmLayout.MODE_REALISTIC, 72), "", "unlocked once the farm reaches its level")
	assert_eq(RealisticAnalyzer.item_level_block(db.get_item("l_unknown"), FarmLayout.MODE_REALISTIC, 1), "", "unknown levels never block")


func test_farm_level_reads_profile() -> void:
	var l := FarmLayout.new()
	l.profile["level"] = 60
	assert_eq(RealisticAnalyzer.farm_level(l), 60)
	l.profile["level"] = 0
	assert_eq(RealisticAnalyzer.farm_level(l), 1, "never below 1")
	l.profile.erase("level")
	assert_eq(RealisticAnalyzer.farm_level(l), 1)
	assert_eq(RealisticAnalyzer.farm_level(null), 1)


func test_level_change_is_undoable_and_keeps_objects() -> void:
	var l := FarmLayout.new()
	l.profile["level"] = 10
	l.add_objects([make_obj(db.get_item("l_late"), Vector2i(1, 1))])
	var before := JSON.stringify(LayoutIO.to_dict(l)["objects"])
	var stack := CommandStack.new(l)
	var p := l.profile.duplicate(true)
	p["level"] = 60
	stack.execute(EditCommands.SetProfile.new(l.profile, p, "Set farm level"))
	assert_eq(RealisticAnalyzer.farm_level(l), 60)
	l.mode = FarmLayout.MODE_REALISTIC
	assert_eq(JSON.stringify(LayoutIO.to_dict(l)["objects"]), before, "level/mode changes never touch placed objects")
	stack.undo()
	assert_eq(RealisticAnalyzer.farm_level(l), 10, "undo restores the level")
	stack.redo()
	assert_eq(RealisticAnalyzer.farm_level(l), 60)


# --- land --------------------------------------------------------------------

func test_plot_required_level_and_ok() -> void:
	var m := _map()
	assert_eq(RealisticAnalyzer.plot_required_level(m, "p_low"), 10)
	assert_eq(RealisticAnalyzer.plot_required_level(m, "exp_101"), 10, "aliases resolve")
	assert_eq(RealisticAnalyzer.plot_required_level(m, "p_unknown"), -1)
	assert_eq(RealisticAnalyzer.plot_required_level(m, "p_bad"), -1, "0 is not a level requirement")
	assert_eq(RealisticAnalyzer.plot_required_level(m, "nope"), -1)
	assert_eq(RealisticAnalyzer.plot_required_level(null, "p_low"), -1)
	assert_true(RealisticAnalyzer.plot_level_ok(m, "p_low", 10))
	assert_false(RealisticAnalyzer.plot_level_ok(m, "p_high", 44))
	assert_true(RealisticAnalyzer.plot_level_ok(m, "p_high", 45))
	assert_true(RealisticAnalyzer.plot_level_ok(m, "p_high", -1), "negative level = no limit (sandbox)")
	assert_true(RealisticAnalyzer.plot_level_ok(m, "p_unknown", 1), "unknown requirement is allowed")


func test_plot_level_info_flags_unknown() -> void:
	var m := _map()
	var hi := RealisticAnalyzer.plot_level_info(m, "p_high", 30)
	assert_false(hi["ok"])
	assert_eq(hi["reason"], "Requires level 45")
	assert_true(hi["known"])
	var un := RealisticAnalyzer.plot_level_info(m, "p_unknown", 30)
	assert_true(un["ok"], "unknown -> allowed")
	assert_false(un["known"], "…but flagged")
	assert_eq(un["reason"], "Required level unknown")
	var lo := RealisticAnalyzer.plot_level_info(m, "exp_101", 30)
	assert_eq(lo["plot"], "p_low", "reports the canonical id")
	assert_eq(lo["reason"], "")
	assert_eq(m.plot_level_block("p_high", 30), hi["reason"], "same wording as FarmMap.plot_level_block")


func test_analyzer_land_levels() -> void:
	var m := _map()
	var l := FarmLayout.new()
	l.profile["level"] = 20
	l.set_unlocked(["exp_101", "p_high", "p_unknown"])
	var r := RealisticAnalyzer.analyze(l, db, m)
	assert_eq(r.land_level_locked.size(), 1, "only the level-45 plot is above level 20")
	assert_eq(r.land_level_locked[0]["plot"], "p_high")
	assert_eq(r.land_level_locked[0]["min_level"], 45)
	assert_eq(r.land_level_unknown, ["p_unknown"], "unknown requirement flagged, not blocked")
	assert_eq(r.required_land_level, 45)
	assert_eq(r.required_level, 45, "required level covers land too")
	assert_false(r.can_recreate(), "land above the farm level blocks recreating")
	l.profile["level"] = 45
	r = RealisticAnalyzer.analyze(l, db, m)
	assert_true(r.land_level_locked.is_empty())
	assert_true(r.can_recreate())


func test_analyzer_objects_on_locked_plot_count_its_level() -> void:
	var m := _map()
	var l := FarmLayout.new()
	l.profile["level"] = 5
	l.set_unlocked(["p_high"])
	var o := make_obj(db.get_item("l_early"), Vector2i(16, 2))
	l.add_objects([o])
	l.set_unlocked([])
	var r := RealisticAnalyzer.analyze(l, db, m)
	assert_eq(r.plots_needed, ["p_high"])
	assert_eq(r.land_level_locked.size(), 1, "land an object needs is checked against the level as well")
	assert_has(r.issues[o.uid], RealisticAnalyzer.LOCKED_LAND)


func test_analyzer_unknown_item_levels_are_reported_not_blocking() -> void:
	var m := _map()
	var l := FarmLayout.new()
	l.profile["level"] = 1
	l.add_objects([make_obj(db.get_item("l_unknown"), Vector2i(0, 0)), make_obj(db.get_item("l_unknown"), Vector2i(2, 0))])
	var r := RealisticAnalyzer.analyze(l, db, m)
	assert_eq(r.level_unknown_items.get("l_unknown"), 2)
	assert_true(r.level_locked.is_empty(), "never guessed as locked")
	assert_eq(r.required_level, 0)
	for u in r.issues:
		assert_false(RealisticAnalyzer.LEVEL_LOCKED in r.issues[u])
