extends Node
## In-app integration + performance self-test. Runs inside the real app (so
## autoloads, UI and the editor controller are all live) and drives the
## editor with synthetic input events.
##   godot --headless --path . -- --selftest          (integration)
##   godot --headless --path . -- --selftest=perf     (benchmarks)
##   godot --path . -- --selftest=artcheck [--artcheck-pack=<id>] [--artcheck-out=<json>]
##       (counts which catalogue items resolve to an installed pack and load; memory;
##        writes counts only — never images — to the private root or user://)
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
	elif mode == "artcheck":
		await _artcheck()
	elif mode == "artflow":
		await _artflow()
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
					var area := Rect2i(o - Vector2i.ONE, item.size_for(flipped) + Vector2i(2, 2))
					var ring := PlacementRules.check_rect(s.layout, s.map, area)
					if ring.ok and not _touches_landmark(area):
						return o
	return near


func _free_block(size: Vector2i) -> Vector2i:
	## Top corner of a completely empty, landmark-free area of this size (-1 = none).
	var s := _s()
	for y in range(0, s.map.size.y - size.y):
		for x in range(0, s.map.size.x - size.x):
			var area := Rect2i(Vector2i(x, y), size)
			if PlacementRules.check_rect(s.layout, s.map, area).ok and not _touches_landmark(area):
				return area.position
	return Vector2i(-1, -1)


func _first_item(pred: Callable) -> ItemDef:
	for it: ItemDef in App.db.ordered:
		if it.can_place() and pred.call(it):
			return it
	return null


func _layout_tools_check() -> void:
	print("Layout tools")
	App.open_layout(App.new_layout("Tools", "expanded"))
	await _frames(2)
	var s := _s()
	s.layout.set_unlocked(s.map.all_plot_ids())
	var lt: LayoutToolController = main.layout_tools
	var base := _free_block(Vector2i(28, 18))
	check(base.x >= 0, "a free block to test the tools on")
	var fence := _first_item(func(it: ItemDef) -> bool: return it.connect_style == "fence" and it.footprint == Vector2i.ONE)
	var tall := _first_item(func(it: ItemDef) -> bool: return it.flippable and it.footprint.x != it.footprint.y and it.footprint.x <= 3 and it.footprint.y <= 3)
	var fid := fence.id
	# Symmetry: mirrored ghost, one undo step, real pointer events.
	s.set_active_item(fid)
	s.set_symmetry_kind(LayoutTools.KIND_ACROSS)
	s.set_symmetry_tile(base + Vector2i(12, 0))
	main.dock.tool_action.emit("symmetry", true)
	check(bool(s.symmetry["enabled"]) and lt.tool_overlay.line == s.mirror_line(), "symmetry on: the mirror line is drawn")
	var p := _screen_of_tile(base + Vector2i(3, 3))
	_move(p)
	await _frames(2)
	var ov: EditorOverlay = main.overlay
	check(ov.ghosts.size() == 2 and bool(ov.ghosts[1].get("mirror", false)) and ov.ghosts[1]["origin"] == base + Vector2i(21, 3), "live ghost of the mirrored copy")
	var n0 := s.layout.count()
	var h0 := s.stack.size()
	_button(p, true)
	_button(p, false)
	check(s.layout.count() == n0 + 2 and s.stack.size() == h0 + 1, "click places the original and its mirror as one undo step")
	check(s.layout.object_at(base + Vector2i(21, 3)) != null, "mirrored copy on the far side of the line")
	s.stack.undo()
	check(s.layout.count() == n0, "one undo removes both")
	# Screen mirror flips a rotatable item.
	s.set_symmetry_kind(LayoutTools.KIND_SCREEN)
	s.set_symmetry_tile(base + Vector2i(12, 9))
	s.place_flipped = false
	s.set_active_item(tall.id)
	var po := _free_origin(tall, base + Vector2i(14, 9))
	var placed := s.place_objects([s.make_object(tall, po)], "Place")
	var mo := s.layout.get_obj(placed[placed.size() - 1]) if placed.size() == 2 else null
	check(mo != null and mo.flipped and mo.size == tall.size_for(true), "screen mirror places the mirrored (rotated) item")
	s.stack.undo()
	main.dock.tool_action.emit("symmetry", false)
	# Outline brush (connection shapes come from the normal renderer logic).
	s.set_active_item(fid)
	s.brush = "outline"
	var a := base + Vector2i(1, 1)
	var b := a + Vector2i(5, 4)
	n0 = s.layout.count()
	h0 = s.stack.size()
	var pa := _screen_of_tile(a)
	var pb := _screen_of_tile(b)
	_move(pa)
	_button(pa, true)
	_move(pa.lerp(pb, 0.5), MOUSE_BUTTON_MASK_LEFT)
	_move(pb, MOUSE_BUTTON_MASK_LEFT)
	await _frames(1)
	check(ov.ghosts.size() == 18 and ov.ghosts[0].has("mask"), "outline preview: perimeter ghosts with connection shapes (%d)" % ov.ghosts.size())
	_button(pb, false)
	check(s.layout.count() == n0 + 18 and s.stack.size() == h0 + 1, "outline: 6×5 perimeter is one undo step")
	check(s.layout.object_at(a + Vector2i(2, 2)) == null, "outline leaves the inside empty")
	var corner := s.layout.object_at(a)
	check(Connections.mask_for(s.layout, s.db, corner) == (Connections.SE | Connections.SW), "outline corner connects both ways")
	s.stack.undo()
	# Line brush on a fence previews connected pieces; Esc cancels mid-gesture.
	s.brush = "line"
	n0 = s.layout.count()
	_move(pa)
	_button(pa, true)
	_move(_screen_of_tile(a + Vector2i(4, 0)), MOUSE_BUTTON_MASK_LEFT)
	await _frames(1)
	check(ov.ghosts.size() == 5 and ov.ghosts[2]["mask"] == (Connections.NW | Connections.SE), "fence line preview shows straight pieces")
	check(lt.cancel(), "cancel ends the gesture")
	_button(_screen_of_tile(a + Vector2i(4, 0)), false)
	check(s.layout.count() == n0, "cancelled line places nothing")
	s.brush = "single"
	s.set_tool("select")
	# Repeat, with a live preview that survives hovering.
	var lamp := _first_item(func(it: ItemDef) -> bool: return it.footprint == Vector2i.ONE and it.connect_style.is_empty())
	var src: Array = s.place_objects([s.make_object(lamp, base + Vector2i(2, 10)), s.make_object(lamp, base + Vector2i(4, 10))], "Two")
	s.select(src, false, false)
	await _frames(1)
	check(main.dock._sel_row.visible and not main.dock._align_btns[0].disabled and main.dock._dist_btns[0].disabled, "selection tools appear (align needs 2, spacing 3)")
	lt.set_repeat_params({"cols": 3, "rows": 2, "gap": Vector2i(1, 1)})
	main.dock.tool_action.emit("repeat", true)
	_move(_screen_of_tile(base + Vector2i(20, 15)))
	await _frames(2)
	check(ov.ghosts.size() == 10, "repeat preview survives hover: %d ghosts" % ov.ghosts.size())
	n0 = s.layout.count()
	h0 = s.stack.size()
	main.dock.tool_action.emit("repeat_apply", null)
	check(s.layout.count() == n0 + 10 and s.stack.size() == h0 + 1, "repeat 3×2 applies as one undo step")
	check(lt.mode == "" and ov.ghosts.is_empty(), "repeat preview closes after applying")
	s.stack.undo()
	# Align / distribute through the dock.
	var trio: Array = s.place_objects([s.make_object(lamp, base + Vector2i(2, 13)), s.make_object(lamp, base + Vector2i(5, 15)), s.make_object(lamp, base + Vector2i(11, 16))], "Three")
	s.select(trio, false, false)
	h0 = s.stack.size()
	main.dock.tool_action.emit("align", "top")
	check(s.layout.get_obj(trio[1]).origin.y == base.y + 13 and s.layout.get_obj(trio[2]).origin.y == base.y + 13 and s.stack.size() == h0 + 1, "align top as one undo step")
	main.dock.tool_action.emit("distribute", LayoutTools.AXIS_ALONG)
	check(s.layout.get_obj(trio[1]).origin.x == base.x + 6 or s.layout.get_obj(trio[1]).origin.x == base.x + 7, "equal spacing moves the middle object")
	s.stack.undo()
	s.stack.undo()
	# Stamps: save the selection, list it, place it, one undo step, export/import.
	s.select(src, false, false)
	var st: Dictionary = lt.save_selection_stamp("Selftest stamp")
	check(not st.is_empty() and FileAccess.file_exists(lt.stamps.thumb_path(st["id"])), "stamp saved with a thumbnail")
	check(lt.panel._ids.has(st["id"]), "stamp listed in the panel")
	lt.begin_stamp(lt.stamps.get_stamp(st["id"]))
	var at := _screen_of_tile(base + Vector2i(15, 12))
	_move(at)
	await _frames(2)
	check(ov.ghosts.size() == 2, "stamp ghost follows the pointer")
	n0 = s.layout.count()
	h0 = s.stack.size()
	_button(at, true)
	_button(at, false)
	check(s.layout.count() == n0 + 2 and s.stack.size() == h0 + 1, "stamp click places it as one undo step")
	s.stack.undo()
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	lt._unhandled_input(esc)
	check(lt.mode == "", "Esc stops stamping")
	var out := "user://selftest_stamp.%s" % StampLibrary.EXT
	check(lt.stamps.export_file(st["id"], out) == OK, "stamp exported")
	var imp: Dictionary = lt.panel.import_path(out)
	check(not (imp["stamp"] as Dictionary).is_empty() and lt.stamps.list().size() == 2, "stamp imported as a new entry")
	for e in lt.stamps.list():
		lt.stamps.delete(str(e["id"]))
	DirAccess.remove_absolute(out)
	# Landmarks refuse every tool.
	var lm_id := "farmhouse" if s.map.landmark("farmhouse") != null else (s.map.landmarks[0].id if not s.map.landmarks.is_empty() else "")
	if not lm_id.is_empty():
		s.select_landmark(lm_id)
		h0 = s.stack.size()
		check(not s.align_selection("left") and s.make_stamp("x").is_empty() and s.repeat_plan(2, 2, Vector2i.ZERO).is_empty() and s.apply_repeat(2, 2, Vector2i.ZERO).is_empty() and s.stack.size() == h0, "a selected landmark can't be aligned, copied, repeated or stamped")
		s.clear_landmark_selection()
	# Issues stay current: conflicts match a full scan; analysis follows mode and level.
	var locked := _first_item(func(it: ItemDef) -> bool: return it.unlock_level > 1 and it.footprint == Vector2i.ONE)
	var over: Array = s.place_objects([s.make_object(locked, base + Vector2i(9, 2))], "Locked item")
	var lock_uid: int = over[0] if not over.is_empty() else -1
	check(lock_uid > 0 and s.conflicts().keys() == PlacementRules.find_conflicts(s.layout, s.map).keys(), "conflict index agrees with a full scan")
	var level_before := int(s.layout.profile.get("level", 1))
	main._set_farm_level(1)
	s.set_mode(FarmLayout.MODE_REALISTIC)
	check(ov.issues.has(lock_uid), "Realistic mode lists the locked item right away")
	main._set_farm_level(locked.unlock_level)
	check(not ov.issues.has(lock_uid) or RealisticAnalyzer.LEVEL_LOCKED not in s.analysis().issues.get(lock_uid, []), "raising the farm level clears it right away")
	main.inspector.rebuild()
	check(is_same(main.inspector.report, s.analysis()), "inspector and canvas share one analysis")
	s.set_mode(FarmLayout.MODE_CREATIVE)
	main._set_farm_level(level_before)


func _touches_landmark(area: Rect2i) -> bool:
	## Approximate landmarks allow placement, but their sprites still catch clicks.
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			if _s().map.landmark_at(Vector2i(x, y)) >= 0:
				return true
	return false


func _grab_tile(o: PlacedObject) -> Vector2i:
	## A footprint tile whose centre picks `o` (centre tile first).
	var c := o.origin + Vector2i((o.size.x - 1) / 2, (o.size.y - 1) / 2)
	if main.renderer.pick(Iso.tile_center(c)) == o.uid:
		return c
	for y in o.size.y:
		for x in o.size.x:
			var t := o.origin + Vector2i(x, y)
			if main.renderer.pick(Iso.tile_center(t)) == o.uid:
				return t
	return c


# --- integration ---------------------------------------------------------------

func _integration() -> void:
	print("Data")
	check(App.db.count() >= 1900, "catalogue loaded (%d items)" % App.db.count())
	check(App.db.errors.is_empty(), "catalogue has no errors %s" % str(App.db.errors.slice(0, 3)))
	check(App.maps.has("hayday_farm") and not App.maps.has("hayday_farm_h1"), "farm world loaded (retired h1 map not shipped)")
	var pub := WorldLoader.load("res://data/maps/hayday_farm.json", [], "")
	check(pub.schema_version == 2 and pub.frame == "game" and pub.plots.size() == 52 and pub.landmarks.size() == 5 and not pub.is_game_data(),
		"public map v2: game frame, 52 plots, 5 approximate landmarks")
	check(not App.world_label().is_empty() and str(App.map.provenance.get("active", "")) in ["public", "private"], "world provenance shown: %s" % App.world_label())
	if App.map.is_game_data():
		check(App.map.plots.size() >= 52 and not App.map.landmarks.is_empty() and App.map.landmark("farmhouse") != null, "private world data replaces the public map")
	else:
		check(App.map.plots.size() == 52, "main section has 52 plots")
	var st := App.assets.stats(App.db)
	check(float(st["with_art"]) / st["items"] > 0.99, "placeholder art for %d/%d items" % [st["with_art"], st["items"]])
	check(App.boot_ms < 5000.0, "services boot in %.0f ms" % App.boot_ms)
	# Every sample is a v2 layout without landmark items that fits the public map
	# with the public catalogue (what the generator guarantees). With a private
	# pack active, footprints/landmarks differ: collisions are reported, never fixed.
	var pdb := ItemDatabase.new()
	pdb.load_default()
	var dir := DirAccess.open("res://data/samples")
	var nsamples := 0
	for f in dir.get_files():
		if f.ends_with(LayoutIO.FILE_EXT):
			var path := "res://data/samples".path_join(f)
			var rep := LayoutIO.LoadReport.new()
			var l := LayoutIO.load_file(path, pdb, rep, pub)
			check(l != null and rep.missing_items.is_empty() and rep.migrated_from < 0 and rep.migrated_landmarks.is_empty()
				and rep.footprint_changes.is_empty() and _landmark_items_in(l) == 0 and PlacementRules.find_conflicts(l, pub).is_empty(),
				"sample %s: v2, no landmark items, no conflicts on the public map" % f)
			var rep2 := LayoutIO.LoadReport.new()
			var l2 := App.library.load_path(path, rep2)
			check(l2 != null and l2.count() == (l.count() if l else -1), "sample %s opens in the active world with every object kept" % f)
			if l2 != null and (App.map.is_game_data() or not App.db.overrides_pack.is_empty()):
				print("  info sample %s with private data: %d collision(s), %d footprint change(s) reported" % [f, rep2.collisions.size(), rep2.footprint_changes.size()])
			nsamples += 1
	check(nsamples >= 5, "%d sample layouts" % nsamples)
	await _migration_check()

	print("Editing")
	App.open_layout(App.new_layout("Selftest farm", "starter"))
	main._fit_or_restore()
	main.camera.smooth = false
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5
	await _frames(3)
	var s := _s()
	var base := s.layout.count()
	var ids := {}
	var any_locked := false
	for o: PlacedObject in s.layout.objects.values():
		ids[o.item_id] = true
		any_locked = any_locked or o.locked
	check(base == 2 and ids.has("barn") and ids.has("silo"), "starter template: barn + silo only (%s)" % str(ids.keys()))
	check(not any_locked, "starter buildings are movable (not locked)")
	check(_landmark_items_in(s.layout) == 0, "no landmark items placed as objects")
	check(int(s.layout.profile.get("level", -1)) == App.default_farm_level(), "new layout starts at the default farm level (%d)" % App.default_farm_level())
	_template_check()
	await _landmark_check()
	await _world_ui_check()
	await _camera_check()
	await _drag_check()
	await _world_art_check()
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
	# Grab the bakery where it is visible: with tall original art an object in
	# front may cover its centre, exactly as a user would see it.
	var grab := _grab_tile(placed)
	var grab_obj := s.layout.get_obj(main.renderer.pick(Iso.tile_center(grab)))
	_drag_tiles(grab, target + (grab - at))
	var moved := s.layout.object_at(target + Vector2i(1, 1))
	check(moved != null and moved.uid == placed.uid, "dragging moves the bakery (one gesture; grabbed %s at tile %s)" % [grab_obj.item_id if grab_obj else "nothing", str(grab)])
	check(s.stack.size() == steps + 1, "a drag-move is a single undo step")
	check(s.layout.object_at(at + Vector2i(1, 1)) == null or s.layout.object_at(at + Vector2i(1, 1)).uid != placed.uid, "old tiles were freed")
	# Invalid drop snaps back: the farmhouse is a fixed landmark of the world.
	var fh_tile := _landmark_tile("farmhouse")
	if fh_tile.x != -9999 and App.map.landmark("farmhouse").blocks_placement():
		var before := moved.origin
		main.camera.center_on(Iso.tile_center(before))
		await _frames(2)
		_drag_tiles(before + Vector2i(1, 1), fh_tile + Vector2i(1, 1))
		check(moved.origin == before, "dropping onto the farmhouse landmark is rejected (object stays)")
	# Locked objects cannot be moved/deleted.
	var barn: PlacedObject = null
	for o: PlacedObject in s.layout.objects.values():
		if o.item_id == "barn":
			barn = o
	if barn:
		s.select([barn.uid])
		_key(KEY_L)
		check(barn.locked, "L locks the barn")
		var c0 := s.layout.count()
		_key(KEY_DELETE)
		check(s.layout.count() == c0, "locked barn survives Delete")
		_key(KEY_L)
		check(not barn.locked, "L unlocks it again")
		s.clear_selection()
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
	var nsel := s.removable_selection().size()
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
	# Asset packs: zip install, thumbnails, variants, overrides, Asset Manager.
	await _asset_pack_check()
	await _world_pack_check()
	await _load_report_check()
	await _layout_tools_check()
	App.library.delete(s.layout.id)
	await _session_wiring_check()
	await _ui_panels_check()
	await _plan_check()
	await _plan_extras_check()
	await _qa_journeys()


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


const SyntheticPack := preload("res://tests/fixtures/synthetic_pack.gd")


func _asset_pack_check() -> void:
	print("Asset packs")
	var lib := App.assets
	PackInstaller.uninstall(SyntheticPack.PACK_ID)   # leftovers of an aborted run
	App.reload_assets()
	var zip := "user://selftest_assets/synthetic_pack.zip"
	var built: Dictionary = SyntheticPack.build_zip(zip, lib, App.db)
	check(built["ok"], "built a synthetic pack zip from placeholder PNGs (%d files) %s" % [built["files"], built["error"]])
	var r: PackInstaller.Result = App.install_pack(ProjectSettings.globalize_path(zip))
	check(r.ok and r.pack_id == SyntheticPack.PACK_ID, "zip with pack.json one folder deep installs: %s" % r.summary())
	var dir := ProjectSettings.globalize_path(AssetLibrary.USER_PACKS.path_join(r.pack_id))
	check(FileAccess.file_exists(dir.path_join("pack.json")) and FileAccess.file_exists(dir.path_join("items/bakery.png")), "pack extracted to user://asset_packs/%s" % r.pack_id)
	var root_dir := DirAccess.open(AssetLibrary.USER_PACKS)
	root_dir.include_hidden = true
	var hidden := Array(root_dir.get_directories()).filter(func(d): return str(d).begins_with("."))
	check(hidden.is_empty(), "atomic install leaves no temp folders")
	var pid := r.pack_id
	var pk := lib.pack_by_id(pid)
	check(not pk.is_empty() and pk["version"] == "1.0-test" and str(pk["provenance"].get("generator", "")).ends_with("synthetic_pack.gd"), "pack version + provenance exposed in pack_list()")
	check(lib.art_source("bakery") == pid and lib.art_status("bakery") == "original", "installed pack wins over the placeholders")
	check(lib.art_source("barn") != pid and lib.has_art("barn"), "items the pack lacks keep their previous art")
	var tl := lib.texture_loads
	var thl := lib.thumb_loads
	var th := lib.get_thumbnail("bakery")
	check(th != null and th.get_width() == 64 and lib.texture_loads == tl and lib.thumb_loads == thl + 1, "catalogue thumbnail comes from the thumb file without loading the full texture")
	check(lib.variants_of("bakery") == ["winter"], "variants_of lists the pack's variants")
	check(lib.missing_files(pid) == ["items/popcorn_pot.png"], "missing image detected: %s" % str(lib.missing_files(pid)))
	check(lib.get_sprite("popcorn_pot") != null and lib.get_sprite("popcorn_pot").pack_id != pid, "missing image falls back to the next pack")
	check(lib.needs_review("feed_mill") and lib.entry_of("feed_mill").get("auto_anchor", false), "auto-anchored art is flagged for review")
	# The farm renders the pack: place a bakery and switch its variant.
	var s := _s()
	var bakery := App.db.get_item("bakery")
	var at := _free_origin(bakery, Vector2i(22, 22))
	var po := PlacedObject.new()
	po.item_id = "bakery"
	po.origin = at
	po.size = bakery.footprint
	var add := EditCommands.AddObjects.new([po])
	s.execute(add)
	var uid: int = add.added_uids()[0]
	var obj := s.layout.get_obj(uid)
	await _frames(2)
	var spr: AssetLibrary.SpriteInfo = main.renderer.sprite_of(uid)
	check(spr != null and spr.pack_id == pid, "renderer draws the placed bakery with pack art")
	s.select([uid])
	main.inspector.show_tab(0)
	main.inspector.rebuild()
	check(main.inspector.variant_option != null and main.inspector.variant_option.item_count == 2, "inspector offers a variant picker for art with variants")
	var steps := s.stack.size()
	main._on_inspector_action("variant", "winter")
	check(obj.variant == "winter" and s.stack.size() == steps + 1, "choosing a variant is one undoable command")
	check(main.renderer.sprite_of(uid).path.ends_with("bakery__winter.png"), "renderer switched to the variant image")
	_key(KEY_Z, true)
	check(obj.variant == "" and main.renderer.sprite_of(uid).path == "items/bakery.png", "Ctrl+Z restores the base image")
	_key(KEY_Z, true, true)
	check(obj.variant == "winter", "Ctrl+Shift+Z re-applies the variant")
	var save_rep := LayoutIO.LoadReport.new()
	var round_trip := LayoutIO.from_dict(LayoutIO.to_dict(s.layout), App.db, save_rep)
	check(round_trip.get_obj(uid) != null and round_trip.get_obj(uid).variant == "winter", "variant is saved with the layout")
	# Asset Manager: Ctrl+Shift+A, anchor edit -> overrides.json -> renderer.
	s.select([uid])
	_key(KEY_A, true, true)
	await _frames(3)
	var am: AssetManager = null
	for c in main.modal_layer.get_children():
		if c is Modal and c.has_meta("asset_manager"):
			am = c.get_meta("asset_manager")
	check(am != null and am.selected_id == "bakery", "Ctrl+Shift+A opens the Asset Manager on the selected item")
	if am == null:
		return
	await _frames(3)
	check(am.preview.layers.size() == 1 and am.preview.editable, "preview shows the editable original on its footprint")
	am.set_view_mode("onion")
	check(am.preview.layers.size() == 2, "onion skin shows placeholder + original")
	var a0: Vector2 = lib.get_sprite("bakery", AssetLibrary.BASE_VARIANT).anchor
	am.set_variant(AssetLibrary.BASE_VARIANT)
	am.nudge(Vector2(3, 0))
	am.nudge(Vector2(0, -2))
	am.flush()
	var ov: Dictionary = lib.overrides_of(pid, "bakery")
	check(ov.get("anchor", []) == [a0.x - 3.0, a0.y + 2.0], "arrow nudges saved to overrides.json as one anchor (%s)" % str(ov.get("anchor")))
	check(FileAccess.file_exists(dir.path_join("overrides.json")), "overrides.json written in the pack folder")
	s.layout.set_property([uid], "variant", [""])
	await _frames(1)
	check(main.renderer.sprite_of(uid).anchor == Vector2(a0.x - 3.0, a0.y + 2.0), "renderer picked up the new anchor")
	# Mouse drag on the preview moves the art (anchor moves the other way).
	var pv := am.preview
	var drag_scale: float = float(pv._active()["scale"]) * pv.zoom
	var p0 := pv.size * 0.5
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = p0
	pv._gui_input(down)
	var mv := InputEventMouseMotion.new()
	mv.position = p0 + Vector2(40, 0)
	pv._gui_input(mv)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = mv.position
	pv._gui_input(up)
	am.flush()
	var dragged: Array = lib.overrides_of(pid, "bakery").get("anchor", [])
	var want_x := snappedf(a0.x - 3.0 - 40.0 / drag_scale, 0.5)
	check(dragged.size() == 2 and absf(float(dragged[0]) - want_x) <= 0.5 and float(dragged[1]) == a0.y + 2.0, "dragging the art 40 px saved anchor x %.1f (expected %.1f)" % [float(dragged[0]) if dragged.size() == 2 else -1.0, want_x])
	am.mark_verified(true)
	check(lib.is_verified("bakery") and not lib.needs_review("bakery"), "Mark verified persists")
	am.select_item("silo")
	am.reject()
	check(lib.art_source("silo") != pid and lib.has_art("silo") and lib.is_rejected("silo"), "Wrong match → silo falls back to the next pack (%s)" % lib.art_source("silo"))
	am.select_item("bakery")
	am._spin["scale"].value = 1.1
	am.flush()
	var n := am.apply_scale_to_category(false)
	check(n >= 3 and absf(float(lib.overrides_of(pid, "dairy").get("scale", 0.0)) - 1.1) < 0.001, "scale applied to %d production sprites of the pack" % n)
	am.show_tab(1)
	await _frames(2)
	check(am._review_items.size() == 1 and am._review_results.item_count >= 3, "review queue lists the image with its suggestions")
	am.assign_review_to("sugar_mill")
	check(lib.art_source("sugar_mill") == pid and lib.review_queue(pid)[0]["assigned"] == "sugar_mill", "review image assigned to an item via overrides")
	am.show_tab(2)
	await _frames(2)
	check(am._packs_box.get_child_count() >= 3, "packs tab lists every pack")
	am.modal.close()
	await _frames(2)
	# Everything survives a full reload.
	App.reload_assets()
	check(lib.overrides_of(pid, "bakery").get("anchor", []) == dragged and lib.is_verified("bakery") and lib.is_rejected("silo") and lib.art_source("sugar_mill") == pid, "overrides re-applied after reload")
	# Re-installing (pack update) keeps the user's overrides.
	var r2: PackInstaller.Result = App.install_pack(ProjectSettings.globalize_path(zip))
	check(r2.ok and r2.replaced and r2.kept_overrides and lib.is_verified("bakery"), "updating the pack keeps overrides")
	# Clean up: uninstall and the placeholders return.
	s.execute(EditCommands.RemoveObjects.new([uid]))
	check(PackInstaller.uninstall(pid) == OK, "pack uninstalled")
	App.reload_assets()
	check(lib.art_source("bakery") != pid and lib.pack_by_id(pid).is_empty(), "previous art back after uninstall")


func _world_pack_check() -> void:
	## A pack that declares world data + catalogue corrections (synthetic: a
	## copy of the PUBLIC map with an extra made-up landmark) replaces the world
	## on reload; removing it restores the previous world and catalogue.
	print("World packs")
	var s := _s()
	var pid := "selftest_world"
	PackInstaller.uninstall(pid)   # leftovers of an aborted run
	var dir := AssetLibrary.USER_PACKS.path_join(pid)
	DirAccess.make_dir_recursive_absolute(dir.path_join("world"))
	var world: Dictionary = JsonUtil.read_json("res://data/maps/hayday_farm.json")
	world["provenance"] = {"kind": "private_game_data", "source": "selftest: synthetic copy of the public map", "generated": "2026-01-01", "confidence": "approximate"}
	(world["landmarks"] as Array).append({"id": "selftest_statue", "name": "Selftest Statue", "origin": [30, 1], "footprint": [1, 1], "confidence": "approximate",
		"states": ["broken", "repaired"], "default_state": "repaired", "fallback_art": "barn"})
	world["initial_objects"] = [{"item": "barn", "x": 2, "y": 2, "group": "start"}, {"item": "silo", "x": 7, "y": 2, "group": "start"}]
	JsonUtil.write_atomic(dir.path_join("world/world.json"), JSON.stringify(world), false)
	var bush_item := App.db.get_item("raspberry_bush")
	var fp := bush_item.footprint
	JsonUtil.write_atomic(dir.path_join("catalog_overrides.json"), JSON.stringify({"format": ItemDatabase.OVERRIDES_FORMAT, "version": 1,
		"items": {"raspberry_bush": {"footprint": [fp.y, fp.x], "change": "axis_swap"}}}), false)
	JsonUtil.write_atomic(dir.path_join("pack.json"), JSON.stringify({"format": AssetLibrary.PACK_FORMAT, "id": pid, "name": "Selftest world",
		"version": "0.0-selftest", "priority": 5000, "sprites": {}, "world": "world/world.json", "catalog_overrides": "catalog_overrides.json"}), false)
	var label0 := App.world_label()
	var pack0 := App.db.overrides_pack
	var bush: PlacedObject = null
	for o: PlacedObject in s.layout.objects.values():
		if o.item_id == "raspberry_bush":
			bush = o
	var bsize := bush.size if bush else Vector2i.ZERO
	var bflip := bush.flipped if bush else false
	var got: Array = []
	var cb := func(): got.append(true)
	App.map_changed.connect(cb)
	var steps := s.stack.size()
	App.reload_assets()
	await _frames(2)
	check(got.size() == 1 and App.map.landmark("selftest_statue") != null and s.map == App.map and App.library.map == App.map,
		"a pack with world data replaces the world on reload (map_changed; session + library rebound)")
	check(App.world_label().contains("0.0-selftest") and App.map.is_game_data(), "provenance names the pack: %s" % App.world_label())
	check(App.db.overrides_pack == pid and App.db.get_item("raspberry_bush").footprint == Vector2i(fp.y, fp.x), "catalogue corrections of the pack applied")
	check(bush != null and bush.size == bsize and bush.flipped != bflip and s.stack.size() == steps + 1,
		"open layout: an axis-swapped footprint keeps its tiles (flip toggled) as one undo step")
	check(App.has_initial_objects() and App.layout_templates().any(func(t): return t["id"] == "new_farm"), "fresh game farm template offered with world data")
	var skey := LandmarkView.key_of("selftest_statue")
	check(main.renderer.world_entry_keys().has(skey) and main.renderer.world_entry_keys().size() == App.map.landmarks.size(),
		"the new world's landmarks are drawn after map_changed (%d world entries)" % main.renderer.world_entry_keys().size())
	check(str(main.renderer.world_entry(skey).get("variant", "")) == "repaired", "landmark drawn in its default state")
	# Inspector state picker -> undoable world-state command -> renderer variant.
	s.select_landmark("selftest_statue")
	main.inspector.rebuild()
	var so: OptionButton = main.inspector.landmark_state_option
	check(main.inspector.landmark_card_id == "selftest_statue" and so != null and so.item_count == 2, "landmark card offers its states")
	if so != null:
		var bi := -1
		for i in so.item_count:
			if str(so.get_item_metadata(i)) == "broken":
				bi = i
		var st0 := s.stack.size()
		so.select(bi)
		so.item_selected.emit(bi)
		await _frames(1)
		check(s.layout.landmark_state("selftest_statue") == "broken" and str(main.renderer.world_entry(skey).get("variant", "")) == "broken"
			and s.stack.size() == st0 + 1, "choosing a state is one undo step and redraws the landmark")
		_key(KEY_Z, true)
		check(str(main.renderer.world_entry(skey).get("variant", "")) == "repaired", "Ctrl+Z restores the default state")
	s.clear_selection()
	check(PackInstaller.uninstall(pid) == OK, "world pack removed")
	App.reload_assets()
	await _frames(2)
	check(got.size() == 2 and App.map.landmark("selftest_statue") == null and App.world_label() == label0, "removing it restores the previous world (%s)" % App.world_label())
	check(App.db.overrides_pack == pack0 and App.db.get_item("raspberry_bush").footprint == fp and bush != null and bush.flipped == bflip,
		"…and the previous catalogue footprints (open layout follows)")
	App.map_changed.disconnect(cb)


# --- world layer: landmarks, templates, migration -------------------------------------

func _landmark_items_in(l: FarmLayout) -> int:
	var n := 0
	for o: PlacedObject in l.objects.values():
		var it := App.db.get_item(o.item_id)
		if it and not it.landmark.is_empty():
			n += 1
	return n


func _landmark_tile(id: String) -> Vector2i:
	## A placement-blocking, on-grid tile of the landmark ((-9999, -9999) = none).
	var lm := App.map.landmark(id)
	if lm == null:
		return Vector2i(-9999, -9999)
	for r in lm.block_rects():
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var t := Vector2i(x, y)
				if App.map.in_bounds(t) and App.map.kind_at(t) != FarmMap.Kind.VOID:
					return t
	return Vector2i(-9999, -9999)


func _template_check() -> void:
	var ids: Array = App.layout_templates().map(func(t): return t["id"])
	check("starter" in ids and "expanded" in ids and "empty" in ids, "templates offered: %s" % str(ids))
	check(("new_farm" in ids) == App.has_initial_objects(), "fresh game farm offered only with the game's initial objects")
	var empty := App.new_layout("t", "empty")
	check(empty.count() == 0, "empty template has no objects")
	var exp := App.new_layout("t", "expanded")
	check(exp.unlocked_plots.size() == App.map.plots.size() and _landmark_items_in(exp) == 0 and exp.count() == 2, "expanded template: all land + barn + silo")
	if App.has_initial_objects():
		var nf := App.new_layout("t", "new_farm")
		check(nf.count() > 0 and _landmark_items_in(nf) == 0 and PlacementRules.find_conflicts(nf, App.map).is_empty(), "fresh game farm template: objects from the world data, no landmarks, no conflicts")
	# A world whose landmark replaces an item listed among the fresh-farm objects
	# (synthetic): the template never places that landmark copy.
	var world := App.map
	App.map = FarmMap.from_data({"format": "hayday-sandbox-map", "schema_version": 2, "id": "selftest_world", "frame": "game",
		"size": [24, 24], "regions": [{"id": "start", "kind": "buildable", "rects": [[0, 0, 24, 24]]}],
		"landmarks": [{"id": "bake_stand", "name": "Bake Stand", "origin": [20, 20], "footprint": [1, 1],
			"replaces_items": ["bakery"], "confidence": "approximate"}],
		"initial_objects": [{"item": "bakery", "x": 2, "y": 2}, {"item": "barn", "x": 8, "y": 2}]})
	var fresh := App.new_layout("t", "new_farm")
	App.map = world
	var fresh_items: Array = fresh.objects.values().map(func(o): return o.item_id)
	check(not "bakery" in fresh_items and "barn" in fresh_items, "fresh-farm template skips items a world landmark replaces (%s)" % str(fresh_items))
	var lvl: Variant = App.settings.get_v("default_farm_level")
	App.settings.set_v("default_farm_level", 60, false)
	check(int(App.new_layout("t", "empty").profile["level"]) == 60, "default farm level setting applies to new layouts")
	App.settings.set_v("default_farm_level", lvl, false)


func _landmark_check() -> void:
	print("Landmarks")
	var s := _s()
	var tile := _landmark_tile("farmhouse")
	check(tile.x != -9999, "farmhouse landmark is on the map")
	if tile.x == -9999:
		return
	var lm := App.map.landmark("farmhouse")
	var lm_before := "%s %s" % [str(lm.origin), str(lm.footprint)]
	var fence := App.db.get_item("fence")
	main.camera.center_on(Iso.tile_center(tile))
	await _frames(2)
	for mode in [FarmLayout.MODE_CREATIVE, FarmLayout.MODE_REALISTIC]:
		s.set_mode(mode)
		var r := PlacementRules.check_item(s.layout, s.map, fence, tile, false)
		if lm.blocks_placement():
			check(not r.ok and r.reason_counts.has(PlacementRules.LANDMARK), "%s mode: landmark tiles block placement (%s)" % [mode, r.message(s.layout, s.db, s.map)])
			main._on_item_chosen("fence")
			var c0 := s.layout.count()
			_click_tile(tile)
			check(s.layout.count() == c0, "%s mode: clicking the farmhouse with the place tool places nothing" % mode)
			_key(KEY_ESCAPE)
		else:
			check(not r.reason_counts.has(PlacementRules.LANDMARK), "%s mode: an approximate landmark raises no false conflict" % mode)
	s.set_mode(FarmLayout.MODE_CREATIVE)
	_key(KEY_ESCAPE)
	main._on_item_chosen("farmhouse")
	check(s.active_item != "farmhouse", "the farmhouse can't be picked from the catalogue as an object")
	# A selected landmark refuses every edit shortcut.
	check(s.select_landmark("farmhouse") and s.selection.is_empty(), "landmark selection is separate from objects")
	var snap := JSON.stringify(LayoutIO.to_dict(s.layout)["objects"])
	var steps := s.stack.size()
	for k in [KEY_DELETE, KEY_R, KEY_L, KEY_UP]:
		_key(k)
	_key(KEY_C, true)
	_key(KEY_G, true)
	_key(KEY_D, true)
	_key(KEY_ESCAPE)
	check(JSON.stringify(LayoutIO.to_dict(s.layout)["objects"]) == snap and s.stack.size() == steps, "Delete / R / L / arrows / Ctrl+C/G/D change nothing with a landmark selected")
	check("%s %s" % [str(lm.origin), str(lm.footprint)] == lm_before and App.map.landmark("farmhouse") == lm, "the farmhouse never moved")
	check(not s.explain_fixed("farmhouse", "move").is_empty(), "friendly explanation: %s" % s.explain_fixed("farmhouse", "move"))
	s.clear_selection()
	main.controller.stamp_mode = false
	# World look is per layout and undoable.
	s.set_theme("winter")
	check(s.layout.theme() == "winter", "theme change applied")
	_key(KEY_Z, true)
	check(s.layout.theme() == FarmLayout.DEFAULT_THEME, "Ctrl+Z undoes the theme change")


func _migration_check() -> void:
	print("Migration")
	var note := LayoutIO.V1_STARTER_NOTE
	var v1 := {"format": LayoutIO.FORMAT, "schema_version": 1, "app_version": "0.1.0",
		"meta": {"id": "selftest_v1", "name": "Old v1 farm", "mode": "creative"},
		"map": {"id": "hayday_farm", "unlocked_plots": ["main_01"]},
		"objects": [
			{"uid": 1, "item": "farmhouse", "x": 19, "y": 15, "w": 4, "h": 4, "locked": true, "note": note},
			{"uid": 2, "item": "barn", "x": 9, "y": 7, "w": 4, "h": 4, "locked": true, "note": note},
			{"uid": 3, "item": "silo", "x": 14, "y": 7, "w": 3, "h": 3, "locked": true, "note": note},
			{"uid": 4, "item": "truck_and_order_board", "x": 18, "y": 31, "w": 4, "h": 3, "locked": true, "note": note},
			{"uid": 5, "item": "roadside_shop", "x": 24, "y": 31, "w": 3, "h": 3, "locked": true, "note": note},
			{"uid": 6, "item": "mailbox", "x": 23, "y": 15, "w": 1, "h": 1, "locked": true, "note": note},
			{"uid": 7, "item": "bakery", "x": 7, "y": 18, "w": 3, "h": 3},
		],
		"camera": {"x": 0.0, "y": 0.0, "zoom": 1.0}}
	var path := App.library.path_for("selftest_v1")
	var text := JSON.stringify(v1, "\t")
	JsonUtil.write_atomic(path, text, false)
	var rep := LayoutIO.LoadReport.new()
	var l := App.library.load_layout("selftest_v1", rep)
	check(l != null and rep.migrated_from == 1 and rep.shifted == Vector2i(-5, -3), "v1 file upgrades into the game frame")
	if l == null:
		return
	check(rep.migrated_landmarks.size() == 4 and _landmark_items_in(l) == 0 and l.count() == 3, "farmhouse, truck, shop and mailbox leave the layout (kept in migration.migrated_landmarks)")
	var barn: PlacedObject = null
	for o: PlacedObject in l.objects.values():
		if o.item_id == "barn":
			barn = o
	check(barn != null and barn.origin == Vector2i(4, 4) and not barn.locked, "barn keeps its place, starter lock cleared")
	check(not rep.summary().is_empty() and rep.backup_path.ends_with(".v1-backup"), "load report: %s" % rep.summary())
	check(App.library.save(l, false) == OK and FileAccess.file_exists(rep.backup_path) and JsonUtil.read_text(rep.backup_path) == text, "first save keeps the v1 original as .v1-backup")
	var rep2 := LayoutIO.LoadReport.new()
	var again := App.library.load_layout("selftest_v1", rep2)
	check(again != null and rep2.migrated_from < 0 and again.count() == 3 and (again.migration.get("migrated_landmarks", []) as Array).size() == 4, "saved as v2; migration record kept")
	App.library.delete("selftest_v1")
	await _migration_v2_reference_check()


func _migration_v2_reference_check() -> void:
	## A v2 layout with one (missing) reference image, opened through the app:
	## nothing is lost, the report is about this upgrade only, the original is
	## kept, and undo / redo work straight away.
	var v2 := {"format": LayoutIO.FORMAT, "schema_version": 2, "app_version": "0.1.0",
		"meta": {"id": "selftest_v2", "name": "v2 farm", "mode": "creative"},
		"map": {"id": "hayday_farm", "unlocked_plots": []},
		"objects": [{"uid": 1, "item": "bakery", "x": 4, "y": 4, "w": 3, "h": 3}],
		"reference": {"file": "user://references/selftest_missing.png", "opacity": 0.35, "x": 12.0, "y": -40.0,
			"scale": 1.25, "rotation": 0.0, "visible": true, "locked": false, "above": true},
		"migration": {"from": 1, "at": "2026-01-01T00:00:00Z", "shifted_by": [-5, -3], "from_map": "hayday_farm",
			"migrated_landmarks": [{"record": {"uid": 9, "item": "farmhouse", "x": 19, "y": 15, "w": 4, "h": 4}, "landmark": "farmhouse", "reason": "test"}],
			"review_uids": [], "notes": []},
		"world": FarmLayout.default_world_state()}
	var text := JSON.stringify(v2, "\t")
	JsonUtil.write_atomic(App.library.path_for("selftest_v2"), text, false)
	var rep := LayoutIO.LoadReport.new()
	var l := App.library.load_layout("selftest_v2", rep)
	check(l != null and rep.migrated_from == 2 and rep.shifted == Vector2i.ZERO and rep.migrated_landmarks.is_empty()
		and l.count() == 1 and l.get_obj(1).origin == Vector2i(4, 4), "v2 file: no second shift, old landmark record not reported again (%s)" % rep.summary())
	if l == null:
		return
	App.open_layout(l, rep)
	await _frames(2)
	var s := _s()
	var imgs: Array = s.layout.reference.get("images", [])
	check(imgs.size() == 1 and str(imgs[0].get("file", "")) == "user://references/selftest_missing.png" and is_equal_approx(float(imgs[0]["opacity"]), 0.35)
		and bool(s.layout.reference.get("above", false)), "the single v2 reference becomes a one-image list %s" % str(s.layout.reference))
	check(str(main._view_state.get("ref_status", "")).contains("missing"), "a missing reference image is reported, not dropped (%s)" % str(main._view_state.get("ref_status", "")))
	var steps := s.stack.size()
	s.select([1])
	var d := Vector2i.ZERO
	for c in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if d == Vector2i.ZERO and PlacementRules.check_group_move(s.layout, s.map, [1], c).ok:
			d = c
	check(d != Vector2i.ZERO and s.nudge(d) and s.layout.get_obj(1).origin == Vector2i(4, 4) + d, "edit right after the upgrade")
	_key(KEY_Z, true)
	check(s.layout.get_obj(1).origin == Vector2i(4, 4) and s.stack.size() == steps, "undo right after the upgrade")
	_key(KEY_Z, true, true)
	check(s.layout.get_obj(1).origin == Vector2i(4, 4) + d, "redo too")
	var serr := App.save_current(false)
	var bk2 := LayoutIO.backup_path_for(App.library.path_for("selftest_v2"), 2)
	check(serr == OK and JsonUtil.read_text(bk2) == text, "first save keeps the v2 original (%s, backup exists: %s, session layout id %s)" % [error_string(serr), str(FileAccess.file_exists(bk2)), s.layout.id])
	var rep2 := LayoutIO.LoadReport.new()
	var back := App.library.load_layout("selftest_v2", rep2)
	check(back != null and rep2.migrated_from < 0 and back.reference == s.layout.reference and (back.migration.get("migrated_landmarks", []) as Array).size() == 1,
		"v3 reload: reference and migration record kept")
	App.library.delete("selftest_v2")


func _conn_counts(objs: Dictionary) -> Dictionary:
	## "<name>.<signal>" -> number of connections, for every signal of each object.
	var out := {}
	for name in objs:
		var o: Object = objs[name]
		for sg: Dictionary in o.get_signal_list():
			out["%s.%s" % [name, sg["name"]]] = o.get_signal_connection_list(sg["name"]).size()
	return out


func _session_counts() -> Dictionary:
	return _conn_counts({"session": _s(), "layout": _s().layout, "stack": _s().stack})


func _app_counts() -> Dictionary:
	## Long-lived emitters: their connections must not grow with every layout opened.
	return _conn_counts({"app": App, "settings": App.settings, "controller": main.controller, "camera": main.camera,
		"dock": main.dock, "top_bar": main.top_bar, "catalog": main.catalog, "inspector": main.inspector})


func _toasts_with(text: String) -> int:
	var n := 0
	var stack: Array = [main.toasts]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd is Label and (nd as Label).text == text and not nd.is_queued_for_deletion():
			n += 1
		stack.append_array(nd.get_children())
	return n


func _conflicts_fresh(s: EditorSession) -> bool:
	var a: Array = s.conflicts().keys()
	var b: Array = PlacementRules.find_conflicts(s.layout, s.map).keys()
	a.sort()
	b.sort()
	return a == b


func _session_wiring_check() -> void:
	## Opening layouts one after another (and rebuilding the UI) must not stack
	## up signal handlers, leak old sessions, or leave caches pointing at the old
	## document / world.
	print("Session wiring")
	var app0 := _app_counts()
	var per: Array = []
	var first: WeakRef = null
	var templates := ["empty", "starter", "expanded"]
	for i in 3:
		var l := App.new_layout("Wiring %d" % i, templates[i])
		l.id = ""   # not a library layout
		App.open_layout(l)
		await _frames(2)
		if i == 0:
			first = weakref(_s())
		per.append(_session_counts())
		var probe := "wiring probe %d" % i
		_s().message.emit(probe, "info")
		check(_toasts_with(probe) == 1, "layout %d: a session message shows exactly one toast" % (i + 1))
		check(_conflicts_fresh(_s()), "layout %d: conflict index matches a full scan" % (i + 1))
	check(per[0] == per[1] and per[1] == per[2], "three layouts in a row: the same handlers per session")
	var app1 := _app_counts()
	var grew: Array = []
	for k in app1:
		if int(app1[k]) != int(app0.get(k, 0)):
			grew.append("%s %d->%d" % [k, int(app0.get(k, 0)), int(app1[k])])
	check(grew.is_empty(), "long-lived signals keep their handler count across layout switches %s" % str(grew))
	check(first != null and first.get_ref() == null, "an earlier session is freed after switching layouts")
	# Rebuilding the UI (theme / UI scale change) re-runs the session wiring.
	var s := _s()
	var before := _session_counts()
	await main._rebuild_ui()
	await _frames(2)
	check(_session_counts() == before, "rebuilding the UI doesn't connect the session's handlers twice")
	s.message.emit("wiring probe rebuilt", "info")
	check(_toasts_with("wiring probe rebuilt") == 1, "after a UI rebuild a message still shows exactly one toast")
	var lt: LayoutToolController = main.layout_tools
	check(lt.dock == main.dock and is_instance_valid(lt.panel) and lt.panel.is_inside_tree() and main.dock.tool_action.is_connected(lt._on_dock),
		"layout tools follow the rebuilt dock and stamps panel")
	main.dock.tool_action.emit("symmetry", true)
	check(bool(s.symmetry["enabled"]), "the rebuilt dock's symmetry switch reaches the session")
	main.dock.tool_action.emit("symmetry", false)
	# Caches after a world swap and a catalogue footprint correction.
	var at := _free_block(Vector2i(6, 6))
	if at.x >= 0:
		var bk := App.db.get_item("bakery")
		var uids := s.place_objects([s.make_object(bk, at)], "t")
		var fence := App.db.get_item("fence")
		var f_uids := s.place_objects([s.make_object(fence, at + Vector2i(4, 0))], "t")
		check(_conflicts_fresh(s) and not s.conflicts().has(uids[0]), "bakery fits")
		s.execute(EditCommands.SetGeometry.new(uids, [{"size": Vector2i(5, 3), "flipped": false}], "Apply corrected footprints"))
		check(_conflicts_fresh(s) and s.conflicts().has(uids[0]) and s.conflicts().has(f_uids[0]), "a corrected footprint updates the conflict index (both overlapping objects)")
		s.stack.undo()
		check(_conflicts_fresh(s) and not s.conflicts().has(uids[0]), "undo of the correction too")
		var other := FarmMap.from_data({"format": "hayday-sandbox-map", "schema_version": 2, "id": s.map.id, "frame": "game",
			"size": [2, 2], "regions": [{"id": "start", "kind": "buildable", "rects": [[0, 0, 2, 2]]}]})
		var old_map := s.map
		var r0 := s.analysis()
		s.set_map(other)
		check(_conflicts_fresh(s) and s.conflicts().has(uids[0]) and s.analysis() != r0, "a world swap rechecks conflicts and the analysis")
		s.set_map(old_map)
		check(_conflicts_fresh(s), "…and back")
		App.reload_assets()
		await _frames(1)
		check(_conflicts_fresh(_s()), "a pack reload leaves the conflict index current")
	App.open_layout(App.new_layout("Wiring end", "starter"))
	await _frames(2)


# --- performance -----------------------------------------------------------------

func _perf() -> void:
	var results := {}
	results["world"] = await _bench_world()
	# A: the real farm (all mapped land unlocked), packed densely.
	results["farm"] = await _bench("farm", 4000, App.maps["hayday_farm"])
	# B: synthetic stress maps far beyond any real farm.
	var big := FarmMap.make_simple(160, 160)
	App.maps[big.id] = big
	for n in [2000, 5000, 10000]:
		results[n] = await _bench(str(n), n, big)
	results["thumbnails"] = await _bench_thumbs()
	for k in results:
		print("PERF %s %s" % [k, JSON.stringify(results[k])])
	var r5: Dictionary = results[5000]
	check(r5["sort_ms"] < 1500.0, "full depth sort of %d objects: %.0f ms" % [r5["objects"], r5["sort_ms"]])
	check(r5["edit_resort_ms"] < 1500.0, "single edit incl. re-sort at %d objects: %.0f ms" % [r5["objects"], r5["edit_resort_ms"]])
	check(r5["place_check_us"] < 2000.0, "placement check: %.0f µs" % r5["place_check_us"])
	check(r5["pick_us"] < 5000.0, "pixel-accurate pick: %.0f µs" % r5["pick_us"])
	check(r5["save_ms"] < 3000.0 and r5["load_ms"] < 3000.0, "save %.0f ms / load %.0f ms" % [r5["save_ms"], r5["load_ms"]])
	App.maps.erase(big.id)
	var e5: Dictionary = r5["edits"]
	if e5.has(FarmLayout.MODE_REALISTIC):
		check(float(e5[FarmLayout.MODE_REALISTIC]["total"]["p95"]) < 1500.0, "edit at %d objects, Realistic mode: p95 %.1f ms" % [r5["objects"], e5[FarmLayout.MODE_REALISTIC]["total"]["p95"]])


func _bench_world() -> Dictionary:
	## World layer of the active world: scenery build, ground redraw (one
	## frame), landmark world-entry refresh, landmark-aware hover pick.
	App.open_layout(App.new_layout("World bench", "expanded"))
	await _frames(2)
	var s := _s()
	var t0 := Time.get_ticks_usec()
	main.scenery.setup(s.map, App.assets, s.db)
	var scenery_ms := _ms(t0)
	t0 = Time.get_ticks_usec()
	main.ground.setup(s.map, s.layout.unlocked_plots)
	await _frames(1)   # the redraw happens in the next frame
	var ground_ms := _ms(t0)
	t0 = Time.get_ticks_usec()
	for i in 10:
		main._refresh_world()
	var entries_ms := _ms(t0) / 10.0
	var w: Vector2 = main.camera.view_center()
	t0 = Time.get_ticks_usec()
	for i in 500:
		main.controller.pick_at(w + Vector2(i % 50, i / 50) * 7.0)
	var pick_us := _ms(t0) * 1000.0 / 500.0
	var r := {"world": s.map.provenance_label(), "landmarks": s.map.landmarks.size(), "scenery_sprites": main.scenery._items.size(),
		"scenery_build_ms": snappedf(scenery_ms, 0.1), "ground_redraw_frame_ms": snappedf(ground_ms, 0.1),
		"world_entries_refresh_ms": snappedf(entries_ms, 0.01), "hover_pick_us": snappedf(pick_us, 0.1)}
	check(scenery_ms < 1000.0 and entries_ms < 50.0 and pick_us < 2000.0,
		"world layer: scenery %.0f ms, ground redraw+frame %.0f ms, landmark refresh %.1f ms, hover pick %.0f µs" % [scenery_ms, ground_ms, entries_ms, pick_us])
	return r


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
	var edits := await _bench_edits(l, map, rng) if label != "farm" else {}
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
		"frame_ms": snappedf(frame_ms, 0.01), "mem_mb": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1), "edits": edits}


static func _stats(samples: Array) -> Dictionary:
	## {mean, p95} of millisecond samples.
	if samples.is_empty():
		return {"n": 0}
	var v := samples.duplicate()
	v.sort()
	var total := 0.0
	for x: float in v:
		total += x
	return {"n": v.size(), "mean": snappedf(total / v.size(), 0.01), "p95": snappedf(float(v[clampi(int(ceil(0.95 * v.size())) - 1, 0, v.size() - 1)]), 0.01)}


func _fine_ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


func _bench_edits(l: FarmLayout, map: FarmMap, rng: RandomNumberGenerator) -> Dictionary:
	## Per-edit UI cost, Creative and Realistic: one synchronous edit (command ->
	## history_changed -> issues, tints, top bar) plus the draw-order update, and
	## each component on its own. Cycles move / add / undo so the layout stays dense.
	var s := _s()
	var out := {}
	var idx: Variant = null
	if ClassDB.class_exists("ConflictIndex") or ResourceLoader.exists("res://src/core/conflict_index.gd"):
		idx = load("res://src/core/conflict_index.gd").new(l, map)
	var ids: Array = []
	for it: ItemDef in App.db.ordered:
		if it.can_place() and it.footprint == Vector2i.ONE:
			ids.append(it.id)
	var keys := l.objects.keys()
	for mode: String in [FarmLayout.MODE_CREATIVE, FarmLayout.MODE_REALISTIC]:
		s.set_mode(mode)
		main.inspector.rebuild()
		await _frames(1)
		var total: Array = []
		var draw: Array = []
		var full_conf: Array = []
		var index_conf: Array = []
		var full_an: Array = []
		var fast_an: Array = []
		var inspector: Array = []
		var i := 0
		while total.size() < 45 and i < 2000:
			i += 1
			var cmd: Command = null
			var undo := false
			match total.size() % 3:
				0:
					var u: int = keys[rng.randi() % keys.size()]
					var delta := Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3))
					if l.objects.has(u) and delta != Vector2i.ZERO and PlacementRules.check_group_move(l, map, [u], delta).ok:
						cmd = EditCommands.MoveObjects.new([u], delta)
				1:
					var t := Vector2i(rng.randi_range(0, map.size.x - 1), rng.randi_range(0, map.size.y - 1))
					if PlacementRules.check_rect(l, map, Rect2i(t, Vector2i.ONE)).ok:
						var po := PlacedObject.new()
						po.item_id = ids[rng.randi() % ids.size()]
						po.origin = t
						cmd = EditCommands.AddObjects.new([po])
				_:
					undo = true
			if cmd == null and not undo:
				continue
			var t0 := Time.get_ticks_usec()
			if undo:
				s.stack.undo()
			else:
				s.execute(cmd)
			var t1 := Time.get_ticks_usec()
			main.renderer.ensure_sorted()
			var t2 := Time.get_ticks_usec()
			total.append((t2 - t0) / 1000.0)
			draw.append((t2 - t1) / 1000.0)
			t0 = Time.get_ticks_usec()
			PlacementRules.find_conflicts(l, map)
			full_conf.append(_fine_ms(t0))
			t0 = Time.get_ticks_usec()
			var cf: Variant = idx.conflicts() if idx != null else null
			if idx != null:
				index_conf.append(_fine_ms(t0))
			t0 = Time.get_ticks_usec()
			RealisticAnalyzer.analyze(l, s.db, map)
			full_an.append(_fine_ms(t0))
			if idx != null:
				t0 = Time.get_ticks_usec()
				Callable(RealisticAnalyzer, "analyze").call(l, s.db, map, cf)
				fast_an.append(_fine_ms(t0))
			t0 = Time.get_ticks_usec()
			main.inspector.rebuild()
			inspector.append(_fine_ms(t0))
		out[mode] = {"total": _stats(total), "draw_index": _stats(draw), "conflicts_full": _stats(full_conf),
			"conflicts_index": _stats(index_conf), "analyzer_full": _stats(full_an), "analyzer_with_index": _stats(fast_an),
			"inspector_rebuild": _stats(inspector)}
	s.set_mode(FarmLayout.MODE_CREATIVE)
	await _frames(1)
	return out


func _bench_thumbs() -> Dictionary:
	## The catalogue's own thumbnail batches over the full catalogue, cold (no
	## texture held by anything) and warm. Memory = static + reported texture memory.
	var cat: Node = main.catalog
	cat._list.clear()
	cat._ids.clear()
	cat._icon_queue.clear()
	App.open_layout(App.new_layout("Thumb bench", "expanded"))
	cat._list.clear()
	cat._ids.clear()
	cat._icon_queue.clear()
	await _frames(2)
	var lib := App.assets
	lib.clear_cache()
	await _frames(2)
	var items: Array = App.db.ordered
	var mem0 := OS.get_static_memory_usage()
	var tex0 := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var loads0 := lib.texture_loads + lib.thumb_loads
	var cold: Array = []
	var t_all := Time.get_ticks_usec()
	for b in range(0, items.size(), 24):
		var t0 := Time.get_ticks_usec()
		for j in range(b, mini(b + 24, items.size())):
			var it: ItemDef = items[j]
			lib.get_thumbnail(it.art_key, "", UI.preview_mask(it))
		cold.append(_fine_ms(t0))
	var cold_total := _fine_ms(t_all)
	var mem1 := OS.get_static_memory_usage()
	var tex1 := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var loads1 := lib.texture_loads + lib.thumb_loads
	var warm: Array = []
	for b in range(0, items.size(), 24):
		var t0 := Time.get_ticks_usec()
		for j in range(b, mini(b + 24, items.size())):
			var it: ItemDef = items[j]
			lib.get_thumbnail(it.art_key, "", UI.preview_mask(it))
		warm.append(_fine_ms(t0))
	cat.refresh()
	await _frames(2)
	return {"items": items.size(), "cold_batch_24": _stats(cold), "cold_total_ms": snappedf(cold_total, 0.1), "warm_batch_24": _stats(warm),
		"images_decoded": loads1 - loads0, "static_mem_delta_mb": snappedf((mem1 - mem0) / 1048576.0, 0.1),
		"texture_mem_delta_mb": snappedf((tex1 - tex0) / 1048576.0, 0.1)}


# --- art check (installed private/user packs) --------------------------------------

func _artcheck() -> void:
	## Per catalogue item: does App.assets resolve it to the pack and does the
	## texture really load (non-null, size > 0)? Plus variants, connection
	## pieces, thumbnails, implausible world sizes and memory. Counts only.
	var pack_id := "hayday_original"
	var out_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--artcheck-pack="):
			pack_id = a.substr(16)
		elif a.begins_with("--artcheck-out="):
			out_path = a.substr(15)
	if out_path.is_empty():
		out_path = _private_root().path_join("mapping/godot_artcheck.json") if not _private_root().is_empty() else "user://artcheck.json"
	var lib := App.assets
	var pk := lib.pack_by_id(pack_id)
	check(not pk.is_empty(), "pack %s installed (%s)" % [pack_id, str(pk.get("version", "-"))])
	if pk.is_empty():
		return
	var tex_mon := Performance.RENDER_TEXTURE_MEM_USED
	var mem0 := {"static_mb": OS.get_static_memory_usage() / 1048576.0, "texture_mb": Performance.get_monitor(tex_mon) / 1048576.0}
	var by_cat := {}
	var rendered: Array = []
	var not_in_pack: Array = []
	var load_failed: Array = []
	var odd: Array = []
	# 1) thumbnails only (what the catalogue shows)
	var t0 := Time.get_ticks_usec()
	var thumbs_ok := 0
	var thumb_from_file := 0
	var tl0 := lib.texture_loads
	for it: ItemDef in App.db.ordered:
		if lib.art_source(it.art_key) != pack_id:
			continue
		var th := lib.get_thumbnail(it.art_key)
		if th != null and th.get_width() > 0:
			thumbs_ok += 1
		if not str(lib.entry_of(it.art_key).get("thumb", "")).is_empty():
			thumb_from_file += 1
	var thumbs_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var full_loads_during_thumbs := lib.texture_loads - tl0
	await _frames(3)
	var mem_thumbs := {"static_mb": OS.get_static_memory_usage() / 1048576.0, "texture_mb": Performance.get_monitor(tex_mon) / 1048576.0}
	# 2) full sprites
	t0 = Time.get_ticks_usec()
	var var_ok := 0
	var var_total := 0
	var var_bad: Array = []
	var conn_ok := 0
	var conn_total := 0
	var conn_bad: Array = []
	for it: ItemDef in App.db.ordered:
		var c: Dictionary = by_cat.get(it.category, {"items": 0, "in_pack": 0, "rendered": 0, "variants": 0, "variants_ok": 0})
		c["items"] += 1
		var src := lib.art_source(it.art_key)
		if src != pack_id:
			not_in_pack.append(it.id)
			by_cat[it.category] = c
			continue
		c["in_pack"] += 1
		var spr := lib.get_sprite(it.art_key, AssetLibrary.BASE_VARIANT)
		var ok := spr != null and spr.pack_id == pack_id and spr.texture != null and spr.texture.get_width() > 0 and spr.texture.get_height() > 0
		if ok:
			c["rendered"] += 1
			rendered.append(it.id)
			var wsz := spr.texture.get_size() * spr.scale
			var fp := it.footprint
			var diamond_w := float(fp.x + fp.y) * Iso.HALF_W
			var ratio := wsz.x / diamond_w
			var a_in := spr.anchor.x >= -1.0 and spr.anchor.y >= -1.0 and spr.anchor.x <= spr.texture.get_width() + 1 and spr.anchor.y <= spr.texture.get_height() + 1
			if ratio < 0.45 or ratio > 2.2 or not a_in:
				odd.append({"id": it.id, "category": it.category, "fp": [fp.x, fp.y], "world_w": snappedf(wsz.x, 0.1), "world_h": snappedf(wsz.y, 0.1), "w_over_diamond": snappedf(ratio, 0.01), "anchor_inside": a_in, "auto_anchor": bool(lib.entry_of(it.art_key).get("auto_anchor", false))})
		else:
			load_failed.append(it.id)
		for v in lib.variants_of(it.art_key):
			var_total += 1
			c["variants"] += 1
			var vs := lib.get_sprite(it.art_key, v)
			if vs != null and vs.pack_id == pack_id and vs.variant == v and vs.texture != null and vs.texture.get_width() > 0:
				var_ok += 1
				c["variants_ok"] += 1
			else:
				var_bad.append("%s:%s" % [it.id, v])
		if not it.connect_group.is_empty():
			var masks := lib.connection_masks(it.art_key)
			for m in 16:
				if masks.is_empty():
					break
				conn_total += 1
				var cs := lib.get_sprite(it.art_key, "", m)
				if cs != null and cs.pack_id == pack_id and cs.texture != null and cs.texture.get_width() > 0:
					conn_ok += 1
				else:
					conn_bad.append("%s:%d" % [it.id, m])
		by_cat[it.category] = c
	var full_ms := (Time.get_ticks_usec() - t0) / 1000.0
	await _frames(3)
	var mem_full := {"static_mb": OS.get_static_memory_usage() / 1048576.0, "texture_mb": Performance.get_monitor(tex_mon) / 1048576.0}
	for d in [mem0, mem_thumbs, mem_full]:
		for k in d:
			d[k] = snappedf(d[k], 0.1)
	var n_items := App.db.count()
	var res := {"pack": pack_id, "version": pk.get("version", ""), "renderer": RenderingServer.get_current_rendering_driver_name(),
		"display": DisplayServer.get_name(), "items": n_items, "in_pack": n_items - not_in_pack.size(), "rendered": rendered.size(),
		"load_failed": load_failed, "not_in_pack": not_in_pack, "by_category": by_cat,
		"variants_total": var_total, "variants_ok": var_ok, "variants_bad": var_bad,
		"connection_pieces_total": conn_total, "connection_pieces_ok": conn_ok, "connection_bad": conn_bad,
		"thumbnails_ok": thumbs_ok, "thumbnails_from_thumb_file": thumb_from_file, "full_loads_during_thumbs": full_loads_during_thumbs,
		"thumbs_ms": snappedf(thumbs_ms, 0.1), "full_ms": snappedf(full_ms, 0.1), "texture_loads": lib.texture_loads, "thumb_loads": lib.thumb_loads,
		"memory_start": mem0, "memory_after_thumbnails": mem_thumbs, "memory_after_full_sprites": mem_full,
		"odd_world_size": odd, "lib_errors": Array(lib.errors).slice(0, 20), "lib_errors_total": lib.errors.size(),
		"time": Time.get_datetime_string_from_system(true)}
	if out_path.begins_with("user://") or out_path.begins_with("/"):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path.get_base_dir()) if out_path.begins_with("user://") else out_path.get_base_dir())
	JsonUtil.write_atomic(out_path, JsonUtil.stringify(res, true), false)
	var cats: Array = by_cat.keys()
	cats.sort()
	for k in cats:
		var c: Dictionary = by_cat[k]
		print("ARTCHECK CAT %-14s items %4d  in_pack %4d  rendered %4d  variants %3d/%3d" % [k, c["items"], c["in_pack"], c["rendered"], c["variants_ok"], c["variants"]])
	print("ARTCHECK items %d in_pack %d rendered %d load_failed %d variants %d/%d connections %d/%d thumbs %d (full loads during thumbs %d) odd %d" % [n_items, res["in_pack"], rendered.size(), load_failed.size(), var_ok, var_total, conn_ok, conn_total, thumbs_ok, full_loads_during_thumbs, odd.size()])
	print("ARTCHECK MEM start %s | thumbs %s (%.0f ms) | full %s (%.0f ms)" % [str(mem0), str(mem_thumbs), thumbs_ms, str(mem_full), full_ms])
	print("ARTCHECK OUT ", ProjectSettings.globalize_path(out_path))
	check(load_failed.is_empty(), "every item resolved to %s loads its texture (%d failed)" % [pack_id, load_failed.size()])
	check(var_bad.is_empty(), "all %d variants load" % var_total)
	check(conn_bad.is_empty(), "all %d connection pieces load" % conn_total)
	check(full_loads_during_thumbs == 0, "catalogue thumbnails never decode full sprites")


static func _private_root() -> String:
	## Private storage root for files about the user's private pack (never the repo).
	var env := OS.get_environment("HAYDAY_PRIVATE_ASSETS")
	if not env.is_empty():
		return env
	var home := OS.get_environment("USERPROFILE") if OS.has_feature("windows") else OS.get_environment("HOME")
	for c in [home.path_join("hayday-sandbox-private-assets"), "/root/hayday-sandbox-private-assets"]:
		if DirAccess.dir_exists_absolute(c):
			return c
	return ""


# --- editor workflows with an installed pack ------------------------------------------

func _ms(t0: int) -> float:
	return snappedf((Time.get_ticks_usec() - t0) / 1000.0, 0.1)


func _artflow() -> void:
	var pack_id := "hayday_original"
	var lay_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--artflow-layout="):
			lay_path = a.substr(17)
		elif a.begins_with("--artflow-pack="):
			pack_id = a.substr(15)   # e.g. builtin_placeholders for a baseline run
	if lay_path.is_empty() and not _private_root().is_empty():
		lay_path = _private_root().path_join("layouts/real_art_test.hdlayout")
	var lib := App.assets
	var T := {}
	check(not lib.pack_by_id(pack_id).is_empty(), "pack %s installed" % pack_id)
	if lib.pack_by_id(pack_id).is_empty():
		return
	var tex_mon := Performance.RENDER_TEXTURE_MEM_USED
	var mem := {"start_static_mb": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1), "start_texture_mb": snappedf(Performance.get_monitor(tex_mon) / 1048576.0, 0.1)}
	# 1) open the private QA layout and render it
	if not lay_path.is_empty() and FileAccess.file_exists(lay_path):
		var tl := lib.texture_loads
		var t0 := Time.get_ticks_usec()
		var rep := LayoutIO.LoadReport.new()
		var l := App.library.load_path(lay_path, rep)
		T["load_layout_ms"] = _ms(t0)
		t0 = Time.get_ticks_usec()
		App.open_layout(l, rep)
		T["open_layout_ms"] = _ms(t0)
		t0 = Time.get_ticks_usec()
		main.renderer.ensure_sorted()
		T["first_sort_ms"] = _ms(t0)
		main.camera.smooth = false
		main._fit()
		t0 = Time.get_ticks_usec()
		await _frames(1)
		T["first_frame_ms"] = _ms(t0)
		var n_orig := 0
		for o: PlacedObject in _s().layout.objects.values():
			var spr: AssetLibrary.SpriteInfo = main.renderer.sprite_of(o.uid)
			if spr and spr.pack_id == pack_id:
				n_orig += 1
		T["layout_objects"] = _s().layout.count()
		T["layout_textures_loaded"] = lib.texture_loads - tl
		check(n_orig == _s().layout.count(), "QA layout: %d/%d objects drawn with %s art" % [n_orig, _s().layout.count(), pack_id])
		mem["after_layout_static_mb"] = snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1)
		mem["after_layout_texture_mb"] = snappedf(Performance.get_monitor(tex_mon) / 1048576.0, 0.1)
		if DisplayServer.get_name() != "headless":
			for z in [0.3, 1.0, 2.0]:
				main.camera.set_zoom_level(z)
				main.camera.zoom = Vector2(z, z)
				main.camera.target_zoom = z
				main.camera.center_on(Iso.tile_center(Vector2i(30, 18)))
				await _frames(10)
				var f0 := Time.get_ticks_usec()
				for i in 60:
					main.camera.pan_screen(Vector2(4, 2))
					await get_tree().process_frame
				T["pan_frame_ms_zoom_%s" % str(z)] = snappedf((Time.get_ticks_usec() - f0) / 1000.0 / 60.0, 0.01)
			mem["after_pan_texture_mb"] = snappedf(Performance.get_monitor(tex_mon) / 1048576.0, 0.1)
	else:
		print("  (no QA layout at %s - skipped)" % lay_path)
	# 2) catalogue thumbnails (all items, progressive loader drained)
	main.catalog._search.text = ""
	main.catalog.refresh()
	var tl2 := lib.texture_loads
	var t1 := Time.get_ticks_usec()
	while not main.catalog._icon_queue.is_empty():
		main.catalog._process(0.0)
	T["catalogue_all_thumbs_ms"] = _ms(t1)
	var icons_pack := 0
	for i in main.catalog._ids.size():
		var id: String = main.catalog._ids[i]
		if id.is_empty():
			continue
		var it := App.db.get_item(id)
		if lib.art_source(it.art_key) == pack_id and main.catalog._list.get_item_icon(i) != null and main.catalog._list.get_item_icon(i) == lib.get_thumbnail(it.art_key, "", UI.preview_mask(it)):
			icons_pack += 1
	check(icons_pack >= 1900, "catalogue shows %d thumbnails from %s" % [icons_pack, pack_id])
	check(lib.texture_loads == tl2, "catalogue thumbnails decoded %d full-size sprites (expected 0)" % (lib.texture_loads - tl2))
	# 3) editing on a fresh farm
	App.open_layout(App.new_layout("Artflow farm", "starter"))
	main._fit_or_restore()
	main.camera.smooth = false
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5
	await _frames(3)
	var s := _s()
	var bakery := App.db.get_item("bakery")
	var at := _free_origin(bakery, Vector2i(26, 10))
	main.camera.center_on(Iso.tile_center(at))
	await _frames(2)
	var t2 := Time.get_ticks_usec()
	main._on_item_chosen("bakery")
	_click_tile(at + Vector2i(1, 1))
	T["place_ms"] = _ms(t2)
	var placed := s.layout.object_at(at + Vector2i(1, 1))
	check(placed != null and placed.item_id == "bakery", "placed a bakery")
	if placed == null:
		return
	await _frames(1)
	var spr0: AssetLibrary.SpriteInfo = main.renderer.sprite_of(placed.uid)
	check(spr0 != null and spr0.pack_id == pack_id, "placed bakery drawn with %s art" % pack_id)
	_key(KEY_ESCAPE)
	var target := _free_origin(bakery, at + Vector2i(0, 5))
	var grab := _grab_tile(placed)
	t2 = Time.get_ticks_usec()
	_drag_tiles(grab, target + (grab - at))
	T["drag_move_ms"] = _ms(t2)
	check(placed.origin == target, "drag-moved the bakery onto %s (grab %s)" % [str(target), str(grab)])
	t2 = Time.get_ticks_usec()
	_key(KEY_Z, true)
	T["undo_ms"] = _ms(t2)
	check(placed.origin == at, "undo restores the position")
	_key(KEY_Z, true, true)
	check(placed.origin == target, "redo moves it again")
	# fence line with connection pieces from the pack
	var fa := _free_origin(App.db.get_item("plan_reserve_4x4"), Vector2i(30, 24))
	main.camera.center_on(Iso.tile_center(fa))
	await _frames(2)
	main._on_item_chosen("fence")
	t2 = Time.get_ticks_usec()
	_drag_tiles(fa, fa + Vector2i(4, 0), true)
	T["fence_line_ms"] = _ms(t2)
	_key(KEY_ESCAPE)
	await _frames(1)
	var mid := s.layout.object_at(fa + Vector2i(2, 0))
	var mspr: AssetLibrary.SpriteInfo = main.renderer.sprite_of(mid.uid) if mid else null
	check(mspr != null and mspr.pack_id == pack_id and mspr.path != lib.entry_of("fence").get("file", ""), "fence line uses a connection piece from the pack (%s)" % (mspr.path if mspr else "-"))
	# variant via the inspector (one undoable command)
	s.select([placed.uid])
	main.inspector.show_tab(0)
	main.inspector.rebuild()
	var vars := lib.variants_of("bakery")
	if not vars.is_empty():
		var steps := s.stack.size()
		main._on_inspector_action("variant", vars[0])
		await _frames(1)
		check(placed.variant == vars[0] and s.stack.size() == steps + 1 and main.renderer.sprite_of(placed.uid).variant == vars[0], "variant %s applied as one command and drawn" % vars[0])
	# save + load round trip
	t2 = Time.get_ticks_usec()
	var err := App.save_current(true)
	T["save_ms"] = _ms(t2)
	t2 = Time.get_ticks_usec()
	var rep2 := LayoutIO.LoadReport.new()
	var back := App.library.load_layout(s.layout.id, rep2)
	T["reload_ms"] = _ms(t2)
	var same := err == OK and back != null and back.count() == s.layout.count()
	if same:
		for o: PlacedObject in s.layout.objects.values():
			var b := back.get_obj(o.uid)
			if b == null or b.origin != o.origin or b.variant != o.variant:
				same = false
	check(same, "save/reload keeps %d objects incl. the variant" % s.layout.count())
	App.library.delete(s.layout.id)
	mem["end_static_mb"] = snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1)
	mem["end_texture_mb"] = snappedf(Performance.get_monitor(tex_mon) / 1048576.0, 0.1)
	print("ARTFLOW TIMES ", JSON.stringify(T))
	print("ARTFLOW MEM ", JSON.stringify(mem))


# --- camera (animated path, keys, bookmarks) and object dragging ---------------------------

func _settle_camera() -> int:
	## Frames until the camera has stopped moving.
	for i in 900:
		if not main.camera.is_animating():
			return i
		await get_tree().process_frame
	return 900


func _camera_check() -> void:
	print("Camera")
	var s := _s()
	var cam: FarmCamera = main.camera
	s.set_tool("select")
	s.clear_selection()
	main.controller.stamp_mode = false
	cam.go_home()
	# Wheel: zoom at the cursor by the configured factor.
	var at_screen: Vector2 = cam.view_rect.get_center() + Vector2(120, 40)
	var w0: Vector2 = cam.screen_to_world(at_screen)
	var factor0: float = cam.wheel_factor
	cam.wheel_factor = 1.3
	_button(at_screen, true, MOUSE_BUTTON_WHEEL_UP)
	check(is_equal_approx(cam.zoom.x, 1.3 * FarmCamera.HOME_ZOOM), "wheel notch uses the wheel-factor setting (zoom %.3f)" % cam.zoom.x)
	check(cam.world_to_screen(w0).distance_to(at_screen) < 0.75, "wheel zooms at the cursor")
	cam.wheel_factor = factor0
	# Animated path: the pan made during a running zoom survives it.
	cam.smooth = true
	cam.go_home()
	var anchor: Vector2 = cam.view_rect.get_center() + Vector2(90, -30)
	cam.zoom_at(anchor, 1.6)
	await _settle_camera()
	var plain_end: Vector2 = cam.position
	check(is_equal_approx(cam.target_zoom, 1.6) and absf(cam.zoom.x - 1.6) < 0.002, "smooth zoom arrives (%.3f)" % cam.zoom.x)
	cam.go_home()
	cam.zoom_at(anchor, 1.6)
	await get_tree().process_frame
	check(cam.is_animating(), "zoom is still animating when the pan comes")
	var z_now: float = cam.zoom.x
	var pan := Vector2(-70, 44)
	cam.pan_screen(pan)
	await _settle_camera()
	var kept: Vector2 = cam.position - plain_end
	check(kept.distance_to(-pan / z_now) < 0.75, "panning during a zoom is kept (moved %s, expected %s)" % [str(kept), str(-pan / z_now)])
	# Fly-to.
	var dest: Vector2 = Iso.grid_to_world(LandmarkView.home_tile_point(s.map)) + Vector2(260, 120)
	cam.fly_to(dest, 1.5)
	check(cam.is_animating(), "fly-to animates")
	var fly_frames: int = await _settle_camera()
	check(cam.view_center().distance_to(dest) < 1.0 and is_equal_approx(snappedf(cam.zoom.x, 0.001), 1.5), "fly-to arrives (%d frames)" % fly_frames)
	# Inertia, and the immediate path that interrupts it.
	cam.go_home()
	var before: Vector2 = cam.position
	cam.throw(Vector2(-900, 200))
	await _frames(3)
	check(cam.position != before and cam.is_animating(), "a released pan coasts")
	await _settle_camera()
	check(cam.position.x > before.x, "…in the direction of the throw and comes to rest")
	cam.throw(Vector2(900, 0))
	await get_tree().process_frame
	var tile := Iso.grid_to_world(LandmarkView.home_tile_point(s.map))
	cam.center_on(tile)
	check(not cam.is_animating() and cam.view_center().distance_to(tile) < 1.0, "center_on is immediate and stops the motion")
	# Rubber band: past the limit while held, back afterwards.
	cam.begin_user_pan()
	cam.pan_screen(Vector2(-400000, -300000))
	var lim: Rect2 = cam.limits
	check(not lim.grow(1.0).has_point(cam.view_center()), "dragging past the limit overshoots (rubber band)")
	cam.end_user_pan()
	await _settle_camera()
	check(lim.grow(1.0).has_point(cam.view_center()), "…and springs back inside")
	cam.smooth = false
	cam.go_home()
	# Limits and minimum zoom come from the world.
	var wr: Rect2 = main.world_rect_px(s.map)
	check(lim == wr.grow(FarmCamera.LIMIT_MARGIN), "limits = world bounds + margin")
	check(cam.min_zoom <= CameraMath.fit_zoom(cam.view_rect.size, wr.size) + 0.0001 and cam.min_zoom >= FarmCamera.ABS_MIN_ZOOM, "minimum zoom comes from fitting the world (%.3f)" % cam.min_zoom)
	for i in 80:
		cam.wheel_zoom(cam.view_rect.get_center(), -1.0)
	check(is_equal_approx(snappedf(cam.zoom.x, 0.0001), snappedf(cam.min_zoom, 0.0001)), "zooming out stops at the minimum")
	cam.go_home()
	# Keys.
	var o: PlacedObject = s.layout.objects.values()[0]
	s.select([o.uid])
	_key(KEY_F)
	var r: Rect2 = main._selection_world_rect(s)
	check(cam.view_center().distance_to(r.get_center()) < 1.0, "F fits the selection")
	s.clear_selection()
	_key(KEY_F)
	var z_key: float = cam.zoom.x
	main._fit()
	check(is_equal_approx(snappedf(z_key, 0.0001), snappedf(cam.zoom.x, 0.0001)), "F without a selection fits the farm")
	_key(KEY_F, false, true)
	check(cam.view_center().distance_to(wr.get_center()) < 1.0, "Shift+F shows the whole world")
	var home_pt := Iso.grid_to_world(LandmarkView.home_tile_point(s.map))
	cam.center_on(home_pt + Vector2(300, 150))
	_key(KEY_H)
	check(cam.view_center().distance_to(home_pt) < 1.0 and s.tool == "select", "H goes home")
	_key(KEY_D)
	check(s.tool == "pan", "D is the pan tool now")
	_key(KEY_ESCAPE)
	# Bookmarks: saved views, kept through view changes, undoable, in the file.
	var steps := s.stack.size()
	var view_a := home_pt + Vector2(200, 100)
	cam.center_on(view_a)
	_key(KEY_3, true)
	check(s.stack.size() == steps + 1 and s.layout.camera.get("bookmarks", {}).has("3"), "Ctrl+3 saves a view as one undo step")
	cam.center_on(home_pt)
	cam.pan_screen(Vector2(5, 5))
	check(s.layout.camera.get("bookmarks", {}).has("3"), "view changes don't wipe the bookmarks")
	check(s.tool == "select", "digit keys leave the tool alone")
	_key(KEY_3)
	check(cam.view_center().distance_to(view_a) < 1.0, "3 returns to the saved view")
	var saved: Dictionary = LayoutIO.to_dict(s.layout)["camera"]
	check(saved.get("bookmarks", {}).has("3") and saved.has("x"), "bookmarks are written with the layout")
	_key(KEY_Z, true)
	check(not s.layout.camera.has("bookmarks"), "Ctrl+Z removes the bookmark")
	_key(KEY_5)
	check(s.stack.size() == steps, "an empty slot does nothing")
	main.go_home()
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5


func _free_area(near: Vector2i, size: Vector2i) -> Vector2i:
	## Origin near `near` of a free size×size area with no landmark (x = -9999: none).
	var s := _s()
	for r in 40:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var o := near + Vector2i(dx, dy)
				var a := Rect2i(o, size)
				if PlacementRules.check_rect(s.layout, s.map, a).ok and not _touches_landmark(a):
					return o
	return Vector2i(-9999, -9999)


func _put(item_id: String, origin: Vector2i) -> PlacedObject:
	var s := _s()
	var uids := s.place_objects([s.make_object(App.db.get_item(item_id), origin)], "selftest drag object")
	return s.layout.get_obj(uids[0]) if not uids.is_empty() else null


func _overlap_point(a: PlacedObject, b: PlacedObject) -> Variant:
	## A world point where pick_all finds both objects (null: none).
	var r: Rect2 = main.renderer.bounds_of(a.uid).intersection(main.renderer.bounds_of(b.uid))
	var y := r.position.y
	while y < r.end.y:
		var x := r.position.x
		while x < r.end.x:
			var uids := []
			for h: Dictionary in main.renderer.pick_all(Vector2(x, y)):
				uids.append(h["uid"])
			if a.uid in uids and b.uid in uids:
				return Vector2(x, y)
			x += 3.0
		y += 3.0
	return null


func _click_screen(p: Vector2) -> void:
	_move(p)
	_button(p, true)
	_button(p, false)


func _drag_check() -> void:
	print("Dragging and overlapping objects")
	var s := _s()
	var cam: FarmCamera = main.camera
	var ctl: EditorController = main.controller
	s.set_tool("select")
	s.clear_selection()
	check(main.underlay.get_index() < main.renderer.get_index() and main.renderer.get_index() < main.overlay.get_index(), "selection fill is drawn under the objects, outlines above")
	var at := _free_area(Vector2i(26, 12), Vector2i(12, 8))
	if at.x == -9999:
		check(false, "free area for the drag checks")
		return
	cam.center_on(Iso.tile_center(at + Vector2i(4, 2)))
	await _frames(2)
	var steps0 := s.stack.size()
	var a := _put("bakery", at)
	var b := _put("bakery", at + Vector2i(3, 0))
	main.renderer.ensure_sorted()
	check(a != null and b != null, "two neighbouring objects placed")
	if a == null or b == null:
		return
	# pick_all / cycling.
	var p: Variant = _overlap_point(a, b)
	check(p != null, "the two sprites overlap somewhere")
	if p != null:
		var stack: Array = ctl.objects_here(p)
		check(stack.size() >= 2 and stack[0]["uid"] == main.renderer.pick_any(p)["uid"], "objects_here lists both, top-most first (%d entries)" % stack.size())
		var sp: Vector2 = cam.world_to_screen(p)
		_click_screen(sp)
		check(s.selection == [stack[0]["uid"]], "first click selects the top-most object")
		_click_screen(sp)
		check(s.selection == [stack[1]["uid"]], "clicking the same spot again selects the one behind")
		for i in range(2, stack.size()):
			_click_screen(sp)
		_click_screen(sp)
		check(s.selection == [stack[0]["uid"]], "…and cycles back to the top")
		# Right-click context list.
		_button(sp, true, MOUSE_BUTTON_RIGHT)
		_button(sp, false, MOUSE_BUTTON_RIGHT)
		check(ctl.last_context_stack.size() == stack.size() and s.selection == [stack[0]["uid"]], "right-click keeps the selection and lists the objects here")
		main._on_objects_here_id(main.OBJECTS_HERE_ID + 1)
		check(s.selection == [stack[1]["uid"]], "choosing from “Objects here” selects that object")
		for c in main.root.get_children():
			if c is PopupMenu:
				(c as PopupMenu).hide()
		s.clear_selection()
	# Live drag: previewed by the renderer, the layout is untouched until the drop.
	await _frames(1)
	var grab := _grab_tile(a)
	var from: Vector2 = _screen_of_tile(grab)
	var one_tile: Vector2 = _screen_of_tile(grab + Vector2i(0, 1)) - from
	var origin0 := a.origin
	var steps := s.stack.size()
	_move(from)
	_button(from, true)
	for i in range(1, 25):
		_move(from + one_tile * i / 8.0, MOUSE_BUTTON_MASK_LEFT)
	var mid_ok: bool = main.renderer.is_previewing(a.uid) and a.origin == origin0 and main.overlay.drag_delta == Vector2i(0, 3) and main.overlay.drag_result != null
	check(mid_ok, "dragging previews in the renderer; the layout doesn't change until the drop (Δ %s)" % str(main.overlay.drag_delta))
	check(main.renderer.pick(Iso.tile_center(a.origin)) == a.uid, "picking keeps using the real position while dragging")
	# A pointer trembling on a tile boundary must not make the object flicker.
	var boundary: Vector2 = from + one_tile * 3.5
	var flips := 0
	var last_delta: Vector2i = main.overlay.drag_delta
	var rec0: int = ctl.drag_stats["recomputes"]
	var moves0: int = ctl.drag_stats["moves"]
	for i in 60:
		_move(boundary + one_tile * (0.08 if i % 2 == 0 else -0.08), MOUSE_BUTTON_MASK_LEFT)
		if main.overlay.drag_delta != last_delta:
			flips += 1
			last_delta = main.overlay.drag_delta
	check(flips <= 1 and int(ctl.drag_stats["recomputes"]) - rec0 <= 1, "pointer jitter on a tile boundary: %d flip(s), %d recompute(s) in %d moves" % [flips, int(ctl.drag_stats["recomputes"]) - rec0, int(ctl.drag_stats["moves"]) - moves0])
	# The camera moving under a still pointer moves the drop target.
	var dd: Vector2i = main.overlay.drag_delta
	cam.pan_screen(one_tile * -2.0)
	check(main.overlay.drag_delta != dd, "a view change during the drag updates the drop position (%s → %s)" % [str(dd), str(main.overlay.drag_delta)])
	cam.pan_screen(one_tile * 2.0)
	var dt: Vector2 = from + one_tile * 4.0
	_move(dt, MOUSE_BUTTON_MASK_LEFT)
	_button(dt, false)
	check(a.origin == origin0 + Vector2i(0, 4) and s.stack.size() == steps + 1, "drop commits one move, one undo step (at %s)" % str(a.origin))
	check(not main.renderer.is_previewing(a.uid) and main.overlay.drag_uids.is_empty(), "the preview and overlay state are cleared")
	# Dropping on another object: red blocker, one reason per chip, nothing moves.
	var a_tile := _grab_tile(a)
	var dpos: Vector2 = _screen_of_tile(a_tile)
	var onto: Vector2 = _screen_of_tile(a_tile + (b.origin - a.origin))
	_move(dpos)
	_button(dpos, true)
	for i in range(1, 11):
		_move(dpos.lerp(onto, i / 10.0), MOUSE_BUTTON_MASK_LEFT)
	check(b.uid in main.overlay.blocker_uids, "a drop on another object outlines the blocker")
	var reasons: PackedStringArray = main.overlay.cursor_reasons
	check(reasons.size() >= 1 and reasons[0].begins_with("Blocked by") and main.overlay.cursor_text.find("Blocked") < 0, "the reason gets its own chip: %s" % " | ".join(reasons))
	var a_at := a.origin
	var steps2 := s.stack.size()
	_button(onto, false)
	check(a.origin == a_at and s.stack.size() == steps2 and main.overlay.blocker_uids.is_empty(), "the drop is refused and the blockers are gone")
	# Snap to the nearest free spot (setting, not persisted here).
	App.settings.set_v("drag_snap_valid", true, false)
	a_tile = _grab_tile(a)
	dpos = _screen_of_tile(a_tile)
	onto = _screen_of_tile(a_tile + (b.origin - a.origin) + Vector2i(1, 0))
	_move(dpos)
	_button(dpos, true)
	for i in range(1, 11):
		_move(dpos.lerp(onto, i / 10.0), MOUSE_BUTTON_MASK_LEFT)
	check(main.overlay.cursor_text.find("snapped") >= 0 and main.overlay.drag_result.ok and main.overlay.blocker_uids.is_empty(), "with snapping on, an occupied drop jumps to the nearest free spot (%s)" % main.overlay.cursor_text)
	var snap_delta: Vector2i = main.overlay.drag_delta
	var b0 := a.origin
	_button(onto, false)
	App.settings.set_v("drag_snap_valid", false, false)
	check(a.origin == b0 + snap_delta and PlacementRules.check_rect(s.layout, s.map, a.rect(), {a.uid: true}).ok, "…and drops there")
	# Very large drags use overlay ghosts instead of re-sorting every object.
	var big := _free_area(at + Vector2i(0, 12), Vector2i(12, 15))
	if big.x != -9999:
		var objs: Array = []
		var item := App.db.get_item("fence")
		for y in 12:
			for x in 12:
				objs.append(s.make_object(item, big + Vector2i(x, y)))
		var uids := s.place_objects(objs, "selftest many")
		check(uids.size() > EditorController.LIVE_DRAG_MAX, "%d objects placed for the large drag" % uids.size())
		cam.center_on(Iso.tile_center(big + Vector2i(5, 5)))
		await _frames(2)
		var g0: Vector2 = _screen_of_tile(big + Vector2i(5, 5))
		var g1: Vector2 = _screen_of_tile(big + Vector2i(5, 8))
		# Cost of a live preview at a size near the limit (informational).
		s.select(uids.slice(0, 100), false, false)
		_move(g0)
		_button(g0, true)
		_move(g0.lerp(g1, 1.0 / 6.0), MOUSE_BUTTON_MASK_LEFT)
		main.renderer.ensure_sorted()
		var t_live := Time.get_ticks_usec()
		for i in range(2, 7):
			_move(g0.lerp(g1, i / 6.0), MOUSE_BUTTON_MASK_LEFT)
			main.renderer.ensure_sorted()
		print("  DRAG live preview, 100 objects: %.2f ms per tile change (%d recomputes in %d moves)" % [(Time.get_ticks_usec() - t_live) / 1000.0 / 3.0, ctl.drag_stats["recomputes"], ctl.drag_stats["moves"]])
		_key(KEY_ESCAPE)
		check(not main.renderer.is_previewing(uids[0]) and s.layout.get_obj(uids[0]).origin == big, "Esc cancels a live drag without moving anything")
		s.select(uids, false, false)
		var st3 := s.stack.size()
		_move(g0)
		_button(g0, true)
		for i in range(1, 7):
			_move(g0.lerp(g1, i / 6.0), MOUSE_BUTTON_MASK_LEFT)
		check(main.overlay.ghosts.size() == uids.size() and not main.renderer.is_previewing(uids[0]), "large drag: %d overlay ghosts, nothing re-sorted per move" % main.overlay.ghosts.size())
		_button(g1, false)
		check(s.stack.size() == st3 + 1 and s.layout.get_obj(uids[0]).origin == big + Vector2i(0, 3), "large drag still commits as one move")
	while s.stack.size() > steps0:
		s.stack.undo()
	s.clear_selection()
	main.go_home()
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5


# --- world layer in the app: landmark rendering + interaction, home, land level ----------

func _landmark_pick_tile(id: String) -> Vector2i:
	## A footprint tile whose centre pick_any() resolves to the landmark
	## ((-9999, -9999) = none: hidden or covered everywhere).
	var lm := App.map.landmark(id)
	if lm == null:
		return Vector2i(-9999, -9999)
	var key := LandmarkView.key_of(id)
	var c := lm.origin + Vector2i((lm.footprint.x - 1) / 2, (lm.footprint.y - 1) / 2)
	var order: Array = [c]
	for y in lm.footprint.y:
		for x in lm.footprint.x:
			order.append(lm.origin + Vector2i(x, y))
	for t: Vector2i in order:
		var r: Dictionary = main.renderer.pick_any(Iso.tile_center(t))
		if r.get("kind") == "landmark" and r.get("key") == key:
			return t
	return Vector2i(-9999, -9999)


func _snapshot_objects() -> String:
	return JSON.stringify(LayoutIO.to_dict(_s().layout)["objects"])


func _place_near_landmark(lm: Landmark, item_id: String, front: bool) -> int:
	## Places item_id right in front of (south / east) or behind (north / west)
	## the landmark so that their sprites overlap; returns the uid (0 = no free
	## spot found).
	var s := _s()
	var it := App.db.get_item(item_id)
	var key := LandmarkView.key_of(lm.id)
	var lb: Rect2 = main.renderer.world_entry_bounds(key)
	var cands: Array = []
	for k in 8:
		for dx in range(-it.footprint.x + 1, lm.footprint.x):
			cands.append(Vector2i(lm.origin.x + dx, lm.origin.y + lm.footprint.y + k) if front \
				else Vector2i(lm.origin.x + dx, lm.origin.y - it.footprint.y - k))
		for dy in range(-it.footprint.y + 1, lm.footprint.y):
			cands.append(Vector2i(lm.origin.x + lm.footprint.x + k, lm.origin.y + dy) if front \
				else Vector2i(lm.origin.x - it.footprint.x - k, lm.origin.y + dy))
	for o: Vector2i in cands:
		if not PlacementRules.check_item(s.layout, s.map, it, o, false).ok:
			continue
		var po := PlacedObject.new()
		po.item_id = it.id
		po.origin = o
		po.size = it.footprint
		var uids := s.place_objects([po], "selftest depth probe")
		if uids.is_empty():
			continue
		main.renderer.ensure_sorted()
		if main.renderer.bounds_of(uids[0]).intersects(lb):
			return uids[0]
		s.stack.undo()
	return 0


func _world_ui_check() -> void:
	print("World layer (rendering, landmark UI, home, land level)")
	var s := _s()
	s.set_tool("select")
	s.clear_selection()
	main.controller.stamp_mode = false
	# Every landmark of the active world is a renderer world entry.
	var keys: Array = main.renderer.world_entry_keys()
	var all_in := keys.size() == s.map.landmarks.size()
	for lm in s.map.landmarks:
		all_in = all_in and keys.has(LandmarkView.key_of(lm.id))
	check(all_in and not keys.is_empty(), "every landmark of the world is drawn (%d world entries)" % keys.size())
	var fh := s.map.landmark("farmhouse")
	if fh == null:
		check(false, "farmhouse landmark present")
		return
	var key := LandmarkView.key_of("farmhouse")
	check(main.renderer.world_entry_bounds(key).size != Vector2.ZERO, "farmhouse drawn (art or placeholder; bounds %s)" % str(main.renderer.world_entry_bounds(key).size))
	# Depth: an object in front of the farmhouse draws over it, one behind under it.
	var front := _place_near_landmark(fh, "bakery", true)
	if front == 0:
		front = _place_near_landmark(fh, "apple_tree", true)
	var back := _place_near_landmark(fh, "bakery", false)
	if back == 0:
		back = _place_near_landmark(fh, "apple_tree", false)
	var fo: int = main.renderer.world_order_of(key)
	check(front != 0 and main.renderer.order_of(front) > fo, "object in front of the farmhouse is drawn over it")
	check(back != 0 and main.renderer.order_of(back) < fo, "object behind the farmhouse is drawn under it")
	var co: Dictionary = main.renderer.check_order()
	check(int(co["mismatch"]) == 0 and int(co["violations"]) == 0, "landmarks depth-sort together with objects (%s)" % str(co))
	for u in [back, front]:
		if u != 0:
			s.stack.undo()
	# Click selects the landmark (its own card); drag / erase / R explain instead.
	main.camera.center_on(Iso.footprint_center(fh.origin, fh.footprint))
	await _frames(2)
	var pt := _landmark_pick_tile("farmhouse")
	check(pt.x != -9999, "farmhouse is pickable pixel-accurately (pick_any)")
	if pt.x == -9999:
		return
	var hover_before: int = main.fixed_hint_count
	_move(_screen_of_tile(pt))
	check(main._lm_hover == "farmhouse" and main.overlay.landmark_hover == fh.rect(), "hovering the farmhouse highlights it")
	_click_tile(pt)
	check(s.selected_landmark == "farmhouse" and s.selection.is_empty(), "clicking the farmhouse selects the landmark (not an object)")
	main.inspector.rebuild()
	check(main.inspector.landmark_card_id == "farmhouse" and main.overlay.landmark_selected == fh.rect(), "inspector shows the farmhouse card; selection outline drawn")
	var sk: OptionButton = main.inspector.landmark_skin_option
	if sk != null and sk.item_count > 1:
		# Private packs: a skin preset is an undoable world-state change.
		var sid := str(sk.get_item_metadata(1))
		sk.select(1)
		sk.item_selected.emit(1)
		await _frames(1)
		var v := str(main.renderer.world_entry(key).get("variant", ""))
		check(s.layout.landmark_skin("farmhouse") == sid and (v.begins_with("skin_" + sid) or not App.assets.variants_of(fh.art).has("skin_" + sid)),
			"skin preset “%s” applied (variant %s)" % [sid, v])
		_key(KEY_Z, true)
		check(s.layout.landmark_skin("farmhouse", "original") == "original", "Ctrl+Z restores the original skin")
	var snap := _snapshot_objects()
	var steps := s.stack.size()
	var origin0 := fh.origin
	main._hint_times.clear()
	_drag_tiles(pt, pt + Vector2i(3, 2))
	check(App.map.landmark("farmhouse").origin == origin0 and _snapshot_objects() == snap and s.stack.size() == steps,
		"dragging the farmhouse moves nothing")
	check(main.fixed_hint_count > hover_before and main.last_fixed_hint == s.explain_fixed("farmhouse", "drag"),
		"…and shows the fixed-in-place hint near the cursor: %s" % main.last_fixed_hint)
	main._hint_times.clear()
	_key(KEY_R)
	check(main.last_fixed_hint == s.explain_fixed("farmhouse", "rotate") and s.stack.size() == steps, "R on the landmark: hint, no change")
	main._hint_times.clear()
	var n0: int = main.fixed_hint_count
	_key(KEY_DELETE)
	check(main.fixed_hint_count == n0 + 1 and main.last_fixed_hint == s.explain_fixed("farmhouse", "delete") and _snapshot_objects() == snap, "Delete on the landmark: hint, no change")
	_key(KEY_ESCAPE)
	check(s.selected_landmark.is_empty(), "Esc clears the landmark selection")
	# Erase tool on the landmark does nothing.
	s.set_tool("erase")
	main._hint_times.clear()
	var c0 := s.layout.count()
	_click_tile(pt)
	check(s.layout.count() == c0 and s.stack.size() == steps and App.map.landmark("farmhouse") != null
		and main.last_fixed_hint == s.explain_fixed("farmhouse", "erase"), "erase tool on the farmhouse removes nothing (hint: %s)" % main.last_fixed_hint)
	s.set_tool("select")
	# Box selection never selects landmarks.
	var b: Rect2 = main.renderer.world_entry_bounds(key).grow(64)
	var start := Vector2.ZERO
	var found := false
	for p in [b.position, Vector2(b.end.x, b.position.y), Vector2(b.position.x, b.end.y), b.end]:
		if (main.renderer.pick_any(p) as Dictionary).get("kind", "") == "":
			start = p
			found = true
			break
	if found:
		var a: Vector2 = main.camera.world_to_screen(start)
		var z: Vector2 = main.camera.world_to_screen(b.get_center() * 2.0 - start)
		_move(a)
		_button(a, true)
		for i in 10:
			_move(a.lerp(z, (i + 1) / 10.0), MOUSE_BUTTON_MASK_LEFT)
		_button(z, false)
		check(s.selected_landmark.is_empty() and s.selection.all(func(u): return s.layout.objects.has(u)), "box selection over the farmhouse never selects the landmark")
		s.clear_selection()
	else:
		check(true, "box selection check skipped (no empty corner around the farmhouse)")
	# A permanent landmark can't be hidden (that would remove it from the farm).
	var vsteps := s.stack.size()
	check(not s.set_landmark_visible("farmhouse", false) and s.stack.size() == vsteps and bool(main.renderer.world_entry(key).get("visible", false)),
		"the farmhouse can't be hidden")
	# Visibility of a transient landmark is per layout, undoable, and hides it from picking.
	var fh_lm := s.map.landmark("farmhouse")
	fh_lm.transient = true
	s.set_landmark_visible("farmhouse", false)
	check(not bool(main.renderer.world_entry(key).get("visible", true)) and (main.renderer.pick_any(Iso.tile_center(pt)) as Dictionary).get("key", "") != key,
		"hiding a transient landmark hides it in the renderer (not pickable)")
	_key(KEY_Z, true)
	check(bool(main.renderer.world_entry(key).get("visible", false)), "Ctrl+Z shows it again")
	fh_lm.transient = false
	# Season selector: only themes with art (public build: Default only).
	var themes := LandmarkView.themes_with_art(s.map, App.assets)
	check(themes[0] == FarmLayout.DEFAULT_THEME and (themes.size() == 1 or App.map.is_game_data() or App.assets.has_art("lm_farmhouse")),
		"season choices = themes with art: %s" % str(themes))
	main.set_theme("no_such_season")
	check(s.layout.theme() == FarmLayout.DEFAULT_THEME, "a season without art can't be chosen")
	if themes.size() > 1:
		var t: String = themes[themes.size() - 1]
		main.set_theme(t)
		var seasonal := 0
		for lm in s.map.landmarks:
			if str(main.renderer.world_entry(LandmarkView.key_of(lm.id)).get("variant", "")).ends_with("__" + t):
				seasonal += 1
		check(s.layout.theme() == t and seasonal > 0, "season %s: %d landmark(s) switch to their seasonal art" % [t, seasonal])
		_key(KEY_Z, true)
		check(s.layout.theme() == FarmLayout.DEFAULT_THEME, "Ctrl+Z restores the default season")
	main.inspector.show_tab(2)
	main.inspector.rebuild()
	check(main.inspector.theme_option != null and main.inspector.theme_option.item_count == themes.size(), "View tab: season selector lists %d theme(s)" % themes.size())
	main.inspector.show_tab(0)
	# Home: farmhouse (else starting land) at 100 %, via button, Home key and Shift+H.
	var home_pt := Iso.grid_to_world(LandmarkView.home_tile_point(s.map))
	main.camera.center_on(home_pt + Vector2(900, 600))
	main.home_button.pressed.emit()
	check(main.camera.view_center().distance_to(home_pt) < 1.0 and is_equal_approx(main.camera.zoom.x, FarmCamera.HOME_ZOOM), "Home button centres the farmhouse at 100%")
	main.camera.center_on(home_pt + Vector2(-700, 300))
	_key(KEY_HOME)
	var ok_home: bool = main.camera.view_center().distance_to(home_pt) < 1.0
	main.camera.center_on(home_pt + Vector2(500, -300))
	_key(KEY_H, false, true)
	check(ok_home and main.camera.view_center().distance_to(home_pt) < 1.0 and s.tool == "select", "Home key and Shift+H go home too")
	# Camera bounds: the view centre can't leave the world.
	main.camera.pan_screen(Vector2(-200000, -150000))
	var lim: Rect2 = main.camera.limits
	check(lim.size != Vector2.ZERO and lim.grow(1.0).has_point(main.camera.view_center()), "camera stays inside the world bounds")
	main.go_home()
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5
	# Land tool: Realistic mode refuses plots above the farm level.
	var plot_id := ""
	for p in s.map.plots:
		var pid := str(p["id"])
		if not s.map.is_plot_unlocked(pid, s.layout.unlocked_plots) and RealisticAnalyzer.plot_required_level(s.map, pid) > 1 and p.has("center"):
			plot_id = pid
			break
	if plot_id.is_empty():
		check(true, "land level check skipped (no plot with a known level above 1)")
		return
	var lvl0 := RealisticAnalyzer.farm_level(s.layout)
	var prof := s.layout.profile.duplicate(true)
	prof["level"] = 1
	s.execute(EditCommands.SetProfile.new(s.layout.profile, prof, "selftest level"))
	s.set_mode(FarmLayout.MODE_REALISTIC)
	s.set_tool("land")
	var pc: Vector2 = s.map.plot(plot_id)["center"]
	var ptile := Vector2i(floori(pc.x), floori(pc.y))
	if s.map.plot_id_at(ptile) != plot_id:
		for y in s.map.size.y:
			for x in s.map.size.x:
				if s.map.plot_id_at(Vector2i(x, y)) == plot_id:
					ptile = Vector2i(x, y)
	var got: Array = []
	var cb := func(t, _k): got.append(t)
	s.message.connect(cb)
	var st1 := s.stack.size()
	_click_tile(ptile)
	s.message.disconnect(cb)
	var need := RealisticAnalyzer.plot_required_level(s.map, plot_id)
	check(not s.map.is_plot_unlocked(plot_id, s.layout.unlocked_plots) and s.stack.size() == st1
		and got.any(func(t): return str(t).contains("Requires level %d" % need)), "Realistic, level 1: a level-%d plot can't be unlocked (%s)" % [need, str(got.slice(0, 1))])
	check(main.ground.level_blocked.has(plot_id), "…and is drawn as level-locked on the ground")
	s.set_mode(FarmLayout.MODE_CREATIVE)
	_click_tile(ptile)
	check(s.map.is_plot_unlocked(plot_id, s.layout.unlocked_plots) and main.ground.level_blocked.is_empty(), "Creative (sandbox) unlocks it")
	_key(KEY_Z, true)
	prof["level"] = lvl0
	s.execute(EditCommands.SetProfile.new(s.layout.profile, prof, "selftest level"))
	s.set_tool("select")


func _load_report_check() -> void:
	## Opening an old (v1) layout: the load-report dialog data and its "Show"
	## buttons. Positions are computed from the active world (no game data here).
	print("Load report")
	var road := Vector2i(-1, -1)
	for y in App.map.size.y:
		for x in App.map.size.x:
			if road.x < 0 and App.map.kind_at(Vector2i(x, y)) == FarmMap.Kind.ROAD and App.map.landmark_at(Vector2i(x, y)) < 0:
				road = Vector2i(x, y)
	var shift := Vector2i(5, 3)   # v1 = game frame + (5, 3)
	var objs: Array = [
		{"uid": 1, "item": "farmhouse", "x": 19, "y": 15, "w": 4, "h": 4, "locked": true, "note": LayoutIO.V1_STARTER_NOTE},
		{"uid": 2, "item": "barn", "x": 9, "y": 7, "w": 4, "h": 4, "locked": true, "note": LayoutIO.V1_STARTER_NOTE}]
	if road.x >= 0:
		objs.append({"uid": 3, "item": "bakery", "x": road.x + shift.x, "y": road.y + shift.y, "w": 3, "h": 3})
	var v1 := {"format": LayoutIO.FORMAT, "schema_version": 1, "app_version": "0.1.0",
		"meta": {"id": "selftest_report_v1", "name": "Old farm (report)", "mode": "creative"},
		"map": {"id": "hayday_farm", "unlocked_plots": []}, "objects": objs, "camera": {"x": 0.0, "y": 0.0, "zoom": 1.0}}
	var rep := LayoutIO.LoadReport.new()
	var l := LayoutIO.from_dict(v1, App.db, rep, App.map)
	check(l != null, "old layout loads")
	if l == null:
		return
	var d := Dialogs.load_report_data(rep, l, App.db, App.map)
	check(d["shifted"] == Vector2i(-5, -3) and (d["landmarks"] as Array).size() == 1 and str(d["landmarks"][0]["landmark"]) == "farmhouse"
		and Dialogs.load_report_needs_dialog(rep), "load report: frame shift, farmhouse now a fixed landmark (%s)" % rep.summary())
	check(road.x < 0 or (d["collisions"] as Array).any(func(c): return int(c["uid"]) == 3), "load report lists the object on the road as a collision")
	var small := LayoutIO.LoadReport.new()
	check(not Dialogs.load_report_needs_dialog(small), "nothing to report -> no dialog")
	l.id = ""   # not a library layout: keeps the app's "last layout" setting untouched
	App.open_layout(l, rep)
	await _frames(2)
	check(main.load_report_modal == null or not is_instance_valid(main.load_report_modal) or main.load_report_modal.is_queued_for_deletion(),
		"automation: the dialog is not opened by itself")
	var m: Modal = main.show_load_report(rep)
	await _frames(2)
	var shows: Array = []
	var stack: Array = [m]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and (n as Button).text == "Show":
			shows.append(n)
		stack.append_array(n.get_children())
	var expect := 0
	var seen := {}
	for c in d["collisions"]:
		seen[c["uid"]] = true
	for r in d["review"]:
		seen[r["uid"]] = true
	expect = mini(seen.size(), Dialogs.REPORT_LIST_MAX)
	check(m != null and shows.size() == expect, "dialog: one Show button per object to check (%d)" % shows.size())
	if road.x >= 0 and not shows.is_empty():
		(shows[0] as Button).pressed.emit()
		await _frames(2)
		var u := int((d["collisions"] as Array)[0]["uid"]) if not (d["collisions"] as Array).is_empty() else int(d["review"][0]["uid"])
		var o := _s().layout.get_obj(u)
		check(o != null and _s().selection == [u] and main.camera.view_center().distance_to(Iso.footprint_center(o.origin, o.size)) < 1.0
			and (not is_instance_valid(m) or m.is_queued_for_deletion()), "Show closes the dialog, selects the object and centres it")
	if is_instance_valid(m):
		m.close()


# --- world art, terrain, ambient animation, references -----------------------------------

func _world_art_check() -> void:
	print("World art")
	var s := _s()
	if not App.map.is_game_data():
		var truck: AssetLibrary.SpriteInfo = main.renderer.world_sprite_of(LandmarkView.key_of("truck"))
		check(truck != null and truck.path == "items/ph_truck.png", "the public truck landmark draws its own placeholder")
		await _frames(2)
		main.ground._terrain.queue_redraw()
		await _frames(2)
		var plain_us: int = main.ground._terrain.last_draw_usec
		main.ground.set_theme("winter")
		await _frames(2)
		var winter_us: int = main.ground._terrain.last_draw_usec
		main.ground.set_theme(s.layout.theme())
		await _frames(2)
		print("  TERRAIN build %d us, redraw %d us, season change %d us" % [main.ground._terrain.last_build_usec, plain_us, winter_us])
		check(winter_us > 0 and winter_us < 50000, "a season change rebuilds the terrain in under 50 ms (%.1f ms)" % (winter_us / 1000.0))
		main.ground.setup(s.map, s.layout.unlocked_plots)
		main.ground.queue_redraw()
		await _frames(2)
		print("  GROUND ownership redraw %d us" % main.ground.last_draw_usec)
		check(main.ground.last_draw_usec > 0 and main.ground.last_draw_usec < 50000, "an ownership change redraws in under 50 ms (%.1f ms)" % (main.ground.last_draw_usec / 1000.0))
	# A real ambient animation from the built-in placeholders.
	var wm: ItemDef = s.db.get_item("windmill")
	var at := _free_origin(wm, Vector2i(6, 6))
	var po := PlacedObject.new()
	po.item_id = "windmill"
	po.origin = at
	po.size = wm.footprint
	s.execute(EditCommands.AddObjects.new([po]))
	var uid: int = s.layout.objects.keys().max()
	check(main.renderer.anim_stats()["animated"] >= 1 and main.renderer.anim_frame_of(uid) >= -1, "a windmill placeholder is animated")
	var view := Rect2(-1e6, -1e6, 2e6, 2e6)
	main.renderer.set_ambient_mode(ObjectRenderer.Ambient.FULL)
	var f0: int = main.renderer.anim_frame_of(uid)
	main.renderer.advance_anim(1.0 / 6.0 + 0.001, view)
	check(main.renderer.anim_frame_of(uid) != f0, "its frame advances with the clock")
	App.settings.set_v("ambient_animation", "off", false)
	check(main.renderer.anim_frame_of(uid) == -1, "Ambient animation: Off shows the static image")
	App.settings.set_v("ambient_animation", "full", false)
	check(main.renderer.anim_frame_of(uid) >= 0, "…and Full plays it again")
	s.stack.undo()
	check(main.renderer.anim_frame_of(uid) == -2, "removing the object removes its animation")
	await _reference_check()


func _reference_check() -> void:
	print("References")
	var s := _s()
	var before := s.layout.reference.duplicate(true)
	DirAccess.make_dir_recursive_absolute("user://references")
	var files: Array[String] = []
	for i in 2:
		var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.5, 0.5 + i * 0.2, 0.9))
		var f := "user://references/selftest_%d.png" % i
		img.save_png(f)
		files.append(f)
	var depth: int = s.stack.history_labels().size()
	main._ref_add_image(files[0])
	main._ref_add_image(files[1])
	check((s.layout.reference["images"] as Array).size() == 2 and s.stack.history_labels().size() == depth + 2, "two reference images, one undo step each")
	check(main.reference.visible and main._view_state["ref_loaded"] and (main._view_state["ref_images"] as Array).size() == 2, "both are loaded and listed")
	var ids: Array = (s.layout.reference["images"] as Array).map(func(im): return im["id"])
	check(main.reference.active_id == ids[1], "a new image becomes the active one")
	main._on_inspector_action("ref", {"id": ids[0], "opacity": 0.25})
	check(is_equal_approx(float(s.layout.reference["images"][0]["opacity"]), 0.25) and not is_equal_approx(float(s.layout.reference["images"][1]["opacity"]), 0.25), "opacity is per image")
	s.stack.undo()
	check(not is_equal_approx(float(s.layout.reference["images"][0]["opacity"]), 0.25), "undo restores it")
	main._on_inspector_action("ref", {"id": ids[0], "visible": false})
	check(not bool(s.layout.reference["images"][0].get("visible", true)) and main.reference.visible, "hiding one image leaves the other")
	main._on_inspector_action("ref_order", [ids[1], -1])
	check(s.layout.reference["images"][0]["id"] == ids[1], "order changes")
	s.stack.undo()
	s.stack.undo()
	# A drag of the active image is one undo step, and only moves that image.
	main._on_inspector_action("ref_move", true)
	var p := Vector2(600, 400)
	var x0 := float(s.layout.reference["images"][1]["x"])
	var y0_other := float(s.layout.reference["images"][0]["y"])
	depth = s.stack.history_labels().size()
	_button(p, true)
	for i in range(1, 8):
		_move(p + Vector2(i * 6, 0), MOUSE_BUTTON_MASK_LEFT)
	_button(p + Vector2(42, 0), false)
	main._on_inspector_action("ref_move", false)
	check(s.stack.history_labels().size() == depth + 1, "a reference drag is one undo step")
	check(not is_equal_approx(float(s.layout.reference["images"][1]["x"]), x0) and is_equal_approx(float(s.layout.reference["images"][0]["y"]), y0_other), "the drag moved only the active image")
	s.stack.undo()
	check(is_equal_approx(float(s.layout.reference["images"][1]["x"]), x0), "undo puts it back")
	# Locked images don't move.
	main._on_inspector_action("ref", {"locked": true})
	main._on_inspector_action("ref_move", true)
	depth = s.stack.history_labels().size()
	_button(p, true)
	_move(p + Vector2(30, 0), MOUSE_BUTTON_MASK_LEFT)
	_button(p + Vector2(30, 0), false)
	main._on_inspector_action("ref_move", false)
	check(s.stack.history_labels().size() == depth, "a locked image can't be dragged")
	s.stack.undo()
	# Two-point calibration through the same click path as the editor.
	main._on_inspector_action("ref_calibrate", 2)
	check(main.controller.calibrating, "calibration started")
	var a := Vector2(100, 40)
	var b := Vector2(260, 120)
	main._on_calibration_point(a)
	main._on_calibration_point(b)
	var ga := Iso.grid_to_world(Vector2(10, 10))
	var gb := Iso.grid_to_world(Vector2(16, 10))
	var ia: Vector2 = main.reference.world_to_image(a)
	var ib: Vector2 = main.reference.world_to_image(b)
	main._on_calibration_point(ga)
	main._on_calibration_point(gb)
	check(not main.controller.calibrating and s.layout.reference["images"][1].has("affine"), "two pairs of clicks calibrate the active image")
	var xf: Transform2D = ReferenceLayer.xform_of(s.layout.reference["images"][1])
	check((xf * ia).distance_to(ga) < 0.01 and (xf * ib).distance_to(gb) < 0.01, "the clicked points land on the tile corners")
	s.stack.undo()
	check(not s.layout.reference["images"][1].has("affine"), "calibration is undoable")
	main._on_inspector_action("ref_remove", ids[1])
	check((s.layout.reference["images"] as Array).size() == 1 and main.reference.active_id == ids[0], "removing one keeps the other")
	s.stack.undo()
	s.execute(EditCommands.SetReference.new(s.layout.reference, before, "Reset"))
	check(s.layout.reference == before, "reference state restored")
	for f in files:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))


func _ui_panels_check() -> void:
	## Side panels: auto-hiding inspector, collapse / resize remembered in the
	## settings, wrapped catalogue names, grouped issues, help keys, repeat spinboxes.
	print("Panels")
	App.open_layout(App.new_layout("Panels", "starter"))
	await _frames(2)
	var s := _s()
	var st: AppSettings = App.settings
	var keep := {}
	for k in ["inspector_auto_hide", "catalog_width", "inspector_width", "left_panel"]:
		keep[k] = st.get_v(k)
	st.set_v("inspector_auto_hide", true)
	s.clear_selection()
	s.set_tool("select")
	main.inspector.show_tab(0)
	main._update_view_rect()
	check(not main.inspector.visible, "inspector hides itself when nothing needs it")
	var share_free: float = main.canvas_share()
	var o: PlacedObject = s.layout.objects.values()[0]
	s.select([o.uid])
	check(main.inspector.visible, "selecting an object shows the inspector")
	var share_sel: float = main.canvas_share()
	check(share_free > share_sel + 0.02, "the canvas grows when the inspector hides (%.1f%% vs %.1f%%)" % [share_free * 100.0, share_sel * 100.0])
	var vr: Rect2 = main.camera.view_rect
	check(is_equal_approx(vr.end.x, main.root.get_viewport_rect().size.x + main.inspector.offset_left - 4.0), "the camera's view stops at the inspector")
	main.toggle_inspector()
	check(not main.inspector.visible, "] closes the inspector for this selection")
	var o2: PlacedObject = s.layout.objects.values()[1]
	s.select([o2.uid])
	check(main.inspector.visible, "…and it comes back for the next selection")
	s.clear_selection()
	check(not main.inspector.visible, "clearing the selection hides it again")
	main.toggle_inspector()
	check(main.inspector.visible and main.inspector_shown(), "] pins it open with nothing selected")
	main.toggle_inspector()
	check(not main.inspector.visible, "] again unpins it")
	main.inspector.show_tab(1)
	check(main.inspector.visible, "opening the Farm tab shows the inspector")
	main.toggle_inspector()
	check(not main.inspector.visible and main.inspector.current_tab() == 0, "closing it returns to the Selection tab")
	s.set_active_item("bakery")
	s.set_tool("place")
	check(main.inspector.visible, "the brush shows the inspector (placing card)")
	s.set_tool("select")
	s.set_active_item("")
	st.set_v("inspector_auto_hide", false)
	check(main.inspector.visible == bool(st.get_v("right_panel")), "auto-hide off: the inspector follows its toggle")
	st.set_v("inspector_auto_hide", true)
	# Catalogue: collapse to the rail, remembered.
	var left0: float = main.camera.view_rect.position.x
	main.set_catalog_expanded(false)
	check(main.catalog.is_collapsed() and not bool(st.get_v("left_panel")), "the catalogue collapses to its rail (remembered)")
	check(is_equal_approx(main.catalog.offset_right - main.catalog.offset_left, main.catalog.rail_width()) and main.camera.view_rect.position.x < left0,
		"collapsed catalogue is only the rail wide; the canvas grows")
	var rails := 0
	for k in main.catalog._rail_btns:
		rails += 1
	check(rails >= 10, "the rail lists scopes and categories (%d)" % rails)
	main.catalog._on_rail("cat:fence")
	check(not main.catalog.is_collapsed() and bool(st.get_v("left_panel")) and main.catalog._category == "fence", "a rail category expands the catalogue and filters it")
	main.catalog._on_rail("scope:all")
	# Widths: drag result kept in the settings file, double-click resets.
	var path := ProjectSettings.globalize_path(AppSettings.PATH)
	var win_w: float = main.root.get_viewport_rect().size.x
	var cw := minf(330.0, main._side_max(win_w, main.CATALOG_MIN))
	st.set_v("catalog_width", cw, false)
	main._catalog_grip.released.emit()
	main._update_view_rect()
	check(is_equal_approx(main.catalog.offset_right, main.MARGIN + cw), "a resized catalogue keeps its width (%d px)" % int(cw))
	var fresh := AppSettings.new()
	fresh.load_settings()
	check(is_equal_approx(float(fresh.get_v("catalog_width")), cw), "the width is saved when the drag ends (%s)" % path.get_file())
	var iw := minf(320.0, main._side_max(win_w, main.INSPECTOR_MIN))
	st.set_v("inspector_width", iw)
	s.select([o.uid])
	check(is_equal_approx(-main.inspector.offset_left, main.MARGIN + iw), "a resized inspector keeps its width")
	main._inspector_grip.reset.emit()
	check(float(st.get_v("inspector_width")) == 0.0, "double-click on the grip returns to the automatic width")
	s.clear_selection()
	# Catalogue names wrap between words only.
	var cat: CatalogPanel = main.catalog
	var split := 0
	var n := 0
	for i in mini(cat._ids.size(), 400):
		var it := App.db.get_item(cat._ids[i])
		if it == null:
			continue
		n += 1
		var words := {}
		for w in it.name.split(" ", false):
			words[w] = true
		for ln in cat._list.get_item_text(i).split("\n"):
			for w in ln.split(" ", false):
				if not words.has(w) and not w.ends_with("…"):
					split += 1
	check(n > 50 and split == 0, "catalogue names break only between words (%d names, %d split words)" % [n, split])
	var wrapped: String = cat._wrap_text("Enchanted Workshop Deluxe Edition", 70.0, 2)
	check(wrapped.split("\n").size() == 2 and wrapped.ends_with("…") and not wrapped.contains("Work\n"), "long names end in an ellipsis on the second line")
	# Repeat parameters set from code show in the dock.
	main.layout_tools.set_repeat_params({"cols": 5, "rows": 2, "gap": Vector2i(2, 1)})
	var rv: Dictionary = main.dock.repeat_values()
	check(rv["cols"] == 5 and rv["rows"] == 2 and rv["gap"] == Vector2i(2, 1), "repeat spinboxes follow parameters set from code")
	main.layout_tools.set_repeat_params({"cols": 3, "rows": 1, "gap": Vector2i.ZERO})
	# Many problems: a grouped list, outlines only for the selection.
	var bush := App.db.get_item("fence")
	var at := _free_block(Vector2i(2, 2))
	var objs: Array = []
	for i in main.ISSUE_OUTLINE_MAX + 6:
		objs.append(s.make_object(bush, at))
	s.layout.add_objects(objs)
	main._refresh_issues()
	var groups: Array = main.inspector.issue_groups()
	check(not groups.is_empty() and main.top_bar.issues_count() >= main.ISSUE_OUTLINE_MAX + 6, "issues are grouped (%s)" % str(groups.map(func(g): return "%d × %s" % [(g["uids"] as Array).size(), g["label"]])))
	check(main.overlay.issues.is_empty(), "with many problems nothing is outlined until selected")
	main._on_inspector_action("select_uids", groups[0]["uids"])
	check(not s.selection.is_empty() and main.overlay.issues.size() == s.selection.size(), "picking a group selects and outlines it")
	# Help lists this wave's keys.
	var keys := {}
	for e in Dialogs.SHORTCUTS:
		keys[e[0]] = true
	var want := ["F / Shift+F", "H / Home", "1 … 9 / Ctrl+1 … 9", "D", "Click again on the same spot", "Right-click", "Alt while dragging",
		"Symmetry (dock)", "Repeat (selection row)", "Align (selection row)", "Equal ↔ / Equal ↕", "Stamps (dock) / Save stamp", "[ / ]"]
	var missing: Array = want.filter(func(k): return not keys.has(k))
	check(missing.is_empty(), "help lists the new tools and keys %s" % str(missing))
	for k in keep:
		st.set_v(k, keep[k])
	main._update_view_rect()


# --- planning (docs/PLANNING.md): budget, areas, phases, Plan panel ------------------------

func _coins(t: BudgetEngine.Totals) -> int:
	return int(t.cost.get("coins", 0)) if t != null else -1


func _ctx_counts() -> Dictionary:
	return _conn_counts({"ctx": App.plan_ctx, "prices": App.prices})


func _find_modal_edit() -> LineEdit:
	var stack: Array = [main.modal_layer]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is LineEdit and not n.is_queued_for_deletion():
			return n
		stack.append_array(n.get_children())
	return null


func _esc() -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.pressed = true
	return e


func _plan_check() -> void:
	print("Planning")
	var ctx: PlanContext = App.plan_ctx
	var st: AppSettings = App.settings
	var keep := {}
	for k in ["budget_mode", "budget_scope", "plan_tab", "plan_show_heatmap", "budget_visible", "budget_expanded", "budget_collapsed"]:
		keep[k] = st.get_v(k)
	check(App.prices != null and App.prices.price_db_count() > 300, "price book loaded (%d researched records)" % (App.prices.price_db_count() if App.prices else 0))
	App.open_layout(App.new_layout("Plan farm", "starter"))
	main._fit_or_restore()
	main.camera.smooth = false
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5
	await _frames(3)
	var s := _s()
	check(s.budget != null and ctx.session == s and ctx.engine == s.budget and ctx.prices == App.prices, "the planning context follows the open session and its budget engine")
	ctx.set_mode(BudgetEngine.MODE_TO_BUY)
	ctx.set_scope_pin("auto")
	st.set_v("budget_visible", true)
	main._place_budget()
	await _frames(2)
	var w: BudgetWidget = main.budget
	check(w.visible and w.last_totals != null, "the budget chip is on the canvas")
	var c0 := _coins(w.last_totals)
	# Live updates: place, move, delete, undo, redo.
	var apple := App.db.get_item("apple_tree")
	var at := _free_origin(apple, Vector2i(12, 26))
	var uids := s.place_objects([s.make_object(apple, at)], "Place apple tree")
	await _frames(2)
	var price := _coins(ctx.engine.totals(uids, BudgetEngine.MODE_DESIGN))
	check(price > 0 and _coins(w.last_totals) == c0 + price, "placing updates the chip (+%d coins: %d → %d)" % [price, c0, _coins(w.last_totals)])
	var to := _free_origin(apple, at + Vector2i(3, 0))
	s.execute(EditCommands.MoveObjects.new(uids, to - at))
	await _frames(2)
	check(_coins(w.last_totals) == c0 + price, "moving keeps the cost")
	s.select(uids)
	await _frames(2)
	check(ctx.scope()["kind"] == PlanScope.SCOPE_SELECTION and _coins(w.last_totals) == price, "with a selection the chip shows the selection's cost")
	s.delete_selection()
	await _frames(2)
	check(_coins(w.last_totals) == c0, "deleting takes the cost away (back to the farm scope)")
	s.stack.undo()
	await _frames(2)
	check(_coins(w.last_totals) == c0 + price, "undo brings it back")
	s.stack.redo()
	await _frames(2)
	check(_coins(w.last_totals) == c0, "redo removes it again")
	s.stack.undo()
	await _frames(2)
	# Inventory: owning the copy takes it off "To buy", not off "Design cost".
	var p := s.layout.profile.duplicate(true)
	p["owned"] = {"apple_tree": 1}
	ctx.set_profile(p, "Own an apple tree")
	await _frames(2)
	check(_coins(w.last_totals) == c0, "recording the copy as owned removes it from To buy")
	ctx.set_mode(BudgetEngine.MODE_DESIGN)
	await _frames(2)
	check(_coins(w.last_totals) == c0 + price and st.get_v("budget_mode") == "design", "Design cost ignores the inventory (mode remembered)")
	ctx.set_mode(BudgetEngine.MODE_TO_BUY)
	# Areas: a dragged rectangle and a clicked polygon, one undo step each.
	s.clear_selection()
	var n0 := s.stack.size()
	var a := _free_block(Vector2i(8, 6))
	main.camera.center_on(Iso.tile_center(a + Vector2i(4, 3)))
	await _frames(2)
	ctx.request_area_tool.emit("rect")
	check(main.plan_controller.active(), "the area tool arms from the Plan context")
	_drag_tiles(a, a + Vector2i(3, 2))
	await _frames(1)
	var areas := PlanDoc.areas(s.layout.planning)
	check(areas.size() == 1 and PlanDoc.area_bounds(areas[0]) == Rect2i(a, Vector2i(4, 3)) and s.stack.size() == n0 + 1,
		"dragging draws a rectangle area as one undo step (%s)" % str(areas))
	check(not areas.is_empty() and ctx.active_area == str(areas[0].get("id")) and not main.plan_controller.active(), "the new area becomes the active one; the tool ends")
	ctx.request_area_tool.emit("polygon")
	for g in [a, a + Vector2i(6, 0), a + Vector2i(6, 5)]:
		var sp: Vector2 = main.camera.world_to_screen(Iso.grid_to_world(Vector2(g)))
		_move(sp)
		_button(sp, true)
		_button(sp, false)
	main.plan_controller.close_polygon()
	areas = PlanDoc.areas(s.layout.planning)
	check(areas.size() == 2 and (areas[1].get("points", []) as Array).size() == 3 and s.stack.size() == n0 + 2, "clicked corners make a polygon area")
	s.stack.undo()
	check(PlanDoc.areas(s.layout.planning).size() == 1, "undo removes the polygon")
	s.stack.redo()
	check(PlanDoc.areas(s.layout.planning).size() == 2, "redo restores it")
	ctx.request_area_tool.emit("polygon")
	main._unhandled_input(_esc())
	check(not main.plan_controller.active() and PlanDoc.areas(s.layout.planning).size() == 2, "Esc cancels the area tool without adding anything")
	# The notes tool's drag makes a planning area too (named in a prompt).
	s.set_tool("annotate")
	_drag_tiles(a + Vector2i(0, 4), a + Vector2i(2, 5))
	var le := _find_modal_edit()
	if le != null:
		le.text = "Herb Corner"
		le.text_submitted.emit(le.text)
	await _frames(1)
	areas = PlanDoc.areas(s.layout.planning)
	check(areas.size() == 3 and str(areas[areas.size() - 1].get("name")) == "Herb Corner" and s.layout.annotations.is_empty(), "a notes-tool drag adds a named planning area, not a zone note")
	s.set_tool("select")
	# Area from selection.
	var bench := App.db.get_item("bench")
	var bat := _free_origin(bench, a + Vector2i(10, 0))
	var b_uids := s.place_objects([s.make_object(bench, bat)], "Bench")
	s.select(b_uids)
	ctx.request_area_tool.emit("selection")
	areas = PlanDoc.areas(s.layout.planning)
	check(areas.size() == 4 and PlanDoc.area_bounds(areas[3]) == s.layout.bounds_of(b_uids), "an area from the selection covers its footprints")
	s.clear_selection()
	ctx.set_active_area(str(areas[0].get("id")))
	await _frames(1)
	check(ctx.scope()["kind"] == PlanScope.SCOPE_AREA, "without a selection the active area is the budget scope")
	ctx.set_scope_pin("farm")
	check(ctx.scope()["kind"] == PlanScope.SCOPE_FARM and st.get_v("budget_scope") == "farm", "pinning the whole farm overrides it (remembered)")
	ctx.set_scope_pin("auto")
	# Plan panel: J opens it in the inspector's place, Esc closes it, the tab is remembered.
	main.set_plan_open(false)
	s.select(b_uids)
	main._update_view_rect()
	_key(KEY_J)
	await _frames(2)
	check(main.plan_open() and main.plan_panel.visible and not main.inspector.visible, "J opens the Plan panel in the inspector's place")
	var vr: Rect2 = main.camera.view_rect
	check(is_equal_approx(vr.end.x, main.root.get_viewport_rect().size.x + main.plan_panel.offset_left - 4.0), "the camera's view stops at the Plan panel")
	main.open_plan("phases")
	await _frames(2)
	var tab: PlanTab = main.plan_panel.page_of("phases")
	check(tab != null and tab.is_visible_in_tree(), "the Phases tab opens")
	tab.call("_add_phase")
	await _frames(1)
	var phases := PlanDoc.phases(s.layout.planning)
	check(phases.size() == 1 and ctx.active_phase == str(phases[0].get("id")), "Add phase creates and activates a phase")
	var pid := str(phases[0].get("id")) if not phases.is_empty() else ""
	tab.call("_assign", pid)
	await _frames(1)
	check(s.budget.primary_phase(b_uids[0]) == pid, "Assign selection puts the selected objects in that phase")
	tab.call("_assign", "")
	check(not (s.layout.planning.get("assign", {}) as Dictionary).has(str(b_uids[0])), "Clear manual removes the manual assignment")
	s.clear_selection()
	_key(KEY_ESCAPE)
	await _frames(1)
	check(not main.plan_open(), "Esc closes the Plan panel")
	_key(KEY_J)
	await _frames(1)
	check(main.plan_open() and main.plan_panel.current == "phases" and st.get_v("plan_tab") == "phases", "the last tab is remembered")
	for id in PlanPanel.tab_ids():
		main.open_plan(id)
		await _frames(1)
		check(main.plan_panel.page_of(id) != null, "Plan tab “%s” opens" % id)
	main.set_plan_open(false)
	# Layers: heatmap toggle reaches the settings; exports draw the plan only when asked.
	ctx.set_layer("heatmap", true)
	check(bool(st.get_v("plan_show_heatmap")), "the heatmap layer is remembered")
	ctx.set_layer("heatmap", false)
	check(main.plan_overlay.visibility_layer == PlanOverlay.LAYER and (PlanOverlay.LAYER & (Exporter.LAYER_WORLD | Exporter.LAYER_GRID | Exporter.LAYER_OVERLAY | Exporter.LAYER_LABELS)) == 0,
		"planning marks are on a layer no ordinary export includes")
	var er: Rect2 = main.plan_export_rect("area", str(areas[0].get("id")))
	var ab := PlanDoc.area_bounds(areas[0])
	check(er.encloses(Iso.footprint_world_bounds(ab.position, ab.size)), "an area picture frames the whole area")
	check(main.plan_export_rect("farm", "").get_area() > er.get_area(), "a farm picture shows more than an area picture")
	if DisplayServer.get_name() != "headless":
		# Rendering needs a real renderer (the capture runner exports one too).
		var png := "user://selftest_plan_area.png"
		var err: Error = await main.export_plan_image({"scope": "area", "id": str(areas[0].get("id")), "guide_numbers": true, "path": png})
		var img := Image.load_from_file(ProjectSettings.globalize_path(png)) if err == OK else null
		check(err == OK and img != null and img.get_width() > 50, "a plan picture of an area is exported (%s)" % (str(img.get_size()) if img else error_string(err)))
		check(main.plan_overlay.visibility_layer == PlanOverlay.LAYER and main.plan_overlay.export_opts.is_empty(), "…and the plan overlay is back to the live view")
	# Layout switch: the chip follows the new layout.
	var objs_before := s.layout.count()
	App.open_layout(App.new_layout("Plan farm 2", "empty"))
	await _frames(2)
	check(ctx.engine == _s().budget and w.last_totals != null and w.last_totals.objects == _s().layout.count() and _s().layout.count() != objs_before,
		"switching layouts rebinds the chip (%d objects)" % (w.last_totals.objects if w.last_totals else -1))
	# No doubled handlers after a UI rebuild (theme / scale change), nor across layouts.
	var c1 := _ctx_counts()
	App.open_layout(App.new_layout("Plan farm 3", "starter"))
	await _frames(2)
	check(_ctx_counts() == c1, "layout switches leave the planning context's handlers as they were")
	await main._rebuild_ui()
	await _frames(2)
	var c2 := _ctx_counts()
	var grew: Array = []
	for k in c2:
		if int(c2[k]) > int(c1.get(k, 0)):
			grew.append("%s %d->%d" % [k, int(c1.get(k, 0)), int(c2[k])])
	check(grew.is_empty(), "a UI rebuild doesn't double the planning handlers %s" % str(grew))
	check(is_instance_valid(main.budget) and main.budget != w and main.budget.ctx == ctx, "the rebuilt UI has a fresh budget chip on the same context")
	var keys := {}
	for e in Dialogs.SHORTCUTS:
		keys[e[0]] = true
	check(keys.has("J"), "help lists the Plan panel key (J)")
	for k in keep:
		st.set_v(k, keep[k])
	ctx.set_mode(str(keep["budget_mode"]))
	ctx.set_scope_pin(str(keep["budget_scope"]))
	main._update_view_rect()


# --- planning extras: object layers, compare with my farm, area stamps, readiness, minimap ----

func _layout_json() -> String:
	return JSON.stringify(LayoutIO.to_dict(_s().layout))


func _plan_extras_check() -> void:
	print("Planning extras")
	var ctx: PlanContext = App.plan_ctx
	var st: AppSettings = App.settings
	var keep := {}
	for k in ["object_layers", "minimap_visible", "minimap_collapsed"]:
		keep[k] = st.get_v(k)
	st.set_v("object_layers", {}, false)
	App.open_layout(App.new_layout("Extras farm", "starter"))
	main._fit_or_restore()
	main.camera.smooth = false
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5
	await _frames(3)
	var s := _s()
	var r: ObjectRenderer = main.renderer
	var bench := App.db.get_item("bench")
	var apple := App.db.get_item("apple_tree")
	var fence := _first_item(func(it: ItemDef) -> bool: return it.category == "fence" and it.footprint == Vector2i.ONE and s.item_block_reason(it.id).is_empty())
	var b_at := _free_origin(bench, Vector2i(10, 24))
	var b_uid: int = s.place_objects([s.make_object(bench, b_at)], "Bench")[0]
	var a_at := _free_origin(apple, b_at + Vector2i(3, 0))
	var a_uid: int = s.place_objects([s.make_object(apple, a_at)], "Apple tree")[0]
	var f_at := _free_origin(fence, b_at + Vector2i(0, 3))
	var f_uid: int = s.place_objects([s.make_object(fence, f_at)], "Fence")[0]
	await _frames(2)
	check(ObjectLayers.group_of(App.db, "bench") == "decorations" and ObjectLayers.group_of(App.db, "apple_tree") == "trees" and ObjectLayers.group_of(App.db, fence.id) == "fences",
		"object layers group the catalogue (bench: decorations, apple tree: trees, %s: fences)" % fence.id)
	# Object layers are view only.
	s.select([b_uid, a_uid])
	var json0 := _layout_json()
	var v0 := s.stack.version
	var dirty0 := s.stack.is_dirty()
	var b_pt := Iso.footprint_center(b_at, s.layout.get_obj(b_uid).size)
	check(r.pick(b_pt) == b_uid, "the bench can be picked while its layer is shown")
	main.set_object_layer("decorations", ObjectLayers.HIDE)
	main.set_object_layer("trees", ObjectLayers.DIM)
	await _frames(2)
	check(ObjectLayers.normalize(st.get_v("object_layers")) == {"decorations": "hide", "trees": "dim"}, "layer states are remembered in the settings")
	check(r.is_layer_hidden(b_uid) and not r.is_layer_hidden(a_uid) and not r.is_layer_hidden(f_uid), "hiding decorations hides the bench only (trees dimmed, fences shown)")
	check(r.pick(b_pt) != b_uid and int(r.pick_any(b_pt).get("uid", 0)) != b_uid, "a hidden object can't be picked")
	var big := Iso.footprint_world_bounds(Vector2i(-5, -5), s.map.size + Vector2i(10, 10))
	var boxed: Array = r.uids_in_world_rect(big)
	check(not b_uid in boxed and a_uid in boxed and f_uid in boxed, "box selection skips hidden objects")
	check(not b_uid in s.selection and a_uid in s.selection, "hiding a layer lets go of its selected objects")
	check(_layout_json() == json0 and s.stack.version == v0 and s.stack.is_dirty() == dirty0, "layer toggles never change the layout or its save data")
	main.set_object_layer("decorations", ObjectLayers.SHOW)
	main.set_object_layer("trees", ObjectLayers.SHOW)
	await _frames(1)
	check(ObjectLayers.normalize(st.get_v("object_layers")).is_empty() and r.layer_hidden_count() == 0 and r.pick(b_pt) == b_uid, "showing them again restores drawing and picking")
	check(_layout_json() == json0, "the save data is still the same afterwards")
	# Compare with my farm.
	ctx.set_plan(PlanDoc.with_baseline(ctx.plan(), Baseline.snapshot(s.layout, "Mine")), "Set my real farm")
	await _frames(1)
	check(ctx.has_baseline() and int(ctx.compare_counts().get("unchanged", -1)) == s.layout.count(), "right after the snapshot everything is unchanged (%s)" % str(ctx.compare_counts()))
	var mv_to := _free_origin(bench, b_at + Vector2i(0, 4))
	s.execute(EditCommands.MoveObjects.new([b_uid], mv_to - b_at))
	s.execute(EditCommands.RemoveObjects.new([f_uid], "Remove fence"))
	var n_uid: int = s.place_objects([s.make_object(apple, _free_origin(apple, a_at + Vector2i(4, 2)))], "New tree")[0]
	ctx.set_compare(true)
	await _frames(3)
	var d := Baseline.diff(s.layout, s.layout.planning["baseline"], s.db)
	var c := ctx.compare_counts()
	check(int(c.get("unchanged", -1)) == (d["unchanged"] as Array).size() and int(c.get("moved", -1)) == (d["moved"] as Array).size()
		and int(c.get("new", -1)) == (d["new"] as Array).size() and int(c.get("removed", -1)) == (d["removed"] as Array).size(),
		"compare counts match Baseline.diff (%s)" % str(c))
	check(int(c.get("moved", 0)) == 1 and int(c.get("removed", 0)) == 1 and int(c.get("new", 0)) == 1 and n_uid in d["new"], "one moved, one removed, one new")
	check(r.view_tint_count() == s.layout.count(), "every design object gets a compare tint (%d of %d)" % [r.view_tint_count(), s.layout.count()])
	check(main.compare_legend.visible and main.compare_legend._title.text.contains("Mine"), "the compare legend names the snapshot")
	var v1 := s.stack.version
	ctx.set_compare(false)
	await _frames(2)
	check(r.view_tint_count() == 0 and not main.compare_legend.visible and s.stack.version == v1, "turning compare off clears the tints and the legend (no edit)")
	ctx.set_compare(true)
	await _frames(1)
	s.stack.undo()   # the new tree
	await _frames(2)
	check(int(ctx.compare_counts().get("new", -1)) == 0 and r.view_tint_count() == s.layout.count(), "compare follows undo")
	s.stack.redo()
	ctx.set_compare(false)
	await _frames(1)
	# Area -> stamp round trip.
	var lo := Vector2i(mini(mv_to.x, a_at.x), mini(mv_to.y, a_at.y)) - Vector2i.ONE
	var hi := Vector2i(maxi(mv_to.x, a_at.x), maxi(mv_to.y, a_at.y)) + Vector2i(3, 3)
	var aid := PlanDoc.next_id(ctx.plan(), "a")
	ctx.set_plan(PlanDoc.with_area(ctx.plan(), PlanScope.rect_area(Rect2i(lo, hi - lo), "Corner garden")), "Add area")
	var area := PlanDoc.area(ctx.plan(), aid)
	var inside: Array = PlanDoc.objects_in_area(s.layout, area)
	var v2 := s.stack.version
	var json2 := _layout_json()
	var stamp: Dictionary = main.area_to_stamp(aid)
	check(not stamp.is_empty() and (stamp["items"] as Array).size() == inside.size() and inside.size() >= 2 and str(stamp["name"]) == "Corner garden",
		"Save area as stamp keeps every object in the area (%d)" % inside.size())
	check(s.stack.version == v2 and _layout_json() == json2, "saving an area as a stamp doesn't edit the layout")
	var loaded: Dictionary = main.layout_tools.stamps.get_stamp(str(stamp.get("id", "")))
	check(not loaded.is_empty() and (loaded["items"] as Array).size() == inside.size(), "the stamp is in the library")
	var want := _relative_items(s.layout, inside)
	var target := _free_block(Vector2i(10, 10))
	var placed: Array = s.place_stamp(loaded, target + Vector2i.ONE) if target.x >= 0 and not loaded.is_empty() else []
	check(placed.size() == inside.size() and _relative_items(s.layout, placed) == want, "placing it elsewhere keeps the relative positions (%d objects)" % placed.size())
	var refused := StampLibrary.from_area(s.layout, area, func(id: String) -> String: return "fixed" if id == "apple_tree" else "")
	var kept_n := (refused["stamp"]["items"] as Array).size() if not (refused["stamp"] as Dictionary).is_empty() else 0
	check(int(refused["dropped"]) >= 1 and kept_n == inside.size() - int(refused["dropped"]), "refused items (landmarks, fixed) are left out of an area stamp")
	main.layout_tools.stamps.delete(str(stamp.get("id", "")))
	# Readiness.
	var ready0: Dictionary = ctx.readiness()
	var some := s.layout.get_obj(a_uid)
	s.execute(EditCommands.AddObjects.new([s.make_object(bench, some.origin)]))
	var over_uid: int = s.layout.objects.keys().max()
	await _frames(1)
	var ready1: Dictionary = ctx.readiness()
	var prow: Dictionary = {}
	for row: Dictionary in ready1.get("rows", []):
		if row["id"] == Readiness.PLACEMENT:
			prow = row
	check(not prow.is_empty() and over_uid in prow["uids"] and int(ready1["blocking"]) > int(ready0.get("blocking", 0)), "an overlap shows up as a blocking readiness row")
	check(is_same(ready1, ctx.readiness()), "readiness is cached between edits")
	s.stack.undo()
	await _frames(1)
	var still := false
	for row: Dictionary in ctx.readiness().get("rows", []):
		still = still or (row["id"] == Readiness.PLACEMENT and over_uid in row["uids"])
	check(not still, "undo clears the readiness row")
	# Minimap.
	st.set_v("minimap_visible", true, false)
	main._update_view_rect()
	await _frames(1)
	var mm: Minimap = main.minimap
	check(main.minimap_shown() == main.minimap_room(), "the overview shows only where the canvas has room (room: %s)" % str(main.minimap_room()))
	var full0 := mm.full_repaints
	var tiles0 := mm.tile_repaints
	s.place_objects([s.make_object(apple, _free_origin(apple, a_at + Vector2i(0, 6)))], "One more")
	await _frames(2)
	check(mm.full_repaints == full0 and mm.tile_repaints > tiles0 and mm.tile_repaints - tiles0 <= 4, "an edit repaints only its tiles on the overview (%d)" % (mm.tile_repaints - tiles0))
	if main.minimap_shown():
		var w := Iso.tile_center(a_at)
		check(mm.map_to_world(mm.world_to_map(w)).distance_to(w) < 1.0, "overview and world coordinates round-trip")
		var before: float = main.camera.view_center().distance_to(w)
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = true
		e.position = mm.world_to_map(w)
		mm._map_input(e)
		e.pressed = false
		mm._map_input(e)
		await _frames(2)
		var after: float = main.camera.view_center().distance_to(w)
		check(after < 48.0 or after < before, "clicking the overview moves the camera there (%.0f px → %.0f px)" % [before, after])
	_key(KEY_M, false, true)
	check(not bool(st.get_v("minimap_visible")) and not main.minimap_shown(), "Shift+M hides the overview")
	_key(KEY_M, false, true)
	check(bool(st.get_v("minimap_visible")) and s.tool != "land", "Shift+M shows it again (and doesn't switch to the land tool)")
	App.library.delete(s.layout.id)
	for k in keep:
		st.set_v(k, keep[k], false)


func _relative_items(l: FarmLayout, uids: Array) -> Dictionary:
	## "item@offset" of each object relative to the group's top corner.
	var lo := Vector2i(1 << 30, 1 << 30)
	for u in uids:
		lo = lo.min(l.get_obj(int(u)).origin)
	var out := {}
	for u in uids:
		var o := l.get_obj(int(u))
		out["%s@%s" % [o.item_id, str(o.origin - lo)]] = true
	return out


# --- QA journeys: the planning features played the way a player would ------------------------

const QA_DESIGN := BudgetEngine.MODE_DESIGN
const QA_TO_BUY := BudgetEngine.MODE_TO_BUY
const QA_REMAINING := BudgetEngine.MODE_REMAINING
## tests/fixtures, not tests/unit: exported self-test builds (CI) leave tests/unit out.
const QaUnit := preload("res://tests/fixtures/csv_util.gd")


func _qa_journeys() -> void:
	print("QA journeys")
	var st: AppSettings = App.settings
	var keep := {}
	for k in ["budget_mode", "budget_scope", "plan_tab", "plan_show_heatmap", "budget_visible", "budget_expanded",
			"budget_collapsed", "object_layers", "ui_scale"]:
		keep[k] = st.get_v(k)
	st.set_v("budget_visible", true)
	st.set_v("object_layers", {}, false)
	App.plan_ctx.set_mode(QA_TO_BUY)
	App.plan_ctx.set_scope_pin("auto")
	main._place_budget()
	await _qa_garden()
	await _qa_inventory_and_phases()
	await _qa_shopping()
	await _qa_checklist_resume()
	await _qa_baseline()
	await _qa_modes_and_switching()
	await _qa_migration()
	await _qa_prices()
	await _qa_layers_and_scale()
	for k in keep:
		st.set_v(k, keep[k], false)
	App.plan_ctx.set_mode(str(keep["budget_mode"]))
	App.plan_ctx.set_scope_pin(str(keep["budget_scope"]))
	main.set_plan_open(false)
	App.open_layout(App.new_layout("QA end", "starter"))
	await _frames(2)


func _qa_open(layout_name: String, template: String = "starter") -> EditorSession:
	var l := App.new_layout(layout_name, template)
	l.id = ""   # not a library layout
	App.open_layout(l)
	main._fit_or_restore()
	main.camera.smooth = false
	main.camera.zoom = Vector2(1.5, 1.5)
	main.camera.target_zoom = 1.5
	await _frames(2)
	return _s()


func _qa_line(s: EditorSession, item_id: String, at: Vector2i, n: int, step: Vector2i = Vector2i(1, 0), label: String = "") -> Array:
	## n copies in a row as one undo step (refused items: []).
	var it := App.db.get_item(item_id)
	if it == null:
		print("  info QA: item %s missing from the catalogue" % item_id)
		return []
	var objs: Array = []
	for i in n:
		objs.append(s.make_object(it, at + step * i))
	return s.place_objects(objs, label if not label.is_empty() else "Place %s" % item_id)


func _qa_price_sum(item_id: String, first_k: int, count: int) -> int:
	## Coins of copies first_k .. first_k + count - 1 (price book as it is now); -1 if any is unknown.
	var sum := 0
	for k in range(first_k, first_k + count):
		var c: Variant = App.prices.copy_price(item_id, k)
		if c == null:
			return -1
		sum += int((c as Dictionary).get("coins", 0))
	return sum


func _qa_coins(t: BudgetEngine.Totals) -> int:
	return int(t.cost.get("coins", 0)) if t != null else -1


func _qa_reconcile(eng: BudgetEngine) -> String:
	## "" when the whole farm equals the sum of its phases (+ Unphased) in every mode, land included.
	var bad: PackedStringArray = []
	for m in BudgetEngine.MODES:
		var farm := eng.totals(null, m)
		var sum := {}
		var land := {}
		var plots: Array = []
		var objects := 0
		var unknown := 0
		for pid in eng.phase_ids():
			var t := eng.phase_totals(pid, m)
			Currency.add_into(sum, t.cost)
			Currency.add_into(land, t.land_cost)
			plots.append_array(t.plots)
			objects += t.objects
			unknown += t.unknown_price_objects
		plots.sort()
		if not Currency.equal(sum, farm.cost):
			bad.append("%s cost %s != %s" % [m, str(sum), str(farm.cost)])
		if not Currency.equal(land, farm.land_cost) or plots != farm.plots:
			bad.append("%s land %s %s != %s %s" % [m, str(land), str(plots), str(farm.land_cost), str(farm.plots)])
		if objects != farm.objects or unknown != farm.unknown_price_objects:
			bad.append("%s counts %d/%d != %d/%d" % [m, objects, unknown, farm.objects, farm.unknown_price_objects])
	return "; ".join(bad)


func _qa_texts(n: Node) -> PackedStringArray:
	## Every text under a node (labels and buttons), in tree order.
	var out: PackedStringArray = []
	var stack: Array = [n]
	while not stack.is_empty():
		var nd: Node = stack.pop_front()
		if nd.is_queued_for_deletion():
			continue
		if nd is Label:
			out.append((nd as Label).text)
		elif nd is Button:
			out.append((nd as Button).text)
		stack.append_array(nd.get_children())
	return out


func _qa_find_label(n: Node, text: String) -> Control:
	var stack: Array = [n]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd.is_queued_for_deletion():
			continue
		if nd is Label and (nd as Label).text.to_lower() == text.to_lower():
			return nd
		stack.append_array(nd.get_children())
	return null


func _qa_locked_tile(s: EditorSession) -> Vector2i:
	## A free tile on a locked expansion whose supplies the map knows (-1 = none).
	for p: Dictionary in s.map.plots:
		var pid := str(p.get("id"))
		if s.map.is_plot_unlocked(pid, s.layout.unlocked_plots) or not p.get("cost") is Dictionary or (p["cost"] as Dictionary).is_empty():
			continue
		for r: Rect2i in p.get("rects", []):
			for y in range(r.position.y + 1, r.end.y - 1):
				for x in range(r.position.x + 1, r.end.x - 1):
					var t := Vector2i(x, y)
					if PlacementRules.tile_code(s.layout, s.map, t) == PlacementRules.LOCKED_LAND and not _touches_landmark(Rect2i(t - Vector2i.ONE, Vector2i(3, 3))):
						return t
	return Vector2i(-1, -1)


# 1. Flower Garden: selection budget, polygon area, overlapping area ------------------------

func _qa_garden() -> void:
	print("QA 1: Flower Garden")
	var ctx: PlanContext = App.plan_ctx
	var s: EditorSession = await _qa_open("QA flower garden")
	var w: BudgetWidget = main.budget
	var blk := _free_block(Vector2i(14, 10))
	check(blk.x >= 0, "QA1: room for a 12 × 8 garden")
	if blk.x < 0:
		return
	var a := blk + Vector2i.ONE
	var all: Array = []
	all += _qa_line(s, "stone_path", a, 6, Vector2i(1, 0), "Path")
	all += _qa_line(s, "fence", a + Vector2i(0, 7), 6, Vector2i(1, 0), "Fence")
	var lilies: Array = _qa_line(s, "african_lily", a + Vector2i(0, 2), 5) + _qa_line(s, "african_lily", a + Vector2i(0, 3), 5)
	all += lilies
	var violet := _qa_line(s, "african_violet", a + Vector2i(6, 2), 1)
	var feeder := _qa_line(s, "alpaca_feeder", a + Vector2i(6, 4), 1)
	var bench := _qa_line(s, "bench", a + Vector2i(8, 5), 1)
	all += violet + feeder + bench
	var mystery := PlacedObject.new()
	mystery.item_id = "qa_unknown_statue"   # an item the catalogue doesn't know: no price at all
	mystery.origin = a + Vector2i(10, 2)
	mystery.size = Vector2i.ONE
	var unknown := s.place_objects([mystery], "Mystery statue")
	all += unknown
	check(all.size() == 26 and lilies.size() == 10 and unknown.size() == 1, "QA1: the garden is placed (%d objects)" % all.size())
	if feeder.is_empty() or unknown.is_empty():
		return
	var eng := s.budget
	# Selection budget.
	s.select(all)
	await _frames(2)
	check(ctx.scope()["kind"] == PlanScope.SCOPE_SELECTION and _qa_coins(w.last_totals) == _qa_coins(eng.totals(all, QA_TO_BUY)),
		"QA1: selecting the garden shows its budget on the chip (%d coins)" % _qa_coins(w.last_totals))
	var lily_design := _qa_price_sum("african_lily", 1, 10)
	var lily_br: Dictionary = eng.item_breakdown(lilies, QA_DESIGN).get("african_lily", {})
	check(lily_design > 0 and int((lily_br.get("cost", {}) as Dictionary).get("coins", -1)) == lily_design
		and lily_design > 10 * _qa_price_sum("african_lily", 1, 1), "QA1: 10 lilies cost copies #1..#10 of a rising price (%d coins)" % lily_design)
	var sel := eng.totals(all, QA_DESIGN)
	var vouchers := false
	for k in sel.cost:
		vouchers = vouchers or str(k).begins_with("voucher_")
	check(vouchers, "QA1: the violet adds vouchers, never converted into coins (%s)" % Currency.format_line(sel.cost))
	check("alpaca_feeder" in sel.not_buyable_types and sel.not_buyable_objects == 1, "QA1: the feeder counts as can't be bought")
	check("qa_unknown_statue" in sel.unknown_price_types and sel.unknown_price_objects == 1 and not sel.is_exact(), "QA1: the unknown statue counts as price unknown (not 0)")
	check(w._warn.visible and w._warn.text == "+%d" % (w.last_totals.unknown_price_objects + w.last_totals.not_buyable_objects) and w._note.text.contains("unknown price"),
		"QA1: the chip says what is left out (%s · %s)" % [w._warn.text, w._note.text])
	# The heatmap and the shopping list keep unknowns visible too.
	var heat: Dictionary = main.plan_overlay.heat_buckets()
	check(int(heat.get(unknown[0], 0)) == PlanScope.HEAT_UNKNOWN and int(heat.get(feeder[0], 0)) == PlanScope.HEAT_NOT_BUYABLE,
		"QA1: the heatmap hatches the unknown and the unbuyable object")
	var rows := ShoppingList.build(eng, all, QA_TO_BUY)
	var csv := QaUnit.parse_csv(PlanUiModels.shop_csv(rows))
	var head: Array = csv[0]
	var stat_row: Array = []
	for i in range(1, csv.size()):
		if csv[i][head.find("item_id")] == "qa_unknown_statue":
			stat_row = csv[i]
	check(not stat_row.is_empty() and stat_row[head.find("next_price")] == "unknown" and stat_row[head.find("unknown_price_copies")] == "1",
		"QA1: the shopping CSV writes the statue's price as unknown")
	# Polygon area drawn around it.
	s.clear_selection()
	main.camera.center_on(Iso.tile_center(a + Vector2i(6, 4)))
	await _frames(1)
	var n0 := s.stack.size()
	ctx.request_area_tool.emit("polygon")
	for g in [a, a + Vector2i(12, 0), a + Vector2i(12, 8), a + Vector2i(0, 8)]:
		var sp: Vector2 = main.camera.world_to_screen(Iso.grid_to_world(Vector2(g)))
		_move(sp)
		_button(sp, true)
		_button(sp, false)
	main.plan_controller.close_polygon()
	await _frames(1)
	var aid := ctx.active_area
	check(not aid.is_empty() and s.stack.size() == n0 + 1, "QA1: the polygon area is one undo step")
	var area := PlanDoc.area(ctx.plan(), aid).duplicate(true)
	area["name"] = "Flower Garden"
	ctx.set_plan(PlanDoc.with_area(ctx.plan(), area), "Rename area")
	var members: Array = eng.area_uids(aid).duplicate()
	var want: Array = all.duplicate()
	members.sort()
	want.sort()
	check(members == want, "QA1: the polygon holds exactly the garden (%d of %d)" % [members.size(), want.size()])
	var same := true
	for m in BudgetEngine.MODES:
		var at := eng.area_totals(aid, m)
		var stt := eng.totals(all, m)
		same = same and Currency.equal(at.cost, stt.cost) and at.objects == stt.objects and at.unknown_price_objects == stt.unknown_price_objects \
			and at.not_buyable_objects == stt.not_buyable_objects and at.plots == stt.plots
	check(same, "QA1: area budget == selection budget in every mode")
	await _frames(1)
	check(ctx.scope()["kind"] == PlanScope.SCOPE_AREA and Currency.equal(w.last_totals.cost, eng.area_totals(aid, ctx.mode).cost), "QA1: the chip follows the active area")
	# A second, overlapping area.
	var farm0 := {}
	for m in BudgetEngine.MODES:
		farm0[m] = eng.totals(null, m).cost.duplicate()
	ctx.request_area_tool.emit("rect")
	_drag_tiles(a, a + Vector2i(3, 7))
	await _frames(1)
	check(PlanDoc.areas(ctx.plan()).size() == 2, "QA1: a second area drawn over the left half")
	var unchanged := true
	for m in BudgetEngine.MODES:
		unchanged = unchanged and Currency.equal(farm0[m], eng.totals(null, m).cost)
	check(unchanged, "QA1: another area doesn't change the grand total")
	main.open_plan("areas")
	await _frames(2)
	var at_tab: PlanTab = main.plan_panel.page_of("areas")
	var note := str(at_tab.get("notice_text"))
	check(note.contains("not additive") and note.contains("Flower Garden"), "QA1: the Areas tab says area totals are not additive (%s)" % note)
	main.set_plan_open(false)


# 2 + 3. Inventory across areas, then phases ------------------------------------------------

func _qa_inventory_and_phases() -> void:
	print("QA 2/3: inventory and phases")
	var ctx: PlanContext = App.plan_ctx
	var s: EditorSession = await _qa_open("QA inventory")
	var eng := s.budget
	var blk := _free_block(Vector2i(13, 9))
	check(blk.x >= 0, "QA2: room for two fence rows")
	if blk.x < 0:
		return
	var a := blk + Vector2i.ONE
	var row_a := _qa_line(s, "fence", a, 10, Vector2i(1, 0), "Fence row A")
	var row_b := _qa_line(s, "fence", a + Vector2i(0, 4), 10, Vector2i(1, 0), "Fence row B")
	var pc: PlanController = main.plan_controller
	var area_a := pc.add_rect(Rect2i(a, Vector2i(10, 2)), "Entrance strip")
	var area_b := pc.add_rect(Rect2i(a + Vector2i(0, 3), Vector2i(10, 3)), "Garden strip")
	var p := s.layout.profile.duplicate(true)
	p["owned"] = {"fence": 20}
	ctx.set_profile(p, "Record 20 fences")
	var br: Dictionary = eng.item_breakdown(null, QA_TO_BUY).get("fence", {})
	check(row_a.size() == 10 and row_b.size() == 10 and int(br.get("owned", 0)) == 20 and int(br.get("charged", -1)) == 0, "QA2: 20 owned fences, none to buy on the farm")
	check(eng.area_totals(area_a, QA_TO_BUY).charged_objects == 0 and eng.area_totals(area_b, QA_TO_BUY).charged_objects == 0,
		"QA2: 10 fences in each area, each area charges 0 fences")
	s.execute(EditCommands.MoveObjects.new([row_a[0]], Vector2i(0, 3)))
	await _frames(1)
	check(eng.status_of(row_a[0]) == BudgetEngine.STATUS_OWNED and eng.area_uids(area_a).size() == 9 and eng.area_uids(area_b).size() == 11
		and int(eng.item_breakdown(null, QA_TO_BUY)["fence"]["charged"]) == 0, "QA2: a fence moved to the other area stays owned; totals unchanged")
	var design := _qa_price_sum("fence", 1, 20)
	check(int(eng.item_breakdown(null, QA_DESIGN)["fence"]["cost"].get("coins", -1)) == design, "QA2: Design mode still prices all 20 (%d coins)" % design)
	s.stack.undo()
	# 3. Phases (with an Orchard on locked land when the map has some).
	p = s.layout.profile.duplicate(true)
	p["owned"] = {"fence": 10, "apple_tree": 0}
	ctx.set_profile(p, "Only 10 fences")
	var lt := _qa_locked_tile(s)
	var apple: Array = []
	if lt.x >= 0:
		apple = _qa_line(s, "apple_tree", lt, 1, Vector2i(1, 0), "Apple tree on locked land")
	var plan := ctx.plan()
	var ids := {}
	ids["Entrance"] = PlanDoc.next_id(plan, "p")
	plan = PlanDoc.with_phase(plan, {"name": "Entrance", "areas": [area_a]})
	ids["Garden"] = PlanDoc.next_id(plan, "p")
	plan = PlanDoc.with_phase(plan, {"name": "Garden", "areas": [area_b]})
	if not apple.is_empty():
		var area_c := PlanDoc.next_id(plan, "a")
		plan = PlanDoc.with_area(plan, PlanScope.rect_area(Rect2i(lt - Vector2i.ONE, Vector2i(3, 3)), "Orchard corner"))
		ids["Orchard"] = PlanDoc.next_id(plan, "p")
		plan = PlanDoc.with_phase(plan, {"name": "Orchard", "areas": [area_c]})
	ctx.set_plan(plan, "Phases")
	check(PlanDoc.phases(ctx.plan()).size() == (3 if not apple.is_empty() else 2),
		"QA3: phases Entrance, Garden%s" % (", Orchard (on locked land)" if not apple.is_empty() else " (no locked land with known supplies found)"))
	var first_owned := true
	var second_buy := true
	for u in row_a:
		first_owned = first_owned and eng.status_of(u) == BudgetEngine.STATUS_OWNED
	for u in row_b:
		second_buy = second_buy and eng.status_of(u) == BudgetEngine.STATUS_TO_BUY
	check(first_owned and second_buy, "QA3: the 10 owned fences go to the first phase (Entrance)")
	var rec := _qa_reconcile(eng)
	check(rec.is_empty(), "QA3: whole farm == phases + Unphased in every mode, land included %s" % rec)
	if not apple.is_empty():
		var t := eng.totals(null, QA_TO_BUY)
		var orch := eng.phase_totals(str(ids["Orchard"]), QA_TO_BUY)
		check(not orch.plots.is_empty() and orch.plots == t.plots and not orch.land_cost.is_empty() and Currency.covers(t.cost, orch.land_cost),
			"QA3: the Orchard's locked plot adds its supplies to To buy (%s)" % Currency.format_line(orch.land_cost))
		var od := eng.phase_totals(str(ids["Orchard"]), QA_DESIGN)
		check(Currency.equal(od.cost, od.object_cost), "QA3: Design cost leaves the land out")
	ctx.set_plan(PlanDoc.with_phase_moved(ctx.plan(), str(ids["Garden"]), 0), "Move phase earlier")
	first_owned = true
	second_buy = true
	for u in row_b:
		first_owned = first_owned and eng.status_of(u) == BudgetEngine.STATUS_OWNED
	for u in row_a:
		second_buy = second_buy and eng.status_of(u) == BudgetEngine.STATUS_TO_BUY
	check(first_owned and second_buy, "QA3: reordering phases gives the owned copies to the new first phase (Garden)")
	rec = _qa_reconcile(eng)
	check(rec.is_empty(), "QA3: still reconciles after the reorder %s" % rec)
	# Manual assignment through the Phases tab, then deleting that phase.
	var target := str(ids.get("Orchard", ids["Entrance"]))
	main.open_plan("phases")
	await _frames(1)
	s.select([row_a[0]])
	(main.plan_panel.page_of("phases") as PlanTab).call("_assign", target)
	check(eng.primary_phase(row_a[0]) == target, "QA3: assigning an object puts it in that phase")
	rec = _qa_reconcile(eng)
	check(rec.is_empty(), "QA3: reconciles with a manual assignment %s" % rec)
	ctx.set_plan(PlanDoc.without_phase(ctx.plan(), target), "Delete phase")
	var fallback := str(ids["Entrance"]) if target != str(ids["Entrance"]) else BudgetEngine.UNPHASED
	check(eng.primary_phase(row_a[0]) == fallback and not (ctx.plan()["assign"] as Dictionary).has(str(row_a[0])),
		"QA3: deleting the phase sends its objects back to the area rule (%s)" % eng.primary_phase(row_a[0]))
	if not apple.is_empty():
		check(eng.primary_phase(apple[0]) == BudgetEngine.UNPHASED, "QA3: the apple tree's area has no phase left: Unphased")
	rec = _qa_reconcile(eng)
	check(rec.is_empty(), "QA3: reconciles after deleting a phase %s" % rec)
	s.stack.undo()
	check(eng.primary_phase(row_a[0]) == target, "QA3: undo brings the phase and the assignment back")
	s.clear_selection()
	main.set_plan_open(false)


# 4. Shopping list ------------------------------------------------------------------------------

func _qa_hedge_row(tab: PlanTab) -> Dictionary:
	tab.refresh()
	for r: Dictionary in tab.get("rows"):
		if str(r.get("item")) == "hedge":
			return r
	return {}


func _qa_shopping() -> void:
	print("QA 4: shopping")
	var ctx: PlanContext = App.plan_ctx
	var s: EditorSession = await _qa_open("QA shopping")
	var eng := s.budget
	var blk := _free_block(Vector2i(12, 6))
	if blk.x < 0:
		check(false, "QA4: room for 40 hedges")
		return
	var hedges: Array = []
	for y in 4:
		hedges += _qa_line(s, "hedge", blk + Vector2i(1, 1 + y), 10, Vector2i(1, 0), "Hedges")
	var p := s.layout.profile.duplicate(true)
	p["owned"] = {"hedge": 0}
	ctx.set_profile(p, "No hedges yet")
	main.open_plan("shop")
	await _frames(2)
	var tab: PlanTab = main.plan_panel.page_of("shop")
	tab.set("_mode", QA_REMAINING)
	var r0 := _qa_hedge_row(tab)
	var all40 := _qa_price_sum("hedge", 1, 40)
	check(hedges.size() == 40 and int(r0.get("missing", -1)) == 40 and int((r0.get("total", {}) as Dictionary).get("coins", -1)) == all40,
		"QA4: 40 hedges to buy (%d coins)" % all40)
	ctx.set_plan(PlanDoc.with_acquired(ctx.plan(), "hedge", 15), "Bought: Hedge", "shop_bought:hedge")
	var r1 := _qa_hedge_row(tab)
	var rest := _qa_price_sum("hedge", 16, 25)
	check(int(r1.get("missing", -1)) == 25 and int(r1.get("acquired", -1)) == 15 and int((r1.get("total", {}) as Dictionary).get("coins", -1)) == rest
		and _qa_coins(eng.totals(null, QA_REMAINING)) == rest, "QA4: 15 of 40 bought: 25 still needed, remaining %d coins" % rest)
	check(Currency.equal(r1.get("next_price"), App.prices.copy_price("hedge", 16)), "QA4: the next copy to buy is #16 (rising price)")
	check(_qa_coins(eng.totals(null, QA_TO_BUY)) == all40, "QA4: To buy still counts the 15 bought copies")
	s.stack.undo()
	check(int(_qa_hedge_row(tab).get("missing", -1)) == 40, "QA4: undo restores 40 needed")
	s.stack.redo()
	var n0 := s.stack.size()
	tab.call("_apply_to_inventory")
	var prof := s.layout.profile
	check(s.stack.size() == n0 + 1 and int(prof["owned"].get("hedge", -1)) == 15 and int(prof["purchased"].get("hedge", -1)) == 15
		and (ctx.plan()["acquired"] as Dictionary).is_empty(), "QA4: “Add bought items to my inventory” is one undo step")
	var r2 := _qa_hedge_row(tab)
	check(_qa_coins(eng.totals(null, QA_REMAINING)) == rest and _qa_coins(eng.totals(null, QA_TO_BUY)) == rest and int(r2.get("missing", -1)) == 25
		and int(r2.get("owned", -1)) == 15, "QA4: afterwards nothing is counted twice (remaining = to buy = %d)" % rest)
	tab.call("_apply_to_inventory")
	check(s.stack.size() == n0 + 1 and int(s.layout.profile["owned"]["hedge"]) == 15, "QA4: applying again adds nothing")
	s.stack.undo()
	check(int(s.layout.profile["owned"].get("hedge", -1)) == 0 and int((ctx.plan()["acquired"] as Dictionary).get("hedge", 0)) == 15, "QA4: one undo restores both halves")
	s.stack.redo()
	ctx.set_plan(PlanDoc.with_acquired(ctx.plan(), "hedge", 5), "Bought: Hedge", "shop_bought:hedge")
	check(Currency.equal(_qa_hedge_row(tab).get("next_price"), App.prices.copy_price("hedge", 21)), "QA4: after 5 more purchases the next copy is #21")
	main.set_plan_open(false)


# 5 + 10. Build checklist and guide: tick, undo, save, reopen, resume; guide exports ----------

func _qa_checklist_resume() -> void:
	print("QA 5/10: checklist, guide, exports")
	var ctx: PlanContext = App.plan_ctx
	var s: EditorSession = await _qa_open("QA resume")
	var silo := -1
	for o: PlacedObject in s.layout.objects.values():
		if o.item_id == "silo":
			silo = o.uid
	ctx.set_plan(PlanDoc.with_baseline(ctx.plan(), Baseline.snapshot(s.layout, "My farm")), "Set my real farm")
	if silo > 0:
		s.execute(EditCommands.RemoveObjects.new([silo]))
	var blk := _free_block(Vector2i(10, 6))
	if blk.x < 0:
		check(false, "QA5: room for a small design")
		return
	var lilies := _qa_line(s, "african_lily", blk + Vector2i(1, 1), 3)
	_qa_line(s, "stone_path", blk + Vector2i(1, 3), 4)
	ctx.set_plan(PlanDoc.with_acquired(ctx.plan(), "african_lily", 1), "Bought: African lily")
	main.open_plan("guide")
	await _frames(2)
	var gt: PlanTab = main.plan_panel.page_of("guide")
	var g := ctx.guide()
	var steps: Array = g["steps"]
	var store_i := -1
	var lily_i := -1
	for i in steps.size():
		if steps[i]["kind"] == "store" and store_i < 0:
			store_i = i
		if steps[i]["kind"] == "place" and "african_lily" in steps[i]["items"] and lily_i < 0:
			lily_i = i
	check(silo > 0 and store_i >= 0 and lily_i > store_i, "QA5: the guide stores the silo before placing new things")
	if store_i < 0 or lily_i < 0:
		return
	gt.set("current", store_i)
	gt.call("_toggle_done")
	gt.set("current", lily_i)
	gt.call("_toggle_done")
	g = ctx.guide()
	check(bool(g["steps"][store_i]["done"]) and bool(g["steps"][lily_i]["done"]) and int(g["progress"]["completed"]) == 2,
		"QA5: two steps ticked (a hand tick and three lilies marked placed)")
	s.stack.undo()
	var after_undo := int(ctx.guide()["progress"]["completed"])
	check(after_undo < 2, "QA5: undo takes the ticks back (%d left)" % after_undo)
	s.stack.redo()
	check(int(ctx.guide()["progress"]["completed"]) == 2, "QA5: redo")
	var plan_before := PlanDoc.normalize(ctx.plan())
	var current := int(ctx.guide()["progress"]["current"])
	var path := "user://qa_resume.hdlayout"
	check(LayoutIO.save_file(s.layout, path) == OK, "QA5: saved to %s" % path)
	var rep := LayoutIO.LoadReport.new()
	var back := LayoutIO.load_file(path, App.db, rep, App.map)
	check(back != null, "QA5: reopened")
	if back == null:
		return
	App.open_layout(back, rep)
	await _frames(2)
	s = _s()
	var lost: Array = []
	for k in ["placed", "steps_done", "acquired", "baseline", "areas", "phases"]:
		if plan_before.get(k) != s.layout.planning.get(k):
			lost.append(k)
	check(lost.is_empty(), "QA5: placed, steps_done, acquired and baseline survive save / close / reopen %s" % str(lost))
	check(int(ctx.guide()["progress"]["completed"]) == 2 and int(ctx.guide()["progress"]["current"]) == current, "QA5: the guide resumes at the same step")
	var eng := s.budget
	var u: int = lilies[0]
	check(eng.is_placed(u), "QA5: the ticked lily counts as placed after reopening")
	# Moving a placed object.
	var mv := Vector2i(0, -1) if PlacementRules.check_group_move(s.layout, s.map, [u], Vector2i(0, -1)).ok else Vector2i(-1, 0)
	s.execute(EditCommands.MoveObjects.new([u], mv))
	main.open_plan("build")
	await _frames(2)
	var bt: PlanTab = main.plan_panel.page_of("build")
	bt.refresh()
	check(u in ((bt.get("checklist") as Dictionary).get("moved", []) as Array), "QA5: the Build tab lists it as moved since placed")
	s.stack.undo()
	# Duplicate / paste / repeat of a placed object.
	s.select([u])
	s.copy_selection()
	var spot := _free_origin(App.db.get_item("african_lily"), s.layout.get_obj(u).origin + Vector2i(0, 5))
	var copies := s.place_objects(s.clipboard_objects(spot), "Paste")
	check(copies.size() == 1 and copies[0] != u and not eng.is_placed(copies[0]) and not PlanDoc.is_placed(ctx.plan(), copies[0]),
		"QA5: a pasted copy of a placed object is not placed")
	s.select([u])
	var reps := s.apply_repeat(1, 3, Vector2i(0, 2))
	var rep_placed := false
	for c in reps:
		rep_placed = rep_placed or eng.is_placed(int(c))
	check(not rep_placed, "QA5: repeated copies aren't placed either (%d)" % reps.size())
	# Delete then undo.
	bt.refresh()
	var placed_n := int((bt.get("checklist") as Dictionary)["overall"]["placed"])
	s.select([u])
	s.delete_selection()
	check(not eng.is_placed(u), "QA5: a deleted object is no longer placed")
	s.stack.undo()
	bt.refresh()
	check(eng.is_placed(u) and int((bt.get("checklist") as Dictionary)["overall"]["placed"]) == placed_n, "QA5: undoing the delete restores its placed state")
	# 10. Exports of this guide.
	var guide := ctx.guide()
	var gsteps: Array = guide["steps"]
	var js: Variant = JSON.parse_string(GuideExport.to_json(guide, {"title": "QA"}))
	check(js is Dictionary and str(js["format"]) == GuideExport.FORMAT and (js["steps"] as Array).size() == gsteps.size(), "QA10: guide JSON parses with every step")
	var csv := QaUnit.parse_csv(GuideExport.to_csv(guide))
	var cols_ok := csv.size() == gsteps.size() + 1
	for row in csv:
		cols_ok = cols_ok and (row as Array).size() == GuideExport.CSV_COLUMNS.size()
	check(cols_ok, "QA10: guide CSV: a header and one row per step, every column")
	var txt := GuideExport.to_text(guide, {"title": "QA"})
	check(txt.count("\n[") == gsteps.size(), "QA10: the plain-text guide lists every step")
	main.open_plan("guide")
	await _frames(1)
	var dir := ProjectSettings.globalize_path("user://qa_guide")
	var h: Dictionary = gt.call("html_for", dir.path_join("guide.html"))
	var html := str(h["html"])
	check(html.begins_with("<!doctype html>") and html.count("<li class=\"step") == gsteps.size() and html.contains("</html>"), "QA10: the guide HTML has every step")
	var imgs_ok := not (h["images"] as Array).is_empty()
	for o: Dictionary in h["images"]:
		imgs_ok = imgs_ok and str(o["path"]).begins_with(dir) and not PlanUiKit.is_inside_repo(str(o["path"]))
	check(imgs_ok, "QA10: its pictures go next to the page, never into the program folder")
	var before := int(main.export_refused)
	# The program folder as the app sees it (an exported build has no res:// folder).
	main._plan_export({"scope": "farm", "id": "", "guide_numbers": true, "path": PlanUiKit.repo_dir().path_join("qa_plan.png")})
	main._plan_export({"scope": "farm", "id": "", "path": "res://qa_plan2.png", "art": "installed"})
	check(int(main.export_refused) == before + 2 and not FileAccess.file_exists("res://qa_plan.png") and not FileAccess.file_exists("res://qa_plan2.png"),
		"QA10: picture requests into the program folder are refused (any art) (refused %d of 2; program folder %s)" % [int(main.export_refused) - before, PlanUiKit.repo_dir()])
	check(not bool(gt.call("_request_image", {"scope": "farm", "id": "", "path": "res://qa_plan3.png"})), "QA10: the Guide tab refuses them too")
	var req: Dictionary = main.plan_export_request({"scope": "area", "id": "a1", "path": dir.path_join("x.png")})
	check(str(req.get("art")) == "placeholder", "QA10: picture requests default to placeholder art")
	main.set_plan_open(false)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# 6. Baseline: compare, guide dependencies, swap -------------------------------------------------

func _qa_baseline() -> void:
	print("QA 6: my real farm")
	var ctx: PlanContext = App.plan_ctx
	var s: EditorSession = await _qa_open("QA baseline", "empty")
	var blk := _free_block(Vector2i(10, 8))
	if blk.x < 0:
		check(false, "QA6: room")
		return
	var a := blk + Vector2i.ONE
	var x: int = _qa_line(s, "african_lily", a, 1)[0]
	var y: int = _qa_line(s, "african_violet", a + Vector2i(2, 0), 1)[0]
	var r: int = _qa_line(s, "alpaca_feeder", a + Vector2i(0, 3), 1)[0]
	var m: int = _qa_line(s, "fence", a + Vector2i(5, 3), 1)[0]
	var keep_u: int = _qa_line(s, "stone_path", a + Vector2i(7, 0), 1)[0]
	ctx.set_plan(PlanDoc.with_baseline(ctx.plan(), Baseline.snapshot(s.layout, "My farm")), "Set my real farm")
	check(int(ctx.compare_counts().get("unchanged", -1)) == s.layout.count(), "QA6: right after the snapshot everything is unchanged")
	s.execute(EditCommands.MoveEach.new([x, y], [Vector2i(2, 0), Vector2i(-2, 0)], "Swap"))
	s.execute(EditCommands.RemoveObjects.new([r]))
	var n: int = _qa_line(s, "stone_path", a + Vector2i(0, 3), 1)[0]   # onto the feeder's freed tile
	s.execute(EditCommands.MoveObjects.new([m], Vector2i(0, 2)))
	var c := ctx.compare_counts()
	check(int(c.get("moved", -1)) == 3 and int(c.get("removed", -1)) == 1 and int(c.get("new", -1)) == 1 and int(c.get("unchanged", -1)) == s.layout.count() - 4,
		"QA6: compare counts 3 moved, 1 removed, 1 new (%s)" % str(c))
	var steps: Array = ctx.guide()["steps"]
	var idx := {}
	for i in steps.size():
		var k := str(steps[i]["kind"])
		if not idx.has(k):
			idx[k] = []
		idx[k].append(i)
	var place_n := -1
	for i in steps.size():
		if steps[i]["kind"] == "place" and n in steps[i]["uids"]:
			place_n = i
	check(idx.has("store") and place_n > int(idx["store"][0]), "QA6: the feeder is stored before the path is placed on its tile")
	check((idx.get("store_temp", []) as Array).size() == 1 and (idx.get("place_from_storage", []) as Array).size() == 1
		and int(steps[idx["store_temp"][0]]["then_step"]) == int(steps[idx["place_from_storage"][0]]["number"]), "QA6: the swap is broken by one temporary storage")
	var move_ok := false
	for i in idx.get("move", []):
		move_ok = move_ok or (m in steps[i]["uids"] and i < place_n)
	check(move_ok, "QA6: the fence move comes before placing new objects")
	check(s.budget.status_of(x) == BudgetEngine.STATUS_OWNED and s.budget.status_of(n) == BudgetEngine.STATUS_TO_BUY,
		"QA6: baseline copies count as owned, the new path is to buy")
	check(s.budget.is_placed(keep_u) and not s.budget.is_placed(x), "QA6: the unchanged path counts as placed, the swapped lily doesn't")


# 7. Modes, farm level, layout switching ----------------------------------------------------------

func _qa_layout_with(item_id: String, at: Vector2i, n: int, layout_name: String) -> FarmLayout:
	var l := App.new_layout(layout_name, "empty")
	l.id = ""
	var it := App.db.get_item(item_id)
	var objs: Array = []
	for i in n:
		var o := PlacedObject.new()
		o.item_id = item_id
		o.origin = at + Vector2i(i, 0)
		o.size = it.size_for(false)
		objs.append(o)
	l.add_objects(objs)
	return l


func _qa_modes_and_switching() -> void:
	print("QA 7: modes, level, switching")
	var ctx: PlanContext = App.plan_ctx
	var s: EditorSession = await _qa_open("QA modes")
	var w: BudgetWidget = main.budget
	var blk := _free_block(Vector2i(6, 4))
	var barrels := _qa_line(s, "barrels", blk + Vector2i.ONE, 2)
	var p := s.layout.profile.duplicate(true)
	p["level"] = 5
	ctx.set_profile(p, "Level 5")
	await _frames(2)
	var c0 := _qa_coins(w.last_totals)
	s.set_mode(FarmLayout.MODE_REALISTIC)
	await _frames(2)
	check(ctx.engine == s.budget and _qa_coins(w.last_totals) == c0 and w.visible, "QA7: Realistic mode keeps the budget (%d coins)" % c0)
	var lvl_row := false
	for row: Dictionary in ctx.readiness().get("rows", []):
		lvl_row = lvl_row or (row["id"] == Readiness.LEVEL and not barrels.is_empty() and barrels[0] in row["uids"])
	check(lvl_row, "QA7: at level 5 the level-17 barrels show up as a level issue")
	check(s.analysis().cost_source == "budget" and s.analysis().coins_needed == _qa_coins(s.budget.totals(null, QA_TO_BUY)),
		"QA7: the Realistic verdict's coins are the budget's To-buy figure (%d)" % s.analysis().coins_needed)
	p = s.layout.profile.duplicate(true)
	p["level"] = 20
	ctx.set_profile(p, "Level 20")
	lvl_row = false
	for row: Dictionary in ctx.readiness().get("rows", []):
		lvl_row = lvl_row or row["id"] == Readiness.LEVEL
	check(not lvl_row, "QA7: raising the farm level clears the level issue")
	s.set_mode(FarmLayout.MODE_CREATIVE)
	await _frames(1)
	check(_qa_coins(w.last_totals) == c0, "QA7: back in Creative mode the budget is the same")
	# Two layouts with the same edit counters but different contents: nothing stale.
	ctx.set_layer("heatmap", true)
	ctx.set_scope_pin("farm")
	var at := _free_block(Vector2i(5, 3)) + Vector2i.ONE
	var la := _qa_layout_with("golden_wall", at, 3, "QA expensive")
	var lb := _qa_layout_with("fence", at, 3, "QA cheap")
	App.open_layout(la)
	await _frames(2)
	var texts_a := _qa_texts(w)
	App.open_layout(lb)
	await _frames(2)
	var texts_b := _qa_texts(w)
	w._sig = ""
	w.refresh()
	var fresh := _qa_texts(w)
	check(texts_b == fresh and texts_a != fresh, "QA7: after switching layouts the chip shows the new layout's numbers, not the old ones (%s)" % " ".join(texts_b))
	var heat: Dictionary = main.plan_overlay.heat_buckets()
	var eng := _s().budget
	var heat_ok := heat.size() == _s().layout.count()
	for u in heat:
		heat_ok = heat_ok and int(heat[u]) == PlanScope.heat_bucket(eng.object_cost(u, ctx.mode), str(eng.object_info(u).get("price_state", "")))
	check(heat_ok, "QA7: the heatmap is recomputed for the new layout")
	ctx.set_layer("heatmap", false)
	ctx.set_scope_pin("auto")
	# Handlers and engines don't pile up.
	var c1 := _ctx_counts()
	var weak: WeakRef = weakref(eng)
	eng = null
	la = null
	lb = null
	for i in 4:
		await _qa_open("QA switch %d" % i, ["starter", "empty"][i % 2])
	check(_ctx_counts() == c1, "QA7: four more switches leave the planning context's and price book's handlers as they were")
	check(weak.get_ref() == null, "QA7: the previous budget engine is freed (no leak)")


# 8. Migration ---------------------------------------------------------------------------------

func _qa_migration() -> void:
	print("QA 8: migration")
	var v3 := {"format": LayoutIO.FORMAT, "schema_version": 3, "app_version": "0.2.0",
		"meta": {"id": "qa_v3", "name": "Old v3 farm", "mode": "creative"},
		"map": {"id": "hayday_farm", "unlocked_plots": []},
		"objects": [{"uid": 1, "item": "bakery", "x": 4, "y": 4, "w": 3, "h": 3}],
		"annotations": [{"id": 1, "kind": "zone", "rect": [2, 2, 6, 6], "text": "Herb bed", "color": "#8fc46a"},
			{"id": 2, "kind": "label", "rect": [10, 2, 1, 1], "text": "Remember the gate"},
			{"id": 3, "rect": [12, 2, 3, 3], "text": ""}],
		"world": FarmLayout.default_world_state()}
	var text := JSON.stringify(v3, "\t")
	var path := App.library.path_for("qa_v3")
	JsonUtil.write_atomic(path, text, false)
	var rep := LayoutIO.LoadReport.new()
	var l := App.library.load_layout("qa_v3", rep)
	check(l != null and rep.migrated_from == 3 and rep.zones_to_areas == 2, "QA8: a v3 layout opens as v4 (%s)" % (rep.summary() if l else rep.error))
	if l == null:
		return
	var areas := PlanDoc.areas(l.planning)
	check(areas.size() == 2 and str(areas[0]["name"]) == "Herb bed" and str(areas[0].get("color")) == "#8fc46a" and str(areas[1]["name"]) == "Area 2"
		and l.annotations.size() == 1 and str(l.annotations[0].get("text")) == "Remember the gate" and l.count() == 1,
		"QA8: zones became areas (names, colour), the label stays a note, the object is kept")
	App.open_layout(l, rep)
	await _frames(2)
	var s := _s()
	check(areas.size() == 2 and s.budget.area_uids(str(areas[0]["id"])) == [1], "QA8: the migrated area works in the budget")
	check(App.save_current(false) == OK and JsonUtil.read_text(LayoutIO.backup_path_for(path, 3)) == text, "QA8: the first save keeps a .v3-backup of the original")
	var rep2 := LayoutIO.LoadReport.new()
	var again := App.library.load_layout("qa_v3", rep2)
	check(again != null and rep2.migrated_from < 0 and PlanDoc.areas(again.planning).size() == 2 and again.annotations.size() == 1, "QA8: reloaded as v4, nothing lost")
	App.library.delete("qa_v3")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LayoutIO.backup_path_for(path, 3)))
	var rep1 := LayoutIO.LoadReport.new()
	var v1 := LayoutIO.load_file("res://tests/fixtures/v1_sample_minimal_starter.hdlayout", App.db, rep1, App.map)
	check(v1 != null and rep1.migrated_from == 1 and int(LayoutIO.to_dict(v1)["schema_version"]) == LayoutIO.SCHEMA_VERSION and PlanDoc.areas(v1.planning).is_empty(),
		"QA8: a v1 sample still migrates (to v%d)" % LayoutIO.SCHEMA_VERSION)


# 9. Price overrides --------------------------------------------------------------------------

func _qa_prices() -> void:
	print("QA 9: price overrides")
	var ctx: PlanContext = App.plan_ctx
	var s: EditorSession = await _qa_open("QA prices", "empty")
	var w: BudgetWidget = main.budget
	var blk := _free_block(Vector2i(5, 3))
	var item := "apple_tree"
	var uids := _qa_line(s, item, blk + Vector2i.ONE, 2)
	var p := s.layout.profile.duplicate(true)
	p["owned"] = {item: 0}
	ctx.set_profile(p, "None owned")
	ctx.set_scope_pin("farm")
	await _frames(2)
	var researched: Variant = App.prices.copy_price(item, 1)
	var c0 := _qa_coins(w.last_totals)
	var mine := (int((researched as Dictionary).get("coins", 0)) if researched is Dictionary else 0) + 1000
	check(App.prices.overrides_path.begins_with("user://") and not PlanUiKit.is_inside_repo(ProjectSettings.globalize_path(App.prices.overrides_path)),
		"QA9: overrides live in the user data folder (%s)" % App.prices.overrides_path)
	App.prices.set_override(item, {"price": {"coins": mine}})
	check(App.prices.save_overrides() == OK, "QA9: the override is saved")
	await _frames(2)
	check(uids.size() == 2 and _qa_coins(w.last_totals) == 2 * mine, "QA9: the chip follows the override live (%d → %d coins)" % [c0, _qa_coins(w.last_totals)])
	var restarted := PriceBook.load_default(App.db, App.prices.overrides_path)
	check(restarted.has_override(item) and int((restarted.copy_price(item, 1) as Dictionary).get("coins", 0)) == mine, "QA9: …and survives a restart")
	App.prices.remove_override(item)
	App.prices.save_overrides()
	await _frames(2)
	check(_qa_coins(w.last_totals) == c0 and Currency.equal(App.prices.copy_price(item, 1), researched), "QA9: removing it restores the researched value")
	check(not PriceBook.load_default(App.db, App.prices.overrides_path).has_override(item), "QA9: …also after a restart")
	ctx.set_scope_pin("auto")


# Known gaps: Ctrl+A and hidden layers, issue marks / heatmap on hidden objects, View tab at 200 % --

func _qa_layers_and_scale() -> void:
	print("QA: object layers and UI scale")
	var ctx: PlanContext = App.plan_ctx
	var s: EditorSession = await _qa_open("QA layers")
	var blk := _free_block(Vector2i(6, 5))
	var bench: int = _qa_line(s, "bench", blk + Vector2i.ONE, 1)[0]
	var fence: int = _qa_line(s, "fence", blk + Vector2i(1, 3), 1)[0]
	s.execute(EditCommands.AddObjects.new([s.make_object(App.db.get_item("bench"), blk + Vector2i.ONE)]))   # an overlap: issue mark
	await _frames(2)
	main._refresh_issues()
	ctx.set_layer("heatmap", true)
	check(bench in main.overlay.shown_issue_uids() and bench in main.plan_overlay.heat_drawn_uids(), "QA: the bench has an issue mark and a heatmap tile while shown")
	main.set_object_layer("decorations", ObjectLayers.HIDE)
	await _frames(2)
	var hidden: bool = main.renderer.is_layer_hidden(bench)
	_key(KEY_A, true)
	check(hidden and not bench in s.selection and fence in s.selection, "QA: Ctrl+A leaves out objects hidden by an object layer")
	check(not bench in main.overlay.shown_issue_uids(), "QA: no issue outline on a hidden object")
	var drawn: Array = main.plan_overlay.heat_drawn_uids()
	check(not bench in drawn and fence in drawn, "QA: no heatmap tile on a hidden object (bench %d, fence %d, drawn %s)" % [bench, fence, str(drawn)])
	main.set_object_layer("decorations", ObjectLayers.SHOW)
	await _frames(1)
	_key(KEY_A, true)
	check(bench in s.selection, "QA: shown again, Ctrl+A takes it")
	ctx.set_layer("heatmap", false)
	s.clear_selection()
	# The View tab's Object layers section at 200 %: below the fold is fine if it scrolls there.
	App.settings.set_v("ui_scale", 2.0, false)
	await main._rebuild_ui()
	await _frames(3)
	main.set_plan_open(false)
	main.inspector.visible = true
	main.inspector.show_tab(2)
	main.inspector.rebuild()
	await _frames(3)
	var sc: ScrollContainer = main.inspector._scroll
	var sec := _qa_find_label(sc, "Object layers")
	check(sec != null, "QA: the View tab has the Object layers section at 200 %")
	if sec != null:
		var below := not sc.get_global_rect().encloses(sec.get_global_rect())
		sc.ensure_control_visible(sec)
		await _frames(2)
		var vis := sc.get_global_rect().grow(1.0).encloses(sec.get_global_rect())
		check(vis, "QA: the View tab scrolls to Object layers at 200 %% (below the fold at first: %s; scroll %d of %d)" % [str(below), sc.scroll_vertical, int(sc.get_v_scroll_bar().max_value)])
	App.settings.set_v("ui_scale", 0.0, false)
	await main._rebuild_ui()
	await _frames(2)
