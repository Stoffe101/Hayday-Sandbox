extends TestCase
## Pure tool geometry, the session operations built on it, and stamps.

const STAMP_ROOT := "user://test_stamps"


func before_each() -> void:
	_wipe()


func after_each() -> void:
	_wipe()


func _wipe() -> void:
	var d := DirAccess.open(STAMP_ROOT)
	if d:
		for f in d.get_files():
			d.remove(f)
		DirAccess.remove_absolute(STAMP_ROOT)


func _session() -> EditorSession:
	var db := fixture_db()
	var map := FarmMap.make_simple(40, 40)
	var l := FarmLayout.new()
	return EditorSession.new(l, db, map)


func _lamp(s: EditorSession, at: Vector2i) -> PlacedObject:
	var o := make_obj(s.db.get_item("t_lamp"), at)
	s.layout.add_objects([o], false)
	return o


# --- mirror ----------------------------------------------------------------------------

func test_mirror_rect_is_an_involution_for_every_kind() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 200:
		var r := Rect2i(rng.randi_range(-30, 30), rng.randi_range(-30, 30), rng.randi_range(1, 6), rng.randi_range(1, 6))
		var line := {"kind": LayoutTools.KINDS[rng.randi() % 3], "pos": rng.randi_range(-40, 40)}
		var m := LayoutTools.mirror_rect(r, line)
		assert_eq(LayoutTools.mirror_rect(m, line), r, "twice = original")


func test_screen_mirror_swaps_footprint_like_the_games_rotate() -> void:
	var line := LayoutTools.line_for_tile(LayoutTools.KIND_SCREEN, Vector2i(10, 7))
	assert_eq(line["pos"], 3)
	var r := LayoutTools.mirror_rect(Rect2i(10, 7, 2, 4), line)
	assert_eq(r, Rect2i(10, 7, 4, 2), "corner tile on the line stays; W×H swap")
	assert_eq(LayoutTools.mirror_rect(Rect2i(10, 7, 1, 1), line), Rect2i(10, 7, 1, 1), "a tile on the line is its own mirror")
	# On screen a mirrored footprint centre has the opposite x offset and the same y.
	var c0 := Iso.footprint_center(Vector2i(14, 8), Vector2i(2, 3))
	var m := LayoutTools.mirror_rect(Rect2i(14, 8, 2, 3), line)
	var c1 := Iso.footprint_center(m.position, m.size)
	var axis_x := Iso.grid_to_world(Vector2(3, 0)).x
	assert_almost(c0.y, c1.y, 0.001, "same screen height")
	assert_almost(c0.x - axis_x, axis_x - c1.x, 0.001, "mirrored over the screen line")


func test_along_and_across_lines_reflect_one_axis() -> void:
	var across := LayoutTools.line_for_tile(LayoutTools.KIND_ACROSS, Vector2i(10, 0))
	assert_eq(across["pos"], 21)
	assert_eq(LayoutTools.mirror_rect(Rect2i(12, 3, 2, 1), across), Rect2i(7, 3, 2, 1))
	var along := LayoutTools.line_for_tile(LayoutTools.KIND_ALONG, Vector2i(0, 5))
	assert_eq(LayoutTools.mirror_rect(Rect2i(2, 8, 3, 2), along), Rect2i(2, 1, 3, 2))


func test_mirror_placement_flip_rules() -> void:
	var line := {"kind": LayoutTools.KIND_SCREEN, "pos": 0}
	var a := LayoutTools.mirror_placement(Rect2i(1, 2, 3, 3), false, true, line)
	assert_eq(a["flipped"], true, "flippable items flip")
	var b := LayoutTools.mirror_placement(Rect2i(1, 2, 2, 4), false, false, line)
	assert_true(b.is_empty(), "non-flippable, non-square has no mirror")
	var c := LayoutTools.mirror_placement(Rect2i(1, 2, 3, 3), false, false, line)
	assert_eq(c["flipped"], false, "square but not flippable: moved, not flipped")
	var across := {"kind": LayoutTools.KIND_ACROSS, "pos": 10}
	assert_eq(LayoutTools.mirror_placement(Rect2i(1, 2, 2, 4), false, true, across)["flipped"], false, "footprint can't change on this line")
	assert_eq(LayoutTools.mirror_placement(Rect2i(1, 2, 3, 3), false, true, across)["flipped"], true)


func test_mirror_mask_stays_connected() -> void:
	# A straight run along x (NW + SE) mirrored over the screen line runs along y.
	var line := {"kind": LayoutTools.KIND_SCREEN, "pos": 0}
	assert_eq(LayoutTools.mirror_mask(Connections.NW | Connections.SE, line), Connections.NE | Connections.SW)
	assert_eq(LayoutTools.mirror_mask(-1, line), -1)
	var across := {"kind": LayoutTools.KIND_ACROSS, "pos": 10}
	assert_eq(LayoutTools.mirror_mask(Connections.NW, across), Connections.SE)


func test_line_segment_stays_inside_bounds() -> void:
	var b := Rect2i(0, 0, 20, 10)
	var seg := LayoutTools.line_segment({"kind": LayoutTools.KIND_SCREEN, "pos": 3}, b)
	assert_vec_almost(seg[0], Vector2(3, 0))
	assert_vec_almost(seg[1], Vector2(13, 10))
	assert_true(LayoutTools.line_segment({"kind": LayoutTools.KIND_ACROSS, "pos": 100}, b).is_empty())


# --- repeat, align, distribute ----------------------------------------------------------

func test_repeat_offsets_skip_the_original_and_respect_caps() -> void:
	var o := LayoutTools.repeat_offsets(Vector2i(2, 3), 3, 2, Vector2i(1, 0))
	assert_eq(o.size(), 5)
	assert_false(Vector2i.ZERO in o)
	assert_true(Vector2i(6, 3) in o, "col 2, row 1: step = bounds + gap")
	assert_eq(LayoutTools.repeat_offsets(Vector2i.ONE, 1, 1, Vector2i.ZERO).size(), 0)
	assert_true(LayoutTools.repeat_offsets(Vector2i.ONE, 999, 999, Vector2i.ZERO).size() < LayoutTools.MAX_REPEAT_CELLS)


func test_align_ops() -> void:
	var rects := [Rect2i(2, 1, 2, 2), Rect2i(6, 4, 1, 1), Rect2i(9, 9, 3, 3)]
	assert_eq(LayoutTools.align_deltas(rects, "left"), [Vector2i.ZERO, Vector2i(-4, 0), Vector2i(-7, 0)])
	assert_eq(LayoutTools.align_deltas(rects, "right"), [Vector2i(8, 0), Vector2i(5, 0), Vector2i.ZERO])
	assert_eq(LayoutTools.align_deltas(rects, "top"), [Vector2i.ZERO, Vector2i(0, -3), Vector2i(0, -8)])
	assert_eq(LayoutTools.align_deltas(rects, "bottom"), [Vector2i(0, 9), Vector2i(0, 7), Vector2i.ZERO])
	# bounds x 2..12 -> centre 7: a width-2 rect sits at 6, width-1 at 6, width-3 at 5
	assert_eq(LayoutTools.align_deltas(rects, "center_along"), [Vector2i(4, 0), Vector2i(0, 0), Vector2i(-4, 0)])
	assert_eq(LayoutTools.align_deltas(rects, "nope"), [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO])


func test_distribute_equal_gaps_keeps_the_ends() -> void:
	var rects := [Rect2i(0, 0, 1, 1), Rect2i(2, 0, 1, 1), Rect2i(9, 0, 1, 1)]
	var d := LayoutTools.distribute_deltas(rects, LayoutTools.AXIS_ALONG)
	assert_eq(d[0], Vector2i.ZERO)
	assert_eq(d[2], Vector2i.ZERO)
	assert_eq(d[1], Vector2i(3, 0), "7 free tiles over 2 gaps: the middle lands at 5")
	var y := LayoutTools.distribute_deltas([Rect2i(0, 10, 1, 2), Rect2i(0, 1, 1, 2), Rect2i(0, 20, 1, 2)], LayoutTools.AXIS_ACROSS)
	assert_eq(y[1], Vector2i.ZERO, "first stays")
	assert_eq(y[0], Vector2i(0, 1), "order follows position, not the input")
	assert_eq(LayoutTools.distribute_deltas([Rect2i(0, 0, 5, 1), Rect2i(1, 0, 1, 1), Rect2i(2, 0, 1, 1)], LayoutTools.AXIS_ALONG), [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO], "no room: nothing moves")


func test_line_and_outline_origins() -> void:
	assert_eq(LayoutTools.line_origins(Vector2i(1, 1), Vector2i(4, 2), Vector2i.ONE), [Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1)])
	assert_eq(LayoutTools.line_origins(Vector2i(0, 0), Vector2i(0, -4), Vector2i(1, 2)), [Vector2i(0, 0), Vector2i(0, -2), Vector2i(0, -4)])
	var o := LayoutTools.outline_origins(Vector2i(1, 1), Vector2i(4, 3), Vector2i.ONE)
	assert_eq(o.size(), 10, "perimeter of 4×3 without repeats")
	assert_false(Vector2i(2, 2) in o, "the inside stays empty")
	assert_eq(LayoutTools.outline_origins(Vector2i(1, 1), Vector2i(1, 4), Vector2i.ONE).size(), 4, "one wide = a line")
	assert_eq(LayoutTools.outline_origins(Vector2i(4, 3), Vector2i(1, 1), Vector2i.ONE).size(), 10, "any drag direction")


func test_connection_masks_count_plan_and_farm() -> void:
	var s := _session()
	var fence := s.db.get_item("t_fence")
	s.layout.add_objects([make_obj(fence, Vector2i(5, 4))], false)
	s.layout.add_objects([make_obj(s.db.get_item("t_fence_stone"), Vector2i(3, 2))], false)
	var masks := LayoutTools.connection_masks(s.layout, s.db, "wood", [Rect2i(3, 3, 1, 1), Rect2i(4, 3, 1, 1), Rect2i(5, 3, 1, 1)])
	assert_eq(masks[0], Connections.SE, "stone fence doesn't count")
	assert_eq(masks[1], Connections.SE | Connections.NW, "middle of the run")
	assert_eq(masks[2], Connections.NW | Connections.SW, "joins the fence on the farm")


func test_fit_mask_and_resolve_moves() -> void:
	var s := _session()
	var a := _lamp(s, Vector2i(5, 5))
	var b := _lamp(s, Vector2i(6, 5))
	var c := _lamp(s, Vector2i(7, 5))
	assert_eq(LayoutTools.fit_mask(s.layout, s.map, [Rect2i(5, 5, 1, 1), Rect2i(1, 1, 1, 1), Rect2i(1, 1, 1, 1), Rect2i(-1, 0, 1, 1)]), [false, true, false, false])
	# a and b swap-chain: b -> c's tile is blocked while c refuses to leave the map.
	var r := LayoutTools.resolve_moves(s.layout, s.map, [a.uid, b.uid, c.uid], [Vector2i(1, 0), Vector2i(1, 0), Vector2i(40, 0)])
	assert_eq(r["uids"], [], "c can't go, so b can't, so a can't")
	assert_eq(r["skipped"], 3)
	var ok := LayoutTools.resolve_moves(s.layout, s.map, [a.uid, b.uid, c.uid], [Vector2i(1, 0), Vector2i(1, 0), Vector2i(1, 0)])
	assert_eq(ok["uids"].size(), 3, "a whole chain moves together")


# --- session ------------------------------------------------------------------------------

func test_place_with_symmetry_adds_mirror_in_one_undo_step() -> void:
	var s := _session()
	var lamp := s.db.get_item("t_lamp")
	s.tool = "place"
	s.set_symmetry_enabled(true)
	s.symmetry["kind"] = LayoutTools.KIND_ACROSS
	s.symmetry["pos"] = 20    # line between x 9 and 10
	var uids := s.place_objects([make_obj(lamp, Vector2i(2, 2)), make_obj(lamp, Vector2i(3, 2))], "Paint")
	assert_eq(uids.size(), 4)
	assert_true(s.layout.object_at(Vector2i(17, 2)) != null and s.layout.object_at(Vector2i(16, 2)) != null, "mirrored copies")
	s.stack.undo()
	assert_eq(s.layout.count(), 0, "one gesture = one undo step")


func test_symmetry_skips_what_rules_refuse_and_the_axis_itself() -> void:
	var s := _session()
	var lamp := s.db.get_item("t_lamp")
	s.tool = "place"
	s.set_symmetry_enabled(true)
	s.symmetry["kind"] = LayoutTools.KIND_ACROSS
	s.symmetry["pos"] = 21   # through column x = 10
	_lamp(s, Vector2i(15, 2))   # blocks the mirror of (5, 2)
	var uids := s.place_objects([make_obj(lamp, Vector2i(5, 2)), make_obj(lamp, Vector2i(10, 4))], "Paint")
	assert_eq(uids.size(), 2, "mirror of (5,2) blocked; (10,4) lies on the axis: no copy")
	assert_eq(s.layout.count(), 3)
	s.tool = "select"
	assert_eq(s.place_objects([make_obj(lamp, Vector2i(2, 9))], "Paste").size(), 1, "symmetry applies to the place tool only")


func test_symmetry_flips_mirrored_items() -> void:
	var s := _session()
	var it := s.db.get_item("t_long")   # 1×4, flippable
	s.tool = "place"
	s.set_symmetry_enabled(true)
	s.symmetry["kind"] = LayoutTools.KIND_SCREEN
	s.symmetry["pos"] = 0
	var uids := s.place_objects([make_obj(it, Vector2i(10, 1))], "Place")
	assert_eq(uids.size(), 2)
	var m := s.layout.get_obj(uids[1])
	assert_eq(m.flipped, true)
	assert_eq(m.size, Vector2i(4, 1), "footprint swapped")
	assert_eq(m.origin, Vector2i(1, 10))


func test_symmetry_never_copies_blocked_items() -> void:
	var s := _session()
	s.db.get_item("t_lamp").landmark = "some_landmark"
	s.layout.fixed_items = {"t_lamp": true}
	s.tool = "place"
	s.set_symmetry_enabled(true)
	var o := make_obj(s.db.get_item("t_lamp"), Vector2i(2, 2))
	assert_eq(s.place_objects([o], "Place").size(), 0)
	assert_eq(s.layout.count(), 0)


func test_align_and_distribute_are_one_undo_step() -> void:
	var s := _session()
	var a := _lamp(s, Vector2i(2, 2))
	var b := _lamp(s, Vector2i(4, 6))
	var c := _lamp(s, Vector2i(7, 9))
	s.select([a.uid, b.uid, c.uid], false, false)
	assert_true(s.align_selection("top"))
	assert_eq([a.origin.y, b.origin.y, c.origin.y], [2, 2, 2])
	assert_eq(s.stack.size(), 1)
	s.stack.undo()
	assert_eq([a.origin, b.origin, c.origin], [Vector2i(2, 2), Vector2i(4, 6), Vector2i(7, 9)])
	s.stack.redo()
	assert_true(s.distribute_selection(LayoutTools.AXIS_ALONG), "x 2, 4, 7 -> equal gaps")
	assert_eq(b.origin.x, 5, "7 - 2 - 3 tiles = 2 free tiles: gaps 1 and 1")
	assert_eq(s.stack.size(), 2)


func test_align_leaves_blocked_locked_and_obstacle_objects_alone() -> void:
	var s := _session()
	var msgs: Array = []
	s.message.connect(func(t: String, _k: String): msgs.append(t))
	var a := _lamp(s, Vector2i(2, 2))
	var b := _lamp(s, Vector2i(2, 5))
	var c := _lamp(s, Vector2i(2, 8))
	c.locked = true
	s.select([a.uid, b.uid, c.uid], false, false)
	# Only a and b are movable; aligning a to b's y would put it on b.
	assert_false(s.align_selection("bottom"), "a would land on b, c is locked")
	assert_eq([a.origin, b.origin, c.origin], [Vector2i(2, 2), Vector2i(2, 5), Vector2i(2, 8)])
	assert_eq(s.stack.size(), 0)
	assert_false(msgs.is_empty(), "the refusal is explained")
	# An obstacle is left out; the others still align.
	var bakery := s.db.get_item("t_bakery")
	bakery.movable = false
	var o := make_obj(bakery, Vector2i(20, 20))
	var d := _lamp(s, Vector2i(14, 3))
	var e := _lamp(s, Vector2i(16, 6))
	s.layout.add_objects([o], false)
	s.select([o.uid, d.uid, e.uid], false, false)
	assert_true(s.align_selection("left"))
	assert_eq(d.origin.x, 14)
	assert_eq(e.origin.x, 14, "moved")
	assert_eq(o.origin, Vector2i(20, 20), "obstacle stays")


func test_landmark_selection_refuses_tools() -> void:
	var db := fixture_db()
	var map := FarmMap.new()
	map.from_dict({"id": "w", "name": "W", "size": [30, 30], "schema_version": 2, "frame": "game",
		"regions": [{"id": "all", "kind": "buildable", "rects": [[0, 0, 30, 30]]}],
		"landmarks": [{"id": "barn_lm", "name": "Barn", "origin": [5, 5], "footprint": [3, 3], "selectable": true}]})
	var s := EditorSession.new(FarmLayout.new(), db, map)
	assert_true(s.select_landmark("barn_lm"), "landmark selected")
	assert_false(s.align_selection("left"))
	assert_false(s.distribute_selection(LayoutTools.AXIS_ALONG))
	assert_eq(s.repeat_plan(2, 2, Vector2i.ZERO), {})
	assert_eq(s.apply_repeat(2, 2, Vector2i.ZERO), [])
	assert_eq(s.make_stamp("nope"), {})
	assert_eq(s.stack.size(), 0)


func test_repeat_plan_and_apply() -> void:
	var s := _session()
	var a := _lamp(s, Vector2i(2, 2))
	_lamp(s, Vector2i(6, 2))   # blocks one cell of the array
	s.select([a.uid], false, false)
	var plan := s.repeat_plan(4, 1, Vector2i.ONE)
	assert_eq((plan["rects"] as Array).size(), 3)
	assert_eq((plan["objs"] as Array).size(), 2, "one cell blocked")
	assert_eq(plan["skipped"], 1)
	var uids := s.apply_repeat(4, 1, Vector2i.ONE)
	assert_eq(uids.size(), 2)
	assert_true(s.layout.object_at(Vector2i(4, 2)) != null)
	assert_eq(s.stack.size(), 1, "one undo step")
	s.stack.undo()
	assert_eq(s.layout.count(), 2)


func test_repeat_respects_level_block_and_out_of_scope() -> void:
	var s := _session()
	var a := make_obj(s.db.get_item("t_lamp"), Vector2i(2, 2))   # unlocks at level 30
	s.layout.add_objects([a], false)
	s.select([a.uid], false, false)
	s.set_mode(FarmLayout.MODE_REALISTIC)
	assert_eq(s.repeat_plan(3, 1, Vector2i.ZERO), {}, "above the farm level")
	s.set_mode(FarmLayout.MODE_CREATIVE)
	assert_eq((s.repeat_plan(3, 1, Vector2i.ZERO)["objs"] as Array).size(), 2)


# --- stamps --------------------------------------------------------------------------------

func _stamped(s: EditorSession) -> Dictionary:
	var a := make_obj(s.db.get_item("t_bakery"), Vector2i(5, 5))
	var b := make_obj(s.db.get_item("t_lamp"), Vector2i(8, 7))
	s.layout.add_objects([a, b], false)
	s.select([a.uid, b.uid], false, false)
	return s.make_stamp(" Corner bakery ")


func test_stamp_is_relative_and_round_trips() -> void:
	var s := _session()
	var st := _stamped(s)
	assert_eq(st["name"], "Corner bakery")
	assert_eq(st["size"], [4, 3])
	var lib := StampLibrary.new(STAMP_ROOT)
	assert_eq(lib.save(st, s.db), OK)
	assert_true(FileAccess.file_exists(lib.thumb_path(st["id"])), "thumbnail written")
	var got := lib.get_stamp(st["id"])
	assert_eq(got["items"], st["items"])
	assert_eq(lib.list().size(), 1)
	assert_eq(lib.delete(st["id"]), OK)
	assert_eq(lib.list().size(), 0)
	assert_false(FileAccess.file_exists(lib.thumb_path(st["id"])), "thumbnail removed")


func test_place_stamp_one_undo_step_skips_what_does_not_fit() -> void:
	var s := _session()
	var st := _stamped(s)
	s.select([], false, false)
	s.layout.remove_objects(s.layout.objects.keys(), false)
	_lamp(s, Vector2i(13, 2))   # where the stamp's lamp lands
	var uids := s.place_stamp(st, Vector2i(10, 0))
	assert_eq(uids.size(), 1, "the bakery fits, the lamp is skipped")
	assert_eq(s.layout.get_obj(uids[0]).origin, Vector2i(10, 0))
	assert_eq(s.stack.size(), 1)
	s.stack.undo()
	assert_eq(s.layout.count(), 1)


func test_stamp_never_contains_landmark_duplicates_or_other_areas() -> void:
	var s := _session()
	var a := make_obj(s.db.get_item("t_bakery"), Vector2i(1, 1))
	var b := make_obj(s.db.get_item("t_lamp"), Vector2i(8, 1))
	var c := make_obj(s.db.get_item("t_long"), Vector2i(12, 1))
	s.layout.add_objects([a, b, c], false)
	s.db.get_item("t_bakery").landmark = "barn"
	s.db.get_item("t_lamp").scope = "fishing_lake"
	s.select([a.uid, b.uid, c.uid], false, false)
	var st := s.make_stamp("x")
	assert_eq((st["items"] as Array).size(), 1)
	assert_eq(st["items"][0]["item"], "t_long")
	s.select([a.uid, b.uid], false, false)
	assert_eq(s.make_stamp("y"), {}, "nothing usable")


func test_import_filters_and_never_trusts_the_file() -> void:
	var s := _session()
	s.db.get_item("t_bakery").landmark = "barn"
	var lib := StampLibrary.new(STAMP_ROOT)
	var path := STAMP_ROOT.path_join("in.txt")
	DirAccess.make_dir_recursive_absolute(STAMP_ROOT)
	var data := {"format": StampLibrary.FORMAT, "version": 1, "id": "../../evil", "name": "Mixed",
		"items": [{"item": "t_bakery", "x": 0, "y": 0}, {"item": "t_lamp", "x": 5, "y": 4}, {"item": "no_such_item", "x": 1, "y": 1},
			{"item": "t_long", "x": 900000, "y": 0}, "junk", {"item": "t_long", "x": 7, "y": 6, "flip": true}]}
	JsonUtil.write_atomic(path, JsonUtil.stringify(data), false)
	var r := lib.import_file(path, s.stamp_refusal, s.db)
	assert_eq(r["error"], "")
	var st: Dictionary = r["stamp"]
	assert_eq((st["items"] as Array).size(), 2, "only known, allowed, sane entries")
	assert_eq(r["dropped"], 4)
	assert_true(str(st["id"]).is_valid_filename() and str(st["id"]) != "../../evil", "the file can't choose the id")
	assert_eq(st["items"][0]["x"], 0, "normalized")
	assert_eq(st["items"][0]["y"], 0)
	var out := STAMP_ROOT.path_join("out.%s" % StampLibrary.EXT)
	assert_eq(lib.export_file(st["id"], out), OK)
	var again := lib.import_file(out, s.stamp_refusal, s.db)
	assert_eq((again["stamp"]["items"] as Array).size(), 2, "export -> import keeps the contents")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(out)
	assert_eq(lib.list().size(), 2)


func test_import_refuses_garbage() -> void:
	var s := _session()
	var lib := StampLibrary.new(STAMP_ROOT)
	var path := STAMP_ROOT.path_join("bad.hdstamp")
	DirAccess.make_dir_recursive_absolute(STAMP_ROOT)
	for text in ["not json", "{}", '{"format":"nope"}', '{"format":"hayday-sandbox-stamp","version":999,"items":[]}', '{"format":"hayday-sandbox-stamp","version":1,"items":[]}']:
		JsonUtil.write_atomic(path, text, false)
		var r := lib.import_file(path, s.stamp_refusal)
		assert_true((r["stamp"] as Dictionary).is_empty(), "refused: %s" % text)
		assert_false(str(r["error"]).is_empty(), "with a reason")
	DirAccess.remove_absolute(path)
	assert_eq(lib.import_file("user://no_such_file.hdstamp", s.stamp_refusal)["error"], "File not found")


func test_stamp_placement_rechecks_level_block() -> void:
	var s := _session()
	var st := _stamped(s)
	s.select([], false, false)
	s.layout.remove_objects(s.layout.objects.keys(), false)
	s.set_mode(FarmLayout.MODE_REALISTIC)   # farm level 1: bakery (2) and lamp (30) locked
	var plan := s.stamp_plan(st, Vector2i(1, 1))
	assert_eq((plan["objs"] as Array).size(), 0)
	assert_eq(plan["skipped"], 2)


func test_thumbnail_marks_the_footprints() -> void:
	var s := _session()
	var st := _stamped(s)
	var img := StampLibrary.thumbnail_image(st, s.db, 64)
	assert_eq(img.get_size(), Vector2i(64, 64))
	assert_true(img.get_used_rect().size.x > 20, "something was drawn")


func test_move_each_command_round_trip() -> void:
	var s := _session()
	var a := _lamp(s, Vector2i(1, 1))
	var b := _lamp(s, Vector2i(5, 5))
	s.execute(EditCommands.MoveEach.new([a.uid, b.uid], [Vector2i(2, 0), Vector2i(0, 3)], "Align"))
	assert_eq(a.origin, Vector2i(3, 1))
	assert_eq(b.origin, Vector2i(5, 8))
	assert_true(s.layout.occupancy.at(Vector2i(1, 1)) == 0, "occupancy follows")
	s.stack.undo()
	assert_eq(a.origin, Vector2i(1, 1))
	assert_eq(s.layout.occupancy.at(Vector2i(5, 5)), b.uid)
