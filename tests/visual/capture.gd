extends Node
## Visual test driver: attached by main.gd when the app is started with
## `-- --capture`. Screenshots scripted states of the REAL app. Needs a real
## renderer (Xvfb + OpenGL), NOT --headless. See tools/ci/visual_tests.sh:
##   xvfb-run -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 -- \
##     --capture --out=artifacts/screens --scale=1 --scenarios=all
## Each scenario prints "SHOT <file>"; failures print "FAIL".
## Extra options for checking a user's installed (private) pack:
##   --open=<layout>   open that layout instead of the showcase (main.gd)
##   --real-art        asset scenarios use the installed packs, no synthetic pack
##   scenario at_<x>_<y>_<zoom>   centre on tile (x, y) at that zoom (e.g. at_30_9_2.5)
##   scenario export2x            full-farm export at 2x
##   --outline-all                at_* scenarios select every object (footprint outlines)
##   --dump-objects               write <shot>.objects.json (screen footprints/bounds, no pixels)
##   --hide-panels                hide the top bar and side panels
##   scenario export_objects      export of the objects' bounding box at 1x
##   --select-items=a+b+c         items the "selection" scenario selects (default field+apple_tree)
## Screens of a private pack must go to the private root (--out=...), never artifacts/.

const ALL := ["overview", "place_valid", "place_invalid", "selection", "search", "realistic", "land", "zoomed",
	"gallery", "help", "settings", "welcome", "reference", "compare", "export", "light",
	"asset_manager", "asset_review", "asset_packs", "original_art", "asset_empty", "landmarks", "migration",
	"drag_blocked", "tools_symmetry", "tools_repeat", "winter"]
## Not part of "all": only meaningful with a real pack / --open layout.
const EXTRA := ["export2x", "export_objects", "at_<x>_<y>_<zoom>", "anim_perf"]
## Asset scenarios install a synthetic pack generated from the built-in
## placeholders (never real artwork); it is removed again before the next scenario.
const SyntheticPack := preload("res://tests/fixtures/synthetic_pack.gd")

var out_dir := "res://artifacts/screens"
var scale := 1.0
var scenarios: Array = []
var main: Node
var tag := ""
var _pack_installed := false
var real_art := false
var outline_all := false   ## at_* scenarios select everything, so every footprint is outlined
var hide_panels := false   ## hide top bar + side panels (Tab) for unobstructed QA shots
var dump_objects := false  ## write <shot>.objects.json: id, footprint corners + sprite bounds in screen px
var select_items: Array = ["field", "apple_tree"]   ## "selection" scenario (--select-items=a+b)
var _migration_layout_open := false


func _ready() -> void:
	_apply_window_size_arg()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--scale="):
			scale = float(a.substr(8))
		elif a.begins_with("--scenarios="):
			var s := a.substr(12)
			scenarios = ALL.duplicate() if s == "all" else Array(s.split(","))
		elif a.begins_with("--tag="):
			tag = a.substr(6)
		elif a == "--real-art":
			real_art = true
		elif a == "--outline-all":
			outline_all = true
		elif a == "--dump-objects":
			dump_objects = true
		elif a == "--hide-panels":
			hide_panels = true
		elif a.begins_with("--select-items="):
			select_items = Array(a.substr(15).split("+"))
	if scenarios.is_empty():
		scenarios = ["overview"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir) if out_dir.begins_with("res://") else out_dir)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _app() -> Node:
	return get_tree().root.get_node("App")


func _run() -> void:
	main = get_parent()
	await _frames(20)
	for sc in scenarios:
		await _reset()
		var ok: bool = await _scenario(sc)
		await _frames(12)
		var size := get_viewport().get_visible_rect().size
		var name := "%s%s_%dx%d_s%s_%s.png" % [tag, "", int(DisplayServer.window_get_size().x), int(DisplayServer.window_get_size().y), str(scale).replace(".", ""), sc]
		var img := get_viewport().get_texture().get_image()
		var path := out_dir.path_join(name)
		img.save_png(path)
		if dump_objects:
			_dump_objects(path.get_basename() + ".objects.json", Vector2(img.get_size()) / size)
		print(("SHOT " if ok else "FAIL ") + path + " logical=" + str(size))
		# Share of the window the camera treats as unobstructed canvas.
		var vr: Rect2 = main.camera.view_rect
		print("CANVAS %s share=%.1f%% view=%s" % [sc, 100.0 * vr.get_area() / maxf(1.0, size.x * size.y), str(vr)])
	get_tree().quit(0)


func _apply_window_size_arg() -> void:
	## `--window-size=WxH` (Windows runner): an exact client size, even above the
	## monitor's, in an off-screen window so it stays out of the user's way.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--window-size="):
			var parts: PackedStringArray = a.substr(14).split("x")
			if parts.size() == 2:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
				DisplayServer.window_set_position(Vector2i(-20000, -20000))
				DisplayServer.window_set_size(Vector2i(int(parts[0]), int(parts[1])))


func _reset() -> void:
	for c in main.modal_layer.get_children():
		c.queue_free()
	for c in main.toasts.get_children():
		c.queue_free()
	main.hint_hold_s = 60.0   # slow software rendering: keep the cursor hint for the shot
	if main._hint_panel:
		main._hint_panel.visible = false
	if _pack_installed:
		PackInstaller.uninstall(SyntheticPack.PACK_ID)
		_app().reload_assets()
		_pack_installed = false
	var s = _app().session
	if s and _migration_layout_open:
		# Back to an ordinary farm after the migration scenario.
		_migration_layout_open = false
		_app().library.delete("capture_v1")
		main._open_template("res://data/samples/01_meadow_showcase.hdlayout", "My first farm")
		s = _app().session
	if s:
		main.ground.set_theme(s.layout.theme())
		s.set_mode(FarmLayout.MODE_CREATIVE)
		s.layout.reference = {}
		main._load_reference()
		main.overlay.diff = {}
		main._view_state.erase("diff_summary")
		main._refresh_issues()
		main.camera.smooth = false
		main.controller.cancel()
		main.controller.cancel()
		s.clear_selection()
		s.set_tool("select")
		main.inspector.show_tab(0)   # the auto-hiding inspector starts closed
	if hide_panels and not main._panels_hidden:
		main._panels_hidden = true
		main._update_view_rect()
	await _frames(3)


func _session():
	return _app().session


func _dump_objects(path: String, px_per_logical: Vector2, export_rect := Rect2(), export_scale := 0.0) -> void:
	## Image geometry of every object in view (for annotating QA screenshots
	## outside the app: footprint diamonds, anchors, labels). No image data.
	## With export_rect/export_scale the coordinates are those of an export image.
	var s = _session()
	var exporting := export_scale > 0.0
	var view: Rect2 = Rect2(Vector2.ZERO, export_rect.size * export_scale) if exporting else get_viewport().get_visible_rect()
	var xf := func(w: Vector2) -> Vector2:
		return (w - export_rect.position) * export_scale if exporting else main.camera.world_to_screen(w) * px_per_logical
	var out: Array = []
	for o: PlacedObject in s.layout.objects.values():
		var poly := Iso.footprint_polygon(o.origin, o.size)
		var pts: Array = []
		var inside := false
		for w in poly:
			var p: Vector2 = xf.call(w)
			pts.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
			inside = inside or view.grow(200).has_point(p if exporting else p / px_per_logical)
		if not inside:
			continue
		var c: Vector2 = xf.call(Iso.footprint_center(o.origin, o.size))
		var b: Rect2 = main.renderer.bounds_of(o.uid)
		var b0: Vector2 = xf.call(b.position)
		var b1: Vector2 = xf.call(b.end)
		var spr: AssetLibrary.SpriteInfo = main.renderer.sprite_of(o.uid)
		out.append({"uid": o.uid, "item": o.item_id, "origin": [o.origin.x, o.origin.y], "size": [o.size.x, o.size.y],
			"variant": o.variant, "planned": o.planned, "flipped": o.flipped, "footprint": pts, "center": [snappedf(c.x, 0.1), snappedf(c.y, 0.1)],
			"bounds": [snappedf(b0.x, 0.1), snappedf(b0.y, 0.1), snappedf(b1.x, 0.1), snappedf(b1.y, 0.1)],
			"pack": spr.pack_id if spr else "", "file": spr.path if spr else "", "order": main.renderer.order_of(o.uid)})
	var meta := {"zoom": export_scale if exporting else main.camera.zoom.x, "objects": out}
	if exporting:
		meta["export_rect"] = [export_rect.position.x, export_rect.position.y, export_rect.size.x, export_rect.size.y]
	JsonUtil.write_atomic(path, JsonUtil.stringify(meta, true), false)


func _find_free(item_id: String, near: Vector2i) -> Vector2i:
	var s = _session()
	var it: ItemDef = s.db.get_item(item_id)
	for r in range(0, 30):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var o := near + Vector2i(dx, dy)
				if PlacementRules.check_item(s.layout, s.map, it, o, false).ok:
					return o
	return near


func _ghost_at(item_id: String, origin: Vector2i) -> void:
	var s = _session()
	main._on_item_chosen(item_id)
	var it: ItemDef = s.db.get_item(item_id)
	var t := origin + Vector2i((it.footprint.x - 1) / 2, (it.footprint.y - 1) / 2)
	main.controller._hover_tile = t
	main.controller._update_place_ghost(t)
	var c := Iso.footprint_center(origin, it.footprint)
	main.overlay.cursor_world = c
	main.overlay.refresh()


func _install_synthetic_pack() -> bool:
	if real_art:
		return true   # use whatever packs the user has installed
	var zip := "user://capture_assets/synthetic_pack.zip"
	var b: Dictionary = SyntheticPack.build_zip(zip, _app().assets, _app().db)
	if not b["ok"]:
		print("FAIL synthetic pack: ", b["error"])
		return false
	var r = _app().install_pack(ProjectSettings.globalize_path(zip))
	print("INSTALL ", r.summary())
	_pack_installed = r.ok
	return r.ok


func _asset_manager(item_id: String, tab: int) -> bool:
	if not _install_synthetic_pack():
		return false
	main._fit()
	var am = main._open_asset_manager(item_id)
	await _frames(8)
	if tab == 0:
		am.set_filter("original")
		am.select_item(item_id)
		am.set_view_mode("original" if real_art else "onion")
	else:
		am.show_tab(tab)
	await _frames(20)
	return true


func _focus(sc: String) -> bool:
	## at_<x>_<y>_<zoom>: centre the camera on a tile at a zoom level.
	var parts := sc.split("_")
	if parts.size() != 4 or not parts[1].is_valid_int() or not parts[2].is_valid_int() or not parts[3].is_valid_float():
		return false
	var z := float(parts[3])
	main.camera.smooth = false
	main.camera.set_zoom_level(z)
	main.camera.zoom = Vector2(z, z)
	main.camera.target_zoom = z
	main.camera.center_on(Iso.tile_center(Vector2i(int(parts[1]), int(parts[2]))))
	return true


func _avg_frame_ms(n: int) -> float:
	await _frames(10)
	var t0 := Time.get_ticks_usec()
	await _frames(n)
	return (Time.get_ticks_usec() - t0) / 1000.0 / n


func _anim_perf() -> void:
	## Frame time with 500 animated sprites in view (extra scenario, run on its own).
	var s = _session()
	var it: ItemDef = s.db.get_item("windmill")
	var objs: Array = []
	for i in 500:
		var po := PlacedObject.new()
		po.item_id = "windmill"
		po.origin = Vector2i(1 + i % 25, 1 + i / 25)
		po.size = it.footprint
		objs.append(po)
	s.layout.add_objects(objs, true)
	main.renderer.ensure_sorted()
	main.camera.smooth = false
	main.camera.set_zoom_level(0.55)
	main.camera.zoom = Vector2(0.55, 0.55)
	main.camera.target_zoom = 0.55
	main.camera.center_on(Iso.grid_to_world(Vector2(13, 11)))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var driver := RenderingServer.get_current_rendering_driver_name()
	var method := RenderingServer.get_current_rendering_method()
	var adapter := RenderingServer.get_video_adapter_name()
	main.renderer.set_ambient_mode(ObjectRenderer.Ambient.OFF)
	var off_ms: float = await _avg_frame_ms(240)
	main.renderer.set_ambient_mode(ObjectRenderer.Ambient.REDUCED)
	var red_ms: float = await _avg_frame_ms(240)
	main.renderer.set_ambient_mode(ObjectRenderer.Ambient.FULL)
	var full_ms: float = await _avg_frame_ms(240)
	var st: Dictionary = main.renderer.anim_stats()
	var view: Rect2 = main.renderer.get_canvas_transform().affine_inverse() * main.renderer.get_viewport_rect()
	var t0 := Time.get_ticks_usec()
	for i in 200:
		main.renderer.advance_anim(1.0 / 6.0, view)
	var tick_us := (Time.get_ticks_usec() - t0) / 200.0
	print("PERF anim renderer=%s/%s adapter=%s sprites=%d in_view=%d frame_ms off=%.2f reduced=%.2f full=%.2f script_tick_us=%.1f (every sprite changing frame)" % [
		driver, method, adapter, st["animated"], main.renderer.anim_stats()["ticked"], off_ms, red_ms, full_ms, tick_us])
	for theme_id: String in ["winter", s.layout.theme()]:
		main.ground.set_theme(theme_id)
		await _frames(3)
		print("PERF terrain season=%s redraw_ms=%.2f" % [theme_id, main.ground._terrain.last_draw_usec / 1000.0])
	main.ground.queue_redraw()
	await _frames(3)
	print("PERF ground ownership redraw_ms=%.2f" % (main.ground.last_draw_usec / 1000.0))
	print("PERF terrain build_ms=%.2f" % (main.ground._terrain.last_build_usec / 1000.0))


func _drag_pair() -> Array:
	## [mover, a nearby object to drop it on, the mover's tile that picks it].
	var s = _session()
	var objs: Array = s.layout.objects.values()
	for m: PlacedObject in objs:
		if m.size.x < 2 or m.size.y < 2 or not s.can_move_object(m):
			continue
		var grab := Vector2i(-99999, -99999)
		for y in m.size.y:
			for x in m.size.x:
				var t := m.origin + Vector2i(x, y)
				if main.renderer.pick(Iso.tile_center(t)) == m.uid:
					grab = t
		if grab.x == -99999:
			continue
		for o: PlacedObject in objs:
			if o != m and o.size.x >= 2 and o.size.y >= 2 and (o.origin - m.origin).length() < 14.0:
				return [m, o, grab]
	return []


func _canvas_move(p: Vector2, mask: int) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.button_mask = mask
	main._on_canvas_input(e)


func _canvas_button(p: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	main._on_canvas_input(e)


func _scenario(sc: String) -> bool:
	var s = _session()
	if sc.begins_with("at_"):
		if not _focus(sc):
			return false
		if outline_all:
			s.select(s.layout.objects.keys(), false, false)
		await _frames(25)
		return true
	match sc:
		"asset_manager":
			var ok_0: bool = await _asset_manager("bakery", 0)
			if not ok_0:
				return false
		"asset_review":
			var ok_1: bool = await _asset_manager("bakery", 1)
			if not ok_1:
				return false
		"asset_packs":
			var ok_2: bool = await _asset_manager("bakery", 2)
			if not ok_2:
				return false
		"asset_empty":
			# What a user sees before installing any pack.
			main._fit()
			main._open_asset_manager("bakery")
		"original_art":
			if not _install_synthetic_pack():
				return false
			var target: PlacedObject = null
			for o: PlacedObject in s.layout.objects.values():
				if o.item_id == "bakery" and target == null:
					target = o
			if target == null:
				var it: ItemDef = s.db.get_item("bakery")
				var po := PlacedObject.new()
				po.item_id = "bakery"
				po.origin = _find_free("bakery", Vector2i(24, 24))
				po.size = it.footprint
				s.execute(EditCommands.AddObjects.new([po]))
				target = s.layout.get_obj(s.layout.objects.keys().max())
			main.set_variant([target.uid], "winter")
			s.select([target.uid], false, false)
			main.inspector.show_tab(0)
			main.camera.set_zoom_level(1.3)
			main.camera.smooth = false
			main.camera.zoom = Vector2(1.3, 1.3)
			main.camera.target_zoom = 1.3
			main.camera.center_on(Iso.footprint_center(target.origin, target.size))
		"overview":
			main._fit()
		"place_valid":
			main._fit()
			_ghost_at("bakery", _find_free("bakery", Vector2i(24, 26)))
		"place_invalid":
			main._fit()
			# The farmhouse is a fixed landmark of the world (not an object).
			var fh: Landmark = s.map.landmark("farmhouse")
			_ghost_at("dairy", fh.origin + Vector2i(1, 1) if fh else Vector2i(15, 13))
		"drag_blocked":
			# A live drag held over another object: lift + shadow, red validity
			# tiles under the objects, red blocker outline, one chip per reason.
			var pair: Array = _drag_pair()
			if pair.is_empty():
				return false
			var mover: PlacedObject = pair[0]
			var other: PlacedObject = pair[1]
			main.camera.smooth = false
			main.camera.set_zoom_level(1.6)
			main.camera.center_on(Iso.footprint_center(other.origin, other.size))
			await _frames(3)
			var a: Vector2 = main.camera.world_to_screen(Iso.tile_center(pair[2]))
			var b: Vector2 = main.camera.world_to_screen(Iso.tile_center(pair[2] + other.origin - mover.origin))
			_canvas_move(a, 0)
			_canvas_button(a, true)
			for i in range(1, 11):
				_canvas_move(a.lerp(b, i / 10.0), MOUSE_BUTTON_MASK_LEFT)
		"selection":
			var uids: Array = []
			for o: PlacedObject in s.layout.objects.values():
				if o.item_id in select_items:
					uids.append(o.uid)
			s.select(uids, false, false)
			main.camera.set_zoom_level(1.0)
			if not uids.is_empty():
				var r: Rect2i = s.layout.bounds_of(uids)
				main.camera.center_on(Iso.footprint_center(r.position, r.size))
		"search":
			main.catalog._search.text = "fence"
			main.catalog.refresh()
			await _frames(30)
		"realistic":
			var p: Dictionary = s.layout.profile.duplicate(true)
			p["level"] = 12
			s.execute(EditCommands.SetProfile.new(s.layout.profile, p))
			s.set_mode(FarmLayout.MODE_REALISTIC)
			main.inspector.show_tab(1)
			main._fit()
		"land":
			s.set_tool("land")
			main.ground.highlight_plot = "main_12"
			main.ground.queue_redraw()
			main._fit()
			main.inspector.show_tab(1)
		"zoomed":
			main.camera.set_zoom_level(2.2)
			main.camera.smooth = false
			main.camera.zoom = Vector2(2.2, 2.2)
			main.camera.target_zoom = 2.2
			main.camera.center_on(Iso.grid_to_world(Vector2(5 + 25, 3 + 6)))
		"gallery":
			s.layout.mode = FarmLayout.MODE_CREATIVE
			_app().save_current(true)
			await _frames(5)
			main._gallery()
		"help":
			Dialogs.help(main.modal_layer)
		"settings":
			Dialogs.settings(main.modal_layer, func(_k): pass)
		"welcome":
			Dialogs.welcome(main.modal_layer, func(): pass)
		"reference":
			# A synthetic "screenshot": render the farm, tint it, load as reference.
			var r: Rect2 = Exporter.farm_world_rect(s.map, s.layout, "unlocked")
			var img: Image = await main.exporter.capture(r, 0.5, false)
			img.adjust_bcs(1.1, 0.6, 1.0)
			var tmp := "user://ref_test.png"
			img.save_png(tmp)
			var first: Dictionary = ReferenceLayer.default_image(ReferenceLayer.import_image(ProjectSettings.globalize_path(tmp), "test"), r.get_center() + Vector2(40, 20), r.size.x * 0.98)
			first["opacity"] = 0.6
			first["name"] = "Whole farm"
			var second := first.duplicate()
			second["file"] = ReferenceLayer.import_image(ProjectSettings.globalize_path(tmp), "test2")
			second["name"] = "Farmhouse close-up"
			second["scale"] = float(first["scale"]) * 0.35
			second["opacity"] = 0.85
			s.layout.reference = {"images": [first, second], "above": true}
			main._load_reference()
			main.inspector.show_tab(2)
			main.inspector.rebuild()
			main._fit()
		"compare":
			var lib = _app().library
			var cur: FarmLayout = s.layout
			var copy := LayoutIO.from_dict(LayoutIO.to_dict(cur), s.db)
			copy.id = LayoutLibrary.new_id()
			copy.name = "Older version"
			var uids: Array = copy.objects.keys()
			uids.sort()
			copy.remove_objects(uids.slice(0, 12))
			for u in uids.slice(20, 26):
				var o: PlacedObject = copy.get_obj(u)
				if o and not o.locked:
					copy.move_objects([u], Vector2i(0, -2))
			lib.save(copy, false)
			main._compare_with(copy.id, copy.name)
			main._fit()
		"export":
			var r2: Rect2 = Exporter.farm_world_rect(s.map, s.layout, "land")
			var img2: Image = await main.exporter.capture(r2, 1.0, false)
			if img2 == null:
				return false
			var p2 := out_dir.path_join("%sexport_full_farm_%dx%d.png" % [tag, img2.get_width(), img2.get_height()])
			img2.save_png(p2)
			if dump_objects:
				_dump_objects(p2.get_basename() + ".objects.json", Vector2.ONE, r2, 1.0)
			print("EXPORT %dx%d" % [img2.get_width(), img2.get_height()])
			main._fit()
		"export2x":
			var r3: Rect2 = Exporter.farm_world_rect(s.map, s.layout, "land")
			var img3: Image = await main.exporter.capture(r3, 2.0, false)
			if img3 == null:
				return false
			var p3 := out_dir.path_join("%sexport_full_farm_2x_%dx%d.png" % [tag, img3.get_width(), img3.get_height()])
			img3.save_png(p3)
			if dump_objects:
				_dump_objects(p3.get_basename() + ".objects.json", Vector2.ONE, r3, 2.0)
			print("EXPORT %dx%d" % [img3.get_width(), img3.get_height()])
		"export_objects":
			# Bounding box of the layout's objects at 1x (QA galleries).
			var r4: Rect2 = Exporter.farm_world_rect(s.map, s.layout, "objects")
			var img4: Image = await main.exporter.capture(r4, 1.0, false)
			if img4 == null:
				return false
			var p4 := out_dir.path_join("%sexport_objects_%dx%d.png" % [tag, img4.get_width(), img4.get_height()])
			img4.save_png(p4)
			if dump_objects:
				_dump_objects(p4.get_basename() + ".objects.json", Vector2.ONE, r4, 1.0)
			print("EXPORT %dx%d" % [img4.get_width(), img4.get_height()])
			main._fit()
		"tools_symmetry":
			# Symmetry on: the mirror line and the mirrored ghost of what's being placed.
			var tile := _find_free("fence", Vector2i(10, 22))
			main.camera.smooth = false
			main.camera.set_zoom_level(1.0)
			main.camera.center_on(Iso.footprint_center(tile, Vector2i.ONE))
			s.set_symmetry_kind(LayoutTools.KIND_ACROSS)
			s.set_symmetry_tile(tile + Vector2i(6, 0))
			s.set_symmetry_enabled(true)
			_ghost_at("fence", tile)
			await _frames(3)
		"tools_repeat":
			# Selection tools, repeat preview and the stamps panel.
			var fid := "field"
			var at := _find_free(fid, Vector2i(6, 24))
			var it: ItemDef = s.db.get_item(fid)
			var objs: Array = [s.make_object(it, at), s.make_object(it, at + Vector2i(it.footprint.x, 0))]
			var uids: Array = s.place_objects(objs, "Two")
			main.camera.smooth = false
			main.camera.set_zoom_level(1.0)
			main.camera.center_on(Iso.footprint_center(at, Vector2i.ONE))
			s.select(uids, false, false)
			main.layout_tools.set_repeat_params({"cols": 3, "rows": 2, "gap": Vector2i(1, 1)})
			main.dock.tool_action.emit("repeat", true)
			main.layout_tools.save_selection_stamp("Corner fields")
			main.dock.tool_action.emit("stamps", true)
			main.dock.set_stamps_open(true)
			await _frames(3)
		"landmarks":
			# A fixed landmark selected: its card in the inspector, the hover /
			# selection marks and the "fixed in place" hint near the cursor.
			# Public build: approximate positions + placeholder art only.
			var lm: Landmark = s.map.landmark("farmhouse")
			if lm == null:
				return false
			main.camera.smooth = false
			main.camera.set_zoom_level(1.25)
			main.camera.zoom = Vector2(1.25, 1.25)
			main.camera.target_zoom = 1.25
			main.focus_landmark("farmhouse")
			main.inspector.show_tab(0)
			main.inspector.rebuild()
			await _frames(4)
			if s.map.landmark("roadside_shop"):
				main._on_landmark_hovered("roadside_shop")
				main._update_landmark_overlay()
			var p: Vector2 = main.camera.world_to_screen(Iso.footprint_center(lm.origin, lm.footprint))
			main.show_fixed_hint(s.explain_fixed("farmhouse", "drag"), p)
		"migration":
			# A synthetic schema-1 layout (made-up positions, public item ids)
			# opened the way a file is opened: the load-report dialog.
			var v1 := {"format": LayoutIO.FORMAT, "schema_version": 1, "app_version": "0.1.0",
				"meta": {"id": "capture_v1", "name": "My old farm", "mode": "creative"},
				"map": {"id": "hayday_farm_h1", "unlocked_plots": ["main_01"]},
				"objects": [
					{"uid": 1, "item": "farmhouse", "x": 19, "y": 15, "w": 4, "h": 4, "locked": true, "note": LayoutIO.V1_STARTER_NOTE},
					{"uid": 2, "item": "barn", "x": 9, "y": 7, "w": 4, "h": 4, "locked": true, "note": LayoutIO.V1_STARTER_NOTE},
					{"uid": 3, "item": "truck_and_order_board", "x": 18, "y": 31, "w": 4, "h": 3, "locked": true, "note": LayoutIO.V1_STARTER_NOTE},
					{"uid": 4, "item": "roadside_shop", "x": 24, "y": 31, "w": 3, "h": 3, "locked": true, "note": LayoutIO.V1_STARTER_NOTE},
					{"uid": 5, "item": "mailbox", "x": 23, "y": 15, "w": 1, "h": 1},
					{"uid": 6, "item": "bakery", "x": 12, "y": 22, "w": 3, "h": 3},
					{"uid": 7, "item": "bakery", "x": 30, "y": 36, "w": 3, "h": 3},
					{"uid": 8, "item": "apple_tree", "x": 60, "y": 20, "w": 1, "h": 1}],
				"camera": {"x": 0.0, "y": 0.0, "zoom": 1.0}}
			# Saved as a library file, so the report also names the backup that
			# the first save keeps (isolated data folder).
			JsonUtil.write_atomic(_app().library.path_for("capture_v1"), JSON.stringify(v1, "\t"), false)
			var rep := LayoutIO.LoadReport.new()
			var l: FarmLayout = _app().library.load_layout("capture_v1", rep)
			if l == null:
				return false
			main._suppress_open_toast = true   # as in the app: the dialog replaces the toast
			_app().open_layout(l, rep)
			_migration_layout_open = true
			main._fit()
			await _frames(4)
			if main.show_load_report(rep) == null:
				return false
		"winter":
			main.ground.set_theme("winter")
			main._fit()
		"anim_perf":
			await _anim_perf()
		"light":
			_app().settings.set_v("theme", "light", false)
			await main._rebuild_ui()
			await _frames(10)
			main._fit()
			_ghost_at("feed_mill", _find_free("feed_mill", Vector2i(30, 26)))
		_:
			return false
	await _frames(25)
	return true
