class_name UiTheme
extends RefCounted
## Design system: palettes + a Theme built in code (no .tres to drift).
## Global UI scale uses Window.content_scale_factor; fonts are oversampled
## and icons rasterised at the scaled size, so everything stays crisp.

const DARK := {
	"name": "dark",
	"panel": Color("#1d2124f2"), "panel_solid": Color("#1d2124"), "panel_alt": Color("#262b2f"),
	"elevated": Color("#30363b"), "elevated_hover": Color("#3a4147"), "border": Color("#3b4248"),
	"text": Color("#eceae4"), "text_dim": Color("#a9ada8"), "text_faint": Color("#7a807b"),
	"accent": Color("#4cc27a"), "accent_hover": Color("#62d38e"), "accent_text": Color("#0e1a12"),
	"accent_soft": Color("#4cc27a33"), "warn": Color("#f2b33d"), "danger": Color("#ef5b4f"), "info": Color("#5aa9e6"),
	"shadow": Color(0, 0, 0, 0.45), "scrim": Color(0.04, 0.05, 0.05, 0.55), "planned": Color("#7fb3e6"),
}
const LIGHT := {
	"name": "light",
	"panel": Color("#fbf8f1f2"), "panel_solid": Color("#fbf8f1"), "panel_alt": Color("#f1ece0"),
	"elevated": Color("#ffffff"), "elevated_hover": Color("#f4f0e6"), "border": Color("#e0d9c8"),
	"text": Color("#2a2925"), "text_dim": Color("#68645a"), "text_faint": Color("#9a958a"),
	"accent": Color("#2f9a5a"), "accent_hover": Color("#37ad66"), "accent_text": Color("#ffffff"),
	"accent_soft": Color("#2f9a5a26"), "warn": Color("#c98a12"), "danger": Color("#d6453a"), "info": Color("#2f7fc0"),
	"shadow": Color(0.25, 0.2, 0.1, 0.22), "scrim": Color(0.2, 0.18, 0.12, 0.35), "planned": Color("#3f7fc4"),
}

static var palette: Dictionary = DARK
static var font_regular: FontVariation
static var font_bold: FontVariation
static var font_heavy: FontVariation


static func c(key: String) -> Color:
	return palette.get(key, Color.MAGENTA)


static func _fonts() -> void:
	if font_regular:
		return
	var base: FontFile = load("res://assets/ui/fonts/Nunito-Variable.ttf")
	if base == null:
		font_regular = FontVariation.new()
		font_regular.base_font = ThemeDB.fallback_font
		font_bold = font_regular
		font_heavy = font_regular
		return
	base.oversampling = 0.0
	font_regular = FontVariation.new()
	font_regular.base_font = base
	font_regular.variation_opentype = {"wght": 560}
	font_bold = FontVariation.new()
	font_bold.base_font = base
	font_bold.variation_opentype = {"wght": 750}
	font_heavy = FontVariation.new()
	font_heavy.base_font = base
	font_heavy.variation_opentype = {"wght": 900}


static func box(bg: Color, radius: int = 10, border: Color = Color.TRANSPARENT, bw: int = 0, pad: Vector4 = Vector4(10, 6, 10, 6)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.corner_detail = 6
	if bw > 0:
		s.border_color = border
		s.set_border_width_all(bw)
	s.content_margin_left = pad.x
	s.content_margin_top = pad.y
	s.content_margin_right = pad.z
	s.content_margin_bottom = pad.w
	s.anti_aliasing = true
	return s


static func build(dark: bool) -> Theme:
	palette = DARK if dark else LIGHT
	_fonts()
	var t := Theme.new()
	t.default_font = font_regular
	t.default_font_size = 15
	var P := palette
	# --- Panels --------------------------------------------------------
	var floating := box(P["panel"], 16, P["border"], 1, Vector4(12, 12, 12, 12))
	floating.shadow_color = P["shadow"]
	floating.shadow_size = 18
	floating.shadow_offset = Vector2(0, 6)
	t.set_stylebox("panel", "PanelContainer", box(P["panel_solid"], 0, Color.TRANSPARENT, 0, Vector4(0, 0, 0, 0)))
	t.set_type_variation("FloatingPanel", "PanelContainer")
	t.set_stylebox("panel", "FloatingPanel", floating)
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card", box(P["panel_alt"], 12, Color.TRANSPARENT, 0, Vector4(12, 10, 12, 10)))
	t.set_type_variation("Pill", "PanelContainer")
	var pill := box(P["panel"], 999, P["border"], 1, Vector4(8, 6, 8, 6))
	pill.shadow_color = P["shadow"]
	pill.shadow_size = 16
	pill.shadow_offset = Vector2(0, 5)
	t.set_stylebox("panel", "Pill", pill)
	t.set_type_variation("Toast", "PanelContainer")
	var toast := box(P["elevated"], 12, P["border"], 1, Vector4(14, 10, 16, 10))
	toast.shadow_color = P["shadow"]
	toast.shadow_size = 14
	t.set_stylebox("panel", "Toast", toast)
	t.set_type_variation("Modal", "PanelContainer")
	var modal := box(P["panel_solid"], 18, P["border"], 1, Vector4(22, 20, 22, 20))
	modal.shadow_color = Color(0, 0, 0, 0.5)
	modal.shadow_size = 40
	modal.shadow_offset = Vector2(0, 12)
	t.set_stylebox("panel", "Modal", modal)
	t.set_type_variation("Badge", "PanelContainer")
	t.set_stylebox("panel", "Badge", box(P["accent_soft"], 999, Color.TRANSPARENT, 0, Vector4(8, 2, 8, 2)))
	# --- Labels -----------------------------------------------------------
	t.set_color("font_color", "Label", P["text"])
	t.set_type_variation("Dim", "Label")
	t.set_color("font_color", "Dim", P["text_dim"])
	t.set_font_size("font_size", "Dim", 14)
	t.set_type_variation("Faint", "Label")
	t.set_color("font_color", "Faint", P["text_faint"])
	t.set_font_size("font_size", "Faint", 13)
	t.set_type_variation("Title", "Label")
	t.set_font("font", "Title", font_heavy)
	t.set_font_size("font_size", "Title", 22)
	t.set_type_variation("Heading", "Label")
	t.set_font("font", "Heading", font_bold)
	t.set_font_size("font_size", "Heading", 17)
	t.set_type_variation("Section", "Label")
	t.set_font("font", "Section", font_heavy)
	t.set_font_size("font_size", "Section", 12)
	t.set_color("font_color", "Section", P["text_faint"])
	t.set_type_variation("BadgeLabel", "Label")
	t.set_font("font", "BadgeLabel", font_bold)
	t.set_font_size("font_size", "BadgeLabel", 12)
	t.set_color("font_color", "BadgeLabel", P["accent"])
	# --- Buttons ----------------------------------------------------------
	var pad := Vector4(12, 7, 12, 7)
	t.set_stylebox("normal", "Button", box(P["elevated"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("hover", "Button", box(P["elevated_hover"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("pressed", "Button", box(P["accent_soft"], 10, P["accent"], 1, pad))
	t.set_stylebox("hover_pressed", "Button", box(P["accent_soft"], 10, P["accent"], 1, pad))
	t.set_stylebox("disabled", "Button", box(P["panel_alt"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("focus", "Button", box(Color.TRANSPARENT, 10, P["accent"], 2, pad))
	for k in ["font_color", "font_hover_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_focus_color"]:
		t.set_color(k, "Button", P["text"])
	for k in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(k, "Button", P["accent"])
	t.set_color("font_disabled_color", "Button", P["text_faint"])
	t.set_color("icon_disabled_color", "Button", P["text_faint"])
	t.set_constant("h_separation", "Button", 8)
	t.set_constant("icon_max_width", "Button", 20)
	t.set_font("font", "Button", font_bold)
	# Flat ghost buttons (toolbar, icon buttons)
	t.set_type_variation("Ghost", "Button")
	var gpad := Vector4(8, 6, 8, 6)
	t.set_stylebox("normal", "Ghost", box(Color.TRANSPARENT, 10, Color.TRANSPARENT, 0, gpad))
	t.set_stylebox("hover", "Ghost", box(P["elevated"], 10, Color.TRANSPARENT, 0, gpad))
	t.set_stylebox("pressed", "Ghost", box(P["accent_soft"], 10, Color.TRANSPARENT, 0, gpad))
	t.set_stylebox("hover_pressed", "Ghost", box(P["accent_soft"], 10, Color.TRANSPARENT, 0, gpad))
	t.set_stylebox("disabled", "Ghost", box(Color.TRANSPARENT, 10, Color.TRANSPARENT, 0, gpad))
	t.set_stylebox("focus", "Ghost", box(Color.TRANSPARENT, 10, P["accent"], 1, gpad))
	# Tool buttons (bigger, accent when pressed)
	t.set_type_variation("Tool", "Button")
	var tpad := Vector4(10, 8, 10, 8)
	t.set_stylebox("normal", "Tool", box(Color.TRANSPARENT, 999, Color.TRANSPARENT, 0, tpad))
	t.set_stylebox("hover", "Tool", box(P["elevated"], 999, Color.TRANSPARENT, 0, tpad))
	t.set_stylebox("pressed", "Tool", box(P["accent"], 999, Color.TRANSPARENT, 0, tpad))
	t.set_stylebox("hover_pressed", "Tool", box(P["accent_hover"], 999, Color.TRANSPARENT, 0, tpad))
	t.set_stylebox("focus", "Tool", box(Color.TRANSPARENT, 999, P["accent"], 1, tpad))
	t.set_constant("icon_max_width", "Tool", 22)
	for k in ["icon_pressed_color", "icon_hover_pressed_color", "font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(k, "Tool", P["accent_text"])
	# Primary call-to-action
	t.set_type_variation("Accent", "Button")
	t.set_stylebox("normal", "Accent", box(P["accent"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("hover", "Accent", box(P["accent_hover"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("pressed", "Accent", box(P["accent"].darkened(0.1), 10, Color.TRANSPARENT, 0, pad))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		t.set_color(k, "Accent", P["accent_text"])
	t.set_type_variation("Danger", "Button")
	t.set_stylebox("normal", "Danger", box(P["danger"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("hover", "Danger", box(P["danger"].lightened(0.1), 10, Color.TRANSPARENT, 0, pad))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "icon_normal_color", "icon_hover_color"]:
		t.set_color(k, "Danger", Color.WHITE)
	# Category chips
	t.set_type_variation("Chip", "Button")
	var cpad := Vector4(10, 4, 10, 4)
	t.set_stylebox("normal", "Chip", box(P["panel_alt"], 999, Color.TRANSPARENT, 0, cpad))
	t.set_stylebox("hover", "Chip", box(P["elevated_hover"], 999, Color.TRANSPARENT, 0, cpad))
	t.set_stylebox("pressed", "Chip", box(P["accent"], 999, Color.TRANSPARENT, 0, cpad))
	t.set_stylebox("hover_pressed", "Chip", box(P["accent_hover"], 999, Color.TRANSPARENT, 0, cpad))
	t.set_stylebox("focus", "Chip", box(Color.TRANSPARENT, 999, P["accent"], 1, cpad))
	t.set_font_size("font_size", "Chip", 13)
	t.set_constant("icon_max_width", "Chip", 16)
	t.set_constant("h_separation", "Chip", 5)
	for k in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(k, "Chip", P["accent_text"])
	# Segmented control
	t.set_type_variation("Segment", "Button")
	var spad := Vector4(14, 6, 14, 6)
	t.set_stylebox("normal", "Segment", box(Color.TRANSPARENT, 999, Color.TRANSPARENT, 0, spad))
	t.set_stylebox("hover", "Segment", box(P["elevated_hover"], 999, Color.TRANSPARENT, 0, spad))
	t.set_stylebox("pressed", "Segment", box(P["accent"], 999, Color.TRANSPARENT, 0, spad))
	t.set_stylebox("hover_pressed", "Segment", box(P["accent_hover"], 999, Color.TRANSPARENT, 0, spad))
	t.set_stylebox("focus", "Segment", box(Color.TRANSPARENT, 999, Color.TRANSPARENT, 0, spad))
	for k in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(k, "Segment", P["accent_text"])
	t.set_type_variation("SegmentBar", "PanelContainer")
	t.set_stylebox("panel", "SegmentBar", box(P["panel_alt"], 999, Color.TRANSPARENT, 0, Vector4(3, 3, 3, 3)))
	# --- Inputs ---------------------------------------------------------------
	var lpad := Vector4(12, 8, 12, 8)
	t.set_stylebox("normal", "LineEdit", box(P["panel_alt"], 10, P["border"], 1, lpad))
	t.set_stylebox("focus", "LineEdit", box(P["panel_alt"], 10, P["accent"], 2, lpad))
	t.set_stylebox("read_only", "LineEdit", box(P["panel_alt"], 10, Color.TRANSPARENT, 0, lpad))
	t.set_color("font_color", "LineEdit", P["text"])
	t.set_color("font_placeholder_color", "LineEdit", P["text_faint"])
	t.set_color("caret_color", "LineEdit", P["accent"])
	t.set_color("selection_color", "LineEdit", P["accent_soft"])
	t.set_stylebox("normal", "TextEdit", box(P["panel_alt"], 10, P["border"], 1, lpad))
	t.set_stylebox("focus", "TextEdit", box(P["panel_alt"], 10, P["accent"], 2, lpad))
	t.set_color("font_color", "TextEdit", P["text"])
	t.set_color("font_placeholder_color", "TextEdit", P["text_faint"])
	t.set_stylebox("normal", "OptionButton", box(P["elevated"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("hover", "OptionButton", box(P["elevated_hover"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("pressed", "OptionButton", box(P["elevated_hover"], 10, Color.TRANSPARENT, 0, pad))
	t.set_stylebox("focus", "OptionButton", box(Color.TRANSPARENT, 10, P["accent"], 1, pad))
	t.set_color("font_color", "OptionButton", P["text"])
	t.set_color("font_hover_color", "OptionButton", P["text"])
	t.set_font("font", "OptionButton", font_bold)
	for typ in ["CheckBox", "CheckButton"]:
		t.set_stylebox("normal", typ, box(Color.TRANSPARENT, 8, Color.TRANSPARENT, 0, Vector4(4, 4, 4, 4)))
		t.set_stylebox("hover", typ, box(P["elevated"], 8, Color.TRANSPARENT, 0, Vector4(4, 4, 4, 4)))
		t.set_stylebox("pressed", typ, box(Color.TRANSPARENT, 8, Color.TRANSPARENT, 0, Vector4(4, 4, 4, 4)))
		t.set_stylebox("hover_pressed", typ, box(P["elevated"], 8, Color.TRANSPARENT, 0, Vector4(4, 4, 4, 4)))
		t.set_stylebox("focus", typ, box(Color.TRANSPARENT, 8, P["accent"], 1, Vector4(4, 4, 4, 4)))
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			t.set_color(k, typ, P["text"])
	t.set_stylebox("slider", "HSlider", box(P["panel_alt"], 999, Color.TRANSPARENT, 0, Vector4(0, 3, 0, 3)))
	t.set_stylebox("grabber_area", "HSlider", box(P["accent"], 999, Color.TRANSPARENT, 0, Vector4(0, 3, 0, 3)))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(P["accent_hover"], 999, Color.TRANSPARENT, 0, Vector4(0, 3, 0, 3)))
	t.set_icon("grabber", "HSlider", _dot(16, P["text"]))
	t.set_icon("grabber_highlight", "HSlider", _dot(16, P["accent_hover"]))
	t.set_stylebox("normal", "SpinBox", box(P["panel_alt"], 10, P["border"], 1, lpad))
	# --- Lists / scroll ---------------------------------------------------------
	t.set_stylebox("panel", "ItemList", box(Color.TRANSPARENT, 10, Color.TRANSPARENT, 0, Vector4(2, 2, 2, 2)))
	t.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("selected", "ItemList", box(P["accent_soft"], 12, P["accent"], 2, Vector4(4, 4, 4, 4)))
	t.set_stylebox("selected_focus", "ItemList", box(P["accent_soft"], 12, P["accent"], 2, Vector4(4, 4, 4, 4)))
	t.set_stylebox("hovered", "ItemList", box(P["elevated"], 12, Color.TRANSPARENT, 0, Vector4(4, 4, 4, 4)))
	t.set_stylebox("hovered_selected", "ItemList", box(P["accent_soft"], 12, P["accent"], 2, Vector4(4, 4, 4, 4)))
	t.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	t.set_color("font_color", "ItemList", P["text_dim"])
	t.set_color("font_selected_color", "ItemList", P["text"])
	t.set_color("font_hovered_color", "ItemList", P["text"])
	t.set_color("guide_color", "ItemList", Color.TRANSPARENT)
	t.set_constant("h_separation", "ItemList", 6)
	t.set_constant("v_separation", "ItemList", 6)
	t.set_constant("icon_margin", "ItemList", 4)
	t.set_constant("line_separation", "ItemList", 2)
	t.set_font_size("font_size", "ItemList", 12)
	t.set_font("font", "ItemList", font_bold)
	for sb in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb, box(Color.TRANSPARENT, 999, Color.TRANSPARENT, 0, Vector4(3, 3, 3, 3)))
		t.set_stylebox("grabber", sb, box(P["elevated_hover"], 999, Color.TRANSPARENT, 0, Vector4(3, 3, 3, 3)))
		t.set_stylebox("grabber_highlight", sb, box(P["text_faint"], 999, Color.TRANSPARENT, 0, Vector4(3, 3, 3, 3)))
		t.set_stylebox("grabber_pressed", sb, box(P["accent"], 999, Color.TRANSPARENT, 0, Vector4(3, 3, 3, 3)))
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	# --- Popups / tooltips / dialogs ------------------------------------------------
	var pop := box(P["elevated"], 12, P["border"], 1, Vector4(6, 6, 6, 6))
	pop.shadow_color = P["shadow"]
	pop.shadow_size = 14
	t.set_stylebox("panel", "PopupMenu", pop)
	t.set_stylebox("hover", "PopupMenu", box(P["accent_soft"], 8, Color.TRANSPARENT, 0, Vector4(8, 4, 8, 4)))
	t.set_stylebox("separator", "PopupMenu", box(P["border"], 0, Color.TRANSPARENT, 0, Vector4(0, 1, 0, 1)))
	t.set_color("font_color", "PopupMenu", P["text"])
	t.set_color("font_hover_color", "PopupMenu", P["text"])
	t.set_color("font_disabled_color", "PopupMenu", P["text_faint"])
	t.set_color("font_accelerator_color", "PopupMenu", P["text_faint"])
	t.set_constant("v_separation", "PopupMenu", 8)
	t.set_constant("item_start_padding", "PopupMenu", 10)
	t.set_constant("item_end_padding", "PopupMenu", 12)
	t.set_stylebox("panel", "TooltipPanel", box(P["text"], 8, Color.TRANSPARENT, 0, Vector4(10, 6, 10, 6)))
	t.set_color("font_color", "TooltipLabel", P["panel_solid"])
	t.set_font_size("font_size", "TooltipLabel", 13)
	t.set_font("font", "TooltipLabel", font_bold)
	t.set_stylebox("embedded_border", "Window", modal)
	t.set_stylebox("embedded_unfocused_border", "Window", modal)
	t.set_color("title_color", "Window", P["text"])
	t.set_font("title_font", "Window", font_bold)
	t.set_stylebox("panel", "AcceptDialog", box(P["panel_solid"], 0, Color.TRANSPARENT, 0, Vector4(16, 12, 16, 12)))
	t.set_stylebox("panel", "PopupPanel", pop)
	t.set_stylebox("separator", "HSeparator", box(P["border"], 0, Color.TRANSPARENT, 0, Vector4(0, 1, 0, 1)))
	t.set_constant("separation", "HSeparator", 12)
	t.set_stylebox("separator", "VSeparator", box(P["border"], 0, Color.TRANSPARENT, 0, Vector4(1, 0, 1, 0)))
	t.set_constant("separation", "VSeparator", 10)
	t.set_stylebox("background", "ProgressBar", box(P["panel_alt"], 999, Color.TRANSPARENT, 0, Vector4(0, 0, 0, 0)))
	t.set_stylebox("fill", "ProgressBar", box(P["accent"], 999, Color.TRANSPARENT, 0, Vector4(0, 0, 0, 0)))
	t.set_color("default_color", "RichTextLabel", P["text"])
	t.set_font("bold_font", "RichTextLabel", font_bold)
	t.set_font("normal_font", "RichTextLabel", font_regular)
	t.set_font_size("normal_font_size", "RichTextLabel", 14)
	t.set_font_size("bold_font_size", "RichTextLabel", 14)
	t.set_stylebox("tab_selected", "TabBar", box(P["accent_soft"], 999, Color.TRANSPARENT, 0, Vector4(12, 5, 12, 5)))
	t.set_stylebox("tab_unselected", "TabBar", box(Color.TRANSPARENT, 999, Color.TRANSPARENT, 0, Vector4(12, 5, 12, 5)))
	t.set_stylebox("tab_hovered", "TabBar", box(P["elevated"], 999, Color.TRANSPARENT, 0, Vector4(12, 5, 12, 5)))
	t.set_stylebox("tab_focus", "TabBar", StyleBoxEmpty.new())
	t.set_color("font_selected_color", "TabBar", P["accent"])
	t.set_color("font_unselected_color", "TabBar", P["text_dim"])
	t.set_color("font_hovered_color", "TabBar", P["text"])
	t.set_font("font", "TabBar", font_bold)
	t.set_constant("h_separation", "TabBar", 6)
	t.set_constant("icon_max_width", "TabBar", 18)
	return t


static func _dot(size: int, col: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r := size * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			var a := clampf(r - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	return ImageTexture.create_from_image(img)
