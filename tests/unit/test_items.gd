extends TestCase


func test_fixture_loads_without_errors() -> void:
	var db := fixture_db()
	assert_eq(db.errors.size(), 0, "errors: %s" % str(db.errors))
	assert_eq(db.count(), 7)


func test_item_fields_parsed() -> void:
	var db := fixture_db()
	var b := db.get_item("t_bakery")
	assert_eq(b.footprint, Vector2i(3, 3))
	assert_eq(b.unlock_level, 2)
	assert_eq(b.cost_coins, 50)
	assert_eq(b.cost_diamonds, -1)
	assert_eq(b.max_count, 1)
	assert_true(b.is_footprint_trusted())
	var p := db.get_item("t_path")
	assert_eq(p.layer, "ground")
	assert_eq(p.connect_group, "stone_path")


func test_unknown_footprint_is_flagged_not_guessed() -> void:
	var m := fixture_db().get_item("t_mystery")
	assert_eq(m.footprint_status, "unknown")
	assert_eq(m.footprint, Vector2i(2, 2), "explicit provisional footprint used")
	assert_false(m.is_footprint_trusted())


func test_flip_swaps_footprint() -> void:
	var h := fixture_db().get_item("t_long")
	assert_eq(h.size_for(false), Vector2i(1, 4))
	assert_eq(h.size_for(true), Vector2i(4, 1))


func test_aliases_resolve() -> void:
	var db := fixture_db()
	assert_eq(db.resolve_id("old_fence"), "t_fence")
	assert_not_null(db.get_item("old_fence"))
	assert_eq(db.resolve_id("nope"), "nope")


func test_invalid_records_reported() -> void:
	var errs: Array = []
	assert_null(ItemDef.from_dict({"name": "no id"}, errs))
	assert_eq(errs.size(), 1)
	errs.clear()
	var it := ItemDef.from_dict({"id": "Bad-ID", "footprint": [0, 3]}, errs)
	assert_not_null(it)
	assert_true(errs.size() >= 1, "bad id reported")
	assert_eq(it.footprint_status, "unknown", "zero footprint treated as unknown")


func test_search_relevance_and_filters() -> void:
	var db := fixture_db()
	var r := db.search("fence")
	assert_eq(r.size(), 2)
	r = db.search("stone")
	assert_eq(r[0].id, "t_fence_stone", "name prefix wins over tag/contains")
	r = db.search("", {"category": "decoration"})
	assert_eq(r.size(), 3)
	r = db.search("", {"max_level": 10})
	for it in r:
		assert_true(it.unlock_level <= 10)
	r = db.search("", {"footprint": Vector2i(4, 1)})
	assert_eq(r.size(), 1, "footprint filter matches rotated sizes")
	r = db.search("", {"status": "unverified"})
	assert_eq(r.size(), 1)
	r = db.search("", {}, "level")
	assert_eq(r[0].id, "t_bakery")
	r = db.search("xyzzy")
	assert_eq(r.size(), 0)


func test_duplicate_ids_rejected() -> void:
	var db := fixture_db()
	var n := db.load_file("res://tests/fixtures/items.json")
	assert_eq(n, 0)
	assert_true(db.errors.size() >= 7)


func test_to_dict_roundtrip() -> void:
	var db := fixture_db()
	for it: ItemDef in db.ordered:
		var errs: Array = []
		var back := ItemDef.from_dict(it.to_dict(), errs)
		assert_eq(back.id, it.id)
		assert_eq(back.footprint, it.footprint)
		assert_eq(back.unlock_level, it.unlock_level)
		assert_eq(back.cost_coins, it.cost_coins)
		assert_eq(back.connect_group, it.connect_group)
		assert_eq(back.layer, it.layer)
