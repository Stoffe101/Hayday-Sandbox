class_name TerrainLayer
extends Node2D
## Original procedural ground for worlds without game terrain (the public map).
## Every shape comes from the FarmMap: land and road regions, the `scenery`
## areas (river, forest, edge, cliff), the world bounds. Bands that leave the
## world (the river, the road) simply carry on across the backdrop, and the
## road crosses the river on a bridge where the two meet. When the map has no
## cliff area the north edge of the world gets one, which is where the map
## itself says the cliff is ("Y from the cliff/forest to the road").
##
## Geometry is built once per map as triangle lists. A season change only
## re-tints the cached lists (see last_draw_usec), and GroundLayer owns
## everything that depends on land ownership, so neither touches this build.
## Worlds with game data keep GroundLayer's per-tile drawing: see applies_to().

const BACKDROP_MARGIN := 24   ## tiles of ground beyond the world bounds
const CLIFF_HEIGHT := 64.0    ## world px from the foot of the cliff to its top
const STEP := 0.5             ## tiles between the cross-sections of winding edges
const WATER_INSET := 0.75     ## tiles of bank between a river's edge and its water
const UV_TILE := 256.0
const UV_PATCH := 1500.0
const UV_DETAIL := 720.0
const UV_TONE := 4200.0       ## broad tone variation: one texture repeat spans many plots
const UV_PEBBLE := 300.0
## Layers at the start of the build that only colour the ground (backdrop,
## land grass, patches, tufts, broad tone); everything after them keeps off land.
const GREEN_LAYERS := 6

## Season -> tint per layer group, and the veil laid over the green ground.
## "<group>_set" replaces a group's colour (flat, untextured) instead of tinting
## it: grass drawn above the veil (verges, bank and cliff lips) becomes snow.
const SEASONS := {
	"winter": {"veil": Color(0.95, 0.97, 1.0, 0.74), "water": Color(0.82, 0.92, 1.0), "road": Color(0.93, 0.94, 0.98), "rock": Color(0.95, 0.97, 1.0),
		"turf_set": Color(0.84, 0.9, 0.84)},   # ≈ grass under the winter veil
	"autumn": {"veil": Color(0.86, 0.56, 0.2, 0.24), "water": Color(0.88, 0.94, 0.92), "road": Color(0.97, 0.92, 0.84), "rock": Color.WHITE,
		"turf": Color(1.0, 0.86, 0.66)},
	"spring": {"veil": Color(0.9, 1.0, 0.72, 0.1), "water": Color.WHITE, "road": Color.WHITE, "rock": Color.WHITE},
	"summer": {"veil": Color(1.0, 0.9, 0.5, 0.08), "water": Color.WHITE, "road": Color.WHITE, "rock": Color.WHITE},
}
const SEASON_WORDS := {"winter": ["winter", "snow", "christmas", "frost", "ice"],
	"autumn": ["autumn", "fall", "halloween", "harvest"], "spring": ["spring", "easter", "blossom"], "summer": ["summer", "beach"]}


class Layer:
	var pts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var alpha := PackedFloat32Array()
	var idx := PackedInt32Array()
	var tex := ""               ## TerrainTextures kind ("" = flat colour)
	var group := ""             ## key into a SEASONS entry ("" = never re-tinted)
	var tint := Color.WHITE
	var uv_div := UV_TILE


var map: FarmMap
var theme := ""
var last_draw_usec := 0        ## script time of the last redraw (a season change is exactly this)
var last_build_usec := 0
## An asset pack's terrain replaces this one (PackTerrainLayer.backdrop_ok):
## nothing is built or drawn until it is lifted again (e.g. a pack piece is missing).
var suppressed := false
var _built_for: FarmMap
var _layers: Array[Layer] = []
var _veil_at := 0              ## index in _layers where the season veil is drawn
var _veil_rect := Rect2i()


func _ready() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


static func applies_to(m: FarmMap) -> bool:
	return m != null and not m.is_game_data()


func setup(m: FarmMap) -> void:
	if m == map:
		return
	map = m
	_rebuild()


func set_suppressed(on: bool) -> void:
	if on == suppressed:
		return
	suppressed = on
	if not on and _built_for != map:
		_rebuild()
	queue_redraw()


func _rebuild() -> void:
	var t0 := Time.get_ticks_usec()
	_layers.clear()
	_built_for = null
	if applies_to(map) and not suppressed:
		_build()
		_built_for = map
	last_build_usec = Time.get_ticks_usec() - t0
	queue_redraw()


func set_theme(t: String) -> void:
	if t != theme:
		theme = t
		queue_redraw()


static func season_of(theme_id: String) -> String:
	## "winter" | "autumn" | "spring" | "summer", or "" for themes without a known season.
	var low := theme_id.to_lower()
	for s: String in SEASON_WORDS:
		for w: String in SEASON_WORDS[s]:
			if low.contains(w):
				return s
	return ""


# --- what the map says --------------------------------------------------------------

static func _bounds(m: FarmMap) -> Rect2i:
	return m.world_bounds if m.world_bounds.size != Vector2i.ZERO else Rect2i(Vector2i.ZERO, m.size)


static func _rivers(m: FarmMap) -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	for s in m.scenery:
		if str(s["kind"]) == "river":
			out.append(s["rect"])
	return out


static func _road_rects(m: FarmMap) -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	for r in m.regions:
		if r["kind"] == FarmMap.Kind.ROAD:
			for rc in r["rects"]:
				out.append(rc)
	return out


static func cliff_line(m: FarmMap) -> int:
	## Grid y of the foot of the cliff; tiles north of it stand on the plateau.
	for s in m.scenery:
		if str(s["kind"]) == "cliff" and (s["rect"] as Rect2i).end.y <= 0:
			return (s["rect"] as Rect2i).end.y
	return _bounds(m).position.y


static func feature_bands(m: FarmMap) -> Array[Rect2i]:
	## Tiles SceneryLayer keeps free of trees and rocks: rivers and roads,
	## including the stretches that continue beyond the world bounds.
	var out: Array[Rect2i] = []
	var b := _bounds(m).grow(BACKDROP_MARGIN + 8)
	for r in _rivers(m):
		if r.size.y >= r.size.x:
			out.append(Rect2i(r.position.x, b.position.y, r.size.x, b.size.y))
		else:
			out.append(Rect2i(b.position.x, r.position.y, b.size.x, r.size.y))
	for r in _road_rects(m):
		out.append(Rect2i(b.position.x, r.position.y - 1, b.size.x, r.size.y + 2))
	return out


static func plateau_lift(m: FarmMap, t: Vector2i) -> float:
	## World px by which things standing on tile t are raised (the cliff top).
	return CLIFF_HEIGHT if t.y < cliff_line(m) else 0.0


# --- geometry helpers ---------------------------------------------------------------

static func _wob(s: float, seed_v: float) -> float:
	## Smooth, deterministic 0..1 wobble along a line.
	var v := 0.5 + 0.25 * sin(s * 0.83 + seed_v) + 0.15 * sin(s * 2.1 + seed_v * 1.7) + 0.1 * sin(s * 4.3 + seed_v * 0.6)
	return clampf(v, 0.0, 1.0)


func _layer(tex: String, group: String, tint: Color = Color.WHITE, uv_div: float = UV_TILE) -> Layer:
	var l := Layer.new()
	l.tex = tex
	l.group = group
	l.tint = tint
	l.uv_div = uv_div
	_layers.append(l)
	return l


func _strip(l: Layer, a: PackedVector2Array, b: PackedVector2Array, alpha_a: float = 1.0, alpha_b: float = 1.0) -> void:
	## A ribbon between two polylines of world points; alpha fades across it.
	var base := l.pts.size()
	for i in a.size():
		l.pts.append(a[i])
		l.pts.append(b[i])
		l.uvs.append(a[i] / l.uv_div)
		l.uvs.append(b[i] / l.uv_div)
		l.alpha.append(alpha_a)
		l.alpha.append(alpha_b)
		if i > 0:
			var k := base + (i - 1) * 2
			l.idx.append_array([k, k + 1, k + 2, k + 1, k + 3, k + 2])


func _quad(l: Layer, p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, a: float = 1.0) -> void:
	_strip(l, PackedVector2Array([p0, p3]), PackedVector2Array([p1, p2]), a, a)


func _rect_quad(l: Layer, r: Rect2i) -> void:
	var p := Iso.grid_rect_polygon(r)
	_quad(l, p[0], p[1], p[2], p[3])


static func _g(x: float, y: float) -> Vector2:
	return Iso.grid_to_world(Vector2(x, y))


static func _lifted(line: PackedVector2Array, lift: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(line.size())
	for i in line.size():
		out[i] = line[i] + Vector2(0.0, -lift)
	return out


func _along(s0: float, s1: float, along_y: bool, across: Callable, step: float = STEP) -> PackedVector2Array:
	## World polyline from s0 to s1 along an axis; `across(s)` gives the other coordinate.
	var out := PackedVector2Array()
	var n := maxi(1, ceili((s1 - s0) / step))
	for i in n + 1:
		var s := lerpf(s0, s1, float(i) / n)
		var t: float = across.call(s)
		out.append(_g(t, s) if along_y else _g(s, t))
	return out


# --- the world ----------------------------------------------------------------------

func _build() -> void:
	var b := _bounds(map).grow(BACKDROP_MARGIN)
	_veil_rect = b
	_build_green(b)
	_build_forests()
	_build_plateau(b)
	_veil_at = _layers.size()
	_build_cliff(b)
	for r in _rivers(map):
		_build_river(r, b)
	_build_roads(b)


func _build_green(b: Rect2i) -> void:
	_rect_quad(_layer("meadow", "", Color(0.88, 0.92, 0.86)), b)
	_rect_quad(_layer("grass_patch", "", Color(1, 1, 1, 0.75), UV_PATCH), b)
	var grass := _layer("grass", "")
	var patch := _layer("grass_patch", "", Color.WHITE, UV_PATCH)
	var detail := _layer("grass_detail", "", Color(1, 1, 1, 0.9), UV_DETAIL)
	var w := map.size.x
	for y in map.size.y:
		var x := 0
		while x < w:
			var k := map.kinds[y * w + x]
			if k != FarmMap.Kind.BUILDABLE and k != FarmMap.Kind.PLOT:
				x += 1
				continue
			var x1 := x + 1
			while x1 < w and map.kinds[y * w + x1] in [FarmMap.Kind.BUILDABLE, FarmMap.Kind.PLOT]:
				x1 += 1
			var run := Rect2i(x, y, x1 - x, 1)
			_rect_quad(grass, run)
			_rect_quad(patch, run)
			_rect_quad(detail, run)
			x = x1
	# Broad sunny / shaded tone over everything green (one quad): big lawns and
	# the backdrop get a gentle large-scale variation instead of one flat colour.
	_rect_quad(_layer("grass_tone", "", Color.WHITE, UV_TONE), b)


func _build_forests() -> void:
	var floor_ := _layer("forest", "", Color(0.86, 0.92, 0.86))
	var litter := _layer("grass_detail", "", Color(0.5, 0.62, 0.42, 0.8), UV_DETAIL)
	var edge := _layer("", "", Color(0.12, 0.22, 0.1))
	var areas: Array[Rect2i] = []
	for s in map.scenery:
		if str(s["kind"]) in ["forest", "edge"]:
			areas.append(s["rect"])
	for r in map.regions:
		if r["kind"] == FarmMap.Kind.SCENERY:
			for rc in r["rects"]:
				areas.append(rc)
	var seed_v := 1.3
	for r in areas:
		seed_v += 2.1
		var along_y := r.size.y > r.size.x
		var s0 := float(r.position.y if along_y else r.position.x)
		var s1 := float(r.end.y if along_y else r.end.x)
		var t0 := float(r.position.x if along_y else r.position.y)
		var t1 := float(r.end.x if along_y else r.end.y)
		# Both long edges wind inward, so a forest never covers buildable land.
		var a := _along(s0, s1, along_y, func(s: float) -> float: return t0 + 0.4 * _wob(s * 0.7, seed_v), 1.0)
		var z := _along(s0, s1, along_y, func(s: float) -> float: return t1 - 0.4 * _wob(s * 0.7, seed_v + 4.0), 1.0)
		_strip(floor_, a, z)
		_strip(litter, a, z)
		var a2 := _along(s0, s1, along_y, func(s: float) -> float: return t0 + 0.4 * _wob(s * 0.7, seed_v) + 0.7, 1.0)
		var z2 := _along(s0, s1, along_y, func(s: float) -> float: return t1 - 0.4 * _wob(s * 0.7, seed_v + 4.0) - 0.7, 1.0)
		_strip(edge, a, a2, 0.3, 0.0)
		_strip(edge, z, z2, 0.3, 0.0)


func _build_plateau(b: Rect2i) -> void:
	## The ground on top of the cliff, raised by CLIFF_HEIGHT.
	var c := float(cliff_line(map))
	var north := float(b.position.y)
	if north >= c:
		return
	var x0 := float(b.position.x)
	var x1 := float(b.end.x)
	var plateau := _layer("meadow", "", Color(0.94, 0.97, 0.9))
	_quad(plateau, _g(x0, north) + Vector2(0, -CLIFF_HEIGHT), _g(x1, north) + Vector2(0, -CLIFF_HEIGHT),
		_g(x1, c) + Vector2(0, -CLIFF_HEIGHT), _g(x0, c) + Vector2(0, -CLIFF_HEIGHT))
	var patch := _layer("grass_patch", "", Color(1, 1, 1, 0.6), UV_PATCH)
	_quad(patch, _g(x0, north) + Vector2(0, -CLIFF_HEIGHT), _g(x1, north) + Vector2(0, -CLIFF_HEIGHT),
		_g(x1, c) + Vector2(0, -CLIFF_HEIGHT), _g(x0, c) + Vector2(0, -CLIFF_HEIGHT))


func _build_cliff(b: Rect2i) -> void:
	var c := float(cliff_line(map))
	var x0 := float(b.position.x)
	var x1 := float(b.end.x)
	var foot := _along(x0, x1, false, func(x: float) -> float: return c + 0.22 * _wob(x * 0.9, 7.0), 1.0)
	var top := PackedVector2Array()
	var line := _along(x0, x1, false, func(_x: float) -> float: return c, 1.0)
	for i in line.size():
		top.append(line[i] + Vector2(0.0, -CLIFF_HEIGHT + 7.0 * _wob(i * 1.4, 2.0)))
	_strip(_layer("rock", "rock"), foot, top)
	var strata := _layer("", "rock", Color(0.28, 0.24, 0.2))
	for k in [0.3, 0.62]:
		var a := PackedVector2Array()
		var z := PackedVector2Array()
		for i in foot.size():
			var p := foot[i].lerp(top[i], k + 0.05 * _wob(i * 0.9, k * 9.0))
			a.append(p)
			z.append(p + Vector2(0.0, 4.0))
		_strip(strata, a, z, 0.0, 0.32)
	var cracks := _layer("", "rock", Color(0.24, 0.2, 0.17))
	var i2 := 2
	while i2 < foot.size() - 2:
		var f0 := foot[i2].lerp(top[i2], 0.12 + 0.3 * _wob(i2 * 2.2, 3.0))
		var f1 := foot[i2].lerp(top[i2], 0.55 + 0.35 * _wob(i2 * 1.3, 5.0))
		_quad(cracks, f0, f0 + Vector2(3.0, 0.0), f1 + Vector2(5.0, 0.0), f1 + Vector2(3.5, 0.0), 0.4)
		i2 += 1 + int(_wob(i2 * 3.1, 8.0) * 3.0)
	# Shade where the rock meets the forest floor, turf hanging over the top.
	var shade := PackedVector2Array()
	for i in foot.size():
		shade.append(foot[i] + Vector2(0.0, -16.0))
	_strip(_layer("", "", Color(0.1, 0.12, 0.08)), foot, shade, 0.42, 0.0)
	var lip := PackedVector2Array()
	for i in top.size():
		lip.append(top[i] + Vector2(0.0, 7.0 + 6.0 * _wob(i * 1.9, 6.0)))
	_strip(_layer("grass", "turf", Color(0.82, 0.88, 0.74)), top, lip)
	_strip(_layer("", "", Color(0.2, 0.16, 0.1)), lip, _shifted(lip, 4.0), 0.3, 0.0)


static func _shifted(line: PackedVector2Array, dy: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(line.size())
	for i in line.size():
		out[i] = line[i] + Vector2(0.0, dy)
	return out


func _build_river(r: Rect2i, b: Rect2i) -> void:
	var along_y := r.size.y >= r.size.x
	var c := float(cliff_line(map))
	var end_s := float(b.end.y if along_y else b.end.x)
	var start_s := float(b.position.y if along_y else b.position.x)
	if along_y and start_s < c:
		_river_span(r, along_y, c, end_s, 0.0)
		_river_span(r, along_y, start_s, c, CLIFF_HEIGHT)
		_waterfall(r, c)
	else:
		_river_span(r, along_y, start_s, end_s, 0.0)


func _river_span(r: Rect2i, along_y: bool, s0: float, s1: float, lift: float) -> void:
	var t0 := float(r.position.x if along_y else r.position.y)
	var t1 := float(r.end.x if along_y else r.end.y)
	var mid := (t0 + t1) * 0.5
	var ribbon := func(f: Callable) -> PackedVector2Array: return _lifted(_along(s0, s1, along_y, f), lift)
	# Banks: the side next to the farm stays inside the river's own tiles.
	var sand_a: PackedVector2Array = ribbon.call(func(s: float) -> float: return t0 - 0.3 * _wob(s * 0.6, 11.0))
	var sand_z: PackedVector2Array = ribbon.call(func(s: float) -> float: return t1 - 0.22 * _wob(s * 0.6, 13.0))
	_strip(_layer("sand", "road"), sand_a, sand_z)
	# Bank edges: a crisp turf lip where the grass ends, and its soft shadow on
	# the sand below (both inside the sand ribbon, so the land is never painted).
	var lip_a: PackedVector2Array = ribbon.call(func(s: float) -> float: return t0 - 0.3 * _wob(s * 0.6, 11.0) + 0.08)
	var lip_z: PackedVector2Array = ribbon.call(func(s: float) -> float: return t1 - 0.22 * _wob(s * 0.6, 13.0) - 0.08)
	var shade_a: PackedVector2Array = ribbon.call(func(s: float) -> float: return t0 - 0.3 * _wob(s * 0.6, 11.0) + 0.34)
	var shade_z: PackedVector2Array = ribbon.call(func(s: float) -> float: return t1 - 0.22 * _wob(s * 0.6, 13.0) - 0.34)
	var turf := _layer("grass", "turf", Color(0.86, 0.92, 0.78))
	_strip(turf, sand_a, lip_a)
	_strip(turf, lip_z, sand_z)
	var bank_shade := _layer("", "road", Color(0.36, 0.3, 0.16))
	_strip(bank_shade, lip_a, shade_a, 0.38, 0.0)
	_strip(bank_shade, shade_z, lip_z, 0.0, 0.38)
	var wa := func(s: float) -> float: return t0 + WATER_INSET + 0.45 * _wob(s * 0.8, 17.0)
	var wz := func(s: float) -> float: return t1 - WATER_INSET - 0.45 * _wob(s * 0.8, 23.0)
	var bank := _layer("", "road", Color(0.44, 0.34, 0.2))
	var wet_a: PackedVector2Array = ribbon.call(func(s: float) -> float: return wa.call(s) - 0.28)
	var wet_z: PackedVector2Array = ribbon.call(func(s: float) -> float: return wz.call(s) + 0.28)
	var edge_a: PackedVector2Array = ribbon.call(wa)
	var edge_z: PackedVector2Array = ribbon.call(wz)
	_strip(bank, wet_a, edge_a, 0.0, 0.5)
	_strip(bank, wet_z, edge_z, 0.0, 0.5)
	var stones := _layer("pebbles", "road", Color(1, 1, 1, 0.85), UV_PEBBLE)
	_strip(stones, wet_a, edge_a, 0.0, 0.9)
	_strip(stones, edge_z, wet_z, 0.9, 0.0)
	_strip(_layer("water", "water"), edge_a, edge_z)
	var deep := _layer("", "water", Color(0.16, 0.42, 0.66))
	var d0 := func(s: float) -> float: return mid - 0.75 - 0.3 * _wob(s * 0.5, 29.0)
	var d1 := func(s: float) -> float: return mid + 0.75 + 0.3 * _wob(s * 0.5, 31.0)
	var deep_a: PackedVector2Array = ribbon.call(d0)
	var deep_z: PackedVector2Array = ribbon.call(d1)
	_strip(deep, edge_a, deep_a, 0.0, 0.34)
	_strip(deep, deep_a, deep_z, 0.34, 0.34)
	_strip(deep, deep_z, edge_z, 0.34, 0.0)
	var foam := _layer("", "water", Color(0.93, 0.98, 1.0))
	var foam_a: PackedVector2Array = ribbon.call(func(s: float) -> float: return wa.call(s) + 0.12)
	var foam_z: PackedVector2Array = ribbon.call(func(s: float) -> float: return wz.call(s) - 0.12)
	_strip(foam, edge_a, foam_a, 0.6, 0.0)
	_strip(foam, edge_z, foam_z, 0.6, 0.0)
	# Long glints that follow the current.
	var glint := _layer("", "water", Color(0.88, 0.96, 1.0))
	var s := s0 + 0.7
	var n := 0
	while s < s1 - 3.0:
		var at := lerpf(t0 + 1.4, t1 - 1.4, _wob(s * 2.9, 37.0))
		var len_s := 0.9 + 1.5 * _wob(s * 1.7, 41.0)
		var w := 0.05 + 0.07 * _wob(s * 3.7, 43.0)
		var p0: Vector2 = _g(at - w, s) if along_y else _g(s, at - w)
		var p1: Vector2 = _g(at + w, s) if along_y else _g(s, at + w)
		var p2: Vector2 = _g(at + w, s + len_s) if along_y else _g(s + len_s, at + w)
		var p3: Vector2 = _g(at - w, s + len_s) if along_y else _g(s + len_s, at - w)
		var up := Vector2(0.0, -lift)
		_quad(glint, p0 + up, p1 + up, p2 + up, p3 + up, 0.28)
		s += 0.65 + 1.3 * _wob(s * 5.1, 47.0)
		n += 1


func _waterfall(r: Rect2i, c: float) -> void:
	## The river leaves the plateau over the cliff.
	var t0 := float(r.position.x) + WATER_INSET + 0.3
	var t1 := float(r.end.x) - WATER_INSET - 0.3
	var top := PackedVector2Array()
	var foot := PackedVector2Array()
	var n := maxi(2, ceili((t1 - t0) / STEP))
	for i in n + 1:
		var t := lerpf(t0, t1, float(i) / n)
		foot.append(_g(t, c + 0.1))
		top.append(_g(t, c) + Vector2(0.0, -CLIFF_HEIGHT - 1.0))
	_strip(_layer("water", "water", Color(1.0, 1.0, 1.0)), top, foot)
	var streak := _layer("", "water", Color(0.95, 0.99, 1.0))
	for i in range(1, n):
		var off := Vector2(4.0 * _wob(i * 3.3, 53.0), 0.0)
		_quad(streak, top[i] + off, top[i] + off + Vector2(5.0, 0.0), foot[i] + off + Vector2(5.0, 0.0), foot[i] + off, 0.42)
	var foam := _layer("", "water", Color(0.96, 0.99, 1.0))
	var below := PackedVector2Array()
	var edge := PackedVector2Array()
	for i in n + 1:
		var t := lerpf(t0, t1, float(i) / n)
		edge.append(_g(t, c + 0.05))
		below.append(_g(t, c + 0.75 + 0.5 * _wob(t * 3.0, 59.0)))
	_strip(foam, edge, below, 0.85, 0.0)


func _build_roads(b: Rect2i) -> void:
	var rivers := _rivers(map)
	for rd in _road_rects(map):
		if rd.size.x < rd.size.y:
			continue   # only east-west roads continue past the world (the only kind maps have)
		# Road segments between the river crossings, out to the edge of the backdrop.
		var cuts: Array[Vector2] = []
		for rv in rivers:
			if rv.size.y >= rv.size.x and rv.position.y <= rd.position.y and rv.end.y >= rd.end.y:
				cuts.append(Vector2(rv.position.x, rv.end.x))
		cuts.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
		var x := float(b.position.x)
		for cut in cuts:
			_road_span(rd, x, cut.x + 0.15)
			_bridge(rd, cut)
			x = cut.y - 0.15
		_road_span(rd, x, float(b.end.x))


func _road_span(rd: Rect2i, x0: float, x1: float) -> void:
	var y0 := float(rd.position.y)
	var y1 := float(rd.end.y)
	var vn := _along(x0, x1, false, func(_x: float) -> float: return y0, 1.0)
	var vs := _along(x0, x1, false, func(_x: float) -> float: return y1, 1.0)
	_strip(_layer("grass", "turf", Color(0.84, 0.9, 0.76)), vn, vs)
	# The dirt winds inside its strip: it never spills onto land next to the road.
	var north := func(x: float) -> float: return y0 + 0.08 + 0.28 * _wob(x * 0.7, 61.0)
	var south := func(x: float) -> float: return y1 - 0.08 - 0.28 * _wob(x * 0.7, 67.0)
	var edge_n := _along(x0, x1, false, north, 1.0)
	var edge_s := _along(x0, x1, false, south, 1.0)
	# Shoulders: worn, sun-dried verge between the grass and the dirt, inside
	# the road strip (the land next to the road is never painted).
	var verge_n := _along(x0, x1, false, func(_x: float) -> float: return y0 + 0.02, 1.0)
	var verge_s := _along(x0, x1, false, func(_x: float) -> float: return y1 - 0.02, 1.0)
	var worn := _layer("", "road", Color(0.62, 0.56, 0.3))
	_strip(worn, verge_n, edge_n, 0.0, 0.5)
	_strip(worn, edge_s, verge_s, 0.5, 0.0)
	_strip(_layer("road", "road"), edge_n, edge_s)
	# Loose stones along both dirt edges.
	var peb := _layer("pebbles", "road", Color(1, 1, 1, 0.9), UV_PEBBLE)
	var peb_n := _along(x0, x1, false, func(x: float) -> float: return north.call(x) + 0.22, 1.0)
	var peb_s := _along(x0, x1, false, func(x: float) -> float: return south.call(x) - 0.22, 1.0)
	_strip(peb, verge_n, peb_n, 0.6, 0.0)
	_strip(peb, peb_s, verge_s, 0.0, 0.6)
	var dark := _layer("", "road", Color(0.42, 0.3, 0.16))
	var in_n := _along(x0, x1, false, func(x: float) -> float: return north.call(x) + 0.32, 1.0)
	var in_s := _along(x0, x1, false, func(x: float) -> float: return south.call(x) - 0.32, 1.0)
	_strip(dark, edge_n, in_n, 0.3, 0.0)
	_strip(dark, edge_s, in_s, 0.3, 0.0)
	# Two pairs of wheel ruts, one for each direction of traffic.
	var ruts := _layer("", "road", Color(0.5, 0.36, 0.2))
	var h := y1 - y0
	for k in [0.26, 0.4, 0.6, 0.74]:
		var c: float = y0 + h * k
		var a := _along(x0, x1, false, func(x: float) -> float: return c + 0.09 * _wob(x * 0.9, k * 71.0) - 0.09, 1.0)
		var m := _along(x0, x1, false, func(x: float) -> float: return c + 0.09 * _wob(x * 0.9, k * 71.0), 1.0)
		var z := _along(x0, x1, false, func(x: float) -> float: return c + 0.09 * _wob(x * 0.9, k * 71.0) + 0.09, 1.0)
		_strip(ruts, a, m, 0.0, 0.36)
		_strip(ruts, m, z, 0.36, 0.0)
	var stones := _layer("", "road", Color(0.62, 0.55, 0.45))
	var x := x0 + 0.4
	while x < x1 - 0.4:
		var y := lerpf(y0 + 0.5, y1 - 0.5, _wob(x * 4.7, 73.0))
		var p := _g(x, y)
		var w := 2.0 + 2.5 * _wob(x * 6.1, 79.0)
		_quad(stones, p + Vector2(-w, 0), p + Vector2(0, -w * 0.5), p + Vector2(w, 0), p + Vector2(0, w * 0.5), 0.85)
		x += 0.25 + 1.2 * _wob(x * 3.3, 83.0)


func _bridge(rd: Rect2i, cut: Vector2) -> void:
	## A plank bridge, deck over the river's full width.
	var y0 := float(rd.position.y) + 0.45
	var y1 := float(rd.end.y) - 0.45
	var x0 := cut.x - 0.1
	var x1 := cut.y + 0.1
	var shade := _layer("", "", Color(0.08, 0.14, 0.2))
	_quad(shade, _g(x0, y1), _g(x1, y1), _g(x1, y1 + 0.7), _g(x0, y1 + 0.7), 0.3)
	var deck := _layer("road", "road", Color(0.8, 0.58, 0.4))
	_quad(deck, _g(x0, y0), _g(x1, y0), _g(x1, y1), _g(x0, y1))
	var gaps := _layer("", "road", Color(0.26, 0.17, 0.1))
	var x := x0 + 0.45
	while x < x1:
		_quad(gaps, _g(x, y0), _g(x + 0.05, y0), _g(x + 0.05, y1), _g(x, y1), 0.55)
		x += 0.45
	var rail := _layer("", "road", Color(0.44, 0.28, 0.16))
	var dark := _layer("", "road", Color(0.3, 0.19, 0.11))
	var rise := Vector2(0.0, -11.0)
	for y: float in [y0, y1]:
		_quad(rail, _g(x0, y) + rise, _g(x1, y) + rise, _g(x1, y) + rise + Vector2(0, 3), _g(x0, y) + rise + Vector2(0, 3))
		var px := x0 + 0.05
		while px <= x1:
			_quad(dark, _g(px, y) + rise, _g(px, y) + rise + Vector2(3.5, 0), _g(px, y) + Vector2(3.5, 0), _g(px, y))
			px += 1.0


# --- drawing ------------------------------------------------------------------------

func _draw() -> void:
	if _layers.is_empty() or suppressed:
		return
	var t0 := Time.get_ticks_usec()
	var season := season_of(theme)
	var tints: Dictionary = SEASONS.get(season, {})
	var ci := get_canvas_item()
	for i in _layers.size():
		if i == _veil_at and tints.has("veil"):
			_draw_veil(ci, tints["veil"])
		_draw_layer(ci, _layers[i], tints)
	last_draw_usec = Time.get_ticks_usec() - t0


func _draw_veil(ci: RID, c: Color) -> void:
	var p := Iso.grid_rect_polygon(_veil_rect)
	RenderingServer.canvas_item_add_polygon(ci, p, PackedColorArray([c, c, c, c]))


func _draw_layer(ci: RID, l: Layer, tints: Dictionary) -> void:
	if l.pts.is_empty():
		return
	var c := l.tint
	var tex_kind := l.tex
	if not l.group.is_empty() and tints.has(l.group):
		c *= tints[l.group] as Color
	elif not l.group.is_empty() and tints.has(l.group + "_set"):
		# Replaced outright (e.g. turf drawn above the veil turns to snow): flat colour.
		var s: Color = tints[l.group + "_set"]
		c = Color(s.r, s.g, s.b, c.a)
		tex_kind = ""
	var cols := PackedColorArray()
	cols.resize(l.pts.size())
	for i in l.pts.size():
		cols[i] = Color(c.r, c.g, c.b, c.a * l.alpha[i])
	var tex := TerrainTextures.get_tex(tex_kind).get_rid() if not tex_kind.is_empty() else RID()
	RenderingServer.canvas_item_add_triangle_array(ci, l.idx, l.pts, cols, l.uvs, PackedInt32Array(), PackedFloat32Array(), tex)
