extends TestCase
## WorldValidator: a world (world.json dictionary or FarmMap) against the
## client's level data and tables. Synthetic fixtures only
## (tests/fixtures/client_level, invented numbers, not game data).

const DIR := "res://tests/fixtures/client_level"


static func level() -> Dictionary:
	return ClientLevel.parse_level(JsonUtil.read_text(DIR.path_join("level_0.csv")))


static func table(name: String) -> Dictionary:
	return ClientLevel.read_table(JsonUtil.read_text(DIR.path_join(name + ".csv")))


static func world() -> Dictionary:
	return JsonUtil.read_json(DIR.path_join("world.json"))


static func opts() -> Dictionary:
	return {"expansions": table("expansions"), "tiles": table("tiles"),
		"tables": {"houses": table("houses"), "cars": table("cars"), "mines": table("mines")},
		"generated": "2026-01-02T00:00:00Z"}


static func run(w: Variant = null, o: Dictionary = {}) -> Dictionary:
	var op := opts()
	op.merge(o, true)
	return WorldValidator.validate(level(), world() if w == null else w, op)


func _st(rep: Dictionary, id: String) -> String:
	return str(WorldValidator.check(rep, id).get("status", "missing"))


func _lm(rep: Dictionary, so: String) -> Dictionary:
	for r: Dictionary in rep["landmarks"]:
		if r["special_object"] == so:
			return r
	return {}


# --- the matching world ---------------------------------------------------------------------

func test_matching_world_passes() -> void:
	var rep := run()
	assert_eq(rep["format"], WorldValidator.FORMAT)
	assert_eq(rep["version"], WorldValidator.VERSION)
	assert_eq(rep["game_version"], "0.0.1", "from the world's provenance")
	assert_eq(rep["generated"], "2026-01-02T00:00:00Z")
	assert_eq(rep["world"]["generated"], "2026-01-01T00:00:00Z")
	for c: Dictionary in rep["checks"]:
		assert_true(c["status"] in WorldValidator.STATUSES, c["id"])
		if c["id"] != "rendering_anchors":
			assert_eq(c["status"], "pass", "%s: %s" % [c["id"], str(c["examples"])])
	assert_eq(_st(rep, "rendering_anchors"), "warn", "rendering is never verified by data")
	assert_eq(rep["status"], "warn")
	var g := WorldValidator.check(rep, "ground")
	assert_eq(g["compared"], 48)
	assert_eq(g["mismatches"], 0)
	var e := WorldValidator.check(rep, "expansion_tiles")
	assert_eq(e["compared"], 16)
	assert_eq(e["mismatches"], 0)
	assert_eq(WorldValidator.check(rep, "plot_boundaries")["compared"], 3)
	assert_eq(WorldValidator.check(rep, "buildability")["compared"], 48)
	assert_eq(WorldValidator.check(rep, "buildability")["rule_source"], "client tile table")
	assert_eq(WorldValidator.check(rep, "landmarks_present")["compared"], 3)
	var io := WorldValidator.check(rep, "initial_objects")
	assert_eq(io["matched"], 3)
	assert_eq(io["name_differs"], 1, "display name at the client's place counts, does not fail")
	assert_has(WorldValidator.to_markdown(rep), "Expansion definitions not on the map")


func test_farm_map_input_gives_the_same_result() -> void:
	var m := FarmMap.from_data(world())
	assert_true(m.errors.is_empty(), str(m.errors))
	var rep := run(m)
	for id in ["map_size", "ground", "expansion_tiles", "plot_overlaps", "landmark_positions", "buildability", "initial_objects"]:
		assert_eq(_st(rep, id), "pass", id)
	assert_eq(_lm(rep, "Car")["delta_from_source"], [0, -1])


# --- truck / registration ---------------------------------------------------------------------

func test_truck_registration_is_evidence_backed_not_a_blanket_offset() -> void:
	## Regression: the client Car row is the truck's registration point; its 1x2
	## footprint starts one row above it, on the two non-passable road cells.
	var rule: Dictionary = WorldValidator.REGISTRATION["Car"]
	assert_eq(rule["rule"], WorldValidator.RULE_CENTERED)
	assert_true((rule["evidence"] as Array).size() >= 3)
	assert_eq(WorldValidator.expected_origin(WorldValidator.RULE_CENTERED, Vector2i(2, 2), Vector2i(1, 2)), Vector2i(2, 1))
	assert_eq(WorldValidator.expected_origin(WorldValidator.RULE_CENTERED, Vector2i(5, 5), Vector2i(3, 3)), Vector2i(4, 4))
	assert_eq(WorldValidator.expected_origin(WorldValidator.RULE_TOP_CORNER, Vector2i(2, 2), Vector2i(1, 2)), Vector2i(2, 2))
	var rep := run()
	var car := _lm(rep, "Car")
	assert_eq(car["landmark"], "truck")
	assert_eq(car["rule"], "centered")
	assert_eq(car["source"], [2, 2])
	assert_eq(car["expected_origin"], [2, 1])
	assert_eq(car["delta_from_source"], [0, -1])
	assert_eq(car["status"], "pass")
	var ev: Dictionary = car["evidence_check"]
	assert_true(ev["supports_rule"], str(ev))
	assert_eq(ev["blocked"], [[2, 1], [2, 2]])
	assert_eq(ev["in_top_corner_footprint"], 1)
	# A world that stores the truck at the plain source tile is one row off.
	var w := world()
	w["landmarks"][1]["origin"] = [2, 2]
	var bad := run(w)
	assert_eq(_st(bad, "landmark_positions"), "fail")
	assert_eq(_lm(bad, "Car")["shift"], [0, 1])
	# Without the Car rule (blanket top-corner) the correct world is flagged.
	var blanket := run(null, {"registration": {"_default": WorldValidator.REGISTRATION["_default"]}})
	assert_eq(_st(blanket, "landmark_positions"), "fail")
	# The rule is per object: other landmarks keep their source tile, and a
	# one-row shift of the house is caught.
	assert_eq(_lm(rep, "House")["delta_from_source"], [0, 0])
	var w2 := world()
	w2["landmarks"][0]["origin"] = [0, -1]
	assert_eq(_lm(run(w2), "House")["status"], "fail")


func test_truck_rule_warns_when_the_data_stops_supporting_it() -> void:
	## If the parking cells disappear from the TileMap the rule is no longer
	## backed by the data: the position still matches, but it is flagged.
	var text := JsonUtil.read_text(DIR.path_join("level_0.csv")).replace(",0,0,2,0,103", ",0,0,1,0,103")
	var lv := ClientLevel.parse_level(text)
	var rep := WorldValidator.validate(lv, world(), opts())
	var car := _lm(rep, "Car")
	assert_false(car["evidence_check"]["supports_rule"])
	assert_eq(car["status"], "warn")
	assert_eq(_st(rep, "landmark_positions"), "warn")


func test_rendering_anchor_offset_of_centre_anchored_sprites() -> void:
	var rep := run()
	var an := WorldValidator.check(rep, "rendering_anchors")
	assert_false(an["verified"])
	assert_eq(an["mismatches"], 1, "the centre-anchored truck sprite")
	assert_eq(an["examples"][0]["landmark"], "truck")
	# Footprint centre (2.5, 2) vs registration point (2, 2): half a tile along +x.
	assert_eq(an["examples"][0]["offset_world_px"], [16.0, 8.0])
	assert_eq(an["top_corner_sprites"], 2)


func test_landmarks_missing_extra_and_footprints() -> void:
	var w := world()
	w["landmarks"][2]["footprint"] = [3, 2]
	w["landmarks"].append({"id": "ghost", "name": "Ghost", "area": "farm_side", "origin": [0, 3], "footprint": [1, 1],
		"special_object": "Phantom", "confidence": "strong"})
	(w["landmarks"] as Array).remove_at(0)
	var rep := run(w)
	var pr := WorldValidator.check(rep, "landmarks_present")
	assert_eq(pr["missing"], 1)
	assert_eq(pr["extra"], 1)
	assert_eq(pr["status"], "fail")
	var fp := WorldValidator.check(rep, "landmark_footprints")
	assert_eq(fp["mismatches"], 1)
	assert_eq(fp["examples"][0]["client"], [2, 2])


# --- tiles and plots ----------------------------------------------------------------------------

func test_ground_and_expansion_mismatches() -> void:
	var w := world()
	w["ground"]["rows"][5] = [[4, 7], [0, 1]]
	w["regions"][4]["rects"] = [[4, 0, 2, 1]]           # east_01 loses a row
	w["regions"][5]["game_id"] = 3                       # east_02 has the wrong id
	var rep := run(w)
	var g := WorldValidator.check(rep, "ground")
	assert_eq(g["mismatches"], 1)
	assert_eq(g["examples"][0], {"tile": [7, 5], "client": 4, "world": 0})
	var e := WorldValidator.check(rep, "expansion_tiles")
	assert_eq(e["missing"], 2)
	assert_eq(e["different_id"], 4)
	assert_eq(e["status"], "fail")
	assert_eq(_st(rep, "plot_boundaries"), "fail", "stored tile count no longer matches")
	var d := WorldValidator.check(rep, "expansion_definitions")
	assert_eq(d["map_ids_without_world_plot"], [2])
	assert_eq(d["world_plots_not_on_map"], [3])


func test_overlapping_plots_duplicate_ids_and_bad_rects() -> void:
	var w := world()
	w["regions"][5]["rects"] = [[5, 0, 3, 2]]           # overlaps east_01 on x = 5
	w["regions"][6]["game_id"] = 1                       # duplicate game id
	w["regions"].append({"id": "east_04", "kind": "plot", "game_id": 9, "rects": [[7, 5, 2, 2]]})
	var rep := run(w)
	var ov := WorldValidator.check(rep, "plot_overlaps")
	assert_eq(ov["mismatches"], 2 + 1)
	assert_eq(ov["duplicate_game_ids"], 1)
	var pb := WorldValidator.check(rep, "plot_boundaries")
	assert_eq(pb["status"], "fail")
	var probs := (pb["examples"] as Array).map(func(x): return str(x["problem"]))
	assert_true(probs.any(func(p): return p.contains("outside")), str(probs))
	assert_true(WorldValidator.check(rep, "expansion_tiles")["outside_map"] > 0)


func test_disconnected_plot_only_warns() -> void:
	var w := world()
	w["regions"][6]["rects"] = [[4, 2, 1, 2], [6, 2, 2, 2]]
	w["regions"][6]["tiles"] = 6
	w["regions"].insert(4, {"id": "gap", "kind": "buildable", "rects": [[5, 2, 1, 2]]})
	var pb := WorldValidator.check(run(w), "plot_boundaries")
	assert_eq(pb["status"], "warn")
	assert_eq(pb["disconnected"], 1)


func test_buildability_follows_the_tile_table() -> void:
	var w := world()
	(w["regions"] as Array).remove_at(1)                 # the lane (road) is gone: buildable over road ground
	var b := WorldValidator.check(run(w), "buildability")
	assert_eq(b["mismatches"], 4)
	assert_eq(b["status"], "fail")
	# Without a client tile table the world's own tile types are used, which only warns.
	var b2 := WorldValidator.check(run(null, {"tiles": {}}), "buildability")
	assert_eq(b2["rule_source"], "world tile_types (no client tile table given)")
	assert_eq(b2["status"], "warn")


func test_absent_expansion_definitions_are_explained() -> void:
	var rep := run()
	var d := WorldValidator.check(rep, "expansion_definitions")
	assert_eq(d["definitions"], 5)
	assert_eq(d["on_map"], 3)
	assert_eq(d["status"], "pass", "absent definitions are not world errors")
	var absent: Array = rep["expansion_definitions_not_on_map"]
	assert_eq(absent.map(func(x): return x["id"]), [3, 5])
	assert_eq(absent[0]["kind"], "placeholder")
	assert_eq(absent[0]["costs"], {"Spade": 1000, "Rake": 1000})
	var r0 := "; ".join(PackedStringArray(absent[0]["reasons"]))
	assert_has(r0, "placeholder cost")
	assert_has(r0, "numbering gap: ids 2 and 4")
	assert_eq(absent[1]["kind"], "unused")
	assert_has("; ".join(PackedStringArray(absent[1]["reasons"])), "equal to a neighbouring definition")
	# Found in another level file: reported as such (it may use its own table).
	var other := ClientLevel.parse_level("TileMap,,\n,t,t\n,int,int\n,500,0\n")
	var rep2 := run(null, {"other_levels": {"lake_0": other}})
	var a5: Dictionary = rep2["expansion_definitions_not_on_map"][1]
	assert_eq(a5["kind"], "other_level")
	assert_eq(a5["other_levels"], ["lake_0"])


func test_map_size_and_initial_object_problems() -> void:
	var w := world()
	w["size"] = [9, 6]
	w["initial_objects"].append({"item": "t_lamp", "x": 3, "y": 3, "flip": false, "game_name": "Wheat", "source_group": "Objects"})
	w["initial_objects"][1]["flip"] = false
	var rep := run(w)
	assert_eq(_st(rep, "map_size"), "fail")
	var io := WorldValidator.check(rep, "initial_objects")
	assert_eq(io["mismatches"], 2, "an invented object and a wrong mirroring")
	assert_eq(io["status"], "fail")
	assert_eq(rep["status"], "fail")


# --- item footprints ------------------------------------------------------------------------

func test_footprints_after_pack_overrides() -> void:
	var tables := {"decos": table("decos")}
	var sprites := {"t_bakery": {"source": {"kind": "apk", "sc": "b", "export": "bakery_art"}},
		"t_long": {"source": {"kind": "apk", "sc": "b", "export": "long_art"}},
		"t_lamp": {"source": {"kind": "apk", "sc": "b", "export": "lamp_art"}},
		"t_path": {"source": {"kind": "apk", "sc": "b", "export": "twin_art"}},
		"t_fence": {"source": {"kind": "wiki_en", "title": "File:Fence.png"}}}
	var overrides := {"format": PackOverrides.CATALOG_FORMAT, "version": 1, "items": {
		"t_lamp": {"footprint": [2, 1], "footprint_status": "game_data", "change": "resize",
			"evidence": "assets/data/decos.csv line 5 Name=Lamp TileWidth=2 TileHeight=1 (synthetic)"}}}
	# Public catalogue: the lamp differs, the long item has its axes swapped.
	var pub := WorldValidator.compare_footprints(fixture_db(), tables, overrides, sprites)
	var f0: Dictionary = pub["item_footprints"]
	assert_eq(f0["compared"], 3, "bakery, long, lamp (the twin export is ambiguous)")
	assert_eq(f0["matched"], 1)
	assert_eq(f0["axis_swapped"], 1)
	assert_eq(f0["mismatches"], 1)
	assert_eq(f0["ambiguous_links"], 1)
	assert_eq(f0["status"], "fail")
	assert_eq(pub["footprint_corrections"]["mismatches"], 1, "the correction is not applied to a public catalogue")
	# With the pack's corrections applied, as the app does.
	var db := fixture_db()
	db.apply_overrides(PackOverrides.parse_catalog_overrides(overrides), "synthetic")
	var res := WorldValidator.compare_footprints(db, tables, overrides, sprites)
	var f1: Dictionary = res["item_footprints"]
	assert_eq(f1["mismatches"], 0)
	assert_eq(f1["linked_by"], {"override": 1, "export": 2})
	assert_eq(f1["status"], "warn", "an axis swap remains (same tiles)")
	var cc: Dictionary = res["footprint_corrections"]
	assert_eq(cc["present"], 1)
	assert_eq(cc["agree_with_client_tables"], 1)
	assert_eq(cc["status"], "pass")
	# Merged into the world report.
	var rep := run(null, {"footprints": res})
	assert_eq(_st(rep, "footprint_corrections"), "pass")
	assert_eq(_st(rep, "item_footprints"), "warn")
