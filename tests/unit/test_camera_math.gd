extends TestCase

const DT := 1.0 / 60.0


func _state(p: Vector2 = Vector2.ZERO, z: float = 1.0) -> CameraMath.State:
	var s := CameraMath.State.new()
	s.reset(p, z)
	return s


func _run(s: CameraMath.State, frames: int = 600) -> int:
	## Steps until settled; returns the number of frames used.
	for i in frames:
		if not s.is_animating():
			return i
		s.step(DT)
	return frames


func _anchor_screen(s: CameraMath.State, world: Vector2) -> Vector2:
	return (world - s.pos) * s.zoom()


func test_spring_reaches_target_without_overshoot() -> void:
	var x := 0.0
	var v := 0.0
	var peak := 0.0
	for i in 120:
		var r := CameraMath.spring(x, v, 10.0, 20.0, DT)
		x = r.x
		v = r.y
		peak = maxf(peak, x)
	assert_almost(x, 10.0, 0.001, "settles on target")
	assert_true(peak <= 10.0 + 0.0001, "critically damped: no overshoot (peak %f)" % peak)


func test_spring_stable_for_huge_dt() -> void:
	var r := CameraMath.spring(0.0, 0.0, 5.0, 20.0, 10.0)
	assert_almost(r.x, 5.0, 0.001, "lands on target in one giant step")
	assert_almost(r.y, 0.0, 0.001, "at rest")


func test_spring_frame_rate_independent() -> void:
	var a := CameraMath.spring(0.0, 0.0, 1.0, 12.0, 0.1)
	var x := 0.0
	var v := 0.0
	for i in 10:
		var r := CameraMath.spring(x, v, 1.0, 12.0, 0.01)
		x = r.x
		v = r.y
	assert_almost(x, a.x, 0.0001, "ten small steps = one big step")


func test_rubber_shape() -> void:
	assert_almost(CameraMath.rubber(0.0, 100.0), 0.0)
	assert_true(CameraMath.rubber(10.0, 100.0) < 10.0, "resists")
	assert_true(CameraMath.rubber(20.0, 100.0) > CameraMath.rubber(10.0, 100.0), "monotone")
	assert_true(CameraMath.rubber(1e9, 100.0) <= 100.0, "bounded by dim")
	assert_almost(CameraMath.rubber_axis(50.0, 0.0, 100.0, 40.0), 50.0, 0.0001, "inside is untouched")
	assert_true(CameraMath.rubber_axis(-30.0, 0.0, 100.0, 40.0) > -30.0, "pulled towards the low limit")
	assert_true(CameraMath.rubber_axis(130.0, 0.0, 100.0, 40.0) < 130.0, "pulled towards the high limit")


func test_zoom_keeps_anchor_under_cursor_all_the_way() -> void:
	var s := _state(Vector2(100, 50), 1.0)
	var off := Vector2(300, -120)
	var world := s.pos + off / s.zoom()
	s.zoom_about(off, log(3.0))
	for i in 200:
		s.step(DT)
		assert_vec_almost(_anchor_screen(s, world), off, 0.01, "frame %d" % i)
	assert_almost(s.zoom(), 3.0, 0.001, "reaches the target zoom")
	assert_false(s.anchored, "anchor released when settled")


func test_pan_during_zoom_is_kept() -> void:
	# The original bug: the zoom animation restored its anchor and lost the pan.
	var with_pan := _state(Vector2(0, 0), 1.0)
	var no_pan := _state(Vector2(0, 0), 1.0)
	var off := Vector2(200, 100)
	with_pan.zoom_about(off, log(2.0))
	no_pan.zoom_about(off, log(2.0))
	for i in 3:
		with_pan.step(DT)
		no_pan.step(DT)
	with_pan.pan_world(Vector2(-55, 31))
	_run(with_pan)
	_run(no_pan)
	assert_vec_almost(with_pan.pos - no_pan.pos, Vector2(-55, 31), 0.01, "the pan survives the zoom exactly")


func test_consecutive_wheel_steps_compound_on_the_target() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.zoom_about(Vector2.ZERO, s.target_log_z + log(1.15))
	s.step(DT)
	s.zoom_about(Vector2.ZERO, s.target_log_z + log(1.15))
	s.step(DT)
	s.zoom_about(Vector2.ZERO, s.target_log_z + log(1.15))
	_run(s)
	assert_almost(s.zoom(), pow(1.15, 3.0), 0.001, "three notches")


func test_retargeting_the_anchor_mid_zoom_does_not_jump() -> void:
	var s := _state(Vector2(40, 40), 1.0)
	s.zoom_about(Vector2(100, 0), log(2.0))
	for i in 4:
		s.step(DT)
	var before := s.pos
	s.zoom_about(Vector2(-250, 90), s.target_log_z)
	assert_vec_almost(s.pos, before, 0.0001, "position is continuous")
	var world := s.pos + Vector2(-250, 90) / s.zoom()
	s.step(DT)
	assert_vec_almost(_anchor_screen(s, world), Vector2(-250, 90), 0.01, "follows the new anchor")


func test_zoom_is_clamped() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.min_log_z = log(0.5)
	s.max_log_z = log(2.0)
	s.zoom_about(Vector2.ZERO, log(100.0))
	_run(s)
	assert_almost(s.zoom(), 2.0, 0.001, "max")
	s.zoom_about(Vector2.ZERO, log(0.001))
	_run(s)
	assert_almost(s.zoom(), 0.5, 0.001, "min")


func test_inertia_coasts_the_expected_distance_and_stops() -> void:
	var s := _state(Vector2.ZERO, 2.0)
	s.end_hold(Vector2(1000, 0))
	var frames := _run(s, 2000)
	assert_true(frames < 2000, "comes to rest")
	# screen distance v / friction, divided by zoom, opposite to the pointer.
	assert_almost(s.pos.x, -1000.0 / CameraMath.FRICTION / 2.0, 3.0, "distance")
	assert_almost(s.pos.y, 0.0, 0.001)


func test_hard_mode_never_coasts_or_animates() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.soft = false
	s.end_hold(Vector2(1000, 0))
	assert_false(s.is_animating(), "no inertia")
	s.zoom_about(Vector2(50, 0), log(2.0))
	assert_false(s.is_animating(), "zoom applied at once")
	assert_almost(s.zoom(), 2.0, 0.0001)
	assert_vec_almost(s.pos, Vector2(25, 0), 0.001, "anchored at once")


func test_tracker_release_velocity() -> void:
	var t := CameraMath.PanTracker.new()
	assert_vec_almost(t.velocity(0), Vector2.ZERO, 0.0001, "empty")
	for i in 6:
		t.add(Vector2(10, 0), 1000 + i * 10)
	assert_vec_almost(t.velocity(1055), Vector2(1000, 0), 0.5, "10 px per 10 ms")
	assert_vec_almost(t.velocity(1200), Vector2.ZERO, 0.0001, "held still before release: no throw")
	var slow := CameraMath.PanTracker.new()
	slow.add(Vector2(1, 0), 0)
	slow.add(Vector2(1, 0), 20)
	assert_vec_almost(slow.velocity(20), Vector2.ZERO, 0.0001, "too slow to throw")
	var fast := CameraMath.PanTracker.new()
	fast.add(Vector2(1000, 0), 0)
	fast.add(Vector2(1000, 0), 1)
	assert_true(fast.velocity(1).length() <= CameraMath.THROW_MAX + 0.01, "capped")


func test_limits_rubber_band_then_spring_back() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.limits = Rect2(-100, -100, 200, 200)
	s.begin_hold()
	s.pan_world(Vector2(400, 0))
	assert_true(s.shown_pos().x > 100.0, "pulled past the limit")
	assert_true(s.shown_pos().x < 400.0, "with resistance")
	s.step(DT)
	assert_almost(s.pos.x, 400.0, 0.001, "stays out while held")
	s.end_hold(Vector2.ZERO)
	var frames := _run(s)
	assert_true(frames < 600, "comes to rest")
	assert_almost(s.shown_pos().x, 100.0, 0.1, "eases back to the limit")
	assert_false(s.is_outside(), "inside again")


func test_inertia_stops_at_the_limit_and_returns() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.limits = Rect2(-50, -50, 100, 100)
	s.end_hold(Vector2(-5000, 0))
	_run(s, 1200)
	assert_false(s.is_animating(), "at rest")
	assert_almost(s.shown_pos().x, 50.0, 0.2, "ends on the limit")


func test_hard_limits_clamp_the_view_centre() -> void:
	var s := _state(Vector2.ZERO, 2.0)
	s.soft = false
	s.limits = Rect2(0, 0, 100, 100)
	s.view_off = Vector2(40, 0)     # panels shift the visible centre
	s.pan_world(Vector2(5000, 5000))
	assert_vec_almost(s.pos + s.view_off / s.zoom(), Vector2(100, 100), 0.001, "centre clamped")


func test_fly_to_arrives_with_position_and_zoom() -> void:
	var s := _state(Vector2(-300, 200), 0.5)
	s.fly_to(Vector2(500, 500), log(2.0))
	assert_vec_almost(s.settled_pos(), Vector2(500, 500), 0.001, "destination known up front")
	var frames := _run(s)
	assert_true(frames < 200, "arrives (%d frames)" % frames)
	assert_vec_almost(s.pos, Vector2(500, 500), 0.1)
	assert_almost(s.zoom(), 2.0, 0.001)


func test_fly_to_respects_view_offset_and_limits() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.view_off = Vector2(100, 0)
	s.fly_to(Vector2(0, 0), log(1.0))
	_run(s)
	assert_vec_almost(s.pos + s.view_off / s.zoom(), Vector2.ZERO, 0.1, "world point at the view centre")
	s.limits = Rect2(-10, -10, 20, 20)
	s.fly_to(Vector2(9000, 9000), log(1.0))
	_run(s)
	assert_vec_almost(s.pos + s.view_off / s.zoom(), Vector2(10, 10), 0.1, "destination inside the limits")


func test_pan_during_flight_shifts_the_destination() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.fly_to(Vector2(300, 0), log(1.0))
	s.step(DT)
	s.pan_world(Vector2(0, 40))
	_run(s)
	assert_vec_almost(s.pos, Vector2(300, 40), 0.1)


func test_grabbing_the_view_cancels_the_flight() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.fly_to(Vector2(300, 0), log(1.0))
	s.step(DT)
	s.begin_hold()
	var x := s.pos.x
	s.step(DT)
	assert_almost(s.pos.x, x, 0.0001, "no more flying while held")


func test_settled_pos_during_anchored_zoom() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.zoom_about(Vector2(100, 0), log(2.0))
	var end := s.settled_pos()
	_run(s)
	assert_vec_almost(s.pos, end, 0.05, "prediction matches the end of the zoom")


func test_settle_finishes_everything() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.limits = Rect2(-10, -10, 20, 20)
	s.fly_to(Vector2(5, 5), log(2.0))
	s.settle()
	assert_false(s.is_animating())
	assert_vec_almost(s.pos, Vector2(5, 5), 0.001)
	assert_almost(s.zoom(), 2.0, 0.0001)


func test_reset_adopts_an_outside_view() -> void:
	var s := _state(Vector2.ZERO, 1.0)
	s.zoom_about(Vector2(10, 10), log(3.0))
	s.step(DT)
	s.reset(Vector2(7, 8), 1.5)
	assert_false(s.is_animating(), "stops every animation")
	assert_vec_almost(s.pos, Vector2(7, 8), 0.0001)
	assert_almost(s.zoom(), 1.5, 0.0001)


func test_fit_zoom() -> void:
	assert_almost(CameraMath.fit_zoom(Vector2(1000, 500), Vector2(2000, 500)), 0.5, 0.0001, "width limits")
	assert_almost(CameraMath.fit_zoom(Vector2(1000, 500), Vector2(100, 1000)), 0.5, 0.0001, "height limits")
	assert_almost(CameraMath.fit_zoom(Vector2(1000, 1000), Vector2(1000, 1000), 100.0), 0.8, 0.0001, "margin")


func test_bookmark_command_is_undoable_and_keeps_other_slots() -> void:
	var l := FarmLayout.new()
	l.camera = {"x": 1.0, "y": 2.0, "zoom": 1.0}
	var a := EditCommands.SetCameraBookmark.new("1", {"x": 10.0, "y": 20.0, "zoom": 1.5})
	a.do(l)
	assert_eq(l.camera["bookmarks"]["1"]["zoom"], 1.5, "stored")
	var b := EditCommands.SetCameraBookmark.new("2", {"x": 0.0, "y": 0.0, "zoom": 1.0})
	b.do(l)
	assert_true(l.camera["bookmarks"].has("1") and l.camera["bookmarks"].has("2"), "other slots kept")
	b.undo(l)
	assert_false(l.camera["bookmarks"].has("2"), "undo removes a new slot")
	assert_eq(l.camera["x"], 1.0, "the view itself is left alone")
	var c := EditCommands.SetCameraBookmark.new("1", {"x": 99.0, "y": 0.0, "zoom": 1.0})
	c.do(l)
	c.undo(l)
	assert_eq(l.camera["bookmarks"]["1"]["x"], 10.0, "undo restores an overwritten slot")
	a.undo(l)
	assert_false(l.camera.has("bookmarks"), "no empty bookmarks left behind")
