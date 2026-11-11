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
##   --with-look                  include the layout's farmhouse / truck / shop look in the budget (SkinBudget)
##   scenario export_objects      export of the objects' bounding box at 1x
##   --select-items=a+b+c         items the "selection" scenario selects (default field+apple_tree)
## Screens of a private pack must go to the private root (--out=...), never artifacts/.

const ALL := ["overview", "place_valid", "place_invalid", "selection", "search", "realistic", "land", "zoomed",
	"gallery", "help", "settings", "welcome", "reference", "compare", "export", "light",
	"asset_manager", "asset_review", "asset_packs", "original_art", "asset_empty", "landmarks", "migration",
	"drag_blocked", "tools_symmetry", "tools_repeat", "winter", "terrain_pack", "terrain_pack_winter", "terrain_pack_river",
	"terrain_pack_fg", "terrain_pack_blend", "terrain_pack_zoomout",
	"plan_budget", "plan_areas", "plan_phases", "plan_heatmap", "plan_shop", "plan_build", "plan_guide", "plan_accuracy",
	"plan_minimap", "plan_layers", "plan_compare", "plan_ready", "game_data", "game_data_review", "object_glow",
	"tile_drag", "tile_select", "budget_breakdown"]
## Not part of "all": only meaningful with a real pack / --open layout.
const EXTRA := ["export2x", "export_objects", "at_<x>_<y>_<zoom>", "anim_perf", "wz_<item id>", "anim_farm_perf",
	"camera_perf", "drag_perf", "ghost_art", "fence_junctions"]
## Asset scenarios install a synthetic pack generated from the built-in
## placeholders (never real artwork); it is removed again before the next scenario.
const SyntheticPack := preload("res://tests/fixtures/synthetic_pack.gd")
## terrain_pack* scenarios install a generated terrain pack (flat colours and
## patterns, docs/TERRAIN_PACKS.md), removed again before the next scenario.
const SynTerrain := preload("res://tests/fixtures/synthetic_terrain.gd")
## object_glow installs a procedural pack with glow layers and patch animations (removed by the next _reset).
const SynGlow := preload("res://tests/fixtures/synthetic_glow_pack.gd")

var out_dir := "res://artifacts/screens"
var scale := 1.0
var scenarios: Array = []
var main: Node
var tag := ""
var _pack_installed := false
var _terrain_installed := false
var _client_installed := false
var _glow_installed := false
var real_art := false
var outline_all := false   ## at_* scenarios select everything, so every footprint is outlined
var hide_panels := false   ## hide top bar + side panels (Tab) for unobstructed QA shots
var with_look := false     ## --with-look: every scenario includes the farm's look (design customization) in the budget
var dump_objects := false  ## write <shot>.objects.json: id, footprint corners + sprite bounds in screen px
var select_items: Array = ["field", "apple_tree"]   ## "selection" scenario (--select-items=a+b)
var _migration_layout_open := false
var _profile0: Variant = null       ## the showcase's profile before any plan scenario changed it
var _undo_after := 0                ## layout edits a scenario made, undone by the next _reset


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
		elif a == "--with-look":
			with_look = true
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
	# The "light" scenario switches the theme; every later scenario starts from the default.
	if str(_app().settings.get_v("theme")) != str(AppSettings.DEFAULTS["theme"]):
		_app().settings.set_v("theme", AppSettings.DEFAULTS["theme"], false)
		await main._rebuild_ui()
		await _frames(6)
	main.hint_hold_s = 60.0   # slow software rendering: keep the cursor hint for the shot
	if main._hint_panel:
		main._hint_panel.visible = false
	# No real mouse here: the hover-tile outline of the X server's idle pointer (a white 1-tile diamond wherever
	# the start-up camera put it) is not part of any scenario.
	main.overlay.show_hover_tile = false
	# drag_blocked's synthetic pointer leaves its object hovered (white outline in every later shot).
	main.overlay.hover_uid = 0
	main.overlay.ghosts = []   # ghost_art sets ghosts without a gesture
	if _pack_installed:
		PackInstaller.uninstall(SyntheticPack.PACK_ID)
		_app().reload_assets()
		_pack_installed = false
	if _terrain_installed:
		PackInstaller.uninstall(SynTerrain.PACK_ID)
		_app().reload_assets()
		_terrain_installed = false
	if _glow_installed:
		PackInstaller.uninstall(SynGlow.PACK_ID)
		_app().reload_assets()
		_glow_installed = false
	if _client_installed:
		ClientPrices.remove()
		for f in [PriceBook.DEFAULT_CLIENT.get_basename() + ClientPrices.PREVIOUS_SUFFIX, ClientPrices.REPORT_PATH,
				ClientPrices.REPORT_PATH.get_basename() + ".md"]:
			if FileAccess.file_exists(f):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
		_app().reload_client_prices()
		_client_installed = false
	var s = _app().session
	if s and _undo_after > 0:
		# Edits a planning scenario made to the showcase (moved / new / removed objects).
		for i in _undo_after:
			s.stack.undo()
		_undo_after = 0
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
		# Layout tools (tools_symmetry / tools_repeat): no armed stamp, axis pick or
		# repeat preview, symmetry off with its default line, default repeat counts,
		# stamps panel closed.
		var lt: LayoutToolController = main.layout_tools
		lt.cancel()
		lt.set_repeat_params({"cols": 3, "rows": 1, "gap": Vector2i.ZERO})
		s.set_symmetry_enabled(false)
		s.set_symmetry_kind(LayoutTools.KIND_SCREEN)
		lt.panel.visible = false
		main.dock.set_stamps_open(false)
		s.clear_selection()
		s.set_tool("select")
		main.dock.set_status("")   # e.g. "Select something that can be copied"
		main.inspector.show_tab(0)   # the auto-hiding inspector starts closed
		_reset_plan(s)
		if with_look:
			s.layout.set_planning(SkinBudget.with_enabled(s.layout.planning, true))
	if hide_panels and not main._panels_hidden:
		main._panels_hidden = true
		main._update_view_rect()
	await _frames(3)


func _session():
	return _app().session


func _reset_plan(s) -> void:
	## Planning state back to "nothing planned": no areas / phases / marks, the
	## original inventory, the Plan panel closed, the budget chip in its default
	## corner, default mode / scope / layers, no area tool, no highlight.
	if _profile0 == null:
		_profile0 = s.layout.profile.duplicate(true)
	s.layout.profile = (_profile0 as Dictionary).duplicate(true)
	s.layout.set_planning(PlanDoc.empty())
	main.plan_controller.cancel()
	main.set_plan_open(false)
	main.plan_overlay.highlight_uids = []
	var ctx: PlanContext = _app().plan_ctx
	ctx.set_active_area("")
	ctx.set_active_phase("")
	ctx.set_guide_step(-1)
	ctx.set_mode(BudgetEngine.MODE_TO_BUY)
	ctx.set_scope_pin("auto")
	for k in ["areas", "progress", "guide"]:
		ctx.set_layer(k, true)
	ctx.set_layer("heatmap", false)
	ctx.set_compare(false)
	for k in ["budget_corner", "budget_collapsed", "budget_expanded", "budget_visible", "object_layers", "minimap_visible", "minimap_collapsed"]:
		_app().settings.set_v(k, AppSettings.DEFAULTS[k], false)
	main.renderer.set_view_tints({})
	main._compare_key = ""
	main.budget.configure("bl", false, false)
	main._place_budget()


func _plan_layout(with_phases: bool) -> void:
	## A planned showcase: three named areas (the hedge garden as a polygon
	## “Flower Garden”), optionally three phases with one in progress, and a
	## little inventory. Made-up planning data on the public sample; prices come
	## from data/prices as in the app.
	var s = _session()
	var ctx: PlanContext = _app().plan_ctx
	var plan := PlanDoc.empty()
	plan = PlanDoc.with_area(plan, {"name": "Flower Garden", "color": "#e58fb0",
		"points": [[19, 1], [31, 1], [31, 8], [28, 11], [22, 11], [19, 8]], "target": {"coins": 20000}})
	plan = PlanDoc.with_area(plan, {"name": "Orchard", "color": "#8fc46a", "rect": [0, 26, 11, 6]})
	plan = PlanDoc.with_area(plan, {"name": "Animal Yard", "color": "#f2b84b", "rect": [13, 20, 19, 7]})
	if with_phases:
		plan = PlanDoc.with_area(plan, {"name": "Production Row", "color": "#6fb3e0", "rect": [0, 15, 30, 4]})
		plan = PlanDoc.with_phase(plan, {"name": "Farm entrance", "color": "#6fb3e0", "areas": ["a4", "a3"]})
		plan = PlanDoc.with_phase(plan, {"name": "Orchard", "color": "#8fc46a", "areas": ["a2"], "target": {"coins": 3000}})
		plan = PlanDoc.with_phase(plan, {"name": "Flower Garden", "color": "#e58fb0", "areas": ["a1"]})
		var placed: Array = []
		for o: PlacedObject in s.layout.objects.values():
			if o.item_id in ["bakery", "feed_mill", "chicken_coop"]:
				placed.append(o.uid)
		plan = PlanDoc.with_placed(plan, s.layout, placed, true)
	s.execute(EditCommands.SetPlanning.new(s.layout.planning, plan, "Capture plan"))
	var p: Dictionary = s.layout.profile.duplicate(true)
	p["owned"] = {"barn": 1, "silo": 1, "bakery": 1, "feed_mill": 1, "chicken_coop": 1, "field": 20}
	p["balances"] = {"coins": 25000, "diamonds": 40}
	s.execute(EditCommands.SetProfile.new(s.layout.profile, p, "Capture inventory"))
	await _frames(2)
	ctx.notify_changed()


func _plan_tab(tab: String, with_phases: bool = true) -> void:
	await _plan_layout(with_phases)
	main._fit()
	main.open_plan(tab)
	await _frames(4)


func _exec(cmd) -> void:
	## A layout edit made by a scenario: undone again by the next _reset.
	_session().execute(cmd)
	_undo_after += 1


func _movable_offset(o: PlacedObject, tries: Array) -> Vector2i:
	var s = _session()
	for d: Vector2i in tries:
		if PlacementRules.check_group_move(s.layout, s.map, [o.uid], d).ok:
			return d
	return Vector2i.ZERO


func _compare_edits() -> void:
	## The showcase becomes "my real farm" (baseline), then the design changes:
	## a few objects moved, two removed, three new ones. Made-up edits on the public sample.
	var s = _session()
	var ctx: PlanContext = _app().plan_ctx
	var plan: Dictionary = s.layout.planning.duplicate(true)
	plan = PlanDoc.with_baseline(plan, Baseline.snapshot(s.layout, "My farm", "", "2026-11-10T09:00:00Z"))
	_exec(EditCommands.SetPlanning.new(s.layout.planning, plan, "Capture baseline"))
	var objs: Array = s.layout.objects.values()
	objs.sort_custom(func(a: PlacedObject, b: PlacedObject) -> bool: return a.uid < b.uid)
	var moved := 0
	var tries := [Vector2i(0, 3), Vector2i(3, 0), Vector2i(0, -3), Vector2i(-3, 0), Vector2i(2, 2), Vector2i(0, 5), Vector2i(5, 0)]
	for o: PlacedObject in objs:
		if moved >= 3:
			break
		if o.size.x < 2 or o.locked or not s.can_move_object(o):
			continue
		var d := _movable_offset(o, tries)
		if d != Vector2i.ZERO:
			_exec(EditCommands.MoveObjects.new([o.uid], d))
			moved += 1
	var gone: Array = []
	for o: PlacedObject in objs:
		if gone.size() >= 2:
			break
		if o.size == Vector2i.ONE and s.layout.get_obj(o.uid) != null and o.item_id.ends_with("_tree"):
			gone.append(o.uid)
	if not gone.is_empty():
		_exec(EditCommands.RemoveObjects.new(gone, "Capture removal"))
	var added: Array = []
	for e: Array in [["bench", Vector2i(6, 12)], ["windmill", Vector2i(26, 24)], ["apple_tree", Vector2i(2, 24)]]:
		var it: ItemDef = s.db.get_item(e[0])
		if it == null:
			continue
		added.append(s.make_object(it, _find_free(e[0], e[1])))
	if not added.is_empty():
		_exec(EditCommands.AddObjects.new(added))
	await _frames(2)
	ctx.notify_changed()


func _ready_issues() -> void:
	## A few things that block rebuilding: Realistic mode at a low farm level, an
	## overlap, a building on locked land and one copy over the game's limit.
	var s = _session()
	var p: Dictionary = s.layout.profile.duplicate(true)
	p["level"] = 40
	p["owned"] = {"barn": 1, "silo": 1, "bakery": 1, "feed_mill": 1, "chicken_coop": 1, "field": 20}
	_exec(EditCommands.SetProfile.new(s.layout.profile, p, "Capture level"))
	s.set_mode(FarmLayout.MODE_REALISTIC)
	var extra: Array = []
	var bakery: ItemDef = s.db.get_item("bakery")
	var first: PlacedObject = null
	for o: PlacedObject in s.layout.objects.values():
		if o.item_id == "bakery":
			first = o
	if first != null and bakery != null:
		# A second bakery half on top of the first: an overlap and one over the game's limit.
		extra.append(s.make_object(bakery, first.origin + Vector2i(1, 1)))
	var wm: ItemDef = s.db.get_item("windmill")
	if wm != null:
		# On the locked plot nearest the farm.
		var best: Vector2 = Vector2(-1, -1)
		for pl in s.map.plots:
			var c: Variant = pl.get("center")
			if s.map.is_plot_unlocked(str(pl["id"]), s.layout.unlocked_plots) or not c is Vector2 or int(pl.get("tiles", 0)) < 16:
				continue
			if best.x < 0 or (c as Vector2).distance_to(Vector2(16, 16)) < best.distance_to(Vector2(16, 16)):
				best = c
		if best.x >= 0:
			extra.append(s.make_object(wm, Vector2i(best.floor()) - Vector2i(1, 1)))
	if not extra.is_empty():
		_exec(EditCommands.AddObjects.new(extra))
	await _frames(2)
	_app().plan_ctx.notify_changed()


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
	_dump_world_geometry(meta, xf, view, exporting, px_per_logical)
	JsonUtil.write_atomic(path, JsonUtil.stringify(meta, true), false)


func _dump_world_geometry(meta: Dictionary, xf: Callable, view: Rect2, exporting: bool, px_per_logical: Vector2) -> void:
	## Calibration sheets: the tile -> image transform (screen = o + x*ex + y*ey
	## for tile corner (x, y)) and every landmark in view with its footprint,
	## ground centre, sprite bounds and the registration tile its sprite is
	## anchored to (pack field "client_registration"). No image data.
	var o: Vector2 = xf.call(Iso.grid_to_world(Vector2.ZERO))
	var ex: Vector2 = xf.call(Iso.grid_to_world(Vector2(1, 0))) - o
	var ey: Vector2 = xf.call(Iso.grid_to_world(Vector2(0, 1))) - o
	meta["tile_to_image"] = {"o": [snappedf(o.x, 0.01), snappedf(o.y, 0.01)], "ex": [snappedf(ex.x, 0.001), snappedf(ex.y, 0.001)], "ey": [snappedf(ey.x, 0.001), snappedf(ey.y, 0.001)]}
	var s = _session()
	var lms: Array = []
	if s.map != null:
		for lm: Landmark in s.map.landmarks:
			var key := LandmarkView.key_of(lm.id)
			var pts: Array = []
			var inside := false
			for w in Iso.footprint_polygon(lm.origin, lm.footprint):
				var p: Vector2 = xf.call(w)
				pts.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
				inside = inside or view.grow(400).has_point(p if exporting else p / px_per_logical)
			if not inside:
				continue
			var c: Vector2 = xf.call(Iso.footprint_center(lm.origin, lm.footprint))
			var b: Rect2 = main.renderer.world_entry_bounds(key)
			var b0: Vector2 = xf.call(b.position)
			var b1: Vector2 = xf.call(b.end)
			var spr: AssetLibrary.SpriteInfo = main.renderer.world_sprite_of(key)
			var row := {"id": lm.id, "origin": [lm.origin.x, lm.origin.y], "size": [lm.footprint.x, lm.footprint.y],
				"draw_anchor": lm.draw_anchor, "confidence": lm.confidence, "footprint": pts, "center": [snappedf(c.x, 0.1), snappedf(c.y, 0.1)],
				"bounds": [snappedf(b0.x, 0.1), snappedf(b0.y, 0.1), snappedf(b1.x, 0.1), snappedf(b1.y, 0.1)],
				"pack": spr.pack_id if spr else "", "file": spr.path if spr else ""}
			var reg: Variant = lm.extra.get("client_registration", null)
			if reg is Array and (reg as Array).size() == 2:
				var rp: Vector2 = xf.call(Iso.grid_to_world(Vector2(float(reg[0]), float(reg[1]))))
				row["client_registration"] = [int(reg[0]), int(reg[1])]
				row["registration_point"] = [snappedf(rp.x, 0.1), snappedf(rp.y, 0.1)]
			lms.append(row)
	meta["landmarks"] = lms


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


func _free_rect(size: Vector2i, near: Vector2i) -> Vector2i:
	## Origin of a free size area near `near` (x = -9999: none).
	var s = _session()
	for r in range(0, 30):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var o := near + Vector2i(dx, dy)
				if PlacementRules.check_rect(s.layout, s.map, Rect2i(o, size)).ok:
					return o
	return Vector2i(-9999, -9999)


func _ghost_art() -> bool:
	## Placement ghosts show the art the object gets once placed (extra scenario, meant for a real pack): in the
	## winter theme a themed item (left: placed, right: its ghost) and a flipped item with hand-drawn mirror art.
	## Prints "GHOST <item> theme=.. mirror=.. same=true|false" (the ghost's texture vs the placed object's); FAIL
	## if they differ.
	var s = _session()
	var lib: AssetLibrary = _app().assets
	var themed := ""
	var mirrored := ""
	for it: ItemDef in s.db.ordered:
		if it.footprint == Vector2i.ZERO or s.item_block_reason(it.id) != "":
			continue
		if themed.is_empty() and not lib.themed_variant(it.art_key, "", "winter").is_empty():
			themed = it.id
		if mirrored.is_empty() and it.flippable:
			var spr: AssetLibrary.SpriteInfo = lib.get_sprite(it.art_key, "", -1)
			if spr and spr.mirror:
				mirrored = it.id
	if themed.is_empty():
		themed = "big_pine_tree"
	if mirrored.is_empty():
		mirrored = "bench"
	s.execute(SetWorldStateCommand.for_theme(s.layout, "winter"))
	_undo_after += 1
	await _frames(4)
	var ok := true
	var near := Vector2i(24, 26)
	var ghosts: Array = []
	var focus: Array = []
	for pair: Array in [[themed, false], [mirrored, true]]:
		var it: ItemDef = s.db.get_item(pair[0])
		if it == null:
			print("GHOST %s: not in the catalogue" % pair[0])
			continue
		var fl: bool = pair[1] and it.flippable
		var sz := it.size_for(fl)
		var o := _free_rect(Vector2i(sz.x * 2 + 1, sz.y), near)
		if o.x == -9999:
			print("FAIL ghost_art: no room for ", it.id)
			return false
		var po: PlacedObject = s.make_object(it, o)
		po.flipped = fl
		po.size = sz
		po.variant = ""
		var uids: Array = s.place_objects([po], "capture ghost_art")
		_undo_after += 1
		if uids.is_empty():
			print("FAIL ghost_art: %s refused" % it.id)
			return false
		ghosts.append({"item": it, "origin": o + Vector2i(sz.x + 1, 0), "flipped": fl, "variant": ""})
		focus.append(Iso.footprint_center(o + Vector2i(sz.x, 0), sz))
		var placed: AssetLibrary.SpriteInfo = main.renderer.sprite_of(uids[0])
		var pv: Dictionary = UI.resolve_sprite(lib, it, "", fl, s.layout.theme())
		var same: bool = placed != null and pv["texture"] == placed.texture
		ok = ok and same
		print("GHOST %s theme=%s mirror=%s flipped_draw=%s same=%s" % [it.id, lib.themed_variant(it.art_key, "", s.layout.theme()),
			str(lib.get_sprite(it.art_key, "", -1) != null and lib.get_sprite(it.art_key, "", -1).mirror != null), str(pv["flip"]), str(same)])
		near = o + Vector2i(0, sz.y + 3)
	main.overlay.ghosts = ghosts
	main.overlay.ghost_result = null
	main.camera.smooth = false
	main.camera.set_zoom_level(2.0)
	main.camera.zoom = Vector2(2.0, 2.0)
	main.camera.target_zoom = 2.0
	var mid := Vector2.ZERO
	for f: Vector2 in focus:
		mid += f / maxf(1.0, focus.size())
	main.camera.center_on(mid)
	main.overlay.refresh()
	await _frames(8)
	if not ok:
		print("FAIL ghost_art: a ghost shows other art than the placed object")
	return ok


func _fence_junctions() -> bool:
	## Fence, hedge and cobblestone path pieces in a cross and a T (extra scenario): how the connection art joins
	## where three or four pieces meet. Each piece draws its own +x / +y links, so a junction is the corner piece
	## plus its neighbours' links; nothing else is assumed.
	var s = _session()
	var near := Vector2i(26, 24)
	var centres: Array = []
	for item_id: String in ["fence", "hedge", "cobblestone_path"]:
		var it: ItemDef = s.db.get_item(item_id)
		if it == null:
			continue
		var o := _free_rect(Vector2i(11, 5), near)
		if o.x == -9999:
			print("FAIL fence_junctions: no room for ", item_id)
			return false
		var tiles: Array = []
		var c := o + Vector2i(2, 2)
		for d: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(2, 0), Vector2i(-1, 0), Vector2i(-2, 0), Vector2i(0, 1), Vector2i(0, 2), Vector2i(0, -1), Vector2i(0, -2)]:
			tiles.append(c + d)   # cross
		var t := o + Vector2i(8, 1)
		for d: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(2, 0), Vector2i(-1, 0), Vector2i(-2, 0), Vector2i(0, 1), Vector2i(0, 2)]:
			tiles.append(t + d)   # T
		var objs: Array = []
		for tt: Vector2i in tiles:
			objs.append(s.make_object(it, tt))
		var uids: Array = s.place_objects(objs, "capture fence_junctions")
		_undo_after += 1
		print("JUNCTION %s at %s placed=%d of %d" % [item_id, str(o), uids.size(), objs.size()])
		for p: Vector2 in Iso.footprint_polygon(o, Vector2i(11, 5)):
			centres.append(p)
		near = o + Vector2i(0, 6)
	if centres.is_empty():
		return false
	var box := Rect2(centres[0], Vector2.ZERO)
	for c: Vector2 in centres:
		box = box.expand(c)
	main.camera.smooth = false
	main._update_view_rect()
	main.camera.fit_world_rect(box.grow_individual(0, 120, 0, 0), 30.0)
	await _frames(8)
	return true


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


func _install_terrain_pack() -> bool:
	if real_art:
		return true   # whatever terrain the installed packs bring
	var zip := "user://capture_assets/synthetic_terrain.zip"
	var b: Dictionary = SynTerrain.build_zip(zip, _session().map)
	if not b["ok"]:
		print("FAIL synthetic terrain: ", b["error"])
		return false
	var r = _app().install_pack(ProjectSettings.globalize_path(zip))
	print("INSTALL ", r.summary())
	_terrain_installed = r.ok
	return r.ok


func _terrain_pack(theme_id: String, zoom: float, at: Vector2) -> bool:
	## Frame time over the same view without and with the pack, its build
	## times, then the shot (pack terrain, the given theme and view).
	if zoom > 0.0:
		main.camera.set_zoom_level(zoom)
		main.camera.zoom = Vector2(zoom, zoom)
		main.camera.target_zoom = zoom
		main.camera.center_on(at)
	else:
		main._fit()
	var vsync := DisplayServer.window_get_vsync_mode()
	var max_fps := Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var plain_ms: float = await _avg_frame_ms(120)
	if not _install_terrain_pack():
		return false
	main.ground.set_theme(theme_id)
	await _frames(4)
	var pl: PackTerrainLayer = main.ground.pack_layer()
	var first_ms := [pl.last_tiles_usec / 1000.0, pl.last_pieces_usec / 1000.0]
	var pack_ms: float = await _avg_frame_ms(120)
	# Again, alternating (placeholder art = procedural terrain, then the pack from its caches).
	main.ground.set_assets(main._placeholder_assets())
	var plain2_ms: float = await _avg_frame_ms(120)
	var t0 := Time.get_ticks_usec()
	main.ground.set_assets(_app().assets)
	var reload_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var pack2_ms: float = await _avg_frame_ms(120)
	# An ownership change (every plot unlocked) rebuilds only the tiles.
	var s = _session()
	var all_open := {}
	for pid in s.map.all_plot_ids():
		all_open[pid] = true
	main.ground.setup(s.map, all_open)
	var own_ms := pl.last_tiles_usec / 1000.0
	main.ground.setup(s.map, s.layout.unlocked_plots)
	# Ambient animation Off / Reduced / Full over the same view (animated instances in view).
	var amb := []
	var view: Rect2 = main.world.get_canvas_transform().affine_inverse() * main.get_viewport().get_visible_rect()
	for mode in [ObjectRenderer.Ambient.OFF, ObjectRenderer.Ambient.REDUCED, ObjectRenderer.Ambient.FULL]:
		main.ground.set_ambient_mode(mode)
		var an: PackTerrainLayer._AnimNode = pl.anim_node()
		var r0 := an.redraws
		var ms: float = await _avg_frame_ms(60)
		amb.append("%.2f(%d in view, %d redraws)" % [ms, an.animating_in(view), an.redraws - r0])
	main.ground.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[_app().settings.ambient_animation()])
	# Season switches through every variant of the pack and back (GroundLayer.set_theme: pieces, tiles, coverage).
	var seasons := []
	var tpv: TerrainPack = pl.pack
	for v in (tpv.variants + tpv.variants if tpv else []) + [theme_id]:
		var t0s := Time.get_ticks_usec()
		main.ground.set_theme(v)
		seasons.append("%s=%.1f" % [v if not str(v).is_empty() else "-", (Time.get_ticks_usec() - t0s) / 1000.0])
	DisplayServer.window_set_vsync_mode(vsync)
	Engine.max_fps = max_fps
	var tp: TerrainPack = pl.pack
	print("TERRAIN_PACK %s active=%s variant=%s backdrop=%s tiles=%d batches=%d pieces=%d foreground=%d blended=%d failed=%d vertices=%d anims=%d clips=%d first_build_ms tiles=%.2f pieces=%.2f cached_rebuild_ms=%.2f ownership_tiles_ms=%.2f frame_ms procedural=%.2f/%.2f pack=%.2f/%.2f ambient_ms off/reduced/full=%s season_switch_ms %s problems=%s" % [
		theme_id, str(pl.active()), pl.variant, str(pl.backdrop_ok), pl.stats["tiles"], pl.stats["tile_batches"], pl.stats["pieces"],
		pl.stats["foreground"], pl.stats["blended"], pl.failed_pieces, pl.stats["vertices"], pl.stats["anims"], pl.stats["clips"],
		first_ms[0], first_ms[1], reload_ms, own_ms, plain_ms, plain2_ms, pack_ms, pack2_ms, " / ".join(amb), " ".join(seasons), str(tp.diagnostics()) if tp else "[]"])
	return pl.active() or real_art


func _terrain_fx(which: String) -> bool:
	## Pack terrain features over the objects: the foreground layer (picking
	## must still find the object under it) or the blend modes. Prints a
	## TERRAIN_FX line; FAIL when a check does not hold.
	if not _install_terrain_pack():
		return false
	var s = _session()
	main.ground.set_theme("")
	await _frames(4)
	var pl: PackTerrainLayer = main.ground.pack_layer()
	var fg: Node2D = pl.foreground
	var ok: bool = fg.get_parent() == main.world and fg.get_index() == main.renderer.get_index() + 1
	var at := Vector2.ZERO
	var zoom := 1.2
	var picked := "-"
	if which == "fg":
		var canopy := Vector2.ZERO
		for p in pl.pack.pieces_for(pl.variant):
			if p["id"] == "canopy":
				canopy = p["at"]
		# A bakery whose south corner is the canopy's trunk: the leaves cover it.
		var it: ItemDef = s.db.get_item("bakery")
		var origin := Vector2i(Iso.world_to_grid(canopy).round()) - it.footprint
		var under: Array = s.layout.uids_in_rect(Rect2i(origin, it.footprint))
		if not under.is_empty():
			_exec(EditCommands.RemoveObjects.new(under, "Capture removal"))
		var po: PlacedObject = s.make_object(it, origin)
		_exec(EditCommands.AddObjects.new([po]))
		await _frames(2)
		var c := Iso.footprint_center(po.origin, po.size)
		var hit: Dictionary = main.controller.pick_at(c)
		picked = "%s:%d at %s" % [hit.get("kind", ""), int(hit.get("uid", 0)), str(po.origin)]
		ok = ok and s.layout.get_obj(po.uid) != null and str(hit.get("kind", "")) == "object" and int(hit.get("uid", 0)) == po.uid
		at = canopy + Vector2(0, -70)
		zoom = 1.6
	elif which == "zoomout":
		main.camera.smooth = false
		main._apply_world_bounds()
		var cam: FarmCamera = main.camera
		for i in 80:
			cam.wheel_zoom(cam.view_rect.get_center(), -1.0)
		await _frames(6)
		var want: Rect2 = main.world_rect_px(s.map)
		ok = ok and cam.limits == want.grow(FarmCamera.LIMIT_MARGIN) and is_equal_approx(cam.zoom.x, cam.min_zoom)
		ok = ok and (not pl.active() or want.encloses(pl.extent))
		print("TERRAIN_FX zoomout min_zoom=%.3f zoom=%.3f world_rect=%s" % [cam.min_zoom, cam.zoom.x, str(want)])
	else:
		at = Iso.grid_to_world(Vector2(s.map.size.x - 8, s.map.size.y * 0.45))
		zoom = 0.7
		ok = ok and (real_art or pl.stats["blended"] >= 3)   # the real pack has no blended pieces
	main.camera.smooth = false
	if which != "zoomout":
		main.camera.set_zoom_level(zoom)
		main.camera.zoom = Vector2(zoom, zoom)
		main.camera.target_zoom = zoom
		main.camera.center_on(at)
	await _frames(6)
	print("TERRAIN_FX %s ok=%s foreground=%d blended=%d fg_index=%d renderer_index=%d picked=%s extent=%s camera_limits=%s" % [
		which, str(ok), pl.stats["foreground"], pl.stats["blended"], fg.get_index(), main.renderer.get_index(), picked,
		str(pl.extent), str(main.camera.limits)])
	if not ok:
		print("FAIL terrain_pack_%s: a foreground / blend check did not hold" % which)
	return ok


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


func _water_zone_shot(item_id: String) -> bool:
	## wz_<item id> (private pack + world with water_deco_zones): one copy placed
	## inside the first zone through the command stack (must be accepted), then the
	## same item armed one tile outside the zone (must be refused, zones shown).
	## Prints "WZ <item> in=... out=..."; FAIL unless both answers are right.
	var s = _session()
	var it: ItemDef = s.db.get_item(item_id)
	if it == null or not PlacementRules.is_zone_item(it) or not s.map.has_water_deco_zones():
		print("WZ %s: not a water decoration or no zones in this world" % item_id)
		return false
	var zr: Rect2i = s.map.water_deco_zone_rects()[0]
	var inside := zr.position
	var in_res := PlacementRules.check_item(s.layout, s.map, it, inside, false)
	var o := PlacedObject.new()
	o.item_id = it.id
	o.origin = inside
	o.size = it.footprint
	_exec(EditCommands.AddObjects.new([o]))
	var placed: bool = s.layout.objects.has(o.uid) and not s.conflicts().has(o.uid)
	var outside := Vector2i(zr.end.x, zr.position.y + mini(2, zr.size.y - 1))
	var out_res := PlacementRules.check_item(s.layout, s.map, it, outside, false)
	main.camera.smooth = false
	main.camera.set_zoom_level(0.9)
	main.camera.zoom = Vector2(0.9, 0.9)
	main.camera.target_zoom = 0.9
	main.camera.center_on(Iso.tile_center(zr.position + Vector2i(zr.size.x, zr.size.y / 2)))
	_ghost_at(item_id, outside)
	await _frames(20)
	print("WZ %s in=%s placed=%s out=%s (%s)" % [item_id, str(in_res.ok), str(placed), "refused" if not out_res.ok else "ACCEPTED",
		" · ".join(out_res.reasons(s.layout, s.db, s.map))])
	return in_res.ok and placed and not out_res.ok and out_res.reason_counts.has(PlacementRules.WATER_DECO_ZONE)


func _avg_frame_ms(n: int) -> float:
	await _frames(10)
	var t0 := Time.get_ticks_usec()
	await _frames(n)
	return (Time.get_ticks_usec() - t0) / 1000.0 / n


func _object_glow() -> bool:
	## Glow layers (additive) and patch animations of a procedural pack: torches (glow + flickering flame with glow
	## frames), windmills (sails at 2/3 resolution) and lanterns (glow only), placed through the command stack.
	## Checks: the sprites load with their glow / rect animation, glows sit on additive child items, a patch plays
	## once in view, Off shows the static image. Prints "GLOW ..."; FAIL when a check does not hold.
	if real_art:
		print("GLOW skipped with --real-art (the scenario needs its own procedural pack)")
		return true
	var b: Dictionary = SynGlow.build_zip("user://capture_assets/synthetic_glow.zip")
	if not b["ok"]:
		print("FAIL glow pack: ", b["error"])
		return false
	var r = _app().install_pack(ProjectSettings.globalize_path("user://capture_assets/synthetic_glow.zip"))
	_glow_installed = r.ok
	if not r.ok:
		print("FAIL glow pack install: ", r.summary())
		return false
	main.renderer.refresh_all_art()
	var s = _session()
	var want := ["garden_torch", "windmill", "lantern", "garden_torch", "windmill", "lantern"]
	var spot := Vector2i(-1, -1)
	for y in range(2, 30):
		for x in range(2, 28):
			var free := true
			for k in want.size():
				var it: ItemDef = s.db.get_item(want[k])
				if not PlacementRules.check_item(s.layout, s.map, it, Vector2i(x + k % 3 * 2, y + k / 3 * 2), false).ok:
					free = false
					break
			if free:
				spot = Vector2i(x, y)
				break
		if spot.x >= 0:
			break
	if spot.x < 0:
		print("FAIL glow: no free 6x4 spot")
		return false
	var objs: Array = []
	for k in want.size():
		var it: ItemDef = s.db.get_item(want[k])
		var o := PlacedObject.new()
		o.item_id = it.id
		o.origin = spot + Vector2i(k % 3 * 2, k / 3 * 2)
		o.size = it.footprint
		objs.append(o)
	_exec(EditCommands.AddObjects.new(objs))
	main.renderer.ensure_sorted()
	main.camera.smooth = false
	main.camera.set_zoom_level(2.2)
	main.camera.zoom = Vector2(2.2, 2.2)
	main.camera.target_zoom = 2.2
	main.camera.center_on(Iso.grid_to_world(Vector2(spot) + Vector2(3.0, 2.0)))
	main.renderer.set_ambient_mode(ObjectRenderer.Ambient.FULL)
	await _frames(12)
	var torch: PlacedObject = objs[0]
	var mill: PlacedObject = objs[1]
	var lamp: PlacedObject = objs[2]
	var ts: AssetLibrary.SpriteInfo = main.renderer.sprite_of(torch.uid)
	var ms: AssetLibrary.SpriteInfo = main.renderer.sprite_of(mill.uid)
	var ls: AssetLibrary.SpriteInfo = main.renderer.sprite_of(lamp.uid)
	var checks := {
		"torch glow + rect anim with glow frames": ts != null and ts.pack_id == SynGlow.PACK_ID and ts.glow != null and ts.anim != null and ts.anim.has_rect() and ts.anim.has_glow,
		"windmill rect anim": ms != null and ms.anim != null and ms.anim.has_rect() and ms.glow == null,
		"lantern glow only": ls != null and ls.glow != null and ls.anim == null,
		"glow on an additive child item": (main.renderer._vis[lamp.uid] as ObjectRenderer.Vis).gci.is_valid() and main.renderer._add_mat != null,
		"no glow child without glow art": not (main.renderer._vis[mill.uid] as ObjectRenderer.Vis).gci.is_valid(),
		"patches play in view": main.renderer.anim_frame_of(mill.uid) >= 0 and main.renderer.anim_frame_of(torch.uid) >= 0,
	}
	main.renderer.set_ambient_mode(ObjectRenderer.Ambient.OFF)
	checks["Off shows the static image"] = main.renderer.anim_frame_of(mill.uid) == -1
	main.renderer.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[_app().settings.ambient_animation()])
	# A placement ghost of the lantern shows its glow too (additive child of the overlay).
	_ghost_at("lantern", spot + Vector2i(6, 1))
	await _frames(4)
	checks["ghost draws the glow"] = not main.overlay._ghost_glows.is_empty() and main.overlay._ghost_glow != null
	var bad: Array = []
	for k: String in checks:
		if not checks[k]:
			bad.append(k)
	print("GLOW pack=%s sprites=%d at=%s checks=%d failed=%s anim_memory=%s" % [SynGlow.PACK_ID, b["sprites"], str(spot), checks.size(),
		str(bad), str(main.renderer.anim_memory())])
	if not bad.is_empty():
		print("FAIL object_glow: ", ", ".join(bad))
		return false
	return true


func _frame_times(n: int) -> Array:
	## Wall time of each of the next n frames (ms), sorted.
	var out: Array = []
	var t := Time.get_ticks_usec()
	for i in n:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		out.append((now - t) / 1000.0)
		t = now
	out.sort()
	return out


func _anim_farm_perf() -> void:
	## Frame time of the open layout (its own objects, landmarks and terrain) with ambient animation Off / Reduced /
	## Full: mean and p95 of 300 frames, at zoom 1 over the farm centre and fitted to the whole farm (extra scenario).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	main.camera.smooth = false
	var views := {"zoom1": [1.0, Vector2i(17, 24)], "fit": [0.0, Vector2i.ZERO]}
	for vname: String in views:
		var v: Array = views[vname]
		if v[0] > 0.0:
			main.camera.set_zoom_level(v[0])
			main.camera.zoom = Vector2(v[0], v[0])
			main.camera.target_zoom = v[0]
			main.camera.center_on(Iso.tile_center(v[1]))
		else:
			main._fit()
		var res: Array = []
		for mode: int in [ObjectRenderer.Ambient.OFF, ObjectRenderer.Ambient.REDUCED, ObjectRenderer.Ambient.FULL]:
			main.renderer.set_ambient_mode(mode)
			await _frames(40)
			var ft: Array = await _frame_times(300)
			var mean := 0.0
			for x: float in ft:
				mean += x
			mean /= ft.size()
			var st: Dictionary = main.renderer.anim_stats()
			res.append("%s mean=%.2f p95=%.2f ticked=%d updates=%d" % [["off", "reduced", "full"][mode], mean, ft[int(ft.size() * 0.95)],
				st["ticked"], st["frame_updates"]])
		var mem: Dictionary = main.renderer.anim_memory()
		print("PERF anim_farm view=%s zoom=%.2f objects=%d animated=%d sheets_loaded=%d sheet_mb=%.1f | %s" % [vname,
			main.camera.zoom.x, _session().layout.objects.size(), main.renderer.anim_stats()["animated"], mem["sheets"], mem["mb"],
			" | ".join(res)])
	main.renderer.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[_app().settings.ambient_animation()])


static func _ft_stats(ft: Array) -> String:
	## "mean=.. p95=.. max=.. n=.." of frame times (ms, any order).
	var srt := ft.duplicate()
	srt.sort()
	var mean := 0.0
	for x: float in srt:
		mean += x
	mean /= maxf(1.0, srt.size())
	return "mean=%.2f p95=%.2f max=%.2f n=%d" % [mean, srt[int(srt.size() * 0.95)] if not srt.is_empty() else 0.0,
		srt.back() if not srt.is_empty() else 0.0, srt.size()]


func _camera_perf() -> void:
	## Camera responsiveness (extra scenario; run it on its own for a cold start): animated flights at zoom 1.6 to
	## five spots of the farm and a zoom-out after each, Ambient animation Full. Every frame is timed until the
	## camera rests; prints mean / p95 / max and the animation sheets loaded on the way (they load on first view).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	main.renderer.set_ambient_mode(ObjectRenderer.Ambient.FULL)
	main._fit()
	await _frames(30)
	var cam: FarmCamera = main.camera
	cam.smooth = true
	var mem0: Dictionary = main.renderer.anim_memory()
	var ft: Array = []
	var worst := ""
	for t: Vector2i in [Vector2i(17, 24), Vector2i(30, 9), Vector2i(5, 20), Vector2i(22, 36), Vector2i(10, 6)]:
		for step in 2:
			if step == 0:
				cam.fly_to(Iso.tile_center(t), 1.6)
			else:
				cam.set_zoom_level(0.75)
			var tt := Time.get_ticks_usec()
			for i in 240:
				await get_tree().process_frame
				var now := Time.get_ticks_usec()
				var ms := (now - tt) / 1000.0
				tt = now
				ft.append(ms)
				if worst.is_empty() or ms > float(worst.split("@")[0]):
					worst = "%.1f@%s/%d" % [ms, str(t), step]
				if not cam.is_animating():
					break
	var mem1: Dictionary = main.renderer.anim_memory()
	print("PERF camera %s worst=%s sheets=%d->%d sheet_mb=%.1f->%.1f" % [_ft_stats(ft), worst, mem0["sheets"], mem1["sheets"],
		mem0["mb"], mem1["mb"]])
	cam.smooth = false
	main.renderer.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[_app().settings.ambient_animation()])


func _drag_perf() -> bool:
	## Drag feel (extra scenario): one object picked up, carried 6 tiles (one pointer move per frame, 36 frames)
	## and dropped, with Ambient animation Off (instant lift and drop) and Full (eased lift, drop and rebound).
	## Prints the frame times while carrying and for the 12 frames after the drop; the move is undone.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var pair: Array = _drag_pair()
	if pair.is_empty():
		print("FAIL drag_perf: no movable object")
		return false
	var mover: PlacedObject = pair[0]
	var grab: Vector2i = pair[2]
	var s = _session()
	main.camera.smooth = false
	main.camera.set_zoom_level(1.0)
	main.camera.center_on(Iso.footprint_center(mover.origin, mover.size))
	await _frames(20)
	for mode: int in [ObjectRenderer.Ambient.OFF, ObjectRenderer.Ambient.FULL]:
		main.renderer.set_ambient_mode(mode)
		await _frames(10)
		var steps0: int = s.stack.size()
		var a: Vector2 = main.camera.world_to_screen(Iso.tile_center(grab))
		var b: Vector2 = main.camera.world_to_screen(Iso.tile_center(grab + Vector2i(6, 0)))
		_canvas_move(a, 0)
		_canvas_button(a, true)
		var carry: Array = []
		var tt := Time.get_ticks_usec()
		for i in range(1, 37):
			_canvas_move(a.lerp(b, i / 36.0), MOUSE_BUTTON_MASK_LEFT)
			await get_tree().process_frame
			var now := Time.get_ticks_usec()
			carry.append((now - tt) / 1000.0)
			tt = now
		var lifted: float = main.renderer.lift_of(mover.uid)
		_canvas_button(b, false)
		var drop: Array = []
		tt = Time.get_ticks_usec()
		var land_frames := 0
		for i in 12:
			await get_tree().process_frame
			var now := Time.get_ticks_usec()
			drop.append((now - tt) / 1000.0)
			tt = now
			if main.renderer.is_moving([mover.uid]):
				land_frames += 1
		var moved: bool = s.stack.size() > steps0
		print("PERF drag ambient=%s lifted=%.1fpx moved=%s carry %s | drop %s landing_frames=%d" % [["off", "reduced", "full"][mode],
			lifted, str(moved), _ft_stats(carry), _ft_stats(drop), land_frames])
		if moved:
			s.stack.undo()
		await _frames(5)
	main.renderer.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[_app().settings.ambient_animation()])
	return true


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


func _tile_select(hold: bool) -> bool:
	## Tile selection with the Select tool through real pointer events: a drag from
	## empty ground across the fields (tile_drag: the shot is taken while the
	## button is still down; tile_select: after the release). Prints
	## "SEL tiles=<w>x<h> objects=<n> selected=<n>" for checks.
	var s = _session()
	s.set_tool("select")
	s.clear_selection()
	var uids: Array = []
	for o: PlacedObject in s.layout.objects.values():
		if o.item_id in select_items:
			uids.append(o.uid)
	if uids.is_empty():
		print("FAIL %s: no %s objects" % ["tile_drag" if hold else "tile_select", "+".join(select_items)])
		return false
	var r: Rect2i = s.layout.bounds_of(uids)
	var area := r.grow(1)
	# Start on a free tile near the area's top corner (nothing picked there).
	var start := Vector2i(-99999, -99999)
	for d in 6:
		for t: Vector2i in [area.position + Vector2i(d, 0), area.position + Vector2i(0, d), area.position + Vector2i(d, d)]:
			if start.x == -99999 and main.controller.objects_here(Iso.tile_center(t)).is_empty():
				start = t
	if start.x == -99999:
		print("FAIL tile select: no free start tile")
		return false
	var end := area.end - Vector2i.ONE
	main.camera.smooth = false
	main.camera.set_zoom_level(1.0)
	main.camera.center_on(Iso.footprint_center(area.position, area.size))
	await _frames(15)
	var a: Vector2 = main.camera.world_to_screen(Iso.tile_center(start))
	var b: Vector2 = main.camera.world_to_screen(Iso.tile_center(end))
	_canvas_move(a, 0)
	_canvas_button(a, true)
	for i in range(1, 13):
		_canvas_move(a.lerp(b, i / 12.0), MOUSE_BUTTON_MASK_LEFT)
		await get_tree().process_frame
	var rect := Iso.rect_from_corners(start, end)
	if hold:
		main.overlay.cursor_world = Iso.tile_center(end)
		print("SEL tiles=%dx%d objects=%d selected=%d" % [rect.size.x, rect.size.y, main.controller._tile_count, s.selection.size()])
		await _frames(10)
		return true
	_canvas_button(b, false)
	await _frames(10)
	var want := TileRegion.from_rect(rect).uids_in(s.layout)
	var reg: TileRegion = s.selection_region
	print("SEL tiles=%dx%d objects=%d selected=%d region=%s" % [rect.size.x, rect.size.y, want.size(), s.selection.size(), str(reg.bounds()) if reg else "none"])
	if s.selection.size() != s.layout.expand_to_groups(want).size() or reg == null:
		print("FAIL tile_select: selection does not match the tiles")
		return false
	return true


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
	if sc.begins_with("wz_"):
		var ok_wz: bool = await _water_zone_shot(sc.substr(3))
		return ok_wz
	match sc:
		"tile_drag", "tile_select", "budget_breakdown":
			var ok_ts: bool = await _tile_select(sc == "tile_drag")
			if not ok_ts:
				return false
			if sc == "budget_breakdown":
				# Balances recorded, so the card can answer "can I afford it?" (undone by the next _reset).
				var p: Dictionary = s.layout.profile.duplicate(true)
				p["balances"] = {"coins": 25000, "diamonds": 40}
				s.execute(EditCommands.SetProfile.new(s.layout.profile, p))
				_undo_after += 1
				main.budget.set_expanded(true)
				await _frames(8)
				var a: Dictionary = main.budget.last_afford
				print("BUDGET state=%s cost=%s afford=%s" % [str(a.get("state")), str(main.budget.last_cost), str(a.get("shortfall"))])
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
		"game_data", "game_data_review":
			# Asset manager > Game data with an invented client-price supplement
			# (game_data_review: scrolled to the review list's side-by-side candidates)
			# (real game data only with --real-art, whose shots go to the private root).
			if not real_art:
				var recs := ClientPrices.records_from_reference({"format": ClientPrices.REFERENCE_FORMAT, "records": [
					{"table": "decorations", "source_name": "Bench", "purchase_price_fields": {"coins": 120}, "voucher_requirements": [], "can_buy_game_flag": true},
					{"table": "deco_fences", "source_name": "Fence", "purchase_price_fields": {"coins": 4}, "voucher_requirements": [], "price_increase": 3, "increase_every_n_objects": 2},
					{"table": "decorations", "source_name": "Water Dragon Steps", "purchase_price_fields": {}, "voucher_requirements": [{"game_currency": "Voucher3", "amount": 12}]},
					{"table": "decorations", "source_name": "Moon Fountain", "purchase_price_fields": {"pearls": 40}, "voucher_requirements": []},
					{"table": "decorations", "source_name": "Hay Bales", "purchase_price_fields": {"coins": 30}, "voucher_requirements": []},
					{"table": "decorations", "source_name": "Fitting room", "purchase_price_fields": {"coins": 900}, "voucher_requirements": [], "tile_width": 2, "tile_height": 2},
					{"table": "customization_house", "source_name": "RoofInvented", "purchase_price_fields": {"coins": 5000}, "voucher_requirements": []}]})
				var pb0: PriceBook = _app().prices.derived(null)
				var doc := ClientPrices.new().build(recs, _app().db, {}, {}, "0.0.0-synthetic", {"kind": "synthetic"})
				var res := ClientPrices.install(doc, ClientPrices.build_report(doc, pb0, _app().db))
				if not bool(res["ok"]):
					print("FAIL synthetic client prices: ", res["error"])
					return false
				_client_installed = true
				_app().reload_client_prices()
			main._fit()
			var amg = main._open_asset_manager("bakery")
			await _frames(6)
			amg.show_tab(3)
			await _frames(20)
			if sc == "game_data_review":
				amg.game_data.scroll_vertical = 100000
				await _frames(6)
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
		"terrain_pack":
			if not await _terrain_pack("", 0.0, Vector2.ZERO):
				return false
		"terrain_pack_winter":
			if not await _terrain_pack("winter", 0.0, Vector2.ZERO):
				return false
		"terrain_pack_river":
			# River, glints, the road crossing on its bridge, and the land edge.
			var road_y := 0.0
			for r in s.map.regions:
				if r["kind"] == FarmMap.Kind.ROAD and not (r["rects"] as Array).is_empty():
					road_y = (r["rects"][0] as Rect2i).position.y
			if not await _terrain_pack("", 1.6, Iso.grid_to_world(Vector2(-1.0, road_y - 2.0))):
				return false
		"terrain_pack_fg":
			# A foreground piece (canopy) over an object: drawn above it, never picked.
			if not await _terrain_fx("fg"):
				return false
		"terrain_pack_blend":
			# Pieces with the add (light shafts), multiply (cloud shadow) and screen (haze) blends.
			if not await _terrain_fx("blend"):
				return false
		"terrain_pack_zoomout":
			# Zoomed out as far as a user can: the camera bounds follow the pack's pieces.
			if not await _terrain_fx("zoomout"):
				return false
		"anim_perf":
			await _anim_perf()
		"anim_farm_perf":
			await _anim_farm_perf()
		"camera_perf":
			await _camera_perf()
		"ghost_art":
			if not await _ghost_art():
				return false
		"fence_junctions":
			if not await _fence_junctions():
				return false
		"drag_perf":
			if not await _drag_perf():
				return false
		"object_glow":
			if not await _object_glow():
				return false
		"plan_budget":
			# Budget chip expanded (selection scope) + the Budget tab.
			await _plan_layout(false)
			var trees: Array = []
			for o: PlacedObject in s.layout.objects.values():
				if o.item_id.ends_with("_tree") and o.origin.y >= 26:
					trees.append(o.uid)
			s.select(trees, false, false)
			_app().plan_ctx.set_active_area("a1")
			main.budget.set_expanded(true)
			main._fit()
			main.open_plan("budget")
		"plan_areas":
			await _plan_tab("areas", false)
			_app().plan_ctx.set_active_area("a1")
		"plan_phases":
			await _plan_tab("phases")
			var p1 := str(PlanDoc.phases(s.layout.planning)[0].get("id"))   # ids share one counter with the areas
			_app().plan_ctx.set_active_phase(p1)
			main._plan_highlight(s.budget.phase_uids(p1), Color("#6fb3e0"))
			# A plan picture of the phase with its guide numbers (placeholder art).
			var pp := out_dir.path_join("%sexport_plan_phase_1.png" % tag)
			var perr: Error = await main.export_plan_image({"scope": "phase", "id": p1, "guide_numbers": true, "path": pp})
			print("EXPORT plan phase %s (%d guide steps marked of %d)" % [error_string(perr), main._guide_step_numbers("phase", p1).size(),
				(_app().plan_ctx.guide().get("steps", []) as Array).size()])
		"plan_heatmap":
			await _plan_tab("budget", false)
			_app().plan_ctx.set_layer("heatmap", true)
			_app().plan_ctx.set_layer("areas", false)
		"plan_shop":
			await _plan_tab("shop")
		"plan_build":
			await _plan_tab("build")
		"plan_guide":
			await _plan_tab("guide")
		"plan_accuracy":
			await _plan_tab("accuracy")
		"plan_minimap":
			# The overview map: land, objects (the active phase in its colour),
			# area outlines and the camera's view rectangle while zoomed in.
			await _plan_tab("phases")
			var ph1 := str(PlanDoc.phases(s.layout.planning)[0].get("id"))
			_app().plan_ctx.set_active_phase(ph1)
			main.camera.smooth = false
			main.camera.set_zoom_level(1.4)
			main.camera.zoom = Vector2(1.4, 1.4)
			main.camera.target_zoom = 1.4
			main.camera.center_on(Iso.grid_to_world(Vector2(16, 20)))
			await _frames(3)
			main._place_budget()
			print("MINIMAP shown=%s room=%s" % [str(main.minimap_shown()), str(main.minimap_room())])
		"plan_layers":
			# Decorations hidden and trees dimmed (view only), with the View tab.
			await _plan_layout(false)
			main.set_object_layer("decorations", ObjectLayers.HIDE)
			main.set_object_layer("trees", ObjectLayers.DIM)
			main.inspector.show_tab(2)
			main.inspector.rebuild()
			main._fit()
			print("LAYERS hidden=%d" % main.renderer.layer_hidden_count())
		"plan_compare":
			# Before / after with the real farm: tints, arrows, ghosts, legend, Build counts.
			await _plan_layout(true)
			await _compare_edits()
			_app().plan_ctx.set_compare(true)
			main._fit()
			main.open_plan("build")
			await _frames(3)
			main._sync_compare()
			main._place_budget()
			print("COMPARE %s" % str(_app().plan_ctx.compare_counts()))
		"plan_ready":
			# "Can I build this?" with a few blocking issues (top of the Budget tab).
			await _plan_layout(false)
			await _ready_issues()
			main._fit()
			main.open_plan("budget")
			await _frames(3)
			var rr: Dictionary = _app().plan_ctx.readiness()
			print("READY blocking=%d checks=%d rows=%s" % [int(rr.get("blocking", 0)), int(rr.get("checks", 0)),
				str((rr.get("rows", []) as Array).map(func(r: Dictionary) -> String: return str(r["id"])))])
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
