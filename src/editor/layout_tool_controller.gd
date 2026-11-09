class_name LayoutToolController
extends Node
## Pointer gestures and previews of the layout tools (fence/path outline and
## line brushes, stamp placing, mirror-line picking, repeat preview). Everything
## it commits goes through EditorSession, one gesture = one undo step.
##
## main.gd offers every canvas event here first: handle_input() returns true
## when a tool consumed it, so EditorController never sees those. Previews are
## written straight into EditorOverlay's ghost fields; EditorController's hover
## clears those, so _process() puts ours back before the frame is drawn.

var controller: Node               ## EditorController
var overlay: EditorOverlay
var dock: ToolDock
var tool_overlay: ToolOverlay
var panel: StampsPanel
var stamps := StampLibrary.new()
var session: EditorSession

var mode := ""                     ## "" | "stamp" | "axis" | "repeat"
var repeat_params := {"cols": 3, "rows": 1, "gap": Vector2i.ZERO}
var active_stamp: Dictionary = {}
var _brush_active := false
var _brush_from := Vector2i.ZERO
var _ghosts: Array = []
var _result: PlacementRules.Result = null
var _augmented: Array = []


func setup(ctrl: Node, ov: EditorOverlay, tool_dock: ToolDock, world: Node, ui_root: Control, modal_parent: Control) -> void:
	controller = ctrl
	overlay = ov
	dock = tool_dock
	tool_overlay = ToolOverlay.new()
	world.add_child(tool_overlay)
	panel = StampsPanel.new()
	panel.tools = self
	panel.modal_parent = modal_parent
	panel.visible = false
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -270.0
	panel.offset_right = 270.0
	panel.offset_top = 82.0
	panel.offset_bottom = 392.0
	ui_root.add_child(panel)
	ui_root.move_child(panel, modal_parent.get_index())
	dock.tool_action.connect(_on_dock)


func bind(s: EditorSession) -> void:
	if session != null and session != s and session.tool_changed.is_connected(_on_tool_changed):
		session.tool_changed.disconnect(_on_tool_changed)
		session.selection_changed.disconnect(_on_selection_changed)
		session.history_changed.disconnect(_on_history_changed)
		session.tools_changed.disconnect(_on_tools_changed)
	session = s
	cancel()
	if not s.tool_changed.is_connected(_on_tool_changed):
		s.tool_changed.connect(_on_tool_changed)
		s.selection_changed.connect(_on_selection_changed)
		s.history_changed.connect(_on_history_changed)
		s.tools_changed.connect(_on_tools_changed)
	_on_tools_changed()
	_update_dock()
	panel.refresh()


func cancel() -> bool:
	## Esc / tool change: end whatever is armed. True when something was.
	var had := not mode.is_empty() or _brush_active
	_brush_active = false
	mode = ""
	active_stamp = {}
	_clear_preview()
	if session != null:
		_on_tools_changed()
	_update_dock()
	return had


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_ESCAPE and session != null:
		if cancel():
			get_viewport().set_input_as_handled()


func _on_tool_changed() -> void:
	if not mode.is_empty():
		cancel()


func _on_selection_changed() -> void:
	_update_dock()
	if mode == "repeat":
		_update_repeat_preview()


func _on_history_changed() -> void:
	if mode == "repeat":
		_update_repeat_preview()


func _on_tools_changed() -> void:
	var sym: Dictionary = session.symmetry
	if bool(sym["enabled"]) or mode == "axis":
		tool_overlay.show_line(session.mirror_line(), Rect2i(Vector2i.ZERO, session.map.size) if session.map else Rect2i())
	else:
		tool_overlay.clear()
	if dock:
		dock.update_symmetry(bool(sym["enabled"]), str(sym["kind"]))


func _update_dock() -> void:
	if dock == null or session == null:
		return
	dock.update_context(session.selection.size(), session.movable_selection().size(), mode == "repeat")
	if not mode.is_empty():
		dock.set_status(_mode_hint())


func _mode_hint() -> String:
	match mode:
		"stamp":
			return "Click to place “%s” · right-click or Esc to stop" % str(active_stamp.get("name", ""))
		"axis":
			return "Click a tile to put the mirror line through it · Esc to cancel"
		"repeat":
			return "Repeat preview · change the counts below, then Apply"
	return ""


# --- dock actions ---------------------------------------------------------------------

func _on_dock(a: String, arg: Variant) -> void:
	if session == null:
		return
	match a:
		"symmetry":
			session.set_symmetry_enabled(bool(arg))
		"symmetry_kind":
			session.set_symmetry_kind(str(arg))
		"symmetry_pick":
			begin_pick_axis()
		"repeat":
			set_repeat_open(bool(arg))
		"repeat_params":
			set_repeat_params(arg)
		"repeat_apply":
			apply_repeat()
		"align":
			session.align_selection(str(arg))
		"distribute":
			session.distribute_selection(str(arg))
		"stamps":
			panel.visible = bool(arg)
			if panel.visible:
				panel.refresh()
		"save_stamp":
			panel.visible = true
			dock.set_stamps_open(true)
			panel.ask_save()


func begin_pick_axis() -> void:
	cancel()
	mode = "axis"
	_on_tools_changed()
	_update_dock()


func begin_stamp(stamp: Dictionary) -> void:
	## Arms a stamp: every click places a copy until cancelled.
	if stamp.is_empty():
		return
	cancel()
	session.set_tool("select")
	active_stamp = stamp
	mode = "stamp"
	_update_dock()


func set_repeat_open(on: bool) -> void:
	if on == (mode == "repeat"):
		return
	cancel()
	if on:
		mode = "repeat"
		_update_repeat_preview()
	_update_dock()


func set_repeat_params(p: Dictionary) -> void:
	repeat_params.merge(p, true)
	if mode == "repeat":
		_update_repeat_preview()


func apply_repeat() -> Array:
	var uids := session.apply_repeat(int(repeat_params["cols"]), int(repeat_params["rows"]), repeat_params["gap"])
	set_repeat_open(false)
	return uids


func save_selection_stamp(stamp_name: String) -> Dictionary:
	## Stores the selection as a stamp; {} when there was nothing usable.
	var st := session.make_stamp(stamp_name)
	if st.is_empty():
		return {}
	var err := stamps.save(st, session.db)
	if err != OK:
		session.message.emit("Can't save the stamp (%s)" % error_string(err), "error")
		return {}
	session.message.emit("Saved stamp “%s”" % str(st["name"]), "success")
	panel.refresh()
	return st


# --- input ----------------------------------------------------------------------------

func handle_input(e: InputEvent) -> bool:
	if session == null or _passes_through(e):
		return false
	match mode:
		"axis":
			return _axis_input(e)
		"stamp":
			return _stamp_input(e)
	return _brush_input(e)


func _passes_through(e: InputEvent) -> bool:
	## Camera input always reaches EditorController (pan, zoom).
	if e is InputEventMagnifyGesture or e is InputEventPanGesture:
		return true
	if controller.get("_space_down"):
		return true
	if e is InputEventMouseButton:
		return e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_MIDDLE]
	if e is InputEventMouseMotion:
		return (e.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) != 0
	return false


func _tile(e: InputEventMouse) -> Vector2i:
	return controller.call("tile_at", e.position)


func _axis_input(e: InputEvent) -> bool:
	if e is InputEventMouseMotion:
		var line := LayoutTools.line_for_tile(str(session.symmetry["kind"]), _tile(e))
		tool_overlay.show_line(line, Rect2i(Vector2i.ZERO, session.map.size))
		_tag(e, "Mirror line here")
		return true
	if e is InputEventMouseButton:
		if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			session.set_symmetry_tile(_tile(e))
			cancel()
		elif e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			cancel()
		return true
	return false


func _stamp_at(t: Vector2i) -> Vector2i:
	var sz: Array = active_stamp.get("size", [1, 1])
	return t - Vector2i((int(sz[0]) - 1) / 2, (int(sz[1]) - 1) / 2)


func _stamp_input(e: InputEvent) -> bool:
	if e is InputEventMouseMotion:
		_preview_stamp(_stamp_at(_tile(e)), e)
		return true
	if e is InputEventMouseButton:
		if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			var at := _stamp_at(_tile(e))
			var uids := session.place_stamp(active_stamp, at)
			if not uids.is_empty():
				session.select(uids, false, false)
			_preview_stamp(at, e)
		elif e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			cancel()
		return true
	return false


func _preview_stamp(at: Vector2i, e: InputEventMouse) -> void:
	var plan := session.stamp_plan(active_stamp, at)
	var gs: Array = []
	for o: PlacedObject in plan["objs"]:
		gs.append(_ghost_of(o))
	var shown := _with_mirror(gs, PlacementRules.check_stamp(session.layout, session.map, plan["rects"]), bool(session.symmetry["enabled"]))
	_set_preview(shown[0], shown[1])
	var n: int = (plan["objs"] as Array).size()
	_tag(e, "%s · %d fit%s" % [str(active_stamp.get("name", "")), n, "" if int(plan["skipped"]) == 0 else ", %d skipped" % int(plan["skipped"])])


func _wants_brush(e: InputEventMouseButton) -> bool:
	if session.tool != "place" or e.ctrl_pressed or e.shift_pressed or e.alt_pressed or controller.get("stamp_mode"):
		return false
	if session.brush == "outline":
		return true
	if session.brush != "line":
		return false
	var it := session.db.get_item(session.active_item)
	return it != null and not it.connect_group.is_empty()


func _brush_input(e: InputEvent) -> bool:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
			if not _wants_brush(e):
				return false
			var item := session.db.get_item(session.active_item)
			if item == null or not item.can_place():
				return false
			_brush_from = controller.call("ghost_origin", item, _tile(e))
			_brush_active = true
			_preview_brush(_tile(e), e)
			return true
		if e.button_index == MOUSE_BUTTON_LEFT and not e.pressed and _brush_active:
			_commit_brush(_tile(e))
			return true
		if e.button_index == MOUSE_BUTTON_RIGHT and e.pressed and _brush_active:
			_brush_active = false
			_clear_preview()
			return true
		return false
	if e is InputEventMouseMotion and _brush_active:
		_preview_brush(_tile(e), e)
		return true
	return false


func _brush_shape(item: ItemDef, t: Vector2i) -> Array:
	var flipped := session.place_flipped and item.flippable
	var size := item.size_for(flipped)
	var b: Vector2i = controller.call("ghost_origin", item, t)
	var origins := LayoutTools.outline_origins(_brush_from, b, size) if session.brush == "outline" else LayoutTools.line_origins(_brush_from, b, size)
	var rects: Array = []
	for o: Vector2i in origins:
		rects.append(Rect2i(o, size))
	return rects


func _preview_brush(t: Vector2i, e: InputEventMouse) -> void:
	var item := session.db.get_item(session.active_item)
	if item == null:
		return
	var flipped := session.place_flipped and item.flippable
	var rects := _brush_shape(item, t)
	var fit := LayoutTools.fit_mask(session.layout, session.map, rects)
	var masks: Array = LayoutTools.connection_masks(session.layout, session.db, item.connect_group, rects) if not item.connect_group.is_empty() else []
	var gs: Array = []
	var n := 0
	for i in rects.size():
		var g := {"item": item, "origin": (rects[i] as Rect2i).position, "flipped": flipped, "variant": session.place_variant}
		if not masks.is_empty():
			g["mask"] = masks[i]
		gs.append(g)
		n += 1 if fit[i] else 0
	var shown := _with_mirror(gs, PlacementRules.check_stamp(session.layout, session.map, rects), bool(session.symmetry["enabled"]))
	_set_preview(shown[0], shown[1])
	_tag(e, "%d × %s · %d fit" % [rects.size(), item.name, n])


func _commit_brush(t: Vector2i) -> void:
	_brush_active = false
	var item := session.db.get_item(session.active_item)
	_clear_preview()
	if item == null:
		return
	var rects := _brush_shape(item, t)
	var fit := LayoutTools.fit_mask(session.layout, session.map, rects)
	var objs: Array = []
	for i in rects.size():
		if fit[i]:
			objs.append(session.make_object(item, (rects[i] as Rect2i).position))
	if objs.is_empty():
		session.message.emit("Nothing fits there", "warn")
		return
	session.place_objects(objs, "%s %d × %s" % ["Outline" if session.brush == "outline" else "Line", objs.size(), item.name])
	var skipped := rects.size() - objs.size()
	if skipped > 0:
		session.message.emit("Placed %d, skipped %d blocked spot%s" % [objs.size(), skipped, "" if skipped == 1 else "s"], "info")


func _update_repeat_preview() -> void:
	var plan := session.repeat_plan(int(repeat_params["cols"]), int(repeat_params["rows"]), repeat_params["gap"])
	if plan.is_empty():
		_clear_preview()
		dock.set_status("Select something that can be copied")
		return
	var gs: Array = []
	for o: PlacedObject in plan["objs"]:
		gs.append(_ghost_of(o))
	_set_preview(gs, PlacementRules.check_stamp(session.layout, session.map, plan["rects"]))
	dock.set_status("Repeat: %d fit%s" % [(plan["objs"] as Array).size(), "" if int(plan["skipped"]) == 0 else ", %d blocked" % int(plan["skipped"])])


# --- previews ---------------------------------------------------------------------------

func _ghost_of(o: PlacedObject) -> Dictionary:
	return {"item": session.db.get_item(o.item_id), "origin": o.origin, "flipped": o.flipped, "variant": o.variant}


func _set_preview(gs: Array, result: PlacementRules.Result) -> void:
	_ghosts = gs
	_result = result
	overlay.ghosts = gs
	overlay.ghost_result = result
	overlay.refresh()


func _clear_preview() -> void:
	if not _ghosts.is_empty() or _result != null:
		_ghosts = []
		_result = null
		overlay.ghosts = []
		overlay.ghost_result = null
		overlay.cursor_text = ""
		overlay.refresh()


func _tag(e: InputEventMouse, text: String) -> void:
	overlay.cursor_text = text
	overlay.cursor_world = controller.call("world_at", e.position)
	overlay.refresh()


func _with_mirror(gs: Array, result: PlacementRules.Result, on: bool) -> Array:
	## [ghosts + their mirrored copies, result with the copies' tiles added].
	if not on:
		return [gs, result]
	var line := session.mirror_line()
	var out := gs.duplicate()
	var merged := PlacementRules.Result.new()
	if result != null:
		PlacementRules._merge(merged, result)
	for g: Dictionary in gs:
		var it: ItemDef = g["item"]
		if it == null:
			continue
		var r := Rect2i(g["origin"], it.size_for(g["flipped"]))
		var m := LayoutTools.mirror_placement(r, g["flipped"], it.flippable, line)
		if m.is_empty() or m["rect"] == r:
			continue
		var mg := {"item": it, "origin": (m["rect"] as Rect2i).position, "flipped": m["flipped"], "variant": g["variant"], "mirror": true}
		if g.has("mask"):
			mg["mask"] = LayoutTools.mirror_mask(g["mask"], line)
		out.append(mg)
		PlacementRules._merge(merged, PlacementRules.check_rect(session.layout, session.map, m["rect"]))
	return [out, merged]


func _process(_dt: float) -> void:
	if session == null:
		return
	if not _ghosts.is_empty():
		if not is_same(overlay.ghosts, _ghosts):
			overlay.ghosts = _ghosts
			overlay.ghost_result = _result
			overlay.refresh()
		return
	# Symmetry: show the mirrored copy next to whatever the place tool shows.
	if not bool(session.symmetry["enabled"]) or overlay.ghosts.is_empty() or is_same(overlay.ghosts, _augmented):
		return
	if session.tool != "place" or controller.get("stamp_mode"):
		return
	var shown := _with_mirror(overlay.ghosts, overlay.ghost_result, true)
	_augmented = shown[0]
	overlay.ghosts = _augmented
	overlay.ghost_result = shown[1]
	overlay.refresh()
