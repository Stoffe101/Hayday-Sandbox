class_name SelectionUnderlay
extends Node2D
## Flat feedback drawn on the ground, UNDER the objects (world order: grid,
## this, renderer, EditorOverlay): the selection fill and the validity tiles of
## a live drag. Objects standing in front cover it, as they would cover the
## ground. All state lives in EditorOverlay.

var overlay: EditorOverlay
var _sig := 0


func request_redraw() -> void:
	## Redraws only when what it would draw changed (mouse moves call this).
	var s := _signature()
	if s != _sig:
		_sig = s
		queue_redraw()


func _signature() -> int:
	if overlay == null or overlay.layout == null:
		return 0
	var h := hash([overlay.selection.size(), overlay.drag_uids.is_empty(), overlay.landmark_selected, overlay.accent])
	for u in overlay.selection:
		var o := overlay.layout.get_obj(u)
		if o:
			h = (h * 31 + o.origin.x * 73856093 + o.origin.y * 19349663 + o.size.x * 83492791 + o.size.y * 2654435) & 0x7fffffffffff
	if overlay.drag_result != null:
		h = (h * 31 + hash(overlay.drag_result.tiles) + hash(overlay.drag_result.codes)) & 0x7fffffffffff
	return h


func _draw() -> void:
	if overlay == null or overlay.layout == null:
		return
	var fill := overlay.accent
	fill.a = 0.28
	if overlay.drag_uids.is_empty():
		for u in overlay.selection:
			var o := overlay.layout.get_obj(u)
			if o:
				draw_colored_polygon(Iso.footprint_polygon(o.origin, o.size), fill)
	if overlay.landmark_selected.size != Vector2i.ZERO:
		var f := EditorOverlay.C_LANDMARK
		f.a = 0.22
		draw_colored_polygon(Iso.footprint_polygon(overlay.landmark_selected.position, overlay.landmark_selected.size), f)
	var r := overlay.drag_result
	if r:
		for i in r.tiles.size():
			draw_colored_polygon(Iso.footprint_polygon(r.tiles[i], Vector2i.ONE), EditorOverlay.tile_color(r.codes[i]))
