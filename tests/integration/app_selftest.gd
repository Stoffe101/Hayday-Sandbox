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
					var ring := PlacementRules.check_rect(s.layout, s.map, Rect2i(o - Vector2i.ONE, item.size_for(flipped) + Vector2i(2, 2)))
					if ring.ok:
						return o
	return near


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
	_migration_check()

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
	if fh_tile.x != -9999:
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
		check(not r.ok and r.reason_counts.has(PlacementRules.LANDMARK), "%s mode: landmark tiles block placement (%s)" % [mode, r.message(s.layout, s.db, s.map)])
		main._on_item_chosen("fence")
		var c0 := s.layout.count()
		_click_tile(tile)
		check(s.layout.count() == c0, "%s mode: clicking the farmhouse with the place tool places nothing" % mode)
		_key(KEY_ESCAPE)
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
	for k in results:
		print("PERF %s %s" % [k, JSON.stringify(results[k])])
	var r5: Dictionary = results[5000]
	check(r5["sort_ms"] < 1500.0, "full depth sort of %d objects: %.0f ms" % [r5["objects"], r5["sort_ms"]])
	check(r5["edit_resort_ms"] < 1500.0, "single edit incl. re-sort at %d objects: %.0f ms" % [r5["objects"], r5["edit_resort_ms"]])
	check(r5["place_check_us"] < 2000.0, "placement check: %.0f µs" % r5["place_check_us"])
	check(r5["pick_us"] < 5000.0, "pixel-accurate pick: %.0f µs" % r5["pick_us"])
	check(r5["save_ms"] < 3000.0 and r5["load_ms"] < 3000.0, "save %.0f ms / load %.0f ms" % [r5["save_ms"], r5["load_ms"]])
	App.maps.erase(big.id)


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
	# Visibility of a landmark is per layout, undoable, and hides it from picking.
	s.set_landmark_visible("farmhouse", false)
	check(not bool(main.renderer.world_entry(key).get("visible", true)) and (main.renderer.pick_any(Iso.tile_center(pt)) as Dictionary).get("key", "") != key,
		"hiding a landmark hides it in the renderer (not pickable)")
	_key(KEY_Z, true)
	check(bool(main.renderer.world_entry(key).get("visible", false)), "Ctrl+Z shows it again")
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
	check(ok_home and main.camera.view_center().distance_to(home_pt) < 1.0 and s.tool == "select", "Home key and Shift+H go home too (H alone stays the pan tool)")
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
