extends TestCase

var db: ItemDatabase
var tmp_dir := "user://test_tmp"


func before_each() -> void:
	db = fixture_db()
	DirAccess.make_dir_recursive_absolute(tmp_dir)


func after_each() -> void:
	var d := DirAccess.open(tmp_dir)
	if d:
		for f in d.get_files():
			d.remove(f)


func _sample() -> FarmLayout:
	var l := FarmLayout.new()
	l.id = "abc"
	l.name = "Sample"
	l.mode = FarmLayout.MODE_REALISTIC
	l.set_unlocked(["plot_a"])
	var a := make_obj(db.get_item("t_bakery"), Vector2i(1, 1))
	var b := make_obj(db.get_item("t_long"), Vector2i(6, 1), true)
	b.planned = true
	b.note = "later"
	b.group_id = 3
	l.add_objects([a, b])
	l.annotations.append({"id": 1, "kind": "label", "rect": [0, 0, 2, 2], "text": "Garden"})
	l.profile["level"] = 25
	l.profile["owned"] = {"t_bakery": 1}
	return l


func test_roundtrip_preserves_positions_and_props() -> void:
	var l := _sample()
	var d := LayoutIO.to_dict(l)
	var rep := LayoutIO.LoadReport.new()
	var back := LayoutIO.from_dict(JsonUtil.parse(JsonUtil.stringify(d)), db, rep)
	assert_true(rep.ok, rep.error)
	assert_eq(back.name, "Sample")
	assert_eq(back.mode, FarmLayout.MODE_REALISTIC)
	assert_eq(back.count(), 2)
	assert_true(back.unlocked_plots.has("plot_a"))
	var hedge: PlacedObject = null
	for o: PlacedObject in back.objects.values():
		if o.item_id == "t_long":
			hedge = o
	assert_eq(hedge.origin, Vector2i(6, 1))
	assert_eq(hedge.size, Vector2i(4, 1))
	assert_true(hedge.flipped)
	assert_true(hedge.planned)
	assert_eq(hedge.note, "later")
	assert_eq(hedge.group_id, 3)
	assert_eq(int(back.profile["level"]), 25)
	assert_eq(back.annotations[0]["text"], "Garden")
	assert_eq(back.object_at(Vector2i(9, 1)).uid, hedge.uid, "occupancy rebuilt")


func test_file_save_and_load_atomic() -> void:
	var path := tmp_dir.path_join("farm" + LayoutIO.FILE_EXT)
	assert_eq(LayoutIO.save_file(_sample(), path), OK)
	assert_false(FileAccess.file_exists(path + ".tmp"), "temp file renamed away")
	# Second save keeps a backup of the first.
	assert_eq(LayoutIO.save_file(_sample(), path), OK)
	assert_true(FileAccess.file_exists(path + ".bak"))
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.load_file(path, db, rep)
	assert_not_null(l)
	assert_eq(l.count(), 2)


func test_recovers_from_corrupted_main_file() -> void:
	var path := tmp_dir.path_join("broken" + LayoutIO.FILE_EXT)
	LayoutIO.save_file(_sample(), path)
	LayoutIO.save_file(_sample(), path)   # creates .bak
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{\"format\": \"hayday-sand")  # truncated write
	f.close()
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.load_file(path, db, rep)
	assert_not_null(l, "loaded from backup")
	assert_has(rep.recovered_from, ".bak")


func test_missing_items_survive_roundtrip() -> void:
	var d := LayoutIO.to_dict(_sample())
	d["objects"].append({"uid": 99, "item": "retired_statue", "x": 3, "y": 8, "w": 2, "h": 2, "future_field": 7})
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(d, db, rep)
	assert_eq(rep.missing_items.get("retired_statue", 0), 1)
	var o := l.get_obj(99)
	assert_true(o.missing)
	assert_eq(o.size, Vector2i(2, 2), "saved footprint kept")
	assert_not_null(l.object_at(Vector2i(4, 9)), "still blocks its tiles")
	var again := LayoutIO.to_dict(l)
	var found := false
	for rec in again["objects"]:
		if rec["item"] == "retired_statue":
			found = true
			assert_eq(rec["future_field"], 7, "unknown fields preserved")
	assert_true(found)


func test_renamed_and_resized_items() -> void:
	var d := LayoutIO.to_dict(_sample())
	d["objects"].append({"uid": 50, "item": "old_fence", "x": 0, "y": 9, "w": 1, "h": 1})
	d["objects"].append({"uid": 51, "item": "t_lamp", "x": 2, "y": 9, "w": 2, "h": 2})
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(d, db, rep)
	assert_eq(l.get_obj(50).item_id, "t_fence")
	assert_eq(rep.renamed.get("old_fence"), "t_fence")
	assert_eq(l.get_obj(51).size, Vector2i(1, 1), "current metadata wins")
	assert_has(rep.footprint_changed, 51)


func test_rejects_newer_and_foreign_files() -> void:
	var rep := LayoutIO.LoadReport.new()
	assert_null(LayoutIO.from_dict({"format": LayoutIO.FORMAT, "schema_version": 999}, db, rep))
	assert_false(rep.ok)
	rep = LayoutIO.LoadReport.new()
	assert_null(LayoutIO.from_dict({"format": "something-else", "schema_version": 1}, db, rep))
	assert_false(rep.ok)


func test_migrates_v0_prototype_format() -> void:
	var v0 := {"version": 0, "name": "Old farm", "land": ["plot_a"],
		"items": [{"id": "t_bakery", "pos": [2, 3], "size": [3, 3]}, {"id": "t_long", "pos": [7, 0], "size": [4, 1], "mirrored": true}]}
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(v0, db, rep)
	assert_not_null(l)
	assert_eq(rep.migrated_from, 0)
	assert_eq(l.name, "Old farm")
	assert_eq(l.count(), 2)
	assert_true(l.unlocked_plots.has("plot_a"))
	# v0 used the v1 frame of map "hayday_farm": 0 -> 1 -> 2 shifts by (-5, -3).
	assert_eq(rep.shifted, Vector2i(-5, -3))
	assert_not_null(l.object_at(Vector2i(5, -3)), "4x1 hedge (v1 x 7..10, y 0) now at x 2..5, y -3")
	assert_eq(l.loaded_schema, 0)


func test_malformed_records_skipped_not_fatal() -> void:
	var d := LayoutIO.to_dict(_sample())
	d["objects"].append("garbage")
	d["objects"].append({"no_item": true})
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(d, db, rep)
	assert_eq(l.count(), 2)
	assert_eq(rep.dropped, 2)


func test_duplicate_uids_are_repaired() -> void:
	var d := LayoutIO.to_dict(_sample())
	d["objects"][1]["uid"] = d["objects"][0]["uid"]
	var l := LayoutIO.from_dict(d, db)
	assert_eq(l.count(), 2)


# --- schema v2: world frame, landmarks, migration (synthetic fixtures only) -------------

## Synthetic stand-ins for the real catalogue ids the v1 starter template used.
const FARM_ITEMS := [
	{"id": "farmhouse", "name": "Farmhouse", "category": "production", "footprint": [4, 4], "footprint_status": "community", "landmark": "farmhouse"},
	{"id": "truck_and_order_board", "name": "Truck and order board", "category": "production", "footprint": [4, 3], "footprint_status": "community", "landmarks": ["truck", "order_board"]},
	{"id": "roadside_shop", "name": "Roadside Shop", "category": "production", "footprint": [3, 3], "footprint_status": "community", "landmark": "roadside_shop"},
	{"id": "mailbox", "name": "Mailbox", "category": "decoration", "footprint": [1, 1], "footprint_status": "community", "landmark": "newspaper_mailbox"},
	{"id": "barn", "name": "Barn", "category": "production", "footprint": [4, 4], "footprint_status": "community"},
	{"id": "silo", "name": "Silo", "category": "production", "footprint": [3, 3], "footprint_status": "community"},
]


static func world_db() -> ItemDatabase:
	## Fixture items + synthetic world items (landmark duplicates, an obstacle,
	## a Fishing Lake item) + synthetic farm items named like the real ones.
	var wdb := ItemDatabase.new()
	wdb.load_categories("res://tests/fixtures/categories.json")
	wdb.load_file("res://tests/fixtures/items.json")
	wdb.load_file("res://tests/fixtures/world_items.json")
	var errs: Array = []
	for rec in FARM_ITEMS:
		wdb.add_item(ItemDef.from_dict(rec, errs))
	wdb.finalize()
	return wdb


static func world_map() -> FarmMap:
	## Synthetic v2 world (made-up geometry) with the same map id as the public
	## map so migrated layouts are checked against it.
	return FarmMap.from_data({"format": "hayday-sandbox-map", "schema_version": 2, "id": "hayday_farm",
		"frame": "game", "size": [40, 30],
		"regions": [
			{"id": "start", "kind": "buildable", "rects": [[0, 0, 30, 24]]},
			{"id": "road", "kind": "road", "rects": [[0, 24, 40, 4]]},
			{"id": "plot_e", "kind": "plot", "rects": [[30, 0, 10, 24]]},
		],
		"landmarks": [
			{"id": "farmhouse", "name": "Farmhouse", "origin": [12, 10], "footprint": [4, 4], "replaces_items": ["farmhouse"], "confidence": "approximate"},
			{"id": "truck", "name": "Truck", "origin": [16, 21], "footprint": [1, 2], "replaces_items": ["truck_and_order_board"], "confidence": "approximate"},
			{"id": "order_board", "name": "Order Board", "origin": [13, 21], "footprint": [2, 2], "replaces_items": ["truck_and_order_board"], "confidence": "approximate"},
			{"id": "roadside_shop", "name": "Roadside Shop", "origin": [19, 20], "footprint": [3, 3], "replaces_items": ["roadside_shop"], "confidence": "approximate"},
			{"id": "newspaper_mailbox", "name": "Mailbox", "origin": [18, 10], "footprint": [1, 1], "replaces_items": ["mailbox"], "confidence": "approximate"},
			{"id": "well", "name": "Old Well", "origin": [24, 4], "footprint": [2, 2], "confidence": "strong"},
		]})


static func v1_fixture() -> Dictionary:
	## A layout as the v1 app saved it (app tile frame = game + (5, 3)).
	var note := LayoutIO.V1_STARTER_NOTE
	return {"format": LayoutIO.FORMAT, "schema_version": 1, "app_version": "0.1.0",
		"meta": {"id": "v1farm", "name": "Old farm", "mode": "creative"},
		"map": {"id": "hayday_farm", "unlocked_plots": ["plot_e"]},
		"next_uid": 20, "next_group": 1,
		"objects": [
			{"uid": 1, "item": "farmhouse", "x": 19, "y": 15, "w": 4, "h": 4, "locked": true, "note": note},
			{"uid": 2, "item": "truck_and_order_board", "x": 18, "y": 31, "w": 4, "h": 3, "locked": true, "note": note},
			{"uid": 3, "item": "roadside_shop", "x": 24, "y": 31, "w": 3, "h": 3, "locked": true, "note": note, "variant": "v"},
			{"uid": 4, "item": "mailbox", "x": 23, "y": 15, "w": 1, "h": 1, "locked": true, "note": note},
			{"uid": 5, "item": "barn", "x": 9, "y": 7, "w": 4, "h": 4, "locked": true, "note": note},
			{"uid": 6, "item": "silo", "x": 14, "y": 7, "w": 3, "h": 3, "locked": true, "note": note},
			{"uid": 7, "item": "t_bakery", "x": 6, "y": 15, "w": 3, "h": 3, "locked": true, "note": "my bakery"},
			{"uid": 8, "item": "t_lamp", "x": 29, "y": 7, "w": 1, "h": 1},      # -> (24, 4): on the synthetic well landmark
			{"uid": 9, "item": "t_fence", "x": 8, "y": 28, "w": 1, "h": 1},     # -> (3, 25): on the road
			{"uid": 10, "item": "t_long", "x": 37, "y": 5, "w": 4, "h": 1, "flip": true, "group": 1, "future": {"k": 1}},
		],
		"groups": {"1": {"name": "Hedges"}},
		"annotations": [{"id": 1, "kind": "zone", "rect": [10, 10, 4, 2], "text": "Garden", "color": "#fff"}],
		"profile": {"level": 33},
		"reference": {"file": "user://ref.png", "x": 10.0, "y": 20.0, "scale": 1.0},
		"camera": {"x": 100.0, "y": 50.0, "zoom": 1.5},
		"plugin_data": {"keep": true}}


func test_v1_migration_full_fixture() -> void:
	var wdb := world_db()
	var map := world_map()
	var src := v1_fixture()
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(src, wdb, rep, map)
	assert_not_null(l)
	assert_eq(rep.migrated_from, 1)
	assert_eq(rep.shifted, Vector2i(-5, -3))
	assert_eq(l.map_id, "hayday_farm")
	assert_eq(l.loaded_schema, 1)
	# b) landmark duplicates leave `objects`, kept verbatim with a reason.
	assert_eq(l.count(), 6, "farmhouse, truck+board, shop and mailbox were taken out")
	for o: PlacedObject in l.objects.values():
		assert_true(wdb.get_item(o.item_id) == null or wdb.get_item(o.item_id).landmark.is_empty(), "%s is not a landmark copy" % o.item_id)
	var ml: Array = l.migration.get("migrated_landmarks", [])
	assert_eq(ml.size(), 4)
	assert_eq(rep.migrated_landmarks.size(), 4)
	var by_item := {}
	for e: Dictionary in ml:
		by_item[e["record"]["item"]] = e
		assert_false(str(e["reason"]).is_empty(), "every migrated landmark has a reason")
	assert_eq(by_item["farmhouse"]["landmark"], "farmhouse")
	assert_eq(by_item["truck_and_order_board"]["landmark"], "truck")
	assert_eq(by_item["mailbox"]["landmark"], "newspaper_mailbox")
	assert_eq(by_item["farmhouse"]["record"], src["objects"][0], "original v1 record kept verbatim (v1 coordinates)")
	assert_eq(by_item["roadside_shop"]["record"]["variant"], "v")
	# a) frame shift of objects, annotations, camera and reference.
	assert_eq(l.get_obj(5).origin, Vector2i(4, 4), "barn keeps its place in the new frame")
	assert_eq(l.get_obj(10).origin, Vector2i(32, 2))
	assert_eq(l.get_obj(10).extra.get("future"), {"k": 1}, "unknown object fields preserved")
	assert_eq(l.annotations[0]["rect"], [5, 7, 4, 2])
	assert_almost(float(l.camera["x"]), 36.0)
	assert_almost(float(l.camera["y"]), -78.0)
	assert_almost(float(l.reference["images"][0]["x"]), -54.0)
	assert_almost(float(l.reference["images"][0]["y"]), -108.0)
	# d) starter auto-locks cleared on movable buildings only; user locks kept.
	assert_false(l.get_obj(5).locked, "barn starter lock cleared")
	assert_eq(l.get_obj(5).note, "")
	assert_false(l.get_obj(6).locked, "silo starter lock cleared")
	assert_true(l.get_obj(7).locked, "user lock preserved")
	assert_eq(l.get_obj(7).note, "my bakery")
	assert_eq(rep.starter_unlocked, 2)
	# c) collisions reported, never deleted.
	var coll := {}
	for c: Dictionary in rep.collisions:
		coll[int(c["uid"])] = str(c["reason"])
	assert_true(coll.has(8) and coll[8].contains("Old Well"), "lamp on the well landmark reported: %s" % str(coll))
	assert_true(coll.has(9) and coll[9].contains("road"), "fence on the road reported")
	assert_not_null(l.get_obj(8), "colliding objects are kept")
	assert_eq(int(l.profile["level"]), 33)
	assert_eq(l.extra.get("plugin_data"), {"keep": true}, "unknown top-level keys preserved")
	var mig := l.migration
	assert_eq(int(mig["from"]), 1)
	assert_eq(mig["shifted_by"], [-5, -3])
	assert_eq(mig["from_map"], "hayday_farm")
	var sm := rep.summary()
	assert_has(sm, "upgraded from format v1")
	assert_has(sm, "4 fixed landmarks")
	assert_has(sm, "overlap fixed landmarks")


func test_v2_roundtrip_keeps_migration_world_and_unknown_keys() -> void:
	var wdb := world_db()
	var map := world_map()
	var l := LayoutIO.from_dict(v1_fixture(), wdb, null, map)
	l.set_world_value("theme", "", "winter")
	l.set_world_value("landmark_skins", "farmhouse", "blue")
	l.set_world_value("landmark_visible", "truck", false)
	var d := LayoutIO.to_dict(l)
	assert_eq(int(d["schema_version"]), LayoutIO.SCHEMA_VERSION)
	assert_eq(d["world"]["theme"], "winter")
	for rec in d["objects"]:
		assert_false((rec as Dictionary).has("_review"), "internal migration marker never saved")
	var rep := LayoutIO.LoadReport.new()
	var back := LayoutIO.from_dict(JsonUtil.parse(JsonUtil.stringify(d)), wdb, rep, map)
	assert_eq(rep.migrated_from, -1, "a current file is not migrated again")
	assert_eq(rep.shifted, Vector2i.ZERO)
	assert_eq(rep.migrated_landmarks.size(), 0, "old migration entries are not reported again")
	assert_eq(back.get_obj(5).origin, Vector2i(4, 4), "no second shift")
	assert_eq((back.migration["migrated_landmarks"] as Array).size(), 4, "migration record round-trips")
	assert_eq(back.theme(), "winter")
	assert_eq(back.landmark_skin("farmhouse"), "blue")
	assert_false(back.is_landmark_visible("truck"))
	assert_true(back.is_landmark_visible("farmhouse"), "absent = default")
	assert_eq(back.extra.get("plugin_data"), {"keep": true})
	assert_eq(JsonUtil.stringify(LayoutIO.to_dict(back)["world"]), JsonUtil.stringify(d["world"]))


func test_world_state_normalisation() -> void:
	var w := FarmLayout.normalize_world_state({"theme": "", "landmark_states": {"a": "x", "b": 3},
		"landmark_visible": {"a": true, "b": "yes"}, "landmark_skins": "bad", "future": [1]})
	assert_eq(w["theme"], FarmLayout.DEFAULT_THEME)
	assert_eq(w["landmark_states"], {"a": "x"}, "non-string states dropped")
	assert_eq(w["landmark_visible"], {"a": true}, "non-bool visibility dropped")
	assert_eq(w["landmark_skins"], {})
	assert_eq(w["future"], [1], "unknown world keys kept")
	assert_eq(FarmLayout.normalize_world_state(null), FarmLayout.default_world_state())


func test_h1_layouts_migrate_and_flag_review() -> void:
	var wdb := world_db()
	var d := {"format": LayoutIO.FORMAT, "schema_version": 1, "map": {"id": "hayday_farm_h1"},
		"objects": [
			{"uid": 3, "item": "t_lamp", "x": 30, "y": 10, "w": 1, "h": 1},
			{"uid": 4, "item": "t_lamp", "x": 60, "y": 10, "w": 1, "h": 1},
			{"uid": 4, "item": "t_lamp", "x": 70, "y": 12, "w": 1, "h": 1},   # duplicate uid: reassigned, still flagged
		]}
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(d, wdb, rep)
	assert_eq(l.map_id, "hayday_farm", "retired h1 map id migrates to hayday_farm")
	assert_eq(rep.source_map, "hayday_farm_h1")
	assert_eq(l.count(), 3)
	assert_eq(rep.review_uids.size(), 2, "objects at v1 x >= 53 flagged")
	var flagged := {}
	for u in rep.review_uids:
		flagged[l.get_obj(u).origin] = true
	assert_true(flagged.has(Vector2i(55, 7)) and flagged.has(Vector2i(65, 9)), "flagged uids point at the right objects")
	assert_eq(l.migration["review_uids"], rep.review_uids)
	assert_eq(l.get_obj(3).origin, Vector2i(25, 7))
	for o: PlacedObject in l.objects.values():
		assert_false(o.extra.has("_review"), "marker not kept on the object")
	assert_has(rep.summary(), "to check")


func test_unknown_v1_map_is_not_shifted() -> void:
	var d := {"format": LayoutIO.FORMAT, "schema_version": 1, "map": {"id": "my_island"},
		"objects": [{"uid": 1, "item": "t_lamp", "x": 2, "y": 2, "w": 1, "h": 1}]}
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(d, db, rep)
	assert_eq(l.map_id, "my_island")
	assert_eq(rep.shifted, Vector2i.ZERO)
	assert_eq(l.get_obj(1).origin, Vector2i(2, 2))
	assert_eq(l.migration["shifted_by"], [0, 0])


func test_v1_reference_affine_and_pure_migrate() -> void:
	var d := {"format": LayoutIO.FORMAT, "schema_version": 1, "map": {"id": "hayday_farm"},
		"reference": {"affine": [1.0, 0.0, 0.0, 1.0, 10.0, 20.0]}, "objects": [
			{"uid": 1, "item": "farmhouse", "x": 19, "y": 15, "w": 4, "h": 4}]}
	# Pure migrate without db/map: frame shift only (no landmark knowledge).
	var m := LayoutIO.migrate(d.duplicate(true), 1)
	assert_eq(int(m["schema_version"]), LayoutIO.SCHEMA_VERSION)
	assert_eq(m["objects"][0]["x"], 14)
	assert_eq(m["reference"]["images"][0]["affine"], [1.0, 0.0, 0.0, 1.0, -54.0, -108.0])
	assert_eq(m["world"], FarmLayout.default_world_state())
	assert_eq((m["migration"]["migrated_landmarks"] as Array).size(), 0)
	# from_dict with a db still takes the landmark copy out.
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(d, world_db(), rep)
	assert_eq(l.count(), 0)
	assert_eq(rep.migrated_landmarks.size(), 1)
	assert_eq(rep.migrated_landmarks[0]["name"], "Farmhouse")


func test_v2_import_takes_landmark_items_out() -> void:
	## Same path for every import (file, template, paste-from-file): a v2 file
	## that contains a landmark copy never puts it into layout.objects.
	var wdb := world_db()
	var d := LayoutIO.to_dict(FarmLayout.new())
	d["objects"] = [{"uid": 1, "item": "farmhouse", "x": 1, "y": 1, "w": 4, "h": 4},
		{"uid": 2, "item": "w_house", "x": 8, "y": 1, "w": 3, "h": 3},
		{"uid": 3, "item": "t_lamp", "x": 0, "y": 0, "w": 1, "h": 1}]
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(d, wdb, rep, world_map())
	assert_eq(rep.migrated_from, -1)
	assert_eq(l.count(), 1)
	assert_eq(l.objects.values()[0].item_id, "t_lamp")
	assert_eq(rep.migrated_landmarks.size(), 2)
	assert_eq((l.migration["migrated_landmarks"] as Array).size(), 2, "kept in the file, never silently dropped")
	var path := tmp_dir.path_join("import" + LayoutIO.FILE_EXT)
	JsonUtil.write_atomic(path, JsonUtil.stringify(d), false)
	var rep2 := LayoutIO.LoadReport.new()
	var l2 := LayoutIO.load_file(path, wdb, rep2)
	assert_eq(l2.count(), 1, "file import path behaves the same")


func test_catalog_override_footprints_reconcile() -> void:
	var wdb := world_db()
	var l := FarmLayout.new()
	var shed := make_obj(wdb.get_item("w_shed"), Vector2i(2, 2))         # 2x3 flippable
	var bakery := make_obj(wdb.get_item("t_bakery"), Vector2i(8, 2))     # 3x3
	l.add_objects([shed, bakery])
	var d := LayoutIO.to_dict(l)
	var rep_ov := wdb.apply_overrides({"format": ItemDatabase.OVERRIDES_FORMAT, "version": 1, "items": {
		"w_shed": {"footprint": [3, 2], "change": "axis_swap"},
		"t_bakery": {"footprint": [4, 4], "change": "resize"}}}, "test_pack")
	assert_eq(int(rep_ov["applied"]), 2)
	wdb.overrides_report["pack_version"] = "9.9"
	var rep := LayoutIO.LoadReport.new()
	var back := LayoutIO.from_dict(d, wdb, rep)
	var s2 := back.get_obj(shed.uid)
	assert_eq(s2.origin, Vector2i(2, 2), "origin (top corner) kept")
	assert_eq(s2.size, Vector2i(2, 3), "axis-only change keeps the same tiles…")
	assert_true(s2.flipped, "…by toggling flipped")
	var b2 := back.get_obj(bakery.uid)
	assert_eq(b2.origin, Vector2i(8, 2))
	assert_eq(b2.size, Vector2i(4, 4), "a real resize takes the new size")
	assert_eq(rep.footprint_changes.size(), 2)
	var by_uid := {}
	for c: Dictionary in rep.footprint_changes:
		by_uid[int(c["uid"])] = c
	assert_eq(by_uid[shed.uid]["old"], Vector2i(2, 3))
	assert_eq(by_uid[shed.uid]["new"], Vector2i(2, 3))
	assert_true(by_uid[shed.uid]["flipped_toggled"])
	assert_eq(by_uid[bakery.uid]["old"], Vector2i(3, 3))
	assert_eq(by_uid[bakery.uid]["new"], Vector2i(4, 4))
	assert_has(rep.footprint_changed, bakery.uid)
	assert_has(rep.summary(), "turned to match corrected footprints")
	assert_eq(back.footprint_source["pack"], "test_pack")
	assert_eq(back.footprint_source["pack_version"], "9.9")
	# Round trip with the same catalogue: nothing changes, source kept.
	var rep2 := LayoutIO.LoadReport.new()
	var again := LayoutIO.from_dict(LayoutIO.to_dict(back), wdb, rep2)
	assert_eq(rep2.footprint_changes.size(), 0)
	assert_eq(again.footprint_source, back.footprint_source, "footprint_source round-trips")
	# Pack gone: public sizes come back, with a note.
	wdb.revert_overrides()
	var rep3 := LayoutIO.LoadReport.new()
	var pub := LayoutIO.from_dict(LayoutIO.to_dict(back), wdb, rep3)
	assert_eq(pub.get_obj(shed.uid).size, Vector2i(2, 3))
	assert_false(pub.get_obj(shed.uid).flipped, "flip toggled back")
	assert_eq(pub.get_obj(bakery.uid).size, Vector2i(3, 3))
	assert_eq(pub.footprint_source, {})
	assert_true(Array(rep3.warnings).any(func(w): return str(w).contains("test_pack")), "pack change noted")


func test_first_save_over_v1_file_keeps_backup() -> void:
	var wdb := world_db()
	var path := tmp_dir.path_join("old" + LayoutIO.FILE_EXT)
	var original := JsonUtil.stringify(v1_fixture(), true)
	JsonUtil.write_atomic(path, original, false)
	assert_eq(LayoutIO.file_schema_version(path), 1)
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.load_file(path, wdb, rep, world_map())
	assert_not_null(l)
	var bk := LayoutIO.backup_path_for(path, 1)
	assert_true(bk.ends_with(".hdlayout.v1-backup"))
	assert_false(FileAccess.file_exists(bk), "loading alone writes nothing")
	assert_eq(LayoutIO.save_file(l, path), OK)
	assert_true(FileAccess.file_exists(bk), "first save keeps the original")
	assert_eq(JsonUtil.read_text(bk), original, "backup holds the original bytes")
	assert_eq(LayoutIO.file_schema_version(path), LayoutIO.SCHEMA_VERSION)
	assert_eq(l.loaded_schema, LayoutIO.SCHEMA_VERSION)
	# Later saves never touch the backup.
	l.name = "Changed"
	assert_eq(LayoutIO.save_file(l, path), OK)
	assert_eq(JsonUtil.read_text(bk), original)
	# Saving a v2 layout over a v2 file makes no backup.
	var p2 := tmp_dir.path_join("new" + LayoutIO.FILE_EXT)
	assert_eq(LayoutIO.save_file(_sample(), p2), OK)
	assert_eq(LayoutIO.save_file(_sample(), p2), OK)
	assert_false(FileAccess.file_exists(LayoutIO.backup_path_for(p2, 1)))
	assert_eq(LayoutIO.file_schema_version(tmp_dir.path_join("missing.hdlayout")), -1)
	for f in [bk]:
		DirAccess.remove_absolute(f)


func test_v0_file_backup_name() -> void:
	var path := tmp_dir.path_join("proto" + LayoutIO.FILE_EXT)
	JsonUtil.write_atomic(path, JsonUtil.stringify({"version": 0, "name": "P", "items": []}), false)
	assert_eq(LayoutIO.file_schema_version(path), 0)
	var l := LayoutIO.load_file(path, db, LayoutIO.LoadReport.new())
	assert_eq(LayoutIO.save_file(l, path), OK)
	assert_true(FileAccess.file_exists(LayoutIO.backup_path_for(path, 0)))
	DirAccess.remove_absolute(LayoutIO.backup_path_for(path, 0))
