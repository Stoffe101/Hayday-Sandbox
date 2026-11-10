extends TestCase
## PlacementCheck: leave-one-out residuals of a calibrated screenshot per
## landmark, the centre-vs-registration comparison and the labels. Synthetic
## fixture world (tests/fixtures/world_v2.json, invented numbers).


func _map() -> FarmMap:
	return FarmMap.load_file("res://tests/fixtures/world_v2.json")


## A synthetic screenshot: world px -> image px.
func _cam() -> Transform2D:
	return Transform2D(deg_to_rad(0.0), Vector2(1.7, 1.7), 0.0, Vector2(900, 420))


func _pt(m: FarmMap, lid: String, spot: String, shift_px := Vector2.ZERO) -> Dictionary:
	var g := CalibrationMath.landmark_anchor(m.landmark(lid), spot)
	return CalibrationMath.make_point(_cam() * Iso.grid_to_world(g) + shift_px, g, lid, spot, false)


func _image(points: Array) -> Dictionary:
	var f := CalibrationMath.fit(points)
	return {"id": "shot1", "name": "my farm.png", "file": "x.png", "calibration": CalibrationMath.to_record(points, f, "now")}


func test_two_points_are_pending_a_screenshot_check() -> void:
	var m := _map()
	var r := PlacementCheck.build(_image([_pt(m, "house", "top"), _pt(m, "dock", "left")]), m)
	assert_eq(r["label"], "pending-screenshot")
	assert_eq(r["n"], 2)
	for p: Dictionary in r["points"]:
		assert_eq(p["status"], "not measured", "a 2-point fit can't measure itself")


func test_three_clean_landmarks_agree() -> void:
	var m := _map()
	var r := PlacementCheck.build(_image([_pt(m, "house", "top"), _pt(m, "house", "bottom"), _pt(m, "dock", "left")]), m)
	assert_eq(r["label"], "screenshot-checked")
	for p: Dictionary in r["points"]:
		assert_almost(float(p["tiles"]), 0.0, 0.01, p["name"])
	assert_eq(r["landmarks"].size(), 2)
	assert_eq(r["landmarks"][0]["status"], "agrees")
	assert_eq(r["predicted"].size(), 3, "every landmark mapped into the screenshot")
	assert_true(PlacementCheck.to_markdown(r).contains("screenshot-checked"))


func test_a_shifted_landmark_is_found() -> void:
	var m := _map()
	# The dock is drawn a whole tile along +x in the "screenshot": (32, 16) world px.
	var shift := _cam().basis_xform(Vector2(32, 16))
	var pts := [_pt(m, "house", "top"), _pt(m, "house", "bottom"), _pt(m, "house", "left"), _pt(m, "dock", "left", shift)]
	var r := PlacementCheck.build(_image(pts), m)
	assert_eq(r["label"], "mismatch")
	var dock: Dictionary = r["points"][3]
	assert_almost(float(dock["tiles"]), 1.0, 0.02, "one tile off, measured against the other three")
	assert_almost(float(dock["d_tiles"][0]), 1.0, 0.02)
	assert_true(str(r["conclusion"]).contains("dock") or str(r["conclusion"]).contains("Dock"))


func test_centre_click_is_compared_with_the_registration_point() -> void:
	var m := _map()
	var sign := m.landmark("sign")
	# A centred sprite whose registration tile corner differs from its footprint centre.
	sign.extra["client_registration"] = [12, 14]
	var reg_px := _cam() * Iso.grid_to_world(Vector2(12, 14))
	var pts := [_pt(m, "house", "top"), _pt(m, "house", "bottom"), _pt(m, "dock", "left"),
		CalibrationMath.make_point(reg_px, Vector2(12.5, 14.5), "sign", "center", true)]
	var r := PlacementCheck.build(_image(pts), m)
	assert_eq(r["alternatives"].size(), 1)
	var a: Dictionary = r["alternatives"][0]
	assert_eq(a["closer_to"], "registration point", "the art sits on the registration point, not the centre")
	assert_almost(float(a["tiles_to_registration"]), 0.0, 0.01)
	var pe: Dictionary = r["predicted"].filter(func(e: Dictionary) -> bool: return e["id"] == "sign")[0]
	assert_true(pe.has("registration_img"))
