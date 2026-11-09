class_name Gallery
extends RefCounted
## Layout gallery modal: browse, open, create (from templates), duplicate,
## rename, delete (to trash), import/export files and restore snapshots.

signal open_layout(id: String)
signal open_template(path: String, name: String)
signal new_layout(template: String)
signal import_file(path: String)

var modal: Modal
var _grid: GridContainer
var _parent: Control
var _search: LineEdit


func show(parent: Control) -> void:
	_parent = parent
	modal = Modal.open(parent, "Your farm layouts", 1060, "layout-grid")
	var bar := UI.hbox(8)
	_search = LineEdit.new()
	_search.placeholder_text = "Filter layouts…"
	_search.right_icon = Icons.get_icon("search", 18)
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t): _fill())
	bar.add_child(_search)
	var nb := UI.button("New layout", "file-plus", "", "Accent")
	nb.pressed.connect(_new_menu.bind(nb))
	bar.add_child(nb)
	var ib := UI.button("Import file…", "upload")
	ib.pressed.connect(_import)
	bar.add_child(ib)
	modal.body.add_child(bar)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(1000, 560)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 14)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	modal.body.add_child(scroll)
	_fill()
	_add_templates()


func _fill() -> void:
	UI.clear(_grid)
	var q := _search.text.to_lower()
	var list := App.library.list()
	var shown := 0
	for e in list:
		if not q.is_empty() and str(e["name"]).to_lower().find(q) < 0:
			continue
		_grid.add_child(_card(e))
		shown += 1
	if shown == 0:
		var empty := UI.vbox(6)
		empty.custom_minimum_size = Vector2(980, 120)
		empty.add_child(UI.label("No saved layouts yet" if q.is_empty() else "No layouts match “%s”" % q, "Heading"))
		empty.add_child(UI.label("Create one with “New layout”, or start from a template below.", "Dim"))
		_grid.add_child(empty)


func _card(e: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	card.custom_minimum_size = Vector2(236, 0)
	var v := UI.vbox(6)
	card.add_child(v)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(212, 128)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	if not str(e.get("thumb", "")).is_empty():
		var img := Image.load_from_file(ProjectSettings.globalize_path(e["thumb"]))
		if img:
			thumb.texture = ImageTexture.create_from_image(img)
	if thumb.texture == null:
		thumb.texture = Icons.get_icon("tent-tree", 96)
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.modulate = Color(1, 1, 1, 0.35)
	var current: bool = App.session != null and App.session.layout.id == str(e["id"])
	var open_btn := Button.new()
	open_btn.flat = true
	open_btn.custom_minimum_size = thumb.custom_minimum_size
	open_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	open_btn.tooltip_text = "Open"
	open_btn.add_child(thumb)
	thumb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	open_btn.pressed.connect(func():
		modal.close()
		open_layout.emit(e["id"]))
	v.add_child(open_btn)
	var name_row := UI.hbox(4)
	var nl := UI.label(str(e["name"]), "Heading")
	nl.clip_text = true
	nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(nl)
	if current:
		name_row.add_child(UI.badge("Open", UiTheme.c("accent")))
	v.add_child(name_row)
	var date := str(e.get("modified", "")).replace("T", " ").left(16)
	v.add_child(UI.label("%d objects · %d plots · %s" % [e.get("objects", 0), e.get("plots", 0), str(e.get("mode", "")).capitalize()], "Faint"))
	v.add_child(UI.label("Edited %s UTC" % date if not date.is_empty() else "", "Faint"))
	var row := UI.hbox(2)
	for a in [["copy-plus", "Duplicate"], ["pencil", "Rename"], ["clock-arrow-up", "Revisions"], ["download", "Export file"], ["trash", "Delete"]]:
		var b := UI.icon_button(a[0], a[1])
		b.pressed.connect(_card_action.bind(a[1], e))
		row.add_child(b)
	v.add_child(row)
	return card


func _card_action(what: String, e: Dictionary) -> void:
	match what:
		"Duplicate":
			var nid := App.library.duplicate_layout(e["id"])
			App.toast("Duplicated “%s”" % e["name"] if not nid.is_empty() else "Duplicate failed", "success" if not nid.is_empty() else "error")
			_fill()
		"Rename":
			Modal.prompt(_parent, "Rename layout", e["name"], func(t):
				if t.strip_edges().is_empty():
					return
				if App.session and App.session.layout.id == e["id"]:
					App.session.execute(EditCommands.SetMeta.new(App.session.layout.name, t.strip_edges()))
					App.save_current(false)
				else:
					App.library.rename(e["id"], t.strip_edges())
				_fill())
		"Delete":
			Modal.confirm(_parent, "Delete layout?", "“%s” will be moved to the trash folder in your data directory (it can be recovered from there)." % e["name"], "Delete", true, func():
				if App.session and App.session.layout.id == e["id"]:
					App.toast("Close or switch away from the open layout before deleting it", "warn")
					return
				App.library.delete(e["id"])
				_fill())
		"Export file":
			var fd := FileDialog.new()
			fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
			fd.access = FileDialog.ACCESS_FILESYSTEM
			fd.use_native_dialog = true
			fd.filters = PackedStringArray(["*.hdlayout ; Hayday Sandbox layout"])
			fd.current_file = str(e["name"]).validate_filename() + ".hdlayout"
			fd.file_selected.connect(func(p):
				var err := App.library.export_file(e["id"], p)
				App.toast("Exported to %s" % p if err == OK else "Export failed: %s" % error_string(err), "success" if err == OK else "error"))
			_parent.add_child(fd)
			fd.popup_centered_ratio(0.6)
		"Revisions":
			_revisions(e)


func _revisions(e: Dictionary) -> void:
	var m := Modal.open(_parent, "Revisions of “%s”" % e["name"], 520, "clock-arrow-up")
	var snaps := App.library.history(e["id"])
	if snaps.is_empty():
		m.body.add_child(UI.label("No revisions yet. A snapshot is stored every time you save (Ctrl+S); the last %d are kept." % LayoutLibrary.MAX_HISTORY, "Dim", true))
	var v := UI.vbox(4)
	for s in snaps.slice(0, 30):
		var row := UI.hbox(8)
		row.add_child(UI.label(str(s["stamp"]).replace("T", " "), ""))
		row.add_child(UI.spacer())
		var b := UI.button("Restore as copy", "copy-plus")
		b.pressed.connect(func():
			var rep := LayoutIO.LoadReport.new()
			var l := App.library.load_path(s["path"], rep)
			if l:
				l.id = LayoutLibrary.new_id()
				l.name = "%s (restored %s)" % [e["name"], str(s["stamp"]).left(10)]
				App.library.save(l, false)
				App.toast("Restored as “%s”" % l.name, "success")
				m.close()
				_fill())
		row.add_child(b)
		v.add_child(row)
	m.body.add_child(v)
	m.add_button("Close", "", m.close)


func _new_menu(anchor: Button) -> void:
	var pm := PopupMenu.new()
	pm.add_item("Starting land with core buildings", 0)
	pm.add_item("Fully expanded (all mapped plots)", 1)
	pm.add_item("Completely empty", 2)
	pm.id_pressed.connect(func(id):
		modal.close()
		new_layout.emit(["starter", "expanded", "empty"][id]))
	anchor.add_child(pm)
	pm.popup_hide.connect(pm.queue_free)
	var r := anchor.get_global_rect()
	pm.popup(Rect2i(Vector2i(r.position + Vector2(0, r.size.y)), Vector2i.ZERO))


func _add_templates() -> void:
	var dir := DirAccess.open("res://data/samples")
	if dir == null:
		return
	var files := Array(dir.get_files()).filter(func(f): return f.ends_with(LayoutIO.FILE_EXT))
	if files.is_empty():
		return
	files.sort()
	modal.body.add_child(UI.section("Inspiration templates (original sample designs)"))
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 8)
	for f: String in files:
		var data: Variant = JsonUtil.read_json("res://data/samples".path_join(f))
		var nm := str(data.get("meta", {}).get("name", f)) if data is Dictionary else f
		var desc := str(data.get("meta", {}).get("description", "")) if data is Dictionary else ""
		var b := UI.button(nm, "sparkles", desc)
		b.pressed.connect(func():
			modal.close()
			open_template.emit("res://data/samples".path_join(f), nm))
		row.add_child(b)
	modal.body.add_child(row)


func _import() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.filters = PackedStringArray(["*.hdlayout, *.json ; Layout files"])
	fd.file_selected.connect(func(p):
		modal.close()
		import_file.emit(p))
	_parent.add_child(fd)
	fd.popup_centered_ratio(0.6)
