extends SceneTree
## Builds a PRIVATE QA layout ("real_art_test") for checking an installed
## original-art pack in the real app: core buildings, production machines of
## every footprint, animal homes, trees, bushes, flower beds, fence rings with
## corners, path crosses/T-junctions, decorations, large objects, variants and
## planned objects. The file contains item ids only (no art), but it belongs to
## the private QA set, so it is written OUTSIDE the repository (default
## <private root>/layouts/real_art_test.hdlayout; see docs/PRIVATE_ASSETS.md).
##   godot --headless --path . --script res://tools/private_assets/make_test_layout.gd \
##     [-- --out=/root/hayday-sandbox-private-assets/layouts/real_art_test.hdlayout]
##   ... -- --gallery=production+animal_home   every item of these categories in rows
##   ... -- --items=barn+silo+...              these items in rows (QA galleries)
## Invalid placements are skipped and reported; the result has no conflicts.

var db: ItemDatabase
var map: FarmMap
var l: FarmLayout
var pack: Dictionary = {}
var skipped: Array = []
var placed_ids := {}


func _initialize() -> void:
	var out := ""
	var gallery := ""
	var items_arg := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--gallery="):
			gallery = a.substr(10)
		elif a.begins_with("--items="):
			items_arg = a.substr(8)
	if out.is_empty():
		var root := _private_root()
		if root.is_empty():
			push_error("No private root found (set HAYDAY_PRIVATE_ASSETS or pass --out=)")
			quit(2)
			return
		var stem := "real_art_test"
		if not gallery.is_empty():
			stem = "gallery_" + gallery.replace("+", "_")
		elif not items_arg.is_empty():
			stem = "gallery_items"
		out = root.path_join("layouts/%s.hdlayout" % stem)
	var repo := ProjectSettings.globalize_path("res://").trim_suffix("/")
	if out.begins_with("res://") or ProjectSettings.globalize_path(out).begins_with(repo + "/"):
		push_error("Refusing to write the private QA layout inside the repository: " + out)
		quit(2)
		return
	db = ItemDatabase.new()
	db.load_categories("res://data/items/categories.json")
	db.load_directory("res://data/items")
	db.finalize()
	map = FarmMap.load_file("res://data/maps/hayday_farm.json")
	var pj: Variant = JsonUtil.read_json("user://asset_packs/hayday_original/pack.json")
	if pj is Dictionary:
		pack = pj.get("sprites", {})
	print("pack sprites: %d" % pack.size())
	if not gallery.is_empty() or not items_arg.is_empty():
		_gallery(Array(gallery.split("+", false)), Array(items_arg.split("+", false)))
	else:
		_build()
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var d := LayoutIO.to_dict(l)
	d["app_version"] = "private-qa"
	var err := JsonUtil.write_atomic(out, JsonUtil.stringify(d, true), false)
	var conflicts := PlacementRules.find_conflicts(l, map).size()
	var no_art: Array = []
	for id in placed_ids:
		var it := db.get_item(id)
		if not pack.has(it.art_key):
			no_art.append(id)
	print("real_art_test: %d objects (%d distinct items), %d skipped, conflicts=%d, err=%s" % [l.count(), placed_ids.size(), skipped.size(), conflicts, error_string(err)])
	print("skipped: ", skipped)
	print("placed without original art: ", no_art)
	print("OUT ", out)
	quit(0 if err == OK and conflicts == 0 else 1)


static func _private_root() -> String:
	var env := OS.get_environment("HAYDAY_PRIVATE_ASSETS")
	if not env.is_empty():
		return env
	var home := OS.get_environment("USERPROFILE") if OS.has_feature("windows") else OS.get_environment("HOME")
	for c in [home.path_join("hayday-sandbox-private-assets"), "/root/hayday-sandbox-private-assets"]:
		if DirAccess.dir_exists_absolute(c):
			return c
	return ""


func P(id: String, x: int, y: int, opts: Dictionary = {}) -> PlacedObject:
	## Places at ABSOLUTE map coordinates. opts: flip, locked, planned, variant.
	var it := db.get_item(id)
	if it == null:
		skipped.append("%s (unknown id)" % id)
		return null
	var o := PlacedObject.new()
	o.item_id = id
	o.origin = Vector2i(x, y)
	o.flipped = bool(opts.get("flip", false)) and it.flippable
	o.size = it.size_for(o.flipped)
	o.locked = bool(opts.get("locked", false))
	o.planned = bool(opts.get("planned", false))
	var v := str(opts.get("variant", ""))
	if not v.is_empty():
		var e: Dictionary = pack.get(it.art_key, {})
		if e.get("variants") is Dictionary and (e["variants"] as Dictionary).has(v):
			o.variant = v
		else:
			skipped.append("%s variant %s (not in pack)" % [id, v])
	if not PlacementRules.check_rect(l, map, o.rect()).ok:
		skipped.append("%s at %d,%d" % [id, x, y])
		return null
	l.add_objects([o], false)
	placed_ids[id] = true
	return o


func line(id: String, a: Vector2i, b: Vector2i) -> void:
	for t in Iso.tiles_on_line(a, b):
		P(id, t.x, t.y)


func ring(id: String, r: Rect2i, gaps: Array = []) -> void:
	for x in range(r.position.x, r.end.x):
		for y in [r.position.y, r.end.y - 1]:
			if not Vector2i(x, y) in gaps:
				P(id, x, y)
	for y in range(r.position.y + 1, r.end.y - 1):
		for x in [r.position.x, r.end.x - 1]:
			if not Vector2i(x, y) in gaps:
				P(id, x, y)


func fill(id: String, r: Rect2i) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			P(id, x, y)


func row(ids: Array, x: int, y: int, gap: int = 1, opts: Dictionary = {}) -> int:
	## Places items left to right (along +x) with their north edges on row y.
	for id in ids:
		var it := db.get_item(id)
		if it == null:
			skipped.append("%s (unknown id)" % id)
			continue
		P(id, x, y, opts)
		x += it.footprint.x + gap
	return x


func _build() -> void:
	l = FarmLayout.new()
	l.id = ""
	l.name = "Real art test (private QA)"
	l.description = "Private QA layout for checking original-art calibration. Item ids only."
	l.map_id = map.id
	l.created = "2026-11-09T00:00:00Z"
	l.modified = "2026-11-09T00:00:00Z"
	l.tags = PackedStringArray(["private-qa"])
	var plots: Array = []
	for p in map.plots:
		plots.append(p["id"])
	l.set_unlocked(plots, false)
	# Start land is x 5..36, y 3..34 (32x32); expansions east of x = 37.
	var X := 5
	var Y := 3
	# --- core buildings (as in the starter template) ---
	P("barn", X + 2, Y + 2, {"locked": true})
	P("silo", X + 7, Y + 2, {"locked": true})
	P("farmhouse", X + 14, Y + 11, {"locked": true})
	P("mailbox", X + 18, Y + 13, {"locked": true})
	P("truck_and_order_board", X + 12, Y + 28, {"locked": true})
	P("roadside_shop", X + 17, Y + 28, {"locked": true})
	# --- path cross through the start land (junctions) ---
	line("cobblestone_path", Vector2i(X + 0, Y + 19), Vector2i(X + 31, Y + 19))
	line("cobblestone_path", Vector2i(X + 12, Y + 8), Vector2i(X + 12, Y + 27))
	# --- production lane north of the main path: 2x2, 3x3, 3x2, 4x4 ---
	row(["bakery", "feed_mill", "dairy"], X + 0, Y + 15, 0)
	row(["sugar_mill", "popcorn_pot", "bbq_grill"], X + 13, Y + 16, 0)
	row(["ice_cream_maker", "jam_maker", "juice_press"], X + 21, Y + 16, 0)
	# --- fields + fruit trees + bushes (south-west) ---
	fill("field", Rect2i(X + 0, Y + 21, 8, 4))
	var trees := ["apple_tree", "cherry_tree", "plum_tree", "lemon_tree", "orange_tree", "peach_tree", "banana_tree", "coconut_tree", "olive_tree", "mango_tree", "guava_tree"]
	for i in trees.size():
		P(trees[i], X + i, Y + 26)
	P("apple_tree", X + 0, Y + 27, {"variant": "lvl_3"})
	P("apple_tree", X + 1, Y + 27, {"variant": "lvl_2"})
	P("orange_tree", X + 2, Y + 27, {"variant": "lvl_2"})
	P("raspberry_bush", X + 4, Y + 28)
	P("blackberry_bush", X + 6, Y + 28)
	P("blueberry_bush", X + 8, Y + 28)
	P("coffee_bush", X + 9, Y + 28)
	P("raspberry_bush", X + 0, Y + 30, {"flip": true})
	# --- animal yard with a fence ring (corners + a gate gap) ---
	P("chicken_coop", X + 14, Y + 21)
	P("cow_pasture", X + 18, Y + 21)
	P("pig_pen", X + 23, Y + 21)
	P("sheep_pasture", X + 27, Y + 21)
	ring("fence", Rect2i(X + 13, Y + 20, 19, 7), [Vector2i(X + 14, Y + 20), Vector2i(X + 15, Y + 20)])
	# --- hedged garden (NE of the start land) with a brick-path cross ---
	var g := Rect2i(X + 19, Y + 1, 12, 10)
	ring("hedge", g, [Vector2i(X + 24, Y + 10), Vector2i(X + 25, Y + 10)])
	line("brick_path", Vector2i(X + 24, Y + 2), Vector2i(X + 24, Y + 9))
	line("brick_path", Vector2i(X + 25, Y + 2), Vector2i(X + 25, Y + 9))
	line("brick_path", Vector2i(X + 20, Y + 5), Vector2i(X + 29, Y + 5))
	for p in [Vector2i(21, 2), Vector2i(22, 2), Vector2i(27, 2), Vector2i(28, 2), Vector2i(21, 8), Vector2i(22, 8), Vector2i(27, 8), Vector2i(28, 8)]:
		P("tulip_patch", X + p.x, Y + p.y)
	for p in [Vector2i(20, 3), Vector2i(29, 3), Vector2i(20, 7), Vector2i(29, 7)]:
		P("classic_topiary", X + p.x, Y + p.y)
	P("fountain", X + 23, Y + 4)
	P("garden_lantern", X + 26, Y + 6)
	P("park_bench", X + 22, Y + 6)
	P("gazebo", X + 27, Y + 6)
	# --- flower beds + small decorations west of the farmhouse ---
	row(["daisies", "tulip_patch", "colorful_flowers", "raised_flowerbed", "tricolour_flowerbed", "flower_field"], X + 0, Y + 9, 0)
	row(["streetlight", "cone_topiary", "well", "windmill", "garden_lantern", "park_bench"], X + 0, Y + 12, 1)
	# --- expansion east: more production (2x2/3x3/4x4) on a stone-wall ring ---
	row(["cake_oven", "pie_oven", "lobster_pool", "mine"], 38, 4, 1)
	row(["smelter", "loom", "sewing_machine", "candle_maker", "cupcake_maker"], 38, 9, 1)
	row(["sandwich_bar", "salad_bar", "sauce_maker"], 54, 4, 1)
	ring("stone_wall_fence", Rect2i(37, 3, 29, 10), [Vector2i(45, 12), Vector2i(46, 12)])
	# --- more animals ---
	row(["goat_yard", "lamb_pasture", "horse_stable", "dog_house", "cat_house", "beehive_tree"], 38, 15, 1)
	ring("farm_fence", Rect2i(37, 14, 30, 6))
	# --- path variety: gravel / stone / golden, each with a T junction ---
	var py := 21
	for pid in ["gravel_path", "stone_path", "golden_path", "brick_path"]:
		line(pid, Vector2i(38, py), Vector2i(46, py))
		line(pid, Vector2i(42, py + 1), Vector2i(42, py + 2))
		py += 3
	# --- fence variety: short runs with an L corner ---
	var fx := 49
	for fid in ["log_fence", "rustic_fence", "hedge", "fence", "stone_wall_fence"]:
		line(fid, Vector2i(fx, 22), Vector2i(fx, 26))
		line(fid, Vector2i(fx + 1, 26), Vector2i(fx + 2, 26))
		fx += 4
	# --- nature: big decorative trees + pond ---
	row(["leafy_tree", "pine_tree", "baobab_tree", "acacia_tree", "weeping_willow", "red_tree", "winter_tree"], 70, 4, 2)
	P("duck_pond", 70, 8)
	P("lighthouse", 76, 8)
	P("helpers_house", 80, 8)
	# --- large objects ---
	P("neighborhood_house", 70, 14)
	P("fishing_boat", 80, 14)
	P("train_station_farm", 84, 14)
	# --- variants ---
	P("bakery", 70, 22, {"variant": "mastered"})
	P("dairy", 74, 22, {"variant": "mastered"})
	P("farmhouse", 79, 22, {"variant": "lvl_10"})
	P("silo", 84, 22, {"variant": "lvl_11"})
	P("barn", 70, 27, {"variant": "lvl_11"})
	# --- planned objects (ghosts) ---
	P("dairy", 76, 28, {"planned": true})
	P("cherry_tree", 81, 28, {"planned": true})
	P("cherry_tree", 82, 28, {"planned": true})
	P("fence", 81, 30, {"planned": true})
	P("fence", 82, 30, {"planned": true})
	P("fence", 83, 30, {"planned": true})


func _gallery(cats: Array, ids: Array) -> void:
	## QA gallery: items in rows (sorted by footprint), 1 free tile between them,
	## base art only, on the whole unlocked farm.
	l = FarmLayout.new()
	l.id = ""
	l.name = "Gallery %s (private QA)" % "+".join(cats if not cats.is_empty() else ["items"])
	l.map_id = map.id
	l.created = "2026-11-09T00:00:00Z"
	l.modified = "2026-11-09T00:00:00Z"
	l.tags = PackedStringArray(["private-qa"])
	var plots: Array = []
	for p in map.plots:
		plots.append(p["id"])
	l.set_unlocked(plots, false)
	var list: Array = []
	for it: ItemDef in db.ordered:
		if (it.category in cats or it.id in ids) and it.placeable:
			list.append(it)
	list.sort_custom(func(a: ItemDef, b: ItemDef) -> bool:
		var aa := a.footprint.x * a.footprint.y
		var bb := b.footprint.x * b.footprint.y
		return aa > bb if aa != bb else a.id < b.id)
	var x := 6
	var y := 4
	var row_h := 0
	for it: ItemDef in list:
		var fp := it.footprint
		var placed := false
		while not placed and y < 35:
			if x + fp.x > 90:
				x = 6
				y += row_h + 1
				row_h = 0
				continue
			if PlacementRules.check_rect(l, map, Rect2i(Vector2i(x, y), fp)).ok:
				P(it.id, x, y)
				placed = true
			x += fp.x + 1
			row_h = maxi(row_h, fp.y)
		if not placed:
			skipped.append("%s (no room)" % it.id)
