extends TestCase
## EditorSession's budget engine (owned, rebound, disposed) and the planning
## context's view state: mode, scope, active area / phase, layers.

const Budget := preload("res://tests/unit/test_budget.gd")

var db: ItemDatabase
var pb: PriceBook
var map: FarmMap


func before_each() -> void:
	db = Budget.make_db()
	pb = Budget.make_prices(db)
	map = fixture_map()


func _session() -> EditorSession:
	var l := FarmLayout.new()
	l.set_planning(Budget.two_phase_plan(), false)
	return EditorSession.new(l, db, map, pb)


func test_session_owns_and_disposes_its_budget() -> void:
	var before := pb.changed.get_connections().size()
	var s := _session()
	assert_not_null(s.budget, "a session made with a price book has a budget engine")
	assert_eq(pb.changed.get_connections().size(), before + 1, "the engine listens to the price book")
	var lc := s.layout.planning_changed.get_connections().size()
	s.dispose()
	assert_eq(pb.changed.get_connections().size(), before, "dispose lets go of the shared price book")
	assert_eq(s.layout.planning_changed.get_connections().size(), lc - 1, "…and of the layout")
	assert_null(EditorSession.new(FarmLayout.new(), db, map).budget, "no price book: no budget engine")


func test_set_map_rebinds_the_budget() -> void:
	var s := _session()
	var other := FarmMap.make_simple(20, 20)
	var v := s.budget.version
	s.set_map(other)
	assert_true(s.budget.map == other, "the engine follows the session's world")
	assert_true(s.budget.version > v, "and recomputes")
	s.dispose()


func test_context_view_state_and_scope() -> void:
	var s := _session()
	var u := int(s.layout.add_objects([make_obj(db.get_item("t_bakery"), Vector2i(1, 1))])[0])
	var ctx := PlanContext.new()
	ctx.bind(s, s.budget, pb, db, map)
	var views := [0]
	ctx.view_changed.connect(func(): views[0] += 1)
	assert_eq(ctx.scope()["kind"], PlanScope.SCOPE_FARM)
	ctx.set_active_area("a1")
	assert_eq(ctx.scope()["kind"], PlanScope.SCOPE_AREA)
	ctx.set_active_area("a1")
	assert_eq(views[0], 1, "setting the same value again is no change")
	s.select([u])
	assert_eq(ctx.scope()["kind"], PlanScope.SCOPE_SELECTION, "the selection wins over the active area")
	ctx.set_mode(BudgetEngine.MODE_DESIGN)
	assert_eq(ctx.scope_totals().cost, {"coins": 50}, "scope totals in the shared mode")
	ctx.set_mode("nonsense")
	assert_eq(ctx.mode, BudgetEngine.MODE_DESIGN, "unknown modes are ignored")
	ctx.set_scope_pin("farm")
	assert_eq(ctx.scope()["kind"], PlanScope.SCOPE_FARM, "pinned to the whole farm")
	ctx.set_layer("heatmap", true)
	assert_true(bool(ctx.layers["heatmap"]))
	ctx.set_active_phase("p2")
	ctx.set_guide_step(3)
	assert_eq(views[0], 6, "one view change per real change")
	# A new session without that area / phase clears them.
	var s2 := EditorSession.new(FarmLayout.new(), db, map, pb)
	ctx.bind(s2, s2.budget, pb, db, map)
	assert_eq([ctx.active_area, ctx.active_phase, ctx.guide_step], ["", "", -1], "stale ids are cleared on a new session")
	assert_eq(ctx.item_name("t_bakery"), db.get_item("t_bakery").name)
	s.dispose()
	s2.dispose()
