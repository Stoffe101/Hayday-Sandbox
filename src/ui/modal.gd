class_name Modal
extends Control
## Full-window scrim + centred card. Esc or clicking the scrim closes it
## (unless `blocking`). Content goes into `body`.

signal closed

var card: PanelContainer
var body: VBoxContainer
var title_label: Label
var footer: HBoxContainer
var blocking := false


static func open(parent: Control, title: String, width: float = 520.0, icon: String = "") -> Modal:
	var m := Modal.new()
	parent.add_child(m)
	m._build(title, width, icon)
	return m


func _build(title: String, width: float, icon: String) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var scrim := ColorRect.new()
	scrim.color = UiTheme.c("scrim")
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and not blocking:
			close())
	add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	card = PanelContainer.new()
	card.theme_type_variation = "Modal"
	# Never wider than the window (small windows, large UI scales).
	card.custom_minimum_size.x = minf(width, get_viewport_rect().size.x - 32.0)
	center.add_child(card)
	var v := UI.vbox(14)
	card.add_child(v)
	var head := UI.hbox(10)
	if not icon.is_empty():
		head.add_child(UI.icon_rect(icon, 24, UiTheme.c("accent")))
	title_label = UI.label(title, "Title")
	head.add_child(title_label)
	head.add_child(UI.spacer())
	var x := UI.icon_button("x", "Close (Esc)")
	x.pressed.connect(close)
	head.add_child(x)
	v.add_child(head)
	body = UI.vbox(10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)
	footer = UI.hbox(8)
	footer.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(footer)
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.12)


func _unhandled_key_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE and not blocking:
		close()
		get_viewport().set_input_as_handled()


func add_button(text: String, variation: String = "", cb: Callable = Callable(), icon: String = "") -> Button:
	var b := UI.button(text, icon, "", variation)
	b.custom_minimum_size.x = 96
	if cb.is_valid():
		b.pressed.connect(cb)
	footer.add_child(b)
	return b


func close() -> void:
	closed.emit()
	queue_free()


static func prompt(parent: Control, title: String, initial: String, cb: Callable, placeholder: String = "") -> Modal:
	var m := open(parent, title, 440, "pencil")
	var le := LineEdit.new()
	le.text = initial
	le.placeholder_text = placeholder
	le.select_all_on_focus = true
	m.body.add_child(le)
	var ok := func():
		var t := le.text
		m.close()
		cb.call(t)
	le.text_submitted.connect(func(_t): ok.call())
	m.add_button("Cancel", "", m.close)
	m.add_button("OK", "Accent", ok)
	le.call_deferred("grab_focus")
	return m


static func confirm(parent: Control, title: String, text: String, ok_text: String, danger: bool, cb: Callable) -> Modal:
	var m := open(parent, title, 460, "circle-x" if danger else "info")
	m.body.add_child(UI.label(text, "Dim", true))
	m.add_button("Cancel", "", m.close)
	m.add_button(ok_text, "Danger" if danger else "Accent", func():
		m.close()
		cb.call())
	return m
