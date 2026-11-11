class_name SelectionUnderlay
extends Node2D
## Flat feedback drawn on the ground, UNDER the objects (world order: grid,
## this, renderer, EditorOverlay): the selection, a tile-selection drag and the
## validity tiles of a live drag. Objects standing in front cover it, as they
## would cover the ground. All state lives in EditorOverlay.
##
## Selection look: the selected ground (TileRegion) gets a soft sky fill and
## faint tile lines; every selected object's footprint a stronger fill; one
## outline follows the outside tile edges of everything selected (white with a
## dark under-stroke, so it reads on grass, paths and water alike).

var overlay: EditorOverlay
var _sig := 0
## Combined area of the selection (selected ground + selected footprints), rebuilt when the signature changes.
var _area: TileRegion
const AREA_MAX_OBJECTS := 4000   ## above this the combined outline is skipped (fills only)
const GRID_MAX_TILES := 3000     ## tile lines inside the selected ground up to this size
const GRID_MIN_ZOOM := 0.3


func request_redraw() -> void:
	## Redraws only when what it would draw changed (mouse moves call this).
	var s := _signature()
	if s != _sig:
		_sig = s
		_area = null
		queue_redraw()


func _region() -> TileRegion:
	return overlay.session.selection_region if overlay.session != null else null


func _signature() -> int:
	if overlay == null or overlay.layout == null:
		return 0
	var reg := _region()
	var h := hash([overlay.selection.size(), overlay.drag_uids.is_empty(), overlay.landmark_selected, overlay.accent,
		overlay.tile_drag, overlay.tile_drag_op, overlay.tile_drag_uids.size(), reg.get_instance_id() if reg else 0,
		reg.bounds() if reg else Rect2i(), reg.size() if reg else 0, snappedf(overlay.zoom, 0.05)])
	for u in overlay.selection:
		var o := overlay.layout.get_obj(u)
		if o:
			h = (h * 31 + o.origin.x * 73856093 + o.origin.y * 19349663 + o.size.x * 83492791 + o.size.y * 2654435) & 0x7fffffffffff
	if overlay.drag_result != null:
		h = (h * 31 + hash(overlay.drag_result.tiles) + hash(overlay.drag_result.codes)) & 0x7fffffffffff
	return h


func _w(px: float) -> float:
	return px / maxf(overlay.zoom, 0.05)


func _draw() -> void:
	if overlay == null or overlay.layout == null:
		return
	var sel_col := EditorOverlay.C_SELECT
	var reg := _region()
	if overlay.drag_uids.is_empty():
		# Selected ground: soft fill + faint tile lines.
		if reg != null and not reg.is_empty():
			var f := sel_col
			f.a = 0.26
			var grid := overlay.zoom >= GRID_MIN_ZOOM and reg.size() <= GRID_MAX_TILES
			var line := sel_col
			line.a = 0.32
			for t: Vector2i in reg.tiles():
				var poly := Iso.footprint_polygon(t, Vector2i.ONE)
				draw_colored_polygon(poly, f)
				if grid:
					var p := poly.duplicate()
					p.append(poly[0])
					draw_polyline(p, line, _w(1.0), true)
		# Selected objects' footprints: stronger fill.
		var fill := sel_col
		fill.a = 0.4
		for u in overlay.selection:
			var o := overlay.layout.get_obj(u)
			if o:
				draw_colored_polygon(Iso.footprint_polygon(o.origin, o.size), fill)
		# One outline around everything selected.
		if not overlay.selection.is_empty() and overlay.selection.size() <= AREA_MAX_OBJECTS:
			if _area == null:
				_area = TileRegion.of_footprints(overlay.layout, overlay.selection)
				if reg != null:
					for t: Vector2i in reg.tiles():
						_area.add_rect(Rect2i(t, Vector2i.ONE))
			_edges(_area.boundary_edges(), Color(1, 1, 1, 0.95))
	if overlay.landmark_selected.size != Vector2i.ZERO:
		var lf := EditorOverlay.C_LANDMARK
		lf.a = 0.22
		draw_colored_polygon(Iso.footprint_polygon(overlay.landmark_selected.position, overlay.landmark_selected.size), lf)
	_draw_tile_drag()
	var r := overlay.drag_result
	if r:
		for i in r.tiles.size():
			draw_colored_polygon(Iso.footprint_polygon(r.tiles[i], Vector2i.ONE), EditorOverlay.tile_color(r.codes[i]))


func _edges(seg: PackedVector2Array, col: Color) -> void:
	## Outline segments with a dark under-stroke for contrast on light ground.
	if seg.is_empty():
		return
	draw_multiline(seg, Color(0.05, 0.12, 0.2, 0.45), _w(4.0), true)
	draw_multiline(seg, col, _w(2.0), true)


func _draw_tile_drag() -> void:
	## A tile-selection drag: the rectangle of whole tiles, its tile lines, the
	## objects it would take (footprint fill) and a clean outline.
	var t := overlay.tile_drag
	if t.size.x <= 0 or t.size.y <= 0:
		return
	var sub := overlay.tile_drag_op == "subtract"
	var col := EditorOverlay.C_REMOVE if sub else EditorOverlay.C_SELECT
	var f := col
	f.a = 0.28
	var poly := Iso.grid_rect_polygon(t)
	draw_colored_polygon(poly, f)
	var of := col
	of.a = 0.38
	for u in overlay.tile_drag_uids:
		var o := overlay.layout.get_obj(u)
		if o:
			draw_colored_polygon(Iso.footprint_polygon(o.origin, o.size), of)
	if overlay.zoom >= GRID_MIN_ZOOM and t.size.x * t.size.y <= 40000:
		var line := col
		line.a = 0.38
		var inner := TileRegion.rect_inner_lines(t)
		if not inner.is_empty():
			draw_multiline(inner, line, _w(1.0), true)
	var closed := poly.duplicate()
	closed.append(poly[0])
	draw_polyline(closed, Color(0.05, 0.12, 0.2, 0.45), _w(4.0), true)
	draw_polyline(closed, Color(1, 1, 1, 0.95) if not sub else col.lightened(0.3), _w(2.0), true)
