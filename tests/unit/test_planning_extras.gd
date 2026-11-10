extends TestCase
## Object layers (view only), "Can I build this?" (Readiness), area stamps and
## the Accuracy report's count wording.

var db: ItemDatabase
var map: FarmMap
var layout: FarmLayout


func before_each() -> void:
	db = fixture_db()
	map = fixture_map()
	layout = FarmLayout.new()


func _place(id: String, at: Vector2i, flipped: bool = false) -> int:
	return int(layout.add_objects([make_obj(db.get_item(id), at, flipped)])[0])


# --- object layers --------------------------------------------------------------------------

func test_layer_groups() -> void:
	assert_eq(ObjectLayers.group_of_category("decoration"), "decorations")
	assert_eq(ObjectLayers.group_of_category("flowers"), "decorations")
	assert_eq(ObjectLayers.group_of_category("production"), "production")
	assert_eq(ObjectLayers.group_of_category("farm_building"), "production")
	assert_eq(ObjectLayers.group_of_category("animal_home"), "animals")
	assert_eq(ObjectLayers.group_of_category("fruit_tree"), "trees")
	assert_eq(ObjectLayers.group_of_category("bush"), "trees")
	assert_eq(ObjectLayers.group_of_category("fence"), "fences")
	assert_eq(ObjectLayers.group_of_category("path"), "paths")
	assert_eq(ObjectLayers.group_of_category("field"), "other")
	assert_eq(ObjectLayers.group_of_category("no_such_category"), "other")
	assert_eq(ObjectLayers.group_of(db, "t_fence"), "fences")
	assert_eq(ObjectLayers.group_of(db, "unknown_item"), "other", "unknown items are 'other'")
	var ids := ObjectLayers.group_ids()
	assert_eq(ids.size(), ObjectLayers.GROUPS.size())
	for g in ["decorations", "production", "animals", "trees", "fences", "paths"]:
		assert_has(ids, g)


func test_layer_states_normalize() -> void:
	assert_eq(ObjectLayers.normalize(null), {})
	assert_eq(ObjectLayers.normalize({"decorations": "hide", "trees": "dim", "paths": "show", "bogus": "hide", "fences": "blink"}),
		{"decorations": "hide", "trees": "dim"}, "show is the default; unknown groups / states are dropped")
	var st := ObjectLayers.with_state({}, "fences", ObjectLayers.HIDE)
	assert_eq(st, {"fences": "hide"})
	st = ObjectLayers.with_state(st, "fences", ObjectLayers.SHOW)
	assert_true(ObjectLayers.is_all_shown(st))
	assert_eq(ObjectLayers.state_of({"paths": "dim"}, "paths"), ObjectLayers.DIM)
	assert_eq(ObjectLayers.state_of({}, "paths"), ObjectLayers.SHOW)


func test_layer_filter_never_touches_the_layout() -> void:
	var bakery := _place("t_bakery", Vector2i(0, 0))
	var lamp := _place("t_lamp", Vector2i(5, 0))
	var fence := _place("t_fence", Vector2i(6, 0))
	var path := _place("t_path", Vector2i(7, 0))
	var before := LayoutIO.to_dict(layout)
	var f := ObjectLayers.filter(layout, db, {"decorations": "hide", "paths": "dim"})
	assert_eq(f["hidden"], [lamp])
	assert_eq(f["dimmed"], [path])
	assert_false(bakery in f["hidden"] or fence in f["hidden"])
	var c := ObjectLayers.counts(layout, db)
	assert_eq(c["production"], 1)
	assert_eq(c["decorations"], 1)
	assert_eq(c["fences"], 1)
	assert_eq(c["paths"], 1)
	assert_eq(c["animals"], 0)
	assert_eq(LayoutIO.to_dict(layout), before, "filtering is view only")


# --- readiness --------------------------------------------------------------------------------

func _readiness(not_buyable: Dictionary = {}) -> Dictionary:
	var conflicts := PlacementRules.find_conflicts(layout, map)
	var rep := RealisticAnalyzer.analyze(layout, db, map, conflicts)
	return Readiness.build(layout, db, conflicts, rep, not_buyable)


static func _row(r: Dictionary, id: String) -> Dictionary:
	for row: Dictionary in r["rows"]:
		if row["id"] == id:
			return row
	return {}


func test_readiness_ready_design() -> void:
	_place("t_fence", Vector2i(1, 1))
	layout.profile["owned"] = {"t_fence": 1}
	var r := _readiness()
	assert_true(r["ready"])
	assert_eq(r["blocking"], 0)
	assert_eq(r["rows"], [], "nothing to report: %s" % str(r["rows"]))


func test_readiness_rows() -> void:
	layout.mode = FarmLayout.MODE_REALISTIC
	layout.profile["level"] = 5
	var a := _place("t_bakery", Vector2i(0, 0))
	var b := _place("t_bakery", Vector2i(1, 1))        # overlaps a, and a 2nd bakery (max 1)
	var land := _place("t_fence", Vector2i(13, 2))     # on locked plot_a
	var lamp := _place("t_lamp", Vector2i(5, 5))       # unlocks at level 30
	var hedge := _place("t_mystery", Vector2i(7, 5))   # provisional footprint: unverified
	layout.profile["owned"] = {"t_bakery": 2, "t_fence": 1, "t_lamp": 1}
	var r := _readiness({"t_lamp": 1})
	assert_false(r["ready"])
	assert_true(r["realistic"])
	var place := _row(r, Readiness.PLACEMENT)
	assert_eq(place["uids"], [a, b], "the overlap, both objects")
	assert_eq(place["severity"], Readiness.BLOCKING)
	assert_eq(_row(r, Readiness.LOCKED_LAND)["uids"], [land])
	assert_has(str(_row(r, Readiness.LOCKED_LAND)["detail"]), "1 expansion")
	assert_eq(_row(r, Readiness.LEVEL)["uids"], [lamp])
	assert_eq(_row(r, Readiness.OVER_MAX)["uids"], [b], "copies past the maximum")
	assert_eq(_row(r, Readiness.CANT_BUY)["objects"], 1)
	assert_eq(_row(r, Readiness.CANT_BUY)["uids"], [lamp])
	var unv := _row(r, Readiness.UNVERIFIED)
	assert_eq(unv["uids"], [hedge])
	assert_eq(unv["severity"], Readiness.CHECK, "unverified data is a check, not a blocker")
	var inv := _row(r, Readiness.NO_INVENTORY)
	assert_eq(inv["items"], ["t_mystery"], "only the item without an owned entry")
	assert_eq(r["blocking"], 5)
	assert_eq(r["checks"], 2)
	# Row order follows Readiness.ORDER.
	var ids: Array = []
	for row: Dictionary in r["rows"]:
		ids.append(row["id"])
	var order := []
	for id in Readiness.ORDER:
		if id in ids:
			order.append(id)
	assert_eq(ids, order)


func test_readiness_level_only_in_realistic() -> void:
	_place("t_lamp", Vector2i(5, 5))
	layout.profile["level"] = 1
	layout.mode = FarmLayout.MODE_CREATIVE
	var r := _readiness()
	assert_true(_row(r, Readiness.LEVEL).is_empty(), "Creative mode is the sandbox: no level row")
	assert_false(r["realistic"])
	layout.mode = FarmLayout.MODE_REALISTIC
	r = _readiness()
	assert_false(_row(r, Readiness.LEVEL).is_empty())


func test_readiness_fixed_landmark_row() -> void:
	var m := FarmMap.from_data({"format": "hayday-sandbox-map", "schema_version": 2, "id": "lm", "name": "lm", "frame": "game",
		"size": [12, 12], "regions": [{"id": "start", "kind": "buildable", "rects": [[0, 0, 12, 12]]}],
		"landmarks": [{"id": "farmhouse", "name": "Farmhouse", "origin": [4, 4], "footprint": [2, 2], "confidence": "strong"}]})
	map = m
	var o := _place("t_fence", Vector2i(4, 4))
	var r := _readiness()
	var row := _row(r, Readiness.FIXED)
	if m.landmarks.is_empty():
		assert_true(row.is_empty(), "no landmark parsed, no row")
		return
	assert_eq(row["uids"], [o], "objects on a fixed landmark get their own row")
	assert_true(_row(r, Readiness.PLACEMENT).is_empty(), "…not counted again as an ordinary placement problem")


# --- area stamps ------------------------------------------------------------------------------

func test_area_stamp_keeps_relative_positions() -> void:
	var a := _place("t_bakery", Vector2i(2, 2))
	var b := _place("t_fence", Vector2i(6, 3))
	var c := _place("t_long", Vector2i(3, 6), true)
	_place("t_lamp", Vector2i(15, 15))                  # outside the area
	var area := {"id": "a1", "name": "Garden", "rect": [1, 1, 8, 8]}
	var r := StampLibrary.from_area(layout, area, func(_id: String) -> String: return "")
	var st: Dictionary = r["stamp"]
	assert_eq(r["objects"], 3)
	assert_eq(r["dropped"], 0)
	assert_eq(st["name"], "Garden")
	var got := {}
	for e: Dictionary in st["items"]:
		got[e["item"]] = Vector2i(int(e["x"]), int(e["y"]))
	assert_eq(got, {"t_bakery": Vector2i(0, 0), "t_fence": Vector2i(4, 1), "t_long": Vector2i(1, 4)}, "offsets from the group's top corner")
	for e: Dictionary in st["items"]:
		if e["item"] == "t_long":
			assert_true(e["flip"], "orientation kept")
	# Round trip through the file format.
	var back := StampLibrary.parse(JSON.parse_string(StampLibrary.to_text(st)), func(_id: String) -> String: return "")
	assert_eq((back["stamp"]["items"] as Array).size(), 3)
	assert_true(a > 0 and b > 0 and c > 0)


func test_area_stamp_refuses_like_stamps() -> void:
	_place("t_bakery", Vector2i(2, 2))
	_place("t_fence", Vector2i(6, 3))
	var area := {"id": "a1", "name": "Yard", "rect": [0, 0, 10, 10]}
	var r := StampLibrary.from_area(layout, area, func(id: String) -> String: return "Fixed in place" if id == "t_bakery" else "", "My yard")
	assert_eq(r["dropped"], 1)
	assert_eq(r["reason"], "Fixed in place")
	assert_eq((r["stamp"]["items"] as Array).size(), 1)
	assert_eq(r["stamp"]["name"], "My yard")
	var empty := StampLibrary.from_area(layout, {"id": "a2", "name": "Empty", "rect": [15, 15, 2, 2]}, func(_id: String) -> String: return "")
	assert_true((empty["stamp"] as Dictionary).is_empty())
	assert_eq(empty["objects"], 0)


# --- accuracy wording -------------------------------------------------------------------------

func test_accuracy_counts_wording() -> void:
	assert_eq(AccuracyReport._counts_text({"approximation": 52}), "52 approximate")
	assert_eq(AccuracyReport._counts_text({"approximation": 1, "confirmed": 3}), "1 approximate, 3 confirmed")
	assert_eq(AccuracyReport._counts_text({"main": 12}, false, "%d in %s"), "12 in main")
	assert_eq(AccuracyReport._counts_text({}), "none")
	var rep := AccuracyReport.build(map, db, layout)
	var all := AccuracyReport.to_text(rep)
	assert_false(all.contains("approximation 1") or all.contains("approximation 5"), "no 'approximation N' wording left")
