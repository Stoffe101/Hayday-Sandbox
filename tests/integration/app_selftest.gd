extends Node
## In-app integration + performance self-test. Runs inside the real app (so
## autoloads, UI and the editor controller are all live) and drives the
## editor with synthetic input events.
##   godot --headless --path . -- --selftest          (integration)
##   godot --headless --path . -- --selftest=perf     (benchmarks)
##   ./HaydaySandbox.x86_64 --headless -- --selftest  (verifies an exported build)
## Prints "SELFTEST PASS"/"SELFTEST FAIL" and exits 0/1.

var mode := "all"
var main: Node
var fails: Array = []
var checks := 0
var log_lines: Array = []


func _ready() -> void:
	main = get_parent()
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails.append(what)
		print("  FAIL ", what)
	else:
		print("  ok   ", what)


func _run() -> void:
	await _frames(5)
	if mode == "perf":
		await _perf()
	else:
		await _integration()
	print("\n%d checks, %d failed" % [checks, fails.size()])
	print("SELFTEST " + ("PASS" if fails.is_empty() else "FAIL"))
	get_tree().quit(0 if fails.is_empty() else 1)


func _s() -> EditorSession:
	return App.session


# --- input helpers -------------------------------------------------------------

func _screen_of_tile(t: Vector2i) -> Vector2:
	return main.camera.world_to_screen(Iso.tile_center(t))


func _move(p: Vector2, mask: int = 0) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.button_mask = mask
	main._on_canvas_input(e)


func _button(p: Vector2, pressed: bool, button: int = MOUSE_BUTTON_LEFT, shift: bool = false, ctrl: bool = false) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.button_index = button
	e.pressed = pressed
	e.shift_pressed = shift
	e.ctrl_pressed = ctrl
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	main._on_canvas_input(e)


func _click_tile(t: Vector2i, shift: bool = false) -> void:
	var p := _screen_of_tile(t)
	_move(p)
	_button(p, true, MOUSE_BUTTON_LEFT, shift)
	_button(p, false, MOUSE_BUTTON_LEFT, shift)


func _drag_tiles(a: Vector2i, b: Vector2i, shift: bool = false, ctrl: bool = false) -> void:
	var pa := _screen_of_tile(a)
	var pb := _screen_of_tile(b)
	_move(pa)
	_button(pa, true, MOUSE_BUTTON_LEFT, shift, ctrl)
	for i in range(1, 11):
		_move(pa.lerp(pb, i / 10.0), MOUSE_BUTTON_MASK_LEFT)
	_button(pb, false, MOUSE_BUTTON_LEFT, shift, ctrl)


func _key(code: Key, ctrl: bool = false, shift: bool = false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	main._unhandled_input(e)


func _free_origin(item: ItemDef, near: Vector2i, flipped: bool = false) -> Vector2i:
	var s := _s()
	for r in 40:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var o := near + Vector2i(dx, dy)
				var ok := PlacementRules.check_item(s.layout, s.map, item, o, flipped).ok
				if ok:
					# keep a 1-tile free margin so neighbours don't interfere
					var ring := PlacementRules.check_rect(s.layout, s.map, Rect2i(o - Vector2i.ONE, item.size_for(flipped) + Vector2i(2, 2)))
					if ring.ok:
						return o
	return near


# --- integration ---------------------------------------------------------------

func _integration() -> void:
	print("Data")
	check(App.db.count() >= 1900, "catalogue loaded (%d items)" % App.db.count())
	check(App.db.errors.is_empty(), "catalogue has no errors %s" % str(App.db.errors.slice(0, 3)))
	check(App.maps.has("hayday_farm") and App.maps.has("hayday_farm_h1"), "both map hypotheses loaded")
	check(App.map.plots.size() == 52, "main section has 52 plots")
	var st := App.assets.stats(App.db)
	check(float(st["with_art"]) / st["items"] > 0.99, "placeholder art for %d/%d items" % [st["with_art"], st["items"]])
	check(App.boot_ms < 5000.0, "services boot in %.0f ms" % App.boot_ms)
	# Every sample loads cleanly.
	var dir := DirAccess.open("res://data/samples")
	var nsamples := 0
	for f in dir.get_files():
		if f.ends_with(LayoutIO.FILE_EXT):
			var rep := LayoutIO.LoadReport.new()
			var l := App.library.load_path("res://data/samples".path_join(f), rep)
			check(l != null and rep.missing_items.is_empty() and PlacementRules.find_conflicts(l, App.maps[l.map_id]).is_empty(), "sample %s loads with no conflicts" % f)
			nsamples += 1
	check(nsamples >= 5, "%d sample layouts" % nsamples)

	print("Editing")
	App.open_layout(App.new_layout("Selftest farm", "starter"))
	main._fit_or_restore()
	main.camera.smooth = false
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5
	await _frames(3)
	var s := _s()
	var base := s.layout.count()
	check(base >= 5, "starter layout has core buildings (%d)" % base)
	for o: PlacedObject in s.layout.objects.values():
		check(o.locked, "core building %s starts locked" % o.item_id)
		break
	var bakery := App.db.get_item("bakery")
	var at := _free_origin(bakery, Vector2i(14, 28))
	main.camera.center_on(Iso.tile_center(at))
	await _frames(2)
	main._on_item_chosen("bakery")
	check(s.tool == "place", "choosing an item activates the place tool")
	_click_tile(at + Vector2i(1, 1))
	check(s.layout.count() == base + 1, "click places the bakery")
	var placed := s.layout.object_at(at + Vector2i(1, 1))
	check(placed != null and placed.item_id == "bakery" and placed.origin == at, "bakery stands exactly on the previewed tiles")
	_click_tile(at + Vector2i(1, 1))
	check(s.layout.count() == base + 1, "clicking on occupied tiles places nothing")
	_key(KEY_Z, true)
	check(s.layout.count() == base, "Ctrl+Z undoes the placement")
	_key(KEY_Z, true, true)
	check(s.layout.count() == base + 1, "Ctrl+Shift+Z redoes it")
	# Fence line (shift-drag) is one undo step and auto-connects.
	var fence := App.db.get_item("fence")
	var fa := _free_origin(App.db.get_item("plan_reserve_4x4"), Vector2i(8, 20))
	main.camera.center_on(Iso.tile_center(fa))
	await _frames(2)
	main._on_item_chosen("fence")
	var steps_before := s.stack.size()
	_drag_tiles(fa, fa + Vector2i(4, 0), true)
	check(s.stack.size() == steps_before + 1, "a line of fences is a single undo step")
	var mid := s.layout.object_at(fa + Vector2i(2, 0))
	check(mid != null and mid.item_id == "fence", "fence line placed")
	if mid:
		check(Connections.mask_for(s.layout, s.db, mid) == (Connections.NW | Connections.SE), "middle fence connects both ways (straight)")
	# Escape -> select tool; drag-move the bakery.
	_key(KEY_ESCAPE)
	check(s.tool == "select", "Esc returns to the select tool")
	var target := _free_origin(bakery, at + Vector2i(0, 5))
	main.camera.center_on(Iso.tile_center(at))
	await _frames(2)
	var steps := s.stack.size()
	_drag_tiles(at + Vector2i(1, 1), target + Vector2i(1, 1))
	var moved := s.layout.object_at(target + Vector2i(1, 1))
	check(moved != null and moved.uid == placed.uid, "dragging moves the bakery (one gesture)")
	check(s.stack.size() == steps + 1, "a drag-move is a single undo step")
	check(s.layout.object_at(at + Vector2i(1, 1)) == null or s.layout.object_at(at + Vector2i(1, 1)).uid != placed.uid, "old tiles were freed")
	# Invalid drop snaps back.
	var fh: PlacedObject = null
	for o: PlacedObject in s.layout.objects.values():
		if o.item_id == "farmhouse":
			fh = o
	if fh:
		var before := moved.origin
		main.camera.center_on(Iso.tile_center(before))
		await _frames(2)
		_drag_tiles(before + Vector2i(1, 1), fh.origin + Vector2i(1, 1))
		check(moved.origin == before, "dropping onto the farmhouse is rejected (object stays)")
	# Locked objects cannot be moved/deleted.
	if fh:
		s.select([fh.uid])
		var c0 := s.layout.count()
		_key(KEY_DELETE)
		check(s.layout.count() == c0, "locked farmhouse survives Delete")
		_key(KEY_L)
		check(not fh.locked, "L unlocks it")
		_key(KEY_L)
		check(fh.locked, "L locks it again")
	# Copy / paste.
	s.select([moved.uid])
	_key(KEY_C, true)
	check(s.clipboard.size() == 1, "Ctrl+C copies the selection")
	_key(KEY_V, true)
	check(main.controller.stamp_mode, "Ctrl+V enters stamp mode")
	var pat := _free_origin(bakery, moved.origin + Vector2i(5, 0))
	var c1 := s.layout.count()
	_click_tile(pat + Vector2i(1, 1))
	check(s.layout.count() == c1 + 1, "click pastes a copy")
	_key(KEY_ESCAPE)
	# Flip (rotate) swaps a non-square footprint.
	var hedge_item := App.db.get_item("raspberry_bush")
	var ho := _free_origin(hedge_item, Vector2i(6, 26))
	main.camera.center_on(Iso.tile_center(ho))
	await _frames(2)
	main._on_item_chosen("raspberry_bush")
	_click_tile(ho)
	var bush := s.layout.object_at(ho)
	_key(KEY_ESCAPE)
	if bush:
		s.select([bush.uid])
		var sz := bush.size
		_key(KEY_R)
		check(bush.size == Vector2i(sz.y, sz.x) and bush.flipped, "R rotates (mirrors) and swaps the footprint")
	# Marquee selection.
	s.clear_selection()
	var wa: Vector2 = main.camera.world_to_screen(Iso.tile_center(at) - Vector2(400, 300))
	var wb: Vector2 = main.camera.world_to_screen(Iso.tile_center(at) + Vector2(400, 300))
	_move(wa)
	_button(wa, true)
	for i in 10:
		_move(wa.lerp(wb, (i + 1) / 10.0), MOUSE_BUTTON_MASK_LEFT)
	_button(wb, false)
	check(s.selection.size() >= 1, "box-select selects objects (%d)" % s.selection.size())
	# Delete + undo restores everything.
	var keep := s.layout.count()
	var nsel := s.editable_selection().size()
	_key(KEY_DELETE)
	check(s.layout.count() == keep - nsel, "Delete removes the unlocked selection")
	_key(KEY_Z, true)
	check(s.layout.count() == keep, "undo restores deleted objects")
	# Land tool toggles a plot.
	s.set_tool("land")
	var p1: Dictionary = s.map.plots[0]
	var pc: Vector2 = p1["center"]
	var pt := Vector2i(floori(pc.x), floori(pc.y))
	main.camera.center_on(Iso.tile_center(pt))
	await _frames(2)
	_click_tile(pt)
	check(s.layout.unlocked_plots.has(p1["id"]), "land tool unlocks a plot")
	_key(KEY_Z, true)
	check(not s.layout.unlocked_plots.has(p1["id"]), "undo re-locks it")
	# Mode switching never changes the design.
	var snapshot := JSON.stringify(LayoutIO.to_dict(s.layout)["objects"])
	main._toggle_mode()
	check(s.layout.mode == FarmLayout.MODE_REALISTIC, "switched to Realistic")
	main._toggle_mode()
	check(JSON.stringify(LayoutIO.to_dict(s.layout)["objects"]) == snapshot, "Creative↔Realistic leaves objects untouched")
	# Missing art / unknown item does not crash rendering.
	var ghost := PlacedObject.new()
	ghost.item_id = "item_that_does_not_exist"
	ghost.origin = _free_origin(App.db.get_item("plan_reserve_2x2"), Vector2i(20, 8))
	ghost.size = Vector2i(2, 2)
	ghost.missing = true
	s.layout.add_objects([ghost])
	await _frames(2)
	check(main.renderer.object_count() == s.layout.count(), "unknown items render as fallback blocks")
	# Save, reload, compare positions.
	var err := App.save_current(true)
	check(err == OK, "save succeeds")
	var rep := LayoutIO.LoadReport.new()
	var back := App.library.load_layout(s.layout.id, rep)
	var same := back != null and back.count() == s.layout.count()
	if same:
		for o: PlacedObject in s.layout.objects.values():
			var b := back.get_obj(o.uid)
			if b == null or b.origin != o.origin or b.size != o.size or b.flipped != o.flipped:
				same = false
	check(same, "reloaded layout matches exactly (%d objects)" % s.layout.count())
	check(rep.missing_items.has("item_that_does_not_exist"), "unknown item preserved through save/load")
	check(App.library.history(s.layout.id).size() >= 1, "save created a revision snapshot")
	# Asset importer on a generated folder (no proprietary art involved).
	_importer_check()
	App.library.delete(s.layout.id)


func _importer_check() -> void:
	var src := "user://selftest_import"
	DirAccess.make_dir_recursive_absolute(src)
	var img := Image.create(140, 120, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(Rect2i(30, 20, 80, 90), Color(0.8, 0.3, 0.3))
	img.save_png(src.path_join("Bakery.png"))
	img.save_png(src.path_join("bakery copy.png"))
	var junk := Image.create(10, 10, false, Image.FORMAT_RGB8)
	junk.save_png(src.path_join("not_an_item.png"))
	var rep := AssetImporter.run(ProjectSettings.globalize_path(src), "selftest_pack", App.db, "test", "user://selftest_packs")
	check(rep.matched.has("bakery"), "importer matched Bakery.png to the bakery")
	check(rep.duplicates.size() == 1, "importer detected the duplicate image")
	check("not_an_item.png" in rep.unmatched, "importer reported the unmatched file")
	check(rep.trimmed_px > 0, "importer trimmed transparent padding")
	var pack: Variant = JsonUtil.read_json("user://selftest_packs/selftest_pack/pack.json")
	check(pack is Dictionary and pack["sprites"].has("bakery"), "importer wrote a valid pack.json")


# --- performance -----------------------------------------------------------------

func _perf() -> void:
	var results := {}
	# A: the real farm (all mapped land unlocked), packed densely.
	results["farm"] = await _bench("farm", 4000, App.maps["hayday_farm"])
	# B: synthetic stress maps far beyond any real farm.
	var big := FarmMap.make_simple(160, 160)
	App.maps[big.id] = big
	for n in [2000, 5000, 10000]:
		results[n] = await _bench(str(n), n, big)
	for k in results:
		print("PERF %s %s" % [k, JSON.stringify(results[k])])
	var r5: Dictionary = results[5000]
	check(r5["sort_ms"] < 1500.0, "full depth sort of %d objects: %.0f ms" % [r5["objects"], r5["sort_ms"]])
	check(r5["edit_resort_ms"] < 1500.0, "single edit incl. re-sort at %d objects: %.0f ms" % [r5["objects"], r5["edit_resort_ms"]])
	check(r5["place_check_us"] < 2000.0, "placement check: %.0f µs" % r5["place_check_us"])
	check(r5["pick_us"] < 5000.0, "pixel-accurate pick: %.0f µs" % r5["pick_us"])
	check(r5["save_ms"] < 3000.0 and r5["load_ms"] < 3000.0, "save %.0f ms / load %.0f ms" % [r5["save_ms"], r5["load_ms"]])
	App.maps.erase(big.id)


func _bench(label: String, n: int, map: FarmMap) -> Dictionary:
	var l := FarmLayout.new()
	l.name = "Perf " + label
	l.map_id = map.id
	l.set_unlocked(map.all_plot_ids(), false)
	var rng := RandomNumberGenerator.new()
	rng.seed = n
	var ids: Array = []
	for it: ItemDef in App.db.ordered:
		if it.placeable and it.footprint.x * it.footprint.y <= 9:
			ids.append(it.id)
	var tries := 0
	var t0 := Time.get_ticks_usec()
	while l.count() < n and tries < n * 25:
		tries += 1
		var it := App.db.get_item(ids[rng.randi() % ids.size()])
		var o := PlacedObject.new()
		o.item_id = it.id
		o.origin = Vector2i(rng.randi_range(0, map.size.x - 1), rng.randi_range(0, map.size.y - 1))
		o.size = it.footprint
		if PlacementRules.check_rect(l, map, o.rect()).ok:
			l.add_objects([o], false)
	# Fill the rest of a real farm with 1x1 items to reach saturation.
	if label == "farm":
		for y in map.size.y:
			for x in map.size.x:
				if l.count() >= n:
					break
				if PlacementRules.check_rect(l, map, Rect2i(x, y, 1, 1)).ok:
					var f := PlacedObject.new()
					f.item_id = "field"
					f.origin = Vector2i(x, y)
					l.add_objects([f], false)
	var gen_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	App.open_layout(l)
	var open_ms := (Time.get_ticks_usec() - t0) / 1000.0
	main.renderer._order_dirty = true
	t0 = Time.get_ticks_usec()
	main.renderer.ensure_sorted()
	var sort_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var bakery := App.db.get_item("bakery")
	t0 = Time.get_ticks_usec()
	for i in 200:
		PlacementRules.check_item(l, map, bakery, Vector2i(rng.randi_range(0, map.size.x), rng.randi_range(0, map.size.y)), false)
	var place_us := (Time.get_ticks_usec() - t0) / 200.0
	t0 = Time.get_ticks_usec()
	for i in 200:
		main.renderer.pick(Iso.tile_center(Vector2i(rng.randi_range(0, map.size.x), rng.randi_range(0, map.size.y))))
	var pick_us := (Time.get_ticks_usec() - t0) / 200.0
	var free := Vector2i(-1, -1)
	for y in map.size.y:
		for x in map.size.x:
			if free.x < 0 and PlacementRules.check_rect(l, map, Rect2i(x, y, 1, 1)).ok:
				free = Vector2i(x, y)
	var edit_ms := -1.0
	if free.x >= 0:
		t0 = Time.get_ticks_usec()
		var po := PlacedObject.new()
		po.item_id = "fence"
		po.origin = free
		po.size = Vector2i.ONE
		App.session.execute(EditCommands.AddObjects.new([po]))
		main.renderer.ensure_sorted()
		edit_ms = (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var text := JsonUtil.stringify(LayoutIO.to_dict(l), false)
	var path := "user://perf_%s.hdlayout" % label
	JsonUtil.write_atomic(path, text, false)
	var save_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var rep := LayoutIO.LoadReport.new()
	var back := LayoutIO.load_file(path, App.db, rep)
	var load_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	RealisticAnalyzer.analyze(l, App.db, map)
	var analyze_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var frame_ms := -1.0
	if DisplayServer.get_name() != "headless":
		main.camera.smooth = false
		main._fit()
		await _frames(10)
		var f0 := Time.get_ticks_usec()
		for i in 60:
			main.camera.pan_screen(Vector2(3, 1))
			await get_tree().process_frame
		frame_ms = (Time.get_ticks_usec() - f0) / 1000.0 / 60.0
	await _frames(2)
	return {"objects": l.count(), "generate_ms": snappedf(gen_ms, 0.1), "open_ms": snappedf(open_ms, 0.1),
		"sort_ms": snappedf(sort_ms, 0.1), "place_check_us": snappedf(place_us, 0.1), "pick_us": snappedf(pick_us, 0.1),
		"edit_resort_ms": snappedf(edit_ms, 0.1), "save_ms": snappedf(save_ms, 0.1), "load_ms": snappedf(load_ms, 0.1),
		"analyze_ms": snappedf(analyze_ms, 0.1), "file_kb": text.length() / 1024, "loaded": back.count() if back else -1,
		"frame_ms": snappedf(frame_ms, 0.01), "mem_mb": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1)}
