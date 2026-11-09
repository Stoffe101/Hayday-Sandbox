class_name TopBar
extends PanelContainer
## Title bar: brand, layout name, mode switch (+ farm level), document actions.

signal action(name: String)
## The farm level picker changed the open layout's level (main makes it an
## undoable profile edit; placed objects never change).
signal farm_level_set(level: int)

var _name_btn: Button
var _dirty: Label
var _mode_creative: Button
var _mode_real: Button
var _level_btn: Button
var _level_pop: PopupPanel
var _level_spin: SpinBox
var _level_hint: Label
var _default_btn: Button
var _level := 1
var _realistic := false
var _undo: Button
var _redo: Button
var _left_toggle: Button
var _right_toggle: Button
var _brand: Label
var _brand_sep: VSeparator
var _issues_btn: Button
var _compact := -1


func _ready() -> void:
	theme_type_variation = "Pill"
	var h := UI.hbox(6)
	add_child(h)
	_left_toggle = UI.icon_button("panel-left", "Toggle catalogue (Tab hides all panels)")
	_left_toggle.toggle_mode = true
	_left_toggle.button_pressed = true
	_left_toggle.pressed.connect(func(): action.emit("toggle_left"))
	h.add_child(_left_toggle)
	var logo := UI.icon_rect("tent-tree", 22, UiTheme.c("accent"))
	h.add_child(logo)
	_brand = UI.label("Hayday Sandbox", "Heading")
	h.add_child(_brand)
	_brand_sep = VSeparator.new()
	h.add_child(_brand_sep)
	_name_btn = UI.button("Untitled farm", "pencil", "Rename layout", "Ghost")
	_name_btn.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_name_btn.pressed.connect(func(): action.emit("rename"))
	_name_btn.custom_minimum_size.x = 180
	_name_btn.clip_text = true
	_name_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	h.add_child(_name_btn)
	_dirty = UI.label("●", "Faint")
	_dirty.tooltip_text = "Unsaved changes"
	_dirty.mouse_filter = Control.MOUSE_FILTER_STOP
	h.add_child(_dirty)
	h.add_child(UI.spacer())
	var seg := PanelContainer.new()
	seg.theme_type_variation = "SegmentBar"
	var sh := UI.hbox(2)
	seg.add_child(sh)
	_mode_creative = UI.button("Creative", "wand-sparkles", "Sandbox: everything unlocked (Ctrl+M toggles)", "Segment")
	_mode_creative.toggle_mode = true
	_mode_creative.pressed.connect(func(): action.emit("mode_creative"))
	sh.add_child(_mode_creative)
	_mode_real = UI.button("Realistic", "clipboard-check", "My farm at its level: only unlocked items, plus inventory and land checks (Ctrl+M toggles)", "Segment")
	_mode_real.toggle_mode = true
	_mode_real.pressed.connect(func(): action.emit("mode_realistic"))
	sh.add_child(_mode_real)
	_level_btn = UI.button("Lv 1", "sprout", "Farm level — click to change", "Segment")
	_level_btn.pressed.connect(_open_level_popup)
	sh.add_child(_level_btn)
	h.add_child(seg)
	# Problems in the design (conflicts, Realistic blockers): one button that
	# opens the grouped list instead of outlining every object in red.
	_issues_btn = UI.button("", "circle-x", "", "Ghost")
	_issues_btn.add_theme_color_override("icon_normal_color", UiTheme.c("warn"))
	_issues_btn.add_theme_color_override("font_color", UiTheme.c("warn"))
	_issues_btn.add_theme_color_override("icon_hover_color", UiTheme.c("warn"))
	_issues_btn.visible = false
	_issues_btn.pressed.connect(func(): action.emit("issues"))
	h.add_child(_issues_btn)
	h.add_child(UI.spacer())
	_undo = UI.icon_button("undo-2", "Undo (Ctrl+Z)")
	_undo.pressed.connect(func(): action.emit("undo"))
	h.add_child(_undo)
	_redo = UI.icon_button("redo-2", "Redo (Ctrl+Shift+Z)")
	_redo.pressed.connect(func(): action.emit("redo"))
	h.add_child(_redo)
	h.add_child(VSeparator.new())
	for b in [["layout-grid", "Layouts (Ctrl+O)", "gallery"], ["save", "Save (Ctrl+S)", "save"], ["image-down", "Export image (Ctrl+E)", "export"],
			["image", "Asset manager — art packs, anchors, review (Ctrl+Shift+A)", "assets"],
			["settings", "Settings", "settings"], ["circle-question-mark", "Help & shortcuts (F1)", "help"]]:
		var btn := UI.icon_button(b[0], b[1])
		btn.pressed.connect(func(): action.emit(b[2]))
		h.add_child(btn)
	_right_toggle = UI.icon_button("panel-right", "Toggle inspector")
	_right_toggle.toggle_mode = true
	_right_toggle.button_pressed = true
	_right_toggle.pressed.connect(func(): action.emit("toggle_right"))
	h.add_child(_right_toggle)


func update_state(s: EditorSession) -> void:
	if s == null:
		return
	_name_btn.text = s.layout.name
	_dirty.visible = s.stack.is_dirty()
	_mode_creative.button_pressed = s.layout.mode == FarmLayout.MODE_CREATIVE
	_mode_real.button_pressed = s.layout.mode == FarmLayout.MODE_REALISTIC
	_update_level(s)
	_undo.disabled = not s.stack.can_undo()
	_redo.disabled = not s.stack.can_redo()
	_undo.tooltip_text = "Undo %s (Ctrl+Z)" % s.stack.undo_label() if s.stack.can_undo() else "Nothing to undo"
	_redo.tooltip_text = "Redo %s (Ctrl+Shift+Z)" % s.stack.redo_label() if s.stack.can_redo() else "Nothing to redo"


func set_panels(left: bool, right: bool, right_auto: bool = false) -> void:
	_left_toggle.set_pressed_no_signal(left)
	_right_toggle.set_pressed_no_signal(right)
	_left_toggle.tooltip_text = "Collapse the catalogue to its rail ([ · Tab hides all panels)" if left else "Expand the catalogue ([)"
	if right_auto:
		_right_toggle.tooltip_text = "Hide the inspector (])" if right else "Show the inspector (]) — it also opens by itself when you select or place something"
	else:
		_right_toggle.tooltip_text = "Hide the inspector (])" if right else "Show the inspector (])"


func set_issues(count: int, tip: String) -> void:
	## "3 issues" button (hidden at 0).
	_issues_btn.visible = count > 0
	_issues_btn.text = "" if _compact >= 2 else ("%s issue%s" % [UI.fmt_int(count), "" if count == 1 else "s"])
	_issues_btn.set_meta("count", count)
	_issues_btn.tooltip_text = tip


func issues_count() -> int:
	return int(_issues_btn.get_meta("count", 0)) if _issues_btn.visible else 0


func fit_width(avail: float) -> void:
	## Picks the least compact level whose content fits `avail` (re-run when the
	## window, the layout name or the issues button change).
	for lvl in 3:
		set_compact(lvl)
		if get_combined_minimum_size().x <= avail:
			return


func set_compact(level: int) -> void:
	## 0 = full; 1 = no brand text; 2 = also icon-only mode switch and a
	## shorter name (narrow windows / large UI scales).
	if level == _compact:
		return
	_compact = level
	_brand.visible = level < 1
	_brand_sep.visible = level < 1
	_name_btn.custom_minimum_size.x = 180 if level < 2 else 112
	_mode_creative.text = "Creative" if level < 2 else ""
	_mode_real.text = "Realistic" if level < 2 else ""
	if _issues_btn.visible:
		set_issues(int(_issues_btn.get_meta("count", 0)), _issues_btn.tooltip_text)


# ---------------------------------------------------------------------------
# Farm level picker
# ---------------------------------------------------------------------------

func _update_level(s: EditorSession) -> void:
	_level = RealisticAnalyzer.farm_level(s.layout)
	_realistic = s.layout.mode == FarmLayout.MODE_REALISTIC
	_level_btn.text = "Lv %d" % _level
	# Creative is the sandbox: the level only matters in Realistic mode.
	_level_btn.modulate = Color(1, 1, 1, 1.0 if _realistic else 0.6)
	if _realistic:
		_level_btn.tooltip_text = "Farm level %d — the catalogue shows what your farm has unlocked. Click to change." % _level
	else:
		_level_btn.tooltip_text = "Farm level %d (used in Realistic mode; Creative has everything unlocked). Click to change." % _level
	if _level_pop and _level_pop.visible:
		_level_spin.set_value_no_signal(_level)
		_update_level_hint()


func _open_level_popup() -> void:
	if _level_pop == null:
		_build_level_popup()
	_level_spin.set_value_no_signal(_level)
	_update_level_hint()
	var r := _level_btn.get_global_rect()
	_level_pop.popup(Rect2i(Vector2i(r.position + Vector2(0, r.size.y + 6)), Vector2i.ZERO))
	var le := _level_spin.get_line_edit()
	le.grab_focus()
	le.select_all()


func _build_level_popup() -> void:
	_level_pop = PopupPanel.new()
	var v := UI.vbox(8)
	_level_pop.add_child(v)
	var head := UI.hbox(6)
	head.add_child(UI.icon_rect("sprout", 18, UiTheme.c("accent")))
	head.add_child(UI.label("Farm level", "Heading"))
	v.add_child(head)
	# Explicit line breaks (no autowrap): a wrapping label inside a popup is
	# measured before it has a width and would make the popup very tall.
	v.add_child(UI.label("Realistic mode shows only the items and land\nyour farm has unlocked at this level.\nCreative is the sandbox: everything unlocked.\nPlaced objects never change.", "Dim"))
	_level_spin = SpinBox.new()
	_level_spin.min_value = AppSettings.LEVEL_MIN
	_level_spin.max_value = AppSettings.LEVEL_MAX
	_level_spin.step = 1
	_level_spin.rounded = true
	_level_spin.select_all_on_focus = true
	_level_spin.prefix = "Level"
	_level_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_spin.value_changed.connect(func(val: float): farm_level_set.emit(int(val)))
	_level_spin.get_line_edit().text_submitted.connect(func(_t: String):
		_level_spin.apply()
		_level_pop.hide())
	v.add_child(_level_spin)
	var row := UI.hbox(6)
	_level_hint = UI.label("", "Faint")
	_level_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_level_hint)
	_default_btn = UI.button("Make default", "", "Start new farms (new layouts) at this level", "Ghost")
	_default_btn.pressed.connect(func():
		var lv := int(_level_spin.value)
		App.settings.set_v("default_farm_level", lv)
		App.toast("New farms will start at level %d" % lv, "success")
		_update_level_hint())
	row.add_child(_default_btn)
	v.add_child(row)
	add_child(_level_pop)


func _update_level_hint() -> void:
	if _level_hint == null:
		return
	var def := App.default_farm_level()
	_level_hint.text = "New farms start at level %d" % def
	_default_btn.disabled = int(_level_spin.value) == def
