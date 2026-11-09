extends TestCase


func _entry(uid: int, r: Rect2i, height: float = 2.0) -> DepthSorter.Entry:
	# Sprite bounds: the footprint diamond extended upward by `height` tiles.
	var b := Iso.footprint_world_bounds(r.position, r.size)
	var h := height * Iso.Z_UNIT
	b.position.y -= h
	b.size.y += h
	return DepthSorter.Entry.new(uid, r, b)


func _index(order: Array, uid: int) -> int:
	return order.find(uid)


func test_simple_row() -> void:
	var order := DepthSorter.sort([_entry(1, Rect2i(0, 0, 1, 1)), _entry(2, Rect2i(1, 0, 1, 1)), _entry(3, Rect2i(2, 0, 1, 1))])
	assert_eq(order, [1, 2, 3])


func test_elongated_neighbour_regression() -> void:
	# A 1x6 hedge along y next to a 1x1 lamp at larger x: the lamp is in
	# front. A plain centre-depth key draws the lamp first (wrong).
	var hedge := _entry(1, Rect2i(0, 0, 1, 6), 1.0)
	var lamp := _entry(2, Rect2i(1, 0, 1, 1), 2.0)
	assert_true(hedge.key > lamp.key, "precondition: naive key would be wrong")
	var order := DepthSorter.sort([lamp, hedge])
	assert_true(_index(order, 1) < _index(order, 2), "hedge behind lamp")


func test_big_building_and_small_side_object() -> void:
	var big := _entry(1, Rect2i(0, 0, 4, 4), 3.0)
	var small := _entry(2, Rect2i(4, 0, 1, 1), 1.0)
	var order := DepthSorter.sort([small, big])
	assert_true(_index(order, 1) < _index(order, 2))
	var front := _entry(3, Rect2i(0, 4, 1, 1), 1.0)
	order = DepthSorter.sort([front, big, small])
	assert_true(_index(order, 1) < _index(order, 3))


func test_deterministic_regardless_of_input_order() -> void:
	var entries: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var occupied := {}
	var uid := 1
	for i in 200:
		var w := rng.randi_range(1, 4)
		var h := rng.randi_range(1, 4)
		var p := Vector2i(rng.randi_range(0, 40), rng.randi_range(0, 40))
		var r := Rect2i(p, Vector2i(w, h))
		var clash := false
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				if occupied.has(Vector2i(x, y)):
					clash = true
		if clash:
			continue
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				occupied[Vector2i(x, y)] = true
		entries.append(_entry(uid, r, rng.randf_range(0.2, 4.0)))
		uid += 1
	var a := DepthSorter.sort(entries)
	var shuffled := entries.duplicate()
	shuffled.shuffle()
	var b := DepthSorter.sort(shuffled)
	assert_eq(a, b, "same order for shuffled input")
	assert_eq(a.size(), entries.size())
	# Every overlapping pair respects the separation rule.
	var pos := {}
	for i in a.size():
		pos[a[i]] = i
	var violations := 0
	for i in entries.size():
		for j in range(i + 1, entries.size()):
			var ei: DepthSorter.Entry = entries[i]
			var ej: DepthSorter.Entry = entries[j]
			if not ei.bounds.intersects(ej.bounds):
				continue
			var c := DepthSorter.compare(ei, ej)
			if (c < 0) != (pos[ei.uid] < pos[ej.uid]):
				violations += 1
	assert_eq(violations, 0, "pairwise order violations")


func test_empty() -> void:
	assert_eq(DepthSorter.sort([]), [])
