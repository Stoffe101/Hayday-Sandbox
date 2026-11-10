extends TestCase
## Farm Accuracy Report (AccuracyReport) and the coordinate audit: placement,
## rendering, picking and calibration all use the same grid <-> world mapping.

const PUBLIC := "res://data/maps/hayday_farm.json"
const WORLD := "res://tests/fixtures/world_v2.json"
const PRIVATE := "res://tests/fixtures/world_private.json"


func _private_map() -> FarmMap:
	return WorldLoader.load(WORLD, [{"world": PRIVATE, "pack_id": "synthetic", "version": "1.0"}], "")


func _calibrated_image(cam: Transform2D, grids: Array, noise: Array = [], approx_first: bool = false) -> Dictionary:
	var pts: Array = []
	for i in grids.size():
		var g: Vector2 = grids[i]
		var px: Vector2 = cam * Iso.grid_to_world(g) + (noise[i] if i < noise.size() else Vector2.ZERO)
		pts.append(CalibrationMath.make_point(px, g, "sign" if (approx_first and i == 0) else "", "top", approx_first and i == 0))
	var f := CalibrationMath.fit(pts)
	return {"id": "r1", "name": "Screenshot", "file": "user://references/x.png", "affine": f["image_to_world"],
		"calibration": CalibrationMath.to_record(pts, f, "2026-11-10T00:00:00")}


const GRIDS := [Vector2(0, 0), Vector2(20, 0), Vector2(20, 14), Vector2(0, 14), Vector2(9, 6)]


# --- report -------------------------------------------------------------------------------

func test_public_map_report() -> void:
	var m := WorldLoader.load(PUBLIC, [], "")
	var r := AccuracyReport.build(m, fixture_db())
	assert_eq(r["level"], "public_approximation")
	assert_eq(r["headline"], "Public approximate map: positions are approximations reconstructed from wiki images.")
	assert_eq(r["source"]["kind"], "public_approximation")
	assert_false(r["source"]["overrides"])
	assert_eq(r["start_land"]["tiles"], 32 * 32)
	assert_eq(r["start_land"]["rect"], [0, 0, 32, 32])
	assert_eq(r["expansion"]["plots"], m.plots.size())
	assert_eq(r["expansion"]["by_section"]["main"], m.plots.size())
	assert_eq(r["expansion"]["geometry"].get("approximation", 0), m.plots.size(), "every public plot shape is an approximation")
	assert_true(r["expansion"]["unmapped_sections"] > 0 and r["expansion"]["unmapped_plots"] > 0)
	assert_eq(r["landmarks"]["by_confidence"]["approximate"], m.landmarks.size())
	assert_eq(r["landmarks"]["blocking"], 0)
	assert_eq(r["version"]["client_version"], "")
	assert_has(r["version"]["text"], "not tied")
	assert_true((r["uncertainties"] as Array).size() >= m.notes.size() + m.unmapped_sections.size())
	var ids := {}
	for s: Dictionary in r["sections"]:
		ids[s["id"]] = s
		assert_true(s["status"] in ["ok", "info", "warn", "unknown"])
		assert_true((s["lines"] as Array).size() > 0, "section %s has lines" % s["id"])
	for k in ["source", "version", "start_land", "expansion", "landmarks", "footprints", "calibration", "uncertainties"]:
		assert_true(ids.has(k), "section %s" % k)
	assert_false(ids.has("layout"), "no layout section without a layout")
	assert_eq(ids["calibration"]["status"], "unknown")
	assert_has(AccuracyReport.to_text(r), r["headline"])


func test_private_world_is_unverified_until_a_good_calibration() -> void:
	var m := _private_map()
	assert_true(m.is_game_data())
	var r := AccuracyReport.build(m, fixture_db())
	assert_eq(r["level"], "game_data_unverified")
	assert_eq(r["headline"], "Game-derived map, placement correspondence not yet visually verified.")
	assert_eq(r["source"]["pack_id"], "synthetic")
	assert_eq(r["version"]["client_version"], "0.0.1")
	assert_eq(r["landmarks"]["by_confidence"]["verified-in-data"], 1)
	assert_eq(r["landmarks"]["by_confidence"]["approximate"], 2)
	assert_eq(r["expansion"]["client_locked"], 1)
	# A good calibration (5 points, small noise) is the only thing that changes the headline.
	var cam := Transform2D(0.0, Vector2(0.5, 0.5), 0.0, Vector2(700, 200))
	var noise := [Vector2(0.4, 0), Vector2(0, -0.3), Vector2(-0.2, 0.2), Vector2(0.1, 0.3), Vector2(-0.3, -0.1)]
	var good := _calibrated_image(cam, GRIDS, noise)
	var r2 := AccuracyReport.build(m, fixture_db(), null, [good])
	assert_eq(r2["level"], "game_data_calibrated")
	assert_has(r2["headline"], "matches it within")
	assert_false(r2["headline"].to_lower().contains("exact"), "never claims exactness")
	assert_eq(r2["calibration"][0]["verdict"], "good")
	# Exact fits (no redundancy), points on approximate landmarks, or an image
	# moved after calibration don't count as verification.
	var exact := _calibrated_image(cam, GRIDS.slice(0, 3))
	assert_eq(AccuracyReport.build(m, fixture_db(), null, [exact])["level"], "game_data_unverified")
	var approx := _calibrated_image(cam, GRIDS, noise, true)
	assert_eq(AccuracyReport.build(m, fixture_db(), null, [approx])["level"], "game_data_unverified")
	var moved := good.duplicate(true)
	moved["affine"][4] = float(moved["affine"][4]) + 40.0
	assert_eq(AccuracyReport.build(m, fixture_db(), null, [moved])["level"], "game_data_unverified")
	var legacy := {"id": "r9", "name": "old", "affine": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]}
	var r3 := AccuracyReport.build(m, fixture_db(), null, [legacy])
	assert_eq(r3["calibration"][0]["verdict"], "legacy")
	assert_eq(r3["level"], "game_data_unverified")


func test_user_overrides_are_named() -> void:
	var m := WorldLoader.load(WORLD, [], "res://tests/fixtures/world_overrides")
	var r := AccuracyReport.build(m, null)
	assert_true(r["source"]["overrides"])
	assert_has(r["source"]["kind_text"], "corrections")
	assert_eq(r["source"]["override_landmarks"], ["house", "dock"])
	assert_has(r["source"]["label"], "your corrections")


func test_layout_use_of_approximate_data_and_footprints() -> void:
	var m := WorldLoader.load(PUBLIC, [], "")
	var db := fixture_db()
	db.get_item("t_lamp").footprint_status = "unverified"
	var l := FarmLayout.new()
	var fh := m.landmark("farmhouse")   # approximate, 4x4
	var near := make_obj(db.get_item("t_bakery"), fh.origin + Vector2i(fh.footprint.x + 1, 0))   # 1 tile beside it
	var on_plot := make_obj(db.get_item("t_lamp"), Vector2i(33, 29))                         # on main_01
	var far := make_obj(db.get_item("t_bakery"), Vector2i(1, 1))
	l.add_objects([near, on_plot, far])
	assert_eq(m.plot_id_at(Vector2i(33, 29)), "main_01")
	var r := AccuracyReport.build(m, db, l)
	var lu: Dictionary = r["layout"]
	assert_eq(lu["objects"], 3)
	assert_eq(lu["on_approximate_plots"], 1)
	assert_eq(lu["on_approximate_land"], 3, "the public starting land is an approximation too")
	assert_eq(lu["near_approximate_landmarks"], 1)
	assert_has(lu["approximate_landmarks_near"], "farmhouse")
	assert_true(lu["uses_approximate"])
	var fp: Dictionary = r["footprints"]
	assert_eq(fp["layout_objects"], 3)
	assert_eq(fp["layout_unverified_objects"], 1)
	assert_eq(fp["layout_unverified_items"], ["t_lamp"])
	assert_eq(fp["catalogue_total"], db.ordered.size())
	assert_eq(int(fp["trusted"]) + int(fp["unverified"]), db.ordered.size())
	var found := false
	for s: Dictionary in r["sections"]:
		if s["id"] == "layout":
			found = true
			assert_eq(s["status"], "warn")
	assert_true(found, "layout section present")


func test_the_layout_references_are_used_by_default() -> void:
	var m := _private_map()
	var l := FarmLayout.new()
	var cam := Transform2D(0.0, Vector2(0.5, 0.5), 0.0, Vector2(700, 200))
	l.reference = {"images": [_calibrated_image(cam, GRIDS, [Vector2(0.3, 0), Vector2.ZERO, Vector2(0, 0.2)])], "above": false}
	var r := AccuracyReport.build(m, fixture_db(), l)
	assert_eq((r["calibration"] as Array).size(), 1)
	assert_eq(r["level"], "game_data_calibrated")


func test_unknown_map() -> void:
	var r := AccuracyReport.build(FarmMap.make_simple(10, 10), null)
	assert_eq(r["level"], "unknown")
	assert_has(r["headline"], "unknown origin")
	assert_eq(AccuracyReport.build(null, null)["level"], "unknown")


# --- coordinate audit -------------------------------------------------------------------

func _lib() -> AssetLibrary:
	## No art at all: every object draws its vector footprint block.
	var lib := AssetLibrary.new()
	lib.builtin_pack_path = "res://tests/fixtures/__no_pack__/pack.json"
	lib.dev_packs_dir = "user://__no_dev_packs__"
	lib.user_packs_dir = "user://__no_user_packs__"
	lib.load_all()
	return lib


func _renderer(layout: FarmLayout, db: ItemDatabase) -> ObjectRenderer:
	var r := ObjectRenderer.new()
	r._ready()
	r.bind(layout, db, _lib())
	r.ensure_sorted()
	return r


func test_renderer_anchors_objects_at_their_footprint_centre() -> void:
	var db := fixture_db()
	var l := FarmLayout.new()
	var r := _renderer(l, db)
	var cases := [["t_bakery", Vector2i(3, 4), false], ["t_long", Vector2i(10, 2), false], ["t_long", Vector2i(10, 12), true],
		["t_lamp", Vector2i(-2, 7), false]]
	for c in cases:
		var o := make_obj(db.get_item(c[0]), c[1], c[2])
		var uid: int = l.add_objects([o])[0]
		var v: ObjectRenderer.Vis = r._vis[uid]
		var want := Iso.footprint_center(o.origin, o.size)
		assert_vec_almost(v.center, want, 0.001, "%s at %s centre" % [c[0], str(c[1])])
		assert_vec_almost(r._draw_center(v), want, 0.001, "drawn where placed")
		assert_vec_almost(Iso.grid_to_world(Vector2(o.origin) + Vector2(o.size) * 0.5), want, 0.001)
		# Placement and occupancy use the same rect.
		for t in Iso.tiles_of(o.origin, o.size):
			assert_eq(l.object_at(t), o, "occupancy of %s" % str(t))
	# Moving updates the anchor by exactly the grid delta.
	var uid0: int = l.objects.keys()[0]
	var before: Vector2 = r._vis[uid0].center
	l.move_objects([uid0], Vector2i(2, -1))
	assert_vec_almost(r._vis[uid0].center - before, Iso.grid_to_world(Vector2(2, -1)), 0.001)
	r._exit_tree()
	r.free()


func test_mirroring_swaps_the_footprint_around_its_centre() -> void:
	## A mirrored W×H sprite drawn at the H×W footprint's centre covers exactly
	## that footprint: the x-mirror of the W×H diamond about its centre is the
	## H×W diamond about the same point.
	for sz: Vector2i in [Vector2i(1, 4), Vector2i(2, 3), Vector2i(3, 3), Vector2i(5, 1)]:
		var o := Vector2i(7, 3)
		var flip := Vector2i(sz.y, sz.x)
		var c := Iso.footprint_center(o, sz)
		var cf := Iso.footprint_center(o, flip)
		var poly := Iso.footprint_polygon(o, sz)
		var want := Iso.footprint_polygon(o, flip)
		var got := PackedVector2Array()
		for p in poly:
			got.append(Vector2(c.x - (p.x - c.x), p.y) - c + cf)
		# Same corner set (mirroring swaps the left and right corners).
		for p in want:
			var hit := false
			for q in got:
				hit = hit or q.distance_to(p) < 0.001
			assert_true(hit, "%s: corner %s of the mirrored footprint" % [str(sz), str(p)])
	var db := fixture_db()
	var it := db.get_item("t_long")
	assert_eq(it.size_for(true), Vector2i(it.footprint.y, it.footprint.x))
	# Rotating through the command keeps the origin and swaps the size.
	var l := FarmLayout.new()
	var st := CommandStack.new()
	st.layout = l
	var ob := make_obj(it, Vector2i(4, 4))
	var uid: int = l.add_objects([ob])[0]
	st.execute(EditCommands.SetProperty.new([uid], "flipped", [true]))
	assert_eq(l.get_obj(uid).origin, Vector2i(4, 4))
	assert_eq(l.get_obj(uid).size, Vector2i(it.footprint.y, it.footprint.x))
	assert_eq(l.object_at(Vector2i(4 + it.footprint.y - 1, 4)), l.get_obj(uid))


func test_flipped_vector_blocks_pick_their_own_footprint() -> void:
	## Without art an object is a block exactly the size of its footprint; its
	## picking shape must be that block, also when mirrored.
	var db := fixture_db()
	var l := FarmLayout.new()
	var r := _renderer(l, db)
	var o := make_obj(db.get_item("t_long"), Vector2i(5, 5), true)   # 1x4 mirrored -> 4x1 on x 5..8, y 5
	var uid: int = l.add_objects([o])[0]
	assert_eq(o.size, Vector2i(4, 1))
	var v: ObjectRenderer.Vis = r._vis[uid]
	for t in Iso.tiles_of(o.origin, o.size):
		var p := Iso.tile_center(t)
		assert_true(Geometry2D.is_point_in_polygon(p, v.fallback_poly), "tile %s of the block is pickable" % str(t))
	# Ground points beside the block (tiles it does not cover) never pick it.
	for g: Vector2 in [Vector2(6.5, 6.7), Vector2(5.5, 7.5), Vector2(7.5, 8.0)]:
		assert_eq(l.object_at(Vector2i(floori(g.x), floori(g.y))), null)
		assert_eq(r.pick(Iso.grid_to_world(g)), 0, "ground at %s is free" % str(g))
	r._exit_tree()
	r.free()


func test_tile_picking_round_trip() -> void:
	for t: Vector2i in [Vector2i(0, 0), Vector2i(31, 31), Vector2i(-4, -3), Vector2i(-1, 5), Vector2i(88, 40)]:
		assert_eq(Iso.world_to_tile(Iso.tile_center(t)), t, "centre of %s" % str(t))
		var poly := Iso.footprint_polygon(t, Vector2i.ONE)
		for i in 4:
			# Just inside each corner of the diamond.
			var inside := poly[i].lerp(Iso.tile_center(t), 0.02)
			assert_eq(Iso.world_to_tile(inside), t, "corner %d of %s" % [i, str(t)])
		var w := Iso.tile_center(t) + Vector2(3.7, -1.2)
		assert_vec_almost(Iso.grid_to_world(Iso.world_to_grid(w)), w, 0.001)
		# Screen <-> world with a camera.
		var s := Iso.world_to_screen(w, Vector2(120, -40), 1.7, Vector2(1920, 1080))
		assert_vec_almost(Iso.screen_to_world(s, Vector2(120, -40), 1.7, Vector2(1920, 1080)), w, 0.01)


func test_landmark_tiles_block_where_they_are_drawn() -> void:
	var m := _private_map()
	for lm in m.landmarks:
		var e := LandmarkView.entry_for(lm, null, null)
		assert_eq(e["rect"], lm.rect(), "%s is drawn on its footprint" % lm.id)
		for b in lm.block_rects():
			for t in Iso.tiles_of(b.position, b.size):
				if not m.in_bounds(t):
					continue
				assert_eq(m.landmark_id_at(t), lm.id, "%s blocks %s" % [lm.id, str(t)])
				assert_eq(m.blocking_landmark_at(t) >= 0, lm.blocks_placement(), "%s placement at %s" % [lm.id, str(t)])
				assert_eq(m.landmark_covering(t), m.landmark_index[lm.id], "picking a blocked tile finds %s" % lm.id)
	var house := m.landmark("house")
	var l := FarmLayout.new()
	var res := PlacementRules.check_rect(l, m, Rect2i(house.origin, Vector2i.ONE))
	assert_false(res.ok, "a verified landmark's tile refuses objects")
	var sign := m.landmark("sign")
	assert_eq(sign.block_rects().size(), 0, "explicit empty blocks")


func test_calibration_and_placement_share_the_grid() -> void:
	## A reference image calibrated on tile corners puts those corners exactly
	## where objects on those tiles are drawn.
	var cam := Transform2D(deg_to_rad(1.0), Vector2(0.42, 0.42), 0.0, Vector2(511, 77))
	var im := _calibrated_image(cam, GRIDS)
	var xf := ReferenceLayer.xform_of(im)
	for g: Vector2 in GRIDS:
		var px: Vector2 = cam * Iso.grid_to_world(g)
		assert_vec_almost(xf * px, Iso.grid_to_world(g), 0.05)
	# The object anchor seen through the screenshot: image pixel of a footprint centre.
	var c := Iso.footprint_center(Vector2i(4, 6), Vector2i(3, 3))
	assert_vec_almost(xf.affine_inverse() * c, cam * c, 0.05)


# --- evidence ladder (client-data validation) ------------------------------------------------

const LADDER := ["ground", "expansion", "landmarks", "footprints", "anchors", "calibration", "terrain", "version"]


static func _validation(client: String = "0.0.1", generated: String = "2026-02-03T10:00:00Z", ground: String = "pass") -> Dictionary:
	## A synthetic WorldValidator report for the private fixture world.
	return {"format": WorldValidator.FORMAT, "version": 1, "status": "warn", "game_version": client,
		"generated": "2026-02-04T08:00:00Z", "world": {"client_version": client, "generated": generated},
		"checks": [
			{"id": "ground", "status": ground, "compared": 4800, "mismatches": 0 if ground == "pass" else 7},
			{"id": "expansion_tiles", "status": "pass", "compared": 1234, "mismatches": 0},
			{"id": "plot_overlaps", "status": "pass", "mismatches": 0},
			{"id": "expansion_definitions", "status": "pass", "not_on_map": [{"id": 3}]},
			{"id": "landmarks_present", "status": "pass", "client_rows": 3, "mismatches": 0},
			{"id": "landmark_positions", "status": "pass", "compared": 3, "mismatches": 0},
			{"id": "item_footprints", "status": "pass", "matched": 10, "mismatches": 0, "axis_swapped": 0, "unlinked": 2},
			{"id": "footprint_corrections", "status": "pass", "present": 4},
			{"id": "rendering_anchors", "status": "warn", "verified": false,
				"examples": [{"landmark": "truck", "distance_px": 17.89}]}],
		# Deltas as JSON gives them back (floats).
		"landmarks": [{"landmark": "house", "delta_from_source": [0.0, 0.0], "rule_confidence": "verified-in-data"},
			{"landmark": "truck", "delta_from_source": [0.0, -1.0], "rule_confidence": "strong"}]}


func _rows(r: Dictionary) -> Dictionary:
	var out := {}
	for e: Dictionary in r["evidence"]:
		out[e["id"]] = e
	return out


func test_evidence_ladder_on_the_public_map() -> void:
	var r := AccuracyReport.build(WorldLoader.load(PUBLIC, [], ""), fixture_db(), null, [], {})
	assert_eq((r["evidence"] as Array).map(func(e): return e["id"]), LADDER)
	var rows := _rows(r)
	for id in ["ground", "expansion", "landmarks"]:
		assert_eq(rows[id]["status"], "warn", id)
		assert_has(rows[id]["text"], "Public approximate map")
	for id in ["footprints", "anchors", "calibration", "terrain", "version"]:
		assert_eq(rows[id]["status"], "unknown", id)
	assert_eq(r["sections"][0]["id"], "evidence", "the ladder comes first")
	assert_eq((r["sections"][0]["lines"] as Array).size(), 8)
	assert_false(r["validation"]["applies"])
	assert_false(AccuracyReport.to_text(r).to_lower().contains("pixel"), "never claims pixel accuracy")


func test_evidence_ladder_with_a_matching_validation() -> void:
	var m := _private_map()
	var r := AccuracyReport.build(m, fixture_db(), null, [], _validation())
	assert_true(r["validation"]["applies"], str(r["validation"]))
	assert_eq(r["level"], "game_data_validated")
	assert_has(r["headline"], "match the client's level data exactly")
	assert_has(r["headline"], "not yet visually verified")
	var rows := _rows(r)
	assert_eq(rows["ground"]["status"], "ok")
	assert_has(rows["ground"]["text"], "4,800 tiles")
	assert_eq(rows["expansion"]["status"], "ok")
	assert_has(rows["expansion"]["text"], "1,234 expansion tiles")
	assert_has(rows["expansion"]["text"], "not missing land")
	assert_eq(rows["landmarks"]["status"], "ok")
	assert_has(rows["landmarks"]["text"], "1 through a per-object registration rule: truck (strong)")
	assert_eq(rows["footprints"]["status"], "ok")
	assert_has(rows["footprints"]["text"], "after the pack's 4 corrections")
	assert_eq(rows["anchors"]["status"], "unknown", "rendering anchors stay unverified")
	assert_has(rows["anchors"]["text"], "truck drawn 18 world px")
	assert_eq(rows["calibration"]["status"], "unknown")
	assert_eq(rows["terrain"]["status"], "unknown")
	assert_eq(rows["version"]["status"], "warn")
	assert_has(rows["version"]["text"], "0.0.1")
	var txt := AccuracyReport.to_text(r)
	assert_has(txt, "Evidence ladder")
	assert_has(txt, "1. Exact match to client ground data: Verified.")
	assert_false(txt.to_lower().contains("pixel"))
	assert_false(txt.to_lower().contains("guess"), "data-verified tiles are not called a guess")
	# A good screenshot calibration on top.
	var cam := Transform2D(0.0, Vector2(0.5, 0.5), 0.0, Vector2(700, 200))
	var noise := [Vector2(0.4, 0), Vector2(0, -0.3), Vector2(-0.2, 0.2), Vector2(0.1, 0.3), Vector2(-0.3, -0.1)]
	var r2 := AccuracyReport.build(m, fixture_db(), null, [_calibrated_image(cam, GRIDS, noise)], _validation())
	assert_eq(r2["level"], "game_data_calibrated")
	assert_has(r2["headline"], "tiles match the client's level data")
	assert_eq(_rows(r2)["calibration"]["status"], "ok")


func test_validation_for_another_world_does_not_count() -> void:
	var m := _private_map()
	var other := AccuracyReport.build(m, fixture_db(), null, [], _validation("0.0.2"))
	assert_false(other["validation"]["applies"])
	assert_has(other["validation"]["reason"], "0.0.2")
	assert_eq(other["level"], "game_data_unverified")
	assert_eq(_rows(other)["ground"]["status"], "unknown")
	assert_has(_rows(other)["ground"]["text"], "does not apply")
	var stale := AccuracyReport.build(m, fixture_db(), null, [], _validation("0.0.1", "2025-01-01T00:00:00Z"))
	assert_false(stale["validation"]["applies"])
	assert_has(stale["validation"]["reason"], "earlier build")
	# On the public map a private report never applies.
	var pub := AccuracyReport.build(WorldLoader.load(PUBLIC, [], ""), fixture_db(), null, [], _validation())
	assert_false(pub["validation"]["applies"])
	assert_eq(_rows(pub)["ground"]["status"], "warn")
	# A failed ground comparison is reported, not hidden.
	var bad := AccuracyReport.build(m, fixture_db(), null, [], _validation("0.0.1", "2026-02-03T10:00:00Z", "fail"))
	assert_eq(_rows(bad)["ground"]["status"], "warn")
	assert_has(_rows(bad)["ground"]["text"], "7 of 4,800 tiles differ")
	assert_eq(bad["level"], "game_data_unverified")
	# The user's own landmark corrections are not the client's positions.
	var moved := _private_map()
	moved.provenance["user_overrides"] = {"landmarks": ["house"]}
	var mr := AccuracyReport.build(moved, fixture_db(), null, [], _validation())
	assert_eq(_rows(mr)["landmarks"]["status"], "warn")
	assert_has(_rows(mr)["landmarks"]["text"], "Your own corrections move house")
	# No report at all: the private world says how to get one.
	var none := AccuracyReport.build(m, fixture_db(), null, [], {})
	assert_has(_rows(none)["ground"]["text"], "validate_world.gd")


func test_load_validation_file() -> void:
	var path := "user://test_accuracy_validation/report.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(_validation()))
	f.close()
	assert_eq(AccuracyReport.load_validation(path)["game_version"], "0.0.1")
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{\"format\": \"something-else\"}")
	f.close()
	assert_eq(AccuracyReport.load_validation(path), {})
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	assert_eq(AccuracyReport.load_validation(path), {})
	assert_eq(AccuracyReport.VALIDATION_PATH, WorldValidator.DEFAULT_PATH)
	assert_eq(AccuracyReport._n(9976), "9,976")
	assert_eq(AccuracyReport._n(223), "223")
	assert_eq(AccuracyReport._n(1234567), "1,234,567")
