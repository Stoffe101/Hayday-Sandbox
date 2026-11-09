extends TestCase
## Layout library lifecycle, reference calibration maths, importer helpers.

var root := "user://test_library"


func before_each() -> void:
	_rm(root)


func after_each() -> void:
	_rm(root)


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for sub in d.get_directories():
		_rm(path.path_join(sub))
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


func _layout(db: ItemDatabase, name: String) -> FarmLayout:
	var l := FarmLayout.new()
	l.name = name
	l.add_objects([make_obj(db.get_item("t_bakery"), Vector2i(1, 1))])
	return l


func test_library_save_list_duplicate_rename_delete() -> void:
	var db := fixture_db()
	var lib := LayoutLibrary.new(db, root)
	var l := _layout(db, "Alpha")
	assert_eq(lib.save(l), OK)
	assert_false(l.id.is_empty(), "id assigned on first save")
	var listing := lib.list()
	assert_eq(listing.size(), 1)
	assert_eq(listing[0]["name"], "Alpha")
	assert_eq(listing[0]["objects"], 1)
	var dup := lib.duplicate_layout(l.id)
	assert_false(dup.is_empty())
	assert_eq(lib.list().size(), 2)
	assert_eq(lib.rename(dup, "Beta"), OK)
	var names := lib.list().map(func(e): return e["name"])
	assert_has(names, "Beta")
	assert_eq(lib.delete(dup), OK)
	assert_eq(lib.list().size(), 1, "deleted layout leaves the gallery")
	var trash := DirAccess.open(root.path_join("trash"))
	assert_eq(trash.get_files().size(), 1, "…but is kept in the trash folder")


func test_history_snapshots_are_capped() -> void:
	var db := fixture_db()
	var lib := LayoutLibrary.new(db, root)
	var l := _layout(db, "Snap")
	lib.save(l)
	assert_eq(lib.history(l.id).size(), 1)
	var rep := LayoutIO.LoadReport.new()
	var back := lib.load_path(lib.history(l.id)[0]["path"], rep)
	assert_eq(back.count(), 1, "snapshot is a loadable layout")


func test_autosave_recovery_detects_newer_work() -> void:
	var db := fixture_db()
	var lib := LayoutLibrary.new(db, root)
	var l := _layout(db, "Crashy")
	lib.save(l)
	assert_eq(lib.pending_recovery().size(), 0, "nothing to recover right after a save")
	l.add_objects([make_obj(db.get_item("t_lamp"), Vector2i(8, 8))])
	l.modified = "9999-01-01T00:00:00Z"
	lib.autosave(l)
	var rec := lib.pending_recovery()
	assert_eq(rec.size(), 1)
	assert_eq(rec[0]["id"], l.id)
	lib.save(l)
	assert_eq(lib.pending_recovery().size(), 0, "manual save clears the recovery copy")


func test_solve_affine_maps_points_exactly() -> void:
	var img := [Vector2(10, 10), Vector2(200, 30), Vector2(40, 150)]
	var xf := Transform2D(Vector2(0.8, 0.3), Vector2(-0.4, 0.5), Vector2(-120, 35))
	var world := []
	for p in img:
		world.append(xf * p)
	var a: Variant = ReferenceLayer.solve_affine(img, world)
	assert_not_null(a)
	var got := Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))
	for i in 3:
		assert_vec_almost(got * img[i], world[i], 0.001)
	assert_null(ReferenceLayer.solve_affine([Vector2(0, 0), Vector2(1, 1), Vector2(2, 2)], world), "collinear points rejected")


func test_importer_name_matching() -> void:
	var db := fixture_db()
	var idx := AssetImporter.build_name_index(db)
	assert_eq(AssetImporter.normalize("Test Bakery.PNG".get_basename()), "testbakery")
	assert_eq(idx.get(AssetImporter.normalize("test_bakery")), "t_bakery")
	assert_eq(idx.get(AssetImporter.normalize("Wood Fence")), "t_fence")
	assert_eq(idx.get(AssetImporter.normalize("old fence")), "t_fence", "aliases match too")


func test_settings_roundtrip_and_type_safety() -> void:
	var path := "user://test_settings.cfg"
	var s := AppSettings.new(path)
	s.set_v("theme", "light")
	s.toggle_favorite("t_bakery")
	var s2 := AppSettings.new(path)
	s2.load_settings()
	assert_eq(s2.get_v("theme"), "light")
	assert_has(s2.get_v("favorites"), "t_bakery")
	var cf := ConfigFile.new()
	cf.load(path)
	cf.set_value("app", "show_grid", "not a bool")
	cf.save(path)
	var s3 := AppSettings.new(path)
	s3.load_settings()
	assert_eq(s3.get_v("show_grid"), true, "wrongly-typed values fall back to defaults")
	DirAccess.remove_absolute(path)
