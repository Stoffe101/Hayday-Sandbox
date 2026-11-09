class_name TopBar
extends PanelContainer
## Title bar: brand, layout name, mode switch, document actions.

signal action(name: String)

var _name_btn: Button
var _dirty: Label
var _mode_creative: Button
var _mode_real: Button
var _undo: Button
var _redo: Button
var _left_toggle: Button
var _right_toggle: Button


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
	var brand := UI.label("Hayday Sandbox", "Heading")
	h.add_child(brand)
	h.add_child(VSeparator.new())
	_name_btn = UI.button("Untitled farm", "pencil", "Rename layout", "Ghost")
	_name_btn.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_name_btn.pressed.connect(func(): action.emit("rename"))
	_name_btn.custom_minimum_size.x = 180
	_name_btn.clip_text = true
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
	_mode_creative = UI.button("Creative", "wand-sparkles", "Unlimited design (Ctrl+M toggles)", "Segment")
	_mode_creative.toggle_mode = true
	_mode_creative.pressed.connect(func(): action.emit("mode_creative"))
	sh.add_child(_mode_creative)
	_mode_real = UI.button("Realistic", "clipboard-check", "Check against your level, inventory and land", "Segment")
	_mode_real.toggle_mode = true
	_mode_real.pressed.connect(func(): action.emit("mode_realistic"))
	sh.add_child(_mode_real)
	h.add_child(seg)
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
	_undo.disabled = not s.stack.can_undo()
	_redo.disabled = not s.stack.can_redo()
	_undo.tooltip_text = "Undo %s (Ctrl+Z)" % s.stack.undo_label() if s.stack.can_undo() else "Nothing to undo"
	_redo.tooltip_text = "Redo %s (Ctrl+Shift+Z)" % s.stack.redo_label() if s.stack.can_redo() else "Nothing to redo"


func set_panels(left: bool, right: bool) -> void:
	_left_toggle.button_pressed = left
	_right_toggle.button_pressed = right
