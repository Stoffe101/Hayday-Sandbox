class_name UI
extends RefCounted
## Small widget factory helpers so panels read declaratively.


static func button(text: String, icon: String = "", tooltip: String = "", variation: String = "") -> Button:
	var b := Button.new()
	b.text = text
	if not icon.is_empty():
		b.icon = Icons.get_icon(icon, 20)
	b.tooltip_text = tooltip
	if not variation.is_empty():
		b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return b


static func icon_button(icon: String, tooltip: String, variation: String = "Ghost", size: int = 20) -> Button:
	var b := Button.new()
	b.icon = Icons.get_icon(icon, size)
	b.tooltip_text = tooltip
	b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return b


static func label(text: String, variation: String = "", wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	if not variation.is_empty():
		l.theme_type_variation = variation
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


static func hbox(sep: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func vbox(sep: int = 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func spacer(h: bool = true) -> Control:
	var c := Control.new()
	if h:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func icon_rect(icon: String, size: int = 18, tint: Color = Color.WHITE) -> TextureRect:
	var t := TextureRect.new()
	t.texture = Icons.get_icon(icon, size)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(size, size)
	t.modulate = tint
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


static func section(text: String) -> Label:
	return label(text.to_upper(), "Section")


static func badge(text: String, col: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "Badge"
	var sb := UiTheme.box(Color(col.r, col.g, col.b, 0.16), 999, Color.TRANSPARENT, 0, Vector4(8, 1, 8, 1))
	p.add_theme_stylebox_override("panel", sb)
	var l := label(text, "BadgeLabel")
	l.add_theme_color_override("font_color", col)
	p.add_child(l)
	p.mouse_filter = Control.MOUSE_FILTER_PASS
	return p


static func card() -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "Card"
	return p


static func kv(key: String, value: String) -> HBoxContainer:
	var h := hbox(6)
	var k := label(key, "Dim")
	k.custom_minimum_size.x = 96
	h.add_child(k)
	var v := label(value)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	h.add_child(v)
	return h


static func clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


static func status_color(status: String) -> Color:
	match status:
		"confirmed", "original", "game_data": return UiTheme.c("accent")
		"community": return UiTheme.c("info")
		"approximation", "unverified": return UiTheme.c("warn")
		_: return UiTheme.c("danger")


static func status_text(status: String) -> String:
	match status:
		"confirmed": return "Confirmed"
		"game_data": return ItemDef.status_label("game_data")
		"community": return "Community data"
		"approximation": return "Approximate"
		"unverified": return "Unverified"
		"unknown": return "Size unknown"
		"original": return "Editor item"
	return status.capitalize()


static func art_badge(status: String) -> PanelContainer:
	## "Original art" (from an installed pack) / "Placeholder art" / "No art".
	match status:
		"original": return badge("Original art", UiTheme.c("accent"))
		"placeholder": return badge("Placeholder art", UiTheme.c("text_faint"))
	return badge("No art", UiTheme.c("warn"))


static func preview_mask(it: ItemDef) -> int:
	## Connection shape used for thumbnails: a straight run reads better
	## than an isolated post (fences) or a bordered tile (paths).
	if it == null or it.connect_group.is_empty():
		return -1
	return 15 if it.connect_style == "path" else (Connections.NE | Connections.SW)


static func fmt_int(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out
