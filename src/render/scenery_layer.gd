class_name SceneryLayer
extends Node2D
## Decorative surroundings (forest edge, trees and rocks around the farm) so the
## farm sits in a landscape instead of floating. Purely visual: never blocks
## placement and is deterministic for a given map.

const ART := ["leafy_tree", "pine_tree", "big_pine_tree", "dark_leafy_tree", "pine_tree", "leafy_tree", "mossy_rock"]

var map: FarmMap
var assets: AssetLibrary
var db: ItemDatabase
var _items: Array = []   ## [world_pos, SpriteInfo, scale]


func setup(m: FarmMap, lib: AssetLibrary, item_db: ItemDatabase) -> void:
	map = m
	assets = lib
	db = item_db
	_build()
	queue_redraw()


func _build() -> void:
	_items.clear()
	if map == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(map.id)
	var sprites: Array = []
	for key in ART:
		var it := db.get_item(key)
		var s := assets.get_sprite(it.art_key if it else key)
		if s:
			sprites.append(s)
	if sprites.is_empty():
		return
	var land := map.land_bounds()
	var pad := 10
	for y in range(-pad, map.size.y + 2):
		for x in range(-pad, map.size.x + pad):
			var t := Vector2i(x, y)
			var k := map.kind_at(t)
			var density := 0.0
			if k == FarmMap.Kind.SCENERY:
				density = 0.55
			elif k == FarmMap.Kind.VOID:
				# Behind the farm (top/left/right margins) only, so nothing
				# ever hides objects on the land.
				if y < land.position.y or x < 0 or x >= map.size.x:
					density = 0.30 if (y < 0 or x < -1 or x > map.size.x) else 0.18
			if density <= 0.0 or rng.randf() > density:
				continue
			var spr: AssetLibrary.SpriteInfo = sprites[rng.randi() % sprites.size()]
			var jitter := Vector2(rng.randf_range(-0.25, 0.25), rng.randf_range(-0.25, 0.25))
			var center := Iso.grid_to_world(Vector2(x + 0.5, y + 0.5) + jitter)
			_items.append([center, spr, rng.randf_range(0.85, 1.35), rng.randf() < 0.5])
	_items.sort_custom(func(a, b): return a[0].y < b[0].y)


func _draw() -> void:
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
