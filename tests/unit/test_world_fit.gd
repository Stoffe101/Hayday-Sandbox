extends TestCase
## WorldFit: objects a layout puts on a world's fixed ground (road, landmarks,
## water) — the bundled samples on a private world with the real road and
## landmarks. Pieces (fences, paths) and 1x1 items are removed, larger objects
## move to the nearest legal free spot; the repair is one undo step.

var db: ItemDatabase
var map: FarmMap


func before_each() -> void:
	db = fixture_db()
	# Made-up world: a road strip, a blocking landmark ("strong" confidence).
	map = FarmMap.from_data({"format": "hayday-sandbox-map", "schema_version": 2, "id": "fit_map", "frame": "game", "size": [30, 30],
		"regions": [{"id": "start", "kind": "buildable", "rects": [[0, 0, 30, 20]]},
			{"id": "road", "kind": "road", "rects": [[0, 20, 30, 4]]}],
		"landmarks": [{"id": "truck", "name": "Truck", "origin": [10, 10], "footprint": [1, 2], "confidence": "verified-in-data"}]})


func _layout(objs: Array) -> FarmLayout:
	var l := FarmLayout.new()
	l.add_objects(objs)
	return l


func test_plan_removes_pieces_and_moves_buildings() -> void:
	var fence := make_obj(db.get_item("t_fence"), Vector2i(4, 21))       # on the road
	var path := make_obj(db.get_item("t_path"), Vector2i(10, 11))        # on the truck
	var lamp := make_obj(db.get_item("t_lamp"), Vector2i(6, 22))         # 1x1 on the road
	var bak := make_obj(db.get_item("t_bakery"), Vector2i(14, 18))       # half on the road
	var ok := make_obj(db.get_item("t_bakery"), Vector2i(2, 2))          # fine
	var l := _layout([fence, path, lamp, bak, ok])
	var p := WorldFit.plan(l, map, db)
	var rm: Array = p["removes"]
	rm.sort()
	var want := [fence.uid, path.uid, lamp.uid]
	want.sort()
	assert_eq(rm, want, "fence / path pieces and 1x1 items on fixed ground are removed")
	assert_eq((p["moves"] as Array).size(), 1, "the bakery moves")
	var m: Dictionary = p["moves"][0]
	assert_eq(int(m["uid"]), bak.uid)
	var dest := Rect2i(bak.origin + (m["delta"] as Vector2i), bak.size)
	assert_true(PlacementRules.check_rect(l, map, dest, {bak.uid: true}).ok, "it moves to a legal free spot (%s)" % dest)
	assert_true(absi(m["delta"].x) + absi(m["delta"].y) <= 2 * WorldFit.MOVE_RADIUS, "nearby")
	assert_false((p["reasons"] as Dictionary).has(ok.uid), "objects that fit are left alone")
	assert_true(str(p["reasons"][fence.uid]).contains("road"), "the reason names the road")


func test_overlaps_between_objects_are_not_repaired() -> void:
	## Two objects overlapping each other on buildable land is a design choice, not fixed ground.
	var a := make_obj(db.get_item("t_bakery"), Vector2i(2, 2))
	var b := make_obj(db.get_item("t_lamp"), Vector2i(3, 3))
	var l := _layout([a, b])
	assert_true(WorldFit.is_empty(WorldFit.plan(l, map, db)))


func test_moved_objects_never_share_a_spot() -> void:
	var objs: Array = []
	for i in 4:
		objs.append(make_obj(db.get_item("t_bakery"), Vector2i(2 + i * 3, 19)))
	var l := _layout(objs)
	var p := WorldFit.plan(l, map, db)
	var rects: Array[Rect2i] = []
	for m: Dictionary in p["moves"]:
		var o := l.get_obj(int(m["uid"]))
		rects.append(Rect2i(o.origin + (m["delta"] as Vector2i), o.size))
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			assert_false(rects[i].intersects(rects[j]), "destinations %s and %s overlap" % [rects[i], rects[j]])


func test_session_fit_is_one_undo_step() -> void:
	var fence := make_obj(db.get_item("t_fence"), Vector2i(4, 21))
	var bak := make_obj(db.get_item("t_bakery"), Vector2i(14, 18))
	var l := _layout([fence, bak])
	var s := EditorSession.new(l, db, map)
	var steps := s.stack.size()
	var done := s.fit_to_world()
	assert_eq(s.stack.size(), steps + 1, "one undo step")
	assert_eq(l.count(), 1, "the fence is gone")
	assert_true(PlacementRules.check_object(l, map, l.get_obj(bak.uid)).ok, "the bakery stands legally")
	assert_true(WorldFit.summary(done).contains("1 moved") and WorldFit.summary(done).contains("1 left out"))
	s.stack.undo()
	assert_eq(l.count(), 2, "undo brings the fence back")
	assert_eq(l.get_obj(bak.uid).origin, Vector2i(14, 18), "…and the bakery where it was")
	assert_not_null(l.get_obj(fence.uid), "same uid restored")
	s.stack.redo()
	assert_eq(l.count(), 1, "redo applies it again")


func test_apply_to_new_layout() -> void:
	var fence := make_obj(db.get_item("t_fence"), Vector2i(4, 21))
	var bak := make_obj(db.get_item("t_bakery"), Vector2i(14, 18))
	var l := _layout([fence, bak])
	var p := WorldFit.plan(l, map, db)
	WorldFit.apply_to_new(l, p)
	assert_true(LayoutIO.find_collisions(l, map).is_empty(), "a fitted copy has no collisions with the world")


func test_bundled_samples_fit_the_public_map() -> void:
	## Every bundled sample (the first-run "My first farm" is the meadow showcase)
	## stands only on legal ground of the public map. Other worlds: fitted on open.
	var full := ItemDatabase.new()
	full.load_default()
	var pub := FarmMap.load_file("res://data/maps/hayday_farm.json")
	var n := 0
	for f in DirAccess.get_files_at("res://data/samples"):
		if not f.ends_with(".hdlayout"):
			continue
		var rep := LayoutIO.LoadReport.new()
		var l := LayoutIO.load_file("res://data/samples/" + f, full, rep)
		assert_not_null(l, "%s loads" % f)
		if l == null:
			continue
		n += 1
		var col := LayoutIO.find_collisions(l, pub)
		assert_eq(col.size(), 0, "%s: no object on road / water / landmarks / outside (%s)" % [f, str(col.slice(0, 3))])
		assert_eq(l.map_id, pub.id, "%s targets the public map" % f)
		for o: PlacedObject in l.objects.values():
			var it := full.get_item(o.item_id)
			if it:
				assert_eq(o.size, it.size_for(o.flipped), "%s: %s footprint matches the catalogue" % [f, o.item_id])
				break
		assert_true(WorldFit.is_empty(WorldFit.plan(l, pub, full)), "%s needs no fitting on the public map" % f)
	assert_true(n >= 5, "all samples checked (%d)" % n)
