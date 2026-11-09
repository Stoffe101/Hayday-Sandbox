class_name GridOverlay
extends Node2D
## Tile grid over land, plus optional occupancy overlay (which tiles are
## physically taken, coloured by category). Opacity follows camera zoom.

var map: FarmMap
var layout: FarmLayout
var db: ItemDatabase
var show_grid := true:
	set(v):
		show_grid = v
		queue_redraw()
var show_occupancy := false:
	set(v):
		show_occupancy = v
		queue_redraw()
var grid_alpha := 0.16


func setup(m: FarmMap, l: FarmLayout, item_db: ItemDatabase) -> void:
	if layout and layout.objects_added.is_connected(_dirty):
		layout.objects_added.disconnect(_dirty)
		layout.objects_removed.disconnect(_dirty)
		layout.objects_changed.disconnect(_dirty)
	map = m
	layout = l
	db = item_db
	layout.objects_added.connect(_dirty)
	layout.objects_removed.connect(_dirty)
	layout.objects_changed.connect(_dirty)
	queue_redraw()


func _dirty(_u: Array = []) -> void:
	if show_occupancy:
		queue_redraw()


func set_zoom(z: float) -> void:
	var a := clampf((z - 0.18) / 0.5, 0.0, 1.0)
	modulate.a = a


func _draw() -> void:
	if map == null:
		return
	if show_grid:
		var segs := PackedVector2Array()
		for y in range(map.size.y + 1):
			var x := 0
			while x < map.size.x:
				if _land(x, y) or _land(x, y - 1):
					var s := x
					while x < map.size.x and (_land(x, y) or _land(x, y - 1)):
						x += 1
					segs.append(Iso.grid_to_world(Vector2(s, y)))
					segs.append(Iso.grid_to_world(Vector2(x, y)))
				else:
					x += 1
		for x in range(map.size.x + 1):
			var y := 0
			while y < map.size.y:
				if _land(x, y) or _land(x - 1, y):
					var s := y
					while y < map.size.y and (_land(x, y) or _land(x - 1, y)):
						y += 1
					segs.append(Iso.grid_to_world(Vector2(x, s)))
					segs.append(Iso.grid_to_world(Vector2(x, y)))
				else:
					y += 1
		if not segs.is_empty():
			draw_multiline(segs, Color(0.1, 0.18, 0.08, grid_alpha), 1.0)
	if show_occupancy and layout:
		for o: PlacedObject in layout.objects.values():
			var it := db.get_item(o.item_id)
			var c: Color = db.category(it.category)["color"] if it else Color(0.5, 0.5, 0.5)
			c.a = 0.42
			draw_colored_polygon(Iso.footprint_polygon(o.origin, o.size), c)
			var poly := Iso.footprint_polygon(o.origin, o.size)
			poly.append(poly[0])
			draw_polyline(poly, Color(c.r, c.g, c.b, 0.9).darkened(0.3), 1.5)
		for t in layout.occupancy.stacked_tiles():
			draw_colored_polygon(Iso.footprint_polygon(t, Vector2i.ONE), Color(0.9, 0.1, 0.1, 0.6))


func _land(x: int, y: int) -> bool:
	var k := map.kind_at(Vector2i(x, y))
	return k == FarmMap.Kind.BUILDABLE or k == FarmMap.Kind.PLOT
