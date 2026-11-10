class_name BudgetWidget
extends PanelContainer
## Budget chip floating over the farm (docs/PLANNING.md §4): what the current
## scope costs in the current mode, per currency (never converted), with the
## unknowns counted next to it. Scope follows the selection, then the active
## area, then the active phase, else the whole farm (or is pinned to the whole
## farm). Three sizes: one line (collapsed), one line + a note, or with the
## breakdown card. Sits in a canvas corner (menu; remembered in the settings).
## Refreshes on PlanContext.changed (coalesced per frame), never per frame.

signal open_tab(tab_id: String)
## Size, corner or visibility changed: main.gd places it again (and stores the setting).
signal layout_changed
signal setting(key: String, value: Variant)

const MENU_BREAKDOWN := 1
const MENU_COLLAPSE := 2
const MENU_TAB := 3
const MENU_HIDE := 4
const MENU_CORNER := 10
const CARD_WIDTH := 320.0
const SCOPE_CHARS := 22

var ctx: PlanContext
var corner := "bl"
var collapsed := false
var expanded := false

var _scope_btn: Button
var _amounts: HBoxContainer
var _warn: Button
var _mode_btn: Button
var _menu_btn: Button
var _note: Label
var _card: VBoxContainer
var _scope_pop: PopupMenu
var _mode_pop: PopupMenu
var _menu_pop: PopupMenu
var _sig := ""
var last_totals: BudgetEngine.Totals   ## what is shown (tests)


func setup(context: PlanContext) -> void:
	ctx = context
	var sb := UiTheme.box(UiTheme.c("panel"), 14, UiTheme.c("border"), 1, Vector4(8, 4, 8, 6))
	sb.shadow_color = UiTheme.c("shadow")
	sb.shadow_size = 12
	sb.shadow_offset = Vector2(0, 4)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := UI.vbox(2)
	add_child(v)
	var row := UI.hbox(4)
	v.add_child(row)
	_scope_btn = UI.button("", "target", "", "Ghost")
	_scope_btn.add_theme_font_size_override("font_size", 13)
	_scope_btn.pressed.connect(_open_scope_menu)
	row.add_child(_scope_btn)
	_amounts = UI.hbox(10)
	_amounts.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_amounts)
	_warn = UI.button("", "circle-question-mark", "", "Ghost")
	_warn.add_theme_color_override("font_color", UiTheme.c("warn"))
	_warn.add_theme_color_override("icon_normal_color", UiTheme.c("warn"))
	_warn.add_theme_color_override("font_hover_color", UiTheme.c("warn"))
	_warn.add_theme_color_override("icon_hover_color", UiTheme.c("warn"))
	_warn.add_theme_font_size_override("font_size", 13)
	_warn.pressed.connect(func(): set_expanded(not expanded))
	row.add_child(_warn)
	_mode_btn = UI.button("", "", "", "Ghost")
	_mode_btn.add_theme_font_size_override("font_size", 13)
	_mode_btn.pressed.connect(_open_mode_menu)
	row.add_child(_mode_btn)
	_menu_btn = UI.icon_button("ellipsis-vertical", "Budget: breakdown, size, corner", "Ghost", 18)
	_menu_btn.pressed.connect(_open_menu)
	row.add_child(_menu_btn)
	_note = UI.label("", "Faint")
	_note.add_theme_font_size_override("font_size", 12)
	_note.mouse_filter = Control.MOUSE_FILTER_PASS
	var nm := MarginContainer.new()
	nm.add_theme_constant_override("margin_left", 8)
	nm.add_theme_constant_override("margin_right", 8)
	nm.add_child(_note)
	v.add_child(nm)
	_card = UI.vbox(6)
	_card.custom_minimum_size.x = CARD_WIDTH
	var cm := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_bottom"]:
		cm.add_theme_constant_override(side, 8)
	cm.add_child(_card)
	v.add_child(cm)
	_scope_pop = _popup()
	_scope_pop.add_radio_check_item("Follow the selection, area or phase", 0)
	_scope_pop.add_radio_check_item("Whole farm (pinned)", 1)
	_scope_pop.id_pressed.connect(func(id: int): ctx.set_scope_pin("farm" if id == 1 else "auto"))
	_mode_pop = _popup()
	for i in BudgetEngine.MODES.size():
		var m: String = BudgetEngine.MODES[i]
		_mode_pop.add_radio_check_item(str(PlanScope.MODE_LABELS[m]), i)
		_mode_pop.set_item_tooltip(i, str(PlanScope.MODE_HELP[m]))
	_mode_pop.id_pressed.connect(func(id: int): ctx.set_mode(BudgetEngine.MODES[id]))
	_menu_pop = _popup()
	_menu_pop.id_pressed.connect(_on_menu)
	ctx.changed.connect(refresh)
	ctx.session_changed.connect(refresh)
	visibility_changed.connect(func():
		if is_visible_in_tree():
			refresh())
	_apply_size()
	refresh()


func _popup() -> PopupMenu:
	var p := PopupMenu.new()
	add_child(p)
	return p


func configure(corner_id: String, is_collapsed: bool, is_expanded: bool) -> void:
	corner = corner_id if corner_id in PlanScope.CORNERS else "bl"
	collapsed = is_collapsed
	expanded = is_expanded
	_apply_size()
	_sig = ""
	refresh()


## Set by main.gd when the free canvas is small (1080p at 200 %): the notes line
## is dropped unless the breakdown is open (the user's own choice is kept).
var tight := false


func set_tight(on: bool) -> void:
	if on == tight:
		return
	tight = on
	_apply_size()


func _apply_size() -> void:
	if _note == null:
		return
	_note.get_parent().visible = not collapsed and (not tight or expanded)
	_card.get_parent().visible = expanded and not collapsed


func set_expanded(on: bool) -> void:
	expanded = on
	if on:
		collapsed = false
		setting.emit("budget_collapsed", false)
	setting.emit("budget_expanded", on)
	_apply_size()
	_sig = ""
	refresh()
	layout_changed.emit()


func set_collapsed(on: bool) -> void:
	collapsed = on
	if on:
		expanded = false
		setting.emit("budget_expanded", false)
	setting.emit("budget_collapsed", on)
	_apply_size()
	_sig = ""
	refresh()
	layout_changed.emit()


# --- menus -------------------------------------------------------------------------------

func _popup_at(p: PopupMenu, b: Control) -> void:
	var r := b.get_global_rect()
	p.reset_size()
	var at := Vector2(r.position.x, r.end.y + 4.0)
	if corner.begins_with("b"):
		at.y = r.position.y - p.get_contents_minimum_size().y - 8.0
	p.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


func _open_scope_menu() -> void:
	_scope_pop.set_item_checked(0, ctx.scope_pin != "farm")
	_scope_pop.set_item_checked(1, ctx.scope_pin == "farm")
	_popup_at(_scope_pop, _scope_btn)


func _open_mode_menu() -> void:
	for i in BudgetEngine.MODES.size():
		_mode_pop.set_item_checked(i, BudgetEngine.MODES[i] == ctx.mode)
	_popup_at(_mode_pop, _mode_btn)


func _open_menu() -> void:
	var p := _menu_pop
	p.clear()
	p.add_item("Hide breakdown" if expanded else "Show breakdown", MENU_BREAKDOWN)
	p.add_item("Show the notes line" if collapsed else "One line only", MENU_COLLAPSE)
	p.add_item("Open the Budget tab", MENU_TAB)
	p.add_separator("Corner")
	for i in PlanScope.CORNERS.size():
		var c: String = PlanScope.CORNERS[i]
		p.add_radio_check_item(str(PlanScope.CORNER_NAMES[c]), MENU_CORNER + i)
		p.set_item_checked(p.item_count - 1, c == corner)
	p.add_separator()
	p.add_item("Hide (View tab shows it again)", MENU_HIDE)
	_popup_at(p, _menu_btn)


func _on_menu(id: int) -> void:
	match id:
		MENU_BREAKDOWN: set_expanded(not expanded)
		MENU_COLLAPSE: set_collapsed(not collapsed)
		MENU_TAB: open_tab.emit("budget")
		MENU_HIDE: setting.emit("budget_visible", false)
		_:
			var i := id - MENU_CORNER
			if i >= 0 and i < PlanScope.CORNERS.size():
				corner = PlanScope.CORNERS[i]
				setting.emit("budget_corner", corner)
				layout_changed.emit()


# --- content -------------------------------------------------------------------------------

func refresh() -> void:
	if ctx == null or _amounts == null or not is_visible_in_tree():
		return
	if ctx.engine == null:
		_scope_btn.text = "No budget"
		return
	var sc := ctx.scope()
	var t := ctx.scope_totals()
	last_totals = t
	# The engine's instance id too: another layout's engine counts versions from 0 again.
	var sig := "%d/%d|%s|%s|%s|%s|%s|%d%d" % [ctx.engine.get_instance_id(), ctx.engine.version, ctx.mode, str(sc.get("kind")), str(sc.get("id")), str(sc.get("uids").hash() if sc.get("uids") is Array else 0), ctx.scope_pin, int(collapsed), int(expanded)]
	if ctx.session != null:
		sig += "|%d" % ctx.session.stack.version
	if sig == _sig:
		return
	_sig = sig
	_fill_row(sc, t)
	_note.text = _note_text(t)
	_note.tooltip_text = _note.text
	if expanded and not collapsed:
		_fill_card(sc, t)
	layout_changed.emit()


func _fill_row(sc: Dictionary, t: BudgetEngine.Totals) -> void:
	var kind := str(sc.get("kind"))
	var short := str(sc.get("label", ""))
	match kind:
		PlanScope.SCOPE_SELECTION:
			short = "Selection (%d)" % (sc.get("uids", []) as Array).size()
		PlanScope.SCOPE_AREA, PlanScope.SCOPE_PHASE:
			short = short.get_slice(" · ", 1)
	_scope_btn.text = short if short.length() <= SCOPE_CHARS else short.left(SCOPE_CHARS - 1) + "…"
	_scope_btn.icon = Icons.get_icon("lock" if ctx.scope_pin == "farm" else ("mouse-pointer-2" if kind == PlanScope.SCOPE_SELECTION else ("square-dashed" if kind == PlanScope.SCOPE_AREA else ("layers" if kind == PlanScope.SCOPE_PHASE else "tent-tree"))), 16)
	_scope_btn.tooltip_text = "Budget of: %s%s\nClick: follow the selection / area / phase, or pin the whole farm." % [
		str(sc.get("label", "")), " (pinned)" if ctx.scope_pin == "farm" else ""]
	UI.clear(_amounts)
	var ids := Currency.sorted_ids(t.cost.keys())
	if ids.is_empty():
		var l := UI.label("Nothing to pay" if t.is_exact() else "No known price", "Dim")
		l.add_theme_font_size_override("font_size", 14)
		_amounts.add_child(l)
	var shown := 0
	for c: String in ids:
		if shown >= 4:
			var more := UI.label("+%d" % (ids.size() - shown), "Faint")
			more.tooltip_text = Currency.format_line(t.cost)
			_amounts.add_child(more)
			break
		_amounts.add_child(amount_chip(c, int(t.cost[c]), ids.size() > 2))
		shown += 1
	var unknown := t.unknown_price_objects + t.not_buyable_objects
	_warn.visible = unknown > 0 or not t.unknown_cost_plots.is_empty()
	_warn.text = "+%d" % unknown if unknown > 0 else "+?"
	_warn.tooltip_text = "Not included in the total: %s.\nUnknown prices are counted, never treated as 0. Click for the breakdown." % PlanScope.unknown_text(t)
	_mode_btn.text = str(PlanScope.MODE_LABELS.get(ctx.mode, ctx.mode)) + " ▾"
	_mode_btn.tooltip_text = "%s\n\nClick to switch: Design cost · To buy · Remaining." % str(PlanScope.MODE_HELP.get(ctx.mode, ""))


func _note_text(t: BudgetEngine.Totals) -> String:
	var parts: PackedStringArray = [str(PlanScope.MODE_DEDUCTS.get(ctx.mode, ""))]
	parts.append("%d object%s" % [t.objects, "" if t.objects == 1 else "s"])
	if t.unknown_price_objects > 0:
		parts.append("%d unknown price" % t.unknown_price_objects)
	if t.not_buyable_objects > 0:
		parts.append("%d can't be bought" % t.not_buyable_objects)
	if ctx.mode != BudgetEngine.MODE_DESIGN and not t.unknown_ownership_types.is_empty():
		parts.append("%d type%s: ownership unknown" % [t.unknown_ownership_types.size(), "" if t.unknown_ownership_types.size() == 1 else "s"])
	return " · ".join(parts)


func _fill_card(sc: Dictionary, t: BudgetEngine.Totals) -> void:
	UI.clear(_card)
	var head := UI.label("%s — %s" % [str(sc.get("label", "")), str(PlanScope.MODE_LABELS.get(ctx.mode, ""))], "Heading", true)
	head.add_theme_font_size_override("font_size", 15)
	_card.add_child(head)
	_card.add_child(UI.label(str(PlanScope.MODE_HELP.get(ctx.mode, "")), "Faint", true))
	for c: String in Currency.sorted_ids(t.object_cost.keys()):
		_card.add_child(currency_row(c, int(t.object_cost[c]), ""))
	if t.object_cost.is_empty():
		_card.add_child(UI.label("Objects: nothing to pay" if t.unknown_price_objects + t.not_buyable_objects == 0 else "Objects: no known price", "Dim"))
	if ctx.mode != BudgetEngine.MODE_DESIGN and not t.plots.is_empty():
		var land := "Land: %d expansion plot%s — %s" % [t.plots.size(), "" if t.plots.size() == 1 else "s", Currency.format_line(t.land_cost, "no supplies known", "supplies unknown")]
		if not t.unknown_cost_plots.is_empty():
			land += " (+%d with unknown supplies)" % t.unknown_cost_plots.size()
		_card.add_child(UI.label(land, "Dim", true))
	var counts := "%d object%s · %d charged · %d owned · %d bought · %d placed" % [t.objects, "" if t.objects == 1 else "s",
		t.charged_objects, t.owned_objects, t.acquired_objects, t.placed_objects]
	_card.add_child(UI.label(counts, "Faint", true))
	if t.unknown_price_objects > 0:
		_card.add_child(_warn_line("%d object%s of %d type%s with unknown price — not in the total" % [t.unknown_price_objects,
			"" if t.unknown_price_objects == 1 else "s", t.unknown_price_types.size(), "" if t.unknown_price_types.size() == 1 else "s"]))
	if t.not_buyable_objects > 0:
		_card.add_child(_warn_line("%d object%s of %d type%s can't be bought (rewards, not in the shop)" % [t.not_buyable_objects,
			"" if t.not_buyable_objects == 1 else "s", t.not_buyable_types.size(), "" if t.not_buyable_types.size() == 1 else "s"]))
	if ctx.mode != BudgetEngine.MODE_DESIGN and not t.unknown_ownership_types.is_empty():
		_card.add_child(UI.label("%d item type%s without inventory: counted as to buy (an upper bound). Record what you own in the Budget tab." % [
			t.unknown_ownership_types.size(), "" if t.unknown_ownership_types.size() == 1 else "s"], "Faint", true))
	for om: Dictionary in t.over_max:
		_card.add_child(_warn_line("%s: %d in the design, the game allows %d" % [ctx.item_name(str(om.get("item"))), int(om.get("count", 0)), int(om.get("max", 0))]))
	if str(sc.get("kind")) == PlanScope.SCOPE_AREA:
		var others := {}
		for a in PlanDoc.areas(ctx.plan()):
			others[str(a.get("id"))] = ctx.engine.area_uids(str(a.get("id")))
		var sh := PlanScope.shared_objects(others)
		var mine := 0
		for p: Array in sh["pairs"]:
			if p[0] == sc["id"] or p[1] == sc["id"]:
				mine += int(p[2])
		if mine > 0:
			_card.add_child(UI.label("This area shares objects with other areas: area totals are not additive.", "Faint", true))
	var b := UI.button("Budget tab", "coins", "Totals side by side, unknown prices, targets (J)", "Ghost")
	b.pressed.connect(func(): open_tab.emit("budget"))
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_card.add_child(b)


func _warn_line(text: String) -> Label:
	var l := UI.label(text, "Dim", true)
	l.add_theme_color_override("font_color", UiTheme.c("warn"))
	return l


# --- shared pieces (tabs use them too) ------------------------------------------------------------

static func amount_chip(currency: String, amount: int, short: bool = false) -> HBoxContainer:
	## Glyph + amount; the tooltip names the currency and the exact amount.
	var h := UI.hbox(4)
	h.mouse_filter = Control.MOUSE_FILTER_PASS
	h.tooltip_text = "%s %s" % [Currency.format_amount(amount), Currency.unit_name(currency, amount)]
	h.add_child(glyph(currency, 16))
	var l := UI.label(PlanScope.abbreviate(amount) if short else Currency.format_amount(amount))
	l.add_theme_font_size_override("font_size", 14)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	h.add_child(l)
	return h


static func currency_row(currency: String, amount: int, suffix: String) -> HBoxContainer:
	var h := UI.hbox(6)
	h.add_child(glyph(currency, 16))
	var l := UI.label("%s %s%s" % [Currency.format_amount(amount), Currency.unit_name(currency, amount), suffix])
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	h.add_child(l)
	return h


static func glyph(currency: String, size: int = 16) -> Glyph:
	var g := Glyph.new()
	g.currency = currency
	g.custom_minimum_size = Vector2(size, size)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return g


## Original vector currency marks (never game art): gold coin, green diamond,
## coloured voucher tickets, film, key, expansion supplies, "?" for others.
class Glyph:
	extends Control
	var currency := ""

	const VOUCHER_COLORS := {"voucher_green": Color("#4fae55"), "voucher_blue": Color("#4a8fdb"),
		"voucher_purple": Color("#9a6ad6"), "voucher_gold": Color("#e2b23a")}

	func _draw() -> void:
		var s := minf(size.x, size.y)
		var c := size * 0.5
		var r := s * 0.5
		match currency:
			"coins":
				draw_circle(c, r, Color("#a8770f"))
				draw_circle(c, r * 0.84, Color("#f5c842"))
				draw_arc(c, r * 0.56, 0, TAU, 20, Color("#c9951c"), maxf(1.0, s * 0.08), true)
				draw_circle(c + Vector2(-r * 0.32, -r * 0.34), r * 0.16, Color(1, 1, 1, 0.75))
			"diamonds":
				var pts := PackedVector2Array([c + Vector2(-r * 0.9, -r * 0.25), c + Vector2(-r * 0.45, -r * 0.8), c + Vector2(r * 0.45, -r * 0.8),
					c + Vector2(r * 0.9, -r * 0.25), c + Vector2(0, r * 0.92)])
				draw_colored_polygon(pts, Color("#2fae6a"))
				draw_colored_polygon(PackedVector2Array([c + Vector2(-r * 0.45, -r * 0.8), c + Vector2(r * 0.1, -r * 0.8), c + Vector2(-r * 0.2, -r * 0.25), c + Vector2(-r * 0.9, -r * 0.25)]), Color("#7fe0a6"))
				var closed := pts.duplicate()
				closed.append(pts[0])
				draw_polyline(closed, Color("#14683c"), maxf(1.0, s * 0.07), true)
			"voucher_green", "voucher_blue", "voucher_purple", "voucher_gold":
				var col: Color = VOUCHER_COLORS[currency]
				var rect := Rect2(c - Vector2(r * 0.95, r * 0.62), Vector2(r * 1.9, r * 1.24))
				draw_rect(rect, col.darkened(0.35))
				draw_rect(rect.grow(-maxf(1.0, s * 0.07)), col)
				draw_circle(Vector2(rect.position.x, c.y), r * 0.24, Color(0, 0, 0, 0))
				draw_circle(Vector2(rect.position.x, c.y), r * 0.22, col.darkened(0.55))
				draw_circle(Vector2(rect.end.x, c.y), r * 0.22, col.darkened(0.55))
				draw_line(Vector2(c.x + r * 0.25, rect.position.y + 2), Vector2(c.x + r * 0.25, rect.end.y - 2), Color(1, 1, 1, 0.6), 1.0)
			"film":
				var fr := Rect2(c - Vector2(r * 0.9, r * 0.7), Vector2(r * 1.8, r * 1.4))
				draw_rect(fr, Color("#2b2b30"))
				for i in 3:
					var x := fr.position.x + fr.size.x * (0.2 + 0.3 * i)
					draw_rect(Rect2(x - r * 0.1, fr.position.y + r * 0.12, r * 0.2, r * 0.2), Color(0.9, 0.9, 0.9))
					draw_rect(Rect2(x - r * 0.1, fr.end.y - r * 0.32, r * 0.2, r * 0.2), Color(0.9, 0.9, 0.9))
			"golden_keys":
				draw_circle(c + Vector2(-r * 0.4, 0), r * 0.42, Color("#e2b23a"))
				draw_circle(c + Vector2(-r * 0.4, 0), r * 0.18, Color(0.15, 0.12, 0.05))
				draw_rect(Rect2(c + Vector2(-r * 0.05, -r * 0.12), Vector2(r * 0.95, r * 0.24)), Color("#e2b23a"))
				draw_rect(Rect2(c + Vector2(r * 0.6, 0), Vector2(r * 0.18, r * 0.4)), Color("#e2b23a"))
			"land_deed", "expansion_permit":
				var pr := Rect2(c - Vector2(r * 0.7, r * 0.9), Vector2(r * 1.4, r * 1.8))
				draw_rect(pr, Color("#e9dcb8") if currency == "land_deed" else Color("#bcd3ef"))
				for i in 3:
					var y := pr.position.y + pr.size.y * (0.3 + 0.2 * i)
					draw_line(Vector2(pr.position.x + r * 0.25, y), Vector2(pr.end.x - r * 0.25, y), Color(0.3, 0.25, 0.2, 0.8), 1.0)
			"mallet":
				draw_rect(Rect2(c + Vector2(-r * 0.12, -r * 0.2), Vector2(r * 0.24, r * 1.1)), Color("#9a6a3a"))
				draw_rect(Rect2(c + Vector2(-r * 0.8, -r * 0.85), Vector2(r * 1.6, r * 0.7)), Color("#7a4d26"))
			"marker_stake":
				draw_rect(Rect2(c + Vector2(-r * 0.1, -r * 0.9), Vector2(r * 0.2, r * 1.8)), Color("#9a6a3a"))
				draw_colored_polygon(PackedVector2Array([c + Vector2(r * 0.1, -r * 0.9), c + Vector2(r * 0.9, -r * 0.6), c + Vector2(r * 0.1, -r * 0.3)]), Color("#e0533f"))
			_:
				draw_circle(c, r, Color(0.5, 0.52, 0.55))
				var f := ThemeDB.fallback_font
				var fs := maxi(8, int(s * 0.8))
				var w := f.get_string_size("?", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				draw_string(f, Vector2(c.x - w * 0.5, c.y + f.get_ascent(fs) * 0.4), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
