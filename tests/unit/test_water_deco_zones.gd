extends TestCase
## Water-decoration zones (world data "water_deco_zones"): items tagged
## PlacementRules.ZONE_TAG may stand only inside them, every other item keeps
## refusing water and off-grid tiles. Synthetic world: a made-up 20x20 farm
## with a river band west of the grid and two zones in it (one disabled).

var db: ItemDatabase
var map: FarmMap


static func zone_map(with_zones: bool = true) -> FarmMap:
	var d := {"format": "hayday-sandbox-map", "schema_version": 2, "id": "zone_map", "frame": "game", "size": [20, 20],
		"regions": [{"id": "start", "kind": "buildable", "rects": [[0, 0, 20, 20]]},
			{"id": "pond", "kind": "water", "rects": [[0, 15, 3, 3]]}],
		"scenery": [{"id": "river", "kind": "river", "rect": [-6, 0, 6, 20]}],
		"landmarks": [{"id": "farmhouse", "name": "Farmhouse", "origin": [8, 8], "footprint": [3, 3], "confidence": "strong"}]}
	if with_zones:
		d["water_deco_zones"] = [{"id": "near", "name": "Near bank", "rect": [-2, 4, 2, 6], "enabled": true},
			{"id": "far", "name": "Far bank", "rect": [-6, 2, 2, 8]},
			{"id": "off", "name": "Disabled", "rect": [-6, 14, 2, 3], "enabled": false}]
	return FarmMap.from_data(d)


func before_each() -> void:
	db = fixture_db()
	db.add_item(ItemDef.from_dict({"id": "t_duck", "name": "Pearl Duck", "category": "water", "footprint": [1, 1],
		"footprint_status": "confirmed", "tags": ["client_only", PlacementRules.ZONE_TAG], "aliases": ["t_old_duck"]}, []))
	db.add_item(ItemDef.from_dict({"id": "t_lily", "name": "Pearl Lilies", "category": "water", "footprint": [2, 2],
		"footprint_status": "confirmed", "tags": [PlacementRules.ZONE_TAG]}, []))
	db.add_item(ItemDef.from_dict({"id": "t_fountain", "name": "Land Fountain", "category": "water", "footprint": [1, 1],
		"footprint_status": "confirmed"}, []))
	db.finalize()
	map = zone_map()


func _session() -> EditorSession:
	return EditorSession.new(FarmLayout.new(), db, map)


func test_map_parses_zones() -> void:
	assert_true(map.errors.is_empty(), str(map.errors))
	assert_eq(map.water_deco_zones.size(), 3)
	assert_true(map.has_water_deco_zones())
	assert_eq(map.water_deco_zone_at(Vector2i(-1, 4)), 0)
	assert_eq(map.water_deco_zone_at(Vector2i(-5, 9)), 1)
	assert_eq(map.water_deco_zone_at(Vector2i(-5, 15)), -1, "disabled zone")
	assert_eq(map.water_deco_zone_at(Vector2i(0, 4)), -1)
	assert_eq(map.water_deco_zone_rects().size(), 2)
	assert_false(zone_map(false).has_water_deco_zones())
	var bad := FarmMap.from_data({"id": "b", "size": [4, 4], "regions": [], "water_deco_zones": [{"id": "z", "rect": [0, 0, 0, 2]},
		{"id": "y", "rect": [-1, 0, 1, 1]}, {"id": "y", "rect": [-2, 0, 1, 1]}]})
	assert_eq(bad.water_deco_zones.size(), 1, "bad rect and duplicate id dropped")
	assert_eq(bad.errors.size(), 2)
	# Zones widen the default world bounds (no explicit world_bounds).
	assert_true(map.world_bounds.has_point(Vector2i(-6, 2)))


func test_zone_item_ids() -> void:
	var ids := PlacementRules.zone_item_ids(db)
	assert_true(ids.has("t_duck") and ids.has("t_lily") and ids.has("t_old_duck"))
	assert_false(ids.has("t_fountain"), "category water alone is not a zone item")
	assert_true(PlacementRules.is_zone_item(db.get_item("t_duck")))
	assert_false(PlacementRules.is_zone_item(db.get_item("t_lamp")))
	assert_false(PlacementRules.is_zone_item(null))


func test_zone_items_only_inside_zones() -> void:
	var l := FarmLayout.new()
	var duck := db.get_item("t_duck")
	var lily := db.get_item("t_lily")
	assert_true(PlacementRules.check_item(l, map, duck, Vector2i(-1, 5), false).ok, "inside the near zone (off the grid)")
	assert_true(PlacementRules.check_item(l, map, lily, Vector2i(-2, 4), false).ok, "2x2 fills the zone width")
	var half := PlacementRules.check_item(l, map, lily, Vector2i(-1, 4), false)
	assert_false(half.ok, "half outside the zone")
	assert_true(half.reason_counts.has(PlacementRules.WATER_DECO_ZONE))
	for at: Vector2i in [Vector2i(3, 3), Vector2i(1, 16), Vector2i(-4, 5), Vector2i(-5, 15), Vector2i(30, 3)]:
		var r := PlacementRules.check_item(l, map, duck, at, false)
		assert_false(r.ok, "duck at %s" % str(at))
		assert_eq(r.reason_counts.keys(), [PlacementRules.WATER_DECO_ZONE], "only the zone reason at %s" % str(at))
	assert_has(PlacementRules.check_item(l, map, duck, Vector2i(3, 3), false).message(l, db, map), "decoration zones")


func test_land_items_keep_refusing_water_and_zones() -> void:
	var l := FarmLayout.new()
	var lamp := db.get_item("t_lamp")
	var fountain := db.get_item("t_fountain")
	assert_true(PlacementRules.check_item(l, map, lamp, Vector2i(3, 3), false).ok)
	assert_true(PlacementRules.check_item(l, map, fountain, Vector2i(3, 3), false).ok, "untagged water items are land items")
	assert_false(PlacementRules.check_item(l, map, lamp, Vector2i(-1, 5), false).ok, "a zone is no land")
	assert_false(PlacementRules.check_item(l, map, fountain, Vector2i(1, 16), false).ok, "pond water")
	assert_true(PlacementRules.check_item(l, map, fountain, Vector2i(1, 16), false).reason_counts.has(PlacementRules.WATER))


func test_zone_items_collide_with_each_other() -> void:
	var l := FarmLayout.new()
	l.zone_items = PlacementRules.zone_item_ids(db)
	l.add_objects([make_obj(db.get_item("t_duck"), Vector2i(-1, 5))], false)
	var r := PlacementRules.check_item(l, map, db.get_item("t_duck"), Vector2i(-1, 5), false)
	assert_false(r.ok)
	assert_true(r.reason_counts.has(PlacementRules.OCCUPIED))
	assert_true(PlacementRules.check_item(l, map, db.get_item("t_duck"), Vector2i(-2, 5), false).ok)
	assert_true(PlacementRules.find_conflicts(l, map).is_empty())


func test_without_zone_data_nothing_fits() -> void:
	var plain := zone_map(false)
	var l := FarmLayout.new()
	var r := PlacementRules.check_item(l, plain, db.get_item("t_duck"), Vector2i(3, 3), false)
	assert_false(r.ok, "never on land, even without zone data")
	assert_has(r.message(l, db, plain), "this world has none")


func test_session_conflicts_and_undo() -> void:
	var s := _session()
	var l := s.layout
	assert_true(l.zone_items.has("t_duck"), "the session derives zone items from the catalogue")
	var duck := make_obj(db.get_item("t_duck"), Vector2i(-1, 5))
	var lamp := make_obj(db.get_item("t_lamp"), Vector2i(3, 3))
	s.execute(EditCommands.AddObjects.new([duck, lamp]))
	assert_true(s.conflicts().is_empty())
	assert_true(PlacementRules.check_group_move(l, map, [duck.uid], Vector2i(0, 1)).ok, "moving inside the zone")
	assert_false(PlacementRules.check_group_move(l, map, [duck.uid], Vector2i(2, 0)).ok, "moving onto land")
	s.execute(EditCommands.MoveObjects.new([duck.uid], Vector2i(2, 0)))
	assert_true(s.conflicts().has(duck.uid), "a duck on land is a conflict")
	assert_true(s.conflicts()[duck.uid].reason_counts.has(PlacementRules.WATER_DECO_ZONE))
	s.set_mode(FarmLayout.MODE_REALISTIC)
	assert_has(s.analysis().issues.get(duck.uid, []), RealisticAnalyzer.PLACEMENT)
	s.stack.undo()
	assert_true(s.conflicts().is_empty(), "undo puts it back into the zone")
	assert_false(s.analysis().issues.get(duck.uid, []).has(RealisticAnalyzer.PLACEMENT))
	assert_true(PlacementRules.check_object(l, map, duck).ok)
	assert_eq(PlacementRules.find_conflicts(l, map).size(), s.conflicts().size())
	# A catalogue change that drops the tag re-checks: now a land item off the grid.
	db.get_item("t_duck").tags = PackedStringArray()
	s.refresh_catalogue_rules()
	assert_true(s.conflicts().has(duck.uid))


func test_fit_mask_and_stamp_use_zone_flags() -> void:
	var l := FarmLayout.new()
	var rects := [Rect2i(-1, 5, 1, 1), Rect2i(3, 3, 1, 1)]
	assert_eq(LayoutTools.fit_mask(l, map, rects), [false, true], "without flags: land rules")
	assert_eq(LayoutTools.fit_mask(l, map, rects, {}, [true, false]), [true, true])
	assert_eq(LayoutTools.fit_mask(l, map, rects, {}, [true, true]), [true, false])
	assert_true(PlacementRules.check_stamp(l, map, rects, {}, [true, false]).ok)
	assert_false(PlacementRules.check_stamp(l, map, rects, {}, true).ok)
	assert_false(PlacementRules.check_stamp(l, map, rects).ok)


func test_saved_layout_keeps_zone_objects() -> void:
	var l := FarmLayout.new()
	l.map_id = map.id
	l.add_objects([make_obj(db.get_item("t_duck"), Vector2i(-1, 5)), make_obj(db.get_item("t_duck"), Vector2i(4, 4))], false)
	var rep := LayoutIO.LoadReport.new()
	var back := LayoutIO.from_dict(LayoutIO.to_dict(l), db, rep, map)
	assert_eq(back.count(), 2)
	assert_true(back.zone_items.has("t_duck"))
	var origins: Array = []
	for o: PlacedObject in back.objects.values():
		origins.append(o.origin)
	assert_has(origins, Vector2i(-1, 5), "negative (river) coordinates survive a save")
	assert_eq(rep.collisions.size(), 1, "only the duck on land is reported")
	assert_has(str(rep.collisions[0]["reason"]), "decoration zones")


func test_stamp_and_repeat_plans_carry_zone_flags() -> void:
	# Layout tools (stamp / repeat previews, line / outline brush) check water
	# decorations with the zone rule, never the land rule.
	var s := _session()
	var duck := make_obj(db.get_item("t_duck"), Vector2i(-1, 5))
	s.execute(EditCommands.AddObjects.new([duck]))
	var stamp := {"name": "ducks", "size": [1, 2], "items": [{"item": "t_duck", "x": 0, "y": 0}, {"item": "t_lamp", "x": 0, "y": 1}]}
	var plan := s.stamp_plan(stamp, Vector2i(-2, 6))
	assert_eq(plan["zones"], [true, false])
	assert_eq((plan["objs"] as Array).size(), 1, "the duck fits the zone, the lamp does not")
	assert_true(PlacementRules.check_stamp(s.layout, map, plan["rects"], {}, plan["zones"]).codes.has(PlacementRules.OK_TILE))
	s.select([duck.uid], false, false)
	var rep := s.repeat_plan(1, 3, Vector2i.ZERO)
	assert_eq(rep["zones"], [true, true])
	assert_eq((rep["objs"] as Array).size(), 2, "both copies stay inside the zone")
