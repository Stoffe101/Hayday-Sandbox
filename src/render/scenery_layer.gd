class_name SceneryLayer
extends Node2D
## Surroundings that frame the farm (W2 design s4): the map's off-grid
## `scenery` areas (river, cliff, forest, edge — at negative tile coordinates
## in the game frame) drawn procedurally with our own textures, plus trees and
## rocks from the built-in placeholder art scattered over forest areas and the
## world margins behind / beside the farm. Purely visual: never blocks
## placement, never covers land tiles, roads or landmarks, and is
## deterministic for a given map. Where a TerrainLayer draws the ground, this
## layer only adds the scattered sprites and keeps them off the terrain's
## rivers and roads. Pack terrain (docs/TERRAIN_PACKS.md) with "scatter": false
## brings its own forests: then nothing is scattered; with base "color" the
## scenery areas are not painted either (the pack draws the surroundings).

const ART := ["leafy_tree", "pine_tree", "big_pine_tree", "dark_leafy_tree", "pine_tree", "leafy_tree", "mossy_rock"]
const ROCK_ART := ["mossy_rock", "small_rock", "big_rock"]
## Upper bound on scattered sprites (large private worlds stay cheap to draw).
const MAX_SPRITES := 2600
const MARGIN := 10   ## tiles of tree margin around the placement grid without world bounds
const OUTER := 6     ## tiles of thinner woods just outside the world bounds (backdrop)

var map: FarmMap
var assets: AssetLibrary
var db: ItemDatabase
var _items: Array = []    ## [world_pos, SpriteInfo, scale, mirrored, tint]
var _areas: Array = []    ## [kind, Rect2i]
var _pack_backdrop := false   ## pack terrain with base "color" draws the surroundings


func setup(m: FarmMap, lib: AssetLibrary, item_db: ItemDatabase) -> void:
	map = m
	assets = lib
	db = item_db
	_build()
	queue_redraw()


func _sprites(keys: Array) -> Array:
	var out: Array = []
	if assets == null:
		return out
	for key in keys:
		var it := db.get_item(key) if db else null
		var s := assets.get_sprite(it.art_key if it else key)
		if s:
			out.append(s)
	return out


func _build() -> void:
	_items.clear()
	_areas.clear()
	_pack_backdrop = false
	if map == null:
		return
	for s in map.scenery:
		_areas.append([str(s["kind"]), s["rect"] as Rect2i])
	var tp := assets.terrain_for(map) if assets else null
	if tp:
		_pack_backdrop = tp.base == "color"
		if not tp.scatter:
			return
	var trees := _sprites(ART)
	if trees.is_empty():
		return
	var rocks := _sprites(ROCK_ART)
	if rocks.is_empty():
		rocks = trees
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(map.id)
	# Tiles no decoration may stand on: landmark footprints and road tiles.
	var keep_clear := {}
	for lm in map.landmarks:
		var r := lm.rect().grow(1)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				keep_clear[Vector2i(x, y)] = true
	var wb := map.world_bounds if map.world_bounds.size != Vector2i.ZERO else Rect2i(Vector2i.ZERO, map.size).grow(MARGIN)
	var land := map.land_bounds()
	var cands: Array = []   ## [tile, density, kind]
	var outer := wb.grow(OUTER)
	var procedural := TerrainLayer.applies_to(map) and not _pack_backdrop
	var bands: Array[Rect2i] = TerrainLayer.feature_bands(map) if procedural else ([] as Array[Rect2i])
	var cliff_y := TerrainLayer.cliff_line(map) if procedural else outer.position.y - 1
	for y in range(outer.position.y, outer.end.y):
		for x in range(outer.position.x, outer.end.x):
			var t := Vector2i(x, y)
			if keep_clear.has(t) or _in_bands(bands, t):
				continue
			if not wb.has_point(t):
				# Backdrop beyond the world: woods behind and beside the farm only.
				if y < land.position.y or x < wb.position.x or x >= wb.end.x:
					if y < wb.end.y:
						cands.append([t, 0.3, "tree"])
				continue
			var area := _area_at(t)
			var density := 0.0
			var kind := "tree"
			match area:
				"forest":
					density = 0.5
				"cliff":
					density = 0.12
					kind = "rock"
				"edge":
					density = 0.2
				"river":
					continue
				_:
					var k := map.kind_at(t)
					if k == FarmMap.Kind.SCENERY:
						density = 0.5
					elif k == FarmMap.Kind.VOID and not _is_road(t):
						# Behind the farm and beside it only (never in front of
						# the land), thinning out with distance from the grid.
						if y < land.position.y or x < 0 or x >= map.size.x:
							density = 0.3 if (y < 0 or x < -1 or x > map.size.x) else 0.18
			if y == cliff_y and density > 0.0:
				density = 0.35   # boulders along the foot of the cliff
				kind = "rock"
			if density > 0.0:
				cands.append([t, density, kind])
	var expected := 0.0
	for c in cands:
		expected += c[1]
	var thin := minf(1.0, MAX_SPRITES / maxf(1.0, expected))
	for c in cands:
		if rng.randf() > float(c[1]) * thin:
			continue
		var t: Vector2i = c[0]
		var pool: Array = rocks if c[2] == "rock" else trees
		var spr: AssetLibrary.SpriteInfo = pool[rng.randi() % pool.size()]
		var jitter := Vector2(rng.randf_range(-0.25, 0.25), rng.randf_range(-0.25, 0.25))
		var center := Iso.grid_to_world(Vector2(t.x + 0.5, t.y + 0.5) + jitter)
		if procedural:
			center.y -= TerrainLayer.plateau_lift(map, t)
		_items.append([center, spr, rng.randf_range(0.85, 1.35), rng.randf() < 0.5])
	_items.sort_custom(func(a, b): return a[0].y < b[0].y)


static func _in_bands(bands: Array[Rect2i], t: Vector2i) -> bool:
	for r in bands:
		if r.has_point(t):
			return true
	return false


func _area_at(t: Vector2i) -> String:
	## Kind of the last scenery area covering t ("" = none).
	var out := ""
	for a in _areas:
		if (a[1] as Rect2i).has_point(t):
			out = a[0]
	return out


func _is_road(t: Vector2i) -> bool:
	if map.kind_at(t) == FarmMap.Kind.ROAD:
		return true
	if not map.has_ground():
		return false
	var g := map.ground_at(t)
	return g >= 0 and str(map.tile_type(g).get("kind", "")) in GroundLayer.ROAD_GROUND_KINDS


func _uv(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(p / 256.0)
	return out


func _poly(pts: PackedVector2Array, tex: Texture2D, mod: Color) -> void:
	var cols := PackedColorArray()
	for i in pts.size():
		cols.append(mod)
	draw_polygon(pts, cols, _uv(pts), tex)


func _draw() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	if not TerrainLayer.applies_to(map) and not _pack_backdrop:
		for a in _areas:
			_draw_area(a[0], a[1])
	for e in _items:
		var c: Vector2 = e[0]
		var spr: AssetLibrary.SpriteInfo = e[1]
		var k: float = e[2]
		var sc := spr.scale * k
		draw_set_transform(c, 0.0, Vector2(-sc if e[3] else sc, sc))
		if spr.shadow:
			draw_texture(spr.shadow, -spr.shadow_anchor, Color(1, 1, 1, 0.8))
		draw_texture(spr.texture, -spr.anchor, Color(0.92, 0.96, 0.92))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_area(kind: String, r: Rect2i) -> void:
	var pts := Iso.grid_rect_polygon(r)
	match kind:
		"river":
			_poly(pts, TerrainTextures.get_tex("water"), Color.WHITE)
			_draw_banks(r)
		"forest":
			_poly(pts, TerrainTextures.get_tex("forest"), Color(0.86, 0.92, 0.86))
		"cliff":
			# Grassy plateau with a rocky rim on the side that faces the farm.
			_poly(pts, TerrainTextures.get_tex("grass"), Color(0.86, 0.9, 0.8))
			_draw_rim(r)
		_:
			_poly(pts, TerrainTextures.get_tex("meadow"), Color(0.92, 0.95, 0.9))


func _draw_rim(r: Rect2i) -> void:
	var rock := Color("#a39a86")
	var dark := Color("#7d7464")
	var w := 0.6
	var g := Rect2i(Vector2i.ZERO, map.size) if map else Rect2i()
	if r.end.y <= g.position.y:
		_band(Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.end.y), Vector2(0, -w), rock)
		_band(Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.end.y), Vector2(0, -0.15), dark)
	elif r.position.y >= g.end.y:
		_band(Vector2(r.position.x, r.position.y), Vector2(r.end.x, r.position.y), Vector2(0, w), rock)
	elif r.end.x <= g.position.x:
		_band(Vector2(r.end.x, r.position.y), Vector2(r.end.x, r.end.y), Vector2(-w, 0), rock)
		_band(Vector2(r.end.x, r.position.y), Vector2(r.end.x, r.end.y), Vector2(-0.15, 0), dark)
	elif r.position.x >= g.end.x:
		_band(Vector2(r.position.x, r.position.y), Vector2(r.position.x, r.end.y), Vector2(w, 0), rock)


func _draw_banks(r: Rect2i) -> void:
	## Sandy banks along both long sides of a river area, and a light ripple
	## line down the middle, so the water reads as a river.
	var sand := Color("#d9c48f")
	var w := 0.35
	var along_y := r.size.y >= r.size.x
	var a0: Vector2
	var a1: Vector2
	var b0: Vector2
	var b1: Vector2
	if along_y:
		a0 = Vector2(r.position.x, r.position.y); a1 = Vector2(r.position.x, r.end.y)
		b0 = Vector2(r.end.x, r.position.y); b1 = Vector2(r.end.x, r.end.y)
		_band(a0, a1, Vector2(w, 0), sand)
		_band(b0, b1, Vector2(-w, 0), sand)
	else:
		a0 = Vector2(r.position.x, r.position.y); a1 = Vector2(r.end.x, r.position.y)
		b0 = Vector2(r.position.x, r.end.y); b1 = Vector2(r.end.x, r.end.y)
		_band(a0, a1, Vector2(0, w), sand)
		_band(b0, b1, Vector2(0, -w), sand)
	var m0 := (a0 + b0) * 0.5
	var m1 := (a1 + b1) * 0.5
	draw_line(Iso.grid_to_world(m0), Iso.grid_to_world(m1), Color(1, 1, 1, 0.18), 3.0)


func _band(g0: Vector2, g1: Vector2, inward: Vector2, col: Color) -> void:
	var p := PackedVector2Array([Iso.grid_to_world(g0), Iso.grid_to_world(g1),
		Iso.grid_to_world(g1 + inward), Iso.grid_to_world(g0 + inward)])
	draw_colored_polygon(p, col)
