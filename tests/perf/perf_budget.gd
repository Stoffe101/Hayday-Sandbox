extends SceneTree
## BudgetEngine benchmark (headless, no App autoload).
##
##   godot --headless --path . --script res://tests/perf/perf_budget.gd [-- --sizes=2000,5000,10000] [--reps=20]
##
## For every size N: a synthetic layout of N real catalogue items (random
## placeable items up to 3x3 at random spots on the real farm map, fixed seed),
## 4 phases over the map's quadrants, inventory for half of the item types,
## 30 % baseline objects and 10 % marked placed, priced with the real price
## data (PriceBook.load_default). Measures (mean / max ms):
##   * full          recompute_full()
##   * edit_move     move one object + the engine refresh (incremental)
##   * edit_add      add one object + refresh
##   * edit_plan     mark one more item acquired (SetPlanning-style) + refresh
##   * totals_uids   totals over all N uids (no cache)
##   * totals_farm   whole-farm totals right after an edit (cache cleared)
##   * query_idle    a getter with nothing changed (cost of change detection)
##   * query_batch   the same inside engine.begin_batch() / end_batch()
## (tests/perf/perf_planning.gd covers the rest of the planning stack.)
## Timings only; no game data is printed.

var sizes: Array = [2000, 5000, 10000]
var reps := 20


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sizes="):
			sizes.clear()
			for s in a.substr(8).split(","):
				sizes.append(int(s))
		elif a.begins_with("--reps="):
			reps = maxi(3, int(a.substr(7)))
	var db := ItemDatabase.new()
	db.load_default()
	var pb := PriceBook.load_default(db, "user://__perf_no_overrides__.json")
	var map := FarmMap.load_file("res://data/maps/hayday_farm.json")
	var pool: Array[ItemDef] = []
	for it: ItemDef in db.ordered:
		if it.can_place() and it.footprint.x <= 3 and it.footprint.y <= 3:
			pool.append(it)
	print("BudgetEngine benchmark: %d catalogue items in the pool, %d price records, map %dx%d, %d plots" % [
		pool.size(), pb.price_db_count(), map.size.x, map.size.y, map.plots.size()])
	for n in sizes:
		_run(n, db, pb, map, pool)
	quit(0)


func _run(n: int, db: ItemDatabase, pb: PriceBook, map: FarmMap, pool: Array[ItemDef]) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242 + n
	var layout := FarmLayout.new()
	var objs: Array = []
	for i in n:
		var it: ItemDef = pool[rng.randi() % pool.size()]
		var o := PlacedObject.new()
		o.item_id = it.id
		o.size = it.footprint
		o.origin = Vector2i(rng.randi() % (map.size.x - 3), rng.randi() % (map.size.y - 3))
		objs.append(o)
	layout.add_objects(objs)
	var hx := map.size.x / 2
	var hy := map.size.y / 2
	var plan := PlanDoc.empty()
	plan["areas"] = [{"id": "a1", "name": "NW", "rect": [0, 0, hx, hy]}, {"id": "a2", "name": "NE", "rect": [hx, 0, hx, hy]},
		{"id": "a3", "name": "SW", "points": [[0, hy], [hx, hy], [hx, map.size.y], [0, map.size.y]]},
		{"id": "a4", "name": "Middle", "rect": [hx / 2, hy / 2, hx, hy]}]
	plan["phases"] = [{"id": "p1", "name": "One", "areas": ["a4"]}, {"id": "p2", "name": "Two", "areas": ["a1"]},
		{"id": "p3", "name": "Three", "areas": ["a2", "a3"]}]
	var owned := {}
	var bl := {}
	var keys: Array = layout.objects.keys()
	for u in keys:
		var o: PlacedObject = layout.objects[u]
		if rng.randf() < 0.3:
			bl[str(u)] = [o.item_id, o.origin.x, o.origin.y, o.size.x, o.size.y]
		if rng.randf() < 0.1:
			plan["placed"][str(u)] = [o.origin.x, o.origin.y]
	for it in pool:
		if rng.randf() < 0.5:
			owned[it.id] = rng.randi() % 4
	plan["baseline"] = {"name": "perf", "objects": bl}
	layout.set_planning(PlanDoc.normalize(plan))
	layout.profile["owned"] = owned
	var eng := BudgetEngine.new(layout, db, pb, map)
	eng.totals()
	var r := {}
	r["full"] = _time(func() -> void: eng.recompute_full())
	r["edit_move"] = _time(func() -> void:
		var u: int = keys[rng.randi() % keys.size()]
		layout.move_objects([u], Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3)))
		eng.status_of(u))
	r["edit_add"] = _time(func() -> void:
		var it: ItemDef = pool[rng.randi() % pool.size()]
		var o := PlacedObject.new()
		o.item_id = it.id
		o.size = it.footprint
		o.origin = Vector2i(rng.randi() % 100, rng.randi() % 100)
		var u: int = layout.add_objects([o])[0]
		eng.status_of(u))
	r["edit_plan"] = _time(func() -> void:
		var it: ItemDef = pool[rng.randi() % pool.size()]
		var p := PlanDoc.with_acquired(layout.planning, it.id, rng.randi() % 3 + 1)
		layout.set_planning(p)
		eng.status_of(keys[0]))
	var all: Array = layout.objects.keys()
	r["totals_uids"] = _time(func() -> void: eng.totals(all, BudgetEngine.MODE_TO_BUY))
	r["totals_farm"] = _time(func() -> void:
		layout.move_objects([keys[0]], Vector2i(1, 0) if rng.randf() < 0.5 else Vector2i(-1, 0))
		eng.totals(null, BudgetEngine.MODE_REMAINING))
	r["query_idle"] = _time(func() -> void: eng.status_of(keys[1]))
	if eng.has_method("begin_batch"):
		eng.call("begin_batch")
		r["query_batch"] = _time(func() -> void: eng.status_of(keys[1]))
		eng.call("end_batch")
	var t := eng.totals(null, BudgetEngine.MODE_TO_BUY)
	print("\nN = %d objects (%d types, %d unknown-price, %d not-buyable objects, %d plots needed; %d full recomputes)" % [
		layout.objects.size(), t.types, t.unknown_price_objects, t.not_buyable_objects, t.plots.size(), eng.full_recomputes])
	for k in r:
		print("  %-12s mean %7.2f ms   max %7.2f ms" % [k, r[k][0], r[k][1]])
	eng.dispose()


func _time(f: Callable) -> Array:
	f.call()   # warm-up
	var total := 0.0
	var worst := 0.0
	for i in reps:
		var t0 := Time.get_ticks_usec()
		f.call()
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		total += dt
		worst = maxf(worst, dt)
	return [total / reps, worst]
