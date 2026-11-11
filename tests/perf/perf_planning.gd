extends SceneTree
## Planning-stack benchmark (headless, no App autoload): budget engine, scopes,
## phases, checklist, shopping list, recreation guide and its exports.
##
##   godot --headless --path . --script res://tests/perf/perf_planning.gd [-- --sizes=2000,5000,10000] [--reps=30] [--types=500]
##   (Windows: powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 --script res://tests/perf/perf_planning.gd)
##
## For every size N: N real catalogue items (drawn from a fixed random subset of
## --types placeable item types, up to 3x3) at random spots on the real farm map
## (fixed seed), priced with the real price data (PriceBook.load_default, no user
## overrides), 5 areas (3 rectangles, 2 polygons) and 4 phases, inventory for half
## of the types, a few acquired copies, a baseline (30 % of the objects in place,
## 5 % moved since, 2 % removed from the design) and 10 % marked placed.
## Every case is timed `reps` times after one warm-up: mean / p95 / max in ms.
## "Edit" cases go through CommandStack (one undo step) and include the layout
## signals and the engine refresh (whole-farm totals). "(cold)" = the engine's
## per-version caches dropped first (as right after an edit, without the edit).
## Shopping-list cases run after a one-tile move outside the timed part (as after
## a real edit), wrapped like the Shop tab (engine batch). Timings and sizes only;
## no game data is printed.

var sizes: Array = [2000, 5000, 10000]
var reps := 30
var types := 500
var results := {}       ## case -> {n: [mean, p95, max]}
var order: Array = []   ## case names in first-seen order
var notes := {}         ## case -> {n: String}


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sizes="):
			sizes.clear()
			for s in a.substr(8).split(","):
				sizes.append(int(s))
		elif a.begins_with("--reps="):
			reps = maxi(3, int(a.substr(7)))
		elif a.begins_with("--types="):
			types = maxi(10, int(a.substr(8)))
	var db := ItemDatabase.new()
	db.load_default()
	var pb := PriceBook.load_default(db, "user://__perf_no_overrides__.json")
	var map := FarmMap.load_file("res://data/maps/hayday_farm.json")
	var all_pool: Array[ItemDef] = []
	for it: ItemDef in db.ordered:
		if it.can_place() and it.footprint.x <= 3 and it.footprint.y <= 3 and not it.category in RecreationGuide.SKIP_CATEGORIES:
			all_pool.append(it)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var pool: Array[ItemDef] = []
	var picked := {}
	while pool.size() < mini(types, all_pool.size()):
		var it: ItemDef = all_pool[rng.randi() % all_pool.size()]
		if not picked.has(it.id):
			picked[it.id] = true
			pool.append(it)
	var probe := BudgetEngine.new(FarmLayout.new(), db, pb, map)
	print("Planning benchmark: %d item types in the pool (of %d placeable), %d price records, map %dx%d, %d plots, reps %d, engine batching: %s" % [
		pool.size(), all_pool.size(), pb.price_db_count(), map.size.x, map.size.y, map.plots.size(), reps,
		"begin_batch/end_batch" if probe.has_method("begin_batch") else "auto_detect toggle (PlanUiModels.batch)"])
	probe.dispose()
	for n in sizes:
		_run(n, db, pb, map, pool)
	_print_table()
	quit(0)


# --- fixture -----------------------------------------------------------------------------

func _make_plan(map: FarmMap) -> Dictionary:
	@warning_ignore("integer_division")
	var hx := map.size.x / 2
	@warning_ignore("integer_division")
	var hy := map.size.y / 2
	@warning_ignore("integer_division")
	var qx := hx / 2
	@warning_ignore("integer_division")
	var qy := hy / 2
	var plan := PlanDoc.empty()
	plan["areas"] = [
		{"id": "a1", "name": "North west", "rect": [0, 0, hx, hy]},
		{"id": "a2", "name": "North east", "rect": [hx, 0, hx, hy]},
		{"id": "a3", "name": "South west", "points": [[0, hy], [hx, hy + 6], [hx - 4, map.size.y], [0, map.size.y]]},
		{"id": "a4", "name": "Middle", "rect": [qx, qy, hx, hy]},
		{"id": "a5", "name": "South east", "points": [[hx, hy], [map.size.x, hy + 10], [map.size.x - 8, map.size.y], [hx + 6, map.size.y - 4], [hx + 2, hy + 20]]},
	]
	plan["phases"] = [{"id": "p1", "name": "One", "areas": ["a4"]}, {"id": "p2", "name": "Two", "areas": ["a1"]},
		{"id": "p3", "name": "Three", "areas": ["a2", "a3"]}, {"id": "p4", "name": "Four", "areas": ["a5"]}]
	return plan


static func _new_obj(it: ItemDef, rng: RandomNumberGenerator, map: FarmMap) -> PlacedObject:
	var o := PlacedObject.new()
	o.item_id = it.id
	o.size = it.footprint
	o.origin = Vector2i(rng.randi() % (map.size.x - 3), rng.randi() % (map.size.y - 3))
	return o


func _run(n: int, db: ItemDatabase, pb: PriceBook, map: FarmMap, pool: Array[ItemDef]) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9100 + n
	var layout := FarmLayout.new()
	var objs: Array = []
	for i in n:
		objs.append(_new_obj(pool[rng.randi() % pool.size()], rng, map))
	layout.add_objects(objs)
	var plan := _make_plan(map)
	var bl := {}
	var placed := {}
	var removed_uid := 1000000
	for u in layout.objects.keys():
		var o: PlacedObject = layout.objects[u]
		var r := rng.randf()
		if r < 0.30:
			bl[str(u)] = [o.item_id, o.origin.x, o.origin.y, o.size.x, o.size.y]
		elif r < 0.35:
			bl[str(u)] = [o.item_id, clampi(o.origin.x + rng.randi_range(-4, 4), 0, map.size.x - 3),
				clampi(o.origin.y + rng.randi_range(-4, 4), 0, map.size.y - 3), o.size.x, o.size.y]
		elif r < 0.37:
			var it: ItemDef = pool[rng.randi() % pool.size()]
			bl[str(removed_uid)] = [it.id, rng.randi() % (map.size.x - 3), rng.randi() % (map.size.y - 3), it.footprint.x, it.footprint.y]
			removed_uid += 1
		if rng.randf() < 0.1:
			placed[str(u)] = [o.origin.x, o.origin.y]
	plan["baseline"] = {"name": "perf", "objects": bl}
	plan["placed"] = placed
	var owned := {}
	var acquired := {}
	for it in pool:
		if rng.randf() < 0.5:
			owned[it.id] = rng.randi() % 4
		if rng.randf() < 0.1:
			acquired[it.id] = rng.randi() % 3 + 1
	plan["acquired"] = acquired
	layout.set_planning(PlanDoc.normalize(plan))
	layout.profile["owned"] = owned
	layout.profile["balances"] = {"coins": 2000000, "diamonds": 500, "land_deed": 10, "mallet": 5, "marker_stake": 5}
	var stack := CommandStack.new(layout)
	var eng := BudgetEngine.new(layout, db, pb, map)
	var st := {"keys": layout.objects.keys(), "rows": [], "phase_rows": [], "guide": {}, "cursor": 0, "unplaced": []}
	var refresh := func() -> void: eng.totals(null, BudgetEngine.MODE_TO_BUY)
	refresh.call()
	var info := eng.totals(null, BudgetEngine.MODE_REMAINING)
	print("\nN = %d: %d types, %d unknown-price / %d not-buyable objects (remaining), %d plots needed, %d baseline entries" % [
		layout.objects.size(), info.types, info.unknown_price_objects, info.not_buyable_objects, info.plots.size(), bl.size()])
	var cold := func() -> void: _cold(eng)

	# --- budget -------------------------------------------------------------------------
	var f_full := func() -> void:
		eng.recompute_full()
		refresh.call()
	_t("budget: full recompute + farm totals", n, 10, f_full)
	_t("budget: idle query (nothing changed)", n, reps, func() -> void: eng.status_of(int(st["keys"][1])))
	var f_place := func() -> void:
		stack.execute(EditCommands.AddObjects.new([_new_obj(pool[rng.randi() % pool.size()], rng, map)]))
		refresh.call()
	_t("edit: place 1 object + refresh", n, reps, f_place)
	var f_move := func() -> void:
		var ks: Array = st["keys"]
		stack.execute(EditCommands.MoveObjects.new([ks[rng.randi() % ks.size()]], Vector2i(rng.randi_range(-3, 3), rng.randi_range(1, 3))))
		refresh.call()
	_t("edit: move 1 object + refresh", n, reps, f_move)
	var f_delete := func() -> void:
		var ks: Array = st["keys"]
		var u: int = ks[rng.randi() % ks.size()]
		if layout.objects.has(u):
			stack.execute(EditCommands.RemoveObjects.new([u]))
		refresh.call()
	_t("edit: delete 1 object + refresh", n, reps, f_delete)
	var f_undo := func() -> void:
		stack.undo()
		refresh.call()
	_t("edit: undo + refresh", n, reps, f_undo)
	var f_redo := func() -> void:
		stack.redo()
		refresh.call()
	_t("edit: redo + refresh", n, reps, f_redo)
	st["keys"] = layout.objects.keys()

	# --- scopes ---------------------------------------------------------------------------
	var sel: Array = (st["keys"] as Array).duplicate()
	sel.shuffle()
	sel = sel.slice(0, 500)
	var rect_area := PlanDoc.area(layout.planning, "a4")
	var poly_area := PlanDoc.area(layout.planning, "a5")
	var rect_uids := PlanDoc.objects_in_area(layout, rect_area)
	var poly_uids := PlanDoc.objects_in_area(layout, poly_area)
	_t("totals: whole farm (cached per version)", n, reps, func() -> void: eng.totals(null, BudgetEngine.MODE_REMAINING))
	_t("totals: whole farm (cold)", n, reps, func() -> void: eng.totals(null, BudgetEngine.MODE_REMAINING), cold)
	_t("totals: 500-object selection", n, reps, func() -> void: eng.totals(sel, BudgetEngine.MODE_REMAINING))
	_t("area: rectangle objects_in_area", n, reps, func() -> void: PlanDoc.objects_in_area(layout, rect_area))
	_t("area: rectangle totals", n, reps, func() -> void: eng.totals(rect_uids, BudgetEngine.MODE_REMAINING))
	_note("area: rectangle totals", n, "%d objects" % rect_uids.size())
	_t("area: polygon objects_in_area", n, reps, func() -> void: PlanDoc.objects_in_area(layout, poly_area))
	_t("area: polygon totals", n, reps, func() -> void: eng.totals(poly_uids, BudgetEngine.MODE_REMAINING))
	_note("area: polygon totals", n, "%d objects" % poly_uids.size())
	var f_area := func() -> void:
		eng.area_totals("a4", BudgetEngine.MODE_REMAINING)
		eng.area_totals("a5", BudgetEngine.MODE_REMAINING)
	_t("area: area_totals rect + polygon (cold)", n, reps, f_area, cold)
	if "_areas" in eng:
		var cold_areas := func() -> void:
			_cold(eng)
			(eng.get("_areas") as Dictionary).clear()
		_t("area: area_totals rect + polygon (membership from scratch)", n, reps, f_area, cold_areas)
	var move1 := func() -> void:
		var ks: Array = st["keys"]
		var u: int = ks[rng.randi() % ks.size()]
		if layout.objects.has(u):
			layout.move_objects([u], Vector2i(1, 0) if rng.randf() < 0.5 else Vector2i(-1, 0))
	_t("area: area_totals rect + polygon (after a move)", n, reps, f_area, move1)

	# --- phases -----------------------------------------------------------------------------
	var spend := BudgetEngine.spendable(layout.profile)
	var f_phases := func() -> void:
		for pid in eng.phase_ids():
			eng.phase_totals(pid, BudgetEngine.MODE_REMAINING)
			eng.phase_status(pid)
	_t("phases: totals + status, all phases (cold)", n, reps, f_phases, cold)
	_t("phases: totals + status, all phases (after a move)", n, reps, f_phases, move1)
	_t("phases: affordability (cold)", n, reps, func() -> void: eng.affordability(spend, BudgetEngine.MODE_REMAINING), cold)

	# --- checklist ----------------------------------------------------------------------------
	var unplaced: Array = []
	for u in layout.objects.keys():
		if not (layout.planning["placed"] as Dictionary).has(str(u)):
			unplaced.append(u)
	unplaced.shuffle()
	st["unplaced"] = unplaced
	for k: int in [1, 50]:
		var f_mark := func() -> void:
			var c: int = st["cursor"]
			var us: Array = (st["unplaced"] as Array).slice(c, c + k)
			st["cursor"] = c + k
			var p := PlanDoc.with_placed(layout.planning, layout, us, true)
			stack.execute(EditCommands.SetPlanning.new(layout.planning, p, "Mark placed"))
			eng.totals(null, BudgetEngine.MODE_REMAINING)
			for pid in eng.phase_ids():
				eng.phase_status(pid)
		_t("checklist: mark %d placed (command + engine)" % k, n, reps, f_mark)
	var f_cmd_only := func() -> void:
		var c: int = st["cursor"]
		var us: Array = (st["unplaced"] as Array).slice(c, c + 1)
		st["cursor"] = c + 1
		var p := PlanDoc.with_placed(layout.planning, layout, us, true)
		stack.execute(EditCommands.SetPlanning.new(layout.planning, p, "Mark placed"))
	var f_engine_only := func() -> void:
		eng.totals(null, BudgetEngine.MODE_REMAINING)
		for pid in eng.phase_ids():
			eng.phase_status(pid)
	_t("checklist: mark 1 placed, PlanDoc + SetPlanning only", n, reps, f_cmd_only)
	_t("checklist: mark 1 placed, engine part only", n, reps, f_engine_only, f_cmd_only)
	var f_check := func() -> void:
		_batch(eng, func() -> Variant: return PlanUiModels.checklist(eng, layout, db, layout.planning))
	_t("checklist: Build tab model (PlanUiModels.checklist)", n, 10, f_check, cold)

	# --- per-object loops (what canvas overlays do per redraw) ------------------------------
	var f_loop := func() -> Variant:
		for u: int in layout.objects:
			eng.is_placed(u)
		return null
	_t("overlay: is_placed for every object", n, 5, f_loop)
	_t("overlay: is_placed for every object (batched)", n, 5, func() -> void: _batch(eng, f_loop))
	if eng.has_method("placed_set"):
		var f_set := func() -> void:
			var ps: Dictionary = eng.call("placed_set")
			for u: int in layout.objects:
				ps.has(u)
		_t("overlay: placed_set() lookup for every object", n, reps, f_set)

	# --- shopping list ---------------------------------------------------------------------------
	var nudge := func() -> void:
		var ks: Array = st["keys"]
		var u: int = ks[rng.randi() % ks.size()]
		if layout.objects.has(u):
			layout.move_objects([u], Vector2i(1, 0) if rng.randf() < 0.5 else Vector2i(-1, 0))
		eng.status_of(u)
	var f_shop_raw := func() -> void:
		st["rows"] = ShoppingList.build(eng, null, BudgetEngine.MODE_REMAINING, false)
	var f_shop := func() -> Variant:
		st["rows"] = ShoppingList.build(eng, null, BudgetEngine.MODE_REMAINING, false)
		return null
	_t("shop: build whole farm, after an edit (raw)", n, reps, f_shop_raw, nudge)
	_note("shop: build whole farm, after an edit (raw)", n, "%d rows" % (st["rows"] as Array).size())
	_t("shop: build whole farm, after an edit (batched)", n, reps, func() -> void: _batch(eng, f_shop), nudge)
	_t("shop: build whole farm, unchanged (batched)", n, reps, func() -> void: _batch(eng, f_shop))
	var f_tab_phase := func() -> Variant:
		var uids := eng.phase_uids("p3")
		st["phase_rows"] = ShoppingList.build(eng, uids, BudgetEngine.MODE_REMAINING, false)
		ShoppingList.supply_rows(eng, uids, BudgetEngine.MODE_REMAINING)
		eng.totals(uids, BudgetEngine.MODE_REMAINING).to_dict()
		return null
	_t("shop: Shop tab data, phase p3, after an edit", n, reps, func() -> void: _batch(eng, f_tab_phase), nudge)
	_note("shop: Shop tab data, phase p3, after an edit", n, "%d rows" % (st["phase_rows"] as Array).size())
	var f_tab_farm := func() -> Variant:
		st["rows"] = ShoppingList.build(eng, null, BudgetEngine.MODE_REMAINING, false)
		ShoppingList.supply_rows(eng, null, BudgetEngine.MODE_REMAINING)
		eng.totals(null, BudgetEngine.MODE_REMAINING).to_dict()
		return null
	_t("shop: Shop tab data, whole farm, after an edit", n, reps, func() -> void: _batch(eng, f_tab_farm), nudge)
	var rows: Array = st["rows"]
	_t("shop: sort by cost (shop_sort)", n, reps, func() -> void: PlanUiModels.shop_sort(rows, "cost"))
	_t("shop: filter unfinished + query (shop_filter)", n, reps, func() -> void:
		PlanUiModels.shop_filter(rows, {"unfinished": true, "query": "a"}))
	_t("shop: group view (shop_entries by group)", n, reps, func() -> void: PlanUiModels.shop_entries(rows, "group"))
	_t("shop: ShoppingList.sort_rows by name", n, reps, func() -> void: ShoppingList.sort_rows(rows, "name"))

	# --- guide --------------------------------------------------------------------------------------
	var opts := {"db": db, "baseline": layout.planning.get("baseline")}
	var f_guide := func() -> void:
		st["guide"] = RecreationGuide.build(layout, map, layout.planning, opts)
	_t("guide: RecreationGuide.build", n, 5, f_guide)
	var f_guide2 := func() -> void:
		var o2 := opts.duplicate()
		o2["primary"] = eng.primary_phases()
		RecreationGuide.build(layout, map, layout.planning, o2)
	_t("guide: build with options.primary = engine.primary_phases()", n, 5, f_guide2)
	var guide: Dictionary = st["guide"]
	_note("guide: RecreationGuide.build", n, "%d steps" % (guide["steps"] as Array).size())
	var out_len := {}
	_t("guide: GuideExport.to_html", n, 5, func() -> void: out_len["html"] = GuideExport.to_html(guide, {"title": "Perf"}).length())
	_t("guide: GuideExport.to_csv", n, 5, func() -> void: out_len["csv"] = GuideExport.to_csv(guide).length())
	_t("guide: GuideExport.to_json", n, 5, func() -> void: out_len["json"] = GuideExport.to_json(guide).length())
	for k: String in ["html", "csv", "json"]:
		_note("guide: GuideExport.to_" + k, n, "%d KB" % ceili(int(out_len[k]) / 1024.0))
	print("  engine: %d full recomputes, %d item re-allocations" % [eng.full_recomputes, eng.item_recomputes])
	eng.dispose()
	_run_session(n, layout, db, pb, map, pool, rng)


func _run_session(n: int, layout: FarmLayout, db: ItemDatabase, pb: PriceBook, map: FarmMap, pool: Array[ItemDef],
		rng: RandomNumberGenerator) -> void:
	## What the app recomputes after one edit, through the real EditorSession
	## (command stack, ConflictIndex, the session's BudgetEngine) and PlanContext
	## (App.plan_ctx's models): the Realistic report, the budget chip's data
	## (scope totals + design customization), "Compare with my farm"
	## (Baseline.diff), the readiness card and the Build tab checklist.
	## "after an edit" = one undoable one-tile move through the session first
	## (outside the timed part).
	layout.mode = FarmLayout.MODE_REALISTIC
	var s := EditorSession.new(layout, db, map, pb)
	var ctx := PlanContext.new()
	ctx.bind(s, s.budget, pb, db, map)
	var keys: Array = layout.objects.keys()
	var edit := func() -> void:
		var u: int = keys[rng.randi() % keys.size()]
		if layout.objects.has(u):
			s.execute(EditCommands.MoveObjects.new([u], Vector2i(1, 0) if rng.randf() < 0.5 else Vector2i(-1, 0)))
	_t("realistic: report after an edit (session.analysis)", n, reps, func() -> void: s.analysis(), edit)
	_t("realistic: edit + report (move command, analysis)", n, reps, func() -> void:
		edit.call()
		s.analysis())
	_t("realistic: report, unchanged (cached)", n, reps, func() -> void: s.analysis())
	_t("realistic: analyze from scratch (index conflicts + budget)", n, 10, func() -> void:
		RealisticAnalyzer.analyze(layout, db, map, s.conflict_index.conflicts(), s.budget))
	var chip := func() -> Variant:
		var sc := ctx.scope()
		var t := ctx.scope_totals()
		var sk := ctx.customization()
		return [sc, t, sk.hash()]
	_t("chip: budget chip data after an edit (scope, totals, look)", n, reps, chip, edit)
	_t("chip: budget chip data, unchanged", n, reps, chip)
	_t("compare: Baseline.diff (from scratch)", n, 10, func() -> void: Baseline.diff(layout, layout.planning["baseline"], db))
	ctx.set_compare(true)
	_t("compare: compare_diff after an edit", n, reps, func() -> void: ctx.compare_diff(), edit)
	_t("readiness: card data after an edit", n, reps, func() -> void: ctx.readiness(), edit)
	_t("checklist: Build tab model after an edit (batched)", n, 10, func() -> void:
		_batch(s.budget, func() -> Variant: return PlanUiModels.checklist(s.budget, layout, db, layout.planning)), edit)
	_t("guide: ctx.guide() after an edit", n, 5, func() -> void: ctx.guide(), edit)
	var all_after := func() -> void:
		edit.call()
		s.analysis()
		chip.call()
		ctx.compare_diff()
		ctx.readiness()
	_t("edit: Realistic edit + report + chip + compare + readiness", n, reps, all_after)
	s.dispose()


func _cold(eng: BudgetEngine) -> void:
	## Drop the engine's per-version caches (as right after an edit), without
	## any re-allocation work.
	eng._cache.clear()
	eng._derived_ok = false


func _batch(eng: BudgetEngine, f: Callable) -> Variant:
	## The engine's batching API when present, else the Shop tab's old trick.
	if eng.has_method("batch"):
		return eng.call("batch", f)
	return PlanUiModels.batch(eng, f)


# --- timing -----------------------------------------------------------------------------------

func _t(name: String, n: int, count: int, f: Callable, setup: Variant = null) -> void:
	if setup != null:
		(setup as Callable).call()
	f.call()   # warm-up
	var samples := PackedFloat64Array()
	for i in count:
		if setup != null:
			(setup as Callable).call()
		var t0 := Time.get_ticks_usec()
		f.call()
		samples.append((Time.get_ticks_usec() - t0) / 1000.0)
	samples.sort()
	var total := 0.0
	for s in samples:
		total += s
	var p95 := samples[clampi(ceili(0.95 * samples.size()) - 1, 0, samples.size() - 1)]
	var r := [total / samples.size(), p95, samples[samples.size() - 1]]
	if not results.has(name):
		results[name] = {}
		order.append(name)
	results[name][n] = r
	print("  %-52s mean %8.2f  p95 %8.2f  max %8.2f ms" % [name, r[0], r[1], r[2]])


func _note(name: String, n: int, text: String) -> void:
	if not notes.has(name):
		notes[name] = {}
	notes[name][n] = text


func _print_table() -> void:
	print("\nPERF_PLANNING TABLE (ms: mean / p95 / max)")
	var head := "| Case |"
	var sep := "|---|"
	for n in sizes:
		head += " %s objects |" % _thousands(n)
		sep += "---:|"
	print(head)
	print(sep)
	for name: String in order:
		var line := "| %s |" % name
		for n in sizes:
			var r: Variant = (results[name] as Dictionary).get(n)
			var cell := "–" if r == null else "%s / %s / %s" % [_ms(r[0]), _ms(r[1]), _ms(r[2])]
			if notes.has(name) and (notes[name] as Dictionary).has(n):
				cell += " (%s)" % notes[name][n]
			line += " %s |" % cell
		print(line)


static func _ms(v: float) -> String:
	if v < 0.1:
		return "%.3f" % v
	if v < 10.0:
		return "%.2f" % v
	return "%.1f" % v


static func _thousands(n: int) -> String:
	var s := str(n)
	return s if s.length() <= 3 else s.substr(0, s.length() - 3) + "," + s.substr(s.length() - 3)
