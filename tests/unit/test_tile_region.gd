extends TestCase
## TileRegion: the tile area of the Select tool's tile selection. Objects are
## included when their logical footprint overlaps a selected tile (art overhang
## never counts); regions grow and shrink by rectangles.

var db: ItemDatabase


func before_each() -> void:
	db = fixture_db()


func _layout(objs: Array) -> FarmLayout:
	var l := FarmLayout.new()
	l.add_objects(objs)
	return l


func test_rect_region_basics() -> void:
	var r := TileRegion.from_rect(Rect2i(10, 10, 6, 6))
	assert_eq(r.size(), 36)
	assert_true(r.has(Vector2i(10, 10)))
	assert_true(r.has(Vector2i(15, 15)))
	assert_false(r.has(Vector2i(16, 15)))
	assert_eq(r.bounds(), Rect2i(10, 10, 6, 6))
	assert_true(r.is_rect())
	assert_true(TileRegion.new().is_empty())
	assert_eq(TileRegion.new().bounds(), Rect2i())


func test_corner_drag_rect_is_inclusive() -> void:
	## Dragging from tile (10,10) to tile (15,15) selects both corner tiles.
	var r := TileRegion.from_rect(Iso.rect_from_corners(Vector2i(15, 15), Vector2i(10, 10)))
	assert_eq(r.bounds(), Rect2i(10, 10, 6, 6))


func test_add_and_remove_rects() -> void:
	var r := TileRegion.from_rect(Rect2i(0, 0, 4, 4))
	r.add_rect(Rect2i(6, 0, 2, 2))
	assert_eq(r.size(), 20)
	assert_eq(r.bounds(), Rect2i(0, 0, 8, 4))
	assert_false(r.is_rect())
	r.remove_rect(Rect2i(1, 1, 2, 2))
	assert_eq(r.size(), 16)
	assert_false(r.has(Vector2i(1, 1)))
	r.remove_rect(Rect2i(6, 0, 2, 2))
	assert_eq(r.bounds(), Rect2i(0, 0, 4, 4), "bounds shrink after a removal")
	r.remove_rect(Rect2i(-5, -5, 20, 20))
	assert_true(r.is_empty())


func test_footprint_overlap_selects_whole_object() -> void:
	## A 3x3 bakery is selected when any one of its tiles is in the region.
	var bak := make_obj(db.get_item("t_bakery"), Vector2i(5, 5))
	var lamp := make_obj(db.get_item("t_lamp"), Vector2i(9, 9))
	var far := make_obj(db.get_item("t_lamp"), Vector2i(20, 20))
	var l := _layout([bak, lamp, far])
	var corner := TileRegion.from_rect(Rect2i(7, 7, 1, 1))     # bakery's last tile
	assert_eq(corner.uids_in(l), [bak.uid])
	var both := TileRegion.from_rect(Rect2i(7, 7, 3, 3))
	var got := both.uids_in(l)
	got.sort()
	var want := [bak.uid, lamp.uid]
	want.sort()
	assert_eq(got, want)
	assert_eq(TileRegion.from_rect(Rect2i(8, 5, 1, 3)).uids_in(l), [], "next to the footprint is not on it")


func test_index_and_scan_paths_agree() -> void:
	## Small regions use the occupancy index, large ones scan the objects: same answer.
	var objs: Array = []
	for i in 30:
		objs.append(make_obj(db.get_item("t_bakery" if i % 3 == 0 else "t_lamp"), Vector2i((i * 7) % 40, (i * 11) % 40)))
	var l := _layout(objs)
	for r: Rect2i in [Rect2i(0, 0, 3, 3), Rect2i(4, 4, 5, 5), Rect2i(0, 0, 40, 40), Rect2i(10, 2, 30, 12)]:
		var reg := TileRegion.from_rect(r)
		var a := reg.uids_in(l)
		var b := TileRegion.rect_uids(l, r)
		var c := l.uids_in_rect(r)
		a.sort()
		b.sort()
		c.sort()
		assert_eq(a, c, "region %s" % r)
		assert_eq(b, c, "rect %s" % r)
	# A region with a hole: the scan path checks tiles, not just the bounds.
	var holed := TileRegion.from_rect(Rect2i(0, 0, 40, 40))
	holed.remove_rect(Rect2i(0, 0, 40, 40).grow(-1))
	var inner := []
	for o: PlacedObject in l.objects.values():
		if o.rect().intersects(Rect2i(0, 0, 40, 40)) and not Rect2i(0, 0, 40, 40).grow(-1).encloses(o.rect()):
			inner.append(o.uid)
	var got := holed.uids_in(l)
	got.sort()
	inner.sort()
	assert_eq(got, inner)


func test_keep_filter() -> void:
	var a := make_obj(db.get_item("t_lamp"), Vector2i(1, 1))
	var b := make_obj(db.get_item("t_lamp"), Vector2i(2, 1))
	var l := _layout([a, b])
	var r := TileRegion.from_rect(Rect2i(0, 0, 5, 5))
	assert_eq(r.uids_in(l, func(u): return u != a.uid), [b.uid])
	assert_eq(TileRegion.rect_uids(l, Rect2i(0, 0, 5, 5), func(u): return u != b.uid), [a.uid])


func test_boundary_edges_follow_the_outline() -> void:
	## A 3x2 rectangle has 2*(3+2) = 10 outside tile edges; an L-shape counts its notch.
	var r := TileRegion.from_rect(Rect2i(0, 0, 3, 2))
	assert_eq(r.boundary_edges().size(), 20, "10 segments = 20 points")
	r.add_rect(Rect2i(0, 2, 1, 2))   # L: 3x2 + 1x2 leg
	assert_eq(r.boundary_edges().size(), 28, "14 segments")
	var hole := TileRegion.from_rect(Rect2i(0, 0, 3, 3))
	hole.remove_rect(Rect2i(1, 1, 1, 1))
	assert_eq(hole.boundary_edges().size(), 32, "12 outside + 4 around the hole")
	# Points are on the iso grid.
	var e := Array(TileRegion.from_rect(Rect2i(2, 3, 1, 1)).boundary_edges())
	assert_has(e, Iso.grid_to_world(Vector2(2, 3)))
	assert_has(e, Iso.grid_to_world(Vector2(3, 4)))


func test_translate_and_footprint_region() -> void:
	var r := TileRegion.from_rect(Rect2i(0, 0, 2, 2))
	r.translate(Vector2i(5, -1))
	assert_eq(r.bounds(), Rect2i(5, -1, 2, 2))
	assert_true(r.has(Vector2i(6, 0)))
	var bak := make_obj(db.get_item("t_bakery"), Vector2i(1, 1))
	var lamp := make_obj(db.get_item("t_lamp"), Vector2i(10, 1))
	var l := _layout([bak, lamp])
	var f := TileRegion.of_footprints(l, [bak.uid, lamp.uid])
	assert_eq(f.size(), 10)
	assert_eq(f.bounds(), Rect2i(1, 1, 10, 3))
	var d := f.duplicate_region()
	d.remove_rect(Rect2i(10, 1, 1, 1))
	assert_eq(f.size(), 10, "duplicates are independent")
	assert_eq(d.size(), 9)


func test_inner_lines() -> void:
	assert_eq(TileRegion.rect_inner_lines(Rect2i(0, 0, 1, 1)).size(), 0)
	assert_eq(TileRegion.rect_inner_lines(Rect2i(0, 0, 3, 2)).size(), (2 + 1) * 2)
