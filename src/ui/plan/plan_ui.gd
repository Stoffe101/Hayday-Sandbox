class_name PlanUI
extends RefCounted
## Small widgets shared by the Budget, Areas and Phases tabs: colour swatches
## with a palette, status badges, cost lines, list rows, and keeping the
## keyboard focus in a text field when a tab rebuilds itself.

const STATUS_NAMES := {
	BudgetEngine.PHASE_NOT_STARTED: "Not started", BudgetEngine.PHASE_IN_PROGRESS: "In progress",
	BudgetEngine.PHASE_READY: "Ready to build", BudgetEngine.PHASE_COMPLETED: "Completed",
}
const STATUS_HELP := {
	BudgetEngine.PHASE_NOT_STARTED: "Nothing placed yet and something still to buy",
	BudgetEngine.PHASE_IN_PROGRESS: "Some objects are placed in Hay Day",
	BudgetEngine.PHASE_READY: "Nothing left to buy (and no land to unlock): ready to build",
	BudgetEngine.PHASE_COMPLETED: "Every object placed, or marked done",
}


static func status_color(status: String) -> Color:
	match status:
		BudgetEngine.PHASE_COMPLETED: return UiTheme.c("accent")
		BudgetEngine.PHASE_READY: return UiTheme.c("info")
		BudgetEngine.PHASE_IN_PROGRESS: return UiTheme.c("warn")
	return UiTheme.c("text_faint")


static func status_badge(status: String) -> PanelContainer:
	var b := UI.badge(str(STATUS_NAMES.get(status, status)), status_color(status))
	b.tooltip_text = str(STATUS_HELP.get(status, ""))
	return b


static func swatch(color: Color, tip: String, cb: Callable) -> Button:
	## A small colour square; `cb(new_hex)` after a pick from the palette.
	var b := Button.new()
	b.custom_minimum_size = Vector2(22, 22)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st, UiTheme.box(color if st == "normal" else color.lightened(0.15), 6, Color(1, 1, 1, 0.5), 1, Vector4(0, 0, 0, 0)))
	b.pressed.connect(func(): palette(b, cb))
	return b


static func palette(anchor: Control, cb: Callable) -> void:
	var pop := PopupPanel.new()
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	pop.add_child(grid)
	for hex: String in PlanDoc.DEFAULT_COLORS + ["#c7c7c7", "#5f8fbf", "#bf5f8f", "#8fbf5f"]:
		var c := Color(hex)
		var b := Button.new()
		b.custom_minimum_size = Vector2(26, 26)
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = hex
		b.add_theme_stylebox_override("normal", UiTheme.box(c, 6, Color.TRANSPARENT, 0, Vector4.ZERO))
		b.add_theme_stylebox_override("hover", UiTheme.box(c.lightened(0.2), 6, Color.WHITE, 1, Vector4.ZERO))
		b.pressed.connect(func():
			pop.hide()
			cb.call(hex))
		grid.add_child(b)
	anchor.add_child(pop)
	pop.popup_hide.connect(pop.queue_free)
	var r := anchor.get_global_rect()
	pop.popup(Rect2i(Vector2i(r.position + Vector2(0, r.size.y + 4)), Vector2i.ZERO))


static func cost_text(t: BudgetEngine.Totals, empty_text: String = "nothing to pay") -> String:
	## "1,234 coins · 3 diamonds (+2 unknown)" for a Totals' known cost.
	var s := Currency.format_line(t.cost, empty_text if t.is_exact() else "no known price")
	var unk := t.unknown_price_objects + t.not_buyable_objects
	if unk > 0:
		s += "  (+%d not priced)" % unk
	return s


static func row_button(text: String, tip: String, cb: Callable) -> Button:
	## A flat, left-aligned list row.
	var b := UI.button(text, "", tip, "Ghost")
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.add_theme_font_size_override("font_size", 14)
	b.pressed.connect(cb)
	return b


static func small_button(text: String, icon: String, tip: String, cb: Callable) -> Button:
	var b := UI.button(text, icon, tip, "Ghost")
	b.add_theme_font_size_override("font_size", 13)
	b.pressed.connect(cb)
	return b


static func flow() -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 6)
	f.add_theme_constant_override("v_separation", 6)
	return f


static func name_edit(text: String, key: String, cb: Callable) -> LineEdit:
	## Inline name field: commits on Enter or when it loses focus (if changed).
	var le := LineEdit.new()
	le.text = text
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size.x = 60
	le.flat = true
	le.select_all_on_focus = true
	le.set_meta("fkey", key)
	le.add_theme_font_size_override("font_size", 15)
	le.text_submitted.connect(func(_t: String): le.release_focus())
	le.focus_exited.connect(func():
		var t := le.text.strip_edges()
		if t != text and not t.is_empty():
			cb.call(t))
	return le


static func spin(value: int, prefix: String, tip: String, key: String, cb: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = 0
	s.max_value = 999999999
	s.step = 1
	s.rounded = true
	s.allow_greater = true
	s.value = value
	s.prefix = prefix
	s.tooltip_text = tip
	s.select_all_on_focus = true
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size.x = 80
	s.get_line_edit().set_meta("fkey", key)
	s.value_changed.connect(func(v: float): cb.call(int(v)))
	return s


static func focused_key(root: Node) -> String:
	## Key of the text field inside `root` that has the keyboard focus ("" = none).
	var vp := root.get_viewport()
	var f: Control = vp.gui_get_focus_owner() if vp else null
	if f == null or not root.is_ancestor_of(f) or not f.has_meta("fkey"):
		return ""
	return str(f.get_meta("fkey"))


static func restore_focus(root: Node, key: String) -> void:
	if key.is_empty():
		return
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Control and n.has_meta("fkey") and str(n.get_meta("fkey")) == key:
			(n as Control).grab_focus()
			if n is LineEdit:
				(n as LineEdit).caret_column = (n as LineEdit).text.length()
			return
		stack.append_array(n.get_children())
