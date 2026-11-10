extends TestCase
## Baseline snapshot and before / after diff (uid + item, fungible reuse).

var db: ItemDatabase
var layout: FarmLayout


func before_each() -> void:
	db = fixture_db()
	db.load_file("res://tests/fixtures/planning_items.json")
	db.finalize()
	layout = FarmLayout.new()


func _place(id: String, at: Vector2i, flipped: bool = false) -> int:
	return int(layout.add_objects([make_obj(db.get_item(id), at, flipped)])[0])


func test_snapshot_shape() -> void:
	var a := _place("t_bakery", Vector2i(1, 2))
	var b := _place("t_long", Vector2i(6, 1), true)
	var ghost := make_obj(db.get_item("t_lamp"), Vector2i(9, 9))
	ghost.planned = true
	layout.add_objects([ghost])
	layout.set_unlocked(["plot_b", "plot_a"])
	layout.id = "farm1"
	var s := Baseline.snapshot(layout, "My farm", "", "2026-11-10T08:00:00Z")
	assert_eq(s["name"], "My farm")
	assert_eq(s["taken"], "2026-11-10T08:00:00Z")
	assert_eq(s["source_id"], "farm1")
	assert_eq(s["objects"], {str(a): ["t_bakery", 1, 2, 3, 3], str(b): ["t_long", 6, 1, 4, 1, true]})
	assert_false((s["objects"] as Dictionary).has(str(ghost.uid)), "planned ghosts are not on the real farm")
	assert_eq(s["unlocked_plots"], ["plot_a", "plot_b"])
	assert_true(Baseline.is_valid(s))
	assert_false(Baseline.is_valid({"objects": []}))
	var e := Baseline.entries(s)
	assert_eq(e[b]["rect"], Rect2i(6, 1, 4, 1))
	assert_true(e[b]["flipped"])
	# Malformed records are skipped, not fatal; aliases resolve with a db.
	s["objects"]["x"] = ["t_lamp", 0, 0, 1, 1]
	s["objects"]["77"] = ["t_lamp", "a", 0, 1, 1]
	s["objects"]["78"] = ["old_fence", 3, 3, 1, 1]
	var e2 := Baseline.entries(s, db)
	assert_eq(e2.size(), 3)
	assert_eq(e2[78]["item"], "t_fence")


func test_diff_classifies_by_uid_and_item() -> void:
	var same := _place("t_bakery", Vector2i(0, 0))
	var mover := _place("g_mill", Vector2i(5, 0))
	var turner := _place("t_long", Vector2i(0, 6))
	var gone := _place("t_lamp", Vector2i(9, 9))
	var swapped := _place("g_coop", Vector2i(12, 0))
	var base := Baseline.snapshot(layout, "Before", "", "t")
	layout.move_objects([mover], Vector2i(0, 4))
	layout.set_object_rect(turner, Vector2i(0, 6), Vector2i(4, 1))
	layout.get_obj(turner).flipped = true
	layout.remove_objects([gone, swapped])
	var replacement := make_obj(db.get_item("g_pond"), Vector2i(12, 0))
	replacement.uid = swapped                   # same uid, different item
	layout.add_objects([replacement])
	var added := _place("g_rose", Vector2i(15, 15))
	var d := Baseline.diff(layout, base, db)
	assert_eq(d["status"][same], "unchanged")
	assert_eq(d["status"][mover], "moved")
	assert_eq(d["status"][turner], "moved", "rotating counts as moving")
	assert_eq(d["status"][swapped], "new", "same uid with another item is a new object…")
	assert_eq(d["status"][added], "new")
	assert_eq(d["unchanged"], [same])
	assert_eq(d["moved"], [mover, turner])
	assert_eq(d["new"], [swapped, added])
	var rem := {}
	for e: Dictionary in d["removed"]:
		rem[int(e["uid"])] = str(e["item"])
	assert_eq(rem, {gone: "t_lamp", swapped: "g_coop"}, "…and the baseline object it replaced is removed")
	assert_eq(d["moves"][mover], {"from": Rect2i(5, 0, 3, 3), "to": Rect2i(5, 4, 3, 3)})
	assert_eq(d["items"]["g_coop"]["removed"], 1)
	assert_eq(d["items"]["g_coop"]["freed"], 1, "nothing reuses it: it goes to storage")
	assert_eq(d["items"]["g_pond"]["extra_needed"], 1)
	var t: Dictionary = d["totals"]
	assert_eq([t["baseline"], t["design"], t["unchanged"], t["moved"], t["new"], t["removed"]], [5, 5, 1, 2, 2, 2])


func test_fungible_reuse_counts() -> void:
	var f: Array = []
	for x in 4:
		f.append(_place("t_fence", Vector2i(x, 0)))
	var keep := _place("t_lamp", Vector2i(10, 10))
	var base := Baseline.snapshot(layout, "", "", "t")
	# Design: the 4 old fence pieces are deleted and 6 new ones drawn elsewhere;
	# one lamp more.
	layout.remove_objects(f)
	var nf: Array = []
	for x in 6:
		nf.append(_place("t_fence", Vector2i(x, 5)))
	var lamp2 := _place("t_lamp", Vector2i(12, 12))
	var d := Baseline.diff(layout, base, db)
	var c: Dictionary = d["items"]["t_fence"]
	assert_eq([c["baseline"], c["design"], c["kept"], c["new"], c["removed"]], [4, 6, 0, 6, 4])
	assert_eq(c["reused"], 4, "four new pieces reuse the removed ones (from storage, not bought)")
	assert_eq(c["extra_needed"], 2)
	assert_eq(c["freed"], 0)
	assert_eq((d["reuse"] as Dictionary).size(), 4)
	for nu in d["reuse"]:
		assert_true(int(nu) in nf)
		assert_true(int(d["reuse"][nu]) in f)
	# Nearest first: the new piece at x = 0 reuses the old piece at x = 0.
	assert_eq(int(d["reuse"][nf[0]]), f[0])
	var l: Dictionary = d["items"]["t_lamp"]
	assert_eq([l["baseline"], l["design"], l["unchanged"], l["extra_needed"]], [1, 2, 1, 1])
	assert_eq(d["status"][keep], "unchanged")
	assert_eq(d["status"][lamp2], "new")
	# Fewer copies in the design: the surplus is freed to storage.
	layout.remove_objects(nf.slice(0, 5))
	var d2 := Baseline.diff(layout, base, db)
	assert_eq(d2["items"]["t_fence"]["reused"], 1)
	assert_eq(d2["items"]["t_fence"]["freed"], 3)
	assert_eq((d2["freed"] as Array).size(), 3)


func test_empty_or_missing_baseline() -> void:
	_place("t_lamp", Vector2i(1, 1))
	var d := Baseline.diff(layout, {})
	assert_eq((d["new"] as Array).size(), 1)
	assert_true((d["removed"] as Array).is_empty())
	assert_eq(int(d["totals"]["baseline"]), 0)
