extends TestCase

var db: ItemDatabase
var map: FarmMap
var layout: FarmLayout


func before_each() -> void:
	db = fixture_db()
	map = fixture_map()
	layout = FarmLayout.new()


func _place(id: String, at: Vector2i, flipped: bool = false) -> PlacedObject:
	var o := make_obj(db.get_item(id), at, flipped)
	layout.add_objects([o])
	return o


func test_map_kinds() -> void:
	assert_eq(map.errors.size(), 0)
	assert_eq(map.kind_at(Vector2i(0, 0)), FarmMap.Kind.BUILDABLE)
	assert_eq(map.kind_at(Vector2i(10, 5)), FarmMap.Kind.ROAD)
	assert_eq(map.kind_at(Vector2i(13, 3)), FarmMap.Kind.PLOT)
	assert_eq(map.plot_id_at(Vector2i(13, 3)), "plot_a")
	assert_eq(map.kind_at(Vector2i(1, 16)), FarmMap.Kind.WATER)
	assert_eq(map.kind_at(Vector2i(-1, 0)), FarmMap.Kind.VOID)
	assert_eq(map.kind_at(Vector2i(20, 0)), FarmMap.Kind.VOID)


func test_plot_geometry_and_adjacency() -> void:
	var a := map.plot("plot_a")
	assert_eq(a["tiles"], 80)
	assert_eq(a["neighbors"], ["plot_b"])
	assert_vec_almost(a["center"], Vector2(16, 5))


func test_valid_placement() -> void:
	var r := PlacementRules.check_item(layout, map, db.get_item("t_bakery"), Vector2i(0, 0), false)
	assert_true(r.ok)
	assert_eq(r.tiles.size(), 9)


func test_collision_detected_with_reason() -> void:
	_place("t_bakery", Vector2i(2, 2))
	var r := PlacementRules.check_item(layout, map, db.get_item("t_bakery"), Vector2i(4, 4), false)
	assert_false(r.ok)
	assert_eq(r.reason_counts.get(PlacementRules.OCCUPIED, 0), 1, "only the corner tile overlaps")
	assert_has(r.message(layout, db, map), "Test Bakery")


func test_adjacent_is_fine() -> void:
	_place("t_bakery", Vector2i(2, 2))
	assert_true(PlacementRules.check_item(layout, map, db.get_item("t_bakery"), Vector2i(5, 2), false).ok)
	assert_true(PlacementRules.check_item(layout, map, db.get_item("t_bakery"), Vector2i(2, 5), false).ok)


func test_out_of_bounds_road_water_locked() -> void:
	var lamp := db.get_item("t_lamp")
	var r := PlacementRules.check_item(layout, map, lamp, Vector2i(-1, 0), false)
	assert_eq(r.primary_reason(), PlacementRules.OUT_OF_BOUNDS)
	r = PlacementRules.check_item(layout, map, lamp, Vector2i(10, 0), false)
	assert_eq(r.primary_reason(), PlacementRules.ROAD)
	r = PlacementRules.check_item(layout, map, lamp, Vector2i(1, 16), false)
	assert_eq(r.primary_reason(), PlacementRules.WATER)
	r = PlacementRules.check_item(layout, map, lamp, Vector2i(14, 4), false)
	assert_eq(r.primary_reason(), PlacementRules.LOCKED_LAND)
	assert_has(r.message(layout, db, map), "Plot A")
	layout.set_unlocked(["plot_a"])
	assert_true(PlacementRules.check_item(layout, map, lamp, Vector2i(14, 4), false).ok, "unlocked plot is buildable")


func test_partial_overlap_marks_individual_tiles() -> void:
	# A 3x3 straddling the road edge: some tiles ok, some road.
	var r := PlacementRules.check_item(layout, map, db.get_item("t_bakery"), Vector2i(8, 0), false)
	assert_false(r.ok)
	var ok_tiles := 0
	for c in r.codes:
		if c == PlacementRules.OK_TILE:
			ok_tiles += 1
	assert_eq(ok_tiles, 6)
	assert_eq(r.reason_counts[PlacementRules.ROAD], 3)


func test_flipped_footprint_collision() -> void:
	_place("t_long", Vector2i(0, 0), true)   # occupies (0..3, 0)
	assert_eq(layout.object_at(Vector2i(3, 0)).item_id, "t_long")
	assert_null(layout.object_at(Vector2i(0, 1)))


func test_group_move_ignores_own_tiles() -> void:
	var a := _place("t_lamp", Vector2i(1, 1))
	var b := _place("t_lamp", Vector2i(2, 1))
	# Shifting both right by one: b moves onto a free tile, a onto b's old tile.
	var r := PlacementRules.check_group_move(layout, map, [a.uid, b.uid], Vector2i(1, 0))
	assert_true(r.ok)
	_place("t_lamp", Vector2i(3, 1))
	r = PlacementRules.check_group_move(layout, map, [a.uid, b.uid], Vector2i(1, 0))
	assert_false(r.ok)


func test_stamp_detects_internal_overlap() -> void:
	var r := PlacementRules.check_stamp(layout, map, [Rect2i(0, 0, 2, 2), Rect2i(1, 1, 2, 2)])
	assert_false(r.ok)
	assert_eq(r.reason_counts[PlacementRules.OCCUPIED], 1)


func test_find_conflicts_after_land_change() -> void:
	layout.set_unlocked(["plot_a"])
	_place("t_lamp", Vector2i(14, 4))
	assert_eq(PlacementRules.find_conflicts(layout, map).size(), 0)
	layout.set_unlocked([])
	assert_eq(PlacementRules.find_conflicts(layout, map).size(), 1, "re-locking land flags, never deletes")
	assert_eq(layout.count(), 1)


func test_unlockable_plots() -> void:
	# Fixture plots are across the road from the start land: neither touches
	# buildable land directly, so only adjacency to unlocked plots counts.
	assert_eq(map.unlockable_plots({}).size(), 0)
	assert_eq(map.unlockable_plots({"plot_a": true}), ["plot_b"])


func test_simple_map_and_land_count() -> void:
	var m := FarmMap.make_simple(5, 4)
	assert_eq(m.buildable_tile_count({}), 20)
	assert_eq(map.buildable_tile_count({}), 200 - 9)
	assert_eq(map.buildable_tile_count({"plot_a": true}), 200 - 9 + 80)
