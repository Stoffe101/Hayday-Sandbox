extends TestCase
## The procedural terrain of the public map: what it covers, what it leaves
## alone, and that private game-data worlds keep their own ground.


func _public() -> FarmMap:
	return FarmMap.load_file("res://data/maps/hayday_farm.json")


func _built() -> TerrainLayer:
	var t := TerrainLayer.new()
	t.setup(_public())
	return t


func _is_land(m: FarmMap, t: Vector2i) -> bool:
	if not m.in_bounds(t):
		return false
	var k := m.kind_at(t)
	return k == FarmMap.Kind.BUILDABLE or k == FarmMap.Kind.PLOT


func test_applies_only_without_game_data() -> void:
	var m := _public()
	assert_true(TerrainLayer.applies_to(m))
	assert_false(TerrainLayer.applies_to(null))
	var priv := FarmMap.load_file("res://data/maps/hayday_farm.json")
	priv.provenance = {"kind": "private_game_data"}
	assert_false(TerrainLayer.applies_to(priv), "game data keeps GroundLayer's own drawing")
	var t := TerrainLayer.new()
	t.setup(priv)
	assert_eq(t._layers.size(), 0, "nothing is built for it")
	t.free()


func test_builds_every_band_of_the_public_map() -> void:
	var t := _built()
	var texs := {}
	for l: TerrainLayer.Layer in t._layers:
		texs[l.tex] = true
		assert_eq(l.pts.size(), l.uvs.size())
		assert_eq(l.pts.size(), l.alpha.size())
		assert_eq(l.idx.size() % 3, 0)
		for i in l.idx:
			assert_true(i < l.pts.size(), "index in range")
			break
	for k in ["meadow", "grass", "grass_patch", "grass_detail", "grass_tone", "pebbles", "forest", "rock", "sand", "water", "road"]:
		assert_true(texs.has(k), "band drawn with '%s'" % k)
	t.free()


func test_is_deterministic() -> void:
	var a := _built()
	var b := _built()
	assert_eq(a._layers.size(), b._layers.size())
	for i in a._layers.size():
		assert_true(a._layers[i].pts == b._layers[i].pts, "layer %d identical" % i)
	a.free()
	b.free()


func test_features_never_cover_buildable_land() -> void:
	var m := _public()
	var t := _built()
	var first := t._veil_at   # layers before it are the green cover; forests are included in that range
	var green := TerrainLayer.GREEN_LAYERS   # backdrop x2, land grass, patches, tufts, broad tone
	for li in green:
		assert_true(t._layers[li].tex in ["meadow", "grass_patch", "grass", "grass_detail", "grass_tone"], "layer %d only colours the ground" % li)
	var bad := 0
	for li in range(green, t._layers.size()):
		var l: TerrainLayer.Layer = t._layers[li]
		for p in l.pts:
			var g := Iso.world_to_grid(p)
			var c := Vector2i(floori(g.x), floori(g.y))
			var fr := g - Vector2(c)
			if minf(minf(fr.x, fr.y), minf(1.0 - fr.x, 1.0 - fr.y)) < 0.02:
				continue   # on a tile edge
			if _is_land(m, c):
				bad += 1
	assert_eq(bad, 0, "vertices of non-green layers inside land tiles (veil at %d)" % first)
	t.free()


func test_trees_keep_off_river_and_road() -> void:
	var m := _public()
	var bands := TerrainLayer.feature_bands(m)
	assert_true(SceneryLayer._in_bands(bands, Vector2i(-3, -2)), "river through the forest band")
	assert_true(SceneryLayer._in_bands(bands, Vector2i(-3, 60)), "river beyond the world")
	assert_true(SceneryLayer._in_bands(bands, Vector2i(120, 34)), "road beyond the world")
	assert_false(SceneryLayer._in_bands(bands, Vector2i(10, -2)), "forest stays forest")
	assert_eq(TerrainLayer.plateau_lift(m, Vector2i(5, -4)), TerrainLayer.CLIFF_HEIGHT)
	assert_eq(TerrainLayer.plateau_lift(m, Vector2i(5, -3)), 0.0)


func test_grass_above_the_veil_follows_the_season() -> void:
	## Layers drawn after the season veil (road verges, river bank and cliff
	## lips) must not stay summer-green in winter.
	var t := _built()
	var n := 0
	for li in range(t._veil_at, t._layers.size()):
		var l: TerrainLayer.Layer = t._layers[li]
		if l.tex in ["grass", "grass_detail", "grass_patch", "meadow", "grass_tone"]:
			n += 1
			assert_eq(l.group, "turf", "layer %d (%s) is re-coloured by the season" % [li, l.tex])
	assert_true(n >= 3, "verges and lips exist")
	assert_true(TerrainLayer.SEASONS["winter"].has("turf_set"))
	t.free()


func test_season_names() -> void:
	assert_eq(TerrainLayer.season_of("winter"), "winter")
	assert_eq(TerrainLayer.season_of("Halloween_2024"), "autumn")
	assert_eq(TerrainLayer.season_of("spring_fair"), "spring")
	assert_eq(TerrainLayer.season_of("default"), "")
	assert_eq(TerrainLayer.season_of("pirates"), "", "an unknown theme changes nothing")


func test_ground_layer_owns_a_terrain_child() -> void:
	var g := GroundLayer.new()
	g.setup(_public(), {})
	assert_true(g._procedural)
	assert_true(g._terrain.show_behind_parent, "drawn under the plot overlays")
	assert_true(g._terrain._layers.size() > 0)
	g.free()


func test_textures_are_seamless_and_cached() -> void:
	for k in ["grass_tone", "pebbles"]:
		var tex := TerrainTextures.get_tex(k)
		assert_not_null(tex)
		assert_true(TerrainTextures.get_tex(k) == tex, "%s is generated once" % k)
		var img := tex.get_image()
		assert_true(img != null and img.get_width() > 0)
		var max_a := 0.0
		for i in 64:
			max_a = maxf(max_a, img.get_pixel((i * 37) % img.get_width(), (i * 53) % img.get_height()).a)
		assert_true(max_a <= 1.0)
	# The broad tone is a gentle overlay, never an opaque colour.
	var tone := TerrainTextures.get_tex("grass_tone").get_image()
	for y in range(0, tone.get_height(), 8):
		for x in range(0, tone.get_width(), 8):
			assert_true(tone.get_pixel(x, y).a <= 0.23, "tone alpha at %d,%d" % [x, y])


# --- private pack worlds: their own ground replaces the procedural terrain ---------------

const GROUND_WORLD := "res://tests/fixtures/world_private_ground.json"


func _ground_world() -> FarmMap:
	## The synthetic private world replaces the public test world (same map id).
	return WorldLoader.load("res://tests/fixtures/world_v2.json", [{"world": GROUND_WORLD, "pack_id": "synthetic_ground"}], "")


func test_pack_world_ground_replaces_the_procedural_terrain() -> void:
	var m := _ground_world()
	assert_eq(m.provenance["active"], "private", str(m.warnings))
	assert_true(m.is_game_data())
	assert_true(m.has_ground())
	assert_false(TerrainLayer.applies_to(m))
	var g := GroundLayer.new()
	g.setup(m, {})
	assert_false(g._procedural, "GroundLayer draws the base ground itself")
	assert_eq(g._terrain._layers.size(), 0, "no procedural terrain is built under a pack world")
	# Per-tile classes come from the pack's regions and its ground layer.
	assert_eq(g.tile_class(Vector2i(1, 1)), FarmMap.Kind.BUILDABLE)
	assert_eq(g.tile_class(Vector2i(9, 1)), GroundLayer.PLOT_BASE + m.plot_index["plot_a"])
	assert_eq(g.tile_class(Vector2i(9, 4)), GroundLayer.PLOT_BASE + m.plot_index["plot_b"])
	assert_eq(g.tile_class(Vector2i(4, 6)), FarmMap.Kind.ROAD, "map road")
	assert_eq(g.tile_class(Vector2i(3, 8)), FarmMap.Kind.ROAD, "a driveway tile of the ground layer turns blocked ground into road")
	assert_eq(g.tile_class(Vector2i(4, 8)), FarmMap.Kind.BLOCKED)
	assert_eq(g.tile_class(Vector2i(2, 5)), FarmMap.Kind.BUILDABLE, "a road tile type on land stays buildable land")
	assert_true(g.is_road_tile(Vector2i(2, 5)), "…but counts as road for the land edge")
	assert_true(g.is_road_tile(Vector2i(3, 8)))
	assert_false(g.is_road_tile(Vector2i(4, 8)))
	assert_eq(g.tile_class(Vector2i(-1, 0)), -1, "off-grid tiles are never land")
	# Road tiles outside the placement grid are drawn as road runs.
	var runs := g.offgrid_road_runs()
	assert_has(runs, Rect2i(-3, -1, 3, 1), "road stub west of the farm")
	assert_has(runs, Rect2i(-3, 6, 3, 1), "the road continues west")
	assert_has(runs, Rect2i(12, 7, 3, 1), "…and east")
	for r in runs:
		for t in Iso.tiles_of(r.position, r.size):
			assert_false(m.in_bounds(t), "off-grid only: %s" % str(t))
	# Placement follows the same data: the driveway is not buildable.
	assert_false(m.is_land(Vector2i(3, 8), {}))
	assert_true(m.is_land(Vector2i(2, 5), {}))
	g.free()


func test_frontier_between_owned_and_locked_land() -> void:
	var m := _ground_world()
	var g := GroundLayer.new()
	g.setup(m, {})
	# Both plots locked: the frontier is the 6-tile edge between start land (x < 8) and the plots.
	assert_eq(g.frontier_edges(), 6)
	g.setup(m, {"plot_a": true})
	# plot_a owned: start|plot_b (3) + plot_a|plot_b (4).
	assert_eq(g.frontier_edges(), 3 + 4)
	g.setup(m, {"plot_a": true, "plot_b": true})
	assert_eq(g.frontier_edges(), 0, "everything owned: no frontier")
	g.free()
