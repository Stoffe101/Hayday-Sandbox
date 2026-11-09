extends TestCase
## World layer: Landmark records, FarmMap schema v2 (landmarks, ground RLE,
## plot aliases, sections, scenery), WorldLoader (public / private candidates /
## user corrections), LANDMARK placement code, catalogue overrides and hidden
## catalogue items. Synthetic fixtures only — no game data.

const WORLD := "res://tests/fixtures/world_v2.json"
const PRIVATE := "res://tests/fixtures/world_private.json"
const PRIVATE_BAD := "res://tests/fixtures/world_private_bad.json"
const OVERRIDES_DIR := "res://tests/fixtures/world_overrides"
const TMP := "user://test_world"


func before_each() -> void:
	PackInstaller.remove_recursive(ProjectSettings.globalize_path(TMP))


func after_each() -> void:
	PackInstaller.remove_recursive(ProjectSettings.globalize_path(TMP))


static func world_db() -> ItemDatabase:
	var db := ItemDatabase.new()
	db.load_categories("res://tests/fixtures/categories.json")
	db.load_file("res://tests/fixtures/items.json")
	db.load_file("res://tests/fixtures/world_items.json")
	db.finalize()
	return db


static func _write_json(path: String, data: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, " "))
	f.close()


static func _lm_dict() -> Dictionary:
	return {"id": "barn_x", "name": "Barn X", "area": "farm_side", "origin": [-2, 4], "footprint": [3, 2],
		"states": ["broken", "ok"], "default_state": "ok", "skin_kind": "house", "skins": [{"id": "red", "name": "Red"}],
		"themes": ["winter"], "unlock_level": 9, "replaces_items": ["a", "b"], "confidence": "strong",
		"evidence": "synthetic", "note": "n", "future_field": 3}


# --- Landmark -------------------------------------------------------------------------

func test_landmark_parse_and_roundtrip() -> void:
	var errs: Array = []
	var lm := Landmark.from_dict(_lm_dict(), errs)
	assert_not_null(lm)
	assert_eq(errs.size(), 0, str(errs))
	assert_eq(lm.origin, Vector2i(-2, 4))
	assert_eq(lm.rect(), Rect2i(-2, 4, 3, 2))
	assert_eq(lm.block_rects(), [Rect2i(-2, 4, 3, 2)] as Array[Rect2i], "default blocks = footprint")
	assert_eq(lm.art, "lm_barn_x", "art defaults to lm_<id>")
	assert_eq(lm.draw_anchor, "top_corner")
	assert_false(lm.movable)
	assert_false(lm.rotatable)
	assert_true(lm.has_skin("red"))
	assert_true(lm.has_skin("original"), "Original is implied")
	var d := lm.to_dict()
	assert_eq(d["future_field"], 3, "unknown fields survive a round trip")
	assert_false(d.has("blocks"), "implicit blocks are not written")
	var back := Landmark.from_dict(d, errs)
	assert_eq(errs.size(), 0)
	assert_eq(back.to_dict(), d, "to_dict -> from_dict -> to_dict is stable")
	var d2 := _lm_dict()
	d2["blocks"] = []
	var none := Landmark.from_dict(d2, errs)
	assert_eq(none.block_rects().size(), 0, "explicit [] blocks nothing")
	assert_false(none.blocks_tile(Vector2i(-2, 4)))
	assert_eq(Landmark.from_dict(none.to_dict(), errs).block_rects().size(), 0, "[] survives a round trip")


func test_landmark_validation_errors() -> void:
	var cases := {
		"footprint": [0, 2], "origin": [1.5, 2], "draw_anchor": "middle", "confidence": "sure",
		"default_state": "nope", "blocks": [[0, 0, 0, 1]], "id": "Bad Id",
	}
	for k in cases:
		var d := _lm_dict()
		d[k] = cases[k]
		var errs: Array = []
		assert_null(Landmark.from_dict(d, errs), "bad %s rejected" % k)
		assert_true(errs.size() >= 1, "bad %s reported" % k)
	var errs2: Array = []
	var warns: Array = []
	var d3 := _lm_dict()
	d3["movable"] = true
	d3["area"] = "moon"
	var lm := Landmark.from_dict(d3, errs2, warns)
	assert_not_null(lm, "cosmetic problems are warnings only")
	assert_false(lm.movable, "a map file cannot make a landmark movable")
	assert_eq(warns.size(), 2)


# --- FarmMap v2 -----------------------------------------------------------------------

func test_map_v2_parses_everything() -> void:
	var m := FarmMap.load_file(WORLD)
	assert_eq(m.errors.size(), 0, str(m.errors))
	assert_eq(m.schema_version, 2)
	assert_eq(m.frame, "game")
	assert_eq(m.provenance["kind"], "public_approximation")
	assert_false(m.is_game_data())
	assert_eq(m.world_bounds, Rect2i(-4, -2, 24, 22))
	assert_eq(m.landmark_ids(), ["house", "dock", "sign"] as Array[String])
	assert_eq(m.landmark("house").name, "Test House")
	assert_null(m.landmark("nope"))
	assert_eq(m.landmark("dock").draw_anchor, "center")
	assert_eq(m.landmarks_replacing("w_house"), ["house"] as Array[String])
	assert_eq(m.scenery.size(), 2)
	assert_eq(m.scenery[0]["rect"], Rect2i(-4, -2, 4, 22))
	assert_eq(m.tile_type(2)["name"], "Road")
	assert_true(m.has_ground())
	assert_eq(m.ground_at(Vector2i(0, 0)), 0)
	assert_eq(m.ground_at(Vector2i(5, 12)), 3, "RLE run 2 in row 12")
	assert_eq(m.ground_at(Vector2i(6, 13)), 0)
	assert_eq(m.ground_at(Vector2i(19, 15)), 2)
	assert_eq(m.ground_at(Vector2i(19, 19)), 5)
	assert_eq(m.ground_at(Vector2i(-1, 0)), -1, "no ground outside its rect")
	assert_eq(m.sections.size(), 1)
	assert_eq(m.section("main")["plots"], ["plot_east", "plot_far"] as Array[String], "aliases resolved in sections")
	assert_eq(m.initial_objects.size(), 2)
	assert_eq(m.initial_objects[1]["origin"], Vector2i(8, 2))
	assert_true(m.initial_objects[1]["flip"])
	assert_eq(m.terrain_path, "res://tests/fixtures/terrain/terrain.json", "terrain resolved next to the map file")
	var p := m.plot("plot_far")
	assert_eq(p["game_id"], 8)
	assert_true(p["client_locked"])
	assert_eq(p["locked_text"], "Coming soon")
	assert_eq(p["exclusive_decorations"], ["t_lamp"])
	assert_eq(m.provenance_label(), "Public approximation")


func test_landmark_mask_and_offgrid_tiles() -> void:
	var m := FarmMap.load_file(WORLD)
	var house := m.landmark_index["house"] as int
	var dock := m.landmark_index["dock"] as int
	assert_eq(m.landmark_at(Vector2i(3, 3)), house)
	assert_eq(m.landmark_at(Vector2i(5, 5)), house)
	assert_eq(m.landmark_at(Vector2i(6, 5)), -1)
	assert_eq(m.landmark_id_at(Vector2i(4, 4)), "house")
	assert_eq(m.landmark_at(Vector2i(0, 6)), dock, "in-grid end of a negative-origin landmark")
	assert_eq(m.landmark_at(Vector2i(-2, 6)), dock, "off-grid tile")
	assert_eq(m.landmark_at(Vector2i(0, 7)), -1, "footprint row not listed in blocks")
	assert_eq(m.landmark_at(Vector2i(12, 14)), -1, "blocks: [] never blocks")
	assert_eq(m.landmark_covering(Vector2i(12, 14)), m.landmark_index["sign"])
	assert_eq(m.landmark_covering(Vector2i(0, 7)), dock)


func test_plot_aliases() -> void:
	var m := FarmMap.load_file(WORLD)
	assert_eq(m.resolve_plot_id("exp_7"), "plot_east")
	assert_eq(m.resolve_plot_id("plot_east"), "plot_east")
	assert_eq(m.resolve_plot_id("mystery"), "mystery", "unknown ids are never dropped")
	assert_true(m.has_plot("exp_8"))
	assert_eq(m.plot("exp_8")["name"], "Far plot")
	assert_eq(m.plot_id_at(Vector2i(11, 0)), "plot_east", "tiles report canonical ids")
	assert_false(m.is_land(Vector2i(11, 0), {}))
	assert_true(m.is_land(Vector2i(11, 0), {"exp_7": true}), "alias unlocks the plot")
	assert_true(m.is_plot_unlocked("exp_7", {"plot_east": true}))
	assert_eq(m.unlockable_plots({}), ["plot_east"] as Array[String])
	assert_eq(m.unlockable_plots({"exp_7": true}), ["plot_far"] as Array[String], "alias counts as unlocked neighbour")
	assert_eq(m.canonical_unlocked({"exp_7": true, "zzz": true}), {"plot_east": true, "zzz": true})
	assert_eq(m.canonical_unlocked(["exp_8"]), {"plot_far": true})
	assert_eq(m.buildable_tile_count({"exp_7": true}), m.buildable_tile_count({"plot_east": true}))
	var lay := FarmLayout.new()
	lay.set_unlocked(["exp_7"])
	var r := PlacementRules.check_rect(lay, m, Rect2i(11, 0, 1, 1))
	assert_true(r.ok, "placement accepts aliases in layout.unlocked_plots")


func test_plot_level_requirements() -> void:
	var m := FarmMap.load_file(WORLD)
	assert_eq(m.plot_level_block("plot_east", 10), "Requires level 12")
	assert_eq(m.plot_level_block("exp_7", 12), "")
	assert_eq(m.plot_level_block("plot_east", -1), "", "no level limit (Creative)")
	assert_eq(m.unlockable_plots({}, 10).size(), 0)
	assert_eq(m.unlockable_plots({}, 12), ["plot_east"] as Array[String])
	assert_eq(m.unlockable_plots({"plot_east": true}, 20).size(), 0, "level 30 plot still locked at 20")


func test_v1_map_still_parses() -> void:
	var m := fixture_map()
	assert_eq(m.errors.size(), 0)
	assert_eq(m.schema_version, 1)
	assert_eq(m.frame, "v1")
	assert_eq(m.landmarks.size(), 0)
	assert_eq(m.landmark_at(Vector2i(1, 1)), -1)
	assert_eq(m.world_bounds, Rect2i(0, 0, 20, 20))
	assert_false(m.has_ground())


func test_map_v2_errors_are_reported() -> void:
	var d: Dictionary = JsonUtil.read_json(WORLD)
	var bad := d.duplicate(true)
	bad["ground"]["rows"][3] = [[0, 19]]
	assert_true(FarmMap.from_data(bad).errors.size() > 0, "short ground row")
	bad = d.duplicate(true)
	bad["landmarks"].append(bad["landmarks"][0].duplicate(true))
	assert_has(" ".join(FarmMap.from_data(bad).errors), "duplicate landmark")
	bad = d.duplicate(true)
	bad["regions"][2]["aliases"] = ["plot_far"]
	assert_has(" ".join(FarmMap.from_data(bad).errors), "collides")
	bad = d.duplicate(true)
	bad["frame"] = "v1"
	assert_true(FarmMap.from_data(bad).errors.size() > 0, "v2 requires the game frame")
	bad = d.duplicate(true)
	bad["terrain"] = "../../escape.json"
	var m := FarmMap.from_data(bad, "res://x")
	assert_eq(m.terrain_path, "", "unsafe terrain path ignored")
	assert_eq(m.errors.size(), 0)


func test_public_map_is_v2_game_frame() -> void:
	var m := FarmMap.load_file("res://data/maps/hayday_farm.json")
	assert_eq(m.errors.size(), 0, str(m.errors))
	assert_eq(m.schema_version, 2)
	assert_eq(m.provenance["kind"], "public_approximation")
	assert_eq(m.kind_at(Vector2i(0, 0)), FarmMap.Kind.BUILDABLE, "start land at the origin")
	assert_eq(m.kind_at(Vector2i(31, 31)), FarmMap.Kind.BUILDABLE)
	for y in range(32, 37):
		assert_eq(m.kind_at(Vector2i(10, y)), FarmMap.Kind.ROAD, "5-row road strip y 32..36")
	assert_eq(m.kind_at(Vector2i(10, 37)), FarmMap.Kind.BLOCKED, "across-road blocked")
	assert_eq(m.plots.size(), 52)
	assert_eq(m.landmark_ids().size(), 5)
	for lid in ["farmhouse", "truck", "order_board", "roadside_shop", "newspaper_mailbox"]:
		var lm := m.landmark(lid)
		assert_not_null(lm, lid)
		if lm:
			assert_eq(lm.confidence, "approximate")
			assert_true(Rect2i(0, 0, 32, 32).encloses(lm.rect()), "%s inside the start land" % lid)
	assert_true(m.world_bounds.position.x < 0 and m.world_bounds.position.y < 0, "scenery off-grid")
	assert_eq(m.landmark_at(m.landmark("farmhouse").origin), m.landmark_index["farmhouse"])


func test_large_map_build_is_fast() -> void:
	# Synthetic map of the private world's order of magnitude (larger on purpose).
	var w := 120
	var h := 90
	var regions: Array = [{"id": "start", "kind": "buildable", "rects": [[0, 0, 32, 32]]},
		{"id": "road", "kind": "road", "rects": [[0, 32, w, 5]]}]
	var n := 0
	for gy in range(0, 90, 6):
		for gx in range(32 if gy < 32 else 0, 120, 6):
			if gy >= 32 and gy < 37:
				continue
			regions.append({"id": "p_%d" % n, "kind": "plot", "aliases": ["exp_%d" % n], "game_id": n,
				"rects": [[gx, gy, mini(6, w - gx), mini(6, h - gy)], [gx, gy, 1, 1]]})
			n += 1
	var lms: Array = []
	for i in 32:
		lms.append({"id": "lm_%d" % i, "origin": [(i * 3) % 110 - 4, (i * 7) % 80 - 5], "footprint": [2 + i % 3, 2],
			"confidence": "approximate"})
	var rows: Array = []
	for y in h:
		rows.append([[0, 40], [2, 40], [1, 40]])
	var d := {"format": FarmMap.FORMAT, "schema_version": 2, "frame": "game", "id": "big", "size": [w, h],
		"regions": regions, "landmarks": lms, "ground": {"encoding": "rle-rows", "rows": rows}}
	var best := 1e9
	var m: FarmMap
	for i in 3:
		var t0 := Time.get_ticks_usec()
		m = FarmMap.from_data(d)
		best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
	print("    [perf] FarmMap.from_dict %dx%d, %d plots, %d landmarks: %.1f ms" % [w, h, m.plots.size(), m.landmarks.size(), best])
	assert_eq(m.errors.size(), 0, str(m.errors))
	assert_true(m.plots.size() >= 230)
	assert_true(best < 100.0, "map build took %.1f ms (budget 50 ms, test allows 2x for slow CI)" % best)


# --- WorldLoader ----------------------------------------------------------------------

func test_loader_public_only() -> void:
	var m := WorldLoader.load(WORLD, [], "")
	assert_eq(m.errors.size(), 0)
	assert_eq(m.provenance["active"], "public")
	assert_eq(m.provenance_label(), "Public approximation")
	assert_eq(m.size, Vector2i(20, 20))


func test_loader_private_replaces_public() -> void:
	var cands: Array = [{"pack_id": "hayday_original", "version": "2026.11.09", "world": PRIVATE, "priority": 110}]
	var m := WorldLoader.load(WORLD, cands, "")
	assert_eq(m.errors.size(), 0, str(m.errors))
	assert_eq(m.provenance["active"], "private")
	assert_eq(m.provenance["pack_id"], "hayday_original")
	assert_eq(m.provenance_label(), "Game data (private pack 2026.11.09)")
	assert_true(m.is_game_data())
	assert_eq(m.size, Vector2i(24, 20), "private world replaces the public map entirely")
	assert_eq(m.landmark("house").origin, Vector2i(5, 5))
	assert_true(m.has_plot("exp_9"))
	assert_false(m.has_ground(), "nothing of the public map is merged in")
	assert_eq(m.source_path, PRIVATE)


func test_loader_invalid_private_falls_back() -> void:
	var other: Dictionary = JsonUtil.read_json(PRIVATE)
	other["id"] = "another_map"
	_write_json(TMP.path_join("other/world.json"), other)
	var v1: Dictionary = JsonUtil.read_json(PRIVATE)
	v1["schema_version"] = 1
	_write_json(TMP.path_join("v1/world.json"), v1)
	var cands: Array = [
		{"pack_id": "bad", "world": PRIVATE_BAD},
		{"pack_id": "other", "world": TMP.path_join("other/world.json")},
		{"pack_id": "old", "world": TMP.path_join("v1/world.json")},
		{"pack_id": "missing", "world": TMP.path_join("nope/world.json")},
	]
	var m := WorldLoader.load(WORLD, cands, "")
	assert_eq(m.provenance["active"], "public")
	assert_eq(m.size, Vector2i(20, 20))
	assert_eq((m.provenance["rejected"] as Array).size(), 4)
	var text := " ".join(m.warnings)
	for pid in ["'bad'", "'other'", "'old'", "'missing'"]:
		assert_has(text, pid)
	assert_has(text, "footprint")
	# A broken high-priority pack does not hide a valid lower-priority one.
	cands.append({"pack_id": "good", "version": "1.0", "world": PRIVATE})
	var m2 := WorldLoader.load(WORLD, cands, "")
	assert_eq(m2.provenance["active"], "private")
	assert_eq(m2.provenance["pack_id"], "good")
	# Highest priority (first) valid candidate wins.
	var m3 := WorldLoader.load(WORLD, [{"pack_id": "a", "world": PRIVATE}, {"pack_id": "b", "world": PRIVATE}], "")
	assert_eq(m3.provenance["pack_id"], "a")
	assert_eq(m3.provenance_label(), "Game data (private pack 2026-02-03)", "falls back to the generation date")


func test_loader_user_overrides() -> void:
	var m := WorldLoader.load(WORLD, [], OVERRIDES_DIR)
	assert_eq(m.errors.size(), 0, str(m.errors))
	assert_eq(m.landmark("house").origin, Vector2i(6, 6), "user correction applied last")
	assert_eq(m.landmark_id_at(Vector2i(6, 6)), "house", "mask rebuilt")
	assert_eq(m.landmark_at(Vector2i(3, 3)), -1)
	assert_eq(m.landmark("dock").note, "moved by me")
	assert_eq(m.landmark("dock").art, "lm_dock", "non-patchable field ignored")
	assert_eq(m.provenance["user_overrides"]["landmarks"], ["house", "dock"])
	assert_eq(m.provenance_label(), "Public approximation + your corrections")
	var text := " ".join(m.warnings)
	assert_has(text, "unknown landmark 'nope'")
	assert_has(text, "dock.art")
	# Also on top of a private world.
	var mp := WorldLoader.load(WORLD, [{"pack_id": "p", "version": "9", "world": PRIVATE}], OVERRIDES_DIR)
	assert_eq(mp.landmark("house").origin, Vector2i(6, 6))
	assert_eq(mp.size, Vector2i(24, 20))
	assert_eq(mp.provenance_label(), "Game data (private pack 9) + your corrections")


func test_loader_invalid_user_override_is_skipped() -> void:
	var base := FarmMap.load_file(WORLD)
	var raw: Dictionary = JsonUtil.read_json(WORLD)
	var res := WorldLoader.apply_user_overrides(base, raw, {"landmarks": {"house": {"footprint": [0, 0]}}})
	assert_null(res["map"], "nothing applied -> map unchanged")
	assert_has(" ".join(PackedStringArray(res["warnings"])), "invalid")
	res = WorldLoader.apply_user_overrides(base, raw, "garbage")
	assert_null(res["map"])
	assert_eq((res["warnings"] as Array).size(), 1)


func test_legacy_map_ids() -> void:
	assert_eq(WorldLoader.canonical_map_id("hayday_farm_h1"), "hayday_farm")
	assert_eq(WorldLoader.canonical_map_id(""), "hayday_farm")
	assert_eq(WorldLoader.canonical_map_id("custom"), "custom")
	assert_true(WorldLoader.is_legacy_map_id("hayday_farm_h1"))
	assert_eq(WorldLoader.V1_TO_GAME_SHIFT, Vector2i(-5, -3))
	assert_true("hayday_farm_h1" in WorldLoader.V1_MAP_IDS)
	assert_false(FileAccess.file_exists("res://data/maps/hayday_farm_h1.json"), "retired map not shipped")


func test_asset_library_lists_world_files() -> void:
	var base := TMP.path_join("builtin")
	_write_json(base.path_join("pack.json"), {"format": AssetLibrary.PACK_FORMAT, "id": AssetLibrary.BUILTIN_ID,
		"world": "world/world.json", "sprites": {}})
	_write_json(TMP.path_join("user/priv/pack.json"), {"format": AssetLibrary.PACK_FORMAT, "id": "priv", "version": "7",
		"priority": 5, "world": "world/world.json", "catalog_overrides": "catalog_overrides.json",
		"terrain": "../escape.json", "sprites": {}})
	_write_json(TMP.path_join("user/plain/pack.json"), {"format": AssetLibrary.PACK_FORMAT, "id": "plain", "sprites": {}})
	var lib := AssetLibrary.new()
	lib.builtin_pack_path = base.path_join("pack.json")
	lib.dev_packs_dir = TMP.path_join("no_dev")
	lib.user_packs_dir = TMP.path_join("user")
	lib.load_all()
	var files := lib.world_data_files()
	assert_eq(files.size(), 1, "only packs that declare world data; never the built-in pack")
	var e: Dictionary = files[0]
	assert_eq(e["pack_id"], "priv")
	assert_eq(e["version"], "7")
	assert_eq(e["priority"], 105)
	assert_eq(e["world"], TMP.path_join("user/priv/world/world.json"))
	assert_eq(e["catalog_overrides"], TMP.path_join("user/priv/catalog_overrides.json"))
	assert_eq(e["terrain"], "", "unsafe path dropped")


# --- placement ------------------------------------------------------------------------

func test_landmark_blocks_placement_in_every_mode() -> void:
	var db := world_db()
	var m := FarmMap.load_file(WORLD)
	for mode in [FarmLayout.MODE_CREATIVE, FarmLayout.MODE_REALISTIC]:
		var lay := FarmLayout.new()
		lay.mode = mode
		var r := PlacementRules.check_item(lay, m, db.get_item("t_lamp"), Vector2i(4, 4), false)
		assert_false(r.ok, mode)
		assert_eq(r.primary_reason(), PlacementRules.LANDMARK, mode)
		assert_eq(r.message(lay, db, m), "Fixed landmark: Test House", mode)
		r = PlacementRules.check_item(lay, m, db.get_item("t_lamp"), Vector2i(0, 6), false)
		assert_eq(r.primary_reason(), PlacementRules.LANDMARK, "in-grid block of an off-grid landmark (%s)" % mode)
		assert_true(PlacementRules.check_item(lay, m, db.get_item("t_lamp"), Vector2i(0, 7), false).ok, mode)
	# A footprint straddling the house and locked land lists both, landmark first.
	var lay2 := FarmLayout.new()
	var r2 := PlacementRules.check_rect(lay2, m, Rect2i(5, 0, 6, 4))
	assert_true(r2.reason_counts.has(PlacementRules.LANDMARK))
	assert_true(r2.reason_counts.has(PlacementRules.LOCKED_LAND))
	assert_true(r2.message(lay2, db, m).begins_with("Fixed landmark: Test House · Locked land"))
	assert_eq(r2.landmark_ids, {"house": true})


func _approx_vs_strong_map() -> FarmMap:
	var rows: Array = []
	for y in 10:
		rows.append([[1, 10]])
	return FarmMap.from_data({"format": FarmMap.FORMAT, "schema_version": 2, "frame": "game", "id": "c", "size": [10, 10],
		"regions": [], "ground": {"encoding": "rle-rows", "rows": rows}, "landmarks": [
			{"id": "guess", "origin": [1, 1], "footprint": [3, 3], "confidence": "approximate"},
			{"id": "known", "origin": [3, 3], "footprint": [2, 2], "confidence": "strong"}]})


func test_approximate_landmarks_do_not_block_placement() -> void:
	var m := _approx_vs_strong_map()
	assert_eq(m.landmark_id_at(Vector2i(1, 1)), "guess", "still located on the map")
	assert_eq(m.blocking_landmark_at(Vector2i(1, 1)), -1, "but it refuses nothing")
	assert_eq(m.blocking_landmark_at(Vector2i(4, 4)), m.landmark_index["known"])
	assert_eq(m.blocking_landmark_at(Vector2i(3, 3)), m.landmark_index["known"], "a real block wins an overlap")


func test_landmark_and_out_of_scope_items_not_placeable() -> void:
	var db := world_db()
	var m := FarmMap.load_file(WORLD)
	var lay := FarmLayout.new()
	var house := db.get_item("w_house")
	assert_false(house.can_place())
	var r := PlacementRules.check_item(lay, m, house, Vector2i(0, 10), false)
	assert_false(r.ok)
	assert_eq(r.primary_reason(), PlacementRules.NOT_PLACEABLE)
	assert_has(r.message(lay, db, m), "fixed landmark")
	var lake := db.get_item("w_lake")
	assert_false(lake.placeable, "out-of-scope items are never placeable (even if the record omits it)")
	assert_false(lake.can_place())
	r = PlacementRules.check_item(lay, m, lake, Vector2i(0, 10), false)
	assert_eq(r.primary_reason(), PlacementRules.NOT_PLACEABLE)
	assert_has(r.message(lay, db, m), "Fishing Lake")
	assert_true(PlacementRules.check_item(lay, m, db.get_item("w_rock"), Vector2i(0, 10), false).ok)


# --- items: landmark/scope flags, overrides, catalogue --------------------------------

func test_item_landmark_scope_and_obstacle_flags() -> void:
	var db := world_db()
	assert_eq(db.errors.size(), 0, str(db.errors))
	var h := db.get_item("w_house")
	assert_eq(h.landmark, "house")
	assert_true(h.is_landmark_duplicate())
	var c := db.get_item("w_combo")
	assert_eq(c.landmark, "sign", "first of several landmarks")
	assert_eq(c.landmarks, PackedStringArray(["sign", "dock"]))
	assert_eq(db.items_for_landmark("dock").size(), 1)
	assert_eq(db.landmark_items().size(), 2)
	assert_eq(db.get_item("w_lake").scope, "fishing_lake")
	assert_eq(db.get_item("w_rock").scope, ItemDef.SCOPE_MAIN_FARM)
	assert_false(db.get_item("w_stump").movable, "obstacles are removed, not moved")
	assert_true(db.get_item("w_rock").movable)
	var back := ItemDef.from_dict(c.to_dict(), [])
	assert_eq(back.landmarks, c.landmarks, "landmarks round trip")
	assert_eq(ItemDef.from_dict(db.get_item("w_lake").to_dict(), []).scope, "fishing_lake")
	var errs: Array = []
	ItemDef.from_dict({"id": "x", "landmark": "Bad Id", "scope": "Not Valid"}, errs)
	assert_eq(errs.size(), 2)


func test_search_hides_landmark_and_out_of_scope_items() -> void:
	var db := world_db()
	var ids := {}
	for it in db.search(""):
		ids[it.id] = true
	assert_false(ids.has("w_house"))
	assert_false(ids.has("w_combo"))
	assert_false(ids.has("w_lake"))
	assert_true(ids.has("w_rock"))
	assert_eq(db.search("lake hut").size(), 0)
	assert_eq(db.search("lake hut", {"include_hidden": true}).size(), 1)
	var all := db.search("", {"include_hidden": true})
	assert_eq(all.size(), db.count())
	assert_eq(db.search("", {"category": "production"}).size(), 2, "t_bakery + w_shed")


func test_level_state() -> void:
	var db := world_db()
	var shed := db.get_item("w_shed")
	assert_eq(shed.level_state(60), "unlocked")
	assert_eq(shed.level_state(39), "locked")
	assert_eq(shed.level_state(-1), "unlocked", "no level limit")
	assert_eq(db.get_item("w_rock").level_state(5), "unknown", "unknown unlock level is never guessed")


func test_catalog_overrides_parse() -> void:
	var errs: Array = []
	var ov := PackOverrides.parse_catalog_overrides(JsonUtil.read_json("res://tests/fixtures/catalog_overrides.json"), errs)
	var items: Dictionary = ov["items"]
	assert_false(items.has("t_long"), "invalid footprint dropped")
	assert_false(items.has("t_path"), "entry that changes nothing dropped")
	assert_true(items.has("w_shed"))
	assert_eq(items["t_mystery"]["footprint_status"], "game_data", "footprint without status -> game_data")
	assert_eq(items["t_bakery"]["unlock_level"], 5)
	assert_true(ov.has("candidates_need_confirmation"), "unknown top-level fields kept")
	assert_eq(errs.size(), 2, str(errs))
	errs.clear()
	PackOverrides.parse_catalog_overrides({"format": "nope"}, errs)
	assert_eq(errs.size(), 1)
	errs.clear()
	assert_eq((PackOverrides.parse_catalog_overrides(null, errs)["items"] as Dictionary).size(), 0)
	assert_eq(errs.size(), 0)


func test_catalog_overrides_apply_and_revert() -> void:
	var db := world_db()
	var raw: Variant = JsonUtil.read_json("res://tests/fixtures/catalog_overrides.json")
	var shed := db.get_item("w_shed")
	var mystery := db.get_item("t_mystery")
	var bakery := db.get_item("t_bakery")
	assert_eq(ItemDef.STATUS_ORDER.find("game_data"), ItemDef.STATUS_ORDER.find("confirmed") + 1, "trusted right after confirmed")
	var rep := db.apply_overrides(raw, "hayday_original")
	assert_eq(rep["unknown"], ["ghost_item"])
	assert_eq((rep["invalid"] as Array).size(), 1, str(rep["invalid"]))
	assert_eq(rep["applied"], 5, "w_shed, t_lamp, t_mystery, t_bakery, old_fence->t_fence")
	assert_ne(rep["hash"], "")
	assert_eq(shed.footprint, Vector2i(3, 2))
	assert_eq(shed.footprint_status, "game_data")
	assert_eq(shed.footprint_source, "hayday_original")
	assert_true(shed.is_footprint_trusted())
	assert_eq(ItemDef.status_label(shed.footprint_status), "From your game files (private pack)")
	assert_eq(mystery.footprint, Vector2i(3, 3))
	assert_eq(mystery.footprint_status, "game_data", "unknown size becomes game data")
	assert_eq(bakery.unlock_level, 5)
	assert_eq(bakery.footprint_status, "confirmed", "unlock-only change keeps the status")
	assert_eq(db.get_item("t_fence").footprint, Vector2i(1, 2), "aliases resolve")
	var swap: Dictionary = {}
	for c in rep["footprint_changed"]:
		if c["id"] == "w_shed":
			swap = c
	assert_true(swap.get("axis_swap", false), "axis swap detected")
	assert_eq(swap["old"], Vector2i(2, 3))
	assert_eq(db.overrides_pack, "hayday_original")
	# Applying again is idempotent (reverts first).
	var rep2 := db.apply_overrides(raw, "hayday_original")
	assert_eq(rep2["applied"], 5)
	assert_eq(shed.public_footprint, Vector2i(2, 3))
	# Revert restores the public values.
	assert_eq(db.revert_overrides(), 5)
	assert_eq(shed.footprint, Vector2i(2, 3))
	assert_eq(shed.footprint_status, "community")
	assert_eq(shed.footprint_source, "")
	assert_eq(mystery.footprint_status, "unknown")
	assert_eq(mystery.footprint, Vector2i(2, 2))
	assert_eq(bakery.unlock_level, 2)
	assert_eq(db.overrides_pack, "")
	var r3 := db.apply_overrides({"format": "other", "items": {}}, "x")
	assert_eq(r3["applied"], 0)
	assert_eq((r3["invalid"] as Array).size(), 1)
