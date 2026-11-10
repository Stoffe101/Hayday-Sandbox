class_name Minimap
extends PanelContainer
## Small overview of the farm in a canvas corner (View tab / Shift+M): the land
## (start land and unlocked plots, locked plots darker, road, water, fixed farm
## buildings), objects as dots in their category colour (the active phase's in
## its colour, the rest faded), planning area outlines and the camera's view
## rectangle. Click or drag on it to move the camera there.
##
## Cheap by construction: the ground and the objects are two small images, one
## pixel per tile, drawn with the isometric transform. The ground image is
## rebuilt only when the map or the land changes; object edits repaint just the
## tiles they touch (once per frame); camera moves only redraw the view rectangle.
## Never touches the layout.

signal collapse_requested(collapsed: bool)
signal hide_requested
## The camera should centre on this world point (click / drag).
signal navigate(world: Vector2)

const C_LAND := Color("#79ad57")
const C_LOCKED := Color("#4a6340")
const C_ROAD := Color("#cdb68c")
const C_WATER := Color("#4f9fd6")
const C_BLOCKED := Color("#5d6b51")
const C_SCENERY := Color("#3d5636")
const C_LANDMARK := Color("#b79466")
const C_VIEW := Color(1, 1, 1, 0.95)
const FULL_REPAINT_TILES := 6000

var layout: FarmLayout
var map: FarmMap
var db: ItemDatabase
var ctx: PlanContext
var renderer: ObjectRenderer          ## layer-hidden objects are left out
var view_rect := Rect2()              ## camera's visible world rectangle
var collapsed := false
var map_width := 220.0

var _view: MapView
var _body: VBoxContainer
var _collapse_btn: Button
var _title: Label
var _grid := Rect2i()                 ## tiles in the images (map land bounds)
## Tiles the overview frames: owned land, the objects and the planning areas
## (with a margin), within the map. Grows when something is placed outside it.
var _frame := Rect2i()
var _land_box := Rect2i()
var _obj_box := Rect2i()
const FRAME_MARGIN := 3
var _ground_img: Image
var _ground_tex: ImageTexture
var _obj_img: Image
var _obj_tex: ImageTexture
var _rects: Dictionary = {}           ## uid -> Rect2i painted
var _dirty: Dictionary = {}           ## Vector2i tile -> true
var _flush_queued := false
var _phase_set: Dictionary = {}
var _phase_key := ""
var _phase_color := Color.WHITE
var _phase_active := false
var _cat_colors: Dictionary = {}
## Diagnostics (tests): full object repaints / tiles repainted incrementally.
var full_repaints := 0
var tile_repaints := 0


class MapView:
	extends Control
	var mm: Minimap

	func _draw() -> void:
		mm._draw_map(self)

	func _gui_input(e: InputEvent) -> void:
		mm._map_input(e)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := UiTheme.box(UiTheme.c("panel"), 12, UiTheme.c("border"), 1, Vector4(8, 4, 8, 8))
	sb.shadow_color = UiTheme.c("shadow")
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 3)
	add_theme_stylebox_override("panel", sb)
	_body = UI.vbox(4)
	add_child(_body)
	var head := UI.hbox(4)
	head.add_child(UI.icon_rect("map", 14, UiTheme.c("text_dim")))
	_title = UI.label("Overview", "Dim")
	_title.add_theme_font_size_override("font_size", 12)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_collapse_btn = UI.icon_button("minus", "Collapse the overview", "Ghost", 14)
	_collapse_btn.pressed.connect(func(): collapse_requested.emit(not collapsed))
	head.add_child(_collapse_btn)
	var x := UI.icon_button("x", "Hide the overview (View tab or Shift+M shows it again)", "Ghost", 14)
	x.pressed.connect(func(): hide_requested.emit())
	head.add_child(x)
	_body.add_child(head)
	_view = MapView.new()
	_view.mm = self
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_view.clip_contents = true
	_view.tooltip_text = "Click or drag to move the view"
	_body.add_child(_view)


func set_collapsed(on: bool) -> void:
	collapsed = on
	_view.visible = not on
	_title.visible = true
	_collapse_btn.icon = Icons.get_icon("maximize-2" if on else "minus", 14)
	_collapse_btn.tooltip_text = "Show the overview" if on else "Collapse the overview"
	reset_size()


func set_map_width(w: float) -> void:
	map_width = w
	_update_view_size()


func _update_view_size() -> void:
	var aspect := 0.5
	if _frame.size != Vector2i.ZERO:
		var wb := Iso.footprint_world_bounds(_frame.position, _frame.size)
		aspect = clampf(wb.size.y / maxf(1.0, wb.size.x), 0.35, 0.9)
	_view.custom_minimum_size = Vector2(map_width, roundf(map_width * aspect))
	reset_size()


# --- binding / rebuilding -------------------------------------------------------------

func bind(l: FarmLayout, m: FarmMap, item_db: ItemDatabase, context: PlanContext, r: ObjectRenderer) -> void:
	if layout != null and layout != l:
		for pair in _signals():
			if (pair[0] as Signal).is_connected(pair[1]):
				(pair[0] as Signal).disconnect(pair[1])
	var changed := layout != l
	layout = l
	map = m
	db = item_db
	ctx = context
	renderer = r
	if changed and l != null:
		for pair in _signals():
			if not (pair[0] as Signal).is_connected(pair[1]):
				(pair[0] as Signal).connect(pair[1])
	if ctx != null and not ctx.changed.is_connected(_on_plan_changed):
		ctx.changed.connect(_on_plan_changed)
	_cat_colors.clear()
	rebuild()


func _signals() -> Array:
	return [[layout.objects_added, _on_objects], [layout.objects_removed, _on_removed],
		[layout.objects_changed, _on_objects], [layout.land_changed, rebuild_ground]]


func unbind_signals() -> void:
	## Before the widget is freed (UI rebuild): drop the layout connections.
	if layout != null:
		for pair in _signals():
			if (pair[0] as Signal).is_connected(pair[1]):
				(pair[0] as Signal).disconnect(pair[1])
	if ctx != null and ctx.changed.is_connected(_on_plan_changed):
		ctx.changed.disconnect(_on_plan_changed)


func rebuild() -> void:
	if map == null:
		return
	_grid = map.land_bounds()
	rebuild_ground()
	rebuild_objects()


static func _merge(a: Rect2i, b: Rect2i) -> Rect2i:
	if a.size == Vector2i.ZERO:
		return b
	if b.size == Vector2i.ZERO:
		return a
	return a.merge(b)


func _update_frame() -> void:
	## What the overview shows: owned land + objects + areas, with a margin.
	var f := _merge(_land_box, _obj_box)
	if ctx != null and ctx.session != null and ctx.session.layout == layout:
		for a: Dictionary in PlanDoc.areas(ctx.plan()):
			f = _merge(f, PlanDoc.area_bounds(a))
	if f.size == Vector2i.ZERO:
		f = _grid
	f = f.grow(FRAME_MARGIN).intersection(_grid)
	if f.size == Vector2i.ZERO:
		f = _grid
	if f != _frame:
		_frame = f
		_update_view_size()
		_view.queue_redraw()


func rebuild_ground() -> void:
	## Land, road, water, ownership and fixed buildings: one pixel per tile.
	if map == null or layout == null:
		return
	var sz := _grid.size
	if _ground_img == null or _ground_img.get_size() != sz:
		_ground_img = Image.create_empty(maxi(1, sz.x), maxi(1, sz.y), false, Image.FORMAT_RGBA8)
	_ground_img.fill(Color(0, 0, 0, 0))
	var unlocked := layout.unlocked_plots
	var kind_colors := {FarmMap.Kind.BUILDABLE: C_LAND, FarmMap.Kind.ROAD: C_ROAD, FarmMap.Kind.WATER: C_WATER,
		FarmMap.Kind.BLOCKED: C_BLOCKED, FarmMap.Kind.SCENERY: C_SCENERY}
	var plot_open := {}
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-1, -1)
	for y in sz.y:
		for x in sz.x:
			var t := _grid.position + Vector2i(x, y)
			var k := map.kind_at(t)
			var c: Color = kind_colors.get(k, Color(0, 0, 0, 0))
			if k == FarmMap.Kind.PLOT:
				var pid := map.plot_id_at(t)
				if not plot_open.has(pid):
					plot_open[pid] = map.is_plot_unlocked(pid, unlocked)
				c = C_LAND if plot_open[pid] else C_LOCKED
			if c.a > 0.0:
				_ground_img.set_pixel(x, y, c)
				if c == C_LAND:
					lo = lo.min(t)
					hi = hi.max(t)
	for lm: Landmark in map.landmarks:
		var r := lm.rect().intersection(_grid)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				_ground_img.set_pixel(x - _grid.position.x, y - _grid.position.y, C_LANDMARK)
	if _ground_tex == null or _ground_tex.get_size() != Vector2(_ground_img.get_size()):
		_ground_tex = ImageTexture.create_from_image(_ground_img)
	else:
		_ground_tex.update(_ground_img)
	_land_box = Rect2i(lo, hi - lo + Vector2i.ONE) if hi.x >= 0 else Rect2i()
	_update_frame()
	_view.queue_redraw()


func rebuild_objects() -> void:
	## Every object again (bind, layer or phase change, big batches).
	if layout == null or map == null:
		return
	var sz := _grid.size
	if _obj_img == null or _obj_img.get_size() != sz:
		_obj_img = Image.create_empty(maxi(1, sz.x), maxi(1, sz.y), false, Image.FORMAT_RGBA8)
	_obj_img.fill(Color(0, 0, 0, 0))
	_rects.clear()
	_dirty.clear()
	_refresh_phase_set(true)
	_obj_box = Rect2i()
	for o: PlacedObject in layout.objects.values():
		_rects[o.uid] = o.rect()
		_obj_box = _merge(_obj_box, o.rect())
		if renderer != null and renderer.is_layer_hidden(o.uid):
			continue
		var col := _color_of(o)
		var r := o.rect().intersection(_grid)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				_obj_img.set_pixel(x - _grid.position.x, y - _grid.position.y, col)
	full_repaints += 1
	_update_frame()
	_push_objects()


func _push_objects() -> void:
	if _obj_tex == null or _obj_tex.get_size() != Vector2(_obj_img.get_size()):
		_obj_tex = ImageTexture.create_from_image(_obj_img)
	else:
		_obj_tex.update(_obj_img)
	_view.queue_redraw()


func _color_of(o: PlacedObject) -> Color:
	var c: Variant = _cat_colors.get(o.item_id)
	if c == null:
		var it := db.get_item(o.item_id) if db else null
		c = db.category(it.category)["color"] if it else Color(0.6, 0.6, 0.6)
		_cat_colors[o.item_id] = c
	var col: Color = c
	if _phase_active:
		col = _phase_color if _phase_set.has(o.uid) else Color(col.r, col.g, col.b, 0.35)
	if o.planned:
		col.a *= 0.55
	return col.lightened(0.12)


func _refresh_phase_set(force: bool) -> bool:
	## The active phase's objects (painted in its colour). True when it changed.
	var pid := ctx.active_phase if ctx != null else ""
	var eng := ctx.engine if ctx != null else null
	var key := "%s|%s" % [pid, "%d/%d" % [eng.get_instance_id(), eng.version] if eng != null and not pid.is_empty() else ""]
	if key == _phase_key and not force:
		return false
	_phase_key = key
	_phase_set.clear()
	_phase_active = not pid.is_empty() and eng != null
	if _phase_active:
		var ph := PlanDoc.phase(ctx.plan(), pid)
		_phase_color = Color.from_string(str(ph.get("color", "#f2b84b")), Color("#f2b84b"))
		for u in eng.phase_uids(pid):
			_phase_set[int(u)] = true
	return true


# --- incremental object updates ---------------------------------------------------------

func _on_objects(uids: Array) -> void:
	for u in uids:
		var old: Variant = _rects.get(u)
		if old is Rect2i:
			_mark(old)
		var o := layout.get_obj(u)
		if o:
			_rects[u] = o.rect()
			_mark(o.rect())
			if not _frame.encloses(o.rect()):
				_obj_box = _merge(_obj_box, o.rect())
				_update_frame()
	_queue_flush()


func _on_removed(uids: Array) -> void:
	for u in uids:
		var old: Variant = _rects.get(u)
		if old is Rect2i:
			_mark(old)
		_rects.erase(u)
	_queue_flush()


func _mark(r: Rect2i) -> void:
	if _dirty.size() > FULL_REPAINT_TILES:
		return
	var c := r.intersection(_grid)
	for y in range(c.position.y, c.end.y):
		for x in range(c.position.x, c.end.x):
			_dirty[Vector2i(x, y)] = true


func _queue_flush() -> void:
	if _flush_queued:
		return
	_flush_queued = true
	_flush.call_deferred()


func _flush() -> void:
	_flush_queued = false
	if layout == null or _obj_img == null:
		return
	if _dirty.size() > FULL_REPAINT_TILES:
		rebuild_objects()
		return
	for t: Vector2i in _dirty:
		var col := Color(0, 0, 0, 0)
		for u in layout.occupancy.all_at(t):
			var o := layout.get_obj(int(u))
			if o != null and not (renderer != null and renderer.is_layer_hidden(o.uid)):
				col = _color_of(o)
		_obj_img.set_pixel(t.x - _grid.position.x, t.y - _grid.position.y, col)
	tile_repaints += _dirty.size()
	_dirty.clear()
	_push_objects()


func sync() -> void:
	## Catch up after being hidden (areas / phase changed meanwhile).
	_on_plan_changed()


func _on_plan_changed() -> void:
	## Areas, the active phase or its members may have changed.
	if not is_visible_in_tree():
		return
	if _refresh_phase_set(false):
		rebuild_objects()
	_update_frame()
	_view.queue_redraw()


func set_view_rect(r: Rect2) -> void:
	if r != view_rect:
		view_rect = r
		if is_visible_in_tree():
			_view.queue_redraw()


# --- drawing ----------------------------------------------------------------------------

func _world_frame() -> Rect2:
	var f := _frame if _frame.size != Vector2i.ZERO else _grid
	return Iso.footprint_world_bounds(f.position, f.size)


func world_to_map(w: Vector2) -> Vector2:
	## World point -> point in the map view (local px).
	var wf := _world_frame()
	var vs := _view.size
	var k := minf(vs.x / maxf(1.0, wf.size.x), vs.y / maxf(1.0, wf.size.y))
	var off := (vs - wf.size * k) * 0.5
	return (w - wf.position) * k + off


func map_to_world(p: Vector2) -> Vector2:
	var wf := _world_frame()
	var vs := _view.size
	var k := minf(vs.x / maxf(1.0, wf.size.x), vs.y / maxf(1.0, wf.size.y))
	var off := (vs - wf.size * k) * 0.5
	return (p - off) / maxf(k, 0.000001) + wf.position


func _grid_xform() -> Transform2D:
	## Image pixel (tile, from _grid.position) -> map view point.
	var o := world_to_map(Iso.grid_to_world(Vector2(_grid.position)))
	var ax := world_to_map(Iso.grid_to_world(Vector2(_grid.position) + Vector2(1, 0))) - o
	var ay := world_to_map(Iso.grid_to_world(Vector2(_grid.position) + Vector2(0, 1))) - o
	return Transform2D(ax, ay, o)


func _draw_map(ci: Control) -> void:
	if map == null or _ground_tex == null:
		return
	ci.draw_set_transform_matrix(_grid_xform())
	var r := Rect2(Vector2.ZERO, Vector2(_grid.size))
	ci.draw_texture_rect(_ground_tex, r, false)
	if _obj_tex != null:
		ci.draw_texture_rect(_obj_tex, r, false)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)
	if ctx != null and ctx.session != null:
		var ph := PlanDoc.phase(ctx.plan(), ctx.active_phase) if not ctx.active_phase.is_empty() else {}
		var ph_areas: Array = ph.get("areas", []) if not ph.is_empty() else []
		for a: Dictionary in PlanDoc.areas(ctx.plan()):
			if not bool(a.get("visible", true)) and str(a.get("id")) != ctx.active_area:
				continue
			var pts := PackedVector2Array()
			for p in PlanDoc.area_polygon(a):
				pts.append(world_to_map(Iso.grid_to_world(p)))
			if pts.size() < 3:
				continue
			pts.append(pts[0])
			var col := Color.from_string(str(a.get("color", "#6fb3e0")), Color("#6fb3e0"))
			var strong: bool = str(a.get("id")) == ctx.active_area or str(a.get("id")) in ph_areas
			ci.draw_polyline(pts, Color(col.r, col.g, col.b, 1.0 if strong else 0.85), 2.0 if strong else 1.2, true)
	if view_rect.size != Vector2.ZERO:
		# Unclipped: the view clips it, so edges beyond the overview simply aren't drawn.
		var a := world_to_map(view_rect.position)
		var b := world_to_map(view_rect.end)
		var vr := Rect2(a, b - a)
		ci.draw_rect(vr.grow(1.0), Color(0, 0, 0, 0.5), false, 1.0)
		ci.draw_rect(vr, C_VIEW, false, 1.5)


var _dragging := false


func _map_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var b := e as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_LEFT:
			_dragging = b.pressed
			if b.pressed:
				navigate.emit(map_to_world(b.position))
			_view.accept_event()
		elif b.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_view.accept_event()
	elif e is InputEventMouseMotion and _dragging and ((e as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		navigate.emit(map_to_world((e as InputEventMouseMotion).position))
		_view.accept_event()
