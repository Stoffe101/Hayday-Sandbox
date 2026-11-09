extends Node
## Visual test driver: attached by main.gd when the app is started with
## `-- --capture`. Screenshots scripted states of the REAL app. Needs a real
## renderer (Xvfb + OpenGL), NOT --headless. See tools/ci/visual_tests.sh:
##   xvfb-run -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 -- \
##     --capture --out=artifacts/screens --scale=1 --scenarios=all
## Each scenario prints "SHOT <file>"; failures print "FAIL".

const ALL := ["overview", "place_valid", "place_invalid", "selection", "search", "realistic", "land", "zoomed",
	"gallery", "help", "settings", "welcome", "reference", "compare", "export", "light"]

var out_dir := "res://artifacts/screens"
var scale := 1.0
var scenarios: Array = []
var main: Node
var tag := ""


func _ready() -> void:
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
		print(("SHOT " if ok else "FAIL ") + path + " logical=" + str(size))
	get_tree().quit(0)


func _reset() -> void:
	for c in main.modal_layer.get_children():
		c.queue_free()
	var s = _app().session
	if s:
		s.layout.mode = FarmLayout.MODE_CREATIVE
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
	await _frames(3)


func _session():
	return _app().session


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


func _scenario(sc: String) -> bool:
	var s = _session()
	match sc:
		"overview":
			main._fit()
		"place_valid":
			main._fit()
			_ghost_at("bakery", _find_free("bakery", Vector2i(24, 26)))
		"place_invalid":
			main._fit()
			var fh: PlacedObject = null
			for o: PlacedObject in s.layout.objects.values():
				if o.item_id == "farmhouse":
					fh = o
			_ghost_at("dairy", fh.origin + Vector2i(1, 1) if fh else Vector2i(20, 15))
		"selection":
			var uids: Array = []
			for o: PlacedObject in s.layout.objects.values():
				if o.item_id == "field" or o.item_id == "apple_tree":
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
			s.layout.reference = main.reference.default_settings(ReferenceLayer.import_image(ProjectSettings.globalize_path(tmp), "test"), r.get_center() + Vector2(40, 20), r.size.x * 0.98)
			s.layout.reference["opacity"] = 0.6
			s.layout.reference["above"] = true
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
			img2.save_png(out_dir.path_join("%sexport_full_farm_%dx%d.png" % [tag, img2.get_width(), img2.get_height()]))
			print("EXPORT %dx%d" % [img2.get_width(), img2.get_height()])
			main._fit()
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
