extends Node
## Composition root: builds the world + UI, wires them to App/EditorSession,
## and owns global shortcuts. Contains glue only — behaviour lives in the
## core, editor and ui modules.

var world: Node2D
var camera: FarmCamera
var ground: GroundLayer
var scenery: SceneryLayer
var reference: ReferenceLayer
var grid: GridOverlay
var renderer: ObjectRenderer
var overlay: EditorOverlay
var controller: EditorController
var exporter: Exporter

var ui_layer: CanvasLayer
var root: Control
var canvas_area: Control
var top_bar: TopBar
var catalog: CatalogPanel
var inspector: InspectorPanel
var dock: ToolDock
var toasts: Toasts
var modal_layer: Control

var _left_visible := true
var _right_visible := true
var _panels_hidden := false
var _diff: LayoutDiff.Result
var _view_state := {}
var _calib_world: Array = []
var _ref_drag := false
var _ref_drag_last := Vector2.ZERO
var _layout_dirty_ui := true
var _last_title := ""


func _ready() -> void:
	get_tree().root.min_size = Vector2i(1024, 640)
	get_tree().set_auto_accept_quit(false)
	var capture := OS.get_cmdline_user_args().has("--capture")
	if capture:
		# Deterministic state for visual tests (never persisted).
		App.settings.set_v("onboarding_done", true, false)
		App.settings.set_v("theme", "dark", false)
		App.settings.set_v("last_layout", "", false)
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--scale="):
				App.settings.set_v("ui_scale", float(a.substr(8)), false)
	_build_world()
	_apply_ui_scale()
	_build_ui()
	App.notify.connect(func(t, k): toasts.show_toast(t, k))
	App.session_changed.connect(_on_session_changed)
	App.assets_reloaded.connect(func():
		renderer.refresh_all_art()
		catalog.refresh())
	App.settings.changed.connect(_on_setting_changed)
	_open_initial()
	get_tree().root.size_changed.connect(_update_view_rect)
	call_deferred("_update_view_rect")
	call_deferred("_fit_or_restore")
	if not bool(App.settings.get_v("onboarding_done")) and not _is_automation():
		call_deferred("_show_welcome")
	if capture:
		var drv: Variant = load("res://tests/visual/capture.gd")
		if drv:
			add_child(drv.new())
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--selftest"):
			var st: Variant = load("res://tests/integration/app_selftest.gd")
			if st:
				var node: Node = st.new()
				node.set("mode", a.get_slice("=", 1) if a.contains("=") else "all")
				add_child(node)
			else:
				print("SELFTEST UNAVAILABLE (tests not packaged)")
				get_tree().quit(3)


func _is_automation() -> bool:
	var args := OS.get_cmdline_user_args()
	return args.has("--no-welcome") or args.has("--capture") or DisplayServer.get_name() == "headless" or "--selftest" in " ".join(args)


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_world() -> void:
	world = Node2D.new()
	world.name = "World"
	add_child(world)
	ground = GroundLayer.new()
	world.add_child(ground)
	scenery = SceneryLayer.new()
	world.add_child(scenery)
	reference = ReferenceLayer.new()
	reference.visibility_layer = Exporter.LAYER_OVERLAY
	world.add_child(reference)
	grid = GridOverlay.new()
	grid.visibility_layer = Exporter.LAYER_GRID
	world.add_child(grid)
	renderer = ObjectRenderer.new()
	world.add_child(renderer)
	overlay = EditorOverlay.new()
	overlay.visibility_layer = Exporter.LAYER_OVERLAY
	world.add_child(overlay)
	camera = FarmCamera.new()
	world.add_child(camera)
	camera.make_current()
	camera.view_changed.connect(_on_view_changed)
	controller = EditorController.new()
	controller.camera = camera
	controller.renderer = renderer
	controller.overlay = overlay
	controller.ground = ground
	add_child(controller)
	exporter = Exporter.new()
	add_child(exporter)
	controller.status_changed.connect(func(t): dock.set_status(t))
	controller.request_text.connect(func(title, initial, cb): Modal.prompt(modal_layer, title, initial, cb))
	controller.request_context_menu.connect(_context_menu)
	controller.calibration_point.connect(_on_calibration_point)


func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 1
	add_child(ui_layer)
	root = Control.new()
	root.name = "UIRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiTheme.build(App.settings.get_v("theme") == "dark")
	ui_layer.add_child(root)
	RenderingServer.set_default_clear_color(Color("#3d6b3a") if App.settings.get_v("theme") == "dark" else Color("#6f9c5c"))
	canvas_area = Control.new()
	canvas_area.name = "Canvas"
	canvas_area.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas_area.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas_area.focus_mode = Control.FOCUS_CLICK
	canvas_area.gui_input.connect(_on_canvas_input)
	canvas_area.mouse_exited.connect(func():
		overlay.hover_uid = 0
		overlay.cursor_text = ""
		overlay.ghosts = [] if controller.session and controller.session.tool != "place" and not controller.stamp_mode else overlay.ghosts
		overlay.refresh())
	root.add_child(canvas_area)
	var m := 14
	top_bar = TopBar.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_left = m
	top_bar.offset_right = -m
	top_bar.offset_top = m
	top_bar.action.connect(_on_top_action)
	root.add_child(top_bar)
	catalog = CatalogPanel.new()
	catalog.anchor_top = 0
	catalog.anchor_bottom = 1
	catalog.offset_left = m
	catalog.offset_top = 82
	catalog.offset_bottom = -m
	catalog.item_chosen.connect(_on_item_chosen)
	root.add_child(catalog)
	inspector = InspectorPanel.new()
	inspector.anchor_left = 1
	inspector.anchor_right = 1
	inspector.anchor_bottom = 1
	inspector.offset_top = 82
	inspector.offset_bottom = -m
	inspector.offset_right = -m
	inspector.action.connect(_on_inspector_action)
	root.add_child(inspector)
	dock = ToolDock.new()
	dock.anchor_left = 0
	dock.anchor_right = 1
	dock.anchor_top = 1
	dock.anchor_bottom = 1
	dock.offset_top = -96
	dock.offset_bottom = -m
	dock.tool_selected.connect(func(t):
		if App.session:
			if t == "place" and App.session.active_item.is_empty():
				App.toast("Pick an item from the catalogue first", "info")
			App.session.set_tool(t))
	dock.action.connect(_on_dock_action)
	root.add_child(dock)
	toasts = Toasts.new()
	toasts.anchor_left = 1
	toasts.anchor_right = 1
	toasts.anchor_top = 1
	toasts.anchor_bottom = 1
	toasts.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	toasts.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(toasts)
	modal_layer = Control.new()
	modal_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(modal_layer)
	_layout_panels()


func _layout_panels() -> void:
	var w := root.get_viewport_rect().size.x
	var side := clampf(w * 0.2, 290.0, 380.0)
	catalog.offset_right = catalog.offset_left + side
	inspector.offset_left = -14 - clampf(w * 0.2, 300.0, 380.0)
	catalog.visible = _left_visible and not _panels_hidden
	inspector.visible = _right_visible and not _panels_hidden
	top_bar.visible = not _panels_hidden
	var left_edge := (catalog.offset_right + 14) if catalog.visible else 14.0
	var right_edge := (-inspector.offset_left + 14) if inspector.visible else 14.0
	dock.offset_left = left_edge
	dock.offset_right = -right_edge
	toasts.offset_right = -right_edge
	toasts.offset_left = toasts.offset_right - 360
	toasts.offset_bottom = -104
	toasts.offset_top = toasts.offset_bottom - 300
	top_bar.set_panels(_left_visible, _right_visible)


func _update_view_rect() -> void:
	_layout_panels()
	var vs := root.get_viewport_rect().size
	var l := (catalog.offset_right + 10) if catalog.visible else 0.0
	var r := (-inspector.offset_left + 10) if inspector.visible else 0.0
	var t := 80.0 if top_bar.visible else 0.0
	camera.view_rect = Rect2(Vector2(l, t), Vector2(vs.x - l - r, vs.y - t - 100))


func _apply_ui_scale() -> void:
	var s := float(App.settings.get_v("ui_scale"))
	if s <= 0.0:
		s = _auto_scale()
	get_window().content_scale_factor = s
	Icons.set_scale(s)


func _auto_scale() -> float:
	var dpi := DisplayServer.screen_get_dpi()
	var size := DisplayServer.screen_get_size()
	var s := 1.0
	if dpi >= 192:
		s = 2.0
	elif dpi >= 144:
		s = 1.5
	elif dpi >= 120:
		s = 1.25
	if size.y >= 2000 and s < 1.5:
		s = 1.5
	return s


func _rebuild_ui() -> void:
	ui_layer.queue_free()
	await get_tree().process_frame
	_apply_ui_scale()
	_build_ui()
	_on_session_changed()
	_update_view_rect()


# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

func _open_initial() -> void:
	var last := str(App.settings.get_v("last_layout"))
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--open="):
			var rep := LayoutIO.LoadReport.new()
			var l := App.library.load_path(a.substr(7), rep)
			if l:
				App.open_layout(l, rep)
				return
	if not last.is_empty() and App.library.exists(last):
		var rep2 := LayoutIO.LoadReport.new()
		var l2 := App.library.load_layout(last, rep2)
		if l2:
			App.open_layout(l2, rep2)
			_offer_recovery()
			return
	# First run: start from the showcase template if present.
	var sample := "res://data/samples/01_meadow_showcase.hdlayout"
	if FileAccess.file_exists(sample):
		_open_template(sample, "My first farm")
	else:
		App.open_layout(App.new_layout("My first farm"))
	_offer_recovery()


func _offer_recovery() -> void:
	var rec := App.library.pending_recovery()
	if rec.is_empty():
		return
	var e: Dictionary = rec[0]
	Modal.confirm(modal_layer, "Recover unsaved work?", "“%s” has autosaved changes newer than its last save (%s). Open the recovered version?" % [e["name"], str(e["modified"]).replace("T", " ")], "Recover", false, func():
		var rep := LayoutIO.LoadReport.new()
		var l := App.library.load_path(e["path"], rep)
		if l:
			l.id = e["id"]
			App.open_layout(l, rep)
			App.session.stack._dirty_counter = 1
			App.toast("Recovered — save to keep it", "success"))


func _open_template(path: String, name: String) -> void:
	var rep := LayoutIO.LoadReport.new()
	var l := App.library.load_path(path, rep)
	if l == null:
		App.toast("Template could not be loaded: %s" % rep.error, "error")
		return
	l.id = LayoutLibrary.new_id()
	l.name = name
	l.created = ""
	App.open_layout(l, rep)
	App.session.stack._dirty_counter = 1


func _on_session_changed() -> void:
	var s := App.session
	if s == null:
		return
	ground.setup(s.map, s.layout.unlocked_plots)
	if scenery.map != s.map:
		scenery.setup(s.map, App.assets, s.db)
	ground.hide_locked = bool(_view_state.get("hide_locked", false))
	grid.setup(s.map, s.layout, s.db)
	grid.show_grid = bool(App.settings.get_v("show_grid"))
	grid.show_occupancy = bool(App.settings.get_v("show_occupancy"))
	renderer.show_shadows = bool(App.settings.get_v("show_shadows"))
	renderer.bind(s.layout, s.db, App.assets)
	overlay.layout = s.layout
	overlay.db = s.db
	overlay.assets = App.assets
	overlay.renderer = renderer
	overlay.accent = UiTheme.c("accent")
	overlay.show_labels = bool(App.settings.get_v("show_labels"))
	overlay.show_annotations = bool(App.settings.get_v("show_annotations"))
	overlay.diff = {}
	_diff = null
	_view_state.erase("diff_summary")
	controller.bind(s)
	_load_reference()
	s.selection_changed.connect(_on_selection_changed)
	s.tool_changed.connect(_on_tool_changed)
	s.history_changed.connect(_on_history_changed)
	s.active_item_changed.connect(func():
		catalog.select_item(s.active_item)
		inspector.queue_rebuild())
	s.message.connect(func(t, k): toasts.show_toast(t, k))
	s.mode_changed.connect(func():
		_refresh_issues()
		inspector.queue_rebuild()
		top_bar.update_state(s))
	s.layout.land_changed.connect(func():
		ground.setup(s.map, s.layout.unlocked_plots)
		grid.queue_redraw())
	s.layout.annotations_changed.connect(overlay.refresh)
	s.layout.meta_changed.connect(func(): top_bar.update_state(s))
	s.layout.planning_changed.connect(func():
		_refresh_issues()
		inspector.queue_rebuild())
	_on_tool_changed()
	_on_history_changed()
	inspector.view_state = _view_state
	inspector.rebuild()
	catalog.refresh()
	_update_title()


func _fit_or_restore() -> void:
	_update_view_rect()
	var s := App.session
	if s and s.layout.camera.has("x"):
		camera.zoom = Vector2.ONE * float(s.layout.camera.get("zoom", 1.0))
		camera.target_zoom = camera.zoom.x
		camera.position = Vector2(float(s.layout.camera["x"]), float(s.layout.camera["y"]))
		camera.force_update_scroll()
		_on_view_changed()
	else:
		_fit()


func _fit() -> void:
	var s := App.session
	if s == null:
		return
	_update_view_rect()
	camera.fit_world_rect(Exporter.farm_world_rect(s.map, s.layout, "unlocked"), 20.0)


func _on_selection_changed() -> void:
	overlay.selection = App.session.selection
	overlay.refresh()
	if inspector.current_tab() != 0 and not App.session.selection.is_empty():
		inspector.show_tab(0)
	inspector.queue_rebuild()


func _on_tool_changed() -> void:
	var s := App.session
	dock.set_tool(s.tool)
	if s.tool != "land" and not ground.highlight_plot.is_empty():
		ground.highlight_plot = ""
		ground.queue_redraw()
	canvas_area.mouse_default_cursor_shape = Control.CURSOR_ARROW
	match s.tool:
		"pan": canvas_area.mouse_default_cursor_shape = Control.CURSOR_DRAG
		"pick": canvas_area.mouse_default_cursor_shape = Control.CURSOR_CROSS
		"place", "annotate": canvas_area.mouse_default_cursor_shape = Control.CURSOR_CROSS
		"land": canvas_area.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if s.tool != "place":
		overlay.ghosts = []
		overlay.ghost_result = null
	controller.refresh_hover()
	inspector.queue_rebuild()


func _on_history_changed() -> void:
	top_bar.update_state(App.session)
	_refresh_issues()
	inspector.queue_rebuild()
	_update_title()


func _refresh_issues() -> void:
	var s := App.session
	var issues := {}
	var conflicts := PlacementRules.find_conflicts(s.layout, s.map)
	for u in conflicts:
		issues[u] = 2
	if s.layout.mode == FarmLayout.MODE_REALISTIC:
		var r := RealisticAnalyzer.analyze(s.layout, s.db, s.map)
		for u in r.issues:
			var sev := 0
			for c in r.issues[u]:
				sev = maxi(sev, RealisticAnalyzer.SEVERITY.get(c, 0))
			if sev > 0:
				issues[u] = maxi(issues.get(u, 0), sev)
	overlay.issues = issues
	var tints := {}
	if s.layout.mode == FarmLayout.MODE_REALISTIC:
		for u in issues:
			if issues[u] >= 2:
				tints[u] = Color(1.0, 0.82, 0.8)
	renderer.set_tints(tints)
	overlay.refresh()


func _update_title() -> void:
	var s := App.session
	var t := "%s%s — Hayday Sandbox" % ["• " if s and s.stack.is_dirty() else "", s.layout.name if s else ""]
	if t != _last_title:
		_last_title = t
		get_window().title = t


func _on_view_changed() -> void:
	var z := camera.zoom.x
	dock.set_zoom(z)
	grid.set_zoom(z)
	overlay.zoom = z
	overlay.visible_rect = camera.visible_world_rect()
	overlay.refresh()
	if App.session:
		App.session.layout.camera = {"x": camera.position.x, "y": camera.position.y, "zoom": camera.target_zoom}


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _on_canvas_input(e: InputEvent) -> void:
	if _ref_drag and e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			_ref_drag_last = camera.screen_to_world(e.position)
			_view_state["ref_dragging"] = true
		else:
			_view_state["ref_dragging"] = false
			_save_reference_settings()
		return
	if _ref_drag and e is InputEventMouseMotion and _view_state.get("ref_dragging", false):
		var w := camera.screen_to_world(e.position)
		reference.move_by(w - _ref_drag_last)
		_ref_drag_last = w
		return
	if e is InputEventMouseButton and e.pressed:
		canvas_area.grab_focus()
	controller.handle_input(e)


func _unhandled_input(e: InputEvent) -> void:
	if not e is InputEventKey or App.session == null:
		return
	var k := e as InputEventKey
	if k.keycode == KEY_SPACE:
		controller.set_space(k.pressed)
		canvas_area.mouse_default_cursor_shape = Control.CURSOR_DRAG if k.pressed else Control.CURSOR_ARROW
		get_viewport().set_input_as_handled()
		return
	if not k.pressed or k.echo and not k.keycode in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_EQUAL, KEY_MINUS, KEY_KP_ADD, KEY_KP_SUBTRACT]:
		return
	if modal_layer.get_child_count() > 0:
		return
	var s := App.session
	var ctrl := k.ctrl_pressed or k.meta_pressed
	var handled := true
	match k.keycode:
		KEY_Z when ctrl and k.shift_pressed: _redo()
		KEY_Z when ctrl: _undo()
		KEY_Y when ctrl: _redo()
		KEY_S when ctrl: _save()
		KEY_O when ctrl: _gallery()
		KEY_N when ctrl: _new_layout("starter")
		KEY_E when ctrl: _export_dialog()
		KEY_F when ctrl: catalog.focus_search()
		KEY_M when ctrl: _toggle_mode()
		KEY_A when ctrl: s.select_all()
		KEY_C when ctrl: _copy(false)
		KEY_X when ctrl: _copy(true)
		KEY_V when ctrl: controller.start_stamp()
		KEY_D when ctrl:
			if _copy(false) > 0:
				controller.start_stamp()
		KEY_G when ctrl and k.shift_pressed: s.ungroup_selection()
		KEY_G when ctrl: s.group_selection()
		KEY_ESCAPE:
			if not controller.cancel():
				handled = false
			overlay.calibration_points = []
			overlay.refresh()
		KEY_DELETE, KEY_BACKSPACE: s.delete_selection()
		KEY_V: s.set_tool("select")
		KEY_B:
			if s.active_item.is_empty():
				App.toast("Pick an item from the catalogue first", "info")
			s.set_tool("place")
		KEY_E: s.set_tool("erase")
		KEY_I: s.set_tool("pick")
		KEY_M: s.set_tool("land")
		KEY_N: s.set_tool("annotate")
		KEY_H: s.set_tool("pan")
		KEY_R:
			if s.tool == "place":
				_inspector_place_flip()
			else:
				s.flip_selection()
		KEY_P:
			if s.tool == "place":
				s.place_planned = not s.place_planned
				App.toast("Placing as %s" % ("planned (future) objects" if s.place_planned else "real objects"), "info")
				inspector.queue_rebuild()
			else:
				_toggle_selection_flag("planned", "Planned")
		KEY_L: _toggle_selection_flag("locked", "Lock")
		KEY_G: _set_view("show_grid", not bool(App.settings.get_v("show_grid")))
		KEY_O: _set_view("show_occupancy", not bool(App.settings.get_v("show_occupancy")))
		KEY_F, KEY_HOME: _fit()
		KEY_TAB:
			_panels_hidden = not _panels_hidden
			_update_view_rect()
		KEY_F1, KEY_QUESTION: Dialogs.help(modal_layer)
		KEY_EQUAL, KEY_KP_ADD: camera.zoom_at(camera.view_rect.get_center(), 1.2)
		KEY_MINUS, KEY_KP_SUBTRACT: camera.zoom_at(camera.view_rect.get_center(), 1.0 / 1.2)
		KEY_UP: _arrow(Vector2i(0, -1))
		KEY_DOWN: _arrow(Vector2i(0, 1))
		KEY_LEFT: _arrow(Vector2i(-1, 0))
		KEY_RIGHT: _arrow(Vector2i(1, 0))
		_: handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _arrow(d: Vector2i) -> void:
	if App.session.selection.is_empty():
		var step := Iso.grid_to_world(Vector2(d)) * 2.0
		camera.position += step
		camera.force_update_scroll()
		_on_view_changed()
	else:
		App.session.nudge(d)


func _toggle_selection_flag(prop: String, label: String) -> void:
	var objs := App.session.selected_objects()
	if objs.is_empty():
		return
	var all_on := true
	for o: PlacedObject in objs:
		all_on = all_on and bool(o.get(prop))
	App.session.set_flag(prop, not all_on, ("Un" + label.to_lower() if all_on else label))


func _copy(cut: bool) -> int:
	var n := App.session.copy_selection()
	if n == 0:
		return 0
	if cut:
		App.session.delete_selection()
	App.toast("%s %d object%s — Ctrl+V to paste" % ["Cut" if cut else "Copied", n, "" if n == 1 else "s"], "info")
	return n


func _undo() -> void:
	controller.cancel()
	var l := App.session.stack.undo()
	if not l.is_empty():
		dock.set_status("Undid: " + l)


func _redo() -> void:
	var l := App.session.stack.redo()
	if not l.is_empty():
		dock.set_status("Redid: " + l)


func _toggle_mode() -> void:
	var s := App.session
	s.set_mode(FarmLayout.MODE_REALISTIC if s.layout.mode == FarmLayout.MODE_CREATIVE else FarmLayout.MODE_CREATIVE)
	App.toast("%s mode%s" % [s.layout.mode.capitalize(), " — conflicts are highlighted; your design is unchanged" if s.layout.mode == FarmLayout.MODE_REALISTIC else ""], "info")
	inspector.show_tab(1)


func _context_menu(screen: Vector2, uid: int) -> void:
	var s := App.session
	var pm := PopupMenu.new()
	if uid != 0:
		pm.add_item("Rotate  (R)", 1)
		pm.add_item("Duplicate  (Ctrl+D)", 2)
		pm.add_item("Copy  (Ctrl+C)", 3)
		pm.add_item("Lock / unlock  (L)", 4)
		pm.add_item("Planned / real  (P)", 5)
		pm.add_item("Pick this item  (I)", 6)
		pm.add_separator()
		pm.add_item("Delete  (Del)", 7)
	else:
		pm.add_item("Paste here  (Ctrl+V)", 10)
		pm.set_item_disabled(pm.item_count - 1, s.clipboard.is_empty())
		pm.add_item("Select all  (Ctrl+A)", 11)
		pm.add_item("Fit farm  (F)", 12)
	pm.id_pressed.connect(_on_context_id.bind(uid))
	root.add_child(pm)
	pm.popup_hide.connect(pm.queue_free)
	pm.popup(Rect2i(Vector2i(screen), Vector2i.ZERO))


func _on_context_id(id: int, uid: int) -> void:
	var s := App.session
	match id:
		1: s.flip_selection()
		2:
			if _copy(false) > 0:
				controller.start_stamp()
		3: _copy(false)
		4: _toggle_selection_flag("locked", "Lock")
		5: _toggle_selection_flag("planned", "Planned")
		6:
			var o := s.layout.get_obj(uid)
			if o:
				s.set_active_item(o.item_id)
		7: s.delete_selection()
		10: controller.start_stamp()
		11: s.select_all()
		12: _fit()


# ---------------------------------------------------------------------------
# Actions from widgets
# ---------------------------------------------------------------------------

func _on_item_chosen(id: String) -> void:
	controller.stamp_mode = false
	App.session.set_active_item(id)
	App.session.clear_selection()
	if inspector.current_tab() != 0:
		inspector.show_tab(0)


func _on_top_action(a: String) -> void:
	match a:
		"undo": _undo()
		"redo": _redo()
		"save": _save()
		"gallery": _gallery()
		"export": _export_dialog()
		"settings": Dialogs.settings(modal_layer, _on_settings_dialog)
		"help": Dialogs.help(modal_layer)
		"rename":
			Modal.prompt(modal_layer, "Rename layout", App.session.layout.name, func(t):
				if not t.strip_edges().is_empty():
					App.session.layout.name = t.strip_edges()
					App.session.layout.meta_changed.emit()
					App.session.stack._dirty_counter += 1
					top_bar.update_state(App.session)
					_update_title())
		"mode_creative":
			App.session.set_mode(FarmLayout.MODE_CREATIVE)
			top_bar.update_state(App.session)
		"mode_realistic":
			App.session.set_mode(FarmLayout.MODE_REALISTIC)
			top_bar.update_state(App.session)
			inspector.show_tab(1)
		"toggle_left":
			_left_visible = not _left_visible
			App.settings.set_v("left_panel", _left_visible)
			_update_view_rect()
		"toggle_right":
			_right_visible = not _right_visible
			App.settings.set_v("right_panel", _right_visible)
			_update_view_rect()


func _on_dock_action(a: String) -> void:
	match a:
		"zoom_in": camera.zoom_at(camera.view_rect.get_center(), 1.25)
		"zoom_out": camera.zoom_at(camera.view_rect.get_center(), 0.8)
		"fit": _fit()
		"grid": _set_view("show_grid", not bool(App.settings.get_v("show_grid")))


func _inspector_place_flip() -> void:
	var s := App.session
	var it := s.db.get_item(s.active_item)
	if it and it.flippable:
		s.place_flipped = not s.place_flipped
		controller.refresh_hover()
		inspector.queue_rebuild()
	elif it:
		App.toast("%s can't be rotated in the game" % it.name, "warn")


func _on_inspector_action(a: String, arg: Variant) -> void:
	var s := App.session
	match a:
		"place_flip": _inspector_place_flip()
		"place_planned":
			s.place_planned = not s.place_planned
			inspector.queue_rebuild()
		"brush":
			s.brush = arg
			inspector.queue_rebuild()
		"flip": s.flip_selection()
		"duplicate":
			if _copy(false) > 0:
				controller.start_stamp()
		"lock": _toggle_selection_flag("locked", "Lock")
		"planned": _toggle_selection_flag("planned", "Planned")
		"group":
			var any := false
			for o: PlacedObject in s.selected_objects():
				any = any or o.group_id != 0
			if any:
				s.ungroup_selection()
			else:
				s.group_selection()
		"delete": s.delete_selection()
		"note":
			var uids := s.selection.duplicate()
			if uids.size() == 1:
				s.execute(EditCommands.SetProperty.new(uids, "note", [str(arg)], "Edit note"))
		"toggle_mode": _toggle_mode()
		"tool": s.set_tool(arg)
		"land_all":
			var old := s.layout.unlocked_plots.keys()
			s.execute(EditCommands.SetLand.new(old, s.map.all_plot_ids() if arg else [], "Unlock all land" if arg else "Lock all expansions"))
		"profile":
			var p := s.layout.profile.duplicate(true)
			p.merge(arg, true)
			s.execute(EditCommands.SetProfile.new(s.layout.profile, p))
		"own_all":
			var p2 := s.layout.profile.duplicate(true)
			p2["owned"] = s.layout.item_counts(false)
			s.execute(EditCommands.SetProfile.new(s.layout.profile, p2, "Record inventory"))
			App.toast("Recorded %d item types as owned" % (p2["owned"] as Dictionary).size(), "success")
		"select_item":
			var uids2: Array = []
			for o: PlacedObject in s.layout.objects.values():
				if o.item_id == arg:
					uids2.append(o.uid)
			s.select(uids2, false, false)
		"view": _set_view(arg[0], arg[1])
		"ref_import": _ref_import()
		"ref": _ref_update(arg)
		"ref_calibrate": _ref_calibrate()
		"ref_remove":
			s.layout.reference = {}
			s.stack._dirty_counter += 1
			_load_reference()
			inspector.rebuild()
		"ref_move":
			_ref_drag = bool(arg)
		"compare": _compare_pick()
		"compare_clear":
			overlay.diff = {}
			_view_state.erase("diff_summary")
			overlay.refresh()
			inspector.rebuild()


func _set_view(key: String, on: bool) -> void:
	if key == "hide_locked":
		_view_state["hide_locked"] = on
		ground.hide_locked = on
		ground.queue_redraw()
		return
	App.settings.set_v(key, on)


func _on_setting_changed(key: String) -> void:
	match key:
		"show_grid":
			grid.show_grid = bool(App.settings.get_v(key))
			dock.set_grid(grid.show_grid)
		"show_occupancy": grid.show_occupancy = bool(App.settings.get_v(key))
		"show_shadows": renderer.show_shadows = bool(App.settings.get_v(key))
		"show_labels":
			overlay.show_labels = bool(App.settings.get_v(key))
			overlay.refresh()
		"show_annotations":
			overlay.show_annotations = bool(App.settings.get_v(key))
			overlay.refresh()
		"smooth_zoom": camera.smooth = bool(App.settings.get_v(key))


func _on_settings_dialog(what: String) -> void:
	match what:
		"theme", "ui_scale":
			_rebuild_ui()
		"map_id":
			App.map = App.map_for(str(App.settings.get_v("map_id")))
			App.toast("New layouts will use “%s”. Open layouts keep their own map." % App.map.name, "info")
		"import_art":
			ArtImportDialog.new().show(modal_layer)


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

func _save() -> void:
	var err := App.save_current(true)
	if err == OK:
		App.toast("Saved “%s”" % App.session.layout.name, "success")
		_update_title()
		top_bar.update_state(App.session)
		_make_thumbnail()


func _make_thumbnail() -> void:
	var s := App.session
	var r := Exporter.farm_world_rect(s.map, s.layout, "unlocked")
	var scale := 480.0 / maxf(1.0, r.size.x)
	var img: Image = await exporter.capture(r, scale, false)
	if img:
		img.save_png(App.library.thumb_for(s.layout.id))


func _gallery() -> void:
	var g := Gallery.new()
	g.open_layout.connect(func(id):
		_confirm_discard(func():
			var rep := LayoutIO.LoadReport.new()
			var l := App.library.load_layout(id, rep)
			if l:
				App.open_layout(l, rep)
				_fit_or_restore()
			else:
				App.toast("Could not open: %s" % rep.error, "error")))
	g.new_layout.connect(_new_layout)
	g.open_template.connect(func(p, n): _confirm_discard(func():
		_open_template(p, n)
		_fit()))
	g.import_file.connect(func(p):
		var rep := LayoutIO.LoadReport.new()
		var id := App.library.import_file(p, rep)
		if id.is_empty():
			App.toast("Import failed: %s" % rep.error, "error")
		else:
			_confirm_discard(func():
				var rep2 := LayoutIO.LoadReport.new()
				App.open_layout(App.library.load_layout(id, rep2), rep)
				_fit()))
	g.show(modal_layer)


func _new_layout(template: String) -> void:
	_confirm_discard(func():
		App.open_layout(App.new_layout("New farm", template))
		_fit())


func _confirm_discard(then: Callable) -> void:
	if App.session and App.session.stack.is_dirty():
		Modal.confirm(modal_layer, "Unsaved changes", "Save “%s” before continuing?" % App.session.layout.name, "Save & continue", false, func():
			_save()
			then.call())
	else:
		then.call()


func _export_dialog() -> void:
	Dialogs.export_image(modal_layer, func(opts: Dictionary):
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.use_native_dialog = true
		fd.filters = PackedStringArray(["*.png ; PNG image"])
		fd.current_file = App.session.layout.name.validate_filename() + ".png"
		fd.file_selected.connect(func(p): _do_export(p, opts))
		root.add_child(fd)
		fd.popup_centered_ratio(0.6))


func _do_export(path: String, opts: Dictionary) -> void:
	var s := App.session
	var r: Rect2
	if opts["area"] == "view":
		r = camera.visible_world_rect()
	else:
		r = Exporter.farm_world_rect(s.map, s.layout, opts["area"])
	App.toast("Rendering image…", "info")
	var img: Image = await exporter.capture(r, float(opts["scale"]), bool(opts["transparent"]), bool(opts["grid"]), bool(opts["overlay"]))
	if img == null:
		App.toast("Export failed (image too large?)", "error")
		return
	var err := img.save_png(path)
	App.toast("Exported %d×%d image to %s" % [img.get_width(), img.get_height(), path] if err == OK else "Could not write file: %s" % error_string(err), "success" if err == OK else "error")


# ---------------------------------------------------------------------------
# Screenshot reference
# ---------------------------------------------------------------------------

func _load_reference() -> void:
	var s := App.session
	var ok := reference.load_from_settings(s.layout.reference)
	_view_state["ref_loaded"] = ok
	if ok:
		var st := s.layout.reference
		_view_state["ref_visible"] = bool(st.get("visible", true))
		_view_state["ref_locked"] = bool(st.get("locked", false))
		_view_state["ref_above"] = bool(st.get("above", false))
		_view_state["ref_opacity"] = float(st.get("opacity", 0.5))
		_view_state["ref_scale"] = float(st.get("scale", 1.0))
		_view_state["ref_rotation"] = float(st.get("rotation", 0.0))
		_place_reference_layer(bool(st.get("above", false)))
	elif not s.layout.reference.is_empty():
		_view_state["ref_status"] = "Reference image file is missing: %s" % str(s.layout.reference.get("file", ""))


func _place_reference_layer(above: bool) -> void:
	world.move_child(reference, overlay.get_index() if above else scenery.get_index() + 1)


func _ref_import() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	fd.file_selected.connect(func(p):
		var s := App.session
		var dst := ReferenceLayer.import_image(p, s.layout.id)
		if dst.is_empty():
			App.toast("Could not read that image", "error")
			return
		var land := Exporter.farm_world_rect(s.map, s.layout, "unlocked")
		s.layout.reference = reference.default_settings(dst, land.get_center(), land.size.x)
		s.stack._dirty_counter += 1
		_load_reference()
		inspector.show_tab(2)
		inspector.rebuild()
		App.toast("Reference added. Calibrate it to line it up with the grid.", "success"))
	root.add_child(fd)
	fd.popup_centered_ratio(0.6)


func _ref_update(d: Dictionary) -> void:
	var st := App.session.layout.reference
	for k in d:
		st[k] = d[k]
		_view_state["ref_" + k] = d[k]
	if d.has("scale") or d.has("rotation"):
		st.erase("affine")
	if d.has("above"):
		_place_reference_layer(bool(d["above"]))
	if d.has("locked"):
		_ref_drag = false
	reference.settings = st
	reference.apply()
	App.session.stack._dirty_counter += 1


func _save_reference_settings() -> void:
	App.session.layout.reference = reference.settings
	App.session.stack._dirty_counter += 1


func _ref_calibrate() -> void:
	_calib_world = []
	overlay.calibration_points = []
	controller.calibrating = true
	App.toast("Calibration: click 3 recognisable points on the screenshot…", "info")


func _on_calibration_point(w: Vector2) -> void:
	_calib_world.append(w)
	var n := _calib_world.size()
	if n <= 3:
		overlay.calibration_points = _calib_world.duplicate()
		if n == 3:
			App.toast("…now click the matching 3 tile corners on the grid, in the same order", "info")
	else:
		var g := Iso.world_to_grid(w)
		var snapped := Iso.grid_to_world(Vector2(roundf(g.x), roundf(g.y)))
		_calib_world[n - 1] = snapped
		overlay.calibration_points = _calib_world.duplicate()
	overlay.refresh()
	if _calib_world.size() == 6:
		controller.calibrating = false
		var img_pts: Array = []
		for i in 3:
			img_pts.append(reference.world_to_image(_calib_world[i]))
		var aff: Variant = ReferenceLayer.solve_affine(img_pts, _calib_world.slice(3, 6))
		overlay.calibration_points = []
		if aff == null:
			App.toast("Those points are in a line — pick three spread-out points", "warn")
			return
		var st := App.session.layout.reference
		st["affine"] = aff
		reference.settings = st
		reference.apply()
		App.session.stack._dirty_counter += 1
		_view_state["ref_status"] = "Calibrated with 3 points (affine). Perspective in screenshots isn't corrected."
		inspector.rebuild()
		App.toast("Reference aligned to the grid", "success")


# ---------------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------------

func _compare_pick() -> void:
	var m := Modal.open(modal_layer, "Compare with…", 520, "git-compare")
	var v := UI.vbox(4)
	var list := App.library.list()
	for e in list:
		if e["id"] == App.session.layout.id:
			continue
		var b := UI.button("%s  ·  %d objects" % [e["name"], e.get("objects", 0)], "layout-grid", "", "Ghost")
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func():
			m.close()
			_compare_with(e["id"], e["name"]))
		v.add_child(b)
	if v.get_child_count() == 0:
		v.add_child(UI.label("Save another layout first (e.g. duplicate this one in the gallery and change it).", "Dim", true))
	m.body.add_child(v)
	m.add_button("Cancel", "", m.close)


func _compare_with(id: String, name: String) -> void:
	var rep := LayoutIO.LoadReport.new()
	var other := App.library.load_layout(id, rep)
	if other == null:
		App.toast("Could not load “%s”" % name, "error")
		return
	var cur := App.session.layout
	# "added" = in the current layout but not in the other one.
	var d := LayoutDiff.compare(other, cur)
	var added: Array = []
	var removed: Array = []
	var moved: Array = []
	for u in d.added:
		added.append(cur.get_obj(u).rect())
	for u in d.removed:
		removed.append(other.get_obj(u).rect())
	for p in d.moved:
		moved.append([other.get_obj(p[0]).rect(), cur.get_obj(p[1]).rect()])
	overlay.diff = {"added": added, "removed": removed, "moved": moved}
	_view_state["diff_summary"] = d.summary()
	_view_state["diff_name"] = name
	_view_state["diff_delta"] = d.item_delta
	overlay.refresh()
	inspector.show_tab(2)
	inspector.rebuild()


func _show_welcome() -> void:
	Dialogs.welcome(modal_layer, func(): App.settings.set_v("onboarding_done", true))


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	if App.session == null or not App.session.stack.is_dirty():
		get_tree().quit()
		return
	# Keep a recovery copy no matter what the user answers.
	App.library.autosave(App.session.layout)
	if modal_layer.get_child_count() > 0:
		for c in modal_layer.get_children():
			c.queue_free()
	var m := Modal.open(modal_layer, "Save changes before closing?", 480, "save")
	m.body.add_child(UI.label("“%s” has unsaved changes." % App.session.layout.name, "Dim", true))
	m.add_button("Cancel", "", m.close)
	m.add_button("Don't save", "", func():
		App.library.discard_autosave(App.session.layout.id)
		get_tree().quit())
	m.add_button("Save", "Accent", func():
		if App.save_current(true) == OK:
			get_tree().quit()
		else:
			m.close())
