extends TestCase
## Layout schema 4: the planning document, 3 -> 4 migration (zones become
## areas), backup on first save, SetPlanning undo / redo / merge and object
## identity (uids) across edits.

var db: ItemDatabase
var tmp_dir := "user://test_tmp_schema4"


func before_each() -> void:
	db = fixture_db()
	DirAccess.make_dir_recursive_absolute(tmp_dir)


func after_each() -> void:
	var d := DirAccess.open(tmp_dir)
	if d:
		for f in d.get_files():
			d.remove(f)


static func v3_fixture() -> Dictionary:
	## A layout exactly as schema 3 saved it, with zones and a label.
	return {"format": LayoutIO.FORMAT, "schema_version": 3, "app_version": "0.5.0",
		"meta": {"id": "v3farm", "name": "Three", "mode": "creative"},
		"map": {"id": "hayday_farm", "unlocked_plots": []}, "next_uid": 3, "next_group": 1,
		"objects": [{"uid": 1, "item": "t_bakery", "x": 2, "y": 2, "w": 3, "h": 3},
			{"uid": 2, "item": "t_lamp", "x": 8, "y": 1, "w": 1, "h": 1}],
		"groups": {},
		"annotations": [
			{"id": 1, "kind": "zone", "rect": [1, 1, 5, 4], "text": "Bakery corner", "color": "#e58fb0", "mine": "x"},
			{"id": 2, "kind": "label", "rect": [0, 0, 2, 1], "text": "Hello"},
			{"id": 3, "kind": "zone", "rect": [10, 10, 2, 2], "text": "", "color": "#123456"},
			{"id": 4, "rect": [12, 1, 1, 1], "text": "kindless"}],
		"profile": {"level": 12}, "reference": {}, "camera": {"x": 0.0, "y": 0.0, "zoom": 1.0},
		"world": FarmLayout.default_world_state()}


func test_v3_zones_become_areas() -> void:
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(v3_fixture(), db, rep)
	assert_not_null(l)
	assert_eq(rep.migrated_from, 3)
	assert_eq(rep.zones_to_areas, 3)
	assert_has(rep.summary(), "3 zones became planning areas")
	assert_eq(l.annotations.size(), 1, "only the label stays an annotation")
	assert_eq(l.annotations[0]["kind"], "label")
	var areas := PlanDoc.areas(l.planning)
	assert_eq(areas.size(), 3)
	assert_eq(areas[0]["name"], "Bakery corner")
	assert_eq(areas[0]["rect"], [1, 1, 5, 4])
	assert_eq(areas[0]["color"], "#e58fb0", "colour kept")
	assert_eq(areas[0]["mine"], "x", "unknown zone fields kept")
	assert_eq(areas[1]["name"], "Area 2", "an empty text gets a numbered name")
	assert_eq(areas[1]["color"], "#123456")
	assert_eq(areas[2]["name"], "kindless", "an annotation without kind is a zone (as the editor draws it)")
	assert_eq(PlanDoc.objects_in_area(l, areas[0]), [1])
	var ids := {}
	for a in areas:
		ids[str(a["id"])] = true
	assert_eq(ids.size(), 3, "unique area ids")
	assert_true(PlanDoc.phases(l.planning).is_empty())
	# Pure migrate() gives the same document.
	var m := LayoutIO.migrate(v3_fixture(), 3)
	assert_eq(int(m["schema_version"]), 4)
	assert_eq((m["planning"]["areas"] as Array).size(), 3)


func test_v3_without_zones_gets_empty_plan() -> void:
	var d := v3_fixture()
	d["annotations"] = [{"id": 2, "kind": "label", "rect": [0, 0, 2, 1], "text": "Hello"},
		{"id": 5, "kind": "zone", "rect": "bad"}]
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(d, db, rep)
	assert_eq(rep.zones_to_areas, 0)
	assert_eq(l.annotations.size(), 2, "a zone without a usable rect is left alone")
	assert_eq(l.planning, PlanDoc.empty())
	assert_false(rep.summary().contains("zone"))


func test_v4_round_trip_keeps_planning_and_unknown_keys() -> void:
	var l := LayoutIO.from_dict(v3_fixture(), db)
	var p := l.planning.duplicate(true)
	p = PlanDoc.with_phase(p, {"name": "First", "areas": [PlanDoc.areas(p)[0]["id"]], "target": {"coins": 500}, "x_note": "keep"})
	p = PlanDoc.with_placed(p, l, [1], true)
	p = PlanDoc.with_acquired(p, "t_lamp", 2)
	p = PlanDoc.with_baseline(p, Baseline.snapshot(l, "Real", "v3farm", "2026-11-10T00:00:00Z"))
	p = PlanDoc.with_step_done(p, "unlock-abc", true)
	p["future_tool"] = {"nested": [1, {"a": "b"}]}
	l.set_planning(p, false)
	var d := LayoutIO.to_dict(l)
	assert_eq(int(d["schema_version"]), 4)
	assert_true(d.has("planning"))
	d["new_top_level"] = 7
	var rep := LayoutIO.LoadReport.new()
	var back := LayoutIO.from_dict(JsonUtil.parse(JsonUtil.stringify(d)), db, rep)
	assert_eq(rep.migrated_from, -1)
	# (JSON reads every number as a float; PlanDoc makes the known integer fields int again.)
	assert_eq(back.planning["future_tool"], {"nested": [1.0, {"a": "b"}]}, "unknown planning keys survive")
	assert_eq(back.planning["phases"][0]["x_note"], "keep")
	assert_eq(back.planning["phases"][0]["target"], {"coins": 500.0})
	assert_eq(back.planning["placed"], {"1": [2, 2]})
	assert_eq(back.planning["acquired"], {"t_lamp": 2})
	assert_eq(back.planning["steps_done"], {"unlock-abc": true})
	assert_eq(back.planning["baseline"]["objects"]["1"], ["t_bakery", 2, 2, 3, 3])
	assert_eq(back.planning["areas"][0]["rect"], [1, 1, 5, 4])
	assert_eq(back.extra.get("new_top_level"), 7.0)
	assert_false(back.extra.has("planning"), "planning is a known key, not an extra")
	var second := JsonUtil.stringify(LayoutIO.to_dict(back)["planning"])
	var third_l := LayoutIO.from_dict(JsonUtil.parse(JsonUtil.stringify(LayoutIO.to_dict(back))), db)
	assert_eq(JsonUtil.stringify(LayoutIO.to_dict(third_l)["planning"]), second, "stable across saves")


func test_newer_schema_is_refused() -> void:
	var d := v3_fixture()
	d["schema_version"] = 5
	var rep := LayoutIO.LoadReport.new()
	assert_null(LayoutIO.from_dict(d, db, rep))
	assert_has(rep.error, "newer version")


func test_first_save_over_v3_file_keeps_backup() -> void:
	var path := tmp_dir.path_join("three" + LayoutIO.FILE_EXT)
	var original := JsonUtil.stringify(v3_fixture(), true)
	JsonUtil.write_atomic(path, original, false)
	assert_eq(LayoutIO.file_schema_version(path), 3)
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.load_file(path, db, rep)
	assert_not_null(l)
	var bk := LayoutIO.backup_path_for(path, 3)
	assert_true(bk.ends_with(".hdlayout.v3-backup"))
	assert_false(FileAccess.file_exists(bk), "loading alone writes nothing")
	assert_eq(LayoutIO.save_file(l, path), OK)
	assert_eq(JsonUtil.read_text(bk), original, "the v3 original is kept byte for byte")
	assert_eq(LayoutIO.file_schema_version(path), 4)
	l.name = "Changed"
	assert_eq(LayoutIO.save_file(l, path), OK)
	assert_eq(JsonUtil.read_text(bk), original, "later saves leave the backup alone")
	var back := LayoutIO.load_file(path, db, LayoutIO.LoadReport.new())
	assert_eq(PlanDoc.areas(back.planning).size(), 3, "areas saved in the v4 file")
	DirAccess.remove_absolute(bk)
	# A v4 file is not backed up again.
	assert_eq(LayoutIO.save_file(back, path), OK)
	assert_false(FileAccess.file_exists(bk))


func test_set_planning_undo_redo() -> void:
	var l := FarmLayout.new()
	var stack := CommandStack.new(l)
	var fired := [0]
	l.planning_changed.connect(func() -> void: fired[0] += 1)
	var p0 := l.planning.duplicate(true)
	var p1 := PlanDoc.with_area(p0, {"name": "A", "rect": [0, 0, 2, 2]})
	var v0 := stack.version
	stack.execute(EditCommands.SetPlanning.new(p0, p1, "Add area"))
	assert_eq(PlanDoc.areas(l.planning).size(), 1)
	assert_eq(fired[0], 1, "planning_changed emitted")
	assert_eq(stack.version, v0 + 1, "version bumps like any command")
	assert_true(stack.is_dirty())
	assert_eq(stack.undo_label(), "Add area")
	p1["areas"][0]["name"] = "mutated after"
	assert_eq(PlanDoc.areas(l.planning)[0]["name"], "A", "the command keeps its own deep copy")
	(l.planning["areas"] as Array).clear()
	stack.undo()
	assert_eq(l.planning, p0)
	stack.redo()
	assert_eq(PlanDoc.areas(l.planning)[0]["name"], "A", "redo restores the snapshot, not the mutated live dictionary")
	assert_eq(fired[0], 3)
	stack.execute(EditCommands.SetPlanning.new(l.planning, l.planning.duplicate(true), "Nothing"))
	assert_eq(stack.size(), 1, "a no-op is not recorded")


func test_set_planning_merges_only_with_same_key() -> void:
	var l := FarmLayout.new()
	var stack := CommandStack.new(l)
	for u in [1, 2, 3]:
		l.add_objects([make_obj(db.get_item("t_lamp"), Vector2i(u, 0))])
	var steps_before := stack.size()
	for u in [1, 2, 3]:
		stack.execute(EditCommands.SetPlanning.new(l.planning, PlanDoc.with_placed(l.planning, l, [u], true), "Tick", "checklist"))
	assert_eq(stack.size(), steps_before + 1, "rapid ticks with the same key merge")
	assert_eq((l.planning["placed"] as Dictionary).size(), 3)
	stack.execute(EditCommands.SetPlanning.new(l.planning, PlanDoc.with_acquired(l.planning, "t_lamp", 1), "Acquire", "shopping"))
	assert_eq(stack.size(), steps_before + 2, "a different key starts a new step")
	stack.execute(EditCommands.SetPlanning.new(l.planning, PlanDoc.with_acquired(l.planning, "t_lamp", 2), "Acquire"))
	stack.execute(EditCommands.SetPlanning.new(l.planning, PlanDoc.with_acquired(l.planning, "t_lamp", 3), "Acquire"))
	assert_eq(stack.size(), steps_before + 4, "no key, no merge")
	stack.undo()
	stack.undo()
	stack.undo()
	assert_eq((l.planning["placed"] as Dictionary).size(), 3)
	assert_false((l.planning["acquired"] as Dictionary).has("t_lamp"))
	stack.undo()
	assert_true((l.planning["placed"] as Dictionary).is_empty(), "the merged ticks undo as one step")


func test_uid_identity_across_edits() -> void:
	var map := FarmMap.make_simple(40, 40)
	var l := FarmLayout.new()
	var s := EditorSession.new(l, db, map)
	var first := s.place_objects([make_obj(db.get_item("t_lamp"), Vector2i(2, 2)), make_obj(db.get_item("t_long"), Vector2i(5, 2))], "Place")
	assert_eq(first.size(), 2)
	var lamp: int = first[0]
	var hedge: int = first[1]
	var plan := PlanDoc.with_placed(l.planning, l, [lamp, hedge], true)
	plan = PlanDoc.with_assignment(plan, [lamp], "p1")
	s.execute(EditCommands.SetPlanning.new(l.planning, plan, "Tick"))
	# Move keeps the uid.
	s.select([lamp])
	assert_true(s.nudge(Vector2i(1, 0)))
	assert_eq(l.get_obj(lamp).origin, Vector2i(3, 2), "moved")
	assert_eq(l.get_obj(lamp).item_id, "t_lamp", "same uid, same object")
	assert_true(PlanDoc.is_placed(l.planning, lamp), "plan entries still point at it")
	# Duplicate / paste: new uids.
	s.select([lamp, hedge])
	assert_eq(s.copy_selection(), 2)
	var pasted := s.place_objects(s.clipboard_objects(Vector2i(20, 20)), "Paste")
	assert_eq(pasted.size(), 2)
	for u in pasted:
		assert_false(u in [lamp, hedge], "paste makes new uids")
		assert_false(PlanDoc.is_placed(l.planning, u), "copies are not placed")
	# Repeat: new uids.
	s.select([lamp])
	var rep := s.apply_repeat(1, 3, Vector2i.ZERO)
	assert_true(rep.size() >= 2)
	for u in rep:
		assert_false(u in [lamp, hedge] or u in pasted, "repeat makes new uids")
	# Stamp: new uids.
	s.select([hedge])
	var stamp := s.make_stamp("Hedge")
	var stamped := s.place_stamp(stamp, Vector2i(30, 30))
	assert_eq(stamped.size(), 1)
	assert_false(stamped[0] in [lamp, hedge] or stamped[0] in pasted or stamped[0] in rep, "stamp makes a new uid")
	# Delete + undo: the same uid comes back, so its plan entries are valid again.
	s.select([lamp])
	s.delete_selection()
	assert_null(l.get_obj(lamp))
	assert_true(PlanDoc.is_placed(l.planning, lamp), "deleting does not edit the plan")
	s.stack.undo()
	assert_not_null(l.get_obj(lamp))
	assert_eq(l.get_obj(lamp).item_id, "t_lamp")
	assert_eq(str(PlanDoc.primary_phases(l, plan_with_phase(l.planning)).get(lamp)), "p1", "assignment valid again")
	# A deleted uid (here the newest one) is never handed to a new object, not
	# in this session and not after save / load.
	var newest: int = stamped[0]
	s.select([newest])
	s.delete_selection()
	assert_null(l.get_obj(newest))
	var again := s.place_objects([make_obj(db.get_item("t_lamp"), Vector2i(0, 0))], "Place")
	assert_true(int(again[0]) > newest, "no uid reuse in the session")
	s.select(again)
	s.delete_selection()
	var back := LayoutIO.from_dict(JsonUtil.parse(JsonUtil.stringify(LayoutIO.to_dict(l))), db)
	var fresh: Array = back.add_objects([make_obj(db.get_item("t_lamp"), Vector2i(0, 1))])
	assert_true(int(fresh[0]) > int(again[0]), "uids are not reused after a reload (%d)" % int(fresh[0]))


func plan_with_phase(p: Dictionary) -> Dictionary:
	return PlanDoc.with_phase(p, {"id": "p1", "name": "One"})
