extends TestCase

var db: ItemDatabase
var layout: FarmLayout
var stack: CommandStack


func before_each() -> void:
	db = fixture_db()
	layout = FarmLayout.new()
	stack = CommandStack.new(layout)


func _obj(id: String, at: Vector2i) -> PlacedObject:
	return make_obj(db.get_item(id), at)


func test_add_undo_redo_keeps_uids() -> void:
	var cmd := EditCommands.AddObjects.new([_obj("t_bakery", Vector2i(1, 1))])
	stack.execute(cmd)
	assert_eq(layout.count(), 1)
	var uid: int = cmd.added_uids()[0]
	assert_eq(layout.object_at(Vector2i(2, 2)).uid, uid)
	stack.undo()
	assert_eq(layout.count(), 0)
	assert_null(layout.object_at(Vector2i(2, 2)), "occupancy cleared on undo")
	stack.redo()
	assert_eq(layout.object_at(Vector2i(2, 2)).uid, uid, "same uid after redo")


func test_remove_restores_everything() -> void:
	var o := _obj("t_long", Vector2i(3, 3))
	o.note = "keep me"
	o.planned = true
	stack.execute(EditCommands.AddObjects.new([o]))
	var uid: int = layout.objects.keys()[0]
	stack.execute(EditCommands.RemoveObjects.new([uid]))
	assert_eq(layout.count(), 0)
	stack.undo()
	var back := layout.get_obj(uid)
	assert_not_null(back)
	assert_eq(back.note, "keep me")
	assert_true(back.planned)
	assert_eq(back.size, Vector2i(1, 4))


func test_bulk_move_is_one_step() -> void:
	var objs: Array = []
	for i in 10:
		objs.append(_obj("t_lamp", Vector2i(i, 0)))
	stack.execute(EditCommands.AddObjects.new(objs))
	var uids := layout.objects.keys()
	stack.execute(EditCommands.MoveObjects.new(uids, Vector2i(0, 5)))
	assert_eq(layout.object_at(Vector2i(4, 5)).item_id, "t_lamp")
	assert_null(layout.object_at(Vector2i(4, 0)))
	assert_eq(stack.size(), 2)
	stack.undo()
	assert_not_null(layout.object_at(Vector2i(4, 0)))
	assert_null(layout.object_at(Vector2i(4, 5)))


func test_nudges_merge() -> void:
	stack.execute(EditCommands.AddObjects.new([_obj("t_lamp", Vector2i(0, 0))]))
	var uid: int = layout.objects.keys()[0]
	for i in 5:
		stack.execute(EditCommands.MoveObjects.new([uid], Vector2i(1, 0), "Nudge", "nudge"))
	assert_eq(stack.size(), 2, "five quick nudges merged into one step")
	assert_eq(layout.get_obj(uid).origin, Vector2i(5, 0))
	stack.undo()
	assert_eq(layout.get_obj(uid).origin, Vector2i(0, 0))


func test_flip_swaps_size_and_undo_restores() -> void:
	stack.execute(EditCommands.AddObjects.new([_obj("t_long", Vector2i(0, 0))]))
	var uid: int = layout.objects.keys()[0]
	stack.execute(EditCommands.SetProperty.new([uid], "flipped", [true]))
	assert_eq(layout.get_obj(uid).size, Vector2i(4, 1))
	assert_not_null(layout.object_at(Vector2i(3, 0)))
	assert_null(layout.object_at(Vector2i(0, 3)))
	stack.undo()
	assert_eq(layout.get_obj(uid).size, Vector2i(1, 4))
	assert_not_null(layout.object_at(Vector2i(0, 3)))


func test_land_command() -> void:
	stack.execute(EditCommands.SetLand.new([], ["plot_a"]))
	assert_true(layout.unlocked_plots.has("plot_a"))
	stack.undo()
	assert_false(layout.unlocked_plots.has("plot_a"))
	stack.execute(EditCommands.SetLand.new(["x"], ["x"]))
	assert_eq(stack.size(), 0, "no-op commands are skipped")


func test_dirty_tracking() -> void:
	assert_false(stack.is_dirty())
	stack.execute(EditCommands.AddObjects.new([_obj("t_lamp", Vector2i(0, 0))]))
	assert_true(stack.is_dirty())
	stack.mark_saved()
	assert_false(stack.is_dirty())
	stack.undo()
	assert_true(stack.is_dirty())
	stack.redo()
	assert_false(stack.is_dirty(), "back at save point")
	stack.undo()
	stack.execute(EditCommands.AddObjects.new([_obj("t_lamp", Vector2i(3, 3))]))
	assert_true(stack.is_dirty(), "diverged history stays dirty")


func test_history_is_bounded() -> void:
	stack.max_size = 20
	for i in 50:
		stack.execute(EditCommands.AddObjects.new([_obj("t_lamp", Vector2i(i, 0))]))
	assert_eq(stack.size(), 20)
	assert_eq(layout.count(), 50)


func test_composite_undo_order() -> void:
	stack.execute(EditCommands.AddObjects.new([_obj("t_lamp", Vector2i(0, 0))]))
	var uid: int = layout.objects.keys()[0]
	var comp := EditCommands.Composite.new([
		EditCommands.MoveObjects.new([uid], Vector2i(2, 0)),
		EditCommands.SetProperty.new([uid], "note", ["moved"]),
	], "Move and note")
	stack.execute(comp)
	assert_eq(layout.get_obj(uid).origin, Vector2i(2, 0))
	stack.undo()
	assert_eq(layout.get_obj(uid).origin, Vector2i(0, 0))
	assert_eq(layout.get_obj(uid).note, "")


# --- world state (theme / landmark look) -------------------------------------------

func test_world_state_command_undo_redo() -> void:
	var seen: Array = []
	layout.world_changed.connect(func(keys): seen.append(keys))
	stack.execute(SetWorldStateCommand.for_theme(layout, "winter"))
	assert_eq(layout.theme(), "winter")
	assert_eq(seen.back(), ["theme"], "world_changed names what changed")
	stack.execute(SetWorldStateCommand.new([
		{"field": "landmark_states", "id": "farmhouse", "value": "stage_2"},
		{"field": "landmark_skins", "id": "truck", "value": "red"},
		{"field": "landmark_visible", "id": "truck", "value": false}], "Preset", layout))
	assert_eq(stack.size(), 2, "a multi-change preset is one undo step")
	assert_eq(layout.landmark_state("farmhouse"), "stage_2")
	assert_eq(layout.landmark_skin("truck"), "red")
	assert_false(layout.is_landmark_visible("truck"))
	assert_has(seen.back(), "landmark_skins/truck")
	stack.undo()
	assert_eq(layout.landmark_state("farmhouse", "default"), "default", "undo removes the value again")
	assert_eq(layout.landmark_skin("truck"), "")
	assert_true(layout.is_landmark_visible("truck"))
	assert_false((layout.world_state["landmark_states"] as Dictionary).has("farmhouse"))
	stack.undo()
	assert_eq(layout.theme(), FarmLayout.DEFAULT_THEME)
	stack.redo()
	stack.redo()
	assert_eq(layout.theme(), "winter")
	assert_eq(layout.landmark_skin("truck"), "red")
	# null = back to the default
	stack.execute(SetWorldStateCommand.for_landmark(layout, "landmark_skins", "truck", null))
	assert_eq(layout.landmark_skin("truck"), "")
	stack.undo()
	assert_eq(layout.landmark_skin("truck"), "red")


func test_world_state_gesture_merges_and_noop() -> void:
	stack.execute(SetWorldStateCommand.for_landmark(layout, "landmark_skins", "farmhouse", "a"))
	stack.execute(SetWorldStateCommand.for_landmark(layout, "landmark_skins", "farmhouse", "b"))
	stack.execute(SetWorldStateCommand.for_landmark(layout, "landmark_skins", "farmhouse", "c"))
	assert_eq(stack.size(), 1, "scrubbing through skins is one undo step")
	assert_eq(layout.landmark_skin("farmhouse"), "c")
	stack.undo()
	assert_eq(layout.landmark_skin("farmhouse"), "", "one undo returns to the original look")
	stack.redo()
	assert_eq(layout.landmark_skin("farmhouse"), "c")
	stack.execute(SetWorldStateCommand.for_landmark(layout, "landmark_skins", "farmhouse", "c"))
	assert_eq(stack.size(), 1, "setting the current value is a no-op")
	stack.execute(SetWorldStateCommand.for_theme(layout, FarmLayout.DEFAULT_THEME))
	assert_eq(stack.size(), 1, "default theme again is a no-op")
	stack.execute(SetWorldStateCommand.new([{"field": "bogus", "id": "x", "value": 1}]))
	assert_eq(stack.size(), 1, "unknown fields are ignored")
	assert_true(stack.is_dirty())


func test_world_state_never_touches_objects() -> void:
	stack.execute(EditCommands.AddObjects.new([_obj("t_bakery", Vector2i(1, 1))]))
	var before := JsonUtil.stringify(LayoutIO.to_dict(layout)["objects"])
	stack.execute(SetWorldStateCommand.for_theme(layout, "halloween"))
	stack.execute(SetWorldStateCommand.for_landmark(layout, "landmark_states", "farmhouse", "broken"))
	stack.undo()
	stack.redo()
	assert_eq(JsonUtil.stringify(LayoutIO.to_dict(layout)["objects"]), before)


func test_set_geometry_command() -> void:
	stack.execute(EditCommands.AddObjects.new([_obj("t_long", Vector2i(2, 2))]))
	var uid: int = layout.objects.keys()[0]
	stack.execute(EditCommands.SetGeometry.new([uid], [{"size": Vector2i(1, 4), "flipped": true}]))
	assert_true(layout.get_obj(uid).flipped)
	assert_eq(layout.get_obj(uid).origin, Vector2i(2, 2))
	stack.execute(EditCommands.SetGeometry.new([uid], [{"size": Vector2i(2, 2), "flipped": true}]))
	assert_eq(layout.get_obj(uid).size, Vector2i(2, 2))
	assert_not_null(layout.object_at(Vector2i(3, 3)), "occupancy follows the new size")
	stack.undo()
	stack.undo()
	assert_false(layout.get_obj(uid).flipped)
	assert_eq(layout.get_obj(uid).size, Vector2i(1, 4))
	assert_null(layout.object_at(Vector2i(3, 3)))


func test_layout_refuses_fixed_items() -> void:
	layout.fixed_items = {"t_lamp": true}
	var cmd := EditCommands.AddObjects.new([_obj("t_lamp", Vector2i(0, 0)), _obj("t_bakery", Vector2i(3, 3))])
	stack.execute(cmd)
	assert_eq(layout.count(), 1, "the fixed item never entered layout.objects")
	assert_eq(layout.objects.values()[0].item_id, "t_bakery")
	stack.undo()
	assert_eq(layout.count(), 0)
	stack.redo()
	assert_eq(layout.count(), 1)
