class_name PlanController
extends Node
## The planning-area tool (docs/PLANNING.md §3): draws a rectangle (drag) or a
## polygon (click corners; double-click, Enter or a click on the first corner
## closes it; Backspace removes the last corner; Esc or right-click cancels) and
## adds it as ONE undoable SetPlanning step through the PlanContext. Also
## "Area from selection". Like LayoutToolController it sees canvas input before
## EditorController (main.gd asks handle_input() first) and only while armed;
## camera input (wheel, middle / right drag, Space) always passes through.

signal finished(area_id: String)       ## an area was added ("" = cancelled)
signal status(text: String)

var ctx: PlanContext
var overlay: PlanOverlay
var controller: Node                   ## EditorController (tile_at / world_at, Space state)
var kind := ""                         ## "" | "rect" | "polygon"
var _points: Array = []                ## polygon corners (Vector2i)
var _pressing := false
var _press_tile := Vector2i.ZERO
var _last_click_ms := -100000


func setup(context: PlanContext, plan_overlay: PlanOverlay, editor_controller: Node) -> void:
	ctx = context
	overlay = plan_overlay
	controller = editor_controller


func active() -> bool:
	return not kind.is_empty()


func begin(k: String) -> void:
	## Arms the tool ("rect" | "polygon"); the next gesture on the canvas draws.
	if not k in ["rect", "polygon"] or ctx == null or ctx.session == null:
		return
	cancel()
	kind = k
	if ctx.session.tool != "select":
		ctx.session.set_tool("select")
	overlay.draft_kind = k
	status.emit(_hint())


func cancel() -> bool:
	## Esc: ends the tool without adding anything. True when it was armed.
	var was := active()
	kind = ""
	_points = []
	_pressing = false
	if overlay != null:
		overlay.draft_kind = ""
		overlay.draft_points = []
		overlay.draft_rect = Rect2i()
		overlay.refresh()
	if was:
		status.emit("")
		finished.emit("")
	return was


func _hint() -> String:
	if kind == "rect":
		return "Area: drag a rectangle on the farm · Esc cancels"
	return "Area: click the corners · double-click, Enter or the first corner closes · Backspace undoes a corner · Esc cancels"


func _unhandled_input(e: InputEvent) -> void:
	if not active() or not e is InputEventKey or not e.pressed or e.echo:
		return
	match (e as InputEventKey).keycode:
		KEY_ESCAPE:
			cancel()
			get_viewport().set_input_as_handled()
		KEY_ENTER, KEY_KP_ENTER:
			if kind == "polygon":
				close_polygon()
			get_viewport().set_input_as_handled()
		KEY_BACKSPACE, KEY_DELETE:
			if kind == "polygon" and not _points.is_empty():
				_points.pop_back()
				_sync_draft()
			get_viewport().set_input_as_handled()


# --- canvas input ------------------------------------------------------------------------

func handle_input(e: InputEvent) -> bool:
	if not active() or _passes_through(e):
		return false
	if e is InputEventMouseMotion:
		var g: Vector2 = Iso.world_to_grid(controller.call("world_at", e.position))
		overlay.draft_cursor = Vector2(PlanScope.snap_corner(g)) if kind == "polygon" else g
		if kind == "rect" and _pressing:
			overlay.draft_rect = Iso.rect_from_corners(_press_tile, controller.call("tile_at", e.position))
		overlay.refresh()
		return true
	if e is InputEventMouseButton:
		var b := e as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_RIGHT:
			if b.pressed:
				cancel()
			return true
		if b.button_index != MOUSE_BUTTON_LEFT:
			return true
		if kind == "rect":
			_rect_button(b)
		else:
			_polygon_button(b)
		return true
	return false


func _passes_through(e: InputEvent) -> bool:
	if e is InputEventMagnifyGesture or e is InputEventPanGesture:
		return true
	if controller != null and controller.get("_space_down"):
		return true
	if e is InputEventMouseButton:
		return e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]
	if e is InputEventMouseMotion:
		return (e.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) != 0
	return false


func _rect_button(b: InputEventMouseButton) -> void:
	var t: Vector2i = controller.call("tile_at", b.position)
	if b.pressed:
		_pressing = true
		_press_tile = t
		overlay.draft_rect = Rect2i(t, Vector2i.ONE)
		overlay.refresh()
		return
	if not _pressing:
		return
	_pressing = false
	add_rect(Iso.rect_from_corners(_press_tile, t))


func _polygon_button(b: InputEventMouseButton) -> void:
	if not b.pressed:
		return
	var p := PlanScope.snap_corner(Iso.world_to_grid(controller.call("world_at", b.position)))
	var now := Time.get_ticks_msec()
	var dbl: bool = b.double_click or (now - _last_click_ms < 350 and not _points.is_empty() and _points[_points.size() - 1] == p)
	_last_click_ms = now
	if dbl or (_points.size() >= 3 and p == _points[0]):
		close_polygon()
		return
	if _points.is_empty() or _points[_points.size() - 1] != p:
		_points.append(p)
	_sync_draft()


func _sync_draft() -> void:
	overlay.draft_points = _points.duplicate()
	overlay.draft_valid = _points.size() < 3 or PlanScope.polygon_ok(_points)
	overlay.refresh()
	status.emit("%s · %d corner%s" % [_hint(), _points.size(), "" if _points.size() == 1 else "s"])


func close_polygon() -> String:
	## Finishes the polygon (needs 3+ corners enclosing some ground).
	if kind != "polygon":
		return ""
	if not PlanScope.polygon_ok(_points):
		ctx.toast("An area needs at least three corners around some ground", "info")
		return ""
	return add_polygon(_points)


# --- adding areas (one undo step each) ---------------------------------------------------------

func add_rect(r: Rect2i, area_name: String = "") -> String:
	var rec := PlanScope.rect_area(r, area_name if not area_name.is_empty() else PlanScope.next_area_name(ctx.plan()))
	return _add(rec)


func add_polygon(points: Array, area_name: String = "") -> String:
	var rec := PlanScope.polygon_area(PlanScope.clean_polygon(points), area_name if not area_name.is_empty() else PlanScope.next_area_name(ctx.plan()))
	return _add(rec)


func area_from_selection() -> String:
	## Rectangle around the selected objects' footprints.
	if ctx == null or ctx.session == null:
		return ""
	var r := PlanScope.selection_rect(ctx.session.layout, ctx.session.selection)
	if r.size == Vector2i.ZERO:
		ctx.toast("Select some objects first", "info")
		return ""
	return add_rect(r)


func _add(rec: Dictionary) -> String:
	var plan := ctx.plan()
	var id := PlanDoc.next_id(plan, "a")
	var area_label := str(rec.get("name", ""))
	ctx.set_plan(PlanDoc.with_area(plan, rec), "Add area “%s”" % area_label)
	kind = ""
	_points = []
	_pressing = false
	overlay.draft_kind = ""
	overlay.draft_points = []
	overlay.draft_rect = Rect2i()
	overlay.refresh()
	ctx.set_active_area(id)
	status.emit("")
	ctx.toast("Added area “%s” (Ctrl+Z undoes it)" % area_label, "success")
	finished.emit(id)
	return id
