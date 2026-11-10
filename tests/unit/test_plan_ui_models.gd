extends TestCase
## PlanUiModels: the pure view-models behind the Plan tabs and planning dialogs
## (shopping list view, checklist aggregation, guide progress and ticks,
## inventory rows, price override preview). Synthetic fixtures only.

const Fx := preload("res://tests/unit/test_budget.gd")
const M := preload("res://src/ui/plan/plan_ui_models.gd")
const TO_BUY := BudgetEngine.MODE_TO_BUY
const REMAINING := BudgetEngine.MODE_REMAINING

var db: ItemDatabase
var pb: PriceBook
var layout: FarmLayout
var eng: BudgetEngine


func before_each() -> void:
	db = Fx.make_db()
	db.load_file("res://tests/fixtures/planning_items.json")
	db.finalize()
	pb = Fx.make_prices(db)
	layout = FarmLayout.new()
	eng = BudgetEngine.new(layout, db, pb, fixture_map())


func after_each() -> void:
	eng.dispose()


func _place(id: String, at: Vector2i, planned: bool = false) -> int:
	var o := make_obj(db.get_item(id), at)
	o.planned = planned
	return layout.add_objects([o])[0]


func _row(rows: Array, item: String) -> Dictionary:
	for r in rows:
		if r["item"] == item:
			return r
	return {}


func _setup_shop() -> void:
	var p := layout.profile.duplicate(true)
	p["owned"] = {"t_long": 1, "t_fence": 0, "t_prize": 0, "t_bakery": 0, "t_voucher": 0}
	p["level"] = 10
	layout.profile = p
	for x in 4:
		_place("t_long", Vector2i(x, 0))
	for x in 5:
		_place("t_fence", Vector2i(x, 5))
	_place("t_prize", Vector2i(0, 8))
	_place("t_voucher", Vector2i(6, 8))
	_place("t_lamp", Vector2i(8, 8))       # no owned entry, no price
	layout.set_planning(PlanDoc.with_acquired(layout.planning, "t_long", 1))


# --- text helpers ------------------------------------------------------------------------------

func test_cost_words_keep_currencies_apart() -> void:
	assert_eq(M.cost_words({"coins": 150000, "diamonds": 90}), "150,000 coins and 90 diamonds")
	assert_eq(M.cost_words({"coins": 1}), "1 coin")
	assert_eq(M.cost_words({"coins": 5, "diamonds": 2, "voucher_green": 3}), "5 coins, 2 diamonds and 3 green vouchers")
	assert_eq(M.cost_words({}), "nothing")
	assert_eq(M.cost_words(null), "unknown", "unknown is never 0")


func test_totals_text_counts_unknowns() -> void:
	var t := {"cost": {"coins": 150000, "diamonds": 90}, "charged_objects": 20, "unknown_price_objects": 12,
		"not_buyable_objects": 1, "unknown_ownership_types": ["a", "b"], "unknown_cost_plots": [], "plots": []}
	var s := M.totals_text(t)
	assert_true(s.begins_with("Known cost: 150,000 coins and 90 diamonds."), s)
	assert_true(s.contains("12 items have unknown prices."), s)
	assert_true(s.contains("1 item can't be bought"), s)
	assert_true(s.contains("2 item types without a recorded inventory are counted as to buy"), s)
	var one := M.totals_text({"cost": {}, "charged_objects": 1, "unknown_price_objects": 1})
	assert_true(one.contains("Known cost: nothing yet.") and one.contains("1 item has an unknown price."), one)
	assert_eq(M.totals_text({"cost": {}, "charged_objects": 0}), "Nothing left to pay for.")


func test_safe_file_stem_and_guide_image_names() -> void:
	assert_eq(M.safe_file_stem("My Farm: Spring/2026"), "My_Farm__Spring_2026")
	assert_eq(M.safe_file_stem("..hidden"), "hidden")
	assert_eq(M.safe_file_stem("   "), "farm")
	var n := M.guide_image_names("Farm guide", ["p1", ""])
	assert_eq(n["overview"], "Farm_guide_overview.png")
	assert_eq(n["phases"]["p1"], "Farm_guide_phase_1.png")
	assert_eq(n["phases"][""], "Farm_guide_phase_2.png")
	# GuideExport accepts these names as relative pictures.
	var html := GuideExport.to_html({"steps": [], "progress": {}}, {"overview_image": n["overview"]})
	assert_true(html.contains("src=\"Farm_guide_overview.png\""), "relative picture kept")


func test_batch_restores_auto_detect() -> void:
	_place("t_long", Vector2i(0, 0))
	assert_true(eng.auto_detect)
	var seen: Array = []
	var out: Variant = M.batch(eng, func() -> Variant:
		seen.append(eng.auto_detect)
		return eng.totals(null, TO_BUY).objects)
	assert_eq(out, 1)
	assert_eq(seen, [false], "paused inside")
	assert_true(eng.auto_detect, "restored")
	# In-place edits made before the batch are still detected by its first sync.
	layout.profile["owned"] = {"t_long": 1}
	var st: Variant = M.batch(eng, func() -> Variant: return eng.status_of(1))
	assert_eq(st, BudgetEngine.STATUS_OWNED)


# --- shopping list view -------------------------------------------------------------------------

func test_scope_options_and_uids() -> void:
	layout.set_planning(Fx.two_phase_plan())
	var a := _place("t_long", Vector2i(1, 1))
	var b := _place("t_long", Vector2i(6, 1))
	var opts := M.scope_options(layout.planning, 2)
	var keys: Array = opts.map(func(o: Dictionary) -> String: return str(o["key"]))
	assert_eq(keys, ["farm", "selection", "phase:p1", "phase:p2", "area:a1", "area:a2"])
	assert_true(str(opts[1]["label"]).contains("2 objects"))
	assert_null(M.scope_uids(eng, opts[0], []), "whole farm = null")
	assert_eq(M.scope_uids(eng, opts[1], [b]), [b])
	assert_eq(M.scope_uids(eng, opts[2], []), [a])
	assert_eq(M.scope_uids(eng, opts[5], []), [b])


func test_shop_filter_sort_and_groups() -> void:
	_setup_shop()
	var rows := ShoppingList.build(eng, null, REMAINING, false)
	assert_eq(M.shop_filter(rows, {"cant_buy": true}).map(func(r): return r["item"]), ["t_prize"])
	var unk: Array = M.shop_filter(rows, {"unknown_price": true}).map(func(r): return r["item"])
	assert_eq(unk, ["t_fence"], "copies past the price table are unknown")
	assert_false("t_prize" in unk, "can't buy is not 'price unknown'")
	var unfinished := M.shop_filter(rows, {"unfinished": true})
	for r in unfinished:
		assert_true(int(r["missing"]) > 0)
	assert_eq(M.shop_filter(rows, {"query": "fence"}).size(), 1)
	assert_eq(M.shop_filter(rows, {"cant_buy": true, "unknown_price": true}).size(), 0, "filters combine with AND")
	# Grouped entries: a header per group, followed by its rows, in group order.
	var e := M.shop_entries(rows, "group")
	assert_eq(e[0]["type"], "group")
	var groups: Array = e.filter(func(x): return x["type"] == "group").map(func(x): return x["group"])
	assert_eq(groups, ["Decorations", "Fences", "Trees"])
	var n_rows := e.filter(func(x): return x["type"] == "row").size()
	assert_eq(n_rows, rows.size())
	var fences: Dictionary = e.filter(func(x): return x["type"] == "group" and x["group"] == "Fences")[0]
	assert_eq(fences["total"], {"coins": 5 + 7 + 9}, "known part only: copies 4 and 5 are unknown")
	assert_true(str(fences["text"]).contains("2 with unknown price"), str(fences["text"]))
	# Flat sorts.
	var by_name: Array = M.shop_entries(rows, "name").map(func(x): return x["row"]["name"])
	var sorted := by_name.duplicate()
	sorted.sort_custom(func(a, b): return str(a).naturalnocasecmp_to(str(b)) < 0)
	assert_eq(by_name, sorted)
	var by_missing: Array = M.shop_entries(rows, "missing").map(func(x): return int(x["row"]["missing"]))
	for i in range(1, by_missing.size()):
		assert_true(by_missing[i - 1] >= by_missing[i], "most missing first")
	var by_level: Array = M.shop_sort(rows, "level")
	assert_eq(by_level[by_level.size() - 1]["unlock_level"], -1, "unknown level last")
	var by_cost: Array = M.shop_sort(rows, "cost")
	assert_eq(by_cost.map(func(r): return r["item"]).slice(0, 3), ["t_long", "t_fence", "t_lamp"], "coins first, dearest first, then diamonds")


func test_row_texts_and_badges() -> void:
	_setup_shop()
	var rows := ShoppingList.build(eng, null, REMAINING, false)
	var fence := _row(rows, "t_fence")
	assert_eq(M.row_price_text(fence), "5 coins, later copies: price unknown")
	assert_eq(M.row_total_text(fence), "21 coins + 2 with unknown price")
	var long := _row(rows, "t_long")
	assert_eq(M.row_price_text(long), "20–25 coins (rises per copy)", "copies 3 and 4 (1 owned, 1 bought)")
	assert_eq(M.row_total_text(long), "45 coins")
	assert_eq(M.row_counts_text(long), "Used 4 · owned 1 · bought 1 · still needed 2")
	var prize := _row(rows, "t_prize")
	assert_eq(M.row_price_text(prize), "Can't be bought: derby reward")
	assert_eq(M.row_total_text(prize), "1 can't be bought")
	var lamp := _row(rows, "t_lamp")
	assert_eq(M.row_counts_text(lamp), "Used 1 · owned ? · bought 0 · still needed 1", "unknown ownership shown as ?")
	var lb := M.row_badges(lamp, 10)
	assert_eq(lb[0], ["Level 30", "danger"], "unlock level above the farm level is red")
	assert_has(lb, ["Unverified", "warn"])
	assert_eq(M.row_badges(lamp, 40)[0], ["Level 30", "faint"])
	assert_has(M.row_badges(prize, 10), ["Can't buy", "warn"])
	assert_has(M.row_badges(fence, 10), ["Price unknown", "danger"])
	assert_false(M.row_badges(fence, 10).has(["Community data", "info"]), "no confidence badge on an unknown price")
	assert_has(M.row_badges(long, 10), ["Community data", "info"])
	assert_eq(M.row_counts_text(_row(rows, "t_voucher")), "Used 1 · owned 0 · bought 0 · still needed 1")


func test_shop_csv_keeps_unknown_visible() -> void:
	_setup_shop()
	var rows := ShoppingList.build(eng, null, REMAINING, false)
	var csv := M.shop_csv(rows, [{"item": "land_deed", "name": "Land deeds", "needed": 3, "have": 1, "have_known": true, "missing": 2}])
	var lines := csv.strip_edges().split("\n")
	assert_eq(lines.size(), rows.size() + 2)
	assert_true(lines[0].begins_with("group,item_id,name,used,owned,bought,still_needed"))
	var lamp := ""
	for l in lines:
		if l.contains("t_lamp"):
			lamp = l
	assert_true(lamp.contains(",unknown,"), lamp)
	assert_false(lamp.contains(",0 coins"), "never a zero price")
	assert_true(csv.contains("\"Can't be bought: derby reward\"") or csv.contains("Can't be bought: derby reward"))
	assert_true(lines[lines.size() - 1].begins_with("Expansion supplies,land_deed,Land deeds,3,1,,2"))


func test_supply_text() -> void:
	assert_eq(M.supply_text({"item": "land_deed", "name": "Land deeds", "needed": 6, "have": 1, "have_known": true, "missing": 5}),
		"Land deeds: need 6, have 1 → 5 more")
	assert_eq(M.supply_text({"item": "mallet", "name": "Mallets", "needed": 2, "have": 0, "have_known": false, "missing": 2}),
		"Mallets: need 2, have ? → 2 more")
	assert_true(M.supply_text({"item": "", "unknown_plots": ["a", "b"]}).contains("2 plots"))


# --- construction checklist ------------------------------------------------------------------------

func test_object_states_match_engine() -> void:
	layout.set_planning(Fx.two_phase_plan())
	var p := layout.profile.duplicate(true)
	p["owned"] = {"t_long": 1}
	layout.profile = p
	var u: Array = []
	for x in 4:
		u.append(_place("t_long", Vector2i(x, 0)))
	u.append(_place("t_long", Vector2i(6, 0)))
	var plan := PlanDoc.with_acquired(layout.planning, "t_long", 1)
	plan = PlanDoc.with_placed(plan, layout, [u[3]], true)
	layout.set_planning(plan)
	var states := M.object_states(eng, layout, db, layout.planning)
	var placed := M.placed_uids(layout, layout.planning, db)
	for uid in u:
		assert_eq(placed.has(uid), eng.is_placed(uid), "placed rule == engine for %d" % uid)
		var expect := M.ST_PLACED if eng.is_placed(uid) else (M.ST_NOT_ACQUIRED if eng.status_of(uid) == BudgetEngine.STATUS_TO_BUY else M.ST_ACQUIRED)
		assert_eq(states[uid], expect, "state of %d" % uid)
	assert_eq(states[u[0]], M.ST_ACQUIRED, "owned copy")
	assert_eq(states[u[1]], M.ST_ACQUIRED, "acquired copy")
	assert_eq(states[u[2]], M.ST_NOT_ACQUIRED)
	assert_eq(states[u[3]], M.ST_PLACED)


func test_baseline_objects_count_as_placed() -> void:
	var a := _place("t_long", Vector2i(0, 0))
	var b := _place("t_long", Vector2i(2, 0))
	layout.set_planning(PlanDoc.with_baseline(layout.planning, Baseline.snapshot(layout, "real")))
	layout.move_objects([b], Vector2i(0, 5))
	var placed := M.placed_uids(layout, layout.planning, db)
	assert_true(placed.has(a), "unchanged baseline object")
	assert_false(placed.has(b), "moved baseline object is not placed yet")
	assert_eq(placed.has(a), eng.is_placed(a))
	assert_eq(placed.has(b), eng.is_placed(b))


func test_checklist_per_phase_and_group() -> void:
	layout.set_planning(Fx.two_phase_plan())
	var p := layout.profile.duplicate(true)
	p["owned"] = {"t_long": 2, "t_fence": 0}
	layout.profile = p
	var l1 := _place("t_long", Vector2i(0, 0))
	var l2 := _place("t_long", Vector2i(2, 0))
	var f1 := _place("t_fence", Vector2i(1, 6))
	var f2 := _place("t_fence", Vector2i(6, 6))
	var marker := _place("g_marker", Vector2i(7, 7))
	var out := _place("t_path", Vector2i(15, 15))   # outside every area: Unphased
	layout.set_planning(PlanDoc.with_placed(layout.planning, layout, [l1], true))
	var cl := M.checklist(eng, layout, db, layout.planning)
	var phases: Array = cl["phases"]
	assert_eq(phases.map(func(x): return x["phase"]), ["p1", "p2", ""])
	var p1: Dictionary = phases[0]
	assert_eq(p1["total"], 3)
	assert_eq(p1[M.ST_PLACED], 1)
	assert_eq(p1[M.ST_ACQUIRED], 1)
	assert_eq(p1[M.ST_NOT_ACQUIRED], 1)
	assert_eq(p1["groups"].map(func(g): return g["group"]), ["Decorations", "Fences"])
	assert_eq(p1["open_uids"], [l2, f1])
	assert_eq(p1["status"], BudgetEngine.PHASE_IN_PROGRESS)
	var p2: Dictionary = phases[1]
	assert_eq(p2["total"], 1, "the planning marker is not a game object")
	assert_eq(p2["uids"], [f2])
	assert_eq(cl["skipped"], 1)
	assert_eq(phases[2]["uids"], [out])
	var ov: Dictionary = cl["overall"]
	assert_eq(ov["total"], 5)
	assert_eq(int(ov[M.ST_PLACED]) + int(ov[M.ST_ACQUIRED]) + int(ov[M.ST_NOT_ACQUIRED]), 5, "states add up")
	assert_almost(float(ov["percent"]), 20.0)
	assert_eq(M.counts_text(p1), "1 not acquired · 1 to place · 1 of 3 placed")
	assert_false(marker in ov["uids"])
	# Filter: fully placed groups / phases disappear.
	layout.set_planning(PlanDoc.with_placed(layout.planning, layout, [f2], true))
	var fin := M.filter_unfinished(M.checklist(eng, layout, db, layout.planning))
	assert_eq(fin["phases"].map(func(x): return x["phase"]), ["p1", ""])
	assert_eq(fin["phases"][0]["groups"].map(func(g): return g["group"]), ["Decorations", "Fences"])


func test_moved_since_marked_placed() -> void:
	var a := _place("t_long", Vector2i(0, 0))
	var b := _place("t_long", Vector2i(2, 0))
	layout.set_planning(PlanDoc.with_placed(layout.planning, layout, [a, b], true))
	assert_eq(M.moved_since_placed(layout, layout.planning), [])
	layout.move_objects([b], Vector2i(1, 0))
	assert_eq(M.moved_since_placed(layout, layout.planning), [b])
	assert_eq(M.checklist(eng, layout, db, layout.planning)["moved"], [b])
	# Marking it placed again remembers the new spot.
	layout.set_planning(PlanDoc.with_placed(layout.planning, layout, [b], true))
	assert_eq(M.moved_since_placed(layout, layout.planning), [])


# --- recreation guide -----------------------------------------------------------------------------

func _guide() -> Dictionary:
	return RecreationGuide.build(layout, fixture_map(), layout.planning, {"db": db})


func test_plan_with_step_marks_objects_or_ticks() -> void:
	layout.set_planning(Fx.two_phase_plan())
	var a := _place("g_mill", Vector2i(0, 0))
	var b := _place("g_rose", Vector2i(6, 0))
	var g := _guide()
	var steps: Array = g["steps"]
	assert_eq(steps.size(), 2)
	var s0: Dictionary = steps[0]
	assert_false(M.step_is_manual(s0))
	var p := M.plan_with_step(layout.planning, layout, s0, true)
	assert_true(PlanDoc.is_placed(p, a), "objects of the step marked placed")
	assert_false(PlanDoc.is_placed(p, b))
	assert_true(RecreationGuide.step_done(s0, p))
	var back := M.plan_with_step(p, layout, s0, false)
	assert_false(PlanDoc.is_placed(back, a))
	# A manual step (unlock / clear / store) is ticked by hand.
	var manual := {"id": "unlock-abc", "kind": "unlock", "uids": []}
	assert_true(M.step_is_manual(manual))
	var t := M.plan_with_step(layout.planning, layout, manual, true)
	assert_true(PlanDoc.is_step_done(t, "unlock-abc"))
	assert_eq(t["placed"], layout.planning["placed"], "nothing marked placed")
	assert_false(PlanDoc.is_step_done(M.plan_with_step(t, layout, manual, false), "unlock-abc"))


func test_guide_entries_and_progress_text() -> void:
	layout.set_planning(Fx.two_phase_plan())
	var a := _place("g_mill", Vector2i(0, 0))
	_place("g_rose", Vector2i(6, 0))
	_place("g_rose", Vector2i(6, 5))
	layout.set_planning(PlanDoc.with_placed(layout.planning, layout, [a], true))
	var g := _guide()
	var e := M.guide_entries(g)
	assert_eq(e.map(func(x): return x["type"]), ["phase", "step", "phase", "step", "step"])
	assert_eq(e[0]["name"], "First")
	assert_eq(e[2]["name"], "Second")
	var open := M.guide_entries(g, true)
	assert_eq(open.map(func(x): return x["type"]), ["phase", "step", "step"], "done steps and empty phases hidden")
	var txt := M.progress_text(g["progress"])
	assert_eq(txt, "Now: step 2 of 3 · 1 done (33.3%) · 2 to go · then step 3")
	assert_eq(M.progress_text({"total": 0}), "No steps: the design has nothing to build.")
	assert_eq(M.progress_text({"total": 4, "completed": 4}), "All 4 steps done.")
	var s: Dictionary = g["steps"][0]
	assert_eq(M.step_list_text(s), "1. %s" % s["title"])
	assert_true(M.step_meta_text(s).begins_with("Stage 4 · Large buildings · 1 object · Phase: First"), M.step_meta_text(s))
	assert_eq(M.step_where_text({"tiles_text": "tiles X 1–2, Y 3", "from_tiles_text": "tile X 0, Y 0"}), "to tiles X 1–2, Y 3 (from tile X 0, Y 0)")


# --- accuracy ----------------------------------------------------------------------------------

func test_calibration_rows() -> void:
	var rows := M.calibration_rows({"calibration": [
		{"id": "r1", "name": "", "verdict": "good", "verdict_text": "Good fit", "text": "5 points, RMS 0.10 tile", "applied": true},
		{"id": "r2", "name": "Shot", "verdict": "poor", "verdict_text": "Poor fit", "text": "x", "applied": false}]})
	assert_eq(rows[0]["name"], "Screenshot r1")
	assert_eq(rows[0]["tone"], "accent")
	assert_eq(rows[1]["tone"], "danger")
	var rep := AccuracyReport.build(fixture_map(), db, layout)
	for s: Dictionary in rep["sections"]:
		assert_true(M.STATUS_TONES.has(str(s["status"])), "every status has a tone")


# --- inventory dialog -------------------------------------------------------------------------------

func test_inventory_rows_filters() -> void:
	_place("t_long", Vector2i(0, 0))
	_place("t_long", Vector2i(2, 0))
	_place("t_fence", Vector2i(0, 5))
	_place("g_marker", Vector2i(9, 9))
	_place("t_lamp", Vector2i(8, 8), true)     # planned ghost: not on the farm
	var used := M.design_counts(layout, db)
	assert_eq(used, {"t_long": 2, "t_fence": 1}, "markers and ghosts left out")
	assert_eq(M.design_counts(layout, db, true).get("t_lamp"), 1)
	var prof := {"owned": {"t_long": 3, "t_bakery": 0}, "purchased": {"t_long": 5}}
	var rows := M.inventory_rows(db, prof, used, "used")
	assert_eq(rows.map(func(r): return r["item"]), ["t_long", "t_fence"], "by name: Long Hedge, Wood Fence")
	var long: Dictionary = rows[0]
	assert_eq([long["owned"], long["purchased"], long["used"]], [3, 5, 2])
	assert_eq(rows[1]["owned"], -1, "not recorded is not 0")
	assert_eq(M.inventory_rows(db, prof, used, "not_recorded").map(func(r): return r["item"]), ["t_fence"])
	assert_eq(M.inventory_rows(db, prof, used, "recorded").map(func(r): return r["item"]), ["t_long", "t_bakery"], "used first, then by name")
	var all := M.inventory_rows(db, prof, used, "all")
	assert_true(all.size() >= db.ordered.size() - 1, "whole catalogue (minus editor markers)")
	assert_false(all.any(func(r): return r["item"] == "g_marker"))
	assert_eq(M.inventory_rows(db, prof, used, "all", "voucher tree").map(func(r): return r["item"]), ["t_voucher"])


func test_inventory_edits_on_working_copy() -> void:
	var prof := {"owned": {"t_long": 3}}
	M.set_count(prof, "owned", "t_fence", 0)
	assert_eq(prof["owned"], {"t_long": 3, "t_fence": 0})
	M.set_count(prof, "owned", "t_long", -1)
	assert_eq(prof["owned"], {"t_fence": 0}, "-1 removes (not recorded)")
	M.set_count(prof, "balances", "coins", 500)
	assert_eq(prof["balances"], {"coins": 500})
	var n := M.fill_owned(prof, {"t_fence": 2, "t_long": 1}, true)
	assert_eq(n, 2)
	assert_eq(prof["owned"], {"t_fence": 2, "t_long": 1})
	assert_eq(M.fill_owned(prof, {"t_fence": 1}, true), 0, "raise only: never lowers a recorded count")
	assert_eq(M.fill_owned(prof, {"t_fence": 1}, false), 1)
	assert_eq(prof["owned"]["t_fence"], 1)
	assert_eq(M.parse_count(" 1,200 "), 1200)
	assert_eq(M.parse_count(""), -1)
	assert_eq(M.parse_count("-3"), -2)
	assert_eq(M.parse_count("abc"), -2)


func test_baseline_counts_and_lines() -> void:
	_place("t_long", Vector2i(0, 0))
	_place("t_long", Vector2i(2, 0))
	assert_eq(M.baseline_counts(layout.planning, db), {})
	layout.set_planning(PlanDoc.with_baseline(layout.planning, Baseline.snapshot(layout, "real")))
	assert_eq(M.baseline_counts(layout.planning, db), {"t_long": 2})
	layout.remove_objects([1])
	_place("t_long", Vector2i(5, 5))
	_place("t_fence", Vector2i(9, 9))
	var lines := M.baseline_lines(Baseline.diff(layout, layout.planning["baseline"], db))
	assert_eq(lines[0], "1 unchanged · 0 moved · 2 new · 1 removed")
	assert_eq(lines[1], "Reused from removed copies (storage, not a purchase): 1")
	assert_eq(lines[2], "New copies from storage, your inventory or the shop: 1")


func test_import_report_lines() -> void:
	var rep := InventoryIO.import_text("item_id,owned\nt_long,2\nnope_item,1\ncurrency:coins,40\n", db, {})
	var lines := M.import_report_lines(rep)
	assert_eq(lines[0], "Read 1 owned, 0 purchased and 1 balance entries.")
	assert_true(lines[1].begins_with("Not recognised (1): nope_item"), lines[1])


# --- price dialog ---------------------------------------------------------------------------------

func test_copy_price_of_matches_price_book() -> void:
	for id in ["t_bakery", "t_long", "t_fence", "t_fence_stone", "t_voucher", "t_film", "t_prize", "t_rare", "t_free", "t_odd", "t_lamp"]:
		var rec := pb.resolved(id)
		for k in range(1, 6):
			var a: Variant = M.copy_price_of(rec, k)
			var b: Variant = pb.copy_price(id, k)
			assert_true(Currency.equal(a, b), "%s copy %d: %s vs %s" % [id, k, str(a), str(b)])
	var pv := M.preview_copies(pb.resolved("t_fence"), 4)
	assert_eq(pv.map(func(p): return p["text"]), ["5 coins", "7 coins", "9 coins", "Price unknown"])


func test_resolve_with_override_matches_price_book() -> void:
	var cases := [
		["t_fence", {"price": {"coins": 8}, "step": {"coins": 2}, "confidence": "confirmed"}],
		["t_prize", {"price": {"coins": 100}}],
		["t_long", {"notes": "seen in my shop"}],
		["t_lamp", {"method": "vouchers", "price": {"voucher_blue": 4}}],
		["t_bakery", {"method": "free"}],
	]
	for c in cases:
		var id: String = c[0]
		var base := M.base_record(pb, id)
		var mine := M.resolve_with_override(base, c[1])
		pb.set_override(id, c[1])
		var real := pb.resolved(id)
		for k in range(1, 6):
			assert_true(Currency.equal(M.copy_price_of(mine, k), pb.copy_price(id, k)), "%s copy %d" % [id, k])
		assert_eq(mine["method"], real["method"], id)
		assert_eq(mine["origin"], PriceBook.ORIGIN_USER)
		assert_eq(mine["progressive"], real["progressive"], id)
		pb.remove_override(id)
	assert_eq(M.resolve_with_override(M.base_record(pb, "t_fence"), {})["origin"], PriceBook.ORIGIN_PRICE_DB)


func test_override_record_from_form() -> void:
	var r := M.override_record({"method": "shop", "price": {"coins": 300}, "step": {"coins": 50}, "confidence": "confirmed",
		"source": " my game ", "notes": "", "availability": "unknown"})
	assert_eq(r["error"], "")
	assert_eq(r["record"], {"method": "shop", "price": {"coins": 300}, "step": {"coins": 50}, "step_basis": "copies_owned",
		"confidence": "confirmed", "sources": ["my game"]})
	var keep := M.override_record({"method": "shop", "price": {}, "step": {}, "notes": "note only"})
	assert_eq(keep["record"], {"method": "shop", "notes": "note only"}, "empty price keeps the researched price")
	var bad := M.override_record({"method": "shop", "price": {}, "step": {"coins": 5}})
	assert_ne(bad["error"], "", "a step alone would make the price unknown")
	var reward := M.override_record({"method": "reward", "price": {"coins": 5}})
	assert_false(reward["record"].has("price"), "rewards have no price")
	var lines := M.record_lines(pb.resolved("t_long"), pb)
	assert_has(lines, ["First copy", "10 coins"])
	assert_has(lines, ["Each extra copy", "+ 5 coins"])
	assert_has(lines, ["Sources", "synthetic"])
	var fl := M.record_lines(pb.resolved("t_fence"), pb)
	assert_has(fl, ["Price per copy", "5 coins → 7 coins → 9 coins (later copies unknown)"])
