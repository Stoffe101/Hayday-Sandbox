class_name ToolDock
extends VBoxContainer
## Floating bottom dock: tool buttons, view toggles, zoom; plus a status line.

signal tool_selected(tool: String)
signal action(name: String)
## Layout-tool buttons (handled by LayoutToolController).
signal tool_action(name: String, arg: Variant)

const TOOLS := [
	["select", "mouse-pointer-2", "Select & move", "V"],
	["place", "paintbrush", "Place / paint", "B"],
	["erase", "eraser", "Erase (Shift-drag: area)", "E"],
	["pick", "pipette", "Eyedropper", "I"],
	["land", "map", "Land: lock / unlock plots", "M"],
	["annotate", "sticky-note", "Notes & zones", "N"],
	["pan", "hand", "Pan (or hold Space / middle mouse)", "D"],
]

var _btns: Dictionary = {}
var _zoom_lbl: Label
var _status: Label
var _grid_btn: Button
var _stats: Label
var _sym_btn: Button
var _stamps_btn: Button
var _sym_row: Control
var _sel_row: Control
var _repeat_row: Control
var _repeat_btn: Button
var _align_btns: Array = []
var _dist_btns: Array = []
var _kind_btns: Dictionary = {}
var _cols: SpinBox
var _rows: SpinBox
var _gap_x: SpinBox
var _gap_y: SpinBox


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 8)
	# The contextual rows make the dock taller: it must grow upwards.
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	_build_context_rows()
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var pill := PanelContainer.new()
	pill.theme_type_variation = "Pill"
	center.add_child(pill)
	var h := UI.hbox(4)
	pill.add_child(h)
	var group := ButtonGroup.new()
	for t in TOOLS:
		var b := UI.icon_button(t[1], "%s  (%s)" % [t[2], t[3]], "Tool", 22)
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(44, 44)
		b.pressed.connect(func(): tool_selected.emit(t[0]))
		_btns[t[0]] = b
		h.add_child(b)
	h.add_child(VSeparator.new())
	_sym_btn = UI.icon_button("git-compare", "Symmetry: placing also places a mirrored copy", "Tool", 20)
	_sym_btn.toggle_mode = true
	_sym_btn.custom_minimum_size = Vector2(40, 40)
	_sym_btn.toggled.connect(func(on: bool): tool_action.emit("symmetry", on))
	h.add_child(_sym_btn)
	_stamps_btn = UI.icon_button("package-open", "Stamps: reusable groups", "Tool", 20)
	_stamps_btn.toggle_mode = true
	_stamps_btn.custom_minimum_size = Vector2(40, 40)
	_stamps_btn.toggled.connect(func(on: bool): tool_action.emit("stamps", on))
	h.add_child(_stamps_btn)
	_grid_btn = UI.icon_button("grid-3x3", "Grid (G)", "Tool", 20)
	_grid_btn.toggle_mode = true
	_grid_btn.button_pressed = true
	_grid_btn.custom_minimum_size = Vector2(40, 40)
	_grid_btn.pressed.connect(func(): action.emit("grid"))
	h.add_child(_grid_btn)
	var zo := UI.icon_button("zoom-out", "Zoom out (-)", "Ghost")
	zo.pressed.connect(func(): action.emit("zoom_out"))
	h.add_child(zo)
	_zoom_lbl = UI.label("100%", "Dim")
	_zoom_lbl.custom_minimum_size.x = 48
	_zoom_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	h.add_child(_zoom_lbl)
	var zi := UI.icon_button("zoom-in", "Zoom in (+)", "Ghost")
	zi.pressed.connect(func(): action.emit("zoom_in"))
	h.add_child(zi)
	var fit := UI.icon_button("scan", "Fit farm (F / Home)", "Ghost")
	fit.pressed.connect(func(): action.emit("fit"))
	h.add_child(fit)
	var status_row := UI.hbox(12)
	status_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status = UI.label("", "Faint")
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_status.add_theme_constant_override("shadow_offset_y", 1)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	status_row.add_child(_status)
	add_child(status_row)


func _pill_row() -> HBoxContainer:
	## A centred floating row above the tools; starts hidden.
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.visible = false
	add_child(c)
	var p := PanelContainer.new()
	p.theme_type_variation = "Pill"
	c.add_child(p)
	var row := UI.hbox(4)
	p.add_child(row)
	row.set_meta("holder", c)
	return row


func _text_button(text: String, tip: String, cb: Callable) -> Button:
	var b := UI.button(text, "", tip, "Ghost")
	b.pressed.connect(cb)
	return b


func _spin(prefix: String, lo: int, hi: int, value: int, tip: String) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = value
	s.prefix = prefix
	s.tooltip_text = tip
	s.custom_minimum_size.x = 120
	s.value_changed.connect(func(_v: float): _emit_repeat())
	return s


func _build_context_rows() -> void:
	var sym := _pill_row()
	_sym_row = sym.get_meta("holder")
	sym.add_child(UI.label("Mirror over", "Dim"))
	for k in [[LayoutTools.KIND_SCREEN, "Screen centre line", "The game's own mirror: art flips and W×H swaps"],
			[LayoutTools.KIND_ACROSS, "Line across the road", "Reflects positions along the road"],
			[LayoutTools.KIND_ALONG, "Line along the road", "Reflects positions across the road"]]:
		var b := UI.button(k[1], "", k[2], "Segment")
		b.toggle_mode = true
		b.pressed.connect(func(): tool_action.emit("symmetry_kind", k[0]))
		sym.add_child(b)
		_kind_btns[k[0]] = b
	sym.add_child(VSeparator.new())
	sym.add_child(_text_button("Set line…", "Click a tile to put the mirror line through it", func(): tool_action.emit("symmetry_pick", null)))

	var sel := _pill_row()
	_sel_row = sel.get_meta("holder")
	_repeat_btn = UI.button("Repeat", "layout-grid", "Copy the selection as an N × M array", "Ghost")
	_repeat_btn.toggle_mode = true
	_repeat_btn.toggled.connect(func(on: bool): tool_action.emit("repeat", on))
	sel.add_child(_repeat_btn)
	sel.add_child(_text_button("Save stamp", "Keep the selection as a reusable group", func(): tool_action.emit("save_stamp", null)))
	sel.add_child(VSeparator.new())
	sel.add_child(UI.label("Align", "Dim"))
	for a in [["left", "Left", "Along the road: to the lowest end"], ["right", "Right", "Along the road: to the highest end"],
			["center_along", "Mid ↔", "Centre along the road"], ["top", "Top", "Across the road: to the far side"],
			["bottom", "Bottom", "Across the road: to the road side"], ["center_across", "Mid ↕", "Centre across the road"]]:
		var b := _text_button(a[1], a[2], func(): tool_action.emit("align", a[0]))
		sel.add_child(b)
		_align_btns.append(b)
	sel.add_child(VSeparator.new())
	sel.add_child(UI.label("Space", "Dim"))
	for d in [[LayoutTools.AXIS_ALONG, "Equal ↔", "Equal gaps along the road (first and last stay)"],
			[LayoutTools.AXIS_ACROSS, "Equal ↕", "Equal gaps across the road (first and last stay)"]]:
		var b := _text_button(d[1], d[2], func(): tool_action.emit("distribute", d[0]))
		sel.add_child(b)
		_dist_btns.append(b)

	var rep := _pill_row()
	_repeat_row = rep.get_meta("holder")
	_cols = _spin("Columns ", 1, LayoutTools.MAX_REPEAT_AXIS, 3, "Columns (along the road)")
	_rows = _spin("Rows ", 1, LayoutTools.MAX_REPEAT_AXIS, 1, "Rows (across the road)")
	_gap_x = _spin("gap ", 0, 40, 0, "Empty tiles between columns")
	_gap_y = _spin("gap ", 0, 40, 0, "Empty tiles between rows")
	for s: SpinBox in [_cols, _gap_x, _rows, _gap_y]:
		rep.add_child(s)
	rep.add_child(_text_button("Apply", "Place the copies (one undo step)", func(): tool_action.emit("repeat_apply", null)))


func _emit_repeat() -> void:
	tool_action.emit("repeat_params", {"cols": int(_cols.value), "rows": int(_rows.value), "gap": Vector2i(int(_gap_x.value), int(_gap_y.value))})


func update_context(selected: int, movable: int, repeat_open: bool) -> void:
	## What the selection allows: repeat / stamp need one object, align two,
	## equal spacing three movable ones.
	_sel_row.visible = selected > 0
	for b: Button in _align_btns:
		b.disabled = movable < 2
	for b: Button in _dist_btns:
		b.disabled = movable < 3
	_repeat_btn.set_pressed_no_signal(repeat_open)
	_repeat_row.visible = repeat_open


func update_symmetry(on: bool, kind: String) -> void:
	_sym_btn.set_pressed_no_signal(on)
	_sym_row.visible = on
	for k in _kind_btns:
		(_kind_btns[k] as Button).set_pressed_no_signal(k == kind)


func set_stamps_open(on: bool) -> void:
	_stamps_btn.set_pressed_no_signal(on)


func set_tool(t: String) -> void:
	if _btns.has(t):
		_btns[t].button_pressed = true


func set_zoom(z: float) -> void:
	_zoom_lbl.text = "%d%%" % roundi(z * 100.0)


func set_status(text: String) -> void:
	_status.text = text


func set_grid(on: bool) -> void:
	_grid_btn.button_pressed = on
