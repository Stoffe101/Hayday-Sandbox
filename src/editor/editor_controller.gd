class_name EditorController
extends Node
## Translates pointer/keyboard input on the farm canvas into tool behaviour.
## One continuous gesture (drag-move, paint stroke, line, rectangle, erase
## stroke) always produces exactly one undo step.
##
## Fixed landmarks (FarmMap.landmarks, drawn as renderer world entries) are
## picked pixel-accurately with ObjectRenderer.pick_any(): hovering highlights
## one, clicking selects it (EditorSession.select_landmark), and trying to drag,
## erase, eyedrop or rotate one only emits `fixed_refused` with the session's
## friendly explanation (main.gd shows it near the cursor). Box selection only
## ever selects placed objects.

signal status_changed(text: String)
signal hover_changed(tile: Vector2i, uid: int)
signal request_text(title: String, initial: String, callback: Callable)
signal request_context_menu(screen_pos: Vector2, uid: int)
signal plot_hovered(plot_id: String)
signal calibration_point(world: Vector2)
## An edit was refused because the target is a fixed landmark (text from
## EditorSession.explain_fixed; screen_pos = where the pointer is).
signal fixed_refused(text: String, screen_pos: Vector2)
## The hovered fixed landmark changed ("" = none).
signal landmark_hovered(id: String)
signal request_landmark_menu(screen_pos: Vector2, landmark_id: String)

const DRAG_THRESHOLD := 5.0

var camera: FarmCamera
var renderer: ObjectRenderer
var overlay: EditorOverlay
var ground: GroundLayer
var session: EditorSession

var _press_pos := Vector2.ZERO
var _press_tile := Vector2i.ZERO
var _press_button := 0
var _dragging := false
var _gesture := ""             ## pan | move | marquee | paint | line | rect | erase | erase_rect | zone | stamp
var _move_uids: Array = []
var _move_delta := Vector2i.ZERO
var _paint_objs: Array = []
var _paint_tiles: Dictionary = {}
var _erase_uids: Dictionary = {}
var _space_down := false
var _last_mouse := Vector2.ZERO
var _hover_tile := Vector2i.ZERO
var _hover_uid := 0
var _hover_lm := ""
var _press_lm := ""            ## landmark under the pointer when the gesture started
var stamp_mode := false        ## pasting the clipboard
var calibrating := false       ## screenshot reference calibration clicks


func bind(s: EditorSession) -> void:
	session = s
	_cancel_gesture()
	stamp_mode = false
	_update_overlay_state()


func world_at(screen: Vector2) -> Vector2:
	return camera.screen_to_world(screen)


func tile_at(screen: Vector2) -> Vector2i:
	return Iso.world_to_tile(world_at(screen))


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func handle_input(event: InputEvent) -> bool:
	if session == null:
		return false
	if event is InputEventMouseButton:
		return _mouse_button(event)
	if event is InputEventMouseMotion:
		_mouse_motion(event)
		return true
	if event is InputEventMagnifyGesture:
		camera.zoom_at(_last_mouse, event.factor)
		return true
	if event is InputEventPanGesture:
		camera.pan_screen(-event.delta * 12.0)
		return true
	return false


func _mouse_button(e: InputEventMouseButton) -> bool:
	_last_mouse = e.position
	if e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
		camera.zoom_at(e.position, 1.15)
		return true
	if e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		camera.zoom_at(e.position, 1.0 / 1.15)
		return true
	if e.button_index == MOUSE_BUTTON_MIDDLE or (e.button_index == MOUSE_BUTTON_LEFT and (_space_down or session.tool == "pan")):
		if e.pressed:
			_begin(e, "pan")
		else:
			_end(e)
		return true
	if e.button_index == MOUSE_BUTTON_RIGHT:
		if e.pressed:
			_press_pos = e.position
			_press_button = MOUSE_BUTTON_RIGHT
			_gesture = "rpan"
			_dragging = false
		else:
			if not _dragging:
				_right_click(e.position)
			_cancel_gesture_soft()
		return true
	if e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			if e.double_click and session.tool == "select":
				_double_click(e.position)
				return true
			_left_press(e)
		else:
			_end(e)
		return true
	return false


func _begin(e: InputEventMouseButton, gesture: String) -> void:
	_press_pos = e.position
	_press_tile = tile_at(e.position)
	_press_button = e.button_index
	_gesture = gesture
	_dragging = false


func _mouse_motion(e: InputEventMouseMotion) -> void:
	var prev := _last_mouse
	_last_mouse = e.position
	if _gesture == "pan" or (_gesture == "rpan" and (e.button_mask & MOUSE_BUTTON_MASK_RIGHT)):
		if _gesture == "rpan" and not _dragging and e.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_dragging = true
		if _gesture == "pan" or _dragging:
			camera.pan_screen(e.position - prev)
		return
	if not _gesture.is_empty() and not _dragging and e.position.distance_to(_press_pos) > DRAG_THRESHOLD:
		_dragging = true
		_start_drag()
	var t := tile_at(e.position)
	_hover_tile = t
	if _dragging:
		_update_drag(t, e.position)
	else:
		_update_hover(t, e.position)
	overlay.cursor_world = world_at(e.position)
	overlay.refresh()


func pick_at(w: Vector2) -> Dictionary:
	## Top-most placed object or fixed landmark under a world point:
	## {"kind": "object" | "landmark" | "", "uid": int, "id": landmark id}.
	var r := renderer.pick_any(w)
	var kind := str(r.get("kind", ""))
	var lid := ""
	if kind == "landmark":
		lid = LandmarkView.id_of(str(r.get("key", "")))
		if lid.is_empty() or session.map == null or session.map.landmark(lid) == null:
			kind = ""
	return {"kind": kind, "uid": int(r.get("uid", 0)) if kind == "object" else 0, "id": lid}


func _refuse_fixed(landmark_id: String, action: String, screen: Vector2) -> void:
	var why := session.explain_fixed(landmark_id, action)
	if not why.is_empty():
		fixed_refused.emit(why, screen)


func _update_hover(t: Vector2i, screen: Vector2) -> void:
	var w := world_at(screen)
	var uid := 0
	var lid := ""
	if session.tool in ["select", "erase", "pick"] and not stamp_mode:
		var hit := pick_at(w)
		uid = hit["uid"]
		lid = hit["id"]
	_hover_uid = uid
	overlay.hover_uid = uid
	if lid != _hover_lm:
		_hover_lm = lid
		var lm: Landmark = session.map.landmark(lid) if not lid.is_empty() else null
		overlay.landmark_hover = lm.rect() if lm else Rect2i()
		landmark_hovered.emit(lid)
	overlay.hover_tile = t
	overlay.show_hover_tile = session.tool in ["select", "annotate"]
	overlay.line_tiles = []
	if session.tool == "place" or stamp_mode:
		_update_place_ghost(t)
	else:
		overlay.ghosts = []
		overlay.ghost_result = null
		overlay.cursor_text = ""
	if session.tool == "land":
		var pid := session.map.plot_id_at(t)
		var blocked := not pid.is_empty() and not plot_unlock_block(pid).is_empty()
		if ground.highlight_plot != pid or ground.highlight_blocked != blocked:
			ground.highlight_plot = pid
			ground.highlight_blocked = blocked
			ground.queue_redraw()
		plot_hovered.emit(pid)
	hover_changed.emit(t, uid)
	_status_for_hover(t, uid)


func _status_for_hover(t: Vector2i, uid: int) -> void:
	var parts := PackedStringArray(["Tile %d, %d" % [t.x, t.y]])
	var k := session.map.kind_at(t)
	match k:
		FarmMap.Kind.PLOT:
			var pid := session.map.plot_id_at(t)
			var p := session.map.plot(pid)
			var open := session.map.is_plot_unlocked(pid, session.layout.unlocked_plots)
			var txt := "%s (%s)" % [p.get("name", "Plot"), "unlocked" if open else "locked"]
			if not open and session.tool == "land":
				var why := plot_unlock_block(pid)
				if not why.is_empty():
					txt += " · " + why
			parts.append(txt)
		FarmMap.Kind.ROAD: parts.append("Road")
		FarmMap.Kind.WATER: parts.append("Water")
		FarmMap.Kind.VOID: parts.append("Outside the farm")
		FarmMap.Kind.SCENERY, FarmMap.Kind.BLOCKED: parts.append("Restricted")
	if uid != 0:
		var o := session.layout.get_obj(uid)
		var it := session.db.get_item(o.item_id) if o else null
		if o:
			parts.append("%s · %d×%d%s%s" % [it.name if it else o.item_id + " (unknown)", o.size.x, o.size.y,
				" · locked" if o.locked else "", " · planned" if o.planned else ""])
	elif not _hover_lm.is_empty():
		var lm := session.map.landmark(_hover_lm)
		if lm:
			parts.append("%s · fixed landmark (part of the farm)" % lm.name)
	status_changed.emit("   ·   ".join(parts))


# ---------------------------------------------------------------------------
# Placement ghost
# ---------------------------------------------------------------------------

func ghost_origin(item: ItemDef, t: Vector2i) -> Vector2i:
	var sz := item.size_for(session.place_flipped and item.flippable)
	return t - Vector2i((sz.x - 1) / 2, (sz.y - 1) / 2)


func _update_place_ghost(t: Vector2i) -> void:
	if stamp_mode:
		var size := session.clipboard_size()
		var at := t - Vector2i((size.x - 1) / 2, (size.y - 1) / 2)
		var rects: Array = []
		var gs: Array = []
		for c in session.clipboard:
			var it := session.db.get_item(c["item"])
			gs.append({"item": it, "origin": at + (c["offset"] as Vector2i), "flipped": c["flipped"], "variant": c["variant"]})
			rects.append(Rect2i(at + (c["offset"] as Vector2i), c["size"]))
		overlay.ghosts = gs
		overlay.ghost_result = PlacementRules.check_stamp(session.layout, session.map, rects)
		overlay.cursor_text = "Paste %d object%s%s" % [gs.size(), "" if gs.size() == 1 else "s", "" if overlay.ghost_result.ok else " — " + overlay.ghost_result.message(session.layout, session.db, session.map)]
		return
	var item := session.db.get_item(session.active_item)
	if item == null:
		overlay.ghosts = []
		overlay.ghost_result = null
		overlay.cursor_text = "Pick an item from the catalogue"
		return
	var origin := ghost_origin(item, t)
	var flipped := session.place_flipped and item.flippable
	var g := {"item": item, "origin": origin, "flipped": flipped, "variant": session.place_variant}
	if not item.connect_group.is_empty():
		g["mask"] = _preview_mask(item, origin)
	overlay.ghosts = [g]
	var r := PlacementRules.check_item(session.layout, session.map, item, origin, flipped)
	overlay.ghost_result = r
	var txt := "%s · %d×%d" % [item.name, item.size_for(flipped).x, item.size_for(flipped).y]
	if not item.is_footprint_trusted():
		txt += " · size unverified"
	if not r.ok:
		txt += "\n" + r.message(session.layout, session.db, session.map)
	overlay.cursor_text = txt


func _preview_mask(item: ItemDef, origin: Vector2i) -> int:
	var mask := 0
	for bit in Connections.DIRS:
		var n := session.layout.object_at(origin + (Connections.DIRS[bit] as Vector2i))
		if n:
			var nit := session.db.get_item(n.item_id)
			if nit and nit.connect_group == item.connect_group:
				mask |= bit
	return mask


# ---------------------------------------------------------------------------
# Press / drag / release per tool
# ---------------------------------------------------------------------------

func _left_press(e: InputEventMouseButton) -> void:
	_begin(e, "")
	var w := world_at(e.position)
	if calibrating:
		calibration_point.emit(w)
		return
	if e.alt_pressed and session.tool in ["select", "place"]:
		_eyedrop(w)
		return
	if stamp_mode:
		_gesture = "stamp"
		return
	_press_lm = ""
	match session.tool:
		"select":
			var hit := pick_at(w)
			var uid: int = hit["uid"]
			if hit["kind"] == "landmark":
				# Fixed landmark: select it (its own card in the inspector);
				# dragging it only explains that it is fixed.
				_press_lm = hit["id"]
				session.select_landmark(_press_lm)
				_gesture = "landmark"
			elif uid != 0:
				if e.shift_pressed or e.ctrl_pressed:
					session.select([uid], true)
				elif not uid in session.selection:
					session.select([uid])
				_gesture = "move"
			else:
				_gesture = "marquee"
		"place":
			if e.ctrl_pressed:
				_gesture = "rect"
			elif e.shift_pressed or session.brush == "line":
				_gesture = "line"
			elif session.brush == "rect":
				_gesture = "rect"
			else:
				_gesture = "paint"
				_paint_objs = []
				_paint_tiles = {}
				_paint_at(_press_tile)
		"erase":
			_erase_uids = {}
			if e.shift_pressed:
				_gesture = "erase_rect"
			else:
				_gesture = "erase"
				_erase_at(w)
		"pick":
			_eyedrop(w)
		"land":
			_toggle_plot(session.map.plot_id_at(_press_tile), e.shift_pressed)
		"annotate":
			_gesture = "zone"


func _start_drag() -> void:
	match _gesture:
		"landmark":
			_refuse_fixed(_press_lm, "drag", _press_pos)
			_gesture = "landmark_held"
		"move":
			_move_uids = session.editable_selection()
			if _move_uids.is_empty():
				_gesture = "marquee" if session.selection.is_empty() else ""
				if not session.selection.is_empty():
					var why := session.move_refusal_message()
					if why.is_empty() or why.begins_with("Locked"):
						session.message.emit("Locked objects can't be moved — unlock with L", "warn")
					else:
						fixed_refused.emit(why, _press_pos)   # obstacles: subtle hint near the cursor
				return
			renderer.set_hidden(_move_uids)
			_move_delta = Vector2i.ZERO


func _update_drag(t: Vector2i, screen: Vector2) -> void:
	match _gesture:
		"move":
			_move_delta = t - _press_tile
			var gs: Array = []
			for u in _move_uids:
				var o := session.layout.get_obj(u)
				var it := session.db.get_item(o.item_id)
				var g := {"item": it, "origin": o.origin + _move_delta, "flipped": o.flipped, "variant": o.variant}
				if it == null:
					g["item"] = null
				gs.append(g)
			overlay.ghosts = gs
			overlay.ghost_result = PlacementRules.check_group_move(session.layout, session.map, _move_uids, _move_delta)
			overlay.cursor_text = "Move %d · Δ %d, %d%s" % [_move_uids.size(), _move_delta.x, _move_delta.y,
				"" if overlay.ghost_result.ok else "\n" + overlay.ghost_result.message(session.layout, session.db, session.map)]
		"marquee", "erase_rect", "zone":
			var a := world_at(_press_pos)
			var b := world_at(screen)
			if _gesture == "marquee":
				overlay.marquee = Rect2(a, b - a)
			else:
				var r := Iso.rect_from_corners(_press_tile, t)
				overlay.marquee = Rect2()
				overlay.ghosts = []
				var res := PlacementRules.Result.new()
				for tt in Iso.tiles_of(r.position, r.size):
					res.tiles.append(tt)
					res.codes.append(PlacementRules.OCCUPIED if _gesture == "erase_rect" else PlacementRules.LOCKED_LAND)
				overlay.ghost_result = res
				overlay.cursor_text = "%d × %d" % [r.size.x, r.size.y]
		"paint":
			_paint_at(t)
		"line", "rect":
			_preview_multi(t)
		"erase":
			_erase_at(world_at(screen))


func _end(e: InputEventMouseButton) -> void:
	var g := _gesture
	var was_drag := _dragging
	_gesture = ""
	_dragging = false
	match g:
		"move":
			renderer.set_hidden([])
			if was_drag and _move_delta != Vector2i.ZERO:
				var r := PlacementRules.check_group_move(session.layout, session.map, _move_uids, _move_delta)
				if r.ok:
					session.execute(EditCommands.MoveObjects.new(_move_uids, _move_delta))
				else:
					session.message.emit("Can't drop here: " + r.message(session.layout, session.db, session.map), "warn")
			_move_uids = []
			overlay.ghosts = []
			overlay.ghost_result = null
		"marquee":
			if was_drag:
				var uids := renderer.uids_in_world_rect(overlay.marquee.abs())
				session.select(uids, e.shift_pressed or e.ctrl_pressed)
			elif not (e.shift_pressed or e.ctrl_pressed):
				session.clear_selection()
			overlay.marquee = Rect2()
		"paint":
			_commit_paint()
		"line", "rect":
			_commit_multi(tile_at(e.position))
		"erase":
			_commit_erase()
		"erase_rect":
			var r := Iso.rect_from_corners(_press_tile, tile_at(e.position))
			for u in session.layout.uids_in_rect(r):
				_erase_uids[u] = true
			_commit_erase()
		"zone":
			var r := Iso.rect_from_corners(_press_tile, tile_at(e.position))
			_create_annotation(r, was_drag)
		"stamp":
			_commit_stamp()
	overlay.line_tiles = []
	overlay.cursor_text = ""
	_update_hover(tile_at(e.position), e.position)
	overlay.refresh()


func _cancel_gesture() -> void:
	if renderer and _gesture == "move":
		renderer.set_hidden([])
	_gesture = ""
	_press_lm = ""
	_dragging = false
	_move_uids = []
	_paint_objs = []
	if overlay:
		overlay.ghosts = []
		overlay.ghost_result = null
		overlay.marquee = Rect2()
		overlay.line_tiles = []
		overlay.refresh()


func _cancel_gesture_soft() -> void:
	_gesture = ""
	_dragging = false


func cancel() -> bool:
	## Esc: cancel the innermost thing. Returns true if something was cancelled.
	if calibrating:
		calibrating = false
		return true
	if not _gesture.is_empty():
		_cancel_gesture()
		return true
	if stamp_mode:
		stamp_mode = false
		_cancel_gesture()
		return true
	if session.tool != "select":
		session.set_tool("select")
		return true
	if session.has_selection():
		session.clear_selection()
		return true
	return false


# --- place tool ---------------------------------------------------------------

func _paint_at(t: Vector2i) -> void:
	var item := session.db.get_item(session.active_item)
	if item == null:
		return
	if not item.can_place():
		var why := session.item_block_reason(item.id)
		session.message.emit(why if not why.is_empty() else item.not_placeable_reason(), "warn")
		return
	var origin := ghost_origin(item, t)
	var flipped := session.place_flipped and item.flippable
	var rects: Array = []
	for o: PlacedObject in _paint_objs:
		rects.append(o.rect())
	var r := Rect2i(origin, item.size_for(flipped))
	rects.append(r)
	var res := PlacementRules.check_stamp(session.layout, session.map, rects)
	if not res.ok:
		if _paint_objs.is_empty() and not _dragging:
			session.message.emit(PlacementRules.check_item(session.layout, session.map, item, origin, flipped).message(session.layout, session.db, session.map), "warn")
		return
	var o := session.make_object(item, origin)
	_paint_objs.append(o)
	var gs: Array = []
	for po: PlacedObject in _paint_objs:
		gs.append({"item": item, "origin": po.origin, "flipped": po.flipped, "variant": po.variant})
	overlay.ghosts = gs
	overlay.ghost_result = null
	overlay.refresh()


func _commit_paint() -> void:
	if _paint_objs.is_empty():
		return
	var item := session.db.get_item(session.active_item)
	session.place_objects(_paint_objs, "Place %s" % item.name if _paint_objs.size() == 1 else "Paint %d × %s" % [_paint_objs.size(), item.name])
	App.settings.push_recent("recent_items", item.id)
	_paint_objs = []
	overlay.ghosts = []


func _multi_origins(item: ItemDef, t: Vector2i) -> Array:
	var flipped := session.place_flipped and item.flippable
	var sz := item.size_for(flipped)
	var a := ghost_origin(item, _press_tile)
	var b := ghost_origin(item, t)
	var out: Array = []
	if _gesture == "line":
		var d := b - a
		if absi(d.x) >= absi(d.y):
			var steps := absi(d.x) / sz.x
			for i in range(steps + 1):
				out.append(a + Vector2i(i * sz.x * signi(d.x) if d.x != 0 else 0, 0))
		else:
			var steps := absi(d.y) / sz.y
			for i in range(steps + 1):
				out.append(a + Vector2i(0, i * sz.y * signi(d.y)))
	else:
		var nx := absi(b.x - a.x) / sz.x + 1
		var ny := absi(b.y - a.y) / sz.y + 1
		var sx := signi(b.x - a.x) if b.x != a.x else 1
		var sy := signi(b.y - a.y) if b.y != a.y else 1
		for j in ny:
			for i in nx:
				out.append(a + Vector2i(i * sz.x * sx, j * sz.y * sy))
	return out


func _preview_multi(t: Vector2i) -> void:
	var item := session.db.get_item(session.active_item)
	if item == null:
		return
	var flipped := session.place_flipped and item.flippable
	var origins := _multi_origins(item, t)
	var gs: Array = []
	var rects: Array = []
	for o in origins:
		var g := {"item": item, "origin": o, "flipped": flipped, "variant": session.place_variant}
		gs.append(g)
		rects.append(Rect2i(o, item.size_for(flipped)))
	overlay.ghosts = gs
	overlay.ghost_result = PlacementRules.check_stamp(session.layout, session.map, rects)
	var valid := 0
	for r in rects:
		if PlacementRules.check_rect(session.layout, session.map, r).ok:
			valid += 1
	overlay.cursor_text = "%d × %s · %d fit" % [origins.size(), item.name, valid]


func _commit_multi(t: Vector2i) -> void:
	var item := session.db.get_item(session.active_item)
	if item == null:
		return
	var objs: Array = []
	var rects: Array = []
	var skipped := 0
	for o in _multi_origins(item, t):
		var r := Rect2i(o, item.size_for(session.place_flipped and item.flippable))
		if PlacementRules.check_stamp(session.layout, session.map, rects + [r]).ok:
			rects.append(r)
			objs.append(session.make_object(item, o))
		else:
			skipped += 1
	overlay.ghosts = []
	overlay.ghost_result = null
	if objs.is_empty():
		session.message.emit("Nothing fits there", "warn")
		return
	session.place_objects(objs, "%s %d × %s" % ["Line" if _gesture == "line" else "Fill", objs.size(), item.name])
	App.settings.push_recent("recent_items", item.id)
	if skipped > 0:
		session.message.emit("Placed %d, skipped %d blocked spot%s" % [objs.size(), skipped, "" if skipped == 1 else "s"], "info")


func _commit_stamp() -> void:
	var size := session.clipboard_size()
	var t := _hover_tile
	var at := t - Vector2i((size.x - 1) / 2, (size.y - 1) / 2)
	var rects: Array = []
	for c in session.clipboard:
		rects.append(Rect2i(at + (c["offset"] as Vector2i), c["size"]))
	var r := PlacementRules.check_stamp(session.layout, session.map, rects)
	if not r.ok:
		session.message.emit("Can't paste here: " + r.message(session.layout, session.db, session.map), "warn")
		return
	var uids := session.place_objects(session.clipboard_objects(at), "Paste %d object%s" % [rects.size(), "" if rects.size() == 1 else "s"])
	session.select(uids, false, false)


# --- erase / pick / land / annotate ---------------------------------------------

func _erase_at(w: Vector2) -> void:
	var hit := pick_at(w)
	if hit["kind"] == "landmark":
		_refuse_fixed(hit["id"], "erase", camera.world_to_screen(w))
		return
	var uid: int = hit["uid"]
	if uid == 0 or _erase_uids.has(uid):
		return
	var o := session.layout.get_obj(uid)
	if o.locked:
		session.message.emit("That object is locked", "warn")
		return
	_erase_uids[uid] = true
	var keys := _erase_uids.keys()
	renderer.set_hidden(keys)


func _commit_erase() -> void:
	renderer.set_hidden([])
	var uids: Array = []
	for u in _erase_uids:
		var o := session.layout.get_obj(u)
		if o and not o.locked:
			uids.append(u)
	_erase_uids = {}
	overlay.ghost_result = null
	if not uids.is_empty():
		session.execute(EditCommands.RemoveObjects.new(uids, "Erase %d object%s" % [uids.size(), "" if uids.size() == 1 else "s"]))


func _eyedrop(w: Vector2) -> void:
	var hit := pick_at(w)
	if hit["kind"] == "landmark":
		_refuse_fixed(hit["id"], "copy", camera.world_to_screen(w))
		return
	var uid: int = hit["uid"]
	if uid == 0:
		return
	var o := session.layout.get_obj(uid)
	if o == null or session.db.get_item(o.item_id) == null:
		return
	session.set_active_item(o.item_id)
	session.place_flipped = o.flipped
	session.place_variant = o.variant
	session.message.emit("Picked %s" % session.db.get_item(o.item_id).name, "info")


func plot_unlock_block(pid: String) -> String:
	## Why the plot can't be unlocked right now ("" = it can): in Realistic
	## mode a plot whose known level requirement is above the farm level
	## ("Requires level 45"). Creative mode is the full sandbox.
	if session.layout.mode != FarmLayout.MODE_REALISTIC or pid.is_empty():
		return ""
	if session.map.is_plot_unlocked(pid, session.layout.unlocked_plots):
		return ""
	var info := RealisticAnalyzer.plot_level_info(session.map, pid, RealisticAnalyzer.farm_level(session.layout))
	return "" if bool(info["ok"]) else str(info["reason"])


func _toggle_plot(pid: String, all_mode: bool) -> void:
	var map := session.map
	var old := session.layout.unlocked_plots.keys()
	var unlocked := map.canonical_unlocked(session.layout.unlocked_plots)
	var new_list: Array = unlocked.keys()
	var realistic := session.layout.mode == FarmLayout.MODE_REALISTIC
	var label := ""
	if all_mode:
		var all_open := true
		for p in map.all_plot_ids():
			all_open = all_open and unlocked.has(p)
		if all_open:
			new_list = []
			label = "Lock all land"
		else:
			new_list = []
			var skipped := 0
			for p in map.all_plot_ids():
				if unlocked.has(p) or plot_unlock_block(p).is_empty():
					new_list.append(p)
				else:
					skipped += 1
			label = "Unlock all land"
			if skipped > 0:
				session.message.emit("%d plot%s need a higher farm level and stay locked" % [skipped, "" if skipped == 1 else "s"], "info")
	elif pid.is_empty():
		return
	elif map.is_plot_unlocked(pid, unlocked):
		new_list.erase(map.resolve_plot_id(pid))
		label = "Lock " + str(map.plot(pid).get("name", pid))
	else:
		var why := plot_unlock_block(pid)
		if not why.is_empty():
			session.message.emit("%s: %s (your farm is level %d)" % [str(map.plot(pid).get("name", pid)), why, RealisticAnalyzer.farm_level(session.layout)], "warn")
			return
		var cid := map.resolve_plot_id(pid)
		new_list.append(cid)
		label = "Unlock " + str(map.plot(pid).get("name", pid))
		if realistic and not cid in map.unlockable_plots(unlocked):
			session.message.emit("Note: in the game this plot only unlocks after a neighbouring plot", "warn")
	# Ids of other maps (kept by the layout) stay as they are.
	for k in old:
		if not map.has_plot(str(k)) and not k in new_list:
			new_list.append(k)
	session.execute(EditCommands.SetLand.new(old, new_list, label))


func annotation_at(t: Vector2i) -> int:
	## Index of the topmost annotation covering tile t, or -1.
	for i in range(session.layout.annotations.size() - 1, -1, -1):
		var a: Dictionary = session.layout.annotations[i]
		var r: Array = a.get("rect", [0, 0, 1, 1])
		if Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])).has_point(t):
			return i
	return -1


func _edit_annotation(idx: int) -> void:
	var a: Dictionary = session.layout.annotations[idx]
	request_text.emit("Edit note (clear the text to delete it)", str(a.get("text", "")), func(text: String):
		var old := session.layout.annotations.duplicate(true)
		var list := session.layout.annotations.duplicate(true)
		if text.strip_edges().is_empty():
			list.remove_at(idx)
			session.execute(EditCommands.SetAnnotations.new(old, list, "Delete note"))
		else:
			list[idx]["text"] = text.strip_edges()
			session.execute(EditCommands.SetAnnotations.new(old, list, "Edit note")))


func _create_annotation(r: Rect2i, as_zone: bool) -> void:
	if not as_zone:
		var existing := annotation_at(r.position)
		if existing >= 0:
			_edit_annotation(existing)
			return
	var kind := "zone" if as_zone else "label"
	request_text.emit("Zone name" if as_zone else "Note text", "", func(text: String):
		if text.strip_edges().is_empty() and not as_zone:
			return
		var old := session.layout.annotations.duplicate(true)
		var list := session.layout.annotations.duplicate(true)
		var colors := ["#4b7fc4", "#e0853a", "#8a62b5", "#3e9e9a", "#c75d8e", "#6aa84f"]
		list.append({"id": session.layout.next_annotation, "kind": kind, "rect": [r.position.x, r.position.y, r.size.x, r.size.y],
			"text": text.strip_edges(), "color": colors[session.layout.next_annotation % colors.size()]})
		session.layout.next_annotation += 1
		session.execute(EditCommands.SetAnnotations.new(old, list, "Add " + kind)))


func _right_click(screen: Vector2) -> void:
	if stamp_mode or session.tool == "place":
		stamp_mode = false
		session.set_tool("select")
		_cancel_gesture()
		return
	var hit := pick_at(world_at(screen))
	if hit["kind"] == "landmark":
		session.select_landmark(hit["id"])
		request_landmark_menu.emit(screen, hit["id"])
		return
	var uid: int = hit["uid"]
	if uid != 0 and not uid in session.selection:
		session.select([uid])
	request_context_menu.emit(screen, uid)


func _double_click(screen: Vector2) -> void:
	var hit := pick_at(world_at(screen))
	if hit["kind"] == "landmark":
		session.select_landmark(hit["id"])
		return
	var uid: int = hit["uid"]
	if uid == 0:
		return
	var o := session.layout.get_obj(uid)
	var same: Array = []
	for p: PlacedObject in session.layout.objects.values():
		if p.item_id == o.item_id:
			same.append(p.uid)
	session.select(same, false, false)
	session.message.emit("Selected all %d × %s" % [same.size(), session.db.get_item(o.item_id).name if session.db.get_item(o.item_id) else o.item_id], "info")


func start_stamp() -> void:
	if session.clipboard.is_empty():
		session.message.emit("Clipboard is empty", "warn")
		return
	stamp_mode = true
	session.set_tool("select")
	_update_place_ghost(_hover_tile)
	overlay.refresh()


func clear_hover() -> void:
	## Pointer left the canvas: forget the hovered object / landmark.
	_hover_uid = 0
	if not _hover_lm.is_empty():
		_hover_lm = ""
		overlay.landmark_hover = Rect2i()
		landmark_hovered.emit("")


func set_space(down: bool) -> void:
	_space_down = down


func refresh_hover() -> void:
	_update_hover(_hover_tile, _last_mouse)
	overlay.refresh()


func _update_overlay_state() -> void:
	if overlay and session:
		overlay.selection = session.selection
		overlay.refresh()
