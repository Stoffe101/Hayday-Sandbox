extends TestCase


func test_exact_integer_delta_is_always_reached() -> void:
	for cur in [Vector2i(0, 0), Vector2i(3, -2), Vector2i(-4, 7)]:
		for want in [Vector2i(0, 0), Vector2i(3, -2), Vector2i(5, 5), Vector2i(-1, 1)]:
			var d := DragMath.hysteresis(Vector2(want), cur)
			# A neighbouring tile is within the band only if |cont - cur| <= 0.62.
			assert_eq(d, want, "from %s to %s" % [str(cur), str(want)])


func test_holds_the_tile_inside_the_band() -> void:
	assert_eq(DragMath.hysteresis_axis(0.55, 0), 0, "just past the boundary")
	assert_eq(DragMath.hysteresis_axis(0.615, 0), 0, "edge of the band")
	assert_eq(DragMath.hysteresis_axis(0.63, 0), 1, "beyond the band")
	assert_eq(DragMath.hysteresis_axis(-0.63, 0), -1, "negative side")
	assert_eq(DragMath.hysteresis_axis(0.45, 1), 1, "coming back: still held")
	assert_eq(DragMath.hysteresis_axis(0.37, 1), 0, "coming back past the band")


func test_big_jumps_land_on_the_nearest_tile() -> void:
	assert_eq(DragMath.hysteresis(Vector2(7.4, -3.6), Vector2i.ZERO), Vector2i(7, -4))


func test_pointer_resting_on_a_boundary_never_flickers() -> void:
	# Pointer trembling +-0.08 tile around a tile boundary (0.5).
	var hyst := 0
	var plain := 0
	var cur := 0
	var last_plain := 0
	for i in 400:
		var c := 0.5 + 0.08 * sin(i * 1.7)
		var n := DragMath.hysteresis_axis(c, cur)
		if n != cur:
			hyst += 1
			cur = n
		var p := roundi(c)
		if p != last_plain:
			plain += 1
			last_plain = p
	assert_eq(hyst, 0, "hysteresis: the object does not change tile")
	assert_true(plain > 50, "plain rounding would flicker (%d changes)" % plain)


func test_offsets_nearest_first() -> void:
	var o := DragMath.offsets_by_distance(3)
	assert_eq(o.size(), 49)
	assert_eq(o[0], Vector2i.ZERO)
	var prev := 0
	for v: Vector2i in o:
		var d := v.x * v.x + v.y * v.y
		assert_true(d >= prev, "sorted by distance")
		prev = d


func test_nearest_valid() -> void:
	var valid := func(d: Vector2i) -> bool: return d == Vector2i(3, 1) or d == Vector2i(4, 4)
	assert_eq(DragMath.nearest_valid(Vector2i(3, 2), 3, valid), Vector2i(3, 1), "closest valid delta")
	assert_eq(DragMath.nearest_valid(Vector2i(3, 1), 3, valid), Vector2i(3, 1), "already valid")
	assert_eq(DragMath.nearest_valid(Vector2i(20, 20), 3, valid), null, "nothing within the radius")


func test_nearest_valid_ties_are_deterministic() -> void:
	var valid := func(d: Vector2i) -> bool: return absi(d.x) + absi(d.y) == 1
	var a: Variant = DragMath.nearest_valid(Vector2i.ZERO, 1, valid)
	var b: Variant = DragMath.nearest_valid(Vector2i.ZERO, 1, valid)
	assert_eq(a, b)
	assert_eq(a, Vector2i(0, -1))
