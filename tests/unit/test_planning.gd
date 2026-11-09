extends TestCase
## Connections, realistic-mode analysis and layout diffs.

var db: ItemDatabase
var map: FarmMap
var layout: FarmLayout


func before_each() -> void:
	db = fixture_db()
	map = fixture_map()
	layout = FarmLayout.new()
	# Ownership tests opt out of the friendly default explicitly.
	layout.profile["treat_unknown_as_owned"] = false


func _place(id: String, at: Vector2i) -> PlacedObject:
	var o := make_obj(db.get_item(id), at)
	layout.add_objects([o])
	return o


func test_fence_masks() -> void:
	var c := _place("t_fence", Vector2i(5, 5))
	assert_eq(Connections.mask_for(layout, db, c), 0)
	_place("t_fence", Vector2i(6, 5))   # +x = SE
	_place("t_fence", Vector2i(5, 4))   # -y = NE
	assert_eq(Connections.mask_for(layout, db, c), Connections.SE | Connections.NE)
	assert_eq(Connections.shape_name(Connections.mask_for(layout, db, c)), "corner")
	_place("t_fence_stone", Vector2i(4, 5))   # different group: no join
	assert_eq(Connections.mask_for(layout, db, c), Connections.SE | Connections.NE)
	_place("t_fence", Vector2i(5, 6))
	assert_eq(Connections.shape_name(Connections.mask_for(layout, db, c)), "t_junction")


func test_non_connecting_items_have_zero_mask() -> void:
	var b := _place("t_bakery", Vector2i(0, 0))
	assert_eq(Connections.mask_for(layout, db, b), 0)


func test_best_variant_degrades_gracefully() -> void:
	var avail := {0: true, Connections.NE | Connections.SW: true, Connections.NE: true}
	assert_eq(Connections.best_variant(Connections.NE | Connections.SW, avail), Connections.NE | Connections.SW)
	assert_eq(Connections.best_variant(Connections.NE | Connections.SW | Connections.SE, avail), Connections.NE | Connections.SW, "drops a connection, never invents one")
	assert_eq(Connections.best_variant(Connections.SE, avail), 0)
	assert_eq(Connections.best_variant(Connections.SE, {}), -1)


func test_neighbours_of_rects() -> void:
	var a := _place("t_fence", Vector2i(2, 2))
	_place("t_fence", Vector2i(9, 9))
	var n := Connections.neighbours_of_rects(layout, [Rect2i(3, 2, 1, 1)])
	assert_eq(n, [a.uid])


func test_realistic_flags_level_ownership_and_max() -> void:
	layout.profile["level"] = 10
	layout.profile["owned"] = {"t_bakery": 1}
	_place("t_bakery", Vector2i(0, 0))
	var b2 := _place("t_bakery", Vector2i(4, 0))
	var lamp := _place("t_lamp", Vector2i(0, 5))
	var r := RealisticAnalyzer.analyze(layout, db, map)
	assert_eq(r.required_level, 30)
	assert_eq(r.level_locked.size(), 1)
	assert_has(r.issues[lamp.uid], RealisticAnalyzer.LEVEL_LOCKED)
	assert_eq(r.over_max.size(), 1, "only one bakery allowed")
	assert_has(r.issues[b2.uid], RealisticAnalyzer.OVER_MAX)
	assert_has(r.issues[b2.uid], RealisticAnalyzer.NOT_OWNED)
	assert_eq(r.coins_needed, 50, "one extra bakery at known price")
	assert_eq(r.diamonds_needed, 5, "lamp has a diamond price")
	assert_false(r.can_recreate())


func test_default_profile_assumes_unlisted_items_are_owned() -> void:
	var fresh := FarmLayout.new()
	fresh.profile["level"] = 99
	fresh.add_objects([make_obj(db.get_item("t_long"), Vector2i(0, 0))])
	var r := RealisticAnalyzer.analyze(fresh, db, map)
	assert_eq(r.shortages.size(), 0, "no inventory recorded -> only level/land/max limits apply")
	assert_true(r.can_recreate())


func test_realistic_unknown_cost_not_invented() -> void:
	_place("t_fence", Vector2i(0, 0))
	var r := RealisticAnalyzer.analyze(layout, db, map)
	assert_eq(r.coins_needed, 0)
	assert_has(r.unknown_cost_items, "t_fence")


func test_realistic_land_and_planned() -> void:
	layout.set_unlocked(["plot_a"])
	var o := _place("t_fence", Vector2i(14, 3))
	var p := _place("t_lamp", Vector2i(15, 3))
	p.planned = true
	layout.set_unlocked([])
	var r := RealisticAnalyzer.analyze(layout, db, map)
	assert_eq(r.plots_needed, ["plot_a"])
	assert_has(r.issues[o.uid], RealisticAnalyzer.LOCKED_LAND)
	assert_eq(r.planned_count, 1)
	assert_false(r.issues[p.uid].has(RealisticAnalyzer.LOCKED_LAND), "planned objects aren't blockers")


func test_realistic_budget_and_owned_everything() -> void:
	layout.profile["level"] = 99
	layout.profile["owned"] = {"t_bakery": 1}
	layout.profile["budget_coins"] = 10
	_place("t_long", Vector2i(0, 0))
	var r := RealisticAnalyzer.analyze(layout, db, map)
	assert_false(r.over_budget_coins, "10 coins needed == budget of 10")
	layout.profile["budget_coins"] = 5
	r = RealisticAnalyzer.analyze(layout, db, map)
	assert_true(r.over_budget_coins)
	layout.profile["treat_unknown_as_owned"] = true
	r = RealisticAnalyzer.analyze(layout, db, map)
	assert_true(r.can_recreate())


func test_unverified_and_unknown_items_reported() -> void:
	_place("t_mystery", Vector2i(0, 0))
	var ghost := PlacedObject.new()
	ghost.item_id = "gone"
	ghost.origin = Vector2i(5, 5)
	ghost.missing = true
	layout.add_objects([ghost])
	var r := RealisticAnalyzer.analyze(layout, db, map)
	assert_eq(r.unverified, 1)
	assert_eq(r.unknown_items.get("gone"), 1)


func test_diff() -> void:
	var a := FarmLayout.new()
	var b := FarmLayout.new()
	a.add_objects([make_obj(db.get_item("t_bakery"), Vector2i(0, 0)), make_obj(db.get_item("t_lamp"), Vector2i(5, 5)),
		make_obj(db.get_item("t_fence"), Vector2i(8, 8))])
	b.add_objects([make_obj(db.get_item("t_bakery"), Vector2i(0, 0)), make_obj(db.get_item("t_lamp"), Vector2i(6, 5)),
		make_obj(db.get_item("t_path"), Vector2i(1, 9))])
	var d := LayoutDiff.compare(a, b)
	assert_eq(d.unchanged.size(), 1)
	assert_eq(d.moved.size(), 1)
	assert_eq(d.added.size(), 1)
	assert_eq(d.removed.size(), 1)
	assert_eq(d.item_delta.get("t_fence"), -1)
	assert_eq(d.item_delta.get("t_path"), 1)
	assert_false(d.item_delta.has("t_lamp"))
