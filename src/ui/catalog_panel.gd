class_name CatalogPanel
extends PanelContainer
## Searchable, filterable item catalogue: a category rail on the left, the
## thumbnail grid with footprint / level / source badges on the right.
## Realistic mode = "my farm at level N": only items unlocked at that level are
## listed (unknown unlock levels stay visible, marked "?"); "Show locked"
## adds the rest greyed out, and they can't become the brush. Creative mode is
## the full sandbox: everything is listed and placeable.
## Collapsed (main.gd), only the rail is shown; picking a category expands it.

signal item_chosen(id: String)
signal open_assets(id: String)      ## open the Asset Manager on this item
signal farm_level_requested(level: int)   ## "Set level to N" on a locked item
signal mode_requested(mode: String)       ## "Creative" on a locked item
signal expand_requested(expand: bool)     ## rail button / collapse button

## Rail: one 36 px button column; the grid keeps at least this tile width.
const RAIL_W := 40.0
const TILE_MIN := 76.0
const TILE_MAX := 104.0
const NAME_LINES := 2

var _search: LineEdit
var _list: ItemList
var _rail: VBoxContainer
var _rail_scroll: ScrollContainer
var _main: VBoxContainer
var _collapse_btn: Button
var _count: Label
var _scope_label: Label
var _detail: VBoxContainer
var _detail_card: PanelContainer
var _sort_btn: MenuButton
var _filter_btn: MenuButton
var _scope := "all"            ## all | favorites | recent
var _category := ""
var _sort := "relevance"
var _filters := {"trusted_only": false, "placeable_only": true, "with_art": false}
var _show_locked := false      ## Realistic: also list items above the farm level (greyed)
var _level_ctx := ""           ## "<mode>:<level>" the list was built for
var _level_box: VBoxContainer
var _level_icon: TextureRect
var _level_text: Label
var _locked_btn: Button
var _unknown_text: Label
var _ids: Array[String] = []
var _icon_queue: Array = []
var _debounce: Timer
var _rail_btns: Dictionary = {}    ## "scope:<id>" / "cat:<id>" -> Button
var _selected_id := ""
var _collapsed := false
var _col_w := 0                    ## current tile width (names are wrapped to it)
var _wrap_cache: Dictionary = {}   ## name -> wrapped text at _col_w
var _states: Array[String] = []    ## per row: RealisticAnalyzer level state
var _favs: Dictionary = {}
var _empty: Label                  ## "No items match …" over the empty grid
var _detail_is_hint := true        ## the detail card shows only the placing hint
var _chip_boxes: Dictionary = {}   ## Color -> StyleBoxFlat for the tile badges


func _ready() -> void:
	theme_type_variation = "FloatingPanel"
	var row := UI.hbox(8)
	add_child(row)
	_build_rail(row)
	_main = UI.vbox(8)
	_main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_main)
	var v := _main
	var head := UI.hbox(6)
	head.add_child(UI.icon_rect("package-open", 20, UiTheme.c("accent")))
	var title := UI.label("Catalogue", "Heading")
	title.clip_text = true
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_count = UI.label("", "Faint")
	head.add_child(_count)
	var am := UI.icon_button("image", "Asset manager — art, anchors, review (Ctrl+Shift+A)", "Ghost", 18)
	am.pressed.connect(func(): open_assets.emit(_selected_id))
	head.add_child(am)
	v.add_child(head)
	_search = LineEdit.new()
	_search.placeholder_text = "Search items…  (Ctrl+F)"
	_search.tooltip_text = "Search 1,900+ items by name or tag (Ctrl+F)"
	_search.right_icon = Icons.get_icon("search", 18)
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): _debounce.start())
	_search.gui_input.connect(_on_search_input)
	v.add_child(_search)
	var bar := UI.hbox(4)
	_scope_label = UI.label("All items", "Dim")
	_scope_label.clip_text = true
	_scope_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_scope_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_scope_label)
	_sort_btn = MenuButton.new()
	_sort_btn.icon = Icons.get_icon("arrow-up-down", 18)
	_sort_btn.tooltip_text = "Sort"
	_sort_btn.flat = true
	var sp := _sort_btn.get_popup()
	for i in [["Best match", "relevance"], ["Name", "name"], ["Unlock level", "level"], ["Size (largest first)", "size"]]:
		sp.add_radio_check_item(i[0])
		sp.set_item_metadata(sp.item_count - 1, i[1])
	sp.index_pressed.connect(func(idx):
		_sort = sp.get_item_metadata(idx)
		for k in sp.item_count:
			sp.set_item_checked(k, k == idx)
		App.settings.set_v("catalog_sort", _sort)
		refresh())
	bar.add_child(_sort_btn)
	_filter_btn = MenuButton.new()
	_filter_btn.icon = Icons.get_icon("sparkles", 18)
	_filter_btn.tooltip_text = "Filters"
	_filter_btn.flat = true
	var fp := _filter_btn.get_popup()
	fp.hide_on_checkable_item_selection = false
	for f in [["Only verified/community sizes", "trusted_only"],
			["Hide reference-only items", "placeable_only"], ["Only items with their own art", "with_art"]]:
		fp.add_check_item(f[0])
		fp.set_item_metadata(fp.item_count - 1, f[1])
		fp.set_item_checked(fp.item_count - 1, _filters[f[1]])
	fp.index_pressed.connect(func(idx):
		var key: String = fp.get_item_metadata(idx)
		_filters[key] = not _filters[key]
		fp.set_item_checked(idx, _filters[key])
		refresh())
	bar.add_child(_filter_btn)
	v.add_child(bar)
	_build_level_strip(v)
	_list = ItemList.new()
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.max_columns = 0
	_list.same_column_width = true
	_list.fixed_column_width = 88
	_list.fixed_icon_size = Vector2i(72, 60)
	_list.max_text_lines = NAME_LINES
	_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.clip_contents = true
	_list.item_selected.connect(_on_selected)
	_list.item_clicked.connect(_on_clicked)
	_list.focus_mode = Control.FOCUS_CLICK
	_list.allow_rmb_select = true
	_list.draw.connect(_draw_badges)
	_list.resized.connect(_on_list_resized)
	v.add_child(_list)
	_empty = UI.label("", "Dim", true)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_empty.offset_left = 12
	_empty.offset_right = -12
	_empty.offset_top = 24
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_child(_empty)
	_detail_card = UI.card()
	_detail = UI.vbox(4)
	_detail_card.add_child(_detail)
	v.add_child(_detail_card)
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = 0.12
	_debounce.timeout.connect(refresh)
	add_child(_debounce)
	_sort = str(App.settings.get_v("catalog_sort"))
	App.settings.changed.connect(func(k):
		if k == "favorites":
			if _scope == "favorites":
				refresh()
			else:
				_favs_changed())
	_sync_rail()
	refresh()
	_show_detail("")


func focus_search() -> void:
	if _collapsed:
		expand_requested.emit(true)
	_search.grab_focus()
	_search.select_all()


func _on_search_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		_search.release_focus()
		accept_event()
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ENTER and _list.item_count > 0:
		_list.select(0)
		_on_selected(0)
		_search.release_focus()


# ---------------------------------------------------------------------------
# Category rail + collapsed state
# ---------------------------------------------------------------------------

func _build_rail(parent: Container) -> void:
	var col := UI.vbox(6)
	col.custom_minimum_size.x = RAIL_W
	parent.add_child(col)
	_collapse_btn = UI.icon_button("panel-left", "Collapse the catalogue to this rail ([)", "Rail", 18)
	_collapse_btn.custom_minimum_size = Vector2(RAIL_W, 34)
	_collapse_btn.pressed.connect(func(): expand_requested.emit(_collapsed))
	col.add_child(_collapse_btn)
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 2)
	col.add_child(sep)
	_rail_scroll = ScrollContainer.new()
	_rail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_rail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_rail_scroll)
	_rail = UI.vbox(3)
	_rail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rail_scroll.add_child(_rail)
	_rail_button("scope:all", "layout-grid", "All items")
	_rail_button("scope:favorites", "star", "Favourites (right-click an item to star it)")
	_rail_button("scope:recent", "clock", "Recently placed")
	var sep2 := HSeparator.new()
	sep2.add_theme_constant_override("separation", 6)
	_rail.add_child(sep2)
	for cat in App.db.categories:
		var n := 0
		for it: ItemDef in App.db.ordered:
			if it.category == cat["id"]:
				n += 1
		if n == 0:
			continue
		_rail_button("cat:" + str(cat["id"]), str(cat["icon"]), "%s (%s)" % [cat["name"], UI.fmt_int(n)])
	_sync_rail()


func _rail_button(key: String, icon: String, tip: String) -> void:
	var b := UI.icon_button(icon, tip, "Rail", 18)
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(RAIL_W, 34)
	b.pressed.connect(_on_rail.bind(key))
	_rail_btns[key] = b
	_rail.add_child(b)


func _on_rail(key: String) -> void:
	var kind := key.get_slice(":", 0)
	var id := key.get_slice(":", 1)
	if kind == "scope":
		_scope = id
		_category = ""
	else:
		# A category narrows the current scope (all / favourites / recent).
		_category = "" if _category == id and not _collapsed else id
	_sync_rail()
	refresh()
	if _collapsed:
		expand_requested.emit(true)


func _sync_rail() -> void:
	for k: String in _rail_btns:
		var on := false
		if k.begins_with("scope:"):
			# "All" lights up only while no category narrows it.
			on = k == "scope:" + _scope and not (_scope == "all" and not _category.is_empty())
		else:
			on = k == "cat:" + _category
		(_rail_btns[k] as Button).set_pressed_no_signal(on)
	if _scope_label:
		var txt: String = {"all": "All items", "favorites": "Favourites", "recent": "Recent"}.get(_scope, "All items")
		if not _category.is_empty():
			var cname := str(App.db.category(_category)["name"])
			txt = cname if _scope == "all" else "%s · %s" % [txt, cname]
		_scope_label.text = txt
		_scope_label.tooltip_text = txt


func set_collapsed(on: bool) -> void:
	## Collapsed: only the rail (main.gd sizes the panel to rail_width()).
	if on == _collapsed and _main.visible != on:
		return
	_collapsed = on
	_main.visible = not on
	_collapse_btn.icon = Icons.get_icon("panel-left", 18)
	_collapse_btn.tooltip_text = "Expand the catalogue ([)" if on else "Collapse the catalogue to this rail ([)"
	_collapse_btn.set_pressed_no_signal(false)
	if not on:
		_fit_columns.call_deferred()


func is_collapsed() -> bool:
	return _collapsed


func rail_width() -> float:
	## Panel width when collapsed: the rail plus the panel's own padding.
	var sb := get_theme_stylebox("panel")
	var pad := sb.get_minimum_size().x if sb else 24.0
	return RAIL_W + pad


# ---------------------------------------------------------------------------
# Level strip
# ---------------------------------------------------------------------------

func _build_level_strip(parent: Container) -> void:
	## "1,169 of 1,949 available at level 60" + "Show locked" (Realistic), or
	## the sandbox note (Creative).
	_level_box = UI.vbox(4)
	var row := UI.hbox(6)
	_level_icon = UI.icon_rect("sprout", 16, UiTheme.c("accent"))
	row.add_child(_level_icon)
	_level_text = UI.label("", "Faint", true)
	_level_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_text.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_child(_level_text)
	_level_box.add_child(row)
	# Wraps instead of widening the panel on narrow catalogues.
	var row2 := HFlowContainer.new()
	row2.add_theme_constant_override("h_separation", 8)
	row2.add_theme_constant_override("v_separation", 4)
	_locked_btn = UI.button("Show locked", "lock", "Also list items your farm level hasn't unlocked yet (greyed; they can't be placed in Realistic mode)", "Chip")
	_locked_btn.toggle_mode = true
	_locked_btn.button_pressed = _show_locked
	_locked_btn.toggled.connect(func(on: bool):
		_show_locked = on
		refresh())
	row2.add_child(_locked_btn)
	_unknown_text = UI.label("", "Faint")
	_unknown_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_unknown_text.mouse_filter = Control.MOUSE_FILTER_STOP
	_unknown_text.tooltip_text = "Items whose unlock level isn't known stay visible, marked “?”. They are never guessed — check them in the game."
	row2.add_child(_unknown_text)
	_level_box.add_child(row2)
	parent.add_child(_level_box)


func _mode() -> String:
	return App.session.layout.mode if App.session else FarmLayout.MODE_CREATIVE


func _level() -> int:
	return RealisticAnalyzer.farm_level(App.session.layout) if App.session else 1


func _realistic() -> bool:
	return _mode() == FarmLayout.MODE_REALISTIC


func on_level_context_changed() -> void:
	## Mode or farm level changed (also on undo/redo): rebuild the list when the
	## level view differs, and drop a brush that the new level can't place.
	var key := "%s:%d" % [_mode(), _level()]
	if key != _level_ctx:
		refresh()
		_show_detail(_selected_id)
	_drop_locked_brush()


func _drop_locked_brush() -> void:
	var s := App.session
	if s == null or s.active_item.is_empty():
		return
	var why := RealisticAnalyzer.item_level_block(s.db.get_item(s.active_item), s.layout.mode, _level())
	if why.is_empty():
		return
	var keep := _selected_id
	_disarm(s)
	_reselect(keep)
	App.toast(why, "warn")


func _disarm(s: EditorSession) -> void:
	## Drop the brush (and the place tool's ghost) without touching the layout.
	if s == null:
		return
	if not s.active_item.is_empty():
		s.set_active_item("")
	if s.tool == "place":
		s.set_tool("select")


func _reselect(id: String) -> void:
	## Keep showing an item in the list/detail without arming the brush.
	_selected_id = id
	for i in _ids.size():
		if _ids[i] == id and not id.is_empty():
			_list.select(i)
	_show_detail(id)


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------

func refresh() -> void:
	var filters := {}
	if not _category.is_empty():
		filters["category"] = _category
	if _filters["trusted_only"]:
		filters["status"] = "trusted"
	if _scope == "favorites":
		var d := {}
		for f in App.settings.get_v("favorites"):
			d[f] = true
		filters["ids"] = d
	elif _scope == "recent":
		var d2 := {}
		for f in App.settings.get_v("recent_items"):
			d2[f] = true
		filters["ids"] = d2
	var results := App.db.search(_search.text, filters, _sort)
	if _scope == "recent" and _search.text.is_empty():
		var order: Array = App.settings.get_v("recent_items")
		results.sort_custom(func(a, b): return order.find(a.id) < order.find(b.id))
	_list.clear()
	_ids.clear()
	_states.clear()
	_icon_queue.clear()
	var matching: Array[ItemDef] = []
	for it: ItemDef in results:
		if _filters["placeable_only"] and not it.placeable:
			continue
		if _filters["with_art"] and not App.assets.has_art(it.art_key):
			continue
		matching.append(it)
	var mode := _mode()
	var level := _level()
	_level_ctx = "%s:%d" % [mode, level]
	var lf := RealisticAnalyzer.filter_by_level(matching, mode, level, _show_locked)
	_favs.clear()
	for f in App.settings.get_v("favorites"):
		_favs[f] = true
	if _col_w <= 0:
		_col_w = _list.fixed_column_width
	for it: ItemDef in lf["items"]:
		var st := RealisticAnalyzer.mode_level_state(it, mode, level)
		var idx := _list.add_item(_wrapped(it.name), null)
		_list.set_item_tooltip(idx, _tooltip(it, st))
		if not it.placeable or st == RealisticAnalyzer.ABOVE_LEVEL:
			_list.set_item_custom_fg_color(idx, UiTheme.c("text_faint"))
		if st == RealisticAnalyzer.ABOVE_LEVEL:
			_list.set_item_icon_modulate(idx, Color(1, 1, 1, 0.4))
		_ids.append(it.id)
		_states.append(st)
		_icon_queue.append(idx)
		if it.id == _selected_id:
			_list.select(idx)
	var total := App.db.count()
	_count.text = UI.fmt_int(_ids.size()) if _ids.size() != total else UI.fmt_int(total)
	_count.tooltip_text = "%s of %s items shown" % [UI.fmt_int(_ids.size()), UI.fmt_int(total)]
	_count.mouse_filter = Control.MOUSE_FILTER_STOP
	_update_level_strip(lf, mode, level)
	_empty.visible = _ids.is_empty()
	if _ids.is_empty():
		var msg := "No favourites yet — right-click an item to star it." if _scope == "favorites" else ("Nothing placed recently." if _scope == "recent" else "No items match “%s”." % _search.text)
		if mode == FarmLayout.MODE_REALISTIC and not _show_locked and int(lf["locked"]) > 0:
			msg = "Nothing here is unlocked at level %d yet — %s locked item%s hidden. Use “Show locked” to see them." % [level, UI.fmt_int(lf["locked"]), "" if int(lf["locked"]) == 1 else "s"]
		_empty.text = msg
	_list.queue_redraw()


func _on_list_resized() -> void:
	_fit_columns()
	# A selection scrolled into view before the grid shrank (detail card, the
	# level note wrapping at larger UI scales) would end up half hidden.
	if _list.is_anything_selected():
		_list.ensure_current_is_visible()


func _fit_columns() -> void:
	## Tiles fill the list's width exactly (2+ columns); names are re-wrapped to
	## the new tile width, so they never break inside a word.
	if _list == null or _list.size.x <= 0.0:
		return
	# ItemList wraps a row once (column width + h_separation) * n exceeds its
	# width minus the panel margins and the scroll bar.
	var sb := _list.get_theme_stylebox("panel")
	var hsep := float(_list.get_theme_constant("h_separation"))
	var fit := _list.size.x - (sb.get_minimum_size().x if sb else 4.0) - _list.get_v_scroll_bar().get_combined_minimum_size().x - 1.0
	var cols := maxi(1, int(floor(fit / (TILE_MIN + hsep))))
	var w := int(floor(fit / cols - hsep))
	w = clampi(w, int(TILE_MIN) - 16, int(TILE_MAX))
	if w == _col_w and _list.fixed_column_width == w:
		return
	_col_w = w
	_wrap_cache.clear()
	_list.fixed_column_width = w
	_list.fixed_icon_size = Vector2i(w - 16, int((w - 16) * 0.84))
	for i in _ids.size():
		if not _ids[i].is_empty():
			var it := App.db.get_item(_ids[i])
			if it:
				_list.set_item_text(i, _wrapped(it.name))


func _wrapped(text: String) -> String:
	if _wrap_cache.has(text):
		return _wrap_cache[text]
	var out := _wrap_text(text, float(_col_w) - 10.0, NAME_LINES)
	_wrap_cache[text] = out
	return out


func _wrap_text(text: String, width: float, max_lines: int) -> String:
	## Word wrap with explicit line breaks: ItemList would otherwise break inside
	## words ("Döner Kebab Sta|nd"). A word wider than the tile is shortened
	## with an ellipsis instead of split; extra lines end in an ellipsis.
	var font := _list.get_theme_font("font")
	var fs := _list.get_theme_font_size("font_size")
	var lines := PackedStringArray()
	var cur := ""
	for word in text.split(" ", false):
		var cand := word if cur.is_empty() else cur + " " + word
		if cur.is_empty() or font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width:
			cur = cand
		else:
			lines.append(cur)
			cur = word
	if not cur.is_empty():
		lines.append(cur)
	if lines.size() > max_lines:
		var rest := " ".join(lines.slice(max_lines - 1))
		lines = lines.slice(0, max_lines - 1)
		lines.append(_ellipsize(rest, width, font, fs, true))
	for i in lines.size():
		if font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width:
			lines[i] = _ellipsize(lines[i], width, font, fs, false)
	return "\n".join(lines)


static func _ellipsize(s: String, width: float, font: Font, fs: int, force: bool) -> String:
	var t := s
	if not force and font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width:
		return t
	while t.length() > 1 and font.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width:
		t = t.left(t.length() - 1)
	return t.strip_edges() + "…"


func _draw_badges() -> void:
	## Footprint (top left), unlock level (top right), size-source dot and
	## favourite star on every visible tile, drawn over the ItemList.
	if _ids.is_empty() or _ids[0].is_empty():
		return
	var font: Font = UiTheme.font_bold if UiTheme.font_bold else _list.get_theme_font("font")
	var fs := 11
	var vis := Rect2(Vector2.ZERO, _list.size)
	var scroll := _list.get_v_scroll_bar().value
	var real := _realistic()
	var star := Icons.get_icon("star", 12)
	for i in _ids.size():
		var r := _list.get_item_rect(i, false)
		r.position.y -= scroll
		if not vis.intersects(r) or _ids[i].is_empty():
			continue
		var it := App.db.get_item(_ids[i])
		if it == null:
			continue
		var dim := 0.45 if _states[i] == RealisticAnalyzer.ABOVE_LEVEL else 1.0
		var tl := r.position + Vector2(3, 3)
		_chip(font, fs, tl, "%d×%d" % [it.footprint.x, it.footprint.y], Color(0, 0, 0, 0.55 * dim), Color(1, 1, 1, 0.95 * dim), false)
		var lv := ""
		var lcol := Color(0, 0, 0, 0.55 * dim)
		if it.unlock_level > 0:
			lv = "Lv%d" % it.unlock_level
		elif real:
			lv = "Lv?"
		if real and _states[i] == RealisticAnalyzer.ABOVE_LEVEL:
			lcol = Color(UiTheme.c("danger"), 0.85)
		elif real and _states[i] == RealisticAnalyzer.LEVEL_UNKNOWN:
			lcol = Color(UiTheme.c("warn"), 0.85)
		if not lv.is_empty():
			_chip(font, fs, Vector2(r.end.x - 3, r.position.y + 3), lv, lcol, Color(1, 1, 1, 0.95), true)
		# Size source: a dot coloured like the footprint badge in the details.
		var dot := Vector2(r.position.x + 9, r.position.y + 3 + 26)
		_list.draw_circle(dot, 4.5, Color(0, 0, 0, 0.5 * dim))
		_list.draw_circle(dot, 3.2, Color(UI.status_color(it.footprint_status), dim))
		if _favs.has(it.id) and star:
			_list.draw_texture_rect(star, Rect2(Vector2(r.end.x - 17, r.position.y + 22), Vector2(13, 13)), false, UiTheme.c("warn"))


func _chip(font: Font, fs: int, at: Vector2, text: String, bg: Color, fg: Color, right: bool) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 8.0
	var h := font.get_height(fs) + 2.0
	var p := at - Vector2(w, 0) if right else at
	if not _chip_boxes.has(bg):
		_chip_boxes[bg] = UiTheme.box(bg, 6, Color.TRANSPARENT, 0, Vector4.ZERO)
	_list.draw_style_box(_chip_boxes[bg], Rect2(p, Vector2(w, h)))
	_list.draw_string(font, p + Vector2(4, 1 + font.get_ascent(fs)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, fg)


func _favs_changed() -> void:
	_favs.clear()
	for f in App.settings.get_v("favorites"):
		_favs[f] = true
	_list.queue_redraw()


func _update_level_strip(lf: Dictionary, mode: String, level: int) -> void:
	if _level_box == null:
		return
	var real := mode == FarmLayout.MODE_REALISTIC
	_level_icon.texture = Icons.get_icon("sprout" if real else "wand-sparkles", 16)
	_locked_btn.get_parent().visible = real
	if not real:
		_level_text.text = "Sandbox — every item unlocked"
		_level_text.tooltip_text = "Creative mode places anything, whatever its unlock level. Switch to Realistic to see only what your farm has unlocked."
		return
	var unlocked: int = lf["unlocked"]
	var total: int = lf["total"]
	_level_text.text = "%s of %s available at level %d" % [UI.fmt_int(unlocked), UI.fmt_int(total), level]
	_level_text.tooltip_text = "Realistic mode: your farm is level %d (change it in the top bar). Items above it are hidden unless “Show locked” is on, and can't be placed." % level
	_locked_btn.text = "Show locked (%s)" % UI.fmt_int(lf["locked"])
	_locked_btn.set_pressed_no_signal(_show_locked)
	var unknown: int = lf["unknown"]
	_unknown_text.visible = unknown > 0
	_unknown_text.text = "%s level unknown" % UI.fmt_int(unknown)


func _process(_dt: float) -> void:
	# Progressive thumbnail loading keeps search/filter instant.
	var budget := 24
	while budget > 0 and not _icon_queue.is_empty():
		var idx: int = _icon_queue.pop_front()
		if idx < _ids.size() and not _ids[idx].is_empty():
			var it := App.db.get_item(_ids[idx])
			# Thumbnails only: never forces full-size art of large packs to load.
			var th := App.assets.get_thumbnail(it.art_key, "", UI.preview_mask(it))
			_list.set_item_icon(idx, th if th else Icons.get_icon("box", 48))
		budget -= 1


func refresh_art(art_keys: Array) -> void:
	## Re-queue thumbnails of items whose art changed (override edits).
	var ks := {}
	for k in art_keys:
		ks[str(k)] = true
	for i in _ids.size():
		if _ids[i].is_empty():
			continue
		var it := App.db.get_item(_ids[i])
		if it and ks.has(it.art_key) and not i in _icon_queue:
			_icon_queue.append(i)
	if ks.has(_art_key_of(_selected_id)):
		_show_detail(_selected_id)


func _art_key_of(id: String) -> String:
	var it := App.db.get_item(id)
	return it.art_key if it else ""


func _tooltip(it: ItemDef, state: String = RealisticAnalyzer.AVAILABLE) -> String:
	var lines := PackedStringArray([it.name, "%d×%d tiles · %s" % [it.footprint.x, it.footprint.y, UI.status_text(it.footprint_status)]])
	if it.unlock_level > 0:
		lines.append("Unlocks at level %d" % it.unlock_level)
	if _realistic():
		if state == RealisticAnalyzer.ABOVE_LEVEL:
			lines.append("Locked — your farm is level %d" % _level())
		elif state == RealisticAnalyzer.LEVEL_UNKNOWN:
			lines.append("Unlock level unknown — not checked against your level")
	if not it.placeable:
		lines.append("Reference only — fixed scenery in the game")
	if _favs.has(it.id):
		lines.append("★ Favourite")
	return "\n".join(lines)


func _on_selected(idx: int) -> void:
	if idx >= _ids.size() or _ids[idx].is_empty():
		return
	var id := _ids[idx]
	var why := RealisticAnalyzer.item_level_block(App.db.get_item(id), _mode(), _level())
	if not why.is_empty():
		# Realistic mode: a locked item can be inspected but not placed.
		_disarm(App.session)
		_reselect(id)
		App.toast(why, "warn")
		return
	_selected_id = id
	_show_detail(_selected_id)
	item_chosen.emit(_selected_id)


func _on_clicked(idx: int, _at: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT or idx >= _ids.size() or _ids[idx].is_empty():
		return
	var id := _ids[idx]
	var pm := PopupMenu.new()
	var fav: bool = id in App.settings.get_v("favorites")
	pm.add_item("Remove from favourites" if fav else "Add to favourites", 0)
	pm.add_item("Select all placed", 1)
	pm.add_item("Show details", 2)
	pm.id_pressed.connect(_on_menu.bind(id))
	add_child(pm)
	pm.popup(Rect2i(Vector2i(get_viewport().get_mouse_position()), Vector2i.ZERO))
	pm.popup_hide.connect(pm.queue_free)


func _on_menu(pid: int, id: String) -> void:
	match pid:
		0:
			App.settings.toggle_favorite(id)
			if _scope == "favorites":
				refresh()
		1:
			if App.session:
				var uids: Array = []
				for o: PlacedObject in App.session.layout.objects.values():
					if o.item_id == id:
						uids.append(o.uid)
				App.session.select(uids, false, false)
		2:
			_show_detail(id)


func select_item(id: String) -> void:
	_selected_id = id
	for i in _ids.size():
		if _ids[i] == id:
			_list.select(i)
	# The detail card grows below the grid, so the grid shrinks after this; the
	# list re-scrolls on resize (_on_list_resized) to keep the whole tile in view.
	_show_detail(id)
	_list.ensure_current_is_visible()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _detail_card:
		_sync_detail_card()


func _sync_detail_card() -> void:
	## The "how to place" hint gives its room to the grid on short panels.
	_detail_card.visible = not _detail_is_hint or size.y >= 640.0


func _show_detail(id: String) -> void:
	UI.clear(_detail)
	var it := App.db.get_item(id)
	_detail_is_hint = it == null
	_sync_detail_card()
	if it == null:
		_detail.add_child(UI.label("Pick an item, then click the farm to place it. Drag to paint · Shift-drag line · Ctrl-drag fill.", "Faint", true))
		return
	var top := UI.hbox(10)
	var tex := TextureRect.new()
	var th := App.assets.get_thumbnail(it.art_key, "", UI.preview_mask(it))
	tex.texture = th if th else Icons.get_icon("box", 48)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(56, 48)
	top.add_child(tex)
	var info := UI.vbox(2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := UI.label(it.name, "Heading", true)
	info.add_child(nm)
	var meta := PackedStringArray(["%d×%d tiles" % [it.footprint.x, it.footprint.y]])
	if it.unlock_level > 0:
		meta.append("Lv %d" % it.unlock_level)
	if it.cost_coins >= 0:
		meta.append("%s coins" % UI.fmt_int(it.cost_coins))
	if it.cost_diamonds >= 0:
		meta.append("%s diamonds" % UI.fmt_int(it.cost_diamonds))
	info.add_child(UI.label(" · ".join(meta), "Dim", true))
	var badges := HFlowContainer.new()
	badges.add_theme_constant_override("h_separation", 4)
	badges.add_theme_constant_override("v_separation", 4)
	badges.add_child(UI.badge(UI.status_text(it.footprint_status), UI.status_color(it.footprint_status)))
	badges.add_child(UI.art_badge(App.assets.art_status(it.art_key)))
	var nv := App.assets.variants_of(it.art_key).size()
	if nv > 0:
		badges.add_child(UI.badge("%d variant%s" % [nv, "" if nv == 1 else "s"], UiTheme.c("info")))
	if it.flippable:
		badges.add_child(UI.badge("Rotatable", UiTheme.c("text_dim")))
	var st := RealisticAnalyzer.mode_level_state(it, _mode(), _level())
	if st == RealisticAnalyzer.ABOVE_LEVEL:
		badges.add_child(UI.badge("Locked · Lv %d" % it.unlock_level, UiTheme.c("danger")))
	elif st == RealisticAnalyzer.LEVEL_UNKNOWN:
		var ub := UI.badge("Level unknown", UiTheme.c("warn"))
		ub.tooltip_text = "This item's unlock level isn't known, so it isn't checked against your farm level."
		badges.add_child(ub)
	info.add_child(badges)
	top.add_child(info)
	_detail.add_child(top)
	if st == RealisticAnalyzer.ABOVE_LEVEL:
		_detail.add_child(UI.label("Unlocks at level %d — your farm is level %d, so it can't be placed in Realistic mode." % [it.unlock_level, _level()], "Dim", true))
		var acts := HFlowContainer.new()
		acts.add_theme_constant_override("h_separation", 6)
		acts.add_theme_constant_override("v_separation", 6)
		var up := UI.button("Set level to %d" % it.unlock_level, "sprout", "Raise this farm's level (undoable; placed objects don't change)", "Ghost")
		up.pressed.connect(func():
			farm_level_requested.emit(it.unlock_level)
			_arm_if_allowed(it.id))
		acts.add_child(up)
		var cr := UI.button("Creative", "wand-sparkles", "Sandbox: everything unlocked", "Ghost")
		cr.pressed.connect(func():
			mode_requested.emit(FarmLayout.MODE_CREATIVE)
			_arm_if_allowed(it.id))
		acts.add_child(cr)
		_detail.add_child(acts)


func _arm_if_allowed(id: String) -> void:
	## After "Set level" / "Creative" on a locked item: pick it up as the brush
	## once the new level or mode allows it.
	if not RealisticAnalyzer.item_level_block(App.db.get_item(id), _mode(), _level()).is_empty():
		return
	_reselect(id)
	item_chosen.emit(id)
