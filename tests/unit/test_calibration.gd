extends TestCase
## CalibrationMath: least-squares screenshot fits, residuals, verdicts, the
## 2:1 isometric check, landmark anchors and the stored calibration record.


## A synthetic screenshot: world px -> image px (scale, rotation in degrees,
## optional extra stretch of the image's y axis).
func _cam(scale: float, rot_deg: float = 0.0, offset: Vector2 = Vector2(900, 420), stretch_y: float = 1.0) -> Transform2D:
	var xf := Transform2D(deg_to_rad(rot_deg), Vector2(scale, scale), 0.0, offset)
	return Transform2D(Vector2(1, 0), Vector2(0, stretch_y), Vector2.ZERO) * xf


func _pts(cam: Transform2D, grids: Array, noise: Array = []) -> Array:
	var out: Array = []
	for i in grids.size():
		var g: Vector2 = grids[i]
		var px: Vector2 = cam * Iso.grid_to_world(g)
		if i < noise.size():
			px += noise[i]
		out.append(CalibrationMath.make_point(px, g))
	return out


const GRIDS := [Vector2(0, 0), Vector2(32, 0), Vector2(32, 32), Vector2(0, 32), Vector2(16, 10), Vector2(5, 27)]


func _xf(a: Array) -> Transform2D:
	return Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))


func test_two_points_give_an_exact_similarity_but_no_error_estimate() -> void:
	var cam := _cam(0.6, 4.0)
	var f := CalibrationMath.fit(_pts(cam, [Vector2(0, 0), Vector2(20, 6)]))
	assert_true(f["ok"], str(f["error"]))
	assert_eq(f["model"], "similarity")
	assert_eq(f["redundancy"], 0)
	assert_eq(f["verdict"], "unverified", "an exact fit can't measure its own error")
	assert_eq(f["iso"]["verdict"], "assumed")
	var i2w := _xf(f["image_to_world"])
	# The fit reproduces the true camera everywhere (a similarity is fully determined by 2 points).
	for g: Vector2 in GRIDS:
		var w := Iso.grid_to_world(g)
		assert_vec_almost(i2w * (cam * w), w, 0.05, "grid %s" % str(g))
	assert_almost(f["iso"]["scale"], 0.6, 1e-4)
	assert_almost(f["iso"]["rotation_deg"], 4.0, 1e-3)


func test_three_points_give_an_exact_affine() -> void:
	var cam := _cam(0.5, 0.0, Vector2(100, 50), 1.1)
	var f := CalibrationMath.fit(_pts(cam, [Vector2(0, 0), Vector2(30, 2), Vector2(4, 28)]))
	assert_true(f["ok"])
	assert_eq(f["model"], "affine")
	assert_eq(f["redundancy"], 0)
	assert_eq(f["verdict"], "unverified")
	assert_true(f["max_tiles"] < 1e-3)
	assert_eq(f["iso"]["verdict"], "distorted", "a 10 % stretched screenshot is not a plain 2:1 view")
	assert_almost(f["iso"]["aspect"], 1.1, 1e-3)


func test_least_squares_with_clean_points_is_good_and_isometric() -> void:
	var cam := _cam(0.45, -1.5)
	var noise := [Vector2(0.6, -0.4), Vector2(-0.5, 0.3), Vector2(0.2, 0.7), Vector2(-0.4, -0.6), Vector2(0.3, 0.1), Vector2(-0.2, 0.4)]
	var f := CalibrationMath.fit(_pts(cam, GRIDS, noise))
	assert_true(f["ok"])
	assert_eq(f["n"], 6)
	assert_eq(f["redundancy"], 6)
	assert_eq(f["verdict"], "good")
	assert_true(f["rms_tiles"] < 0.05, "sub-pixel noise is a tiny fraction of a tile (%f)" % f["rms_tiles"])
	assert_true(f["rms_px"] < 1.0)
	assert_eq(f["iso"]["verdict"], "iso")
	assert_almost(f["iso"]["tile_aspect"], 2.0, 0.02, "tiles are 2:1 in the screenshot")
	assert_almost(f["iso"]["tile_px"][0], 64.0 * 0.45, 0.2)
	assert_false(f["iso"]["mirrored"])
	assert_eq((f["residuals"] as Array).size(), 6)


func test_an_outlier_is_found_and_downgrades_the_verdict() -> void:
	var cam := _cam(0.5)
	var noise := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2(40, 0), Vector2.ZERO]
	var f := CalibrationMath.fit(_pts(cam, GRIDS, noise))
	assert_true(f["ok"])
	assert_eq(f["worst"], 4, "the moved point has the largest residual")
	assert_true(f["max_tiles"] > 0.5)
	assert_true(f["verdict"] in ["fair", "poor"], "verdict %s" % f["verdict"])
	var res: Array = f["residuals"]
	for r: Dictionary in res:
		assert_true(float(r["tiles"]) <= float(f["max_tiles"]) + 1e-9)


func test_residual_units_are_consistent() -> void:
	## For a similarity camera of scale s, a residual of d tiles is s * |G d| px.
	var s := 0.7
	var cam := _cam(s, 0.0)
	var noise := [Vector2(3, 1), Vector2(-2, 2), Vector2(1, -3), Vector2(0, 2), Vector2(-1, -1), Vector2(2, 0)]
	var f := CalibrationMath.fit(_pts(cam, GRIDS, noise), "similarity")
	assert_true(f["ok"])
	assert_eq(f["redundancy"], 8)
	for r: Dictionary in f["residuals"]:
		var dt := Vector2(r["d_tiles"][0], r["d_tiles"][1])
		var world_err := Iso.grid_to_world(dt).length() * s
		assert_almost(world_err, float(r["px"]), 0.01, "point %d" % int(r["index"]))


func test_verdict_thresholds() -> void:
	assert_eq(CalibrationMath.verdict_for(0.1, 0.2, 2), "good")
	assert_eq(CalibrationMath.verdict_for(0.1, 0.6, 2), "fair", "one point half a tile off is not good")
	assert_eq(CalibrationMath.verdict_for(0.3, 0.4, 2), "fair")
	assert_eq(CalibrationMath.verdict_for(0.6, 0.7, 2), "poor")
	assert_eq(CalibrationMath.verdict_for(0.1, 1.2, 4), "poor")
	assert_eq(CalibrationMath.verdict_for(0.0, 0.0, 0), "unverified")


func test_mirrored_and_degenerate_inputs() -> void:
	var cam := Transform2D(Vector2(-0.5, 0), Vector2(0, 0.5), Vector2(800, 300))   # mirrored screenshot
	var f := CalibrationMath.fit(_pts(cam, GRIDS))
	assert_true(f["ok"])
	assert_eq(f["iso"]["verdict"], "mirrored")
	var bad := CalibrationMath.fit(_pts(_cam(0.5), [Vector2(0, 0), Vector2(5, 5), Vector2(10, 10)]))
	assert_false(bad["ok"], "collinear grid points can't fix an affine")
	assert_false(CalibrationMath.fit(_pts(_cam(0.5), [Vector2(3, 3)]))["ok"], "one point is not enough")
	assert_false(CalibrationMath.fit([CalibrationMath.make_point(Vector2(1, 1), Vector2(0, 0)),
		CalibrationMath.make_point(Vector2(1, 1), Vector2(4, 0))])["ok"], "both clicks on the same pixel")
	assert_false(CalibrationMath.fit([], "affine")["ok"])
	assert_false(CalibrationMath.fit(_pts(_cam(0.5), GRIDS), "perspective")["ok"], "unknown model")
	assert_eq(CalibrationMath.clean_points([{"img": [1, 2]}, "junk", {"img": [1, 2], "grid": [3, 4]}]).size(), 1)


func test_affine_least_squares_matches_known_affine_with_noise_free_points() -> void:
	var cam := Transform2D(Vector2(0.52, 0.03), Vector2(-0.02, 0.47), Vector2(312, -40))
	var f := CalibrationMath.fit(_pts(cam, GRIDS))
	assert_true(f["ok"])
	assert_true(f["max_px"] < 0.01)
	var w2i := _xf(f["world_to_image"])
	assert_vec_almost(w2i.x, cam.x, 1e-4)
	assert_vec_almost(w2i.y, cam.y, 1e-4)
	assert_vec_almost(w2i.origin, cam.origin, 0.01)
	var g2i := _xf(f["grid_to_image"])
	assert_vec_almost(g2i * Vector2(7, 9), cam * Iso.grid_to_world(Vector2(7, 9)), 0.01, "grid -> image")


func test_landmark_anchors() -> void:
	var m := FarmMap.load_file("res://tests/fixtures/world_v2.json")
	var house := m.landmark("house")   # origin (3, 3), 3x3, confidence strong
	assert_vec_almost(CalibrationMath.landmark_anchor(house, "top"), Vector2(3, 3))
	assert_vec_almost(CalibrationMath.landmark_anchor(house, "right"), Vector2(6, 3))
	assert_vec_almost(CalibrationMath.landmark_anchor(house, "bottom"), Vector2(6, 6))
	assert_vec_almost(CalibrationMath.landmark_anchor(house, "left"), Vector2(3, 6))
	assert_vec_almost(CalibrationMath.landmark_anchor(house, "center"), Vector2(4.5, 4.5))
	var poly := Iso.footprint_polygon(house.origin, house.footprint)
	for i in 4:
		assert_vec_almost(Iso.grid_to_world(CalibrationMath.landmark_anchor(house, CalibrationMath.ANCHOR_SPOTS[i])), poly[i], 0.001,
			"corner %s is the footprint diamond's" % CalibrationMath.ANCHOR_SPOTS[i])
	var s := CalibrationMath.snap_grid_point(m, Vector2(4.6, 4.4))
	assert_eq(s["landmark"], "house")
	assert_eq(s["spot"], "center")
	assert_false(s["approximate"])
	var plain := CalibrationMath.snap_grid_point(m, Vector2(10.2, 1.7))
	assert_eq(plain["landmark"], "")
	assert_vec_almost(plain["grid"], Vector2(10, 2), 0.0001, "elsewhere: nearest tile corner")
	var sign := CalibrationMath.snap_grid_point(m, Vector2(13.1, 15.1))   # the sign is approximate
	assert_eq(sign["landmark"], "sign")
	assert_true(sign["approximate"], "anchors on approximate landmarks are flagged")
	# Flags follow the active map.
	var p := [CalibrationMath.make_point(Vector2(1, 1), Vector2(12, 14), "sign", "top", false),
		CalibrationMath.make_point(Vector2(9, 9), Vector2(0, 0), "gone", "top", false)]
	var r := CalibrationMath.refresh_anchor_flags(p, m)
	assert_true(r[0]["approximate"])
	assert_true(r[1]["missing_landmark"])
	assert_false(p[0]["approximate"], "inputs are not modified")


func test_record_round_trip_and_applied_state() -> void:
	var cam := _cam(0.5, 2.0)
	var pts := _pts(cam, GRIDS, [Vector2(0.5, 0), Vector2(0, -0.5)])
	pts[2] = CalibrationMath.make_point(CalibrationMath.point_img(pts[2]), CalibrationMath.point_grid(pts[2]), "house", "bottom", true)
	var f := CalibrationMath.fit(pts)
	var rec := CalibrationMath.to_record(pts, f, "2026-11-10T12:00:00")
	assert_eq(rec["at"], "2026-11-10T12:00:00")
	assert_eq((rec["points"] as Array).size(), 6)
	assert_almost(rec["rms_tiles"], f["rms_tiles"])
	var im := {"id": "r1", "name": "farm", "file": "user://x.png", "affine": f["image_to_world"], "calibration": rec}
	# Survives JSON and the reference document normalisation.
	var back: Dictionary = LayoutIO.normalize_reference(JsonUtil.parse(JsonUtil.stringify({"images": [im], "above": false})))["images"][0]
	assert_true(CalibrationMath.record_applied(back), "the image is placed by its calibration")
	var refit := CalibrationMath.fit(CalibrationMath.record_of(back)["points"])
	assert_almost(refit["rms_tiles"], f["rms_tiles"], 1e-6, "stored points refit identically")
	var sm := CalibrationMath.summary(back)
	assert_true(sm["calibrated"])
	assert_eq(sm["points"], 6)
	assert_eq(sm["verdict"], "good")
	assert_eq(sm["approximate_points"], 1)
	assert_has(sm["text"], "approximate landmark")
	back["affine"][4] = float(back["affine"][4]) + 25.0   # dragged by hand
	assert_false(CalibrationMath.record_applied(back))
	assert_has(CalibrationMath.summary(back)["text"], "moved or adjusted by hand")
	var live := CalibrationMath.live_residuals(back)
	assert_eq(live.size(), 6)
	assert_true(float(live[0]["tiles"]) > 0.3, "the canvas shows the drag as residuals")
	var legacy := CalibrationMath.summary({"id": "r2", "affine": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]})
	assert_eq(legacy["verdict"], "legacy", "old 2/3-point calibrations are reported as error unknown")
	assert_eq(CalibrationMath.summary({"id": "r3"})["verdict"], "none")


func test_reference_layer_uses_the_same_fit() -> void:
	var cam := _cam(0.5, 3.0)
	var img: Array = []
	var world: Array = []
	for g: Vector2 in [Vector2(0, 0), Vector2(12, 3), Vector2(2, 15), Vector2(20, 20)]:
		world.append(Iso.grid_to_world(g))
		img.append(cam * Iso.grid_to_world(g))
	var a: Variant = ReferenceLayer.solve_calibration(img, world)
	assert_not_null(a, "four points are accepted")
	var xf := _xf(a)
	for i in 4:
		assert_vec_almost(xf * (img[i] as Vector2), world[i], 0.05)
	assert_eq(ReferenceLayer.xform_of({"affine": a}), CalibrationMath.image_xform({"affine": a}))


func test_grid_through_a_screenshot() -> void:
	## The grid drawn over an image covers exactly the tiles under it.
	var im := {"x": 0.0, "y": 0.0, "scale": 1.0, "rotation": 0.0}
	var quad := ReferenceLayer.image_quad(im, Vector2(256, 128))
	var segs := ReferenceLayer.grid_lines_in(quad)
	assert_true(segs.size() > 0 and segs.size() % 2 == 0)
	for p in segs:
		assert_true(p.x >= -0.01 and p.x <= 256.01 and p.y >= -0.01 and p.y <= 128.01, "clipped to the image: %s" % str(p))
		var g := Iso.world_to_grid(p)
		var on_line := absf(g.x - roundf(g.x)) < 0.01 or absf(g.y - roundf(g.y)) < 0.01
		assert_true(on_line, "every segment end lies on a tile edge")
	assert_eq(ReferenceLayer.grid_lines_in(quad, 2).size(), 0, "too many lines: nothing drawn")
