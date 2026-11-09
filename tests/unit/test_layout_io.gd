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
	assert_not_null(l.object_at(Vector2i(10, 0)))


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
