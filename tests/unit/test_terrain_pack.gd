extends TestCase
## Pack terrain (docs/TERRAIN_PACKS.md): the manifest format and its
## diagnostics, theme -> variant, tile art resolution, the AssetLibrary lookup,
## the renderer's caches / coverage / fallbacks and the ground-layer wiring.
## Everything uses the generated synthetic pack (no game art).

const SynTerrain := preload("res://tests/fixtures/synthetic_terrain.gd")
const ROOT := "user://test_terrain_packs"


func before_each() -> void:
	PackInstaller.remove_recursive(ROOT)


func after_each() -> void:
	PackInstaller.remove_recursive(ROOT)


func _public() -> FarmMap:
	return FarmMap.load_file("res://data/maps/hayday_farm.json")


func _tp(m: FarmMap, opts: Dictionary = {}) -> TerrainPack:
	return TerrainPack.from_data(SynTerrain.manifest(m, opts), ROOT.path_join("x/terrain"))


func _lib(m: FarmMap, opts: Dictionary = {}) -> AssetLibrary:
	var dir := ROOT.path_join("user").path_join(SynTerrain.PACK_ID)
	var w: Dictionary = SynTerrain.write_dir(dir, m, opts)
	assert_true(w["ok"], "synthetic pack written")
	var lib := AssetLibrary.new()
	lib.dev_packs_dir = ROOT.path_join("no_dev")
	lib.user_packs_dir = ROOT.path_join("user")
	lib.load_all(TestCase.fixture_db())
	return lib


func _open_all(m: FarmMap) -> PackedByteArray:
	var o := PackedByteArray()
	o.resize(m.plots.size())
	o.fill(1)
	return o


func test_synthetic_manifest_is_clean() -> void:
	var m := _public()
	var tp := _tp(m)
	assert_true(tp.is_usable())
	assert_eq(tp.errors.size(), 0, "no errors: %s" % str(tp.errors))
	assert_eq(tp.warnings.size(), 0, "no warnings: %s" % str(tp.warnings))
	assert_eq(tp.variants, ["default", "winter"] as Array[String])
	assert_eq(tp.base, "color")
	assert_false(tp.scatter)
	assert_true(tp.applies_to(m))
	var other := FarmMap.make_simple(10, 10)
	other.frame = "game"
	assert_false(tp.applies_to(other), "a map list limits it to those maps")


func test_theme_to_variant_never_guesses() -> void:
	var tp := _tp(_public())
	assert_eq(tp.variant_for("winter"), "winter")
	assert_eq(tp.variant_for("Christmas"), "winter", "themes table, case-insensitive")
	assert_eq(tp.variant_for("summer"), "default", "no summer art: the default, not a guessed season")
	assert_eq(tp.variant_for("halloween_2024"), "default")
	assert_eq(tp.variant_for(""), "default")
	assert_eq(tp.background_for("winter"), Color("#b9cbd6"))
	assert_eq(tp.background_for("default"), Color("#4d7d68"))


func test_tile_variants_suffix_and_explicit() -> void:
	var tp := _tp(_public())
	var cell := func(k: String) -> Rect2i:
		var c: Vector2i = SynTerrain.CELLS[k]
		return Rect2i(c * SynTerrain.T, Vector2i(SynTerrain.T, SynTerrain.T))
	assert_eq(tp.tile_spec("syn_grass")["rect"], cell.call("syn_grass"))
	assert_eq(tp.tile_spec("syn_grass", "winter")["rect"], cell.call("syn_grass_winter"), "suffix rule <art>_<variant>")
	assert_eq(tp.tile_spec("syn_road", "winter")["rect"], cell.call("syn_road_snow"), "explicit tile variant")
	assert_eq(tp.tile_spec("syn_plot", "winter")["rect"], cell.call("syn_plot"), "no winter art: the base texture")
	assert_eq(tp.tile_spec("nope"), {})


func test_pieces_expand_repeat_and_variants() -> void:
	var m := _public()
	var tp := _tp(m)
	var d := tp.pieces_for("default")
	var w := tp.pieces_for("winter")
	var count := func(list: Array[Dictionary], pid: String) -> int:
		return list.filter(func(p: Dictionary) -> bool: return p["id"] == pid).size()
	assert_eq(count.call(d, "beacon"), 3, "repeat count")
	assert_eq(count.call(w, "beacon"), 0, "hidden in winter")
	var hedges: Array = d.filter(func(p: Dictionary) -> bool: return p["id"] == "north_hedge")
	assert_true(hedges.size() > 10)
	assert_vec_almost(hedges[1]["at"] - hedges[0]["at"], Iso.grid_to_world(Vector2(6, 0)), 0.001, "step_tile")
	var wh: Array = w.filter(func(p: Dictionary) -> bool: return p["id"] == "north_hedge")
	assert_eq(wh[0]["modulate"], Color("#dfe9f5"), "per-piece variant override")
	assert_eq(hedges[0]["modulate"], Color.WHITE)
	var zs: Array = d.map(func(p: Dictionary) -> float: return p["z"])
	var sorted := zs.duplicate()
	sorted.sort()
	assert_eq(zs, sorted, "draw order by z")
	var river: Dictionary = d.filter(func(p: Dictionary) -> bool: return p["id"] == "river")[0]
	assert_eq(river["type"], "polygon")
	assert_eq((river["clips"] as Array).size(), 8)
	assert_has(tp.files(), "mesh/star.mesh.json")
	assert_has(tp.files(), "anim/beacon.png")


func test_bad_manifests_are_diagnosed_not_fatal() -> void:
	var bad := TerrainPack.from_data({"format": "something-else"})
	assert_false(bad.is_usable())
	assert_false(bad.applies_to(_public()))
	var tp := TerrainPack.from_data({"format": TerrainPack.FORMAT, "schema_version": 0, "frame": "game_tile",
		"atlases": {"a": {"file": "../escape.png"}},
		"tiles": {"t1": {"atlas": "missing"}, "t2": {"file": "ok.png", "rect_px": [0, 0, -1, 4]}},
		"themes": {"winter": "snowy"},
		"pieces": [
			{"id": "p1", "file": "/abs.png"},
			{"id": "p2", "polygon_tiles": [[0, 0], [1, 1]]},
			{"id": "p3", "file": "fine.png", "repeat": {"count": 3}},
			{"id": "p4", "type": "laser"},
			{"id": "p5", "file": "fine.png", "anchor_tile": [2, 3]},
			"not a piece"]})
	assert_true(tp.is_usable(), "a broken element never breaks the whole manifest")
	var all := "\n".join(tp.diagnostics())
	for frag in ["prototype", "atlas 'a'", "unknown atlas 'missing'", "bad rect_px", "unknown variant 'snowy'",
			"piece 'p1'", "at least 3 points", "repeat needs step", "unknown type 'laser'", "piece 6 is not an object"]:
		assert_true(all.contains(frag), "diagnostic mentions %s" % frag)
	var ps := tp.pieces_for()
	assert_eq(ps.size(), 2, "the good pieces survive (p3 without its repeat, p5)")
	assert_vec_almost(ps[1]["at"], Iso.grid_to_world(Vector2(2, 3)))
	var odd := TerrainPack.from_data({"format": TerrainPack.FORMAT, "schema_version": 1, "frame": "screen"})
	assert_false(odd.applies_to(_public()), "unsupported frame")


func test_ground_art_by_kind_and_ownership() -> void:
	var m := _public()
	var tp := _tp(m)
	var none := PackedByteArray()
	none.resize(m.plots.size())
	var ga := tp.ground_art(m, none)
	var art := func(g: Dictionary, t: Vector2i) -> String:
		var r: Rect2i = g["rect"]
		var i: int = g["ids"][(t.y - r.position.y) * r.size.x + (t.x - r.position.x)]
		return "" if i < 0 else g["keys"][i]
	var plot_tile := Vector2i(-1, -1)
	var build_tile := Vector2i(-1, -1)
	var road_tile := Vector2i(-1, -1)
	for y in m.size.y:
		for x in m.size.x:
			var k := m.kind_at(Vector2i(x, y))
			if k == FarmMap.Kind.PLOT and plot_tile.x < 0:
				plot_tile = Vector2i(x, y)
			elif k == FarmMap.Kind.BUILDABLE and build_tile.x < 0:
				build_tile = Vector2i(x, y)
			elif k == FarmMap.Kind.ROAD and road_tile.x < 0:
				road_tile = Vector2i(x, y)
	assert_eq(art.call(ga, build_tile), "syn_grass")
	assert_eq(art.call(ga, road_tile), "syn_road")
	assert_eq(art.call(ga, plot_tile), "syn_locked", "locked plot")
	assert_eq(art.call(tp.ground_art(m, _open_all(m)), plot_tile), "syn_plot", "unlocked plot")


func test_ground_art_uses_tile_types_art() -> void:
	var m := FarmMap.load_file("res://tests/fixtures/world_v2.json")
	assert_true(m.has_ground())
	var tp := _tp(m, {"maps": [m.id]})
	var ga := tp.ground_art(m, _open_all(m))
	var r: Rect2i = ga["rect"]
	var at := func(t: Vector2i) -> String:
		var i: int = ga["ids"][(t.y - r.position.y) * r.size.x + (t.x - r.position.x)]
		return "" if i < 0 else ga["keys"][i]
	assert_eq(at.call(Vector2i(0, 0)), "grass", "tile_types[].art")
	assert_eq(at.call(Vector2i(5, 12)), "path")
	assert_eq(m.tile_type(m.ground_at(Vector2i(19, 15)))["art"], null)
	assert_ne(at.call(Vector2i(19, 15)), "", "a type without art falls back to the kind tile")


func test_library_finds_terrain_and_lists_problems() -> void:
	var m := _public()
	var lib := _lib(m, {"omit": ["terrain/pieces/hedge.png"]})
	var tp := lib.terrain_for(m)
	assert_not_null(tp, "an installed pack's terrain applies to the public map")
	assert_eq(tp.pack_id, SynTerrain.PACK_ID)
	var st := lib.pack_stats(SynTerrain.PACK_ID)
	assert_true(st["terrain"])
	assert_has(st["missing_files"], "terrain/pieces/hedge.png", "missing terrain files show with the pack's missing files")
	assert_eq(lib.terrain_for(FarmMap.make_simple(8, 8)), null, "not for other maps")
	var none := AssetLibrary.new()
	none.dev_packs_dir = ROOT.path_join("no_dev")
	none.user_packs_dir = ROOT.path_join("no_user")
	none.load_all(TestCase.fixture_db())
	assert_eq(none.terrain_for(m), null, "built-in placeholders have no terrain")


func test_layer_builds_once_and_falls_back() -> void:
	var m := _public()
	var lib := _lib(m)
	var tp := lib.terrain_for(m)
	var layer := PackTerrainLayer.new()
	var closed := PackedByteArray()
	closed.resize(m.plots.size())
	layer.setup(m, tp, lib, closed, "")
	assert_eq(tp.errors.size(), 0, "loads cleanly: %s" % str(tp.errors))
	assert_true(layer.backdrop_ok, "everything loaded: the procedural terrain may hide")
	assert_true(layer.stats["tiles"] > m.size.x * m.size.y / 2, "ground tiles: %d" % layer.stats["tiles"])
	assert_eq(layer.stats["tile_batches"], 1, "one atlas = one batch")
	assert_eq(layer.stats["anims"], 3)
	assert_eq(layer.stats["clips"], 8)
	assert_true(layer.stats["vertices"] > 0, "mesh pieces")
	assert_true(layer.covers(Vector2i(10, 10)))
	assert_false(layer.covers(Vector2i(-3, 10)), "the river is a piece, not ground tiles")
	var mesh_node: Node2D = null
	for c in layer.get_node("Pieces").get_children():
		if str(c.name).begins_with("stars"):
			mesh_node = c
	assert_not_null(mesh_node)
	assert_not_null(mesh_node.material, "colour-add ops use the add shader")
	# Same inputs: nothing is rebuilt.
	var tv := layer.tiles_version
	var pieces0 := layer.get_node("Pieces").get_child(0)
	layer.setup(m, tp, lib, closed, "")
	assert_eq(layer.tiles_version, tv, "no rebuild without a change")
	assert_eq(layer.get_node("Pieces").get_child(0), pieces0)
	# Ownership: only the tiles.
	layer.setup(m, tp, lib, _open_all(m), "")
	assert_eq(layer.tiles_version, tv + 1, "ownership rebuilds the tiles")
	assert_eq(layer.get_node("Pieces").get_child(0), pieces0, "…but not the pieces")
	# Theme: a variant without the beacons.
	layer.setup(m, tp, lib, _open_all(m), "Christmas")
	assert_eq(layer.variant, "winter")
	assert_eq(layer.stats["anims"], 0)
	layer.free()


func test_color_backdrop_fills_far_beyond_the_world_diamond() -> void:
	## Base "color": zoomed far out, the screen corners outside the world's iso
	## diamond must show the pack's background colour, not the app's clear colour.
	var m := _public()
	var lib := _lib(m)
	var layer := PackTerrainLayer.new()
	layer.setup(m, lib.terrain_for(m), lib, _open_all(m), "")
	var bg: PackedVector2Array = layer._bg_poly
	assert_eq(bg.size(), 4)
	var wb := m.world_bounds if m.world_bounds.size != Vector2i.ZERO else Rect2i(Vector2i.ZERO, m.size)
	var diamond := Iso.grid_rect_polygon(wb.grow(PackTerrainLayer.BACKDROP_MARGIN))
	var box := PackTerrainLayer._poly_bounds(bg)
	var need := PackTerrainLayer._poly_bounds(diamond).grow(10000.0)
	assert_true(box.encloses(need), "backdrop %s encloses %s" % [str(box), str(need)])
	layer.free()


func test_missing_piece_keeps_procedural_backdrop() -> void:
	var m := _public()
	var lib := _lib(m, {"bad_piece": true})
	var tp := lib.terrain_for(m)
	var layer := PackTerrainLayer.new()
	layer.setup(m, tp, lib, _open_all(m), "")
	assert_eq(layer.failed_pieces, 1)
	assert_false(layer.backdrop_ok, "a missing piece keeps the procedural terrain underneath")
	assert_true("\n".join(tp.errors).contains("does_not_exist.png"), "reported: %s" % str(tp.errors))
	assert_true(layer.stats["pieces"] > 5, "the other pieces still draw")
	layer.free()


func test_bad_mesh_is_reported() -> void:
	var m := _public()
	var lib := _lib(m)
	var tp := lib.terrain_for(m)
	var mdir := tp.base_dir.path_join("mesh")
	var bad := SynTerrain.mesh_data()
	bad["indices"] = [0, 1, 99]
	var f := FileAccess.open(mdir.path_join("star.mesh.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(bad))
	f.close()
	var layer := PackTerrainLayer.new()
	layer.setup(m, tp, lib, _open_all(m), "")
	assert_true("\n".join(tp.errors).contains("index is out of range"), str(tp.errors))
	assert_false(layer.backdrop_ok)
	layer.free()


func test_anim_modes() -> void:
	var a := PackTerrainLayer._AnimNode.new()
	a.mode = ObjectRenderer.Ambient.OFF
	assert_eq(a.frame_of(4.0, 4, 0), -1, "Off: static")
	a.mode = ObjectRenderer.Ambient.REDUCED
	assert_eq(a.frame_of(4.0, 4, 1), -1, "Reduced: only every third instance")
	assert_true(a.frame_of(4.0, 4, 0) >= 0)
	a.mode = ObjectRenderer.Ambient.FULL
	var f0 := a.frame_of(4.0, 4, 1)
	a.clock += 0.25
	assert_ne(a.frame_of(4.0, 4, 1), f0, "Full: the clock moves the frame")
	a.free()


func test_ground_layer_hides_procedural_only_when_replaced() -> void:
	var m := _public()
	var lib := _lib(m)
	var g := GroundLayer.new()
	g.assets = lib
	g.setup(m, {})
	assert_true(g._pack_backdrop)
	assert_true(g._terrain.suppressed)
	assert_eq(g._terrain._layers.size(), 0, "the procedural terrain is not even built")
	assert_false(g._procedural)
	assert_eq(g._cov_grid.size(), m.size.x * m.size.y, "per-tile coverage for the overlays")
	assert_false(g.pack_layer().draws_land_edge(), "the pack asked for no soil edge")
	# Placeholder art (exports): back to the procedural terrain.
	g.set_assets(null)
	assert_false(g._pack_backdrop)
	assert_false(g._terrain.suppressed)
	assert_true(g._terrain._layers.size() > 0, "rebuilt on demand")
	assert_true(g._procedural)
	assert_true(g._cov_grid.is_empty())
	g.free()


func test_scenery_scatter_follows_the_pack() -> void:
	var m := _public()
	var lib := _lib(m)
	var s := SceneryLayer.new()
	s.setup(m, lib, TestCase.fixture_db())
	assert_eq(s._items.size(), 0, "\"scatter\": false — the pack brings its own surroundings")
	assert_true(s._pack_backdrop)
	s.free()


func test_validate_file_for_authors() -> void:
	var m := _public()
	_lib(m)
	var r := TerrainPack.validate_file(ROOT.path_join("user").path_join(SynTerrain.PACK_ID).path_join("terrain/terrain.json"))
	assert_true(r["ok"], str(r))
	assert_eq(r["missing"].size(), 0)
	assert_eq(r["variants"], ["default", "winter"] as Array[String])


func test_layers_and_blend_modes_parse() -> void:
	var m := _public()
	var d := _tp(m).pieces_for()
	var by_id := func(pid: String) -> Dictionary:
		return d.filter(func(p: Dictionary) -> bool: return p["id"] == pid)[0]
	assert_eq(by_id.call("canopy")["layer"], "foreground")
	assert_eq(by_id.call("river")["layer"], "ground", "ground is the default")
	assert_eq(by_id.call("rays")["blend"], "add")
	assert_eq(by_id.call("cloud_shadow")["blend"], "multiply")
	assert_eq(by_id.call("haze")["blend"], "screen")
	assert_eq(by_id.call("star_glow")["blend"], "add", "Flash / SC blend number 8")
	assert_eq(by_id.call("river")["blend"], "normal")
	assert_eq(TerrainPack.blend_name(3), "multiply")
	assert_eq(TerrainPack.blend_name("4"), "screen")
	assert_eq(TerrainPack.blend_name(1), "normal")
	assert_eq(TerrainPack.blend_name("ADD"), "add")
	assert_eq(TerrainPack.blend_name(13), "", "overlay is not supported")
	var river: Dictionary = by_id.call("river")
	var inst: Dictionary = river["clips"][1]
	assert_eq(inst["mul"], Color(1.0, 0.7, 0.7, 1.0), "clip instance mul")
	assert_eq(inst["add"], Color(0.0, 0.1, 0.3, 0.0), "clip instance add (rgb)")
	assert_eq((river["clips"][0] as Dictionary)["mul"], Color.WHITE)
	var bad := TerrainPack.from_data({"format": TerrainPack.FORMAT, "schema_version": 1, "frame": "game_tile",
		"pieces": [{"id": "a", "file": "x.png", "layer": "sky"}, {"id": "b", "file": "x.png", "blend": "overlay"}]})
	var all := "\n".join(bad.diagnostics())
	assert_true(all.contains("unknown layer 'sky'"), all)
	assert_true(all.contains("unknown blend 'overlay'"), all)
	var ps := bad.pieces_for()
	assert_eq(ps.size(), 2, "both still drawn")
	assert_eq(ps[0]["layer"], "ground")
	assert_eq(ps[1]["blend"], "normal")


func test_foreground_pieces_draw_over_objects() -> void:
	var m := _public()
	var lib := _lib(m)
	var layer := PackTerrainLayer.new()
	layer.setup(m, lib.terrain_for(m), lib, _open_all(m), "")
	assert_eq(layer.stats["foreground"], 2, "canopy + rays")
	var fg := layer.foreground
	assert_eq(fg.get_parent(), layer, "not attached yet: drawn with the ground")
	var names: Array = fg.get_node("Pieces").get_children().map(func(n: Node) -> String: return str(n.name))
	assert_true(names.any(func(n: String) -> bool: return n.begins_with("canopy")), str(names))
	for c in layer.get_node("Pieces").get_children():
		assert_false(str(c.name).begins_with("canopy"), "a foreground piece is not a ground piece")
	# main.gd: world -> [ground, ..., renderer, foreground, overlays]
	var world := Node2D.new()
	var objects := Node2D.new()
	world.add_child(layer)
	world.add_child(objects)
	world.add_child(Node2D.new())
	layer.attach_foreground(world, objects.get_index() + 1)
	assert_eq(fg.get_parent(), world)
	assert_eq(fg.get_index(), objects.get_index() + 1, "right after the objects, before the overlays")
	assert_true(fg.get_class() == "Node2D", "draws only: it never takes a click")
	for c in fg.get_children():
		assert_false(c is Control or c is CollisionObject2D)
	# Winter (own variant without its own list): the canopy stays, the extent follows.
	var hit := [0]
	layer.extent_changed.connect(func() -> void: hit[0] += 1)
	layer.setup(m, layer.pack, lib, _open_all(m), "")
	assert_eq(hit[0], 0, "no change, no signal")
	layer.free()
	assert_false(is_instance_valid(fg), "the attached foreground goes with its layer")
	world.free()


func test_blend_materials() -> void:
	assert_null(PackTerrainLayer.material_for("normal", false), "plain pieces need no material")
	var a := PackTerrainLayer.material_for("add", false)
	assert_not_null(a)
	assert_eq(a, PackTerrainLayer.material_for("add", false), "shared per combination")
	assert_ne(a, PackTerrainLayer.material_for("add", true))
	assert_true(PackTerrainLayer.shader_code("add", false).contains("blend_add"))
	assert_true(PackTerrainLayer.shader_code("multiply", false).contains("blend_mul"))
	assert_true(PackTerrainLayer.shader_code("multiply", false).contains("mix(vec3(1.0), c.rgb, c.a)"), "transparent texels leave the ground as it is")
	assert_true(PackTerrainLayer.shader_code("screen", false).contains("hint_screen_texture"))
	assert_true(PackTerrainLayer.shader_code("normal", true).contains("CUSTOM0.rgb"), "mesh add ops")
	assert_false(PackTerrainLayer.shader_code("screen", false).contains("CUSTOM0"))
	var m := _public()
	var lib := _lib(m)
	var layer := PackTerrainLayer.new()
	layer.setup(m, lib.terrain_for(m), lib, _open_all(m), "")
	assert_eq(layer.stats["blended"], 4, "rays, cloud shadow, haze, star glow")
	var mats := {}
	for holder in [layer.get_node("Pieces"), layer.foreground.get_node("Pieces")]:
		for c in holder.get_children():
			mats[str(c.name).get_slice("_", 0)] = c.material
	assert_eq(mats["rays"], PackTerrainLayer.material_for("add", false))
	assert_eq(mats["cloud"], PackTerrainLayer.material_for("multiply", false))
	assert_eq(mats["haze"], PackTerrainLayer.material_for("screen", false))
	assert_eq(mats["star"], PackTerrainLayer.material_for("add", true), "star_glow: add op + add blend")
	assert_null(mats["river"])
	layer.free()


func test_clip_colour_transforms() -> void:
	var m := _public()
	var lib := _lib(m)
	var layer := PackTerrainLayer.new()
	layer.setup(m, lib.terrain_for(m), lib, _open_all(m), "")
	var an: PackTerrainLayer._AnimNode = layer.anim_node()
	assert_true(an.has_add, "element add terms: the add pass is used")
	assert_eq(an.clips[1]["mul"], Color(1.0, 0.7, 0.7, 1.0))
	var b: Rect2 = an.clips[0]["bounds"]
	assert_true(b.size.x > 20.0 and b.size.x < 200.0, "bounds from the clip's frames, not a fixed box: %s" % str(b))
	assert_true(b.has_point((an.clips[0]["xform"] as Transform2D).origin.lerp(b.get_center(), 0.5)))
	assert_eq(PackTerrainLayer._AnimNode._rgba([0.5, 0.25, 0.0], Color(0, 0, 0, 0)), Color(0.5, 0.25, 0.0, 0.0))
	layer.free()


func test_only_clips_in_view_animate() -> void:
	var m := _public()
	var lib := _lib(m)
	var layer := PackTerrainLayer.new()
	layer.setup(m, lib.terrain_for(m), lib, _open_all(m), "")
	var an: PackTerrainLayer._AnimNode = layer.anim_node()
	an.set_mode(ObjectRenderer.Ambient.FULL)
	var far := Rect2(Vector2(1e6, 1e6), Vector2(100, 100))
	assert_eq(an.animating_in(far), 0)
	for i in 30:
		assert_false(an.advance(1.0 / 30.0, far), "nothing in view: never redrawn")
	var r0: Rect2 = an.clips[0]["bounds"]
	assert_eq(an.animating_in(r0), an.clips.filter(func(c: Dictionary) -> bool: return (c["bounds"] as Rect2).intersects(r0)).size())
	an._shown.clear()
	assert_true(an.advance(1.0 / 30.0, r0), "a clip in view: redrawn")
	an.set_mode(ObjectRenderer.Ambient.REDUCED)
	var all: Rect2 = an.clips.reduce(func(acc: Rect2, c: Dictionary) -> Rect2: return acc.merge(c["bounds"]), an.clips[0]["bounds"])
	assert_eq(an.animating_in(all), ceili(an.clips.size() / 3.0), "Reduced: every third")
	an.set_mode(ObjectRenderer.Ambient.OFF)
	assert_eq(an.animating_in(all), 0)
	assert_false(an.advance(1.0, all), "Off: never")
	assert_false(an.is_processing())
	layer.free()


func test_camera_rect_follows_the_pieces() -> void:
	var m := _public()
	var lib := _lib(m)
	var layer := PackTerrainLayer.new()
	var world := PackTerrainLayer._poly_bounds(Iso.grid_rect_polygon(Rect2i(-1000, -1000, 10, 10)))
	assert_eq(layer.camera_rect(m, world), world, "no pack: the world rect")
	layer.setup(m, lib.terrain_for(m), lib, _open_all(m), "")
	assert_true(layer.extent.size.x > 0.0)
	var wr := Iso.footprint_world_bounds(m.world_bounds.position, m.world_bounds.size)
	var cr := layer.camera_rect(m, wr)
	assert_true(cr.encloses(layer.extent.grow(PackTerrainLayer.CAMERA_MARGIN)), "every piece is reachable")
	assert_true(cr.encloses(Iso.footprint_world_bounds(Vector2i.ZERO, m.size)), "the whole placement grid too")
	for lm in m.landmarks:
		assert_true(cr.encloses(Iso.footprint_world_bounds(lm.origin, lm.footprint)), "landmark %s" % lm.id)
	assert_true(layer.extent.encloses(Rect2(layer.anim_node().clips[0]["bounds"])), "animations count")
	assert_eq(layer.camera_rect(FarmMap.make_simple(4, 4), wr), wr, "another map: its world rect")
	var proc := PackTerrainLayer.new()
	proc.setup(m, _lib(m, {"base": "procedural"}).terrain_for(m), lib, _open_all(m), "")
	assert_eq(proc.camera_rect(m, wr), wr.merge(proc.extent.grow(PackTerrainLayer.CAMERA_MARGIN)), "over the procedural terrain: the union")
	proc.free()
	layer.free()


func test_ownership_and_theme_transitions() -> void:
	## Locked -> owned plots swap only the tiles of those plots; a theme swaps
	## the variant (tiles and pieces) and back.
	var m := _public()
	var lib := _lib(m)
	var tp := lib.terrain_for(m)
	var layer := PackTerrainLayer.new()
	var closed := PackedByteArray()
	closed.resize(m.plots.size())
	layer.setup(m, tp, lib, closed, "")
	var ga0 := tp.ground_art(m, closed)
	var one := closed.duplicate()
	one[0] = 1
	var ga1 := tp.ground_art(m, one)
	var changed := 0
	var keys0: Array[String] = ga0["keys"]
	var keys1: Array[String] = ga1["keys"]
	var ids0: PackedInt32Array = ga0["ids"]
	var ids1: PackedInt32Array = ga1["ids"]
	var rect: Rect2i = ga0["rect"]
	for i in ids0.size():
		var k0 := keys0[ids0[i]] if ids0[i] >= 0 else ""
		var k1 := keys1[ids1[i]] if ids1[i] >= 0 else ""
		if k0 != k1:
			changed += 1
			var t := rect.position + Vector2i(i % rect.size.x, i / rect.size.x)
			assert_eq(m.plot_of[t.y * m.size.x + t.x], 0, "only tiles of the unlocked plot change")
			assert_eq(k0, "syn_locked")
			assert_eq(k1, "syn_plot")
	assert_true(changed > 0, "the plot's tiles changed look")
	var v := layer.tiles_version
	layer.setup(m, tp, lib, one, "")
	assert_eq(layer.tiles_version, v + 1)
	var default_batches: Array = layer._batches
	var t0 := Time.get_ticks_usec()
	layer.setup(m, tp, lib, one, "winter")
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	assert_eq(layer.variant, "winter")
	assert_eq(layer._bg_color, Color("#b9cbd6"), "the winter background colour")
	assert_false(is_same(layer._batches, default_batches))
	layer.setup(m, tp, lib, one, "")
	assert_eq(layer.variant, "default")
	assert_eq(layer._bg_color, Color("#4d7d68"))
	assert_true(is_same(layer._batches, default_batches), "back to a variant seen with this ownership: cached triangles")
	layer.setup(m, tp, lib, _open_all(m), "")
	assert_false(is_same(layer._batches, default_batches), "another ownership: rebuilt")
	assert_true(ms < 250.0, "theme switch (synthetic, headless) %.1f ms" % ms)
	layer.free()
