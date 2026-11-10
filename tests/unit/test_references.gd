extends TestCase
## Multiple reference images: the schema-3 document, migration of the old
## single-image format, undo, calibration from two or three points.


func _v2_layout() -> Dictionary:
	## A schema-2 file exactly as older versions saved it.
	return {"format": LayoutIO.FORMAT, "schema_version": 2, "meta": {"id": "old", "name": "Old"},
		"map": {"id": "hayday_farm", "unlocked_plots": []}, "objects": [],
		"reference": {"file": "user://references/old_1.png", "opacity": 0.3, "visible": false, "locked": true,
			"above": true, "x": 12.0, "y": -7.5, "scale": 0.8, "rotation": 4.0, "future_field": "kept"},
		"camera": {"x": 0.0, "y": 0.0, "zoom": 1.0}}


func test_old_single_reference_is_migrated_on_read() -> void:
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(_v2_layout(), fixture_db(), rep)
	assert_not_null(l)
	assert_eq(rep.migrated_from, 2)
	assert_eq(l.reference["above"], true, "'above' moves up to the layer")
	var imgs: Array = l.reference["images"]
	assert_eq(imgs.size(), 1)
	var im: Dictionary = imgs[0]
	assert_eq(im["file"], "user://references/old_1.png")
	assert_eq(im["opacity"], 0.3)
	assert_eq(im["visible"], false)
	assert_eq(im["locked"], true)
	assert_eq(im["x"], 12.0)
	assert_eq(im["y"], -7.5)
	assert_eq(im["scale"], 0.8)
	assert_eq(im["rotation"], 4.0)
	assert_eq(im["future_field"], "kept", "unknown fields survive")
	assert_false(im.has("above"))
	assert_eq(im["id"], "r1")
	assert_eq(im["name"], "old_1")


func test_v1_reference_is_shifted_then_wrapped() -> void:
	var d := _v2_layout()
	d["schema_version"] = 1
	d["reference"].erase("rotation")
	var m := LayoutIO.migrate(d.duplicate(true), 1)
	assert_eq(int(m["schema_version"]), LayoutIO.SCHEMA_VERSION)
	var dw := Iso.grid_to_world(Vector2(WorldLoader.V1_TO_GAME_SHIFT))
	assert_almost(float(m["reference"]["images"][0]["x"]), 12.0 + dw.x)
	assert_almost(float(m["reference"]["images"][0]["y"]), -7.5 + dw.y)


func test_empty_reference_stays_empty() -> void:
	assert_eq(LayoutIO.normalize_reference({}), {})
	assert_eq(LayoutIO.normalize_reference(null), {})
	assert_eq(LayoutIO.normalize_reference("junk"), {})
	assert_eq(LayoutIO.normalize_reference({"images": []}), {})
	var d := _v2_layout()
	d.erase("reference")
	assert_eq(LayoutIO.from_dict(d, fixture_db()).reference, {})


func test_normalize_is_idempotent_and_copies() -> void:
	var once := LayoutIO.normalize_reference(_v2_layout()["reference"])
	assert_eq(LayoutIO.normalize_reference(once), once)
	var twice := LayoutIO.normalize_reference(once)
	twice["images"][0]["x"] = 99.0
	assert_eq(once["images"][0]["x"], 12.0, "a fresh copy, not an alias")


func test_ids_are_made_unique() -> void:
	var doc := LayoutIO.normalize_reference({"images": [{"id": "r2", "file": "a"}, {"id": "r2", "file": "b"}, {"file": "c"}, "junk"]})
	var ids := {}
	for im: Dictionary in doc["images"]:
		ids[im["id"]] = true
	assert_eq(ids.size(), 3)
	assert_eq(doc["images"][0]["id"], "r2", "existing ids are kept")


func test_several_images_round_trip_in_order() -> void:
	var l := FarmLayout.new()
	l.id = "x"
	l.reference = {"images": [{"id": "r1", "name": "a", "file": "user://a.png", "opacity": 0.2},
		{"id": "r2", "name": "b", "file": "user://b.png", "opacity": 0.9, "locked": true,
			"affine": [1.0, 0.0, 0.0, 1.0, 5.0, 6.0]}], "above": false}
	var d := LayoutIO.to_dict(l)
	assert_eq(int(d["schema_version"]), LayoutIO.SCHEMA_VERSION)
	var rep := LayoutIO.LoadReport.new()
	var back := LayoutIO.from_dict(JsonUtil.parse(JsonUtil.stringify(d)), fixture_db(), rep)
	assert_eq(rep.migrated_from, -1, "current format: no migration")
	assert_eq(back.reference["images"][0]["id"], "r1")
	assert_eq(back.reference["images"][1]["id"], "r2", "bottom-to-top order kept")
	assert_eq(float(back.reference["images"][0]["opacity"]), 0.2)
	assert_eq(back.reference["images"][1]["affine"], [1.0, 0.0, 0.0, 1.0, 5.0, 6.0])


func test_every_edit_is_one_undo_step() -> void:
	var l := FarmLayout.new()
	var stack := CommandStack.new()
	stack.layout = l
	var seen := [0]
	l.reference_changed.connect(func(): seen[0] += 1)
	var one := {"images": [{"id": "r1", "file": "a"}], "above": false}
	var two := {"images": [{"id": "r1", "file": "a"}, {"id": "r2", "file": "b"}], "above": false}
	var moved := {"images": [{"id": "r2", "file": "b"}, {"id": "r1", "file": "a"}], "above": false}
	stack.execute(EditCommands.SetReference.new({}, one, "Add"))
	stack.execute(EditCommands.SetReference.new(one, two, "Add"))
	stack.execute(EditCommands.SetReference.new(two, moved, "Reorder"))
	assert_eq(l.reference, moved)
	stack.undo()
	assert_eq(l.reference, two)
	stack.undo()
	assert_eq(l.reference, one)
	stack.redo()
	assert_eq(l.reference, two)
	assert_eq(seen[0], 6, "renderers are told every time")


func test_each_image_keeps_its_own_calibration_and_edits_undo() -> void:
	## Calibration records live on the image dictionaries, are saved with the
	## layout and change only through SetReference (one undo step each).
	var l := FarmLayout.new()
	l.id = "cal"
	var stack := CommandStack.new()
	stack.layout = l
	var cam_a := Transform2D(0.0, Vector2(0.5, 0.5), 0.0, Vector2(300, 100))
	var cam_b := Transform2D(deg_to_rad(2.0), Vector2(0.8, 0.8), 0.0, Vector2(-50, 20))
	var grids := [Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)]
	var docs: Array = []
	var base := {"images": [{"id": "r1", "file": "user://a.png"}, {"id": "r2", "file": "user://b.png"}], "above": false}
	stack.execute(EditCommands.SetReference.new({}, base, "Add"))
	var doc := LayoutIO.normalize_reference(l.reference)
	for k in 2:
		var cam: Transform2D = [cam_a, cam_b][k]
		var pts: Array = []
		for g: Vector2 in grids:
			pts.append(CalibrationMath.make_point(cam * Iso.grid_to_world(g) + Vector2(0.3 * k, -0.2), g))
		var f := CalibrationMath.fit(pts)
		var im := ReferenceLayer.image_by_id(doc, "r%d" % (k + 1))
		im["affine"] = f["image_to_world"]
		im["calibration"] = CalibrationMath.to_record(pts, f, "t%d" % k)
		var before := l.reference.duplicate(true)
		stack.execute(EditCommands.SetReference.new(before, doc.duplicate(true), "Calibrate reference"))
		docs.append(l.reference.duplicate(true))
	var a := ReferenceLayer.image_by_id(l.reference, "r1")
	var b := ReferenceLayer.image_by_id(l.reference, "r2")
	assert_eq(a["calibration"]["at"], "t0")
	assert_eq(b["calibration"]["at"], "t1")
	assert_ne(a["affine"], b["affine"], "each image has its own fit")
	assert_true(CalibrationMath.record_applied(a) and CalibrationMath.record_applied(b))
	# Saved and loaded with the layout.
	var back := LayoutIO.from_dict(JsonUtil.parse(JsonUtil.stringify(LayoutIO.to_dict(l))), fixture_db())
	var a2 := ReferenceLayer.image_by_id(back.reference, "r1")
	assert_eq((a2["calibration"]["points"] as Array).size(), 4)
	assert_almost(float(a2["calibration"]["rms_tiles"]), float(a["calibration"]["rms_tiles"]), 1e-6)
	assert_true(CalibrationMath.record_applied(a2))
	stack.undo()
	assert_false(ReferenceLayer.image_by_id(l.reference, "r2").has("calibration"), "undo removes the second calibration only")
	assert_true(ReferenceLayer.image_by_id(l.reference, "r1").has("calibration"))
	stack.undo()
	assert_eq(l.reference, base)
	stack.redo()
	stack.redo()
	assert_eq(l.reference, docs[1])


func test_image_lookup_and_new_ids() -> void:
	var doc := {"images": [{"id": "r1"}, {"id": "r3"}]}
	assert_eq(ReferenceLayer.image_by_id(doc, "r3"), {"id": "r3"})
	assert_eq(ReferenceLayer.image_by_id(doc, "nope"), {})
	assert_eq(ReferenceLayer.new_id(doc), "r2")
	assert_eq(ReferenceLayer.new_id({}), "r1")


func test_xform_of_affine_and_plain() -> void:
	var plain := ReferenceLayer.xform_of({"x": 3.0, "y": 4.0, "scale": 2.0, "rotation": 0.0})
	assert_vec_almost(plain * Vector2(10, 10), Vector2(23, 24))
	var aff := ReferenceLayer.xform_of({"x": 3.0, "affine": [1.0, 0.0, 0.0, 1.0, 5.0, 6.0]})
	assert_vec_almost(aff * Vector2(1, 1), Vector2(6, 7), 0.0001, "affine wins")


func test_calibration_from_two_points() -> void:
	var img := [Vector2(10, 10), Vector2(110, 10)]
	var xf := Transform2D(0.5, Vector2(1.5, 1.5), 0.0, Vector2(-40, 25))
	var world := [xf * img[0], xf * img[1]]
	var a: Variant = ReferenceLayer.solve_calibration(img, world)
	assert_not_null(a)
	var got := Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))
	assert_vec_almost(got * img[0], world[0], 0.001)
	assert_vec_almost(got * img[1], world[1], 0.001)
	assert_almost(got.x.length(), got.y.length(), 0.001, "uniform scale")
	assert_almost(got.x.dot(got.y), 0.0, 0.001, "no shear")
	assert_true(got.determinant() > 0.0, "no reflection")
	assert_vec_almost(got * Vector2(70, 300), xf * Vector2(70, 300), 0.001, "matches the true similarity elsewhere")


func test_calibration_from_three_points_and_bad_input() -> void:
	var img := [Vector2(10, 10), Vector2(200, 30), Vector2(40, 150)]
	var xf := Transform2D(Vector2(0.8, 0.3), Vector2(-0.4, 0.5), Vector2(-120, 35))
	var world := [xf * img[0], xf * img[1], xf * img[2]]
	var a: Variant = ReferenceLayer.solve_calibration(img, world)
	var got := Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))
	for i in 3:
		assert_vec_almost(got * img[i], world[i], 0.001)
	assert_null(ReferenceLayer.solve_calibration([Vector2.ONE, Vector2.ONE], [Vector2.ZERO, Vector2.RIGHT]), "same image point twice")
	assert_null(ReferenceLayer.solve_calibration([Vector2.ZERO, Vector2.ONE], [Vector2.RIGHT, Vector2.RIGHT]), "same world point twice")
	assert_null(ReferenceLayer.solve_calibration([Vector2.ZERO], [Vector2.ZERO]), "one point is not enough")
	assert_null(ReferenceLayer.solve_calibration([Vector2.ZERO, Vector2.ONE], [Vector2.ZERO]), "mismatched lists")
