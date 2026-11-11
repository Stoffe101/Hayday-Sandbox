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
var underlay: SelectionUnderlay
var controller: EditorController
var exporter: Exporter
var plan_overlay: PlanOverlay
var plan_controller: PlanController

var ui_layer: CanvasLayer
var root: Control
var canvas_area: Control
var top_bar: TopBar
var catalog: CatalogPanel
var inspector: InspectorPanel
var dock: ToolDock
var layout_tools: LayoutToolController
var toasts: Toasts
var modal_layer: Control
var plan_panel: PlanPanel
var budget: BudgetWidget
var minimap: Minimap
var compare_legend: CompareLegend
## The minimap only shows where the free canvas is at least this big (logical px).
const MINIMAP_MIN_CANVAS := Vector2(700, 420)
var _compare_key := ""

var _left_visible := true             ## catalogue expanded (else collapsed to its rail)
var _right_visible := true            ## inspector shown when auto-hide is off
var _panels_hidden := false
## Side panels: margins, gaps and width limits (logical px).
const MARGIN := 12.0
const GAP := 8.0
const CATALOG_MIN := 240.0
const INSPECTOR_MIN := 280.0
## Auto-hiding inspector: pinned open by the user, or dismissed until what it
## would show changes (selection, landmark, brush, tab).
var _inspector_pinned := false
var _inspector_dismissed := false
var _inspector_need_sig := ""
var _catalog_grip: PanelGrip
var _inspector_grip: PanelGrip
var _plan_grip: PanelGrip
## Plan panel (docs/PLANNING.md): open in the inspector's place.
var _plan_open := false
const PLAN_MIN := 300.0
## Free canvas between the panels (logical px): where the budget widget sits.
var _canvas_rect := Rect2()
## Image exports asked for by the Plan tabs run one after another.
var _export_queue: Array = []
var _exporting := false
## Plan picture requests refused because they pointed into the program folder (tests read it).
var export_refused := 0
var _placeholder_lib: AssetLibrary
## Planning layers <-> settings keys.
const PLAN_LAYER_KEYS := {"plan_show_areas": "areas", "plan_show_progress": "progress", "plan_show_heatmap": "heatmap", "plan_show_guide": "guide"}
## Above this many objects with problems, the farm outlines only the selected
## ones; the grouped issues list (inspector, top bar) shows the rest.
const ISSUE_OUTLINE_MAX := 24
var _issue_levels: Dictionary = {}   ## uid -> severity of every object with a problem
var _diff: LayoutDiff.Result
var _view_state := {}
var _calib_world: Array = []
var _calib_points := 3
var _calib_grid: Array = []     ## grid-side clicks: CalibrationMath.snap_grid_point() results
var _calib_add := false         ## the clicks add one pair to the active image's calibration
var _ref_ui_sig := ""
var _ref_drag := false
var _ref_drag_last := Vector2.ZERO
var _layout_dirty_ui := true
var _last_title := ""
## Fixed landmarks: hovered id, the subtle "fixed in place" hint near the
## cursor (rate-limited), and the load-report dialog of the open layout.
var home_button: Button
var last_fixed_hint := ""
var fixed_hint_count := 0
var _hint_panel: PanelContainer
var _hint_label: Label
var _hint_tween: Tween
var _hint_times: Dictionary = {}     ## text -> ticks ms of the last time it was shown
const HINT_REPEAT_MS := 1500
var hint_hold_s := 1.8                ## how long the hint stays (visual tests raise it)
var _lm_hover := ""
var _reported_session: EditorSession
var _wired_session: EditorSession     ## session whose signals _connect_session() wired
var _suppress_open_toast := false
var _ref_drag_before: Dictionary = {}
var load_report_modal: Modal


func _ready() -> void:
	if not OS.get_cmdline_user_args().has("--capture"):
		get_tree().root.min_size = Vector2i(1024, 640)
	get_tree().set_auto_accept_quit(false)
	if not _handle_install_args():
		return
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
	_setup_layout_tools()
	App.notify.connect(_on_notify)
	App.session_changed.connect(_on_session_changed)
	App.assets_reloaded.connect(func():
		renderer.refresh_all_art()
		_refresh_pack_terrain()
		_refresh_world()
		overlay.refresh()
		catalog.refresh())
	App.map_changed.connect(_on_map_changed)
	App.art_changed.connect(_on_art_changed)
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
	if OS.get_cmdline_user_args().has("--smoke-plan"):
		_smoke_plan.call_deferred()


func _smoke_plan() -> void:
	## `-- --smoke-plan` (exported-build smoke test, tools/build/build.ps1): opens
	## every Plan tab and the three planning dialogs once, prints SMOKE-PLAN and
	## quits. Script errors in any of them show up in the log.
	for i in 10:
		await get_tree().process_frame
	var tabs := ["budget", "areas", "phases", "shop", "build", "guide", "accuracy"]
	for t in tabs:
		open_plan(t)
		for i in 3:
			await get_tree().process_frame
	_plan_inventory()
	await get_tree().process_frame
	var item := "bakery" if App.db.get_item("bakery") != null else str(App.db.items.keys()[0])
	_plan_price(item)
	await get_tree().process_frame
	_plan_baseline()
	for i in 5:
		await get_tree().process_frame
	print("SMOKE-PLAN OK tabs=%d dialogs=%d" % [tabs.size(), modal_layer.get_child_count()])
	get_tree().quit(0)


func _handle_install_args() -> bool:
	## `-- --install-pack=<zip>` installs an asset pack at startup and prints the
	## result; with `--quit-after-install` the app exits (status 0 = installed).
	## Returns false when the app is quitting.
	var args := OS.get_cmdline_user_args()
	var any := false
	var all_ok := true
	for a in args:
		if a.begins_with("--install-pack="):
			any = true
			var r := App.install_pack(a.substr(15))
			print("INSTALL-PACK %s" % r.summary())
			if r.ok:
				print("INSTALL-PACK DIR %s" % r.dir)
			all_ok = all_ok and r.ok
	if any and args.has("--quit-after-install"):
		get_tree().quit(0 if all_ok else 1)
		return false
	return true


func _on_notify(text: String, kind: String) -> void:
	# The load-report dialog replaces App's "Opened …" summary toast.
	if _suppress_open_toast and text.begins_with("Opened “"):
		_suppress_open_toast = false
		return
	toasts.show_toast(text, kind)


func _on_art_changed(keys: Array) -> void:
	renderer.refresh_art(keys)
	overlay.refresh()
	catalog.refresh_art(keys)
	inspector.queue_rebuild()


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
	ground.assets = App.assets   # pack terrain (docs/TERRAIN_PACKS.md)
	world.add_child(ground)
	scenery = SceneryLayer.new()
	world.add_child(scenery)
	reference = ReferenceLayer.new()
	reference.visibility_layer = Exporter.LAYER_OVERLAY
	world.add_child(reference)
	grid = GridOverlay.new()
	grid.visibility_layer = Exporter.LAYER_GRID
	world.add_child(grid)
	underlay = SelectionUnderlay.new()
	underlay.visibility_layer = Exporter.LAYER_OVERLAY
	world.add_child(underlay)
	# Planning marks: fills / heatmap under the objects, names / numbers above them.
	plan_overlay = PlanOverlay.new()
	plan_overlay.name = "PlanOverlay"
	plan_overlay.ctx = App.plan_ctx
	world.add_child(plan_overlay.under)
	renderer = ObjectRenderer.new()
	plan_overlay.renderer = renderer
	renderer.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[App.settings.ambient_animation()])
	ground.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[App.settings.ambient_animation()])
	world.add_child(renderer)
	# Pack terrain pieces with "layer": "foreground" draw over the objects (docs/TERRAIN_PACKS.md).
	ground.pack_layer().attach_foreground(world)
	world.add_child(plan_overlay)
	overlay = EditorOverlay.new()
	overlay.visibility_layer = Exporter.LAYER_OVERLAY
	world.add_child(overlay)
	overlay.underlay = underlay
	underlay.overlay = overlay
	camera = FarmCamera.new()
	camera.smooth = bool(App.settings.get_v("smooth_zoom"))
	camera.wheel_factor = float(App.settings.get_v("wheel_zoom_factor"))
	world.add_child(camera)
	camera.make_current()
	camera.view_changed.connect(_on_view_changed)
	ground.pack_layer().extent_changed.connect(_apply_world_bounds)   # camera bounds follow the pack terrain
	controller = EditorController.new()
	controller.camera = camera
	controller.renderer = renderer
	controller.overlay = overlay
	controller.ground = ground
	add_child(controller)
	exporter = Exporter.new()
	exporter.capturing.connect(renderer.finish_motion)   # lift / drop motion is never in a picture
	add_child(exporter)
	controller.status_changed.connect(func(t): dock.set_status(t))
	controller.request_text.connect(func(title, initial, cb): Modal.prompt(modal_layer, title, initial, cb))
	controller.request_context_menu.connect(_context_menu)
	controller.request_landmark_menu.connect(_landmark_menu)
	controller.calibration_point.connect(_on_calibration_point)
	controller.fixed_refused.connect(show_fixed_hint)
	controller.landmark_hovered.connect(_on_landmark_hovered)
	controller.area_created.connect(func(id: String): App.plan_ctx.set_active_area(id))
	plan_controller = PlanController.new()
	plan_controller.name = "PlanController"
	add_child(plan_controller)
	plan_controller.setup(App.plan_ctx, plan_overlay, controller)
	plan_controller.status.connect(func(t: String): dock.set_status(t))
	_wire_plan_context()


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
		controller.clear_hover()
		overlay.cursor_text = ""
		overlay.ghosts = [] if controller.session and controller.session.tool != "place" and not controller.stamp_mode else overlay.ghosts
		overlay.refresh())
	root.add_child(canvas_area)
	var m := MARGIN
	_left_visible = bool(App.settings.get_v("left_panel"))
	_right_visible = bool(App.settings.get_v("right_panel"))
	top_bar = TopBar.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_left = m
	top_bar.offset_right = -m
	top_bar.offset_top = m
	top_bar.action.connect(_on_top_action)
	top_bar.farm_level_set.connect(_set_farm_level)
	top_bar.plan_requested.connect(_on_plan_requested)
	root.add_child(top_bar)
	catalog = CatalogPanel.new()
	catalog.anchor_top = 0
	catalog.anchor_bottom = 1
	catalog.offset_left = m
	catalog.offset_top = 82
	catalog.offset_bottom = -m
	catalog.item_chosen.connect(_on_item_chosen)
	catalog.open_assets.connect(_open_asset_manager)
	catalog.farm_level_requested.connect(_set_farm_level)
	catalog.mode_requested.connect(func(m: String):
		_on_top_action("mode_creative" if m == FarmLayout.MODE_CREATIVE else "mode_realistic"))
	catalog.expand_requested.connect(set_catalog_expanded)
	root.add_child(catalog)
	inspector = InspectorPanel.new()
	inspector.anchor_left = 1
	inspector.anchor_right = 1
	inspector.anchor_bottom = 1
	inspector.offset_top = 82
	inspector.offset_bottom = -m
	inspector.offset_right = -m
	inspector.action.connect(_on_inspector_action)
	inspector.tab_switched.connect(_on_inspector_tab)
	inspector.renderer = renderer
	root.add_child(inspector)
	plan_panel = PlanPanel.new()
	plan_panel.anchor_left = 1
	plan_panel.anchor_right = 1
	plan_panel.anchor_bottom = 1
	plan_panel.offset_top = 82
	plan_panel.offset_bottom = -m
	plan_panel.offset_right = -m
	plan_panel.visible = false
	root.add_child(plan_panel)
	plan_panel.setup(App.plan_ctx)
	plan_panel.close_requested.connect(func(): set_plan_open(false))
	plan_panel.tab_changed.connect(func(id: String):
		App.settings.set_v("plan_tab", id)
		_sync_guide_marks()
		top_bar.set_plan_state(_plan_open, id))
	_catalog_grip = _make_grip("catalog_width")
	_inspector_grip = _make_grip("inspector_width")
	_plan_grip = _make_grip("plan_width")
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
	budget = BudgetWidget.new()
	budget.name = "Budget"
	root.add_child(budget)
	budget.setup(App.plan_ctx)
	budget.configure(str(App.settings.get_v("budget_corner")), bool(App.settings.get_v("budget_collapsed")), bool(App.settings.get_v("budget_expanded")))
	budget.open_tab.connect(open_plan)
	budget.layout_changed.connect(_place_budget)
	budget.setting.connect(func(k: String, v: Variant): App.settings.set_v(k, v))
	minimap = Minimap.new()
	minimap.name = "Minimap"
	minimap.visible = false
	root.add_child(minimap)
	minimap.set_collapsed(bool(App.settings.get_v("minimap_collapsed")))
	minimap.collapse_requested.connect(func(on: bool): App.settings.set_v("minimap_collapsed", on))
	minimap.hide_requested.connect(func(): _set_view("minimap_visible", false))
	minimap.navigate.connect(func(w: Vector2):
		camera.stop_motion()
		camera.center_on(w))
	compare_legend = CompareLegend.new()
	compare_legend.name = "CompareLegend"
	compare_legend.visible = false
	root.add_child(compare_legend)
	compare_legend.setup(App.plan_ctx)
	compare_legend.close_requested.connect(func(): App.plan_ctx.set_compare(false))
	toasts = Toasts.new()
	toasts.anchor_left = 1
	toasts.anchor_right = 1
	toasts.anchor_top = 1
	toasts.anchor_bottom = 1
	toasts.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	toasts.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(toasts)
	# Above the dock including its contextual rows (repeat, symmetry, …).
	dock.resized.connect(_place_toasts)
	dock.resized.connect(_on_dock_resized)
	dock.resized.connect(_place_budget)
	_build_hint()
	_add_home_button()
	modal_layer = Control.new()
	modal_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(modal_layer)
	_layout_panels()


func _add_home_button() -> void:
	## "Home" (farmhouse) next to the dock's fit button; a small floating
	## button if the dock layout ever changes.
	home_button = UI.icon_button("house", "Home: centre the farmhouse (Home / Shift+H)", "Ghost")
	home_button.pressed.connect(go_home)
	var fit := _find_button(dock, "Fit farm")
	if fit:
		fit.tooltip_text = "Fit farm (F)"
		fit.get_parent().add_child(home_button)
		fit.get_parent().move_child(home_button, fit.get_index() + 1)
	else:
		home_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
		home_button.position += Vector2(20, -150)
		root.add_child(home_button)


static func _find_button(n: Node, tip_prefix: String) -> Button:
	for c in n.get_children():
		if c is Button and (c as Button).tooltip_text.begins_with(tip_prefix):
			return c
		var r := _find_button(c, tip_prefix)
		if r:
			return r
	return null


func _build_hint() -> void:
	## The small "fixed in place" note shown near the cursor.
	_hint_panel = PanelContainer.new()
	_hint_panel.theme_type_variation = "Toast"
	_hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_panel.visible = false
	var h := UI.hbox(8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_panel.add_child(h)
	h.add_child(UI.icon_rect("lock", 16, UiTheme.c("text_dim")))
	_hint_label = UI.label("", "Dim")
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size.x = 220
	h.add_child(_hint_label)
	root.add_child(_hint_panel)


func show_fixed_hint(text: String, screen_pos: Vector2 = Vector2(-1, -1)) -> void:
	## Subtle, rate-limited note near the cursor (fixed landmarks, obstacles):
	## the same text at most once per HINT_REPEAT_MS.
	if text.is_empty() or _hint_panel == null:
		return
	var now := Time.get_ticks_msec()
	if _hint_times.has(text) and now - int(_hint_times[text]) < HINT_REPEAT_MS and _hint_panel.visible:
		return
	_hint_times[text] = now
	last_fixed_hint = text
	fixed_hint_count += 1
	if screen_pos.x < 0:
		screen_pos = canvas_area.get_local_mouse_position() if canvas_area else Vector2(200, 200)
	_hint_label.text = text
	_hint_label.custom_minimum_size.x = clampf(text.length() * 7.0, 160.0, 340.0)
	_hint_panel.reset_size()
	var vs := root.get_viewport_rect().size
	var sz := _hint_panel.get_combined_minimum_size()
	var at := screen_pos + Vector2(18, 20)
	at.x = clampf(at.x, 8.0, maxf(8.0, vs.x - sz.x - 8.0))
	at.y = clampf(at.y, 8.0, maxf(8.0, vs.y - sz.y - 8.0))
	_hint_panel.position = at
	_hint_panel.visible = true
	_hint_panel.modulate.a = 0.0
	if _hint_tween:
		_hint_tween.kill()
	_hint_tween = create_tween()
	_hint_tween.tween_property(_hint_panel, "modulate:a", 1.0, 0.12)
	_hint_tween.tween_interval(hint_hold_s)
	_hint_tween.tween_property(_hint_panel, "modulate:a", 0.0, 0.4)
	_hint_tween.tween_callback(func(): _hint_panel.visible = false)


func _fixed_refusal(action: String) -> bool:
	## A landmark is selected: object edits don't apply to it. Shows the hint
	## and returns true (the caller then does nothing).
	var s := App.session
	if s == null or s.selected_landmark.is_empty():
		return false
	show_fixed_hint(s.explain_fixed(s.selected_landmark, action))
	return true


func catalog_width(win_w: float) -> float:
	## Expanded catalogue width: the remembered one (settings), else ~17.5 % of the window.
	var saved := float(App.settings.get_v("catalog_width"))
	var auto := clampf(win_w * 0.175, 272.0, 380.0)
	return clampf(saved if saved > 0.0 else auto, CATALOG_MIN, _side_max(win_w, CATALOG_MIN))


func inspector_width(win_w: float) -> float:
	var saved := float(App.settings.get_v("inspector_width"))
	var auto := clampf(win_w * 0.19, 296.0, 400.0)
	return clampf(saved if saved > 0.0 else auto, INSPECTOR_MIN, _side_max(win_w, INSPECTOR_MIN))


static func _side_max(win_w: float, lo: float) -> float:
	return maxf(lo, minf(640.0, win_w * 0.36))


func _inspector_needed() -> bool:
	## Something for the inspector to show: a selection, a landmark, the brush,
	## a tab the user opened (Farm / View), screenshot alignment.
	var s := App.session
	if s == null or inspector == null:
		return false
	if inspector.current_tab() != 0:
		return true
	if not s.selection.is_empty() or not s.selected_landmark.is_empty():
		return true
	if s.tool == "place" and not s.active_item.is_empty():
		return true
	return _ref_drag or (controller != null and controller.calibrating)


func _inspector_need_key() -> String:
	var s := App.session
	if s == null or inspector == null:
		return ""
	return "%d|%d|%s|%s|%d" % [s.selection.size(), s.selection.hash(), s.selected_landmark,
		s.active_item if s.tool == "place" else "", inspector.current_tab()]


func inspector_shown() -> bool:
	## Whether the inspector is on screen. With auto-hide (default) it appears
	## when something needs it, unless the user closed it for that thing, or
	## stays when the user opened it (top bar / ]).
	if _panels_hidden or inspector == null or _plan_open:
		return false
	if not bool(App.settings.get_v("inspector_auto_hide")):
		return _right_visible
	var key := _inspector_need_key()
	if key != _inspector_need_sig:
		_inspector_need_sig = key
		_inspector_dismissed = false
	return _inspector_pinned or (_inspector_needed() and not _inspector_dismissed)


func toggle_inspector() -> void:
	if _plan_open:
		# ] while planning: back to the inspector.
		set_plan_open(false)
		if not inspector_shown():
			_inspector_pinned = true
			_inspector_dismissed = false
		_update_view_rect()
		return
	if not bool(App.settings.get_v("inspector_auto_hide")):
		_right_visible = not _right_visible
		App.settings.set_v("right_panel", _right_visible)
	elif inspector_shown():
		_inspector_pinned = false
		if inspector.current_tab() != 0:
			inspector.show_tab(0)
		_inspector_need_sig = _inspector_need_key()
		_inspector_dismissed = true
	else:
		_inspector_pinned = true
		_inspector_dismissed = false
	_update_view_rect()


func set_catalog_expanded(on: bool) -> void:
	## Expanded catalogue, or collapsed to its category rail (remembered).
	if _left_visible != on:
		_left_visible = on
		App.settings.set_v("left_panel", on)
	_update_view_rect()


func _on_inspector_tab(i: int) -> void:
	if i != 0:
		_inspector_dismissed = false
	_update_view_rect()


func _make_grip(setting: String) -> PanelGrip:
	## Drag handle on a side panel's inner edge; the width follows the pointer
	## and is remembered when the drag ends (double-click: automatic width).
	var g := PanelGrip.new()
	g.anchor_top = 0
	g.anchor_bottom = 1
	g.dragged.connect(func(_dx: float):
		var vs := root.get_viewport_rect().size
		var x := root.get_local_mouse_position().x
		var w := (x - MARGIN) if setting == "catalog_width" else (vs.x - MARGIN - x)
		var lo := CATALOG_MIN if setting == "catalog_width" else (PLAN_MIN if setting == "plan_width" else INSPECTOR_MIN)
		App.settings.set_v(setting, roundf(clampf(w, lo, _side_max(vs.x, lo))), false)
		_update_view_rect())
	g.released.connect(func(): App.settings.save_settings())
	g.reset.connect(func():
		App.settings.set_v(setting, 0.0)
		_update_view_rect())
	root.add_child(g)
	return g


func _layout_panels() -> void:
	var vs := root.get_viewport_rect().size
	var m := MARGIN
	top_bar.visible = not _panels_hidden
	# Narrow window / big UI scale: drop the brand, then shorten the mode switch.
	top_bar.fit_width(vs.x - 2.0 * m)
	var top := m + top_bar.get_combined_minimum_size().y + GAP if top_bar.visible else m
	catalog.visible = not _panels_hidden
	var shown := inspector_shown()
	var plan_shown := _plan_open and not _panels_hidden
	var iw := inspector_width(vs.x)
	var pw := plan_width(vs.x)
	# The right-hand slot: the Plan panel while it is open, else the inspector.
	var rw := pw if plan_shown else iw
	var right_open := shown or plan_shown
	# Very narrow (e.g. 1080p at 200 %): while the inspector is open the
	# catalogue shows only its rail, without changing the remembered state.
	var expanded := _left_visible
	if expanded and right_open and vs.x - 2.0 * m - catalog_width(vs.x) - rw - 2.0 * GAP < dock.pill_width(true) + 16.0:
		expanded = false
	catalog.set_collapsed(not expanded)
	var cw := catalog_width(vs.x) if expanded else catalog.rail_width()
	catalog.offset_left = m
	catalog.offset_right = m + cw
	catalog.offset_top = top
	catalog.offset_bottom = -m
	inspector.visible = shown
	inspector.offset_left = -m - iw
	inspector.offset_right = -m
	inspector.offset_top = top
	inspector.offset_bottom = -m
	_catalog_grip.visible = catalog.visible and expanded
	_catalog_grip.offset_left = catalog.offset_right - 4.0
	_catalog_grip.offset_right = catalog.offset_right + 4.0
	_catalog_grip.offset_top = top + 16.0
	_catalog_grip.offset_bottom = -m - 16.0
	_inspector_grip.visible = shown
	_inspector_grip.anchor_left = 1
	_inspector_grip.anchor_right = 1
	_inspector_grip.offset_left = inspector.offset_left - 4.0
	_inspector_grip.offset_right = inspector.offset_left + 4.0
	_inspector_grip.offset_top = top + 16.0
	_inspector_grip.offset_bottom = -m - 16.0
	plan_panel.visible = plan_shown
	plan_panel.set_compact(pw < 400.0)
	plan_panel.offset_left = -m - pw
	plan_panel.offset_right = -m
	plan_panel.offset_top = top
	plan_panel.offset_bottom = -m
	_plan_grip.visible = plan_shown
	_plan_grip.anchor_left = 1
	_plan_grip.anchor_right = 1
	_plan_grip.offset_left = plan_panel.offset_left - 4.0
	_plan_grip.offset_right = plan_panel.offset_left + 4.0
	_plan_grip.offset_top = top + 16.0
	_plan_grip.offset_bottom = -m - 16.0
	var left_edge := (catalog.offset_right + GAP) if catalog.visible else m
	var right_edge := (rw + m + GAP) if right_open else m
	# Judged with the inspector open, so the dock doesn't change as it comes and goes.
	var between := vs.x - left_edge - (rw + m + GAP)
	dock.set_compact(between < dock.pill_width(false) + 16.0)
	# Too narrow even for the compact dock (small window, big UI scale): the
	# panels end above it and the dock spans the window.
	var narrow := between < dock.pill_width(true) + 16.0
	# Narrow: the dock spans the window, and so do its contextual rows (selection
	# tools, symmetry, repeat): the side panels end above all of it, so those
	# rows never cover the inspector's buttons (1080p at 200 %).
	_dock_narrow_h = maxf(dock.pill_height(), dock.get_combined_minimum_size().y) if narrow else 0.0
	var bottom := -(m + _dock_narrow_h + GAP) if narrow else -m
	catalog.offset_bottom = bottom
	inspector.offset_bottom = bottom
	plan_panel.offset_bottom = bottom
	_catalog_grip.offset_bottom = bottom - 16.0
	_inspector_grip.offset_bottom = bottom - 16.0
	_plan_grip.offset_bottom = bottom - 16.0
	dock.offset_left = m if narrow else left_edge
	dock.offset_right = -m if narrow else -right_edge
	dock.offset_bottom = -m
	_fit_stamps_panel(vs, top, left_edge, right_edge)
	toasts.offset_right = -right_edge
	toasts.offset_left = toasts.offset_right - minf(360.0, vs.x - left_edge - right_edge)
	_place_toasts()
	top_bar.set_panels(_left_visible, shown, bool(App.settings.get_v("inspector_auto_hide")))
	top_bar.set_plan_state(_plan_open, plan_panel.current)
	var canvas_bottom := vs.y - (m + dock.pill_height() + GAP)
	_canvas_rect = Rect2(Vector2(left_edge, top), Vector2(maxf(1.0, vs.x - right_edge - left_edge), maxf(1.0, canvas_bottom - top)))
	_place_budget()


var _dock_narrow_h := 0.0


func _on_dock_resized() -> void:
	## The dock grew or shrank (contextual rows): in the narrow layout the side
	## panels follow its height (once per change; no layout loop).
	if _dock_narrow_h <= 0.0 or dock == null:
		return
	var h := maxf(dock.pill_height(), dock.get_combined_minimum_size().y)
	if not is_equal_approx(h, _dock_narrow_h):
		_update_view_rect.call_deferred()


func plan_width(win_w: float) -> float:
	var saved := float(App.settings.get_v("plan_width"))
	var auto := clampf(win_w * 0.22, 340.0, 440.0)
	return clampf(saved if saved > 0.0 else auto, PLAN_MIN, _side_max(win_w, PLAN_MIN))


func _place_budget() -> void:
	## The budget chip in its corner of the free canvas (above the tool pill at the bottom).
	if budget == null or not is_instance_valid(budget):
		return
	budget.visible = bool(App.settings.get_v("budget_visible")) and not _panels_hidden and App.session != null
	_place_overlays()
	if not budget.visible:
		return
	budget.set_tight(_canvas_rect.size.x < 760.0 or _canvas_rect.size.y < 460.0)
	budget.reset_size()
	var sz := budget.get_combined_minimum_size()
	budget.size = sz
	budget.position = PlanScope.corner_position(budget.corner, _budget_rect(), sz, 0.0)
	# Wrapped text in the breakdown only knows its height once it has a width:
	# settle once more after the layout pass.
	if not _budget_settle:
		_budget_settle = true
		get_tree().process_frame.connect(_settle_budget, CONNECT_ONE_SHOT)


var _budget_settle := false


func _settle_budget() -> void:
	_budget_settle = false
	if budget == null or not is_instance_valid(budget) or not budget.visible:
		return
	budget.reset_size()
	var sz := budget.get_combined_minimum_size()
	budget.size = sz
	budget.position = PlanScope.corner_position(budget.corner, _budget_rect(), sz, 0.0)
	_place_overlays()


func minimap_room() -> bool:
	## The free canvas is big enough for the overview without crowding the farm
	## (e.g. not at 1920×1080 with 200 % UI scale).
	return _canvas_rect.size.x >= MINIMAP_MIN_CANVAS.x and _canvas_rect.size.y >= MINIMAP_MIN_CANVAS.y


func minimap_shown() -> bool:
	return minimap != null and is_instance_valid(minimap) and minimap.visible


func _place_overlays() -> void:
	## The overview map and the compare legend in the top corners of the free
	## canvas that the budget chip doesn't use (the legend stacks under the map
	## when both top corners are taken).
	if minimap == null or not is_instance_valid(minimap):
		return
	var r := _budget_rect()
	var chip_corner := budget.corner if budget != null and is_instance_valid(budget) and budget.visible else ""
	var mm_corner := "tl" if chip_corner == "tr" else "tr"
	var want := bool(App.settings.get_v("minimap_visible")) and not _panels_hidden and App.session != null and minimap_room()
	_view_state["minimap_no_room"] = not minimap_room()
	var was := minimap.visible
	minimap.visible = want
	var mm_rect := Rect2()
	if want:
		if not was:
			minimap.sync()
		minimap.set_map_width(clampf(r.size.x * 0.2, 180.0, 260.0))
		minimap.reset_size()
		var sz := minimap.get_combined_minimum_size()
		minimap.size = sz
		minimap.position = PlanScope.corner_position(mm_corner, r, sz, 0.0)
		mm_rect = Rect2(minimap.position, sz)
		if not was:
			minimap.set_view_rect(camera.visible_world_rect())
			minimap.queue_redraw()
	if compare_legend == null or not is_instance_valid(compare_legend):
		return
	var ctx := App.plan_ctx
	compare_legend.visible = ctx.compare and ctx.has_baseline() and not _panels_hidden and App.session != null
	if not compare_legend.visible:
		return
	compare_legend.set_tight(r.size.x < 760.0 or r.size.y < 460.0)
	compare_legend.refresh()
	compare_legend.reset_size()
	var ls := compare_legend.get_combined_minimum_size()
	compare_legend.size = ls
	var free_top := ""
	for c in ["tl", "tr"]:
		if c != chip_corner and not (want and c == mm_corner):
			free_top = c
			break
	if not free_top.is_empty():
		compare_legend.position = PlanScope.corner_position(free_top, r, ls, 0.0)
	else:
		# Both top corners taken: right under the overview map.
		var below := Rect2(Vector2(r.position.x, mm_rect.end.y + GAP), Vector2(r.size.x, maxf(1.0, r.end.y - mm_rect.end.y - GAP)))
		compare_legend.position = PlanScope.corner_position(mm_corner, below, ls, 0.0)


func _budget_rect() -> Rect2:
	## Free canvas for the chip: at the bottom it stays above the whole dock
	## (status line and contextual rows such as the selection tools).
	var r := _canvas_rect
	if dock != null and is_instance_valid(dock):
		var vs := root.get_viewport_rect().size
		var bottom := vs.y - (MARGIN + maxf(dock.pill_height(), dock.get_combined_minimum_size().y) + 2.0)
		r.size.y = maxf(1.0, minf(r.end.y, bottom) - r.position.y)
	return r


func _fit_stamps_panel(vs: Vector2, top: float, left_edge: float, right_edge: float) -> void:
	## The stamps panel (LayoutToolController) floats at the top of the canvas,
	## centred between the side panels and never wider or taller than it.
	var sp: Control = layout_tools.panel if layout_tools != null and is_instance_valid(layout_tools.panel) else null
	if sp == null:
		return
	var w := clampf(vs.x - left_edge - right_edge - 16.0, 200.0, 540.0)
	var cx := (left_edge + vs.x - right_edge) * 0.5 - vs.x * 0.5   # the panel is anchored at the window's centre
	sp.offset_left = cx - w * 0.5
	sp.offset_right = cx + w * 0.5
	sp.offset_top = top
	sp.offset_bottom = top + clampf(vs.y - top - dock.pill_height() - 140.0, 160.0, 310.0)


func _raise_toasts() -> void:
	## Toasts above the floating panels (stamps), below dialogs.
	# move_child() removes first: with toasts before the modal layer this lands
	# them right below it.
	if toasts.get_index() < modal_layer.get_index():
		root.move_child(toasts, modal_layer.get_index() - 1)


func _place_toasts() -> void:
	if toasts == null or dock == null:
		return
	toasts.offset_bottom = -(MARGIN + maxf(dock.size.y, dock.pill_height()) + 10.0)
	toasts.offset_top = toasts.offset_bottom - 300.0


func _update_view_rect() -> void:
	## The canvas the camera treats as unobstructed: between the side panels,
	## under the top bar and above the tool pill (the dock's status line and
	## contextual rows float over the farm).
	if root == null or not is_instance_valid(root) or root.is_queued_for_deletion():
		return   # mid UI rebuild (a UI scale change resizes the window first): _rebuild_ui() calls it again
	_layout_panels()
	var vs := root.get_viewport_rect().size
	var l := (catalog.offset_right + 4.0) if catalog.visible else 0.0
	var r := (-inspector.offset_left + 4.0) if inspector.visible else 0.0
	if plan_panel.visible:
		r = -plan_panel.offset_left + 4.0
	var t := (MARGIN + top_bar.get_combined_minimum_size().y + 4.0) if top_bar.visible else 0.0
	var b := MARGIN + dock.pill_height() + 4.0
	camera.view_rect = Rect2(Vector2(l, t), Vector2(maxf(1.0, vs.x - l - r), maxf(1.0, vs.y - t - b)))


func canvas_share() -> float:
	## Fraction of the window the unobstructed canvas covers (view_rect).
	var vs := root.get_viewport_rect().size
	return camera.view_rect.get_area() / maxf(1.0, vs.x * vs.y)


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
	if minimap != null and is_instance_valid(minimap):
		minimap.unbind_signals()
	if compare_legend != null and is_instance_valid(compare_legend) and App.plan_ctx.changed.is_connected(compare_legend.refresh):
		App.plan_ctx.changed.disconnect(compare_legend.refresh)
	ui_layer.queue_free()
	await get_tree().process_frame
	_apply_ui_scale()
	_build_ui()
	layout_tools.attach_ui(dock, root, modal_layer)   # the old dock and stamps panel were freed
	_raise_toasts()
	_on_session_changed()
	if _plan_open:
		plan_panel.open(str(App.settings.get_v("plan_tab")))
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
	_apply_world_bounds()
	ground.hide_locked = bool(_view_state.get("hide_locked", false))
	grid.setup(s.map, s.layout, s.db)
	grid.show_grid = bool(App.settings.get_v("show_grid"))
	grid.show_occupancy = bool(App.settings.get_v("show_occupancy"))
	renderer.show_shadows = bool(App.settings.get_v("show_shadows"))
	renderer.set_layer_states(ObjectLayers.normalize(App.settings.get_v("object_layers")))
	renderer.bind(s.layout, s.db, App.assets)
	_compare_key = ""
	_sync_compare()
	minimap.bind(s.layout, s.map, s.db, App.plan_ctx, renderer)
	_lm_hover = ""
	_refresh_world()
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
	layout_tools.bind(s)
	plan_controller.cancel()
	plan_overlay.highlight_uids = []
	plan_overlay.zoom = camera.zoom.x
	plan_overlay.refresh()
	_load_reference()
	# Once per session: _rebuild_ui() runs this function again for the same
	# session, and the lambdas below would otherwise be connected twice.
	if _wired_session != s:
		_wired_session = s
		_connect_session(s)
	_on_tool_changed()
	_on_history_changed()
	_refresh_level_blocks()
	_on_landmark_selected(s.selected_landmark)
	inspector.view_state = _view_state
	inspector.rebuild()
	catalog.refresh()
	_update_title()
	_maybe_report_load(s)


func _connect_session(s: EditorSession) -> void:
	## The session's and its layout's signals -> UI. The lambdas read App.session
	## instead of capturing `s`: a session whose own signal holds a lambda that
	## references it would never be freed after switching layouts.
	s.selection_changed.connect(_on_selection_changed)
	s.tool_changed.connect(_on_tool_changed)
	s.history_changed.connect(_on_history_changed)
	s.active_item_changed.connect(func():
		catalog.select_item(App.session.active_item)
		inspector.queue_rebuild()
		_update_view_rect())
	s.message.connect(func(t, k): toasts.show_toast(t, k))
	s.mode_changed.connect(func():
		_refresh_issues()
		_refresh_level_blocks()
		inspector.queue_rebuild()
		top_bar.update_state(App.session)
		catalog.on_level_context_changed())
	s.layout.land_changed.connect(func():
		ground.setup(App.session.map, App.session.layout.unlocked_plots)
		_refresh_level_blocks()
		grid.queue_redraw())
	if not s.layout.world_changed.is_connected(_on_world_changed):
		s.layout.world_changed.connect(_on_world_changed)
	if not s.landmark_selected.is_connected(_on_landmark_selected):
		s.landmark_selected.connect(_on_landmark_selected)
	s.layout.annotations_changed.connect(overlay.refresh)
	s.layout.meta_changed.connect(func():
		top_bar.update_state(App.session)
		_update_title())
	s.layout.reference_changed.connect(_on_reference_changed)
	s.layout.planning_changed.connect(func():
		_refresh_issues()
		_refresh_level_blocks()
		inspector.queue_rebuild()
		catalog.on_level_context_changed())


# ---------------------------------------------------------------------------
# World layer: landmarks, bounds, home, season
# ---------------------------------------------------------------------------

func _refresh_world() -> void:
	## (Re)builds the renderer's world entries for every landmark of the open
	## world, in the look this layout gives them (theme, state, skin, visibility).
	var s := App.session
	if s == null:
		return
	ground.set_theme(s.layout.theme())
	renderer.refresh_theme()
	renderer.set_world_entries(LandmarkView.entries_for(s.map, s.layout, App.assets, _landmark_tints()))
	_update_landmark_overlay()


func _landmark_tints() -> Dictionary:
	var out := {}
	var s := App.session
	if not _lm_hover.is_empty():
		out[_lm_hover] = Color(1.12, 1.12, 1.08)
	if s and not s.selected_landmark.is_empty():
		out[s.selected_landmark] = Color(1.16, 1.12, 1.0)
	return out


func _on_world_changed(_keys: Array) -> void:
	_refresh_world()
	inspector.queue_rebuild()


func _on_map_changed() -> void:
	## A private world pack was installed / removed: new ground, scenery,
	## landmarks and camera bounds (the open layout itself is unchanged).
	var s := App.session
	if s == null:
		return
	ground.setup(s.map, s.layout.unlocked_plots)
	scenery.setup(s.map, App.assets, s.db)
	grid.setup(s.map, s.layout, s.db)
	_apply_world_bounds()
	_refresh_world()
	_refresh_level_blocks()
	_refresh_issues()
	minimap.bind(s.layout, s.map, s.db, App.plan_ctx, renderer)
	controller.refresh_hover()
	inspector.queue_rebuild()


func world_rect_px(m: FarmMap) -> Rect2:
	var wb := m.world_bounds if m.world_bounds.size != Vector2i.ZERO else Rect2i(Vector2i.ZERO, m.size)
	var r := Iso.footprint_world_bounds(wb.position, wb.size)
	# Pack terrain: framed by its pieces (PackTerrainLayer.camera_rect).
	return ground.pack_layer().camera_rect(m, r) if ground else r


func _apply_world_bounds() -> void:
	var s := App.session
	if s == null:
		return
	camera.home = Iso.grid_to_world(LandmarkView.home_tile_point(s.map))
	camera.set_world_bounds(world_rect_px(s.map))


func go_home() -> void:
	## Home: the farmhouse (or the starting land's centre) at 100 %.
	if App.session == null:
		return
	_update_view_rect()
	camera.fly_home()
	dock.set_status("Home")


func _selection_world_rect(s: EditorSession) -> Rect2:
	## World rectangle around the selected objects' or landmark's art and
	## footprints (size 0 = nothing selected).
	var r := Rect2()
	for o: PlacedObject in s.selected_objects():
		var b := Iso.footprint_world_bounds(o.origin, o.size)
		if renderer.bounds_of(o.uid).size != Vector2.ZERO:
			b = b.merge(renderer.bounds_of(o.uid))
		r = r.merge(b) if r.size != Vector2.ZERO else b
	var lm: Landmark = s.selected_landmark_def()
	if lm:
		var b := Iso.footprint_world_bounds(lm.origin, lm.footprint)
		var art := renderer.world_entry_bounds(LandmarkView.key_of(lm.id))
		r = b.merge(art) if art.size != Vector2.ZERO else b
	return r


func _fit_selection_or_farm() -> void:
	## F: fly to the selection, or to the farm when nothing is selected.
	var s := App.session
	if s == null:
		return
	_update_view_rect()
	var r := _selection_world_rect(s)
	if r.size == Vector2.ZERO:
		camera.fly_to_rect(Exporter.farm_world_rect(s.map, s.layout, "unlocked"), 20.0)
	else:
		camera.fly_to_rect(r, 90.0, 1.6)


func _fit_world() -> void:
	## Shift+F: the whole world.
	var s := App.session
	if s == null:
		return
	_update_view_rect()
	camera.fly_to_rect(world_rect_px(s.map), 20.0)


func _bookmark_key(k: InputEventKey, ctrl: bool) -> void:
	## Ctrl+1..9 saves the view in layout.camera.bookmarks (undoable), 1..9 flies to it.
	var s := App.session
	var slot := str(int(k.keycode) - int(KEY_0))
	if ctrl:
		var c := camera.settled_view_center()
		s.execute(EditCommands.SetCameraBookmark.new(slot, {"x": c.x, "y": c.y, "zoom": camera.target_zoom}))
		App.toast("View %s saved" % slot, "info")
		return
	var marks: Variant = s.layout.camera.get("bookmarks", {})
	var b: Variant = marks.get(slot) if marks is Dictionary else null
	if not b is Dictionary:
		App.toast("No saved view %s yet — Ctrl+%s saves one" % [slot, slot], "info")
		return
	_update_view_rect()
	camera.fly_to(Vector2(float(b.get("x", 0.0)), float(b.get("y", 0.0))), float(b.get("zoom", camera.target_zoom)))
	dock.set_status("View %s" % slot)


func _on_landmark_hovered(id: String) -> void:
	var old := _lm_hover
	_lm_hover = id
	var s := App.session
	if s == null:
		return
	for lid in [old, id]:
		if lid.is_empty():
			continue
		var tint: Color = _landmark_tints().get(lid, Color.WHITE)
		renderer.update_world_entry(LandmarkView.key_of(lid), {"tint": tint})


func _on_landmark_selected(id: String) -> void:
	var s := App.session
	if s == null:
		return
	_update_landmark_overlay()
	for lm in s.map.landmarks:
		var key := LandmarkView.key_of(lm.id)
		var want: Color = _landmark_tints().get(lm.id, Color.WHITE)
		var cur: Variant = renderer.world_entry(key).get("tint", Color.WHITE)
		if cur != want:
			renderer.update_world_entry(key, {"tint": want})
	if not id.is_empty():
		overlay.selection = []
		if inspector.current_tab() != 0:
			inspector.show_tab(0)
	inspector.queue_rebuild()
	_update_view_rect()


func _update_landmark_overlay() -> void:
	var s := App.session
	var lm: Landmark = s.selected_landmark_def() if s else null
	overlay.landmark_selected = lm.rect() if lm else Rect2i()
	overlay.landmark_name = lm.name if lm else ""
	overlay.landmark_bounds = renderer.world_entry_bounds(LandmarkView.key_of(lm.id)) if lm else Rect2()
	var hl: Landmark = s.map.landmark(_lm_hover) if s and not _lm_hover.is_empty() else null
	overlay.landmark_hover = hl.rect() if hl else Rect2i()
	overlay.refresh()


func focus_landmark(id: String) -> void:
	var s := App.session
	var lm: Landmark = s.map.landmark(id) if s else null
	if lm == null:
		return
	s.select_landmark(id)
	camera.fly_to(Iso.footprint_center(lm.origin, lm.footprint))


func _refresh_level_blocks() -> void:
	## Realistic mode: locked plots the farm level can't unlock yet are drawn
	## darker with their level (the land tool refuses them).
	var s := App.session
	if s == null:
		return
	var out := {}
	if s.layout.mode == FarmLayout.MODE_REALISTIC:
		var lvl := RealisticAnalyzer.farm_level(s.layout)
		for p in s.map.plots:
			var pid := str(p["id"])
			if s.map.is_plot_unlocked(pid, s.layout.unlocked_plots):
				continue
			var ml := RealisticAnalyzer.plot_required_level(s.map, pid)
			if ml > lvl:
				out[pid] = ml
	ground.set_level_blocked(out)


func set_theme(theme_id: String) -> void:
	var s := App.session
	if s == null:
		return
	if not theme_id in LandmarkView.themes_with_art(s.map, App.assets):
		App.toast("No art for the %s season is installed" % LandmarkView.theme_name(theme_id), "info")
		return
	s.set_theme(theme_id)


# ---------------------------------------------------------------------------
# Load report (migrated / corrected layouts)
# ---------------------------------------------------------------------------

func _maybe_report_load(s: EditorSession) -> void:
	## Once per opened layout: a compact dialog when the file was upgraded or
	## objects were changed / need a look; small reports stay a toast (App).
	if s == _reported_session:
		return
	_reported_session = s
	var rep := s.load_report
	if rep == null or not Dialogs.load_report_needs_dialog(rep) or _is_automation():
		return
	_suppress_open_toast = true
	call_deferred("show_load_report", rep)


func show_load_report(rep: LayoutIO.LoadReport) -> Modal:
	_suppress_open_toast = false
	var s := App.session
	if s == null or rep == null:
		return null
	if is_instance_valid(load_report_modal):
		load_report_modal.close()
	load_report_modal = Dialogs.load_report(modal_layer, rep, s.layout, s.db, s.map, show_object)
	return load_report_modal


func show_object(uid: int) -> void:
	## Centre the camera on an object and select it (load report "Show").
	var s := App.session
	var o := s.layout.get_obj(uid) if s else null
	if o == null:
		return
	s.select([uid], false, false)
	camera.fly_to(Iso.footprint_center(o.origin, o.size))


func _fit_or_restore() -> void:
	_update_view_rect()
	var s := App.session
	if s and s.layout.camera.has("x"):
		camera.zoom = Vector2.ONE * float(s.layout.camera.get("zoom", 1.0))
		camera.target_zoom = camera.zoom.x
		camera.position = Vector2(float(s.layout.camera["x"]), float(s.layout.camera["y"]))
		camera.force_update_scroll()
		camera.set_world_bounds(world_rect_px(s.map))
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
	if _issue_levels.size() > ISSUE_OUTLINE_MAX:
		_apply_issue_marks()
	overlay.refresh()
	if inspector.current_tab() != 0 and not App.session.selection.is_empty():
		inspector.show_tab(0)
	inspector.queue_rebuild()
	_update_view_rect()


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
	_update_view_rect()


func _on_history_changed() -> void:
	top_bar.update_state(App.session)
	_refresh_issues()
	inspector.queue_rebuild()
	_update_title()


## Placement conflict -> short reason, most telling first.
const CONFLICT_REASONS := [
	[PlacementRules.LANDMARK, "On a fixed landmark"], [PlacementRules.WATER_DECO_ZONE, "Outside the river's decoration zones"],
	[PlacementRules.OCCUPIED, "Overlaps another object"],
	[PlacementRules.OUT_OF_BOUNDS, "Outside the farm"], [PlacementRules.ROAD, "On the road"],
	[PlacementRules.WATER, "In the water"], [PlacementRules.BLOCKED, "On blocked ground"],
	[PlacementRules.LOCKED_LAND, "On locked land"], [PlacementRules.NOT_PLACEABLE, "Can't be placed here"],
]


static func _conflict_reason(res: PlacementRules.Result) -> String:
	if res == null:
		return "Invalid placement"
	for e in CONFLICT_REASONS:
		if res.codes.has(e[0]):
			return e[1]
	return "Invalid placement"


func _refresh_issues() -> void:
	## Every object with a problem, grouped by reason for the issues list. A few
	## are outlined on the farm; many are only listed (and outlined once selected).
	var s := App.session
	var issues := {}
	var groups := {}
	var conflicts := s.conflicts()
	for u in conflicts:
		issues[u] = 2
		_issue_group(groups, _conflict_reason(conflicts[u]), 2, u)
	if s.layout.mode == FarmLayout.MODE_REALISTIC:
		var r := s.analysis()
		for u in r.issues:
			var sev := 0
			for c in r.issues[u]:
				var cs: int = RealisticAnalyzer.SEVERITY.get(c, 0)
				sev = maxi(sev, cs)
				if cs > 0 and c != RealisticAnalyzer.PLACEMENT:
					_issue_group(groups, RealisticAnalyzer.issue_text(c), cs, u)
			if sev > 0:
				issues[u] = maxi(issues.get(u, 0), sev)
	_issue_levels = issues
	var list: Array = groups.values()
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["severity"] != b["severity"]:
			return a["severity"] > b["severity"]
		return (a["uids"] as Array).size() > (b["uids"] as Array).size())
	_view_state["issues"] = list
	_view_state["issues_condensed"] = issues.size() > ISSUE_OUTLINE_MAX
	var blocking := 0
	var tip := PackedStringArray()
	for g: Dictionary in list:
		tip.append("%s × %s" % [UI.fmt_int((g["uids"] as Array).size()), g["label"]])
	for u in issues:
		blocking += 1 if issues[u] >= 2 else 0
	top_bar.set_issues(blocking, "Objects with problems — click for the list\n" + "\n".join(tip.slice(0, 8)))
	top_bar.fit_width(root.get_viewport_rect().size.x - 2.0 * MARGIN)
	_apply_issue_marks()


static func _issue_group(groups: Dictionary, label: String, severity: int, uid: int) -> void:
	if not groups.has(label):
		groups[label] = {"label": label, "severity": severity, "uids": []}
	(groups[label]["uids"] as Array).append(uid)


func _apply_issue_marks() -> void:
	## Red outlines (and Realistic tints) for objects with problems: all of them
	## while there are few, else only the selected ones.
	var s := App.session
	var shown := _issue_levels
	if _issue_levels.size() > ISSUE_OUTLINE_MAX:
		shown = {}
		for u in s.selection:
			if _issue_levels.has(u):
				shown[u] = _issue_levels[u]
	overlay.issues = shown
	var tints := {}
	if s.layout.mode == FarmLayout.MODE_REALISTIC:
		for u in shown:
			if shown[u] >= 2:
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
	if plan_overlay != null and not _exporting:
		plan_overlay.zoom = z
		plan_overlay.visible_rect = overlay.visible_rect
		plan_overlay.refresh()
	if minimap_shown():
		minimap.set_view_rect(overlay.visible_rect)
	if App.session:
		# In place: the saved views (camera.bookmarks) live in the same dictionary.
		var cam: Dictionary = App.session.layout.camera
		var rest := camera.settled_position()
		cam["x"] = rest.x
		cam["y"] = rest.y
		cam["zoom"] = camera.target_zoom


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _on_canvas_input(e: InputEvent) -> void:
	if _ref_drag and e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			if reference.active_image().is_empty() or bool(reference.active_image().get("locked", false)):
				App.toast("This reference image is locked", "info")
				return
			_ref_drag_last = camera.screen_to_world(e.position)
			_ref_drag_before = App.session.layout.reference.duplicate(true)
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
	if plan_controller.handle_input(e):
		return
	if layout_tools.handle_input(e):
		return
	controller.handle_input(e)


func _setup_layout_tools() -> void:
	## Symmetry, repeat, align, stamps and the outline brush (see LayoutToolController).
	layout_tools = LayoutToolController.new()
	layout_tools.name = "LayoutTools"
	add_child(layout_tools)
	layout_tools.setup(controller, overlay, dock, world, root, modal_layer)
	_raise_toasts()


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
	# A selected fixed landmark: object edits explain themselves near the cursor.
	if not s.selected_landmark.is_empty():
		var act := _landmark_key_action(k, ctrl)
		if not act.is_empty():
			_fixed_refusal(act)
			get_viewport().set_input_as_handled()
			return
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
		KEY_M when k.shift_pressed: toggle_minimap()
		KEY_A when ctrl and k.shift_pressed: _open_asset_manager(_asset_focus_item())
		KEY_A when ctrl: select_all_visible()
		KEY_C when ctrl: _copy(false)
		KEY_X when ctrl: _copy(true)
		KEY_V when ctrl: controller.start_stamp()
		KEY_D when ctrl:
			if _copy(false) > 0:
				controller.start_stamp()
		KEY_G when ctrl and k.shift_pressed: s.ungroup_selection()
		KEY_G when ctrl: s.group_selection()
		KEY_ESCAPE:
			if plan_controller.cancel():
				pass
			elif not controller.cancel():
				if _plan_open:
					set_plan_open(false)
				else:
					handled = false
			overlay.calibration_points = []
			overlay.refresh()
		KEY_J: toggle_plan()
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
		KEY_H: go_home()
		KEY_D: s.set_tool("pan")
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9: _bookmark_key(k, ctrl)
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
		KEY_F when k.shift_pressed: _fit_world()
		KEY_F: _fit_selection_or_farm()
		KEY_HOME: go_home()
		KEY_TAB:
			_panels_hidden = not _panels_hidden
			_update_view_rect()
		KEY_BRACKETLEFT: set_catalog_expanded(not _left_visible)
		KEY_BRACKETRIGHT: toggle_inspector()
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


func _landmark_key_action(k: InputEventKey, ctrl: bool) -> String:
	## Which object edit a key would be (for the fixed-landmark hint); "" for
	## keys that don't edit objects.
	match k.keycode:
		KEY_DELETE, KEY_BACKSPACE: return "delete"
		KEY_R when not ctrl: return "rotate"
		KEY_L when not ctrl: return "lock"
		KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT: return "nudge"
		KEY_C when ctrl: return "copy"
		KEY_X when ctrl: return "cut"
		KEY_D when ctrl: return "duplicate"
		KEY_G when ctrl: return "group"
		KEY_P when not ctrl and App.session.tool != "place": return "planned"
	return ""


func _arrow(d: Vector2i) -> void:
	if App.session.selection.is_empty():
		camera.pan_world(Iso.grid_to_world(Vector2(d)) * 2.0)
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
	var n := App.session.cut_selection() if cut else App.session.copy_selection()
	if n == 0:
		return 0
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
		pm.add_item("Home: the farmhouse  (Home)", 13)
	_add_objects_here(pm)
	pm.id_pressed.connect(_on_context_id.bind(uid))
	root.add_child(pm)
	pm.popup_hide.connect(pm.queue_free)
	pm.popup(Rect2i(Vector2i(screen), Vector2i.ZERO))


func _landmark_menu(screen: Vector2, landmark_id: String) -> void:
	var s := App.session
	var lm := s.map.landmark(landmark_id)
	if lm == null:
		return
	var pm := PopupMenu.new()
	pm.add_item("%s — fixed in place in Hay Day" % lm.name, 0)
	pm.set_item_disabled(0, true)
	pm.add_separator()
	pm.add_item("Details", 1)
	pm.add_item("Centre view here", 2)
	pm.add_item("Rotate  (R)", 3)
	pm.add_item("Delete  (Del)", 4)
	_add_objects_here(pm)
	pm.id_pressed.connect(_on_landmark_menu_id.bind(landmark_id))
	root.add_child(pm)
	pm.popup_hide.connect(pm.queue_free)
	pm.popup(Rect2i(Vector2i(screen), Vector2i.ZERO))


const OBJECTS_HERE_ID := 1000


func _add_objects_here(pm: PopupMenu) -> void:
	## Overlapping objects under the right-click: pick any of them from the menu.
	var stack: Array = controller.last_context_stack
	if stack.size() < 2:
		return
	pm.add_separator("Objects here")
	for i in stack.size():
		var e: Dictionary = stack[i]
		pm.add_radio_check_item("%s%s" % [e["name"], "  (fixed)" if e["kind"] == "landmark" else ""], OBJECTS_HERE_ID + i)
		pm.set_item_checked(pm.item_count - 1, (e["kind"] == "landmark" and e["id"] == App.session.selected_landmark) or (e["kind"] == "object" and e["uid"] in App.session.selection))
	pm.id_pressed.connect(_on_objects_here_id)


func _on_objects_here_id(id: int) -> void:
	var i := id - OBJECTS_HERE_ID
	if i >= 0 and i < controller.last_context_stack.size():
		controller.select_stack_entry(controller.last_context_stack[i])


func _on_landmark_menu_id(id: int, landmark_id: String) -> void:
	match id:
		1:
			inspector.show_tab(0)
			inspector.rebuild()
		2: focus_landmark(landmark_id)
		3: _fixed_refusal("rotate")
		4: _fixed_refusal("delete")


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
		11: select_all_visible()
		12: _fit()
		13: go_home()


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
		"assets": _open_asset_manager(_asset_focus_item())
		"help": Dialogs.help(modal_layer)
		"rename":
			Modal.prompt(modal_layer, "Rename layout", App.session.layout.name, func(t):
				if not t.strip_edges().is_empty():
					App.session.execute(EditCommands.SetMeta.new(App.session.layout.name, t.strip_edges())))
		"mode_creative":
			App.session.set_mode(FarmLayout.MODE_CREATIVE)
			top_bar.update_state(App.session)
		"mode_realistic":
			App.session.set_mode(FarmLayout.MODE_REALISTIC)
			top_bar.update_state(App.session)
			inspector.show_tab(1)
		"toggle_left": set_catalog_expanded(not _left_visible)
		"toggle_right": toggle_inspector()
		"issues":
			# The grouped list: Farm tab (it also lists them in Creative mode).
			_inspector_dismissed = false
			inspector.show_tab(1)
			inspector.rebuild()


func _set_farm_level(level: int) -> void:
	## Farm level = the layout's profile.level: one undoable profile edit that
	## never touches placed objects (Realistic filters/highlights follow it).
	var s := App.session
	if s == null:
		return
	level = clampi(level, AppSettings.LEVEL_MIN, AppSettings.LEVEL_MAX)
	if int(s.layout.profile.get("level", -1)) == level:
		return
	var p := s.layout.profile.duplicate(true)
	p["level"] = level
	s.execute(EditCommands.SetProfile.new(s.layout.profile, p, "Set farm level"))
	dock.set_status("Farm level %d" % level)


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
	if a in ["flip", "duplicate", "lock", "planned", "group", "delete"] and _fixed_refusal({"flip": "rotate"}.get(a, a)):
		return
	match a:
		"landmark_state": s.set_landmark_state(str(arg[0]), str(arg[1]))
		"landmark_skin": s.set_landmark_skin(str(arg[0]), str(arg[1]))
		"landmark_visible": s.set_landmark_visible(str(arg[0]), bool(arg[1]))
		"landmark_focus": focus_landmark(str(arg))
		"select_uids":
			# Issues list: select one group and show it.
			var live: Array = []
			for u in arg:
				if s.layout.get_obj(int(u)) != null:
					live.append(int(u))
			if not live.is_empty():
				s.select(live, false, false)
				_fit_selection_or_farm()
		"theme": set_theme(str(arg))
		"home": go_home()
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
		"variant":
			set_variant(s.selection.duplicate(), str(arg))
		"toggle_mode": _toggle_mode()
		"tool": s.set_tool(arg)
		"land_all":
			var old := s.layout.unlocked_plots.keys()
			var plots: Array = []
			var skipped := 0
			if arg:
				for pid in s.map.all_plot_ids():
					if controller.plot_unlock_block(pid).is_empty():
						plots.append(pid)
					else:
						skipped += 1
			s.execute(EditCommands.SetLand.new(old, plots, "Unlock all land" if arg else "Lock all expansions"))
			if skipped > 0:
				App.toast("%d plot%s need a higher farm level and stay locked (Realistic mode)" % [skipped, "" if skipped == 1 else "s"], "info")
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
		"ref_calibrate": _ref_calibrate(int(arg))
		"ref_cal_add": _ref_calibrate_add()
		"ref_cal_remove": _ref_cal_remove_point(int(arg))
		"ref_cal_refit": _ref_cal_refit()
		"ref_cal_show":
			reference.set_show_calibration(bool(arg))
			_sync_reference_view_state()
		"ref_select": _ref_select(str(arg))
		"ref_order": _ref_reorder(str(arg[0]), int(arg[1]))
		"ref_remove":
			_ref_remove(str(arg))
			inspector.rebuild()
		"ref_move":
			_ref_drag = bool(arg)
			_view_state["ref_move"] = _ref_drag
		"compare": _compare_pick()
		"object_layer": set_object_layer(str(arg[0]), str(arg[1]))
		"object_layers_reset": App.settings.set_v("object_layers", {})
		"compare_mine":
			if bool(arg) and not App.plan_ctx.has_baseline():
				_plan_baseline()
			else:
				App.plan_ctx.set_compare(bool(arg))
		"baseline": _plan_baseline()
		"plan": open_plan(str(arg))
		"selection_cost":
			# Budget of the selection: follow it, show the breakdown.
			App.plan_ctx.set_scope_pin("auto")
			App.settings.set_v("budget_visible", true)
			if budget != null and not budget.expanded:
				budget.set_expanded(true)
			_place_budget()
		"edit_price": _plan_price(str(arg))
		"compare_clear":
			overlay.diff = {}
			_view_state.erase("diff_summary")
			overlay.refresh()
			inspector.rebuild()


func toggle_minimap() -> void:
	## Shift+M: the overview map on / off (it only shows where the canvas has room).
	var on := not bool(App.settings.get_v("minimap_visible"))
	_set_view("minimap_visible", on)
	if on and not minimap_room():
		App.toast("The overview needs a bigger canvas: close a side panel or lower the UI scale", "info")


func set_object_layer(group: String, state: String) -> void:
	## View tab: show / dim / hide a category group (remembered; never edits the layout).
	App.settings.set_v("object_layers", ObjectLayers.with_state(ObjectLayers.normalize(App.settings.get_v("object_layers")), group, state))


func select_all_visible() -> void:
	## Ctrl+A / context menu: every object, except those hidden by an object layer
	## (they can't be picked or box-selected either).
	var s := App.session
	if s == null:
		return
	if renderer.layer_hidden_count() == 0:
		s.select_all()
	else:
		s.select_all(func(u: int) -> bool: return not renderer.is_layer_hidden(u))


func _apply_object_layers() -> void:
	renderer.set_layer_states(ObjectLayers.normalize(App.settings.get_v("object_layers")))
	var s := App.session
	if s != null:
		# Hidden objects can't be picked: let go of them in the selection too.
		var keep: Array = s.selection.filter(func(u): return not renderer.is_layer_hidden(int(u)))
		if keep.size() != s.selection.size():
			s.select(keep, false, false)
		if overlay.hover_uid != 0 and renderer.is_layer_hidden(overlay.hover_uid):
			overlay.hover_uid = 0
		# Issue outlines, heatmap and progress checks skip hidden objects.
		overlay.refresh()
		plan_overlay.refresh()
	if minimap != null and is_instance_valid(minimap):
		minimap.rebuild_objects()
	if inspector != null and inspector.current_tab() == 2:
		inspector.queue_rebuild()


func _sync_compare() -> void:
	## "Compare with my farm": object tints from Baseline.diff (view only), the
	## legend and the plan overlay. Recomputed only when the diff changed.
	var ctx := App.plan_ctx
	var on := ctx.compare and ctx.has_baseline() and App.session != null
	var key := ""
	var d := {}
	if on:
		d = ctx.compare_diff()
		key = ctx.compare_key()
	if key == _compare_key:
		return
	_compare_key = key
	var tints := {}
	if on:
		for u in d.get("unchanged", []):
			tints[int(u)] = PlanOverlay.TINT_UNCHANGED
		for u in d.get("moved", []):
			tints[int(u)] = PlanOverlay.TINT_MOVED
		for u in d.get("new", []):
			tints[int(u)] = PlanOverlay.TINT_NEW
	renderer.set_view_tints(tints)
	plan_overlay.refresh()
	_place_overlays()


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
		"ambient_animation":
			renderer.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[App.settings.ambient_animation()])
			ground.set_ambient_mode(ObjectRenderer.AMBIENT_FROM_SETTING[App.settings.ambient_animation()])
		"wheel_zoom_factor": camera.wheel_factor = float(App.settings.get_v(key))
		"inspector_auto_hide":
			_inspector_pinned = false
			_inspector_dismissed = false
			_update_view_rect()
		"budget_visible", "budget_corner":
			if budget != null:
				budget.corner = str(App.settings.get_v("budget_corner"))
			_place_budget()
			if key == "budget_visible":
				inspector.queue_rebuild()
		"plan_show_areas", "plan_show_progress", "plan_show_heatmap", "plan_show_guide":
			App.plan_ctx.set_layer(PLAN_LAYER_KEYS[key], bool(App.settings.get_v(key)))
		"object_layers":
			_apply_object_layers()
		"minimap_visible", "minimap_collapsed":
			if minimap != null and is_instance_valid(minimap):
				minimap.set_collapsed(bool(App.settings.get_v("minimap_collapsed")))
			_place_overlays()
			if inspector != null and inspector.current_tab() == 2:
				inspector.queue_rebuild()


func _on_settings_dialog(what: String) -> void:
	match what:
		"theme", "ui_scale":
			_rebuild_ui()
		"map_id":
			App.map = App.map_for(str(App.settings.get_v("map_id")))
			App.toast("New layouts will use “%s”. Open layouts keep their own map." % App.map.name, "info")
		"import_art":
			ArtImportDialog.new().show(modal_layer)
		"install_pack":
			_install_pack_dialog()
		"asset_manager":
			_open_asset_manager(_asset_focus_item())


func set_variant(uids: Array, variant: String) -> void:
	## Variant switch for placed objects: one undoable command.
	var s := App.session
	var targets: Array = []
	for u in uids:
		var o := s.layout.get_obj(u)
		if o and o.variant != variant:
			targets.append(u)
	if targets.is_empty():
		return
	var vals: Array = []
	vals.resize(targets.size())
	vals.fill(variant)
	s.execute(EditCommands.SetProperty.new(targets, "variant", vals, "Change variant"))


func _asset_focus_item() -> String:
	## Item the Asset Manager opens on: the selected object's, else the active one.
	var s := App.session
	if s == null:
		return ""
	for o: PlacedObject in s.selected_objects():
		return o.item_id
	return s.active_item


func _open_asset_manager(item_id: String = "") -> AssetManager:
	for c in modal_layer.get_children():
		if c is Modal and c.has_meta("asset_manager"):
			return c.get_meta("asset_manager")
	var am := AssetManager.open(modal_layer, item_id)
	am.install_requested.connect(_install_pack_dialog)
	return am


func _install_pack_dialog() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.title = "Install asset pack (.zip)"
	fd.filters = PackedStringArray(["*.zip ; Asset pack (.zip)"])
	fd.file_selected.connect(func(p):
		App.toast("Installing asset pack…", "info")
		var r := App.install_pack(p)
		App.toast("Asset pack %s" % r.summary(), "success" if r.ok else "error"))
	root.add_child(fd)
	fd.popup_centered_ratio(0.6)


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
	var art := str(opts.get("art", "placeholder"))
	if not _export_path_ok(path, art):
		return
	App.toast("Rendering image…", "info")
	var plan := {}
	if bool(opts.get("plan_areas", false)) or bool(opts.get("guide_numbers", false)):
		plan = {"areas": bool(opts.get("plan_areas", false)), "area_ids": [], "guide": bool(opts.get("guide_numbers", false)),
			"steps": _guide_step_numbers("farm", "") if bool(opts.get("guide_numbers", false)) else []}
	var img: Image = await render_export(r, float(opts["scale"]), bool(opts["transparent"]), bool(opts["grid"]), bool(opts["overlay"]), plan, art)
	if img == null:
		App.toast("Export failed (image too large?)", "error")
		return
	var err := img.save_png(path)
	App.toast("Exported %d×%d image to %s" % [img.get_width(), img.get_height(), path] if err == OK else "Could not write file: %s" % error_string(err), "success" if err == OK else "error")
	if err == OK and art == "installed" and has_private_art():
		App.toast("This picture uses your installed art: keep it on this PC, don't share it.", "warn")


func has_private_art() -> bool:
	## An asset pack other than the built-in placeholders is installed.
	for p in App.assets.packs:
		if not bool(p.get("builtin", false)):
			return true
	return false


func _export_path_ok(path: String, art: String) -> bool:
	## Pictures with installed (private) art are never written inside the program folder.
	if art != "installed" or not has_private_art():
		return true
	var repo := ProjectSettings.globalize_path("res://").replace("\\", "/").to_lower().trim_suffix("/")
	var p := path.replace("\\", "/").to_lower()
	if not repo.is_empty() and (p == repo or p.begins_with(repo + "/")):
		App.toast("Pictures with your installed art can't be saved in the program folder — pick another folder.", "error")
		return false
	return true


func render_export(r: Rect2, scale: float, transparent: bool, grid_on: bool, overlay_on: bool, plan: Dictionary, art: String) -> Image:
	## Renders the farm (Exporter) with placeholder art unless `art` is
	## "installed", and with the planning marks in `plan` ({} = none; see
	## PlanOverlay.export_opts). The on-screen view is restored afterwards.
	var swap := art != "installed" and has_private_art()
	if swap:
		_use_art(_placeholder_assets())
	if not plan.is_empty():
		plan_overlay.zoom = scale
		plan_overlay.visible_rect = Rect2()
		plan_overlay.set_exporting(plan, Exporter.LAYER_WORLD)
	var img: Image = await exporter.capture(r, scale, transparent, grid_on, overlay_on)
	if not plan.is_empty():
		plan_overlay.set_exporting({}, PlanOverlay.LAYER)
		plan_overlay.zoom = camera.zoom.x
		plan_overlay.visible_rect = camera.visible_world_rect()
		plan_overlay.refresh()
	if swap:
		_use_art(App.assets)
	return img


func _placeholder_assets() -> AssetLibrary:
	## The built-in placeholder art only (no user or developer packs).
	if _placeholder_lib == null:
		_placeholder_lib = AssetLibrary.new()
		_placeholder_lib.user_packs_dir = "user://__no_packs__"
		_placeholder_lib.dev_packs_dir = "res://__no_packs__"
		_placeholder_lib.load_all(App.db)
	return _placeholder_lib


func _refresh_pack_terrain() -> void:
	## Packs were (re)loaded: pick up an installed / removed pack terrain.
	ground.set_assets(App.assets)
	if App.session:
		scenery.setup(App.session.map, App.assets, App.session.db)


func _use_art(lib: AssetLibrary) -> void:
	var s := App.session
	if s == null:
		return
	renderer.bind(s.layout, s.db, lib)
	renderer.set_world_entries(LandmarkView.entries_for(s.map, s.layout, lib, _landmark_tints()))
	ground.set_assets(lib)   # placeholder exports never show pack terrain
	scenery.setup(s.map, lib, s.db)
	if lib == App.assets:
		_apply_issue_marks()


# ---------------------------------------------------------------------------
# Planning: Plan panel, budget widget, area tool, plan exports
# ---------------------------------------------------------------------------

func _wire_plan_context() -> void:
	## Once (main and the context live as long as the app): the Plan tabs'
	## requests, and the shared view state <-> settings.
	var ctx := App.plan_ctx
	ctx.mode = str(App.settings.get_v("budget_mode")) if str(App.settings.get_v("budget_mode")) in BudgetEngine.MODES else BudgetEngine.MODE_TO_BUY
	ctx.scope_pin = "farm" if str(App.settings.get_v("budget_scope")) == "farm" else "auto"
	for k: String in PLAN_LAYER_KEYS:
		ctx.layers[PLAN_LAYER_KEYS[k]] = bool(App.settings.get_v(k))
	ctx.request_focus.connect(_plan_focus)
	ctx.request_focus_rect.connect(_plan_focus_rect)
	ctx.request_highlight.connect(_plan_highlight)
	ctx.request_dialog.connect(_plan_dialog)
	ctx.request_export_image.connect(_plan_export)
	ctx.request_tab.connect(open_plan)
	ctx.request_area_tool.connect(_plan_area_tool)
	ctx.request_inventory.connect(_plan_inventory)
	ctx.request_price_edit.connect(_plan_price)
	ctx.request_calibration.connect(_plan_calibration)
	ctx.request_area_stamp.connect(_plan_area_stamp)
	ctx.request_baseline.connect(_plan_baseline)
	ctx.view_changed.connect(_on_plan_view_changed)
	ctx.changed.connect(plan_overlay.refresh)
	ctx.changed.connect(_sync_compare)


func _on_plan_view_changed() -> void:
	var ctx := App.plan_ctx
	App.settings.set_v("budget_mode", ctx.mode)
	App.settings.set_v("budget_scope", ctx.scope_pin)
	for k: String in PLAN_LAYER_KEYS:
		App.settings.set_v(k, bool(ctx.layers.get(PLAN_LAYER_KEYS[k], false)))
	plan_overlay.refresh()
	if inspector != null and inspector.current_tab() == 2:
		inspector.queue_rebuild()


func set_plan_open(on: bool, tab: String = "") -> void:
	if on:
		plan_panel.open(tab if not tab.is_empty() else str(App.settings.get_v("plan_tab")))
	elif _plan_open:
		plan_controller.cancel()
		plan_overlay.highlight_uids = []
		plan_overlay.refresh()
	_plan_open = on
	_sync_guide_marks()
	_update_view_rect()


func _sync_guide_marks() -> void:
	## Guide step numbers on the farm while the Guide or Build tab is open.
	plan_overlay.guide_active = _plan_open and plan_panel.current in ["guide", "build"]
	plan_overlay.refresh()


func open_plan(tab: String) -> void:
	set_plan_open(true, tab)


func toggle_plan() -> void:
	set_plan_open(not _plan_open)


func plan_open() -> bool:
	return _plan_open


func _on_plan_requested(tab: String) -> void:
	## Top bar: a workflow step opens that tab (again: closes the panel); "" toggles.
	if tab.is_empty():
		toggle_plan()
	elif _plan_open and plan_panel.current == tab:
		set_plan_open(false)
	else:
		open_plan(tab)


func _plan_world_rect(uids: Array) -> Rect2:
	var s := App.session
	var r := Rect2()
	for u in uids:
		var o := s.layout.get_obj(int(u))
		if o == null:
			continue
		var b := Iso.footprint_world_bounds(o.origin, o.size)
		if renderer.bounds_of(o.uid).size != Vector2.ZERO:
			b = b.merge(renderer.bounds_of(o.uid))
		r = r.merge(b) if r.size != Vector2.ZERO else b
	return r


func _plan_focus(uids: Array, select: bool) -> void:
	var s := App.session
	if s == null:
		return
	var live: Array = []
	for u in uids:
		if s.layout.objects.has(int(u)):
			live.append(int(u))
	if live.is_empty():
		App.toast("Nothing to show", "info")
		return
	if select:
		s.select(live, false, false)
	_update_view_rect()
	camera.fly_to_rect(_plan_world_rect(live), 90.0, 1.6)


func _plan_focus_rect(rect: Rect2i) -> void:
	if App.session == null or rect.size == Vector2i.ZERO:
		return
	_update_view_rect()
	camera.fly_to_rect(Iso.footprint_world_bounds(rect.position, rect.size).grow_individual(0, 60, 0, 0), 60.0, 1.6)


func _plan_highlight(uids: Array, color: Color) -> void:
	plan_overlay.highlight_uids = uids.duplicate()
	plan_overlay.highlight_color = color
	plan_overlay.refresh()


func _plan_dialog(content: Control, title: String) -> void:
	## A planning dialog (PlanDialog) in the modal layer; it closes itself
	## through close_requested.
	if content == null:
		return
	var w := 600.0
	if "preferred_width" in content:
		w = float(content.get("preferred_width"))
	var m := Modal.open(modal_layer, title, w, "clipboard-check")
	m.body.add_child(content)
	if content.has_signal("close_requested"):
		content.connect("close_requested", m.close)


func _plan_area_tool(kind: String) -> void:
	if kind == "selection":
		plan_controller.area_from_selection()
	else:
		plan_controller.begin(kind)


func _plan_inventory() -> void:
	## The inventory dialog when this build has it; else "I own everything placed now".
	var path := "res://src/ui/inventory_dialog.gd"
	if ResourceLoader.exists(path):
		var sc: Variant = load(path)
		if sc is Script and (sc as Script).get_script_method_list().any(func(m: Dictionary) -> bool: return m["name"] == "open"):
			sc.call("open", App.plan_ctx)
			return
	Modal.confirm(modal_layer, "Record inventory", "Record every object placed now (except planned ones) as what you own?", "Record", false,
		func(): _on_inspector_action("own_all", null))


func _plan_price(item_id: String) -> void:
	var path := "res://src/ui/price_dialog.gd"
	if ResourceLoader.exists(path):
		var sc: Variant = load(path)
		if sc is Script and (sc as Script).get_script_method_list().any(func(m: Dictionary) -> bool: return m["name"] == "open"):
			sc.call("open", App.plan_ctx, item_id)
			return
	App.toast("Price editing isn't available in this build", "info")


func _plan_baseline() -> void:
	## "My real farm" (BaselineDialog): the snapshot the comparison and budgets use.
	# Loaded at run time like the other planning dialogs: naming the class here made
	# main.gd compile it (and its PlanDialog base) too early, which an exported build
	# can't resolve ("Could not resolve class PlanDialog").
	if App.session != null:
		load("res://src/ui/baseline_dialog.gd").open(App.plan_ctx)


func area_to_stamp(area_id: String, stamp_name: String = "") -> Dictionary:
	## Areas tab › Save as stamp: the area's objects (relative positions kept;
	## fixed / landmark items refused like any stamp) into the stamp library.
	## Returns the saved stamp ({} when nothing usable). The layout is unchanged.
	var s := App.session
	var a := PlanDoc.area(s.layout.planning, area_id) if s else {}
	if a.is_empty():
		return {}
	var r := StampLibrary.from_area(s.layout, a, s.stamp_refusal, stamp_name)
	var st: Dictionary = r["stamp"]
	if st.is_empty():
		App.toast("Nothing in “%s” can go into a stamp%s" % [str(a.get("name", "")), (": " + str(r["reason"])) if not str(r["reason"]).is_empty() else ""], "info")
		return {}
	var err := layout_tools.stamps.save(st, s.db)
	if err != OK:
		App.toast("Can't save the stamp (%s)" % error_string(err), "error")
		return {}
	var n := (st["items"] as Array).size()
	var msg := "Saved “%s” as a stamp (%d object%s)" % [str(st["name"]), n, "" if n == 1 else "s"]
	if int(r["dropped"]) > 0:
		msg += ", %d left out: %s" % [int(r["dropped"]), str(r["reason"])]
	App.toast(msg + " — place it from Stamps", "success")
	layout_tools.panel.refresh()
	return st


func _plan_area_stamp(area_id: String) -> void:
	var st := area_to_stamp(area_id)
	if st.is_empty():
		return
	# Show it in the stamps panel, chosen and ready to place.
	layout_tools.panel.visible = true
	dock.set_stamps_open(true)
	layout_tools.panel.refresh()
	layout_tools.panel.select_id(str(st["id"]))
	_raise_toasts()


func _plan_calibration() -> void:
	## Accuracy tab → calibrate a screenshot: the inspector's View tab has it.
	set_plan_open(false)
	_inspector_dismissed = false
	inspector.show_tab(2)
	inspector.rebuild()
	App.toast("Add a screenshot under “Screenshot references”, then Calibrate", "info")


func _plan_export(opts: Dictionary) -> void:
	## ctx.request_export_image: queued, rendered one at a time. Requests never
	## write into the program folder (whatever the art) and default to placeholder art.
	var o := plan_export_request(opts)
	if o.is_empty():
		App.toast("Choose a folder outside the program folder (e.g. Documents).", "error")
		export_refused += 1
		return
	_export_queue.append(o)
	if not _exporting:
		_drain_exports()


static func plan_export_request(opts: Dictionary) -> Dictionary:
	## A plan picture request as it will be rendered: placeholder art unless it
	## asks for "installed"; {} = refused (a path inside the program folder).
	var o := opts.duplicate(true)
	if str(o.get("art", "")).is_empty():
		o["art"] = "placeholder"
	var p := str(o.get("path", ""))
	if not p.is_empty() and PlanUiKit.is_inside_repo(p):
		return {}
	return o


func _drain_exports() -> void:
	_exporting = true
	while not _export_queue.is_empty():
		var o: Dictionary = _export_queue.pop_front()
		if str(o.get("path", "")).is_empty():
			_ask_export_path(o)
			continue
		await export_plan_image(o)
	_exporting = false


func _ask_export_path(o: Dictionary) -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.filters = PackedStringArray(["*.png ; PNG image"])
	fd.current_dir = PlanUiKit.documents_dir()   # never the program folder (the default working dir)
	var stem := App.session.layout.name.validate_filename() if App.session else "farm"
	fd.current_file = "%s_%s%s.png" % [stem, str(o.get("scope", "farm")), "_" + str(o.get("id")) if not str(o.get("id", "")).is_empty() else ""]
	fd.file_selected.connect(func(p: String):
		var o2 := o.duplicate(true)
		o2["path"] = p
		_plan_export(o2))
	root.add_child(fd)
	fd.popup_centered_ratio(0.6)


func plan_export_rect(scope: String, id: String) -> Rect2:
	## World rectangle a plan picture shows (farm / phase / area / step), with room for the art.
	var s := App.session
	var tiles := Rect2i()
	match scope:
		"area":
			tiles = PlanDoc.area_bounds(PlanDoc.area(s.layout.planning, id))
		"phase":
			var ph := PlanDoc.phase(s.layout.planning, id)
			var uids: Array = s.budget.phase_uids(id) if s.budget != null else []
			if not uids.is_empty():
				tiles = s.layout.bounds_of(uids)
			for aid in ph.get("areas", []):
				var b := PlanDoc.area_bounds(PlanDoc.area(s.layout.planning, str(aid)))
				if b.size != Vector2i.ZERO:
					tiles = b if tiles.size == Vector2i.ZERO else tiles.merge(b)
		"step":
			var st := _guide_step(id)
			if not st.is_empty():
				tiles = st.get("bounds", Rect2i())
				var fb: Variant = st.get("from_bounds")
				if fb is Rect2i and (fb as Rect2i).size != Vector2i.ZERO:
					tiles = tiles.merge(fb as Rect2i)
	if tiles.size == Vector2i.ZERO:
		var land := Exporter.farm_world_rect(s.map, s.layout, "unlocked")
		if s.layout.count() > 0:
			land = land.merge(Exporter.farm_world_rect(s.map, s.layout, "objects"))
		return land
	tiles = tiles.grow(3)
	return Iso.footprint_world_bounds(tiles.position, tiles.size).grow_individual(48, 200, 48, 48)


func _guide_step(id: String) -> Dictionary:
	for st: Dictionary in App.plan_ctx.guide().get("steps", []):
		if str(st.get("id", "")) == id or str(st.get("number", "")) == id:
			return st
	return {}


func _guide_step_numbers(scope: String, id: String) -> Array:
	## Step numbers a plan picture of this scope marks.
	var out: Array = []
	var s := App.session
	var area := PlanDoc.area(s.layout.planning, id) if scope == "area" else {}
	for st: Dictionary in App.plan_ctx.guide().get("steps", []):
		var keep := true
		match scope:
			"phase":
				keep = str(st.get("phase", "")) == id
			"area":
				var b: Variant = st.get("bounds")
				keep = b is Rect2i and not area.is_empty() and PlanDoc.rect_in_area(area, b)
			"step":
				keep = str(st.get("id", "")) == id or str(st.get("number", "")) == id
		if keep:
			out.append(int(st.get("number", 0)))
	return out


func export_plan_image(o: Dictionary) -> Error:
	## One plan picture: {scope, id, guide_numbers, path, art, scale?, areas?}.
	var s := App.session
	if s == null:
		return ERR_UNAVAILABLE
	var scope := str(o.get("scope", "farm"))
	var id := str(o.get("id", ""))
	var path := str(o.get("path", ""))
	var art := str(o.get("art", "placeholder"))
	if not _export_path_ok(path, art):
		return ERR_FILE_NO_PERMISSION
	if path.is_empty() or path.begins_with("res://"):
		App.toast("Choose a folder outside the program folder (e.g. Documents).", "error")
		return ERR_FILE_NO_PERMISSION
	var numbers := bool(o.get("guide_numbers", false))
	var plan := {"areas": bool(o.get("areas", true)), "area_ids": [id] if scope == "area" else [],
		"guide": numbers, "steps": _guide_step_numbers(scope, id) if numbers else []}
	var img: Image = await render_export(plan_export_rect(scope, id), float(o.get("scale", 1.0)), false, false, false, plan, art)
	if img == null:
		App.toast("Picture export failed (too large?)", "error")
		return FAILED
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	if err != OK:
		App.toast("Could not write %s: %s" % [path, error_string(err)], "error")
	elif art == "installed" and has_private_art():
		App.toast("Saved %s — it uses your installed art: keep it on this PC, don't share it." % path.get_file(), "warn")
	else:
		App.toast("Saved %s" % path.get_file(), "success")
	return err


# ---------------------------------------------------------------------------
# Screenshot reference
# ---------------------------------------------------------------------------

func _load_reference() -> void:
	var s := App.session
	s.layout.reference = LayoutIO.normalize_reference(s.layout.reference)
	reference.load_from_settings(s.layout.reference)
	_view_state["ref_loaded"] = not s.layout.reference.is_empty()
	if not reference.missing.is_empty():
		_view_state["ref_status"] = "Reference image file is missing: %s" % ", ".join(reference.missing)
	elif str(_view_state.get("ref_status", "")).begins_with("Reference image file is missing"):
		_view_state.erase("ref_status")
	_sync_reference_view_state()


func _sync_reference_view_state() -> void:
	var rows: Array = []
	for im: Dictionary in reference.images():
		var id := str(im.get("id", ""))
		rows.append({"id": id, "name": str(im.get("name", "")), "visible": bool(im.get("visible", true)),
			"locked": bool(im.get("locked", false)), "missing": not reference.is_loaded(im), "active": id == reference.active_id})
	_view_state["ref_images"] = rows
	var a := reference.active_image()
	var above := bool(reference.settings.get("above", false))
	_view_state["ref_locked"] = bool(a.get("locked", false))
	_view_state["ref_above"] = above
	_view_state["ref_opacity"] = float(a.get("opacity", 0.5))
	_view_state["ref_scale"] = float(a.get("scale", 1.0))
	_view_state["ref_rotation"] = float(a.get("rotation", 0.0))
	_view_state["ref_grid"] = bool(a.get("grid", false))
	_view_state["ref_cal_show"] = reference.show_calibration
	_view_state["ref_cal"] = _ref_cal_view(a)
	_place_reference_layer(above)


func _ref_cal_view(im: Dictionary) -> Dictionary:
	## What the inspector shows about the active image's calibration ({} = none).
	if im.is_empty():
		return {}
	var sm := CalibrationMath.summary(im, App.session.map if App.session else null)
	var rec := CalibrationMath.record_of(im)
	var rows: Array = []
	if not rec.is_empty():
		var res: Array = (rec.get("fit", {}) as Dictionary).get("residuals", []) if rec.get("fit") is Dictionary else []
		var pts := CalibrationMath.refresh_anchor_flags(rec.get("points", []), App.session.map if App.session else null)
		for i in pts.size():
			var p: Dictionary = pts[i]
			rows.append({"index": i, "tiles": float(res[i]["tiles"]) if i < res.size() else -1.0,
				"px": float(res[i]["px"]) if i < res.size() else -1.0, "landmark": str(p.get("landmark", "")),
				"spot": str(p.get("spot", "")), "approximate": bool(p.get("approximate", false))})
	sm["rows"] = rows
	return sm


func _place_reference_layer(above: bool) -> void:
	world.move_child(reference, overlay.get_index() if above else scenery.get_index() + 1)


func _ref_import() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	fd.file_selected.connect(func(p):
		var dst := ReferenceLayer.import_image(p, App.session.layout.id)
		if dst.is_empty():
			App.toast("Could not read that image", "error")
			return
		_ref_add_image(dst)
		inspector.show_tab(2)
		inspector.rebuild()
		App.toast("Reference added. Calibrate it to line it up with the grid.", "success"))
	root.add_child(fd)
	fd.popup_centered_ratio(0.6)


func _ref_add_image(file: String) -> void:
	## Adds an image (already in the user folder) on top of the list and makes it the active one.
	var s := App.session
	var doc := LayoutIO.normalize_reference(s.layout.reference)
	if doc.is_empty():
		doc = {"images": [], "above": false}
	var land := Exporter.farm_world_rect(s.map, s.layout, "unlocked")
	var im := ReferenceLayer.default_image(file, land.get_center(), land.size.x)
	im["id"] = ReferenceLayer.new_id(doc)
	(doc["images"] as Array).append(im)
	reference.active_id = str(im["id"])
	_set_reference(doc, "Add reference")


func _ref_update(d: Dictionary) -> void:
	## Changes the fields in `d` on image d["id"] (default: the active image);
	## "above" belongs to the whole reference layer.
	var doc := LayoutIO.normalize_reference(App.session.layout.reference)
	var id := str(d.get("id", reference.active_id))
	var im := ReferenceLayer.image_by_id(doc, id)
	if d.has("above"):
		doc["above"] = bool(d["above"])
	for k in d:
		if k != "id" and k != "above" and not im.is_empty():
			im[k] = d[k]
	if d.has("scale") or d.has("rotation"):
		im.erase("affine")
	if d.has("locked"):
		_ref_drag = false
		_view_state["ref_move"] = false
	var keys := d.keys()
	keys.sort()
	_set_reference(doc, "Adjust reference", "reference/%s/%s" % [id, str(keys)])


func _ref_select(id: String) -> void:
	## Which image the inspector edits: view state, not part of the document.
	reference.active_id = id
	_sync_reference_view_state()
	inspector.rebuild()


func _ref_reorder(id: String, dir: int) -> void:
	## dir > 0 moves the image up the stack (towards the end of the list).
	var doc := LayoutIO.normalize_reference(App.session.layout.reference)
	var list: Array = doc.get("images", [])
	var i := list.find(ReferenceLayer.image_by_id(doc, id))
	var j := i + signi(dir)
	if i < 0 or j < 0 or j >= list.size():
		return
	var im: Variant = list[i]
	list[i] = list[j]
	list[j] = im
	_set_reference(doc, "Reorder references")


func _ref_remove(id: String) -> void:
	var doc := LayoutIO.normalize_reference(App.session.layout.reference)
	var list: Array = doc.get("images", [])
	list.erase(ReferenceLayer.image_by_id(doc, id))
	_ref_drag = false
	_view_state["ref_move"] = false
	_set_reference({} if list.is_empty() else doc, "Remove reference")


func _set_reference(settings: Dictionary, text: String, key: String = "") -> void:
	var s := App.session
	s.execute(EditCommands.SetReference.new(s.layout.reference, settings, text, key))


func _on_reference_changed() -> void:
	## Runs after every reference command, undo and redo included. Only new
	## files are read, so sliders stay smooth; the inspector is rebuilt only
	## when what its list shows changed (never in the middle of a slider drag).
	_load_reference()
	var cal: Dictionary = _view_state.get("ref_cal", {})
	var sig := str(_view_state.get("ref_images", [])) + str(_view_state.get("ref_above", false)) \
		+ str(_view_state.get("ref_grid", false)) + str(cal.get("verdict", "")) + str(cal.get("rms_tiles", 0.0)) \
		+ str((cal.get("rows", []) as Array).size())   # not "applied": that flips during a scale slider drag
	if sig != _ref_ui_sig:
		_ref_ui_sig = sig
		inspector.queue_rebuild()


func _save_reference_settings() -> void:
	## End of a reference drag: the whole drag is one undo step.
	if _ref_drag_before.is_empty():
		return
	var after := reference.settings.duplicate(true)
	if after != _ref_drag_before:
		App.session.execute(EditCommands.SetReference.new(_ref_drag_before, after, "Move reference"))
	_ref_drag_before = {}


func _ref_calibrate(points: int = 3) -> void:
	## Starts a calibration of the active image from `points` new pairs: click
	## the points on the screenshot, then the same tile corners (or landmark
	## corners / centres) on the grid, in the same order. Replaces its points.
	if reference.active_image().is_empty():
		return
	_calib_points = clampi(points, 2, CalibrationMath.MAX_POINTS)
	_calib_add = false
	_calib_world = []
	_calib_grid = []
	overlay.calibration_points = []
	controller.calibrating = true
	App.toast("Calibration: click %d recognisable points on the screenshot…" % _calib_points, "info")


func _ref_calibrate_add() -> void:
	## One more pair for the active image's calibration (refit with all points).
	if reference.active_image().is_empty():
		return
	_ref_calibrate(1)
	_calib_points = 1
	_calib_add = true
	App.toast("Add a point: click it on the screenshot, then the matching tile corner on the grid", "info")


func _on_calibration_point(w: Vector2) -> void:
	_calib_world.append(w)
	var n := _calib_world.size()
	var k := _calib_points
	if n <= k:
		overlay.calibration_points = _calib_world.duplicate()
		if n == k:
			App.toast("…now click the matching %d tile corner%s on the grid, in the same order" % [k, "" if k == 1 else "s"], "info")
	else:
		# Grid side: a landmark corner / centre nearby wins, else the nearest tile corner.
		var snap := CalibrationMath.snap_grid_point(App.session.map, Iso.world_to_grid(w))
		_calib_grid.append(snap)
		_calib_world[n - 1] = Iso.grid_to_world(snap["grid"])
		overlay.calibration_points = _calib_world.duplicate()
		if bool(snap["approximate"]):
			App.toast("That point is on %s, whose position on this map is approximate" % str(snap["landmark"]), "warn")
	overlay.refresh()
	if n == k * 2:
		controller.calibrating = false
		overlay.calibration_points = []
		var pts: Array = []
		var im := reference.active_image()
		if _calib_add:
			pts = CalibrationMath.clean_points(CalibrationMath.record_of(im).get("points", []))
		for i in k:
			var g: Dictionary = _calib_grid[i]
			pts.append(CalibrationMath.make_point(reference.world_to_image(_calib_world[i]), g["grid"],
				str(g["landmark"]), str(g["spot"]), bool(g["approximate"])))
		_ref_apply_points(pts, "Calibrate reference" if not _calib_add else "Add calibration point")


func _ref_apply_points(pts: Array, text: String) -> bool:
	## Fits the active image to `pts` and stores the result (image "affine" and
	## its "calibration" record) as one undoable SetReference.
	var f := CalibrationMath.fit(pts)
	if not bool(f["ok"]):
		App.toast("Can't calibrate: %s. Pick spread-out points." % str(f["error"]), "warn")
		return false
	var doc := LayoutIO.normalize_reference(App.session.layout.reference)
	var target := ReferenceLayer.image_by_id(doc, reference.active_id)
	if target.is_empty():
		return false
	target["affine"] = f["image_to_world"]
	target["calibration"] = CalibrationMath.to_record(pts, f, Time.get_datetime_string_from_system(true))
	_set_reference(doc, text)
	var iso: Dictionary = f["iso"]
	var msg := "%s with %d points (%s)." % [CalibrationMath.VERDICT_TEXT[f["verdict"]], int(f["n"]),
		"position, rotation and scale" if f["model"] == "similarity" else "affine"]
	if f["verdict"] in ["good", "fair", "poor"]:
		msg = "%s: RMS %.2f tile, max %.2f tile over %d points." % [CalibrationMath.VERDICT_TEXT[f["verdict"]],
			float(f["rms_tiles"]), float(f["max_tiles"]), int(f["n"])]
	else:
		msg += " Add another point to measure the error."
	_view_state["ref_status"] = msg + " " + str(iso.get("text", ""))
	_sync_reference_view_state()
	inspector.rebuild()
	App.toast("Reference aligned to the grid", "success")
	return true


func _ref_cal_remove_point(i: int) -> void:
	var rec := CalibrationMath.record_of(reference.active_image())
	var pts := CalibrationMath.clean_points(rec.get("points", []))
	if i < 0 or i >= pts.size():
		return
	if pts.size() <= 2:
		App.toast("A calibration needs at least 2 points", "info")
		return
	pts.remove_at(i)
	_ref_apply_points(pts, "Remove calibration point")


func _ref_cal_refit() -> void:
	## Puts the active image back where its stored points say (after a drag).
	var pts := CalibrationMath.clean_points(CalibrationMath.record_of(reference.active_image()).get("points", []))
	if pts.size() >= 2:
		_ref_apply_points(pts, "Re-apply calibration")


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
