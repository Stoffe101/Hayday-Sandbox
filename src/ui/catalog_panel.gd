class_name CatalogPanel
extends PanelContainer
## Searchable, filterable item catalogue with thumbnail grid.

signal item_chosen(id: String)
signal open_assets(id: String)      ## open the Asset Manager on this item

var _search: LineEdit
var _list: ItemList
var _chips: HFlowContainer
var _count: Label
var _detail: VBoxContainer
var _sort_btn: MenuButton
var _filter_btn: MenuButton
var _scope := "all"            ## all | favorites | recent
var _category := ""
var _sort := "relevance"
var _filters := {"fits_level": false, "trusted_only": false, "placeable_only": true, "with_art": false}
var _ids: Array[String] = []
var _icon_queue: Array = []
var _debounce: Timer
var _scope_btns: Dictionary = {}
var _cat_btns: Dictionary = {}
var _selected_id := ""


func _ready() -> void:
	theme_type_variation = "FloatingPanel"
	var v := UI.vbox(10)
	add_child(v)
	var head := UI.hbox(8)
	head.add_child(UI.icon_rect("package-open", 20, UiTheme.c("accent")))
	head.add_child(UI.label("Catalogue", "Heading"))
	head.add_child(UI.spacer())
	_count = UI.label("", "Faint")
	head.add_child(_count)
	var am := UI.icon_button("image", "Asset manager — art, anchors, review (Ctrl+Shift+A)", "Ghost", 18)
	am.pressed.connect(func(): open_assets.emit(_selected_id))
	head.add_child(am)
	v.add_child(head)
	_search = LineEdit.new()
	_search.placeholder_text = "Search 1,900+ items…  (Ctrl+F)"
	_search.right_icon = Icons.get_icon("search", 18)
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): _debounce.start())
	_search.gui_input.connect(_on_search_input)
	v.add_child(_search)
	var scopes := UI.hbox(6)
	for s in [["favorites", "Favourites", "star"], ["recent", "Recent", "clock"]]:
		var b := UI.button(s[1], s[2], "", "Chip")
		b.toggle_mode = true
		b.button_pressed = s[0] == _scope
		b.pressed.connect(_set_scope.bind(s[0]))
		_scope_btns[s[0]] = b
		scopes.add_child(b)
	scopes.add_child(UI.spacer())
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
	scopes.add_child(_sort_btn)
	_filter_btn = MenuButton.new()
	_filter_btn.icon = Icons.get_icon("sparkles", 18)
	_filter_btn.tooltip_text = "Filters"
	_filter_btn.flat = true
	var fp := _filter_btn.get_popup()
	fp.hide_on_checkable_item_selection = false
	for f in [["Only items unlocked at my level", "fits_level"], ["Only verified/community sizes", "trusted_only"],
			["Hide reference-only items", "placeable_only"], ["Only items with their own art", "with_art"]]:
		fp.add_check_item(f[0])
		fp.set_item_metadata(fp.item_count - 1, f[1])
		fp.set_item_checked(fp.item_count - 1, _filters[f[1]])
	fp.index_pressed.connect(func(idx):
		var key: String = fp.get_item_metadata(idx)
		_filters[key] = not _filters[key]
		fp.set_item_checked(idx, _filters[key])
		refresh())
	scopes.add_child(_filter_btn)
	v.add_child(scopes)
	_chips = HFlowContainer.new()
	_chips.add_theme_constant_override("h_separation", 5)
	_chips.add_theme_constant_override("v_separation", 5)
	v.add_child(_chips)
	_build_chips()
	_list = ItemList.new()
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.max_columns = 0
	_list.same_column_width = true
	_list.fixed_column_width = 92
	_list.fixed_icon_size = Vector2i(76, 64)
	_list.max_text_lines = 2
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_selected)
	_list.item_clicked.connect(_on_clicked)
	_list.focus_mode = Control.FOCUS_CLICK
	_list.allow_rmb_select = true
	v.add_child(_list)
	var card := UI.card()
	_detail = UI.vbox(4)
	card.add_child(_detail)
	v.add_child(card)
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = 0.12
	_debounce.timeout.connect(refresh)
	add_child(_debounce)
	_sort = str(App.settings.get_v("catalog_sort"))
	App.settings.changed.connect(func(k):
		if k == "favorites" and _scope == "favorites":
			refresh())
	refresh()
	_show_detail("")


func focus_search() -> void:
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


func _build_chips() -> void:
	UI.clear(_chips)
	_cat_btns.clear()
	var all := UI.button("All", "", "All categories", "Chip")
	all.toggle_mode = true
	all.button_pressed = _category.is_empty()
	all.pressed.connect(_set_category.bind(""))
	_cat_btns[""] = all
	_chips.add_child(all)
	for cat in App.db.categories:
		var n := 0
		for it: ItemDef in App.db.ordered:
			if it.category == cat["id"]:
				n += 1
		if n == 0:
			continue
		var b := UI.button(_short(cat["name"], cat["id"]), cat["icon"], "%s (%d)" % [cat["name"], n], "Chip")
		b.toggle_mode = true
		b.button_pressed = _category == cat["id"]
		b.pressed.connect(_set_category.bind(cat["id"]))
		_cat_btns[cat["id"]] = b
		_chips.add_child(b)


const SHORT := {"farm_building": "Farm", "animal_home": "Animals", "fruit_tree": "Fruit", "fence": "Fences",
	"flowers": "Flowers", "nature": "Nature", "furniture": "Furniture", "seasonal": "Seasonal", "decoration": "Other",
	"obstacle": "Obstacles", "planning": "Planning", "structures": "Structures"}


func _short(n: String, id: String = "") -> String:
	return SHORT.get(id, n)


func _set_scope(s: String) -> void:
	_scope = "all" if _scope == s else s
	for k in _scope_btns:
		_scope_btns[k].button_pressed = k == _scope
	refresh()


func _set_category(c: String) -> void:
	_category = c if _category != c or c.is_empty() else ""
	for k in _cat_btns:
		_cat_btns[k].button_pressed = k == _category
	refresh()


func refresh() -> void:
	var filters := {}
	if not _category.is_empty():
		filters["category"] = _category
	if _filters["trusted_only"]:
		filters["status"] = "trusted"
	if _filters["fits_level"] and App.session:
		filters["max_level"] = int(App.session.layout.profile.get("level", 1))
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
	_icon_queue.clear()
	var favs: Array = App.settings.get_v("favorites")
	for it: ItemDef in results:
		if _filters["placeable_only"] and not it.placeable:
			continue
		if _filters["with_art"] and not App.assets.has_art(it.art_key):
			continue
		var label := ("★ " if it.id in favs else "") + it.name
		var idx := _list.add_item(label, null)
		_list.set_item_tooltip(idx, _tooltip(it))
		if not it.placeable:
			_list.set_item_custom_fg_color(idx, UiTheme.c("text_faint"))
		_ids.append(it.id)
		_icon_queue.append(idx)
		if it.id == _selected_id:
			_list.select(idx)
	var total := App.db.count()
	_count.text = "%s of %s" % [UI.fmt_int(_ids.size()), UI.fmt_int(total)]
	if _ids.is_empty():
		var msg := "No favourites yet — right-click an item to star it." if _scope == "favorites" else ("Nothing placed recently." if _scope == "recent" else "No items match “%s”." % _search.text)
		var idx := _list.add_item(msg, null, false)
		_list.set_item_disabled(idx, true)
		_ids.append("")


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


func _tooltip(it: ItemDef) -> String:
	var lines := PackedStringArray([it.name, "%d×%d tiles · %s" % [it.footprint.x, it.footprint.y, UI.status_text(it.footprint_status)]])
	if it.unlock_level > 0:
		lines.append("Unlocks at level %d" % it.unlock_level)
	if not it.placeable:
		lines.append("Reference only — fixed scenery in the game")
	return "\n".join(lines)


func _on_selected(idx: int) -> void:
	if idx >= _ids.size() or _ids[idx].is_empty():
		return
	_selected_id = _ids[idx]
	_show_detail(_selected_id)
	item_chosen.emit(_selected_id)


func _on_clicked(idx: int, at: Vector2, button: int) -> void:
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
			_list.ensure_current_is_visible()
	_show_detail(id)


func _show_detail(id: String) -> void:
	UI.clear(_detail)
	var it := App.db.get_item(id)
	if it == null:
		_detail.add_child(UI.label("Choose an item, then click on the farm to place it. Drag to paint, Shift-drag for a line, Ctrl-drag to fill.", "Dim", true))
		return
	var top := UI.hbox(10)
	var tex := TextureRect.new()
	var th := App.assets.get_thumbnail(it.art_key, "", UI.preview_mask(it))
	tex.texture = th if th else Icons.get_icon("box", 48)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(64, 56)
	top.add_child(tex)
	var info := UI.vbox(2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := UI.label(it.name, "Heading", true)
	info.add_child(nm)
	var meta := "%d×%d tiles" % [it.footprint.x, it.footprint.y]
	if it.unlock_level > 0:
		meta += " · Lv %d" % it.unlock_level
	if it.cost_coins >= 0:
		meta += " · %s coins" % UI.fmt_int(it.cost_coins)
	if it.cost_diamonds >= 0:
		meta += " · %d 💎" % it.cost_diamonds
	info.add_child(UI.label(meta, "Dim"))
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
	info.add_child(badges)
	top.add_child(info)
	_detail.add_child(top)
