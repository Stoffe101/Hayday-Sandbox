class_name GroundLayer
extends Node2D
## Terrain of the farm world (map schema v2, game tile frame): backdrop over
## the whole world (FarmMap.world_bounds), land tiles by kind (starting land,
## expansion plots — unlocked vs locked —, the 5-row main road, water, blocked
## or unmapped areas), road / driveway tiles from the optional per-tile ground
## layer (private world data; also off the placement grid), the raised land
## edge, plot borders and labels. Tiles outside the placement grid are never
## drawn as land. Drawn once into cached canvas commands and redrawn only when
## land / unlock / level state changes.
##
## Worlds without game terrain get their ground from a TerrainLayer child drawn
## behind this node; here they only add what depends on the layout: the
## locked-plot tint and hatching, blocked areas, the land edge, borders, labels.

var map: FarmMap
## Unlocked plots, canonical ids (aliases resolved in setup()).
var unlocked: Dictionary = {}
var highlight_plot: String = ""
## The highlighted plot can't be unlocked (Realistic: farm level too low).
var highlight_blocked := false
var show_plot_labels := true
var hide_locked := false
var dim_for_land_mode := false
## Realistic mode: locked plots whose known min_level is above the farm level
## (plot id -> min level). Drawn darker with a "Lv N" tag.
var level_blocked: Dictionary = {}
var last_draw_usec := 0   ## script time of the last redraw (ownership changes end here)
var _terrain: TerrainLayer
var _procedural := false  ## the TerrainLayer draws the base ground of this map

const ROAD_GROUND_KINDS := ["road", "road_blocked"]
const BACKDROP_MARGIN := 24


func _init() -> void:
	_terrain = TerrainLayer.new()
	_terrain.name = "Terrain"
	_terrain.show_behind_parent = true
	add_child(_terrain)


func _ready() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


func set_theme(theme_id: String) -> void:
	_terrain.set_theme(theme_id)


func setup(m: FarmMap, unlocked_plots: Dictionary) -> void:
	_terrain.setup(m)
	_procedural = TerrainLayer.applies_to(m)
	if m != map:
		map = m
		_build_static()
	unlocked = m.canonical_unlocked(unlocked_plots) if m else {}
	queue_redraw()


func set_level_blocked(blocked: Dictionary) -> void:
	if blocked == level_blocked:
		return
	level_blocked = blocked.duplicate()
	queue_redraw()


func is_unlocked(plot_id: String) -> bool:
	return unlocked.has(plot_id) or (map != null and map.is_plot_unlocked(plot_id, unlocked))


## Per grid tile, computed once per map: visual class (kind, or PLOT_BASE +
## plot index; ground-layer road tiles off the land count as ROAD) and a road
## flag (map road or ground-layer road/driveway).
const PLOT_BASE := 1000
var _cls_grid := PackedInt32Array()
var _road_grid := PackedByteArray()


func _build_static() -> void:
	_cls_grid = PackedInt32Array()
	_road_grid = PackedByteArray()
	if map == null:
		return
	var w := map.size.x
	var n := w * map.size.y
	_cls_grid.resize(n)
	_road_grid.resize(n)
	var has_ground := map.has_ground()
	for y in map.size.y:
		for x in w:
			var i := y * w + x
			var k := int(map.kinds[i])
			var road := k == FarmMap.Kind.ROAD
			if has_ground and not road and _ground_is_road(Vector2i(x, y)):
				road = true
				if k != FarmMap.Kind.BUILDABLE and k != FarmMap.Kind.PLOT:
					k = FarmMap.Kind.ROAD
			_road_grid[i] = 1 if road else 0
			_cls_grid[i] = PLOT_BASE + map.plot_of[i] if k == FarmMap.Kind.PLOT and map.plot_of[i] >= 0 else k


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


func _ground_is_road(t: Vector2i) -> bool:
	## True when the optional ground layer marks the tile as road/driveway.
	if map == null or not map.has_ground():
		return false
	var g := map.ground_at(t)
	if g < 0:
		return false
	return str(map.tile_type(g).get("kind", "")) in ROAD_GROUND_KINDS


func _plot_open() -> PackedByteArray:
	## Unlocked flag per plot index (aliases resolved once per redraw).
	var out := PackedByteArray()
	out.resize(map.plots.size())
	for i in map.plots.size():
		out[i] = 1 if is_unlocked(str(map.plots[i]["id"])) else 0
	return out


func _draw() -> void:
	if map == null:
		return
	if _cls_grid.size() != map.size.x * map.size.y:
		_build_static()
	var t0 := Time.get_ticks_usec()
	if not _procedural:
		var wb := map.world_bounds if map.world_bounds.size != Vector2i.ZERO else Rect2i(Vector2i.ZERO, map.size)
		var back := Iso.grid_rect_polygon(wb.grow(BACKDROP_MARGIN))
		_poly(back, TerrainTextures.get_tex("meadow"), Color(0.88, 0.92, 0.86))
	var grass := TerrainTextures.get_tex("grass")
	var open := _plot_open()
	# Row runs of equal look (kind / plot / road) become single parallelograms.
	var w := map.size.x
	for y in map.size.y:
		var row := y * w
		var x := 0
		while x < w:
			var c := _cls_grid[row + x]
			var x1 := x + 1
			while x1 < w and _cls_grid[row + x1] == c:
				x1 += 1
			_draw_run(Rect2i(x, y, x1 - x, 1), c, grass, open)
			x = x1
	if map.has_ground():
		_draw_offgrid_roads()
	_draw_land_edge()
	_draw_plot_borders(open)
	if show_plot_labels:
		_draw_labels()
	last_draw_usec = Time.get_ticks_usec() - t0


func _draw_run(r: Rect2i, cls: int, grass: Texture2D, open: PackedByteArray) -> void:
	var pts := Iso.grid_rect_polygon(r)
	if cls >= PLOT_BASE:
		var pi := cls - PLOT_BASE
		var plot_id := str(map.plots[pi]["id"])
		if open[pi] == 1:
			if not _procedural:
				_poly(pts, grass, Color.WHITE)
		elif hide_locked:
			_poly(pts, TerrainTextures.get_tex("meadow"), Color(0.8, 0.85, 0.8))
		else:
			var c := Color(0.74, 0.8, 0.7)
			if level_blocked.has(plot_id):
				c = Color(0.62, 0.64, 0.6)
			if plot_id == highlight_plot:
				c = Color(1.0, 0.72, 0.66) if highlight_blocked else Color(0.95, 1.0, 0.85)
			if _procedural:
				_poly(pts, null, _locked_veil(plot_id))
			else:
				_poly(pts, grass, c)
			_poly(pts, TerrainTextures.get_tex("hatch"), Color(1, 1, 1, 1))
		return
	if _procedural and cls != FarmMap.Kind.BLOCKED:
		return
	match cls:
		FarmMap.Kind.BUILDABLE:
			_poly(pts, grass, Color.WHITE)
		FarmMap.Kind.ROAD:
			_poly(pts, TerrainTextures.get_tex("road"), Color.WHITE)
		FarmMap.Kind.WATER:
			_poly(pts, TerrainTextures.get_tex("water"), Color.WHITE)
		FarmMap.Kind.SCENERY:
			_poly(pts, TerrainTextures.get_tex("forest"), Color.WHITE)
		FarmMap.Kind.BLOCKED:
			if map.is_game_data():
				# Game data: farm ground where nothing may be built (verges,
				# around fixed buildings) — muted grass, lightly hatched.
				_poly(pts, grass, Color(0.8, 0.86, 0.76))
				_poly(pts, TerrainTextures.get_tex("hatch"), Color(1, 1, 1, 0.22))
			else:
				# Public map: unbuildable or not-yet-mapped ground.
				if not _procedural:
					_poly(pts, TerrainTextures.get_tex("meadow"), Color(0.8, 0.84, 0.78))
				_poly(pts, TerrainTextures.get_tex("hatch"), Color(1, 1, 1, 0.6))
		_:
			pass   # VOID: the backdrop shows through


func _locked_veil(plot_id: String) -> Color:
	## See-through tint of a locked plot, so the terrain stays visible under it.
	if plot_id == highlight_plot:
		return Color(1.0, 0.45, 0.35, 0.4) if highlight_blocked else Color(1.0, 1.0, 0.75, 0.3)
	return Color(0.2, 0.2, 0.2, 0.42) if level_blocked.has(plot_id) else Color(0.12, 0.17, 0.1, 0.28)


func _draw_offgrid_roads() -> void:
	## Road / driveway tiles of the ground layer that lie outside the placement
	## grid (e.g. the road continuing past the farm): drawn as road, never land.
	var gr := map.ground_rect
	var road := TerrainTextures.get_tex("road")
	for y in range(gr.position.y, gr.end.y):
		var x := gr.position.x
		while x < gr.end.x:
			var t := Vector2i(x, y)
			if map.in_bounds(t) or not _ground_is_road(t):
				x += 1
				continue
			var x1 := x + 1
			while x1 < gr.end.x and not map.in_bounds(Vector2i(x1, y)) and _ground_is_road(Vector2i(x1, y)):
				x1 += 1
			_poly(Iso.grid_rect_polygon(Rect2i(x, y, x1 - x, 1)), road, Color.WHITE)
			x = x1


func _is_land_i(i: int) -> bool:
	var k := map.kinds[i]
	return k == FarmMap.Kind.BUILDABLE or k == FarmMap.Kind.PLOT


func _draw_land_edge() -> void:
	## A soil "slab" along the front edges of land that borders non-land,
	## so the farm reads as a raised plateau (not along roads). Off-grid
	## neighbours count as non-land.
	var depth := 7.0
	var soil := PackedVector2Array()
	var soil_dark := PackedVector2Array()
	var w := map.size.x
	var h := map.size.y
	for y in h:
		for x in w:
			var i := y * w + x
			if not _is_land_i(i):
				continue
			if y + 1 >= h or (not _is_land_i(i + w) and _road_grid[i + w] == 0):
				var a := Iso.grid_to_world(Vector2(x, y + 1))
				var b := Iso.grid_to_world(Vector2(x + 1, y + 1))
				soil.append_array([a, b, b + Vector2(0, depth), a, b + Vector2(0, depth), a + Vector2(0, depth)])
			if x + 1 >= w or (not _is_land_i(i + 1) and _road_grid[i + 1] == 0):
				var a := Iso.grid_to_world(Vector2(x + 1, y))
				var b := Iso.grid_to_world(Vector2(x + 1, y + 1))
				soil_dark.append_array([a, b, b + Vector2(0, depth), a, b + Vector2(0, depth), a + Vector2(0, depth)])
	_triangles(soil, Color("#8a6040"))
	_triangles(soil_dark, Color("#6d4a30"))


func _triangles(pts: PackedVector2Array, col: Color) -> void:
	## Many quads (as triangle lists) in one draw call.
	if pts.is_empty():
		return
	var cols := PackedColorArray()
	cols.resize(pts.size())
	cols.fill(col)
	var idx := PackedInt32Array()
	idx.resize(pts.size())
	for i in pts.size():
		idx[i] = i
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), idx, pts, cols)


func _draw_plot_borders(open: PackedByteArray) -> void:
	var segs := PackedVector2Array()
	var locked_segs := PackedVector2Array()
	var w := map.size.x
	var h := map.size.y
	var po := map.plot_of
	for y in h:
		for x in w:
			var p := po[y * w + x]
			if p < 0:
				continue
			var p_open := open[p] == 1
			for d in 4:
				var nx := x + (1 if d == 0 else (-1 if d == 2 else 0))
				var ny := y + (1 if d == 1 else (-1 if d == 3 else 0))
				var np := po[ny * w + nx] if nx >= 0 and ny >= 0 and nx < w and ny < h else -1
				if np == p:
					continue
				var a: Vector2
				var b: Vector2
				match d:
					0:
						a = Iso.grid_to_world(Vector2(x + 1, y)); b = Iso.grid_to_world(Vector2(x + 1, y + 1))
					1:
						a = Iso.grid_to_world(Vector2(x, y + 1)); b = Iso.grid_to_world(Vector2(x + 1, y + 1))
					2:
						a = Iso.grid_to_world(Vector2(x, y)); b = Iso.grid_to_world(Vector2(x, y + 1))
					_:
						a = Iso.grid_to_world(Vector2(x, y)); b = Iso.grid_to_world(Vector2(x + 1, y))
				if p_open and (np < 0 or open[np] == 1):
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
		if is_unlocked(pid) or hide_locked or not p.has("center"):
			continue
		var c: Vector2 = Iso.grid_to_world(p["center"])
		var txt := str(p.get("number", "")) if p.get("number") != null else ""
		if txt.is_empty() or txt == "<null>":
			txt = "·"
		var fs := 22
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
		var blocked := level_blocked.has(pid)
		draw_circle(c, 18, Color(0.45, 0.12, 0.1, 0.6) if blocked else Color(0.15, 0.2, 0.15, 0.55))
		draw_string(font, c + Vector2(-w * 0.5, fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))
		if blocked:
			var lt := "Lv %d" % int(level_blocked[pid])
			var lw := font.get_string_size(lt, HORIZONTAL_ALIGNMENT_CENTER, -1, 14).x
			draw_rect(Rect2(c + Vector2(-lw * 0.5 - 5, 21), Vector2(lw + 10, 19)), Color(0.45, 0.12, 0.1, 0.75))
			draw_string(font, c + Vector2(-lw * 0.5, 35), lt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.95))
	for l in map.labels:
		var c2 := Iso.grid_to_world(l["at"])
		var t2: String = l["text"]
		var w2 := font.get_string_size(t2, HORIZONTAL_ALIGNMENT_CENTER, -1, 26).x
		draw_string(font, c2 + Vector2(-w2 * 0.5, 0), t2, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(1, 1, 1, 0.55))
	# Blocked-area names explain unmapped public areas; game data has many small
	# blocked areas whose names would only clutter the farm.
	for r in map.regions:
		if map.is_game_data():
			break
		if r["kind"] == FarmMap.Kind.BLOCKED and not str(r.get("name", "")).is_empty() and not (r["rects"] as Array).is_empty():
			var rect: Rect2i = r["rects"][0]
			var c3 := Iso.grid_to_world(Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * 0.5))
			var t3: String = r["name"]
			var w3 := font.get_string_size(t3, HORIZONTAL_ALIGNMENT_CENTER, -1, 30).x
			draw_string(font, c3 + Vector2(-w3 * 0.5, 0), t3, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(1, 1, 1, 0.6))
