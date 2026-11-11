extends SceneTree
## Generates the ORIGINAL sample/template layouts in data/samples/ using the
## real catalogue and placement rules (invalid placements are skipped and
## reported, so samples are always valid for the current data).
##   godot --headless --path . --script res://tools/samples/generate_samples.gd
##
## Layout schema v2, game tile frame: the starting land starts at (0, 0) of the
## PUBLIC map (data/maps/hayday_farm.json; never the private world). Fixed
## landmarks (farmhouse, truck, order board, roadside shop, mailbox) are part
## of the map and are never placed as objects; the movable barn and silo are.

var db: ItemDatabase
var map: FarmMap
var l: FarmLayout
var skipped := 0
var x0 := 0
var y0 := 0


func _initialize() -> void:
	db = ItemDatabase.new()
	db.load_categories("res://data/items/categories.json")
	db.load_directory("res://data/items")
	db.finalize()
	map = FarmMap.load_file("res://data/maps/hayday_farm.json")
	for r in map.regions:
		if r["id"] == "start":
			x0 = (r["rects"][0] as Rect2i).position.x
			y0 = (r["rects"][0] as Rect2i).position.y
	DirAccess.make_dir_recursive_absolute("res://data/samples")
	_meadow()
	_symmetry()
	_district()
	_countryside()
	_minimal()
	quit(0)


func _begin(name: String, desc: String, plots: Array) -> void:
	l = FarmLayout.new()
	l.id = ""
	l.name = name
	l.description = desc
	l.map_id = map.id
	l.created = "2026-11-09T00:00:00Z"
	l.modified = "2026-11-09T00:00:00Z"
	l.tags = PackedStringArray(["sample", "original"])
	l.set_unlocked(plots, false)
	skipped = 0


func _save(file: String) -> void:
	var path := "res://data/samples/%s%s" % [file, LayoutIO.FILE_EXT]
	# Never ship a sample with objects on fixed ground (road, water, landmarks, outside).
	var col := LayoutIO.find_collisions(l, map)
	if not col.is_empty():
		for c in col:
			var o := l.get_obj(int(c["uid"]))
			printerr("SAMPLE %s: %s at %s — %s" % [file, o.item_id, o.origin, c["reason"]])
		printerr("SAMPLE %s NOT written: %d object(s) on fixed ground" % [file, col.size()])
		return
	var d := LayoutIO.to_dict(l)
	d["app_version"] = "sample"
	JsonUtil.write_atomic(path, JsonUtil.stringify(d, true), false)
	var fixed := 0
	for o: PlacedObject in l.objects.values():
		if not db.get_item(o.item_id).can_place():
			fixed += 1
	print("%s: %d objects, %d skipped, conflicts=%d, unplaceable=%d" % [file, l.count(), skipped, PlacementRules.find_conflicts(l, map).size(), fixed])


func P(id: String, x: int, y: int, flip: bool = false, locked: bool = false, planned: bool = false) -> bool:
	## Places at start-land-relative coordinates.
	var it := db.get_item(id)
	if it == null:
		push_warning("unknown item " + id)
		skipped += 1
		return false
	var o := PlacedObject.new()
	o.item_id = id
	o.origin = Vector2i(x0 + x, y0 + y)
	o.flipped = flip and it.flippable
	o.size = it.size_for(o.flipped)
	o.locked = locked
	o.planned = planned
	# check_item: fixed landmarks / other-area items are never placeable.
	if not PlacementRules.check_item(l, map, it, o.origin, o.flipped).ok:
		skipped += 1
		return false
	l.add_objects([o], false)
	return true


func line(id: String, a: Vector2i, b: Vector2i) -> void:
	for t in Iso.tiles_on_line(a, b):
		P(id, t.x, t.y)


func ring(id: String, r: Rect2i, gap: Array = []) -> void:
	for x in range(r.position.x, r.end.x):
		for y in [r.position.y, r.end.y - 1]:
			if not Vector2i(x, y) in gap:
				P(id, x, y)
	for y in range(r.position.y + 1, r.end.y - 1):
		for x in [r.position.x, r.end.x - 1]:
			if not Vector2i(x, y) in gap:
				P(id, x, y)


func fill(id: String, r: Rect2i, step: Vector2i = Vector2i.ONE) -> void:
	for y in range(r.position.y, r.end.y, step.y):
		for x in range(r.position.x, r.end.x, step.x):
			P(id, x, y)


func _core() -> void:
	## The movable starter buildings. Farmhouse, truck, order board, roadside
	## shop and mailbox are fixed landmarks of the map, not objects.
	P("barn", 2, 2)
	P("silo", 7, 2)


func _meadow() -> void:
	var plots: Array = []
	for i in range(1, 10):
		plots.append("main_%02d" % i)
	_begin("Meadow showcase", "An original sample farm: production lane, animal yard, orchard and a hedged garden.", plots)
	_core()
	# Main lane (x along the road) and a cross path.
	line("cobblestone_path", Vector2i(0, 19), Vector2i(31, 19))
	line("cobblestone_path", Vector2i(12, 8), Vector2i(12, 27))
	# Production lane north of the path.
	var x := 0
	for id in ["bakery", "feed_mill", "popcorn_pot", "sugar_mill", "dairy"]:
		var it := db.get_item(id)
		P(id, x, 19 - it.footprint.y)
		x += it.footprint.x + 1
		if x == 12 or x == 11:
			x = 13
	P("bbq_grill", 21, 16)
	P("jam_maker", 24, 16)
	P("juice_press", 27, 16)
	# Fields south-west.
	fill("field", Rect2i(0, 21, 10, 5))
	for i in 10:
		P(["apple_tree", "cherry_tree", "plum_tree", "lemon_tree", "orange_tree"][i % 5], i, 27)
	P("raspberry_bush", 0, 29)
	P("blackberry_bush", 2, 29)
	P("blueberry_bush", 4, 29)
	P("coffee_bush", 5, 29)
	# Animal yard south-east of the lane.
	P("chicken_coop", 14, 21)
	P("cow_pasture", 18, 21)
	P("pig_pen", 23, 21)
	P("sheep_pasture", 27, 21)
	ring("fence", Rect2i(13, 20, 19, 7), [Vector2i(14, 20), Vector2i(15, 20)])
	# Hedged garden in the north-east corner.
	var g := Rect2i(19, 1, 12, 10)
	ring("hedge", g, [Vector2i(24, 10), Vector2i(25, 10)])
	line("brick_path", Vector2i(24, 2), Vector2i(24, 9))
	line("brick_path", Vector2i(25, 2), Vector2i(25, 9))
	line("brick_path", Vector2i(20, 5), Vector2i(29, 5))
	P("fountain", 24, 5)
	P("fountain", 25, 5)
	for p in [Vector2i(21, 2), Vector2i(22, 2), Vector2i(27, 2), Vector2i(28, 2), Vector2i(21, 8), Vector2i(22, 8), Vector2i(27, 8), Vector2i(28, 8)]:
		P("tulip_patch", p.x, p.y)
	for p in [Vector2i(20, 3), Vector2i(29, 3), Vector2i(20, 7), Vector2i(29, 7)]:
		P("classic_topiary", p.x, p.y)
	P("garden_lantern", 23, 4)
	P("garden_lantern", 26, 6)
	P("park_bench", 22, 6)
	P("park_bench", 27, 3)
	P("gazebo", 20, 8)
	# Orchard / nature on the expansion strip.
	for i in 6:
		P("leafy_tree", 32 + i * 2, 2 + (i % 2))
		P("pine_tree", 33 + i * 2, 6 + (i % 2))
	P("duck_pond", 33, 10)
	P("windmill", 38, 11)
	P("well", 39, 13)
	_save("01_meadow_showcase")


func _symmetry() -> void:
	_begin("Symmetrical estate", "Formal, mirrored layout around a central avenue.", [])
	_core()
	line("stone_path", Vector2i(15, 15), Vector2i(15, 26))
	line("stone_path", Vector2i(16, 15), Vector2i(16, 26))
	for i in range(0, 6):
		P("cone_topiary", 13, 16 + i * 2)
		P("cone_topiary", 18, 16 + i * 2)
		P("streetlight", 14, 17 + i * 2)
		P("streetlight", 17, 17 + i * 2)
	for side in [[2, false], [21, true]]:
		var sx: int = side[0]
		P("bakery", sx, 15)
		P("feed_mill", sx + 4, 15)
		P("dairy", sx + 2, 19)
		fill("field", Rect2i(sx, 24, 8, 3))
	P("fountain", 15, 27)
	P("fountain", 16, 27)
	_save("02_symmetrical_estate")


func _district() -> void:
	var plots: Array = []
	for p in map.plots:
		plots.append(p["id"])
	_begin("Production district", "Every production building packed along service paths on a fully expanded farm.", plots)
	_core()
	var ids: Array = []
	for it: ItemDef in db.ordered:
		if it.category == "production" and it.placeable and it.movable:
			ids.append(it.id)
	var x := 34
	var y := 1
	var row_h := 0
	for id in ids:
		var it := db.get_item(id)
		if y + it.footprint.y > 30:
			x += row_h + 1
			y = 1
			row_h = 0
		P(id, x, y)
		y += it.footprint.y
		row_h = maxi(row_h, it.footprint.x)
	for col in range(33, x + row_h + 2, 5):
		line("gravel_path", Vector2i(col, 0), Vector2i(col, 31))
	_save("03_production_district")


func _countryside() -> void:
	_begin("Natural countryside", "Scattered trees, rocks and a pond with a winding trail.", ["main_01", "main_02", "main_03"])
	_core()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var trail := [Vector2i(0, 20), Vector2i(6, 20), Vector2i(6, 16), Vector2i(12, 16), Vector2i(12, 22), Vector2i(20, 22), Vector2i(20, 18), Vector2i(31, 18)]
	for i in trail.size() - 1:
		line("gravel_path", trail[i], trail[i + 1])
	P("large_pond", 2, 10)
	for i in 70:
		var id: String = ["leafy_tree", "pine_tree", "big_pine_tree", "dark_leafy_tree", "mossy_rock", "rock_formation"][rng.randi() % 6]
		P(id, rng.randi_range(0, 31), rng.randi_range(0, 31))
	fill("field", Rect2i(22, 24, 6, 4))
	P("hay_bale", 28, 24)
	P("hay_cart", 29, 25)
	P("campfire", 8, 13)
	_save("04_natural_countryside")


func _minimal() -> void:
	_begin("Minimal starter", "Just the essentials with room reserved for future buildings.", [])
	_core()
	P("bakery", 2, 15)
	P("feed_mill", 6, 15)
	P("chicken_coop", 2, 20)
	fill("field", Rect2i(2, 25, 6, 2))
	P("plan_reserve_3x3", 10, 15, false, false, false)
	P("plan_reserve_4x4", 6, 20)
	_save("05_minimal_starter")
