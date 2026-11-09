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
## Tiles of a fixed landmark: a neutral "this is part of the farm" colour,
## not the red of a real conflict.
const C_FIXED := Color(0.62, 0.66, 0.78, 0.5)
## Selected / hovered fixed landmark (distinct from the object-selection accent).
const C_LANDMARK := Color(1.0, 0.86, 0.52)

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
## Fixed landmarks: footprint of the hovered / selected one (size 0 = none),
## the selected one's name and sprite bounds (for its tag).
var landmark_hover := Rect2i()
var landmark_selected := Rect2i()
var landmark_name := ""
var landmark_bounds := Rect2()
## Under the objects: selection fill and live-drag validity tiles (reads these fields).
var underlay: SelectionUnderlay
## Reason chips listed under cursor_text (one line each).
var cursor_reasons: PackedStringArray = PackedStringArray()
## Live drag: objects drawn by the renderer at origin + drag_delta and lifted by drag_lift.
var drag_uids: Array = []
var drag_delta := Vector2i.ZERO
var drag_lift := 0.0
var drag_result: PlacementRules.Result
## What blocks the current drop / placement: outlined in red.
var blocker_uids: Array = []
var blocker_rects: Array = []
var _silhouettes: Dictionary = {}   ## texture instance id -> Array[PackedVector2Array]

## Above this many selected objects, footprints are outlined instead of silhouettes.
const SILHOUETTE_MAX := 150
const SILHOUETTE_CACHE := 400
const SILHOUETTE_TEX_MAX := 180     ## long side the mask is reduced to before tracing
const C_BLOCK := Color(1.0, 0.28, 0.24, 0.95)
const C_CHIP := Color(0.12, 0.14, 0.13, 0.9)
const C_CHIP_BAD := Color(0.55, 0.13, 0.11, 0.94)
const C_VALID := Color(0.4, 1.0, 0.55, 0.95)
const C_INVALID := Color(1.0, 0.35, 0.3, 0.95)


func _ready() -> void:
	font = ThemeDB.fallback_font


func refresh() -> void:
	queue_redraw()
	if underlay:
		underlay.request_redraw()


static func tile_color(code: int) -> Color:
	match code:
		PlacementRules.OK_TILE: return C_OK
		PlacementRules.LOCKED_LAND: return C_LOCKED
		PlacementRules.OUT_OF_BOUNDS: return C_OUT
		PlacementRules.LANDMARK: return C_FIXED
	return C_BAD


func begin_drag(uids: Array, lift: float) -> void:
	drag_uids = uids
	drag_lift = lift
	drag_delta = Vector2i.ZERO


func end_drag() -> void:
	drag_uids = []
	drag_delta = Vector2i.ZERO
	drag_result = null
	drag_lift = 0.0
	blocker_uids = []
	blocker_rects = []
	cursor_reasons = PackedStringArray()


func _silhouette_of(spr: AssetLibrary.SpriteInfo) -> Array:
	## Outline polygons of the sprite's opaque pixels, in texture pixels (cached).
	if spr == null or spr.texture == null:
		return []
	var key := spr.texture.get_instance_id()
	if _silhouettes.has(key):
		return _silhouettes[key]
	if _silhouettes.size() >= SILHOUETTE_CACHE:
		_silhouettes.clear()
	var out: Array = []
	var img := spr.texture.get_image()
	if img != null:
		if img.is_compressed():
			img.decompress()
		var full := Vector2(img.get_size())
		var s := minf(1.0, float(SILHOUETTE_TEX_MAX) / maxf(full.x, full.y))
		if s < 1.0:
			img = img.duplicate()
			img.resize(maxi(1, int(full.x * s)), maxi(1, int(full.y * s)), Image.INTERPOLATE_BILINEAR)
		var bm := BitMap.new()
		bm.create_from_image_alpha(img, 0.25)
		var back := full / Vector2(bm.get_size())
		for poly in bm.opaque_to_polygons(Rect2i(Vector2i.ZERO, bm.get_size()), 1.0):
			var p := PackedVector2Array()
			for v in poly:
				p.append(v * back)
			if p.size() >= 3:
				p.append(p[0])
				out.append(p)
	_silhouettes[key] = out
	return out


func _outline_object(o: PlacedObject, col: Color, w: float, use_silhouette: bool, world_offset: Vector2 = Vector2.ZERO) -> void:
	var drawn := false
	if use_silhouette and renderer != null:
		var spr := renderer.sprite_of(o.uid)
		var polys := _silhouette_of(spr)
		if not polys.is_empty():
			drawn = true
			var c := Iso.footprint_center(o.origin, o.size) + world_offset
			draw_set_transform(c - Vector2(spr.anchor.x * (-1.0 if o.flipped else 1.0), spr.anchor.y) * spr.scale, 0.0, Vector2(-1.0 if o.flipped else 1.0, 1.0) * spr.scale)
			var lw := w / maxf(zoom, 0.05) / spr.scale
			for p: PackedVector2Array in polys:
				draw_polyline(p, col, lw, true)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if not drawn:
		var poly := Iso.footprint_polygon(o.origin, o.size)
		if world_offset != Vector2.ZERO:
			for i in poly.size():
				poly[i] += world_offset
		_outline(poly, col, w)


func _draw_blockers() -> void:
	for u in blocker_uids:
		var o := layout.get_obj(u)
		if o:
			_outline_object(o, C_BLOCK, 2.5, true)
	for r: Rect2i in blocker_rects:
		_outline(Iso.footprint_polygon(r.position, r.size), C_BLOCK, 2.5)


func _draw_drag() -> void:
	## Where the dragged objects came from (dashed) and their outline at the drop.
	var col := C_VALID if drag_result == null or drag_result.ok else C_INVALID
	var off := Iso.grid_to_world(Vector2(drag_delta)) - Vector2(0.0, drag_lift)
	var sil := drag_uids.size() <= SILHOUETTE_MAX
	for u in drag_uids:
		var o := layout.get_obj(u)
		if o == null:
			continue
		if drag_delta != Vector2i.ZERO:
			_dashed(Iso.footprint_polygon(o.origin, o.size), Color(1, 1, 1, 0.55))
		_outline(Iso.footprint_polygon(o.origin + drag_delta, o.size), col, 2.0)
		_outline_object(o, col, 2.0, sil, off)


func _draw_cursor_chips() -> void:
	## cursor_text, then one red chip per reason, kept inside the visible area.
	var inv := 1.0 / maxf(zoom, 0.05)
	var rows: Array = []
	if not cursor_text.is_empty():
		for ln in cursor_text.split("\n"):
			rows.append([ln, C_CHIP])
	for r in cursor_reasons:
		rows.append([r, C_CHIP_BAD])
	if rows.is_empty():
		return
	var fs := 15
	var lh := font.get_height(fs)
	var row_h := lh + 8.0
	var gap := 3.0
	var width := 0.0
	for row: Array in rows:
		width = maxf(width, font.get_string_size(row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 16.0)
	var total := Vector2(width, row_h * rows.size() + gap * (rows.size() - 1)) * inv
	var at := cursor_world + Vector2(18, 22) * inv
	if visible_rect.size != Vector2.ZERO:
		at.x = minf(at.x, maxf(visible_rect.position.x, visible_rect.end.x - total.x - 10.0 * inv))
		at.y = minf(at.y, maxf(visible_rect.position.y, visible_rect.end.y - total.y - 110.0 * inv))
	draw_set_transform(at, 0.0, Vector2(inv, inv))
	var y := 0.0
	for row: Array in rows:
		var w := font.get_string_size(row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 16.0
		draw_rect(Rect2(0.0, y, w, row_h), row[1], true)
		draw_string(font, Vector2(8.0, y + 4.0 + font.get_ascent(fs)), row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.97))
		y += row_h + gap
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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
	# Selection: the fill is under the objects (SelectionUnderlay); here only outlines.
	if drag_uids.is_empty():
		var sil := selection.size() <= SILHOUETTE_MAX
		for u in selection:
			var o := layout.get_obj(u)
			if o:
				_outline_object(o, accent.lightened(0.2), 2.5, sil)
		if selection.size() > 1:
			var r := layout.bounds_of(selection)
			_dashed(Iso.grid_rect_polygon(r.grow(0)), Color(1, 1, 1, 0.85))
	_draw_landmark_marks()
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
			draw_colored_polygon(Iso.footprint_polygon(ghost_result.tiles[i], Vector2i.ONE), tile_color(ghost_result.codes[i]))
	if not drag_uids.is_empty():
		_draw_drag()
	for g in ghosts:
		_draw_ghost(g)
	if ghost_result:
		for g in ghosts:
			var it: ItemDef = g["item"]
			var sz := it.size_for(g["flipped"]) if it else Vector2i.ONE
			var col := C_VALID if ghost_result.ok else C_INVALID
			_outline(Iso.footprint_polygon(g["origin"], sz), col, 2.0)
	_draw_blockers()
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
	_draw_cursor_chips()


func _draw_landmark_marks() -> void:
	if landmark_selected.size != Vector2i.ZERO:
		var poly := Iso.footprint_polygon(landmark_selected.position, landmark_selected.size)
		_outline(poly, C_LANDMARK, 2.5)
		if not landmark_name.is_empty():
			var top := landmark_bounds.position + Vector2(landmark_bounds.size.x * 0.5, 0.0) if landmark_bounds.size != Vector2.ZERO \
				else Iso.footprint_center(landmark_selected.position, landmark_selected.size)
			_draw_tag(top - Vector2(0, 14.0 / maxf(zoom, 0.05)), landmark_name + " · fixed", Color(0.45, 0.36, 0.16, 0.95), true)
	if landmark_hover.size != Vector2i.ZERO and landmark_hover != landmark_selected:
		_outline(Iso.footprint_polygon(landmark_hover.position, landmark_hover.size), Color(1, 1, 1, 0.8), 2.0)


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
	## A small label box in screen-size pixels at a world point; "\n" starts a new line.
	var inv := 1.0 / maxf(zoom, 0.05)
	var fs := 15
	var lines := text.split("\n")
	var lh := font.get_height(fs)
	var size := Vector2.ZERO
	for ln in lines:
		size.x = maxf(size.x, font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	size.y = lh * lines.size()
	draw_set_transform(at, 0.0, Vector2(inv, inv))
	var pos := Vector2(-size.x * 0.5 - 8, -size.y * 0.5 - 4) if centered else Vector2.ZERO
	var box := Rect2(pos, size + Vector2(16, 8))
	var bg := col
	if centered:
		bg = Color(col.r * 0.55, col.g * 0.55, col.b * 0.55, 0.9)
	draw_rect(box, bg, true)
	for i in lines.size():
		draw_string(font, pos + Vector2(8, 4 + lh * i + font.get_ascent(fs)), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.97))
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
