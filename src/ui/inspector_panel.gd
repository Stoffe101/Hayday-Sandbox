class_name InspectorPanel
extends PanelContainer
## Right-hand inspector: Selection / Farm planning / View tabs.

signal action(name: String, arg: Variant)

var _tabs: TabBar
var _scroll: ScrollContainer
var _body: VBoxContainer
var _tab := 0
var _refresh_timer: Timer
var report: RealisticAnalyzer.Report
var view_state: Dictionary = {}      ## filled by main: reference/compare state


func _ready() -> void:
	theme_type_variation = "FloatingPanel"
	var v := UI.vbox(10)
	add_child(v)
	_tabs = TabBar.new()
	_tabs.add_tab("Selection", Icons.get_icon("mouse-pointer-2", 16))
	_tabs.add_tab("Farm", Icons.get_icon("clipboard-check", 16))
	_tabs.add_tab("View", Icons.get_icon("layers", 16))
	_tabs.tab_changed.connect(func(i):
		_tab = i
		rebuild())
	_tabs.focus_mode = Control.FOCUS_NONE
	_tabs.clip_tabs = false
	v.add_child(_tabs)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(_scroll)
	_body = UI.vbox(10)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	_refresh_timer.wait_time = 0.2
	_refresh_timer.timeout.connect(rebuild)
	add_child(_refresh_timer)


func show_tab(i: int) -> void:
	_tabs.current_tab = i


func current_tab() -> int:
	return _tab


func queue_rebuild() -> void:
	_refresh_timer.start()


func rebuild() -> void:
	UI.clear(_body)
	var s := App.session
	if s == null:
		return
	report = RealisticAnalyzer.analyze(s.layout, s.db, s.map)
	match _tab:
		0: _build_selection(s)
		1: _build_farm(s)
		2: _build_view(s)


# ---------------------------------------------------------------------------
# Selection tab
# ---------------------------------------------------------------------------

func _build_selection(s: EditorSession) -> void:
	var objs := s.selected_objects()
	if objs.is_empty():
		var it := s.db.get_item(s.active_item) if s.tool == "place" else null
		if it:
			_body.add_child(UI.section("Placing"))
			_item_card(it, null)
			var row := UI.hbox(6)
			var flip := UI.button("Rotate", "rotate-cw", "Mirror the item (R)")
			flip.disabled = not it.flippable
			flip.toggle_mode = true
			flip.button_pressed = s.place_flipped
			flip.pressed.connect(func(): action.emit("place_flip", null))
			row.add_child(flip)
			var plan := UI.button("Planned", "map-pin", "Place as a future-planning ghost (P)")
			plan.toggle_mode = true
			plan.button_pressed = s.place_planned
			plan.pressed.connect(func(): action.emit("place_planned", null))
			row.add_child(plan)
			_body.add_child(row)
			_body.add_child(_brush_row(s))
			_body.add_child(UI.label("Click to place · drag to paint · Shift-drag line · Ctrl-drag fill · right-click or Esc to stop.", "Faint", true))
			return
		_empty_state()
		return
	if objs.size() == 1:
		var o: PlacedObject = objs[0]
		var it := s.db.get_item(o.item_id)
		_body.add_child(UI.section("Selected object"))
		_item_card(it, o)
		_variant_picker(s, [o])
		_issue_list(o)
		_object_actions(s, [o])
		_note_editor(s, o)
		return
	# Multi-selection summary
	_body.add_child(UI.section("%d objects selected" % objs.size()))
	var counts := {}
	for o: PlacedObject in objs:
		counts[o.item_id] = counts.get(o.item_id, 0) + 1
	var ids := counts.keys()
	ids.sort_custom(func(a, b): return counts[a] > counts[b])
	var card := UI.card()
	var list := UI.vbox(4)
	card.add_child(list)
	for i in mini(ids.size(), 12):
		var it := s.db.get_item(ids[i])
		list.add_child(UI.kv("%d ×" % counts[ids[i]], it.name if it else ids[i]))
	if ids.size() > 12:
		list.add_child(UI.label("+ %d more types" % (ids.size() - 12), "Faint"))
	_body.add_child(card)
	var r := s.layout.bounds_of(s.selection)
	_body.add_child(UI.label("Area: %d × %d tiles" % [r.size.x, r.size.y], "Dim"))
	_variant_picker(s, objs)
	_object_actions(s, objs)


var variant_option: OptionButton    ## exposed for tests


func _variant_picker(s: EditorSession, objs: Array) -> void:
	## Shown when the selected objects share art that has variants. Changing it
	## is one undoable command (EditCommands.SetProperty "variant").
	variant_option = null
	if objs.is_empty():
		return
	var it0 := s.db.get_item((objs[0] as PlacedObject).item_id)
	if it0 == null:
		return
	var mixed := false
	for o: PlacedObject in objs:
		var it := s.db.get_item(o.item_id)
		if it == null or it.art_key != it0.art_key:
			return
		mixed = mixed or o.variant != (objs[0] as PlacedObject).variant
	var vars := App.assets.variants_of(it0.art_key)
	if vars.is_empty():
		return
	_body.add_child(UI.section("Appearance"))
	var row := UI.hbox(8)
	row.add_child(UI.label("Variant", "Dim"))
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.tooltip_text = "Art variant from the installed asset pack (Ctrl+Z undoes)"
	ob.focus_mode = Control.FOCUS_NONE
	var def := App.assets.default_variant_of(it0.art_key)
	ob.add_item("Default" + (" (%s)" % _variant_name(it0, def) if not def.is_empty() else ""))
	ob.set_item_metadata(0, "")
	var cur := (objs[0] as PlacedObject).variant
	ob.selected = 0
	if not def.is_empty():
		ob.add_item("Base image")
		ob.set_item_metadata(1, AssetLibrary.BASE_VARIANT)
		if cur == AssetLibrary.BASE_VARIANT:
			ob.selected = 1
	for v in vars:
		ob.add_item(_variant_name(it0, v))
		ob.set_item_metadata(ob.item_count - 1, v)
		if v == cur:
			ob.selected = ob.item_count - 1
	if mixed:
		ob.selected = -1
		ob.text = "Mixed"
	ob.item_selected.connect(func(i): action.emit("variant", ob.get_item_metadata(i)))
	row.add_child(ob)
	_body.add_child(row)
	variant_option = ob


static func _variant_name(it: ItemDef, vid: String) -> String:
	for v in it.variants:
		if str(v.get("id", "")) == vid:
			return str(v.get("name", vid))
	return vid.replace("_", " ").capitalize()


func _brush_row(s: EditorSession) -> HBoxContainer:
	var bar := PanelContainer.new()
	bar.theme_type_variation = "SegmentBar"
	var row := UI.hbox(2)
	bar.add_child(row)
	for b in [["single", "Single", "paintbrush"], ["line", "Line", "minus"], ["rect", "Fill", "square-dashed"]]:
		var btn := UI.button(b[1], b[2], "", "Segment")
		btn.toggle_mode = true
		btn.button_pressed = s.brush == b[0]
		btn.pressed.connect(func(): action.emit("brush", b[0]))
		row.add_child(btn)
	var h := UI.hbox(0)
	h.add_child(bar)
	return h


func _empty_state() -> void:
	var card := UI.card()
	var v := UI.vbox(8)
	card.add_child(v)
	v.add_child(UI.icon_rect("mouse-pointer-2", 28, UiTheme.c("accent")))
	v.add_child(UI.label("Nothing selected", "Heading"))
	v.add_child(UI.label("Click an object to inspect it, drag on empty ground to box-select, or pick something from the catalogue to start placing.", "Dim", true))
	_body.add_child(card)
	var s := App.session
	_body.add_child(UI.section("This farm"))
	var stats := UI.card()
	var sv := UI.vbox(4)
	stats.add_child(sv)
	var land := s.map.buildable_tile_count(s.layout.unlocked_plots)
	var used := 0
	for o: PlacedObject in s.layout.objects.values():
		used += o.size.x * o.size.y
	sv.add_child(UI.kv("Objects", UI.fmt_int(s.layout.count())))
	sv.add_child(UI.kv("Land", "%s tiles (%d plots unlocked)" % [UI.fmt_int(land), s.layout.unlocked_plots.size()]))
	sv.add_child(UI.kv("Used", "%s tiles (%d%%)" % [UI.fmt_int(used), int(100.0 * used / maxi(1, land))]))
	sv.add_child(UI.kv("Mode", s.layout.mode.capitalize()))
	_body.add_child(stats)
	var hint := UI.label("Tip: press F1 for all keyboard shortcuts.", "Faint", true)
	_body.add_child(hint)


func _item_card(it: ItemDef, o: PlacedObject) -> void:
	var card := UI.card()
	var v := UI.vbox(6)
	card.add_child(v)
	var top := UI.hbox(10)
	var tex := TextureRect.new()
	var key := it.art_key if it else ""
	var spr: AssetLibrary.SpriteInfo = null
	if it:
		spr = App.assets.get_sprite(key, o.variant if o else "", UI.preview_mask(it))
	tex.texture = spr.texture if spr else Icons.get_icon("box", 48)
	tex.flip_h = o != null and o.flipped
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(96, 84)
	top.add_child(tex)
	var info := UI.vbox(3)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(UI.label(it.name if it else (o.item_id + " (unknown item)"), "Heading", true))
	if it:
		info.add_child(UI.label(App.db.category(it.category)["name"], "Dim"))
		var badges := HFlowContainer.new()
		badges.add_theme_constant_override("h_separation", 4)
		badges.add_child(UI.badge(UI.status_text(it.footprint_status), UI.status_color(it.footprint_status)))
		if o and o.planned:
			badges.add_child(UI.badge("Planned", UiTheme.c("planned")))
		if o and o.locked:
			badges.add_child(UI.badge("Locked", UiTheme.c("text_dim")))
		badges.add_child(UI.art_badge(App.assets.art_status(key)))
		var nv := App.assets.variants_of(key).size()
		if nv > 0:
			badges.add_child(UI.badge("%d variant%s" % [nv, "" if nv == 1 else "s"], UiTheme.c("info")))
		info.add_child(badges)
	top.add_child(info)
	v.add_child(top)
	if it == null:
		v.add_child(UI.label("This item type isn't in the current catalogue. It is kept with its saved size so nothing is lost.", "Dim", true))
		return
	var size := o.size if o else it.footprint
	v.add_child(UI.kv("Footprint", "%d × %d tiles%s" % [size.x, size.y, " (rotated)" if o and o.flipped else ""]))
	if o:
		v.add_child(UI.kv("Position", "%d, %d" % [o.origin.x, o.origin.y]))
	v.add_child(UI.kv("Unlocks", "Level %d" % it.unlock_level if it.unlock_level > 0 else "Unknown"))
	var cost := PackedStringArray()
	if it.cost_coins >= 0:
		cost.append("%s coins" % UI.fmt_int(it.cost_coins))
	if it.cost_diamonds >= 0:
		cost.append("%d diamonds" % it.cost_diamonds)
	if not it.cost_other.is_empty():
		cost.append(it.cost_other)
	v.add_child(UI.kv("Cost", ", ".join(cost) if not cost.is_empty() else "Unknown"))
	if it.max_count > 0:
		v.add_child(UI.kv("Max", "%d per farm" % it.max_count))
	v.add_child(UI.kv("Rotate", "Yes (mirror)" if it.flippable else "No"))
	if not it.movable:
		v.add_child(UI.label("Fixed in place in the game.", "Faint", true))
	if not it.notes.is_empty():
		var n := UI.label("Research notes: " + it.notes.left(240) + ("…" if it.notes.length() > 240 else ""), "Faint", true)
		v.add_child(n)
	if not it.sources.is_empty():
		var src := LinkButton.new()
		src.text = "Source"
		src.uri = it.sources[0]
		src.tooltip_text = it.sources[0]
		v.add_child(src)
	_body.add_child(card)


func _issue_list(o: PlacedObject) -> void:
	var codes: Array = report.issues.get(o.uid, []) if report else []
	var place := PlacementRules.check_rect(App.session.layout, App.session.map, o.rect(), {o.uid: true})
	if codes.is_empty() and place.ok:
		return
	var card := UI.card()
	var v := UI.vbox(4)
	card.add_child(v)
	if not place.ok:
		var l := UI.label("⚠ " + place.message(App.session.layout, App.session.db, App.session.map), "", true)
		l.add_theme_color_override("font_color", UiTheme.c("danger"))
		v.add_child(l)
	if App.session.layout.mode == FarmLayout.MODE_REALISTIC:
		for c in codes:
			if c == RealisticAnalyzer.PLACEMENT:
				continue
			var l2 := UI.label("• " + RealisticAnalyzer.issue_text(c), "", true)
			l2.add_theme_color_override("font_color", UiTheme.c("warn") if RealisticAnalyzer.SEVERITY.get(c, 0) < 2 else UiTheme.c("danger"))
			v.add_child(l2)
	if v.get_child_count() > 0:
		_body.add_child(card)


func _object_actions(s: EditorSession, objs: Array) -> void:
	_body.add_child(UI.section("Actions"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	var any_locked := false
	var any_planned := false
	var any_group := false
	for o: PlacedObject in objs:
		any_locked = any_locked or o.locked
		any_planned = any_planned or o.planned
		any_group = any_group or o.group_id != 0
	var acts := [
		["Rotate", "rotate-cw", "R", "flip"], ["Duplicate", "copy-plus", "Ctrl+D", "duplicate"],
		["Unlock" if any_locked else "Lock", "lock-open" if any_locked else "lock", "L", "lock"],
		["Make real" if any_planned else "Planned", "map-pin", "P", "planned"],
		["Ungroup" if any_group else "Group", "ungroup" if any_group else "group", "Ctrl+G", "group"],
		["Delete", "trash", "Del", "delete"],
	]
	for a in acts:
		var b := UI.button(a[0], a[1], "%s (%s)" % [a[0], a[2]])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func(): action.emit(a[3], null))
		if a[3] == "delete":
			b.add_theme_color_override("icon_normal_color", UiTheme.c("danger"))
		grid.add_child(b)
	_body.add_child(grid)


func _note_editor(s: EditorSession, o: PlacedObject) -> void:
	_body.add_child(UI.section("Note"))
	var le := LineEdit.new()
	le.placeholder_text = "Add a note to this object…"
	le.text = o.note
	le.text_submitted.connect(func(t): action.emit("note", t))
	le.focus_exited.connect(func():
		if le.text != o.note:
			action.emit("note", le.text))
	_body.add_child(le)


# ---------------------------------------------------------------------------
# Farm tab: mode, land, realistic plan
# ---------------------------------------------------------------------------

func _build_farm(s: EditorSession) -> void:
	var l := s.layout
	_body.add_child(UI.section("Planning mode"))
	var mode_card := UI.card()
	var mv := UI.vbox(6)
	mode_card.add_child(mv)
	if l.mode == FarmLayout.MODE_CREATIVE:
		mv.add_child(UI.label("Creative — no limits", "Heading"))
		mv.add_child(UI.label("Everything is available. Switch to Realistic to check this design against your level, inventory and land. Nothing in the layout is changed by switching.", "Dim", true))
	else:
		mv.add_child(UI.label("Realistic — can I build this?", "Heading"))
		mv.add_child(UI.label("Objects you can't build yet are highlighted. Set your level and what you own below.", "Dim", true))
	var mbtn := UI.button("Switch to Realistic" if l.mode == FarmLayout.MODE_CREATIVE else "Switch to Creative", "wand-sparkles", "Ctrl+M")
	mbtn.pressed.connect(func(): action.emit("toggle_mode", null))
	mv.add_child(mbtn)
	_body.add_child(mode_card)
	# Land
	_body.add_child(UI.section("Land"))
	var land := UI.card()
	var lv := UI.vbox(6)
	land.add_child(lv)
	var total := s.map.plots.size()
	lv.add_child(UI.kv("Unlocked", "%d of %d mapped plots" % [l.unlocked_plots.size(), total]))
	lv.add_child(UI.kv("Buildable", "%s tiles" % UI.fmt_int(s.map.buildable_tile_count(l.unlocked_plots))))
	var lrow := UI.hbox(6)
	var pick := UI.button("Pick plots", "map", "Land tool: click plots to lock/unlock (M)")
	pick.pressed.connect(func(): action.emit("tool", "land"))
	lrow.add_child(pick)
	var all := UI.button("All", "", "Unlock every mapped plot")
	all.pressed.connect(func(): action.emit("land_all", true))
	lrow.add_child(all)
	var none := UI.button("Start only", "", "Lock every expansion plot")
	none.pressed.connect(func(): action.emit("land_all", false))
	lrow.add_child(none)
	lv.add_child(lrow)
	var mapnote := UI.label("Map: %s. Plot shapes are approximate; %d further sections across the road aren't mapped yet." % [s.map.name, _unmapped(s)], "Faint", true)
	lv.add_child(mapnote)
	_body.add_child(land)
	# Realistic profile
	_body.add_child(UI.section("My farm"))
	var prof := UI.card()
	var pv := UI.vbox(8)
	prof.add_child(pv)
	var lvl_row := UI.hbox(8)
	lvl_row.add_child(UI.label("Farm level", "Dim"))
	lvl_row.add_child(UI.spacer())
	var lvl := SpinBox.new()
	lvl.min_value = 1
	lvl.max_value = 999
	lvl.value = int(l.profile.get("level", 1))
	lvl.value_changed.connect(func(v): action.emit("profile", {"level": int(v)}))
	lvl_row.add_child(lvl)
	pv.add_child(lvl_row)
	for b in [["budget_coins", "Coin budget"], ["budget_diamonds", "Diamond budget"]]:
		var row := UI.hbox(8)
		row.add_child(UI.label(b[1], "Dim"))
		row.add_child(UI.spacer())
		var sb := SpinBox.new()
		sb.min_value = -1
		sb.max_value = 999999999
		sb.step = 1
		sb.value = int(l.profile.get(b[0], -1))
		sb.tooltip_text = "-1 = no budget"
		sb.value_changed.connect(func(v): action.emit("profile", {b[0]: int(v)}))
		row.add_child(sb)
		pv.add_child(row)
	var own := CheckBox.new()
	own.text = "Assume I own items I haven't listed"
	own.button_pressed = bool(l.profile.get("treat_unknown_as_owned", true))
	own.toggled.connect(func(on): action.emit("profile", {"treat_unknown_as_owned": on}))
	pv.add_child(own)
	var snap := UI.button("I own everything placed now", "clipboard-check", "Record current non-planned objects as your inventory")
	snap.pressed.connect(func(): action.emit("own_all", null))
	pv.add_child(snap)
	var owned: Dictionary = l.profile.get("owned", {})
	var owned_n := 0
	for k in owned:
		owned_n += int(owned[k])
	pv.add_child(UI.label("Inventory: %d objects of %d types recorded." % [owned_n, owned.size()], "Faint", true))
	_body.add_child(prof)
	_report_card(s)


func _unmapped(s: EditorSession) -> int:
	var data: Variant = JsonUtil.read_json("res://data/maps/%s.json" % s.map.id)
	return (data.get("unmapped_sections", []) as Array).size() if data is Dictionary else 0


func _report_card(s: EditorSession) -> void:
	var r := report
	_body.add_child(UI.section("Can I build this?"))
	var card := UI.card()
	var v := UI.vbox(6)
	card.add_child(v)
	var ok := r.can_recreate()
	var head := UI.hbox(8)
	head.add_child(UI.icon_rect("check" if ok else "circle-x", 22, UiTheme.c("accent") if ok else UiTheme.c("danger")))
	var hl := UI.label("Ready to build" if ok else "%d object(s) can't be built yet" % r.blocking_count, "Heading", true)
	hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(hl)
	v.add_child(head)
	if r.required_level > 0:
		v.add_child(UI.kv("Needs level", str(r.required_level)))
	if not r.plots_needed.is_empty():
		var names := PackedStringArray()
		for p in r.plots_needed:
			names.append(str(s.map.plot(p).get("number", p)))
		v.add_child(UI.kv("Needs land", "Plots " + ", ".join(names)))
	if r.coins_needed > 0 or r.diamonds_needed > 0:
		var c := PackedStringArray()
		if r.coins_needed > 0:
			c.append("%s coins" % UI.fmt_int(r.coins_needed))
		if r.diamonds_needed > 0:
			c.append("%s diamonds" % UI.fmt_int(r.diamonds_needed))
		var kvc := UI.kv("Est. cost", " + ".join(c))
		if r.over_budget_coins or r.over_budget_diamonds:
			(kvc.get_child(1) as Label).add_theme_color_override("font_color", UiTheme.c("danger"))
		v.add_child(kvc)
	if not r.unknown_cost_items.is_empty():
		v.add_child(UI.label("%d item type(s) have no known price and are not included." % r.unknown_cost_items.size(), "Faint", true))
	if r.unverified > 0:
		v.add_child(UI.label("%d object(s) use unverified footprints." % r.unverified, "Faint", true))
	if r.planned_count > 0:
		v.add_child(UI.label("%d planned object(s) excluded." % r.planned_count, "Faint", true))
	_body.add_child(card)
	if not r.shortages.is_empty() or not r.level_locked.is_empty() or not r.over_max.is_empty():
		_body.add_child(UI.section("Missing"))
		var mc := UI.card()
		var mv := UI.vbox(4)
		mc.add_child(mv)
		for e in r.level_locked.slice(0, 8):
			var b := UI.button("Lv %d · %s ×%d" % [e["level"], e["name"], e["count"]], "", "Select these", "Ghost")
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(func(): action.emit("select_item", e["item"]))
			mv.add_child(b)
		for e in r.over_max:
			var b2 := UI.button("%s: %d placed, max %d" % [e["name"], e["placed"], e["max"]], "", "Select these", "Ghost")
			b2.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b2.pressed.connect(func(): action.emit("select_item", e["item"]))
			mv.add_child(b2)
		for e in r.shortages.slice(0, 20):
			var cost := ""
			if int(e["coins"]) > 0:
				cost = " · %s c" % UI.fmt_int(e["coins"])
			if int(e["diamonds"]) > 0:
				cost += " · %d 💎" % e["diamonds"]
			var b3 := UI.button("Need %d × %s%s" % [e["missing"], e["name"], cost], "", "Select these", "Ghost")
			b3.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b3.pressed.connect(func(): action.emit("select_item", e["item"]))
			mv.add_child(b3)
		if r.shortages.size() > 20:
			mv.add_child(UI.label("+ %d more" % (r.shortages.size() - 20), "Faint"))
		_body.add_child(mc)


# ---------------------------------------------------------------------------
# View tab: layers, reference image, compare
# ---------------------------------------------------------------------------

func _build_view(_s: EditorSession) -> void:
	_body.add_child(UI.section("Layers"))
	var card := UI.card()
	var v := UI.vbox(2)
	card.add_child(v)
	for t in [["show_grid", "Tile grid", "G"], ["show_shadows", "Shadows", ""], ["show_labels", "Item names", "N"],
			["show_occupancy", "Occupied tiles", "O"], ["show_annotations", "Notes & zones", ""], ["hide_locked", "Hide locked land", ""]]:
		var cb := CheckButton.new()
		cb.text = t[1] + ("   " + t[2] if not t[2].is_empty() else "")
		cb.button_pressed = bool(App.settings.get_v(t[0])) if App.settings.values.has(t[0]) else bool(view_state.get(t[0], false))
		cb.toggled.connect(func(on): action.emit("view", [t[0], on]))
		v.add_child(cb)
	_body.add_child(card)
	_body.add_child(UI.section("Screenshot reference"))
	var rc := UI.card()
	var rv := UI.vbox(6)
	rc.add_child(rv)
	var has_ref := bool(view_state.get("ref_loaded", false))
	if not has_ref:
		rv.add_child(UI.label("Trace your real farm: import a screenshot, line it up with the grid, then rebuild it on top.", "Dim", true))
		var imp := UI.button("Import screenshot…", "image", "PNG / JPG / WebP")
		imp.pressed.connect(func(): action.emit("ref_import", null))
		rv.add_child(imp)
	else:
		var row := UI.hbox(6)
		var vis := CheckButton.new()
		vis.text = "Visible"
		vis.button_pressed = bool(view_state.get("ref_visible", true))
		vis.toggled.connect(func(on): action.emit("ref", {"visible": on}))
		row.add_child(vis)
		var lock := CheckButton.new()
		lock.text = "Locked"
		lock.button_pressed = bool(view_state.get("ref_locked", false))
		lock.toggled.connect(func(on): action.emit("ref", {"locked": on}))
		row.add_child(lock)
		rv.add_child(row)
		var mv := CheckButton.new()
		mv.text = "Move image by dragging"
		mv.disabled = bool(view_state.get("ref_locked", false))
		mv.toggled.connect(func(on): action.emit("ref_move", on))
		rv.add_child(mv)
		var above := CheckButton.new()
		above.text = "Show above objects"
		above.button_pressed = bool(view_state.get("ref_above", false))
		above.toggled.connect(func(on): action.emit("ref", {"above": on}))
		rv.add_child(above)
		rv.add_child(UI.label("Opacity", "Dim"))
		var op := HSlider.new()
		op.min_value = 0.05
		op.max_value = 1.0
		op.step = 0.01
		op.value = float(view_state.get("ref_opacity", 0.5))
		op.value_changed.connect(func(x): action.emit("ref", {"opacity": x}))
		rv.add_child(op)
		for f in [["Scale", "ref_scale", 0.05, 8.0, 0.01, "scale"], ["Rotation°", "ref_rotation", -45.0, 45.0, 0.1, "rotation"]]:
			var hr := UI.hbox(6)
			hr.add_child(UI.label(f[0], "Dim"))
			hr.add_child(UI.spacer())
			var sb := SpinBox.new()
			sb.min_value = f[2]
			sb.max_value = f[3]
			sb.step = f[4]
			sb.value = float(view_state.get(f[1], 1.0 if f[5] == "scale" else 0.0))
			sb.value_changed.connect(func(x): action.emit("ref", {f[5]: x}))
			hr.add_child(sb)
			rv.add_child(hr)
		rv.add_child(UI.label("Line it up roughly by dragging, then calibrate: click 3 points on the screenshot, then the same 3 tile corners on the grid.", "Faint", true))
		var row2 := UI.hbox(6)
		var cal := UI.button("Calibrate", "crosshair", "3-point alignment")
		cal.pressed.connect(func(): action.emit("ref_calibrate", null))
		row2.add_child(cal)
		var rm := UI.button("Remove", "trash", "Remove the reference image")
		rm.pressed.connect(func(): action.emit("ref_remove", null))
		row2.add_child(rm)
		rv.add_child(row2)
		var status := str(view_state.get("ref_status", ""))
		if not status.is_empty():
			rv.add_child(UI.label(status, "Faint", true))
	_body.add_child(rc)
	_body.add_child(UI.section("Compare"))
	var cc := UI.card()
	var cv := UI.vbox(6)
	cc.add_child(cv)
	var diff_txt := str(view_state.get("diff_summary", ""))
	if diff_txt.is_empty():
		cv.add_child(UI.label("Compare this layout with another saved design: additions, removals and moved objects are highlighted on the farm.", "Dim", true))
		var pick := UI.button("Compare with…", "git-compare")
		pick.pressed.connect(func(): action.emit("compare", null))
		cv.add_child(pick)
	else:
		cv.add_child(UI.label("vs. “%s”" % str(view_state.get("diff_name", "")), "Heading", true))
		cv.add_child(UI.label(diff_txt, "Dim", true))
		var legend := UI.label("Green = new here · red dashed = removed · blue = moved", "Faint", true)
		cv.add_child(legend)
		var delta: Dictionary = view_state.get("diff_delta", {})
		var keys := delta.keys()
		keys.sort_custom(func(a, b): return absi(delta[a]) > absi(delta[b]))
		for k in keys.slice(0, 10):
			var it := App.db.get_item(k)
			cv.add_child(UI.kv("%+d" % delta[k], it.name if it else k))
		var clr := UI.button("Stop comparing", "x")
		clr.pressed.connect(func(): action.emit("compare_clear", null))
		cv.add_child(clr)
	_body.add_child(cc)
