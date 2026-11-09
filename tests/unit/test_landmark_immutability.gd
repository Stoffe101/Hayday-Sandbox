extends TestCase
## Fixed landmarks can't be moved, rotated, removed, copied or grouped by ANY
## editing operation, and catalogue copies of landmarks never enter
## layout.objects. Every operation below runs on a synthetic world
## (tests/fixtures/world_v2.json + synthetic items; no game data) and the
## invariants are re-checked after each step.

const WORLD := "res://tests/fixtures/world_v2.json"

var db: ItemDatabase
var map: FarmMap
var layout: FarmLayout
var s: EditorSession
var msgs: Array = []
var _lm0: String = ""


func before_each() -> void:
	db = ItemDatabase.new()
	db.load_categories("res://tests/fixtures/categories.json")
	db.load_file("res://tests/fixtures/items.json")
	db.load_file("res://tests/fixtures/world_items.json")
	db.finalize()
	map = FarmMap.load_file(WORLD)
	layout = FarmLayout.new()
	layout.map_id = map.id
	layout.set_unlocked(["plot_east"], false)
	s = EditorSession.new(layout, db, map)
	msgs = []
	s.message.connect(_on_message)
	_lm0 = _landmark_snapshot()
	# A few ordinary objects plus an obstacle to edit around the landmarks.
	var objs: Array = [
		make_obj(db.get_item("t_lamp"), Vector2i(0, 0)),
		make_obj(db.get_item("t_bakery"), Vector2i(7, 0)),
		make_obj(db.get_item("t_long"), Vector2i(0, 8)),
		make_obj(db.get_item("w_stump"), Vector2i(8, 8)),
		make_obj(db.get_item("w_rock"), Vector2i(11, 4)),
	]
	s.place_objects(objs, "setup")


func after_each() -> void:
	# Break signal/reference cycles so nothing leaks between tests.
	if s and s.message.is_connected(_on_message):
		s.message.disconnect(_on_message)
	s = null
	layout = null


func _on_message(t: String, k: String) -> void:
	msgs.append([t, k])


func _landmark_snapshot() -> String:
	var parts: Array = []
	for lm in map.landmarks:
		parts.append("%s@%s+%s|%s|%s" % [lm.id, str(lm.origin), str(lm.footprint), str(lm.mirrored), str(lm.block_rects())])
	return "%d:%s" % [map.landmarks.size(), ";".join(PackedStringArray(parts))]


func _invariants(step: String) -> void:
	assert_eq(_landmark_snapshot(), _lm0, "%s: landmarks unchanged (none moved, vanished or duplicated)" % step)
	assert_eq(map.landmarks.size(), 3, "%s: landmark count" % step)
	for o: PlacedObject in layout.objects.values():
		var it := db.get_item(o.item_id)
		assert_true(it == null or it.landmark.is_empty(), "%s: landmark copy %s entered layout.objects" % [step, o.item_id])
		assert_false(map.landmark(o.item_id) != null, "%s: a landmark id became an object" % step)
	for c in s.clipboard:
		var it := db.get_item(str(c["item"]))
		assert_true(it == null or it.can_place(), "%s: clipboard holds an unplaceable item" % step)
	assert_false(s.selected_landmark in s.selection, "%s: landmark never in the object selection" % step)
	for u in s.selection:
		assert_true(layout.objects.has(u), "%s: selection holds only object uids" % step)


func _uid_of(item: String) -> int:
	for o: PlacedObject in layout.objects.values():
		if o.item_id == item:
			return o.uid
	return 0


func _objects_json() -> String:
	return JsonUtil.stringify(LayoutIO.to_dict(layout)["objects"])


# --- landmark selected: every edit entry point refuses ---------------------------

func test_landmark_selection_is_separate_and_refuses_every_edit() -> void:
	_invariants("setup")
	assert_eq(layout.count(), 5)
	var picked: Array = []
	s.landmark_selected.connect(func(id): picked.append(id))
	s.select([_uid_of("t_lamp")])
	assert_true(s.select_landmark("house"))
	assert_eq(picked, ["house"])
	assert_true(s.selection.is_empty(), "selecting a landmark clears the object selection")
	assert_true(s.has_selection())
	assert_false(s.select_landmark("nope"), "unknown landmark")
	var before := _objects_json()
	var steps := s.stack.size()
	s.delete_selection()
	_invariants("delete")
	s.nudge(Vector2i(1, 0))
	_invariants("nudge")
	s.flip_selection()
	_invariants("flip")
	s.group_selection()
	_invariants("group")
	s.ungroup_selection()
	_invariants("ungroup")
	s.set_flag("locked", true, "Lock")
	_invariants("lock")
	assert_eq(s.copy_selection(), 0, "copy refused")
	_invariants("copy")
	assert_true(s.editable_selection().is_empty())
	assert_true(s.removable_selection().is_empty())
	assert_eq(_objects_json(), before, "no object changed")
	assert_eq(s.stack.size(), steps, "no command was executed")
	assert_eq(s.selected_landmark, "house", "landmark stays selected")
	var texts: Array = msgs.map(func(m): return str(m[0]))
	assert_true(texts.any(func(t): return t.contains("Test House is fixed in place in Hay Day") and t.contains("can't be moved or rotated")), "friendly explanation: %s" % str(texts))
	assert_true(texts.any(func(t): return t.contains("can't be removed")))
	assert_true(texts.any(func(t): return t.contains("only one Test House")))
	assert_eq(s.move_refusal_message(), s.explain_fixed("house", "move"))
	# Selecting objects clears the landmark selection (mutually exclusive).
	s.select([_uid_of("t_lamp")])
	assert_eq(s.selected_landmark, "")
	assert_eq(picked.back(), "")
	s.select_landmark("house")
	s.select_all()
	assert_eq(s.selected_landmark, "", "select all never selects landmarks")
	assert_eq(s.selection.size(), layout.count())
	s.select_landmark("house")
	s.clear_selection()
	assert_false(s.has_selection(), "Esc clears the landmark selection too")
	_invariants("end")


func test_realistic_level_rule_covers_every_new_copy() -> void:
	var it := _level_item()
	layout.mode = FarmLayout.MODE_REALISTIC
	layout.profile["level"] = 1
	s.set_active_item(it.id)
	assert_ne(s.active_item, it.id, "the brush and eyedropper refuse an item above the farm level")
	var c0 := layout.count()
	assert_eq(s.place_objects([make_obj(it, Vector2i(0, 4))], "t"), [], "placing is refused")
	s.clipboard = [{"item": it.id, "offset": Vector2i.ZERO, "flipped": false, "variant": "", "planned": false,
		"note": "", "size": it.size_for(false), "group": 0}]
	assert_eq(s.clipboard_objects(Vector2i(0, 4)), [], "paste skips it")
	assert_eq(layout.count(), c0)
	layout.mode = FarmLayout.MODE_CREATIVE
	assert_eq(s.place_objects([make_obj(it, Vector2i(0, 4))], "t").size(), 1, "the sandbox places anything")
	layout.mode = FarmLayout.MODE_REALISTIC
	assert_eq(layout.count(), c0 + 1, "switching mode never removes the copy that is already there")


func _level_item() -> ItemDef:
	for candidate: ItemDef in db.ordered:
		if candidate.can_place() and not s.is_fixed_item(candidate.id):
			candidate.unlock_level = 50
			return candidate
	return null


func test_rename_and_reference_are_undoable() -> void:
	var name0 := layout.name
	s.execute(EditCommands.SetMeta.new(name0, "Renamed"))
	assert_eq(layout.name, "Renamed")
	s.stack.undo()
	assert_eq(layout.name, name0, "undo restores the name")
	var a := {"file": "user://a.png", "opacity": 0.5}
	s.execute(EditCommands.SetReference.new({}, a, "Add"))
	assert_eq(layout.reference, a)
	s.execute(EditCommands.SetReference.new(a, {}, "Remove"))
	assert_eq(layout.reference, {}, "removed")
	s.stack.undo()
	assert_eq(layout.reference, a, "undo brings the reference back")
	s.stack.undo()
	assert_eq(layout.reference, {}, "undo again removes it")
	s.stack.redo()
	assert_eq(layout.reference, a)
	assert_true(EditCommands.SetMeta.new("x", "x").is_noop(), "same name is a no-op")


func test_out_of_scope_objects_are_flagged() -> void:
	var it := db.get_item("t_lamp")
	var uid: int = layout.objects.keys()[0]
	var obj := layout.get_obj(uid)
	var scope0 := db.get_item(obj.item_id).scope
	db.get_item(obj.item_id).scope = "fishing_lake"
	var r := RealisticAnalyzer.analyze(layout, db, map)
	assert_has(" ".join(PackedStringArray(r.issues.get(uid, []))), RealisticAnalyzer.OUT_OF_SCOPE)
	assert_true(layout.objects.has(uid), "the object itself is kept")
	assert_not_null(it)
	db.get_item(obj.item_id).scope = scope0


func test_explain_fixed_texts() -> void:
	assert_has(s.explain_fixed("house", "move"), "The Test House is fixed in place in Hay Day")
	assert_has(s.explain_fixed("house", "rotate"), "can't be moved or rotated")
	assert_has(s.explain_fixed("house", "delete"), "can't be removed")
	assert_has(s.explain_fixed("house", "group"), "can't be grouped")
	assert_has(s.explain_fixed("w_house", "place"), "There is only one Test House")
	assert_has(s.explain_fixed("w_combo", "move"), "fixed in place", "item duplicating two landmarks")
	assert_eq(s.explain_fixed("w_stump", "move"), EditorSession.OBSTACLE_MOVE_TEXT)
	assert_eq(s.explain_fixed("w_stump", "rotate"), EditorSession.OBSTACLE_ROTATE_TEXT)
	assert_eq(s.explain_fixed("w_stump", "delete"), "", "obstacles can be removed")
	assert_has(s.explain_fixed("w_lake", "place"), "Fishing Lake")
	assert_eq(s.explain_fixed("t_bakery", "move"), "", "ordinary items aren't fixed")
	assert_eq(s.explain_fixed("unknown_thing", "move"), "")


# --- placing / pasting / importing landmark copies -----------------------------------

func test_landmark_items_can_never_be_placed() -> void:
	var n := layout.count()
	s.set_active_item("w_house")
	assert_eq(s.active_item, "", "a landmark copy can't become the brush")
	s.set_active_item("w_lake")
	assert_eq(s.active_item, "", "items of other areas neither")
	s.set_active_item("t_lamp")
	assert_eq(s.active_item, "t_lamp")
	var uids := s.place_objects([make_obj(db.get_item("w_house"), Vector2i(0, 4)), make_obj(db.get_item("w_combo"), Vector2i(4, 10)),
		make_obj(db.get_item("w_lake"), Vector2i(7, 10))], "Place")
	assert_true(uids.is_empty())
	assert_eq(layout.count(), n)
	_invariants("place_objects")
	# Even a raw command can't put a landmark copy into the layout.
	s.execute(EditCommands.AddObjects.new([make_obj(db.get_item("w_house"), Vector2i(0, 4)), make_obj(db.get_item("t_lamp"), Vector2i(1, 4))]))
	assert_eq(layout.count(), n + 1, "only the ordinary object was added")
	_invariants("raw AddObjects")
	s.stack.undo()
	s.stack.redo()
	_invariants("undo/redo raw add")
	# Pasting a clipboard that somehow holds a landmark copy.
	s.clipboard = [{"item": "w_house", "offset": Vector2i.ZERO, "flipped": false, "variant": "", "planned": false, "note": "", "size": Vector2i(3, 3), "group": 0},
		{"item": "t_lamp", "offset": Vector2i(4, 0), "flipped": false, "variant": "", "planned": false, "note": "", "size": Vector2i.ONE, "group": 0}]
	var pasted := s.clipboard_objects(Vector2i(0, 10))
	assert_eq(pasted.size(), 1, "landmark copies are skipped when pasting")
	s.place_objects(pasted, "Paste")
	s.clipboard = []
	_invariants("paste")
	# Placement rules: landmark tiles block in Creative and Realistic.
	for mode in [FarmLayout.MODE_CREATIVE, FarmLayout.MODE_REALISTIC]:
		s.set_mode(mode)
		var r := PlacementRules.check_item(layout, map, db.get_item("t_lamp"), Vector2i(4, 4), false)
		assert_false(r.ok, "%s: landmark tile blocks placement" % mode)
		assert_true(r.reason_counts.has(PlacementRules.LANDMARK), "%s: reason LANDMARK" % mode)
		assert_has(r.message(layout, db, map), "Fixed landmark: Test House")


func test_import_and_templates_strip_landmark_items() -> void:
	var d := LayoutIO.to_dict(layout)
	d["objects"].append({"uid": 90, "item": "w_house", "x": 3, "y": 3, "w": 3, "h": 3})
	d["objects"].append({"uid": 91, "item": "w_combo", "x": 12, "y": 2, "w": 2, "h": 2})
	var rep := LayoutIO.LoadReport.new()
	var imported := LayoutIO.from_dict(d, db, rep, map)
	assert_eq(imported.count(), layout.count(), "landmark copies dropped from objects")
	assert_eq(rep.migrated_landmarks.size(), 2, "…and reported")
	assert_eq((imported.migration["migrated_landmarks"] as Array).size(), 2, "…and kept in the file")
	# Opening it in a session ("apply template" / reset to a new layout).
	var s2 := EditorSession.new(imported, db, map)
	s2.select_all()
	assert_eq(s2.copy_selection(), imported.count())
	for c in s2.clipboard:
		assert_true(db.get_item(str(c["item"])).landmark.is_empty())
	var fresh := FarmLayout.new()
	var s3 := EditorSession.new(fresh, db, map)
	s3.place_objects([make_obj(db.get_item("w_house"), Vector2i(0, 0))], "Template")
	assert_eq(fresh.count(), 0, "a new layout can't receive landmark copies")
	layout.clear_all()
	_invariants("clear_all / reset")


# --- object edits around landmarks ---------------------------------------------------

func test_moves_into_landmarks_are_refused_and_landmarks_never_move() -> void:
	var lamp: int = s.place_objects([make_obj(db.get_item("t_lamp"), Vector2i(0, 4))], "Lamp")[0]
	var hedge := _uid_of("t_long")
	s.select([lamp, hedge])
	# Multi-select move towards the house (x 3..5, y 3..5): the third step is refused.
	var moved := 0
	for i in 5:
		if s.nudge(Vector2i(1, 0)):
			moved += 1
	assert_eq(moved, 2, "group nudge stops right before the landmark")
	assert_has(str(msgs.back()[0]), "Fixed landmark: Test House")
	assert_eq(layout.get_obj(lamp).origin, Vector2i(2, 4))
	_invariants("multi-select nudge")
	assert_false(layout.get_obj(lamp).rect().intersects(map.landmark("house").rect()), "lamp never entered the house")
	var r := PlacementRules.check_group_move(layout, map, [lamp, hedge], Vector2i(1, 0))
	assert_true(r.reason_counts.has(PlacementRules.LANDMARK), "drag preview explains the landmark")
	# Raw drag/move commands with every uid (and bogus ones) never touch landmarks.
	var all := layout.objects.keys()
	s.execute(EditCommands.MoveObjects.new(all + [-1, 0, 9999], Vector2i(3, 3)))
	_invariants("raw MoveObjects")
	var flips: Array = []
	for i in all.size() + 1:
		flips.append(true)
	s.execute(EditCommands.SetProperty.new(all + [-1], "flipped", flips))
	_invariants("raw flip")
	s.execute(EditCommands.RemoveObjects.new([-1, 0, 9999]))
	_invariants("raw remove of unknown uids")
	s.stack.undo()
	s.stack.undo()
	s.stack.undo()
	_invariants("undo")
	s.stack.redo()
	s.stack.redo()
	_invariants("redo")
	# Group / ungroup / duplicate / cut / bulk clear.
	s.select_all()
	s.group_selection()
	_invariants("group")
	s.select([_uid_of("t_lamp")])
	assert_eq(s.selection.size(), layout.count(), "clicking one member selects the whole group")
	s.ungroup_selection()
	_invariants("ungroup")
	s.select_all()
	var n := s.copy_selection()
	assert_eq(n, layout.count(), "every ordinary object (incl. obstacles) can be copied")
	var dup := s.place_objects(s.clipboard_objects(Vector2i(0, 12)), "Duplicate")
	assert_eq(dup.size(), n)
	_invariants("duplicate")
	s.select_all()
	s.delete_selection()
	assert_eq(layout.count(), 0, "bulk clear removes every object")
	_invariants("bulk clear")
	for i in 8:
		s.stack.undo()
	_invariants("long undo")
	for i in 8:
		s.stack.redo()
	_invariants("long redo")


func test_obstacles_can_be_removed_but_not_moved_or_rotated() -> void:
	var stump := _uid_of("w_stump")
	var o := layout.get_obj(stump)
	var at := o.origin
	s.select([stump])
	assert_true(s.editable_selection().is_empty(), "drag/nudge set leaves obstacles out")
	assert_false(s.nudge(Vector2i(1, 0)))
	assert_eq(o.origin, at)
	assert_eq(str(msgs.back()[0]), EditorSession.OBSTACLE_MOVE_TEXT)
	assert_eq(s.move_refusal_message(), EditorSession.OBSTACLE_MOVE_TEXT)
	s.flip_selection()
	assert_false(o.flipped)
	assert_eq(str(msgs.back()[0]), EditorSession.OBSTACLE_ROTATE_TEXT)
	# Mixed selection: the movable object moves, the obstacle stays.
	var lamp := _uid_of("t_lamp")
	s.select([stump, lamp])
	assert_eq(s.editable_selection(), [lamp])
	assert_true(s.nudge(Vector2i(1, 0)))
	assert_eq(o.origin, at)
	s.select([stump])
	s.delete_selection()
	assert_null(layout.get_obj(stump), "obstacles can be removed")
	s.stack.undo()
	assert_not_null(layout.get_obj(stump))
	_invariants("obstacles")


func test_world_state_edits_are_undoable_and_leave_geometry_alone() -> void:
	var before := _objects_json()
	assert_true(s.set_landmark_state("house", "broken"))
	assert_eq(layout.landmark_state("house"), "broken")
	assert_false(s.set_landmark_state("house", "no_such_state"))
	assert_true(s.set_landmark_state("house", "fixed"))
	assert_eq(layout.landmark_state("house", "?"), "?", "default state is stored as 'no override'")
	map.landmark("dock").transient = true   # only landmarks that come and go can be hidden
	assert_true(s.set_landmark_visible("dock", false))
	assert_false(layout.is_landmark_visible("dock"))
	assert_true(s.set_landmark_skin("house", "original"))
	assert_false(s.set_landmark_skin("house", "nope"))
	assert_false(s.set_landmark_state("ghost", "broken"))
	s.set_theme("winter")
	assert_eq(layout.theme(), "winter")
	assert_eq(s.stack.size(), 4, "setup + state (broken->default merged into one step) + visibility + theme; 'original' skin was a no-op")
	for i in 3:
		s.stack.undo()
	assert_eq(layout.theme(), FarmLayout.DEFAULT_THEME)
	assert_true(layout.is_landmark_visible("dock"))
	assert_eq(_objects_json(), before)
	_invariants("world state")


# --- regressions found by the integration audit ---------------------------------------

func test_permanent_landmarks_cant_be_hidden() -> void:
	## Hiding a permanent landmark removes it from the farm (not drawn, not
	## pickable, and the UI offers no switch to bring it back). Neither the
	## session nor a crafted / imported layout file may do that.
	var steps := s.stack.size()
	assert_false(map.landmark("house").can_hide())
	assert_false(s.set_landmark_visible("house", false), "a permanent landmark refuses to hide")
	assert_eq(s.stack.size(), steps, "no command")
	assert_has(str(msgs.back()[0]), "can't be removed")
	assert_true(layout.is_landmark_visible("house"))
	# A file that says "hidden" anyway: the value is kept in the file, the landmark stays.
	var d := LayoutIO.to_dict(layout)
	d["world"]["landmark_visible"] = {"house": false, "dock": false}
	var back := LayoutIO.from_dict(d, db, null, map)
	assert_true(LandmarkView.is_visible(map.landmark("house"), back), "the house is drawn whatever the file says")
	assert_true(LandmarkView.is_visible(map.landmark("dock"), back))
	for e: Dictionary in LandmarkView.entries_for(map, back, null):
		assert_true(bool(e["visible"]), "%s visible" % e["key"])
	assert_eq(LayoutIO.to_dict(back)["world"]["landmark_visible"], {"house": false, "dock": false}, "the saved value round-trips untouched")
	# A transient landmark still follows the layout.
	map.landmark("dock").transient = true
	assert_false(LandmarkView.is_visible(map.landmark("dock"), back))
	map.landmark("dock").transient = false
	_invariants("hide")


func test_undo_of_delete_restores_objects_the_world_now_owns() -> void:
	## A world change while the layout is open (e.g. a private pack whose
	## landmark replaces an item already on the farm) makes that item "fixed".
	## The objects stay; deleting one and undoing must bring it back exactly
	## (undo used to be refused by FarmLayout.add_objects -> silent loss).
	var lamp := _uid_of("t_lamp")
	var before := _objects_json()
	var m2 := FarmMap.load_file(WORLD)
	m2.landmark("dock").replaces_items = PackedStringArray(["t_lamp"])
	s.set_map(m2)
	assert_true(s.is_fixed_item("t_lamp"), "the lamp is now a landmark copy")
	assert_false(s.can_move_object(layout.get_obj(lamp)))
	s.select([lamp])
	s.delete_selection()
	assert_null(layout.get_obj(lamp), "a landmark copy left over in the layout can be removed")
	s.stack.undo()
	assert_not_null(layout.get_obj(lamp), "undo brings it back")
	assert_eq(_objects_json(), before, "exactly as it was")
	s.stack.redo()
	assert_null(layout.get_obj(lamp))
	s.stack.undo()
	# A NEW copy is still refused.
	assert_eq(s.place_objects([make_obj(db.get_item("t_lamp"), Vector2i(0, 12))], "t"), [])
	s.execute(EditCommands.AddObjects.new([make_obj(db.get_item("t_lamp"), Vector2i(1, 12))]))
	assert_eq(_objects_json(), before, "raw AddObjects still can't add a landmark copy")


func test_ordinary_buildings_and_plants_are_not_fixed() -> void:
	## With the public catalogue and map: barn, silo, production buildings,
	## animal homes, fields, trees, bushes and decorations are never treated as
	## landmarks: they can be placed, moved, rotated (when flippable), copied
	## and removed. Only catalogue entries tagged as landmark copies are fixed.
	var pdb := ItemDatabase.new()
	pdb.load_default()
	var pub := WorldLoader.load("res://data/maps/hayday_farm.json", [], "")
	var ps := EditorSession.new(FarmLayout.new(), pdb, pub)
	var per_cat := {}
	for it: ItemDef in pdb.ordered:
		var tagged := not it.landmark.is_empty() or not it.landmarks.is_empty()
		assert_eq(ps.is_fixed_item(it.id), tagged or not LayoutIO.landmark_of(it.id, it, pub).is_empty(), "%s fixed only if it is a landmark copy" % it.id)
		if tagged:
			continue
		per_cat[it.category] = int(per_cat.get(it.category, 0)) + 1
		if it.category in ["animal_home", "bush", "field", "fruit_tree", "decoration", "production", "farm_building", "flowers", "fence", "path"]:
			var o := make_obj(it, Vector2i(0, 0))
			assert_true(ps.can_remove_object(o), "%s removable" % it.id)
			assert_eq(ps.can_move_object(o), it.movable, "%s movable" % it.id)
			if it.can_place():
				assert_true(ps.can_copy_object(o), "%s copyable" % it.id)
	for cat in ["animal_home", "bush", "field", "fruit_tree", "decoration", "production", "farm_building"]:
		assert_true(int(per_cat.get(cat, 0)) > 0, "catalogue has ordinary %s items" % cat)
	# The concrete ones, edited on the real map (approximate landmarks don't block).
	var lay := ps.layout
	lay.set_unlocked(pub.all_plot_ids(), false)
	for id in ["barn", "silo", "bakery", "chicken_coop", "field", "apple_tree", "raspberry_bush", "fence"]:
		var it := pdb.get_item(id)
		assert_not_null(it, id)
		if it == null:
			continue
		var at := Vector2i(-1, -1)
		var room := it.size_for(false) + Vector2i(2, 2)
		for y in range(0, pub.size.y - room.y):
			for xx in range(0, pub.size.x - room.x):
				if at.x < 0 and PlacementRules.check_rect(lay, pub, Rect2i(Vector2i(xx, y), room)).ok:
					at = Vector2i(xx, y) + Vector2i.ONE
		assert_true(at.x >= 0, "%s: room found" % id)
		var uids := ps.place_objects([make_obj(it, at)], "Place " + id)
		assert_eq(uids.size(), 1, "%s placed" % id)
		ps.select(uids)
		assert_true(ps.nudge(Vector2i(0, 1)) or ps.nudge(Vector2i(0, -1)), "%s moves" % id)
		assert_eq(ps.copy_selection(), 1, "%s copies" % id)
		if it.flippable:
			ps.flip_selection()
			assert_true(lay.get_obj(uids[0]).flipped, "%s rotates" % id)
		ps.delete_selection()
		assert_null(lay.get_obj(uids[0]), "%s removed" % id)
		ps.stack.undo()
		assert_not_null(lay.get_obj(uids[0]), "%s back after undo" % id)
		assert_false(lay.get_obj(uids[0]).locked, "%s not locked" % id)


func test_cut_removes_only_what_was_copied() -> void:
	## Ctrl+X on a mixed selection: objects that can't be copied (here an item
	## of another area, already on the farm from an old file) must stay put.
	var lake := PlacedObject.new()
	lake.item_id = "w_lake"
	lake.origin = Vector2i(0, 12)
	lake.size = Vector2i(2, 2)
	layout.add_objects([lake])
	var lamp := _uid_of("t_lamp")
	s.select([lamp, lake.uid])
	var steps := s.stack.size()
	assert_eq(s.cut_selection(), 1, "only the lamp is copied")
	assert_eq(s.clipboard.size(), 1)
	assert_null(layout.get_obj(lamp), "the copied lamp is cut")
	assert_not_null(layout.get_obj(lake.uid), "the uncopyable object stays on the farm")
	assert_eq(s.stack.size(), steps + 1, "one undo step")
	s.stack.undo()
	assert_not_null(layout.get_obj(lamp))
	# A selected landmark: nothing is cut.
	s.select_landmark("house")
	assert_eq(s.cut_selection(), 0)
	assert_eq(s.stack.size(), steps, "no command")
	_invariants("cut")
