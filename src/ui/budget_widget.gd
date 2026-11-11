class_name BudgetWidget
extends PanelContainer
## Budget card floating over the farm (docs/PLANNING.md §4): what the current
## scope costs in the current mode, per currency (never converted), with the
## unknowns counted next to it. Scope follows the selection (a tile selection
## reads "Selected area"), then the active area, then the active phase, else
## the whole farm (or is pinned to the whole farm).
##
## Three lines: what is counted (scope · objects) and in which mode; the
## amounts, large; and one status line — whether recorded balances cover it,
## or what the total leaves out. The breakdown (per currency: needed / you
## have / missing, counts, unknowns, where the prices come from) opens in
## place. Sits in a canvas corner (menu; remembered in the settings).
## Refreshes on PlanContext.changed (coalesced per frame), never per frame.

signal open_tab(tab_id: String)
## Size, corner or visibility changed: main.gd places it again (and stores the setting).
signal layout_changed
signal setting(key: String, value: Variant)

const MENU_BREAKDOWN := 1
const MENU_COLLAPSE := 2
const MENU_TAB := 3
const MENU_HIDE := 4
const MENU_SHOP := 5
const MENU_CORNER := 10
const CARD_WIDTH := 340.0
const SCOPE_CHARS := 30
const AMOUNT_FONT := 19
const GLYPH := 20

var ctx: PlanContext
var corner := "bl"
var collapsed := false
var expanded := false

var _scope_icon: TextureRect
var _scope_btn: Button
var _amounts: HBoxContainer
var _warn: Button
var _mode_btn: Button
var _menu_btn: Button
var _more_btn: Button
var _status_icon: TextureRect
var _note: Label
var _card: VBoxContainer
var _scope_pop: PopupMenu
var _mode_pop: PopupMenu
var _menu_pop: PopupMenu
var _sig := ""
var last_totals: BudgetEngine.Totals   ## what is shown (tests)
## Design customization (PlanContext.customization()) and the cost shown with it (tests).
var last_skin: Dictionary = {}
var last_cost: Dictionary = {}
## PlanScope.affordability_of() of the shown cost against the recorded balances (tests).
var last_afford: Dictionary = {}


func setup(context: PlanContext) -> void:
	ctx = context
	var sb := UiTheme.box(UiTheme.c("panel"), 14, UiTheme.c("border"), 1, Vector4(12, 8, 10, 8))
	sb.shadow_color = UiTheme.c("shadow")
	sb.shadow_size = 14
	sb.shadow_offset = Vector2(0, 4)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := UI.vbox(4)
	add_child(v)
	# 1. What is counted, and how.
	var head := UI.hbox(6)
	v.add_child(head)
	_scope_icon = TextureRect.new()
	_scope_icon.custom_minimum_size = Vector2(16, 16)
	_scope_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_scope_icon.modulate = UiTheme.c("text_dim")
	_scope_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_scope_icon)
	_scope_btn = UI.button("", "", "", "Ghost")
	_scope_btn.add_theme_font_size_override("font_size", 14)
	_scope_btn.add_theme_color_override("font_color", UiTheme.c("text_dim"))
	_scope_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_scope_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scope_btn.pressed.connect(_open_scope_menu)
	head.add_child(_scope_btn)
	_mode_btn = UI.button("", "", "", "Chip")
	_mode_btn.add_theme_font_size_override("font_size", 13)
	_mode_btn.pressed.connect(_open_mode_menu)
	head.add_child(_mode_btn)
	_menu_btn = UI.icon_button("ellipsis-vertical", "Budget: breakdown, size, corner", "Ghost", 18)
	_menu_btn.pressed.connect(_open_menu)
	head.add_child(_menu_btn)
	# 2. The amounts, large.
	var row := UI.hbox(8)
	v.add_child(row)
	_amounts = UI.hbox(14)
	_amounts.mouse_filter = Control.MOUSE_FILTER_PASS
	_amounts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_amounts)
	_warn = UI.button("", "circle-question-mark", "", "Ghost")
	_warn.add_theme_color_override("font_color", UiTheme.c("warn"))
	_warn.add_theme_color_override("icon_normal_color", UiTheme.c("warn"))
	_warn.add_theme_color_override("font_hover_color", UiTheme.c("warn"))
	_warn.add_theme_color_override("icon_hover_color", UiTheme.c("warn"))
	_warn.add_theme_font_size_override("font_size", 14)
	_warn.pressed.connect(func(): set_expanded(not expanded))
	row.add_child(_warn)
	_more_btn = UI.icon_button("chevron-down", "Show the breakdown", "Ghost", 18)
	_more_btn.pressed.connect(func(): set_expanded(not expanded))
	row.add_child(_more_btn)
	# 3. Status: affordability / what the total leaves out.
	var st := UI.hbox(6)
	st.mouse_filter = Control.MOUSE_FILTER_PASS
	_status_icon = TextureRect.new()
	_status_icon.custom_minimum_size = Vector2(15, 15)
	_status_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_status_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_status_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	st.add_child(_status_icon)
	_note = UI.label("", "Dim")
	_note.add_theme_font_size_override("font_size", 13)
	_note.mouse_filter = Control.MOUSE_FILTER_PASS
	_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	st.add_child(_note)
	v.add_child(st)
	_card = UI.vbox(8)
	_card.custom_minimum_size.x = CARD_WIDTH
	var cm := MarginContainer.new()
	cm.add_theme_constant_override("margin_top", 4)
	cm.add_theme_constant_override("margin_bottom", 4)
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


## Set by main.gd when the free canvas is small (1080p at 200 %): the status
## line is dropped unless the breakdown is open (the user's own choice is kept).
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
	_more_btn.icon = Icons.get_icon("chevron-up" if expanded and not collapsed else "chevron-down", 18)
	_more_btn.tooltip_text = "Hide the breakdown" if expanded and not collapsed else "Show the breakdown: per currency, what you have, what is left out"


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
	p.add_item("Show the status line" if collapsed else "Amounts only", MENU_COLLAPSE)
	p.add_item("Open the Budget tab (J)", MENU_TAB)
	p.add_item("Open the shopping list", MENU_SHOP)
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
		MENU_SHOP: open_tab.emit("shop")
		MENU_HIDE: setting.emit("budget_visible", false)
		_:
			var i := id - MENU_CORNER
			if i >= 0 and i < PlanScope.CORNERS.size():
				corner = PlanScope.CORNERS[i]
				setting.emit("budget_corner", corner)
				layout_changed.emit()


# --- content -------------------------------------------------------------------------------

func _spendable() -> Dictionary:
	var l := ctx.layout() if ctx else null
	return BudgetEngine.spendable(l.profile) if l != null else {}


func refresh() -> void:
	if ctx == null or _amounts == null or not is_visible_in_tree():
		return
	if ctx.engine == null:
		_scope_btn.text = "No budget"
		return
	var sc := ctx.scope()
	var t := ctx.scope_totals()
	last_totals = t
	last_skin = ctx.customization()
	# The engine's instance id too: another layout's engine counts versions from 0 again.
	var sig := "%d/%d|%s|%s|%s|%s|%s|%d%d" % [ctx.engine.get_instance_id(), ctx.engine.version, ctx.mode, str(sc.get("kind")), str(sc.get("id")), str(sc.get("uids").hash() if sc.get("uids") is Array else 0), ctx.scope_pin, int(collapsed), int(expanded)]
	if ctx.session != null:
		sig += "|%d|%d" % [ctx.session.stack.version, int(ctx.session.selection_region != null)]
	sig += "|%d|%d" % [last_skin.hash(), _spendable().hash()]
	if sig == _sig:
		return
	_sig = sig
	_fill_row(sc, t)
	_fill_status(sc, t)
	if expanded and not collapsed:
		_fill_card(sc, t)
	layout_changed.emit()


func scope_title(sc: Dictionary, t: BudgetEngine.Totals) -> String:
	## "Selected area · 24 objects", "Whole farm · 260 objects", "Area: Garden · 12 objects".
	var kind := str(sc.get("kind"))
	var n := t.objects if t else 0
	var count := "%s object%s" % [UI.fmt_int(n), "" if n == 1 else "s"]
	match kind:
		PlanScope.SCOPE_SELECTION:
			var tiles := ctx.session != null and ctx.session.selection_region != null
			return "%s · %s" % ["Selected area" if tiles else "Selection", count]
		PlanScope.SCOPE_AREA:
			return "Area: %s · %s" % [str(sc.get("label", "")).get_slice(" · ", 1), count]
		PlanScope.SCOPE_PHASE:
			return "Phase: %s · %s" % [str(sc.get("label", "")).get_slice(" · ", 1), count]
	return "Whole farm · " + count


func _fill_row(sc: Dictionary, t: BudgetEngine.Totals) -> void:
	var kind := str(sc.get("kind"))
	var title := scope_title(sc, t)
	_scope_btn.text = title if title.length() <= SCOPE_CHARS else title.left(SCOPE_CHARS - 1) + "…"
	_scope_icon.texture = Icons.get_icon("lock" if ctx.scope_pin == "farm" else ("square-dashed-mouse-pointer" if kind == PlanScope.SCOPE_SELECTION else ("square-dashed" if kind == PlanScope.SCOPE_AREA else ("layers" if kind == PlanScope.SCOPE_PHASE else "tent-tree"))), 16)
	_scope_btn.tooltip_text = "Budget of: %s%s\nClick to choose: follow the selection / area / phase, or pin the whole farm." % [
		title, " (pinned)" if ctx.scope_pin == "farm" else ""]
	UI.clear(_amounts)
	# The whole farm's total includes the chosen look when the Budget tab says so (SkinBudget).
	var cost := SkinBudget.total_cost(t.cost, last_skin, kind)
	last_cost = cost
	var ids := Currency.sorted_ids(cost.keys())
	if ids.is_empty():
		var l := UI.label("Nothing to pay" if t.is_exact() else "No known price")
		l.add_theme_font_size_override("font_size", AMOUNT_FONT - 2)
		_amounts.add_child(l)
	var shown := 0
	var many := ids.size() > 4
	for c: String in ids:
		if shown >= 5:
			var more := UI.label("+%d more" % (ids.size() - shown), "Dim")
			more.tooltip_text = Currency.format_line(cost)
			_amounts.add_child(more)
			break
		_amounts.add_child(big_chip(c, int(cost[c]), many))
		shown += 1
	var parts_unknown := SkinBudget.unknown_count(last_skin, kind)
	var unknown := t.unknown_price_objects + t.not_buyable_objects + parts_unknown
	_warn.visible = unknown > 0 or not t.unknown_cost_plots.is_empty()
	_warn.text = "+%d" % unknown if unknown > 0 else "+?"
	var why := PlanScope.unknown_text(t)
	if parts_unknown > 0:
		why += "; %d appearance part%s without a price" % [parts_unknown, "" if parts_unknown == 1 else "s"]
	_warn.tooltip_text = "Not included in the total: %s.\nUnknown prices are counted, never treated as 0. Click for the breakdown." % why
	_mode_btn.text = str(PlanScope.MODE_LABELS.get(ctx.mode, ctx.mode)) + "  ▾"
	_mode_btn.tooltip_text = "%s\n\nClick to switch between Design cost, Still to buy and Remaining cost." % str(PlanScope.MODE_HELP.get(ctx.mode, ""))


func _fill_status(sc: Dictionary, t: BudgetEngine.Totals) -> void:
	## One line: can the recorded balances pay it? Else what the number means.
	var spend := _spendable()
	var a := PlanScope.affordability_of(last_cost, t.is_exact() and SkinBudget.unknown_count(last_skin, str(sc.get("kind"))) == 0, spend)
	last_afford = a
	var icon := "info"
	var col := UiTheme.c("text_dim")
	var text := ""
	var deducts := str(PlanScope.MODE_DEDUCTS.get(ctx.mode, ""))
	if ctx.mode == BudgetEngine.MODE_DESIGN:
		text = "What it all costs from scratch · inventory ignored"
	else:
		match str(a["state"]):
			"nothing":
				icon = "circle-check"
				col = UiTheme.c("accent")
				text = "Nothing left to buy"
			"ok":
				icon = "circle-check"
				col = UiTheme.c("accent")
				text = "Your balance covers it" + (" (known prices)" if bool(a["partial"]) else "")
			"short":
				icon = "badge-alert"
				col = UiTheme.c("danger")
				var miss: PackedStringArray = []
				for k in Currency.sorted_ids((a["shortfall"] as Dictionary).keys()):
					miss.append("%s %s" % [Currency.format_amount(int(a["shortfall"][k])), Currency.unit_name(k, int(a["shortfall"][k]))])
				text = "Short: " + ", ".join(miss)
			_:
				if spend.is_empty():
					text = deducts + " · record your coins to check affordability"
				else:
					var names: PackedStringArray = []
					for k in a["no_balance"]:
						names.append(Currency.name_of(k).to_lower())
					text = "No balance recorded for " + ", ".join(names) if not names.is_empty() else deducts
	# What the total leaves out (kept in this line: tests and screen readers look for it).
	var left: PackedStringArray = []
	if t.unknown_price_objects > 0:
		left.append("%d unknown price" % t.unknown_price_objects)
	if t.not_buyable_objects > 0:
		left.append("%d can't be bought" % t.not_buyable_objects)
	if not left.is_empty():
		text += " · " + " · ".join(left)
	_note.text = text
	_note.add_theme_color_override("font_color", col if col != UiTheme.c("text_dim") else UiTheme.c("text_dim"))
	_note.tooltip_text = "%s\n%s\n%s object%s · %d charged · %d owned · %d bought" % [str(PlanScope.MODE_HELP.get(ctx.mode, "")), text,
		UI.fmt_int(t.objects), "" if t.objects == 1 else "s", t.charged_objects, t.owned_objects, t.acquired_objects]
	_status_icon.texture = Icons.get_icon(icon, 15)
	_status_icon.modulate = col


func _note_text(t: BudgetEngine.Totals) -> String:
	## The counts in words (Budget tab and tests reuse it).
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
	_card.add_child(HSeparator.new())
	var help := UI.label(str(PlanScope.MODE_HELP.get(ctx.mode, "")), "Dim", true)
	help.add_theme_font_size_override("font_size", 13)
	_card.add_child(help)
	# Per currency: needed, what you have, what is missing.
	var spend := _spendable()
	var have_cols := not spend.is_empty() and ctx.mode != BudgetEngine.MODE_DESIGN
	var grid := GridContainer.new()
	grid.columns = 4 if have_cols else 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)
	if have_cols:
		for h in ["", "Needed", "You have", "Missing"]:
			var hl := UI.label(h, "Section")
			hl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			grid.add_child(hl)
	var cost := last_cost
	for c: String in Currency.sorted_ids(cost.keys()):
		var name_row := UI.hbox(6)
		name_row.add_child(glyph(c, 18))
		var nl := UI.label(Currency.name_of(c))
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_row.add_child(nl)
		name_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(name_row)
		grid.add_child(_num(int(cost[c]), "", true))
		if have_cols:
			if spend.has(c):
				grid.add_child(_num(int(spend[c]), ""))
				var miss := int(cost[c]) - int(spend[c])
				grid.add_child(_num(miss, "danger") if miss > 0 else _ok_cell())
			else:
				grid.add_child(_txt("—", "Not recorded: set it in the inventory (Budget tab)"))
				grid.add_child(_txt("?", "Unknown without a recorded balance"))
	if cost.is_empty():
		_card.add_child(UI.label("Nothing to pay" if t.is_exact() else "No known price", "Dim"))
	else:
		_card.add_child(grid)
	if ctx.mode != BudgetEngine.MODE_DESIGN and not t.plots.is_empty():
		var land := "Includes land: %d expansion plot%s — %s" % [t.plots.size(), "" if t.plots.size() == 1 else "s", Currency.format_line(t.land_cost, "no supplies known", "supplies unknown")]
		if not t.unknown_cost_plots.is_empty():
			land += " (+%d with unknown supplies)" % t.unknown_cost_plots.size()
		_card.add_child(UI.label(land, "Dim", true))
	if str(sc.get("kind")) == PlanScope.SCOPE_FARM and not SkinBudget.summary_text(last_skin).is_empty():
		_card.add_child(UI.label(SkinBudget.summary_text(last_skin), "Dim", true))
	# Counts.
	var counts := GridContainer.new()
	counts.columns = 2
	counts.add_theme_constant_override("h_separation", 14)
	counts.add_theme_constant_override("v_separation", 2)
	var rows := [["Objects counted", t.objects], ["To pay for", t.charged_objects]]
	if ctx.mode != BudgetEngine.MODE_DESIGN:
		rows.append(["Covered by copies you own", t.owned_objects])
	if ctx.mode == BudgetEngine.MODE_REMAINING:
		rows.append(["Bought for this project", t.acquired_objects])
	for r: Array in rows:
		counts.add_child(UI.label(str(r[0]), "Dim"))
		counts.add_child(_num(int(r[1]), ""))
	_card.add_child(counts)
	if t.unknown_price_objects > 0:
		_card.add_child(_warn_line("%d object%s of %d type%s with unknown price — not in the total" % [t.unknown_price_objects,
			"" if t.unknown_price_objects == 1 else "s", t.unknown_price_types.size(), "" if t.unknown_price_types.size() == 1 else "s"]))
	if t.not_buyable_objects > 0:
		_card.add_child(_warn_line("%d object%s of %d type%s can't be bought (rewards, not in the shop) — not in the total" % [t.not_buyable_objects,
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
	var src := PlanScope.price_sources_text(PlanScope.price_sources(ctx.engine, ctx.prices, PlanScope.scope_uids(ctx.engine, sc), ctx.mode))
	if not src.is_empty():
		var sl := UI.label("Prices (item types): " + src, "Faint", true)
		sl.tooltip_text = "Where each price comes from. Your game files: read from your own client data. Researched: community sources. Your own price: entered by you (Edit price…). Unverified: sources disagree or are old."
		sl.mouse_filter = Control.MOUSE_FILTER_PASS
		_card.add_child(sl)
	var btns := UI.hbox(6)
	var b := UI.button("Budget tab", "coins", "Totals side by side, unknown prices, targets, inventory (J)", "Ghost")
	b.pressed.connect(func(): open_tab.emit("budget"))
	btns.add_child(b)
	var b2 := UI.button("Shopping list", "shopping-cart", "What to buy, in what order", "Ghost")
	b2.pressed.connect(func(): open_tab.emit("shop"))
	btns.add_child(b2)
	_card.add_child(btns)


func _num(n: int, color_key: String, strong: bool = false) -> Label:
	var l := UI.label(Currency.format_amount(n))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if strong:
		l.add_theme_font_override("font", UiTheme.font_bold)
	if not color_key.is_empty():
		l.add_theme_color_override("font_color", UiTheme.c(color_key))
	return l


func _ok_cell() -> Control:
	var l := UI.label("✓")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.add_theme_color_override("font_color", UiTheme.c("accent"))
	return l


func _txt(t: String, tip: String) -> Label:
	var l := UI.label(t, "Faint")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	return l


func _warn_line(text: String) -> Label:
	var l := UI.label(text, "Dim", true)
	l.add_theme_color_override("font_color", UiTheme.c("warn"))
	return l


static func big_chip(currency: String, amount: int, short: bool = false) -> HBoxContainer:
	## The card's amount: larger glyph and bold number (tooltip: exact amount and name).
	var h := UI.hbox(5)
	h.mouse_filter = Control.MOUSE_FILTER_PASS
	h.tooltip_text = "%s %s" % [Currency.format_amount(amount), Currency.unit_name(currency, amount)]
	h.add_child(glyph(currency, GLYPH))
	var l := UI.label(PlanScope.abbreviate(amount) if short else Currency.format_amount(amount))
	l.add_theme_font_size_override("font_size", AMOUNT_FONT)
	l.add_theme_font_override("font", UiTheme.font_bold)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	h.add_child(l)
	return h


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
## coloured voucher tickets, pearl, film, key, expansion supplies, "?" for others.
class Glyph:
	extends Control
	var currency := ""

	const VOUCHER_COLORS := {"voucher_green": Color("#4fae55"), "voucher_blue": Color("#4a8fdb"),
		"voucher_purple": Color("#9a6ad6"), "voucher_gold": Color("#e2b23a")}

	func _draw() -> void:
		paint(self, currency, Rect2(Vector2.ZERO, size))

	static func paint(ci: CanvasItem, cur: String, box: Rect2) -> void:
		## Draws the mark for `cur` into `box` of any canvas item (catalogue tiles use it too).
		var s := minf(box.size.x, box.size.y)
		var c := box.position + box.size * 0.5
		var r := s * 0.5
		match cur:
			"coins":
				ci.draw_circle(c, r, Color("#a8770f"))
				ci.draw_circle(c, r * 0.84, Color("#f5c842"))
				ci.draw_arc(c, r * 0.56, 0, TAU, 20, Color("#c9951c"), maxf(1.0, s * 0.08), true)
				ci.draw_circle(c + Vector2(-r * 0.32, -r * 0.34), r * 0.16, Color(1, 1, 1, 0.75))
			"diamonds":
				var pts := PackedVector2Array([c + Vector2(-r * 0.9, -r * 0.25), c + Vector2(-r * 0.45, -r * 0.8), c + Vector2(r * 0.45, -r * 0.8),
					c + Vector2(r * 0.9, -r * 0.25), c + Vector2(0, r * 0.92)])
				ci.draw_colored_polygon(pts, Color("#2fae6a"))
				ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-r * 0.45, -r * 0.8), c + Vector2(r * 0.1, -r * 0.8), c + Vector2(-r * 0.2, -r * 0.25), c + Vector2(-r * 0.9, -r * 0.25)]), Color("#7fe0a6"))
				var closed := pts.duplicate()
				closed.append(pts[0])
				ci.draw_polyline(closed, Color("#14683c"), maxf(1.0, s * 0.07), true)
			"voucher_green", "voucher_blue", "voucher_purple", "voucher_gold":
				var col: Color = VOUCHER_COLORS[cur]
				var rect := Rect2(c - Vector2(r * 0.95, r * 0.62), Vector2(r * 1.9, r * 1.24))
				ci.draw_rect(rect, col.darkened(0.35))
				ci.draw_rect(rect.grow(-maxf(1.0, s * 0.07)), col)
				ci.draw_circle(Vector2(rect.position.x, c.y), r * 0.24, Color(0, 0, 0, 0))
				ci.draw_circle(Vector2(rect.position.x, c.y), r * 0.22, col.darkened(0.55))
				ci.draw_circle(Vector2(rect.end.x, c.y), r * 0.22, col.darkened(0.55))
				ci.draw_line(Vector2(c.x + r * 0.25, rect.position.y + 2), Vector2(c.x + r * 0.25, rect.end.y - 2), Color(1, 1, 1, 0.6), 1.0)
			"film":
				var fr := Rect2(c - Vector2(r * 0.9, r * 0.7), Vector2(r * 1.8, r * 1.4))
				ci.draw_rect(fr, Color("#2b2b30"))
				for i in 3:
					var x := fr.position.x + fr.size.x * (0.2 + 0.3 * i)
					ci.draw_rect(Rect2(x - r * 0.1, fr.position.y + r * 0.12, r * 0.2, r * 0.2), Color(0.9, 0.9, 0.9))
					ci.draw_rect(Rect2(x - r * 0.1, fr.end.y - r * 0.32, r * 0.2, r * 0.2), Color(0.9, 0.9, 0.9))
			"pearls":
				ci.draw_circle(c, r * 0.9, Color("#b9b2c8"))
				ci.draw_circle(c, r * 0.78, Color("#f1edf6"))
				ci.draw_circle(c + Vector2(r * 0.18, r * 0.2), r * 0.42, Color("#ddd5e8"))
				ci.draw_circle(c + Vector2(-r * 0.3, -r * 0.32), r * 0.18, Color(1, 1, 1, 0.95))
			"golden_keys":
				ci.draw_circle(c + Vector2(-r * 0.4, 0), r * 0.42, Color("#e2b23a"))
				ci.draw_circle(c + Vector2(-r * 0.4, 0), r * 0.18, Color(0.15, 0.12, 0.05))
				ci.draw_rect(Rect2(c + Vector2(-r * 0.05, -r * 0.12), Vector2(r * 0.95, r * 0.24)), Color("#e2b23a"))
				ci.draw_rect(Rect2(c + Vector2(r * 0.6, 0), Vector2(r * 0.18, r * 0.4)), Color("#e2b23a"))
			"land_deed", "expansion_permit":
				var pr := Rect2(c - Vector2(r * 0.7, r * 0.9), Vector2(r * 1.4, r * 1.8))
				ci.draw_rect(pr, Color("#e9dcb8") if cur == "land_deed" else Color("#bcd3ef"))
				for i in 3:
					var y := pr.position.y + pr.size.y * (0.3 + 0.2 * i)
					ci.draw_line(Vector2(pr.position.x + r * 0.25, y), Vector2(pr.end.x - r * 0.25, y), Color(0.3, 0.25, 0.2, 0.8), 1.0)
			"mallet":
				ci.draw_rect(Rect2(c + Vector2(-r * 0.12, -r * 0.2), Vector2(r * 0.24, r * 1.1)), Color("#9a6a3a"))
				ci.draw_rect(Rect2(c + Vector2(-r * 0.8, -r * 0.85), Vector2(r * 1.6, r * 0.7)), Color("#7a4d26"))
			"marker_stake":
				ci.draw_rect(Rect2(c + Vector2(-r * 0.1, -r * 0.9), Vector2(r * 0.2, r * 1.8)), Color("#9a6a3a"))
				ci.draw_colored_polygon(PackedVector2Array([c + Vector2(r * 0.1, -r * 0.9), c + Vector2(r * 0.9, -r * 0.6), c + Vector2(r * 0.1, -r * 0.3)]), Color("#e0533f"))
			_:
				ci.draw_circle(c, r, Color(0.5, 0.52, 0.55))
				var f := ThemeDB.fallback_font
				var fs := maxi(8, int(s * 0.8))
				var w := f.get_string_size("?", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				ci.draw_string(f, Vector2(c.x - w * 0.5, c.y + f.get_ascent(fs) * 0.4), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
