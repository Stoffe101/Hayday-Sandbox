extends TestCase


func test_grid_world_roundtrip() -> void:
	for g in [Vector2(0, 0), Vector2(3, 7), Vector2(-4.5, 2.25), Vector2(100, 1)]:
		assert_vec_almost(Iso.world_to_grid(Iso.grid_to_world(g)), g, 0.0001, "roundtrip %s" % g)


func test_projection_axes() -> void:
	# +x goes down-right, +y goes down-left, 2:1 ratio.
	assert_vec_almost(Iso.grid_to_world(Vector2(1, 0)), Vector2(32, 16))
	assert_vec_almost(Iso.grid_to_world(Vector2(0, 1)), Vector2(-32, 16))
	assert_vec_almost(Iso.grid_to_world(Vector2(1, 1)), Vector2(0, 32))


func test_world_to_tile_picks_correct_diamond() -> void:
	# Points just inside each corner region of tile (2,3).
	var c := Iso.tile_center(Vector2i(2, 3))
	assert_eq(Iso.world_to_tile(c), Vector2i(2, 3))
	assert_eq(Iso.world_to_tile(c + Vector2(0, -15.5)), Vector2i(2, 3), "near top corner")
	assert_eq(Iso.world_to_tile(c + Vector2(31, 0)), Vector2i(2, 3), "near right corner")
	assert_eq(Iso.world_to_tile(c + Vector2(0, 15.5)), Vector2i(2, 3), "near bottom corner")
	assert_eq(Iso.world_to_tile(c + Vector2(-31, 0)), Vector2i(2, 3), "near left corner")
	# Just across the edges.
	assert_eq(Iso.world_to_tile(c + Vector2(0, -16.5)), Vector2i(1, 2), "above top corner")
	assert_eq(Iso.world_to_tile(c + Vector2(33, 0)), Vector2i(3, 2), "right of right corner")


func test_negative_tiles_floor() -> void:
	assert_eq(Iso.world_to_tile(Iso.tile_center(Vector2i(-3, -1))), Vector2i(-3, -1))


func test_screen_world_roundtrip() -> void:
	var cam := Vector2(120, -40)
	var view := Vector2(1920, 1080)
	for zoom in [0.25, 1.0, 2.5]:
		var s := Vector2(300, 700)
		var w := Iso.screen_to_world(s, cam, zoom, view)
		assert_vec_almost(Iso.world_to_screen(w, cam, zoom, view), s, 0.001)
	# Screen centre maps to camera centre.
	assert_vec_almost(Iso.screen_to_world(view / 2, cam, 3.0, view), cam)


func test_footprint_polygon_and_center() -> void:
	var poly := Iso.footprint_polygon(Vector2i(0, 0), Vector2i(2, 3))
	assert_vec_almost(poly[0], Vector2(0, 0))
	assert_vec_almost(poly[1], Vector2(64, 32))
	assert_vec_almost(poly[2], Vector2(-32, 80))
	assert_vec_almost(poly[3], Vector2(-96, 48))
	assert_vec_almost(Iso.footprint_center(Vector2i(0, 0), Vector2i(2, 2)), Vector2(0, 32))
	var b := Iso.footprint_world_bounds(Vector2i(0, 0), Vector2i(2, 3))
	assert_vec_almost(b.position, Vector2(-96, 0))
	assert_vec_almost(b.size, Vector2(160, 80))


func test_line_and_rect_helpers() -> void:
	var line := Iso.tiles_on_line(Vector2i(2, 2), Vector2i(6, 3))
	assert_eq(line.size(), 5, "dominant x axis")
	assert_eq(line[4], Vector2i(6, 2))
	var vline := Iso.tiles_on_line(Vector2i(2, 5), Vector2i(3, 1))
	assert_eq(vline.size(), 5)
	assert_eq(vline[4], Vector2i(2, 1))
	assert_eq(Iso.rect_from_corners(Vector2i(5, 1), Vector2i(2, 4)), Rect2i(2, 1, 4, 4))
	assert_eq(Iso.tiles_of(Vector2i(1, 1), Vector2i(2, 2)).size(), 4)
