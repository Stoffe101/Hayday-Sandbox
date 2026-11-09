class_name GroundLayer
extends Node2D
## Terrain: backdrop, land tiles by kind, raised land edge, locked-plot
## shading, plot borders and labels. Drawn once into cached canvas commands
## and redrawn only when land/unlock state changes.

var map: FarmMap
var unlocked: Dictionary = {}
var highlight_plot: String = ""
var show_plot_labels := true
var hide_locked := false
var dim_for_land_mode := false


func _ready() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


func setup(m: FarmMap, unlocked_plots: Dictionary) -> void:
	map = m
	unlocked = unlocked_plots
	queue_redraw()


func _uv(points: PackedVector2Array, scale: float = 256.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(p / scale)
	return out


func _poly(pts: PackedVector2Array, tex: Texture2D, mod: Color) -> void:
	var cols := PackedColorArray()
	for i in pts.size():
		cols.append(mod)
	draw_polygon(pts, cols, _uv(pts), tex)


func _draw() -> void:
	if map == null:
		return
	var bounds := Rect2i(Vector2i.ZERO, map.size)
	var grow := 40
	var back := Iso.grid_rect_polygon(bounds.grow(grow))
	_poly(back, TerrainTextures.get_tex("meadow"), Color(0.88, 0.92, 0.86))
	var grass := TerrainTextures.get_tex("grass")
	# Row runs of equal kind/plot become single parallelograms.
	for y in map.size.y:
		var x := 0
		while x < map.size.x:
			var k := map.kind_at(Vector2i(x, y))
			var p := map.plot_id_at(Vector2i(x, y))
			var x1 := x + 1
			while x1 < map.size.x and map.kind_at(Vector2i(x1, y)) == k and map.plot_id_at(Vector2i(x1, y)) == p:
				x1 += 1
			_draw_run(Rect2i(x, y, x1 - x, 1), k, p, grass)
			x = x1
	_draw_land_edge()
	_draw_plot_borders()
	if show_plot_labels:
		_draw_labels()


func _draw_run(r: Rect2i, kind: int, plot_id: String, grass: Texture2D) -> void:
	var pts := Iso.grid_rect_polygon(r)
	match kind:
		FarmMap.Kind.BUILDABLE:
			_poly(pts, grass, Color.WHITE)
		FarmMap.Kind.PLOT:
			if unlocked.has(plot_id):
				_poly(pts, grass, Color.WHITE)
			elif hide_locked:
				_poly(pts, TerrainTextures.get_tex("meadow"), Color(0.8, 0.85, 0.8))
			else:
				var c := Color(0.74, 0.8, 0.7) if plot_id != highlight_plot else Color(0.95, 1.0, 0.85)
				_poly(pts, grass, c)
				_poly(pts, TerrainTextures.get_tex("hatch"), Color(1, 1, 1, 1))
		FarmMap.Kind.ROAD:
			_poly(pts, TerrainTextures.get_tex("road"), Color.WHITE)
		FarmMap.Kind.WATER:
			_poly(pts, TerrainTextures.get_tex("water"), Color.WHITE)
		FarmMap.Kind.SCENERY:
			_poly(pts, TerrainTextures.get_tex("forest"), Color.WHITE)
		FarmMap.Kind.BLOCKED:
			_poly(pts, TerrainTextures.get_tex("meadow"), Color(0.8, 0.84, 0.78))
			_poly(pts, TerrainTextures.get_tex("hatch"), Color(1, 1, 1, 0.6))


func _is_land(t: Vector2i) -> bool:
	var k := map.kind_at(t)
	return k == FarmMap.Kind.BUILDABLE or k == FarmMap.Kind.PLOT


func _draw_land_edge() -> void:
	## A soil "slab" along the front edges of land that borders non-land,
	## so the farm reads as a raised plateau.
	var depth := 7.0
	var soil := Color("#8a6040")
	var soil_dark := Color("#6d4a30")
	for y in map.size.y:
		for x in map.size.x:
			var t := Vector2i(x, y)
			if not _is_land(t):
				continue
			if not _is_land(t + Vector2i(0, 1)) and map.kind_at(t + Vector2i(0, 1)) != FarmMap.Kind.ROAD:
				var a := Iso.grid_to_world(Vector2(x, y + 1))
				var b := Iso.grid_to_world(Vector2(x + 1, y + 1))
				draw_colored_polygon(PackedVector2Array([a, b, b + Vector2(0, depth), a + Vector2(0, depth)]), soil)
			if not _is_land(t + Vector2i(1, 0)) and map.kind_at(t + Vector2i(1, 0)) != FarmMap.Kind.ROAD:
				var a := Iso.grid_to_world(Vector2(x + 1, y))
				var b := Iso.grid_to_world(Vector2(x + 1, y + 1))
				draw_colored_polygon(PackedVector2Array([a, b, b + Vector2(0, depth), a + Vector2(0, depth)]), soil_dark)


func _draw_plot_borders() -> void:
	var segs := PackedVector2Array()
	var locked_segs := PackedVector2Array()
	for y in map.size.y:
		for x in map.size.x:
			var t := Vector2i(x, y)
			var p := map.plot_id_at(t)
			if p.is_empty():
				continue
			for d in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
				var n: Vector2i = t + d
				if map.plot_id_at(n) == p:
					continue
				var a: Vector2
				var b: Vector2
				if d == Vector2i(1, 0):
					a = Iso.grid_to_world(Vector2(x + 1, y)); b = Iso.grid_to_world(Vector2(x + 1, y + 1))
				elif d == Vector2i(0, 1):
					a = Iso.grid_to_world(Vector2(x, y + 1)); b = Iso.grid_to_world(Vector2(x + 1, y + 1))
				elif d == Vector2i(-1, 0):
					a = Iso.grid_to_world(Vector2(x, y)); b = Iso.grid_to_world(Vector2(x, y + 1))
				else:
					a = Iso.grid_to_world(Vector2(x, y)); b = Iso.grid_to_world(Vector2(x + 1, y))
				if unlocked.has(p) and (map.plot_id_at(n).is_empty() or unlocked.has(map.plot_id_at(n))):
					segs.append(a); segs.append(b)
				else:
					locked_segs.append(a); locked_segs.append(b)
	if not segs.is_empty():
		draw_multiline(segs, Color(1, 1, 1, 0.12), 1.0)
	if not locked_segs.is_empty() and not hide_locked:
		draw_multiline(locked_segs, Color(1, 1, 1, 0.55), 2.0)


func _draw_labels() -> void:
	var font := ThemeDB.fallback_font
	for p in map.plots:
		var pid := str(p["id"])
		if unlocked.has(pid) or hide_locked:
			continue
		var c: Vector2 = Iso.grid_to_world(p["center"])
		var txt := str(p["number"])
		var fs := 22
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
		draw_circle(c, 18, Color(0.15, 0.2, 0.15, 0.55))
		draw_string(font, c + Vector2(-w * 0.5, fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))
	for l in map.labels:
		var c2 := Iso.grid_to_world(l["at"])
		var t2: String = l["text"]
		var w2 := font.get_string_size(t2, HORIZONTAL_ALIGNMENT_CENTER, -1, 26).x
		draw_string(font, c2 + Vector2(-w2 * 0.5, 0), t2, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(1, 1, 1, 0.55))
	for r in map.regions:
		if r["kind"] == FarmMap.Kind.BLOCKED and not str(r["name"]).is_empty():
			var rect: Rect2i = r["rects"][0]
			var c3 := Iso.grid_to_world(Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * 0.5))
			var t3: String = r["name"]
			var w3 := font.get_string_size(t3, HORIZONTAL_ALIGNMENT_CENTER, -1, 30).x
			draw_string(font, c3 + Vector2(-w3 * 0.5, 0), t3, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(1, 1, 1, 0.6))
