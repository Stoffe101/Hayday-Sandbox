class_name EditorOverlay
extends Node2D
## Interactive feedback drawn above the farm: hover, selection, placement
## ghosts with per-tile validity, marquee, annotations, issue markers, labels,
## layout-comparison highlights. Purely presentational; state is pushed in by
## the editor controller.

const C_OK := Color(0.30, 0.85, 0.45, 0.42)
const C_BAD := Color(0.95, 0.25, 0.22, 0.50)
const C_LOCKED := Color(0.98, 0.65, 0.15, 0.50)
const C_OUT := Color(0.4, 0.4, 0.4, 0.45)

var layout: FarmLayout
var db: ItemDatabase
var assets: AssetLibrary
var renderer: ObjectRenderer
var accent := Color("#3fae6a")

var hover_uid := 0
var hover_tile := Vector2i(-99999, -99999)
var show_hover_tile := false
var selection: Array = []
## Ghosts: Array of {item: ItemDef, origin: Vector2i, flipped: bool, variant: String}
var ghosts: Array = []
var ghost_result: PlacementRules.Result
var ghost_alpha := 0.78
var marquee := Rect2()
var line_tiles: Array = []      ## brush preview tiles
var issues: Dictionary = {}     ## uid -> severity (1 warn, 2 blocking)
var show_labels := false
var show_annotations := true
var diff: Dictionary = {}       ## {added: [rects], removed: [rects], moved: [[from,to]]}
var calibration_points: Array = []  ## world points for screenshot calibration
var zoom := 1.0
var visible_rect := Rect2()
var cursor_text := ""
var cursor_world := Vector2.ZERO
var font: Font


func _ready() -> void:
	font = ThemeDB.fallback_font


func refresh() -> void:
	queue_redraw()


func _outline(poly: PackedVector2Array, col: Color, w: float) -> void:
	var p := poly.duplicate()
	p.append(poly[0])
	draw_polyline(p, col, w / maxf(zoom, 0.05), true)


func _draw() -> void:
	if layout == null:
		return
	var lw := 1.0
	if show_annotations:
		_draw_annotations()
	_draw_diff()
	# Issue markers
	for u in issues:
		var o := layout.get_obj(u)
		if o == null:
			continue
		var poly := Iso.footprint_polygon(o.origin, o.size)
		if issues[u] >= 2:
			var c := Color(0.95, 0.3, 0.2, 0.9)
			draw_colored_polygon(poly, Color(c.r, c.g, c.b, 0.16))
			_outline(poly, c, 2.0)
		else:
			# Warnings (e.g. unverified footprint) stay subtle.
			_dashed(poly, Color(0.98, 0.72, 0.2, 0.55))
	# Selection
	var sel_fill := accent
	sel_fill.a = 0.20
	for u in selection:
		var o := layout.get_obj(u)
		if o == null:
			continue
		var poly := Iso.footprint_polygon(o.origin, o.size)
		draw_colored_polygon(poly, sel_fill)
		_outline(poly, accent.lightened(0.2), 2.5)
	if selection.size() > 1:
		var r := layout.bounds_of(selection)
		_dashed(Iso.grid_rect_polygon(r.grow(0)), Color(1, 1, 1, 0.85))
	# Hover
	if hover_uid != 0 and not hover_uid in selection:
		var o := layout.get_obj(hover_uid)
		if o:
			_outline(Iso.footprint_polygon(o.origin, o.size), Color(1, 1, 1, 0.85), 2.0)
	elif show_hover_tile and ghosts.is_empty():
		_outline(Iso.footprint_polygon(hover_tile, Vector2i.ONE), Color(1, 1, 1, 0.6), 1.5)
	# Brush preview tiles (line / rect fill outline)
	for t in line_tiles:
		_outline(Iso.footprint_polygon(t, Vector2i.ONE), Color(1, 1, 1, 0.35), 1.0)
	# Ghost tiles + sprites
	if ghost_result:
		for i in ghost_result.tiles.size():
			var code := ghost_result.codes[i]
			var c := C_OK
			match code:
				PlacementRules.OK_TILE: c = C_OK
				PlacementRules.LOCKED_LAND: c = C_LOCKED
				PlacementRules.OUT_OF_BOUNDS: c = C_OUT
				_: c = C_BAD
			draw_colored_polygon(Iso.footprint_polygon(ghost_result.tiles[i], Vector2i.ONE), c)
	for g in ghosts:
		_draw_ghost(g)
	if ghost_result:
		for g in ghosts:
			var it: ItemDef = g["item"]
			var sz := it.size_for(g["flipped"]) if it else Vector2i.ONE
			var col := Color(0.4, 1.0, 0.55, 0.95) if ghost_result.ok else Color(1.0, 0.35, 0.3, 0.95)
			_outline(Iso.footprint_polygon(g["origin"], sz), col, 2.0)
	# Marquee
	if marquee.size != Vector2.ZERO:
		var mf := accent
		mf.a = 0.12
		draw_rect(marquee.abs(), mf, true)
		draw_rect(marquee.abs(), accent.lightened(0.3), false, 1.5 / maxf(zoom, 0.05))
	# Calibration points
	for i in calibration_points.size():
		var p: Vector2 = calibration_points[i]
		var r := 7.0 / maxf(zoom, 0.05)
		draw_circle(p, r, Color(1, 0.3, 0.6, 0.9))
		draw_arc(p, r * 1.6, 0, TAU, 24, Color(1, 1, 1, 0.9), 1.5 / maxf(zoom, 0.05))
	if show_labels and zoom > 0.45:
		_draw_labels()
	if not cursor_text.is_empty():
		_draw_tag(cursor_world + Vector2(18, 22) / maxf(zoom, 0.05), cursor_text)


func _draw_ghost(g: Dictionary) -> void:
	var it: ItemDef = g["item"]
	if it == null:
		return
	var flipped: bool = g["flipped"]
	var sz := it.size_for(flipped)
	var center := Iso.footprint_center(g["origin"], sz)
	var mask := -1
	if not it.connect_group.is_empty() and g.has("mask"):
		mask = g["mask"]
	var spr := assets.get_sprite(it.art_key, str(g.get("variant", "")), mask)
	var tint := Color(1, 1, 1, ghost_alpha)
	if ghost_result and not ghost_result.ok:
		tint = Color(1.0, 0.75, 0.72, ghost_alpha * 0.85)
	if spr:
		draw_set_transform(center, 0.0, Vector2(-1.0 if flipped else 1.0, 1.0))
		draw_texture_rect(spr.texture, Rect2(-spr.anchor * spr.scale, spr.texture.get_size() * spr.scale), false, tint)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		var h := (0.4 + 0.25 * mini(sz.x, sz.y)) * Iso.Z_UNIT
		var poly := Iso.footprint_polygon(g["origin"], sz)
		var top := PackedVector2Array()
		for p in poly:
			top.append(p - Vector2(0, h))
		var c: Color = db.category(it.category)["color"]
		c.a = ghost_alpha
		draw_colored_polygon(top, c)


func _dashed(poly: PackedVector2Array, col: Color) -> void:
	var w := 1.5 / maxf(zoom, 0.05)
	var dash := 8.0 / maxf(zoom, 0.05)
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var d := a.distance_to(b)
		var n := maxi(1, int(d / dash))
		for k in range(0, n, 2):
			draw_line(a.lerp(b, float(k) / n), a.lerp(b, minf(1.0, float(k + 1) / n)), col, w)


func _draw_annotations() -> void:
	for a in layout.annotations:
		var r: Array = a.get("rect", [0, 0, 1, 1])
		var rect := Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3]))
		var col := Color(str(a.get("color", "#4b7fc4")))
		var poly := Iso.grid_rect_polygon(rect)
		if str(a.get("kind", "zone")) == "zone":
			var f := col
			f.a = 0.14
			draw_colored_polygon(poly, f)
			_dashed(poly, Color(col.r, col.g, col.b, 0.9))
		var txt := str(a.get("text", ""))
		if not txt.is_empty():
			var c := Iso.grid_to_world(Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * 0.5))
			_draw_tag(c, txt, col, true)


func _draw_tag(at: Vector2, text: String, col: Color = Color(0.12, 0.14, 0.13, 0.88), centered: bool = false) -> void:
	var inv := 1.0 / maxf(zoom, 0.05)
	var fs := 15
	var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_set_transform(at, 0.0, Vector2(inv, inv))
	var pos := Vector2(-size.x * 0.5 - 8, -size.y * 0.5 - 4) if centered else Vector2.ZERO
	var box := Rect2(pos, size + Vector2(16, 8))
	var bg := col
	if centered:
		bg = Color(col.r * 0.55, col.g * 0.55, col.b * 0.55, 0.9)
	draw_rect(box, bg, true)
	draw_string(font, pos + Vector2(8, 4 + size.y * 0.78), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.97))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_labels() -> void:
	var inv := 1.0 / maxf(zoom, 0.05)
	var n := 0
	for o: PlacedObject in layout.objects.values():
		var c := Iso.footprint_center(o.origin, o.size)
		if visible_rect.size != Vector2.ZERO and not visible_rect.has_point(c):
			continue
		var it := db.get_item(o.item_id)
		var name := it.name if it else o.item_id
		var fs := 12
		var s := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_set_transform(c, 0.0, Vector2(inv, inv))
		draw_rect(Rect2(Vector2(-s.x * 0.5 - 4, 2), s + Vector2(8, 4)), Color(0, 0, 0, 0.5), true)
		draw_string(font, Vector2(-s.x * 0.5, 2 + s.y * 0.8), name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		n += 1
		if n > 600:
			break


func _draw_diff() -> void:
	if diff.is_empty():
		return
	for r: Rect2i in diff.get("removed", []):
		var poly := Iso.grid_rect_polygon(r)
		draw_colored_polygon(poly, Color(0.95, 0.25, 0.2, 0.25))
		_dashed(poly, Color(0.95, 0.3, 0.25, 0.95))
	for r: Rect2i in diff.get("added", []):
		var poly := Iso.grid_rect_polygon(r)
		draw_colored_polygon(poly, Color(0.3, 0.9, 0.4, 0.22))
		_outline(poly, Color(0.3, 0.9, 0.4, 0.95), 2.0)
	for pair in diff.get("moved", []):
		var a: Rect2i = pair[0]
		var b: Rect2i = pair[1]
		var ca := Iso.footprint_center(a.position, a.size)
		var cb := Iso.footprint_center(b.position, b.size)
		_dashed(Iso.grid_rect_polygon(a), Color(0.4, 0.6, 1.0, 0.8))
		_outline(Iso.grid_rect_polygon(b), Color(0.4, 0.6, 1.0, 0.95), 2.0)
		draw_line(ca, cb, Color(0.4, 0.6, 1.0, 0.9), 2.0 / maxf(zoom, 0.05))
		var dir := (cb - ca).normalized()
		var side := Vector2(-dir.y, dir.x)
		var s := 10.0 / maxf(zoom, 0.05)
		draw_colored_polygon(PackedVector2Array([cb, cb - dir * s + side * s * 0.5, cb - dir * s - side * s * 0.5]), Color(0.4, 0.6, 1.0, 0.95))
