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
	for k in ["meadow", "grass", "grass_patch", "grass_detail", "forest", "rock", "sand", "water", "road"]:
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
	var green := 5            # backdrop x2, land grass, patches, tufts
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
