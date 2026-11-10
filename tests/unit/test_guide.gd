extends TestCase
## Recreation guide: stage / phase / cluster order, move dependencies and swap
## cycles, landmark-relative directions, done state, progress and exports.

var db: ItemDatabase
var map: FarmMap
var layout: FarmLayout


func before_each() -> void:
	db = fixture_db()
	db.load_file("res://tests/fixtures/planning_items.json")
	db.finalize()
	map = guide_map()
	layout = FarmLayout.new()


static func guide_map() -> FarmMap:
	## Synthetic world (made-up geometry): starting land, a road, land across
	## the road, four plots (Far Plot only reachable through Plot A or B), a
	## pond, a river along the west edge and two landmarks.
	return FarmMap.from_data({"format": "hayday-sandbox-map", "schema_version": 2, "id": "guide_map",
		"frame": "game", "size": [30, 30],
		"regions": [
			{"id": "start", "kind": "buildable", "rects": [[0, 0, 20, 20]]},
			{"id": "pond", "kind": "water", "rects": [[0, 16, 2, 3]]},
			{"id": "road", "kind": "road", "rects": [[0, 20, 30, 2]]},
			{"id": "south", "kind": "buildable", "rects": [[10, 22, 20, 8]]},
			{"id": "plot_a", "kind": "plot", "name": "Plot A", "number": 1, "rects": [[20, 0, 6, 10]], "cost": {"land_deed": 3}},
			{"id": "plot_far", "kind": "plot", "name": "Far Plot", "number": 2, "rects": [[26, 0, 4, 10]]},
			{"id": "plot_b", "kind": "plot", "name": "Plot B", "number": 3, "rects": [[20, 10, 10, 10]]},
			{"id": "plot_x", "kind": "plot", "name": "Plot X", "number": 4, "rects": [[0, 22, 10, 8]]},
		],
		"sections": [{"id": "main", "name": "Main", "side": "main", "plots": ["plot_a", "plot_far", "plot_b"]},
			{"id": "over", "name": "Across", "side": "across_road", "plots": ["plot_x"]}],
		"landmarks": [
			{"id": "farmhouse", "name": "Farmhouse", "origin": [8, 8], "footprint": [4, 4], "confidence": "strong"},
			{"id": "newspaper_mailbox", "name": "Mailbox", "origin": [0, 27], "footprint": [1, 1], "confidence": "approximate"},
		],
		"scenery": [{"id": "river", "kind": "river", "name": "River", "rect": [-3, 0, 3, 30]}]})


func _place(id: String, at: Vector2i) -> int:
	return int(layout.add_objects([make_obj(db.get_item(id), at)])[0])


func _scenario() -> Dictionary:
	## Baseline: rock, bench, bakery, lamp. Design: rock and bench gone, bakery
	## moved, lamp unchanged, new buildings / fences / paths / plants / decor,
	## a new bench (reuses the stored one) and a lamp on the Far Plot.
	var ids := {}
	ids["rock"] = _place("g_rock", Vector2i(16, 16))
	ids["bench_old"] = _place("g_bench", Vector2i(2, 2))
	ids["bakery"] = _place("t_bakery", Vector2i(14, 12))
	ids["lamp_old"] = _place("t_lamp", Vector2i(3, 8))
	var plan := PlanDoc.with_baseline(PlanDoc.empty(), Baseline.snapshot(layout, "Real farm", "real", "2026-11-10T00:00:00Z"))
	layout.remove_objects([ids["rock"], ids["bench_old"]])
	layout.move_objects([ids["bakery"]], Vector2i(2, 0))
	layout.set_unlocked(["plot_a", "plot_far"])
	ids["mill"] = _place("g_mill", Vector2i(14, 1))
	ids["coop"] = _place("g_coop", Vector2i(4, 11))
	ids["pond"] = _place("g_pond", Vector2i(17, 5))
	ids["fences"] = [_place("t_fence", Vector2i(0, 12)), _place("t_fence", Vector2i(1, 12)), _place("t_fence", Vector2i(2, 12))]
	ids["fence_p2"] = _place("t_fence", Vector2i(5, 13))
	ids["fence_x"] = _place("t_fence", Vector2i(18, 18))
	ids["paths"] = [_place("t_path", Vector2i(10, 18)), _place("t_path", Vector2i(11, 18))]
	ids["roses"] = [_place("g_rose", Vector2i(6, 6)), _place("g_rose", Vector2i(7, 7))]
	ids["apple"] = _place("g_apple", Vector2i(1, 1))
	ids["lamp_far"] = _place("t_lamp", Vector2i(27, 2))
	ids["bench_new"] = _place("g_bench", Vector2i(6, 2))
	ids["marker"] = _place("g_marker", Vector2i(0, 0))
	plan = PlanDoc.with_area(plan, {"id": "a1", "name": "North", "rect": [13, 0, 7, 8]})
	plan = PlanDoc.with_area(plan, {"id": "a2", "name": "Garden", "rect": [0, 10, 8, 6]})
	plan = PlanDoc.with_phase(plan, {"id": "p1", "name": "Entrance", "areas": ["a1"]})
	plan = PlanDoc.with_phase(plan, {"id": "p2", "name": "Garden", "areas": ["a2"]})
	ids["plan"] = plan
	return ids


func _titles(g: Dictionary) -> Array:
	var out: Array = []
	for s: Dictionary in g["steps"]:
		out.append(str(s["title"]))
	return out


func test_stage_phase_and_cluster_order() -> void:
	var ids := _scenario()
	var g := RecreationGuide.build(layout, map, ids["plan"], {"db": db})
	assert_true(g["has_baseline"])
	assert_eq(g["skipped_markers"], 1, "planning markers get no step")
	assert_eq(_titles(g), [
		"Unlock Plot A (to reach Far Plot)", "Unlock Far Plot",
		"Clear Test Rock",
		"Put Test Bench in storage", "Move Test Bakery",
		"Place Test Mill", "Place Test Pond", "Place Test Coop",
		"Place 3 × Wood Fence", "Place Wood Fence", "Place 2 × Stone Path", "Place Wood Fence",
		"Place Test Apple Tree", "Place 2 × Test Rose",
		"Place Test Bench (from storage)", "Place Lamp"])
	var st: Array = []
	for s: Dictionary in g["steps"]:
		st.append(int(s["stage"]))
	assert_eq(st, [1, 1, 2, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 7])
	var s9: Dictionary = g["steps"][8]
	assert_eq(s9["number"], 9)
	assert_eq(s9["phase"], "p2")
	assert_eq(s9["phase_name"], "Garden")
	assert_eq(s9["uids"], ids["fences"])
	assert_eq(s9["bounds"], Rect2i(0, 12, 3, 1))
	assert_eq(s9["tiles_text"], "tiles X 0–2, Y 12")
	assert_has(s9["description"], "along the river")
	assert_eq(g["steps"][11]["phase"], "", "the unphased fence comes after the Garden phase's fences")
	assert_eq(g["steps"][1]["plot"], "plot_far")
	assert_eq(g["steps"][1]["needed_by"], [ids["lamp_far"]])
	assert_eq(g["steps"][4]["from_tiles_text"], "tiles X 14–16, Y 12–14")
	assert_has(g["steps"][4]["description"], "from tiles X 14–16, Y 12–14")
	for s: Dictionary in g["steps"]:
		assert_false(s["uids"].has(ids["lamp_old"]), "unchanged objects need no step")
		assert_false(str(s["id"]).is_empty())
	# Reordering phases reorders within a stage only.
	var swapped := PlanDoc.with_phase_moved(ids["plan"], "p2", 0)
	var t := _titles(RecreationGuide.build(layout, map, swapped, {"db": db}))
	assert_eq(t.slice(5, 8), ["Place Test Coop", "Place Test Mill", "Place Test Pond"])
	assert_eq(t.slice(0, 5), _titles(g).slice(0, 5))


func test_without_baseline_everything_is_new() -> void:
	var ids := _scenario()
	layout.set_unlocked(["plot_a"])
	var g := RecreationGuide.build(layout, map, ids["plan"], {"db": db, "baseline": {}})
	assert_false(g["has_baseline"])
	var kinds := {}
	for s: Dictionary in g["steps"]:
		kinds[s["kind"]] = true
	assert_false(kinds.has("clear") or kinds.has("store") or kinds.has("move"))
	assert_eq(_titles(g)[0], "Unlock Far Plot", "without a baseline, land comes from the layout's own unlocked plots")
	assert_eq(g["steps"][1]["kind"], "place", "Plot A is already unlocked")
	assert_has(_titles(g), "Place Test Bakery", "the moved bakery is just placed")
	assert_has(_titles(g), "Place Lamp")
	# Without a db: everything is decor, named by id.
	var bare := RecreationGuide.build(layout, map, ids["plan"], {"baseline": {}})
	for s: Dictionary in bare["steps"]:
		assert_true(int(s["stage"]) in [1, 7])


func test_move_dependencies_and_swap_cycle() -> void:
	var a := _place("t_bakery", Vector2i(0, 0))
	var b := _place("g_mill", Vector2i(5, 0))
	var e := _place("g_rose", Vector2i(10, 0))
	var f := _place("g_apple", Vector2i(11, 0))
	var c := _place("g_coop", Vector2i(13, 0))
	var plan := PlanDoc.with_baseline(PlanDoc.empty(), Baseline.snapshot(layout, "", "", "t"))
	layout.set_object_rect(a, Vector2i(5, 0), Vector2i(3, 3))    # swap bakery and mill
	layout.set_object_rect(b, Vector2i(0, 0), Vector2i(3, 3))
	layout.set_object_rect(e, Vector2i(11, 0), Vector2i.ONE)     # rose moves onto the apple tree's spot,
	layout.set_object_rect(f, Vector2i(12, 0), Vector2i.ONE)     # which moves on first
	layout.remove_objects([c])
	var g := RecreationGuide.build(layout, map, plan, {"db": db})
	var kinds: Array = []
	for s: Dictionary in g["steps"]:
		kinds.append(str(s["kind"]))
	assert_eq(_titles(g), ["Put Test Coop in storage", "Move Test Apple Tree", "Move Test Rose",
		"Put Test Mill in storage for now", "Move Test Bakery", "Place Test Mill from storage"])
	assert_eq(kinds, ["store", "move", "move", "store_temp", "move", "place_from_storage"])
	var tmp: Dictionary = g["steps"][3]
	assert_eq(tmp["then_step"], 6)
	assert_eq(tmp["bounds"], Rect2i(5, 0, 3, 3), "stored from where it stands now")
	assert_has(tmp["description"], "step 6")
	assert_eq(g["steps"][5]["bounds"], Rect2i(0, 0, 3, 3))
	# Done state: marking the mill placed completes its storage detour too.
	var placed := PlanDoc.with_placed(plan, layout, [b], true)
	var g2 := RecreationGuide.build(layout, map, placed, {"db": db})
	assert_true(g2["steps"][3]["done"])
	assert_true(g2["steps"][5]["done"])
	assert_false(g2["steps"][0]["done"], "storage steps are ticked by hand")
	assert_eq(g2["steps"][3]["id"], g["steps"][3]["id"], "ids do not depend on progress")


func test_moves_of_one_item_cluster_together() -> void:
	var pieces: Array = []
	for x in 5:
		pieces.append(_place("t_fence", Vector2i(x, 3)))
	var plan := PlanDoc.with_baseline(PlanDoc.empty(), Baseline.snapshot(layout, "", "", "t"))
	layout.move_objects(pieces, Vector2i(1, 0))     # shift the whole run by one tile
	var g := RecreationGuide.build(layout, map, plan, {"db": db})
	assert_eq(_titles(g), ["Move 5 × Wood Fence"])
	assert_eq(g["steps"][0]["uids"], pieces)
	assert_eq(g["steps"][0]["tiles_text"], "tiles X 1–5, Y 3")


func test_landmark_relative_directions() -> void:
	# Farmhouse footprint 8..11 x 8..11, centre (10, 10). 2x2 objects centred
	# on whole tiles; screen dx = gx - gy, dy = (gx + gy) / 2.
	var cases := [
		[Vector2i(14, 4), "right", "2 tiles right of the Farmhouse"],
		[Vector2i(4, 14), "left", "2 tiles left of the Farmhouse"],
		[Vector2i(14, 14), "below", "2 tiles below the Farmhouse"],
		[Vector2i(4, 4), "above", "2 tiles above the Farmhouse"],
		[Vector2i(15, 9), "lower right", "3 tiles to the lower right of the Farmhouse"],
		[Vector2i(9, 15), "lower left", "3 tiles to the lower left of the Farmhouse"],
		[Vector2i(3, 9), "upper left", "3 tiles to the upper left of the Farmhouse"],
		[Vector2i(9, 3), "upper right", "3 tiles to the upper right of the Farmhouse"],
	]
	for cs in cases:
		var loc := RecreationGuide.describe_location(map, layout, Rect2i(cs[0], Vector2i(2, 2)))
		assert_eq(loc["landmark"], "farmhouse")
		assert_eq(loc["direction"], cs[1], "direction for %s" % str(cs[0]))
		assert_eq(loc["text"], str(cs[2]).substr(0, 1).to_upper() + str(cs[2]).substr(1))
		assert_false(loc["approximate"])
	assert_eq(RecreationGuide.screen_direction(Vector2(1, -1)), "right")
	assert_eq(RecreationGuide.screen_direction(Vector2(1, 1)), "below")
	assert_eq(RecreationGuide.screen_direction(Vector2(1, 0)), "lower right", "grid +x is screen down-right")
	assert_eq(RecreationGuide.screen_direction(Vector2(0, 1)), "lower left", "grid +y is screen down-left")
	assert_eq(RecreationGuide.screen_direction(Vector2.ZERO), "")
	var touching := RecreationGuide.describe_location(map, layout, Rect2i(12, 9, 2, 2))
	assert_eq(touching["text"], "Directly to the lower right of the Farmhouse")
	var on := RecreationGuide.describe_location(map, layout, Rect2i(9, 9, 1, 1))
	assert_eq(on["text"], "At the Farmhouse")
	# Approximate landmark, across the road (plot section side), along the river.
	var near_box := RecreationGuide.describe_location(map, layout, Rect2i(0, 24, 2, 2))
	assert_eq(near_box["landmark"], "newspaper_mailbox")
	assert_true(near_box["approximate"])
	assert_has(near_box["text"], "(approximate landmark position)")
	assert_true(near_box["across_road"])
	assert_true(near_box["along_river"])
	assert_has(near_box["text"], "across the road, along the river")
	# Across the road on plain land: the line to the starting land crosses the road.
	assert_true(RecreationGuide.describe_location(map, layout, Rect2i(20, 25, 1, 1))["across_road"])
	assert_false(RecreationGuide.describe_location(map, layout, Rect2i(15, 15, 1, 1))["across_road"])
	# Next to the pond (water tiles) counts as along the river; inland does not.
	assert_true(RecreationGuide.describe_location(map, layout, Rect2i(2, 17, 1, 1))["along_river"])
	assert_false(RecreationGuide.describe_location(map, layout, Rect2i(15, 15, 1, 1))["along_river"])
	# No landmark is invented: a map without landmarks gives only coordinates.
	var bare := FarmMap.make_simple(10, 10)
	assert_eq(RecreationGuide.describe_location(bare, layout, Rect2i(1, 1, 1, 1))["text"], "")
	assert_eq(RecreationGuide.tiles_text(Rect2i(40, 20, 12, 1)), "tiles X 40–51, Y 20")
	assert_eq(RecreationGuide.tiles_text(Rect2i(3, 4, 1, 1)), "tile X 3, Y 4")


func test_done_progress_and_stable_ids() -> void:
	var ids := _scenario()
	var plan: Dictionary = ids["plan"]
	var g := RecreationGuide.build(layout, map, plan, {"db": db})
	var p: Dictionary = g["progress"]
	assert_eq([p["total"], p["completed"], p["current_number"], p["next_number"]], [16, 0, 1, 2])
	assert_eq(p["percent"], 0.0)
	# Tick the first five steps by hand and mark the mill placed.
	for i in 5:
		plan = PlanDoc.with_step_done(plan, str(g["steps"][i]["id"]), true)
	plan = PlanDoc.with_placed(plan, layout, [ids["mill"]], true)
	var g2 := RecreationGuide.build(layout, map, plan, {"db": db})
	for i in g["steps"].size():
		assert_eq(g2["steps"][i]["id"], g["steps"][i]["id"], "step ids survive regeneration")
	var p2: Dictionary = g2["progress"]
	assert_eq([p2["completed"], p2["remaining"], p2["current_number"], p2["next_number"]], [6, 10, 7, 8])
	assert_almost(float(p2["percent"]), 37.5)
	assert_true(g2["steps"][5]["done"], "mill placed")
	assert_false(g2["steps"][8]["done"])
	# Partly placed cluster is not done; all of it is.
	plan = PlanDoc.with_placed(plan, layout, [ids["fences"][0], ids["fences"][1]], true)
	assert_false(RecreationGuide.build(layout, map, plan, {"db": db})["steps"][8]["done"])
	plan = PlanDoc.with_placed(plan, layout, ids["fences"], true)
	assert_true(RecreationGuide.build(layout, map, plan, {"db": db})["steps"][8]["done"])
	var phases: Array = g2["progress"]["phases"]
	assert_eq(phases.map(func(x: Dictionary) -> String: return str(x["phase"])), ["p1", "p2", ""], "build order, Unphased last")
	assert_eq(phases[0]["name"], "Entrance")
	assert_eq(phases[2]["name"], "Unphased")
	assert_eq((g2["progress"]["stages"] as Array).size(), 7)
	# Same input, same output.
	assert_eq(GuideExport.to_json(RecreationGuide.build(layout, map, plan, {"db": db})),
		GuideExport.to_json(RecreationGuide.build(layout, map, plan, {"db": db})))


func test_exports() -> void:
	var ids := _scenario()
	var plan := PlanDoc.with_placed(ids["plan"], layout, [ids["mill"]], true)
	var g := RecreationGuide.build(layout, map, plan, {"db": db})
	var n: int = (g["steps"] as Array).size()
	var opts := {"title": "<Farm & Co>", "generated": "2026-11-10",
		"overview_image": "data:image/png;base64,iVBORw0KGgo=", "phase_images": {"p1": "phase_p1.png", "p2": "javascript:alert(1)"}}
	# JSON parses and keeps every step (rects as [x, y, w, h]).
	var j: Variant = JSON.parse_string(GuideExport.to_json(g, opts))
	assert_true(j is Dictionary)
	assert_eq(j["format"], "hayday-sandbox-guide")
	assert_eq((j["steps"] as Array).size(), n)
	assert_eq(j["steps"][8]["bounds"], [0.0, 12.0, 3.0, 1.0])
	assert_eq(j["title"], "<Farm & Co>")
	# CSV: header + one row per step.
	var csv := GuideExport.to_csv(g)
	var rows := csv.strip_edges().split("\n")
	assert_eq(rows.size(), n + 1)
	assert_eq(rows[0], ",".join(PackedStringArray(GuideExport.CSV_COLUMNS)))
	assert_true(rows[6].begins_with("6,yes,"), rows[6])
	assert_has(csv, "\"tiles X 0–2, Y 12\"", "fields with commas are quoted")
	# HTML: numbered steps, a section per phase with page breaks, safe images.
	var html := GuideExport.to_html(g, opts)
	assert_eq(html.count("<li class=\"step"), n)
	assert_eq(html.count("<section class=\"phase\""), 3)
	assert_has(html, "break-before:page")
	assert_has(html, "&lt;Farm &amp; Co&gt;")
	assert_false(html.contains("<Farm"), "title escaped")
	assert_has(html, "src=\"data:image/png;base64,iVBORw0KGgo=\"")
	assert_has(html, "src=\"phase_p1.png\"")
	assert_false(html.contains("javascript:"), "unsafe image sources are dropped")
	assert_has(html, "value=\"9\"")
	assert_has(html, "&#9745;")
	# Plain text.
	var txt := GuideExport.to_text(g, opts)
	assert_has(txt, "[x] 6. Place Test Mill")
	assert_has(txt, "[ ] 9. Place 3 × Wood Fence")
	assert_has(txt, "1. Unlock land")
	# include_done = false leaves finished steps out.
	assert_eq(GuideExport.to_csv(g, {"include_done": false}).strip_edges().split("\n").size(), n)


# --- fast paths == the first implementation ---------------------------------------------------

static func _ref_clusters(entries: Array, stage: int, kind: String, rect_key: String) -> Array:
	## The first RecreationGuide._clusters() (tile dictionary, script sort).
	var groups := {}
	for e: Dictionary in entries:
		var gk := "%s|%s" % [e["phase"], e["item"]]
		if e.has("delta"):
			gk += "|%d,%d" % [(e["delta"] as Vector2i).x, (e["delta"] as Vector2i).y]
		if not groups.has(gk):
			groups[gk] = []
		groups[gk].append(e)
	var out: Array = []
	var gkeys: Array = groups.keys()
	gkeys.sort()
	for gk in gkeys:
		var list: Array = groups[gk]
		list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["uid"]) < int(b["uid"]))
		var parent: Array = []
		for i in list.size():
			parent.append(i)
		var at := {}
		for i in list.size():
			var r: Rect2i = list[i][rect_key]
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					at[Vector2i(x, y)] = i
		for i in list.size():
			var g: Rect2i = (list[i][rect_key] as Rect2i).grow(1)
			for y in range(g.position.y, g.end.y):
				for x in range(g.position.x, g.end.x):
					var j: Variant = at.get(Vector2i(x, y))
					if j != null and int(j) != i:
						RecreationGuide._union(parent, i, int(j))
		var members := {}
		for i in list.size():
			var root := RecreationGuide._find(parent, i)
			if not members.has(root):
				members[root] = []
			members[root].append(list[i])
		var roots: Array = members.keys()
		roots.sort()
		for root in roots:
			var ms: Array = members[root]
			var us: Array = []
			var b: Rect2i = ms[0]["rect"]
			var fb: Rect2i = ms[0].get("from", ms[0]["rect"])
			var reused := 0
			for m: Dictionary in ms:
				us.append(int(m["uid"]))
				b = b.merge(m["rect"])
				fb = fb.merge(m.get("from", m["rect"]))
				reused += 1 if bool(m.get("reused", false)) else 0
			us.sort()
			var rects: Array = []
			var from_rects: Array = []
			for m: Dictionary in ms:
				rects.append(m["rect"])
				from_rects.append(m.get("from", m["rect"]))
			out.append({"stage": stage, "kind": kind, "phase": str(ms[0]["phase"]), "item": str(ms[0]["item"]),
				"uids": us, "bounds": b, "from_bounds": fb, "rects": rects, "from_rects": from_rects, "reused": reused})
	return out


static func _ref_land_needed(layout: FarmLayout, map: FarmMap, design: Array, owned: Dictionary) -> Dictionary:
	## The first per-tile loop of _land_drafts(): plot id -> uids needing it.
	var needed := {}
	for o: PlacedObject in design:
		var r := o.rect()
		var seen := {}
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var pid := map.plot_id_at(Vector2i(x, y))
				if pid.is_empty() or seen.has(pid) or map.is_plot_unlocked(pid, owned):
					continue
				seen[pid] = true
				if not needed.has(pid):
					needed[pid] = []
				needed[pid].append(o.uid)
	return needed


func _random_entries(rng: RandomNumberGenerator, n: int, with_from: bool) -> Array:
	var out: Array = []
	for i in n:
		var big := rng.randf() < 0.3
		var r := Rect2i(rng.randi_range(-3, 40), rng.randi_range(-3, 25), rng.randi_range(1, 3), rng.randi_range(1, 3))
		var e := {"uid": (i * 7919 + n * 13) % 100003 + 1, "item": ["a", "b", "c"][rng.randi() % (1 if big else 3)],
			"phase": ["", "p1"][rng.randi() % 2], "rect": r, "reused": rng.randf() < 0.2}
		if with_from:
			var d := Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
			e["from"] = Rect2i(r.position - d, r.size)
			e["delta"] = d
		out.append(e)
	return out


func test_clusters_and_order_match_reference() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8128
	var plan := PlanDoc.with_phase(PlanDoc.empty(), {"id": "p1", "name": "One", "areas": []})
	for round in 40:
		var n: int = [3, 12, 30, 90, 200][round % 5]
		var with_from := round % 3 == 0
		var entries := _random_entries(rng, n, with_from)
		for key in (["rect", "from"] if with_from else ["rect"]):
			var got := RecreationGuide._clusters(entries, 5, "place", key)
			var want := _ref_clusters(entries, 5, "place", key)
			assert_eq(got, want, "round %d (%d entries, %s): clusters" % [round, n, key])
			# Order: native key sort == script _lex_less sort.
			var a := RecreationGuide._ordered_clusters(got.duplicate(), plan)
			RecreationGuide._sort_keys(want, plan)
			want.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return RecreationGuide._lex_less(x["_key"], y["_key"]))
			assert_eq(a, want, "round %d: cluster order" % round)
			var order: Array = range(want.size())
			order.sort_custom(func(x: int, y: int) -> bool: return RecreationGuide._lex_less(want[x]["_key"], want[y]["_key"]))
			assert_eq(RecreationGuide._key_order(want), order, "round %d: move order" % round)
	# Degenerate (empty) rects still cluster like the reference.
	var odd := [{"uid": 1, "item": "a", "phase": "", "rect": Rect2i(2, 2, 0, 0)},
		{"uid": 2, "item": "a", "phase": "", "rect": Rect2i(2, 2, 1, 1)}, {"uid": 3, "item": "a", "phase": "", "rect": Rect2i(4, 4, 1, 1)}]
	assert_eq(RecreationGuide._clusters(odd, 7, "place", "rect"), _ref_clusters(odd, 7, "place", "rect"))


func test_location_texts_match_reference() -> void:
	var real := FarmMap.load_file("res://data/maps/hayday_farm.json")
	var rng := RandomNumberGenerator.new()
	rng.seed = 6174
	for m: FarmMap in [map, real]:
		var world := RecreationGuide._world_info(m, layout)
		# The first implementation = the fallbacks taken without the precomputed tables.
		var plain := world.duplicate()
		for k in ["landmark_centers", "road_sum", "water_sum"]:
			plain.erase(k)
		var bad := 0
		for i in 1500:
			var r := Rect2i(rng.randi_range(-4, m.size.x + 2), rng.randi_range(-4, m.size.y + 2), rng.randi_range(1, 6), rng.randi_range(1, 6))
			if RecreationGuide._across_road(m, r, world) != RecreationGuide._across_road(m, r, plain):
				bad += 1
			if RecreationGuide._along_river(m, r, world) != RecreationGuide._along_river(m, r, plain):
				bad += 1
			if RecreationGuide.describe_location(m, layout, r, world) != RecreationGuide.describe_location(m, layout, r, plain):
				bad += 1
		assert_eq(bad, 0, "location helpers == first implementation on %s" % m.id)
		assert_true(world.has("road_sum") and world.has("water_sum"))


func test_land_and_primary_option_match_reference() -> void:
	var real := FarmMap.load_file("res://data/maps/hayday_farm.json")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1729
	var items := ["t_fence", "t_path", "g_rose", "t_lamp", "g_bench", "t_bakery", "g_mill"]
	for m: FarmMap in [map, real]:
		layout = FarmLayout.new()
		for i in 120:
			var o := make_obj(db.get_item(items[rng.randi() % items.size()]), Vector2i(rng.randi_range(-2, m.size.x), rng.randi_range(-2, m.size.y)))
			layout.add_objects([o])
		layout.set_unlocked(m.plots.slice(0, 3).map(func(p: Dictionary) -> String: return str(p["id"])))
		var design: Array = layout.objects.values()
		var owned := m.canonical_unlocked(layout.unlocked_plots)
		var want := _ref_land_needed(layout, m, design, owned)
		var got := {}
		for d: Dictionary in RecreationGuide._land_drafts(layout, m, PlanDoc.empty(), design, {}, false, {}):
			if not (d["needed_by"] as Array).is_empty():
				got[d["plot"]] = d["needed_by"]
		var want_sorted := {}
		for pid in want:
			var l: Array = want[pid].duplicate()
			l.sort()
			want_sorted[pid] = l
		assert_eq(got, want_sorted, "plots needed on %s" % m.id)
		var plan := PlanDoc.empty()
		plan = PlanDoc.with_area(plan, {"id": "a1", "name": "A", "rect": [0, 0, 12, 12]})
		plan = PlanDoc.with_area(plan, {"id": "a2", "name": "B", "points": [[10, 0], [30, 5], [14, 20]]})
		plan = PlanDoc.with_phase(plan, {"id": "p1", "name": "One", "areas": ["a2"]})
		plan = PlanDoc.with_phase(plan, {"id": "p2", "name": "Two", "areas": ["a1"]})
		layout.set_planning(plan)
		var eng := BudgetEngine.new(layout, db, null, m)
		var a := RecreationGuide.build(layout, m, plan, {"db": db})
		var b := RecreationGuide.build(layout, m, plan, {"db": db, "primary": eng.primary_phases()})
		eng.dispose()
		assert_eq(GuideExport.to_json(b), GuideExport.to_json(a), "options.primary gives the same guide on %s" % m.id)