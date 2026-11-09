class_name StampsPanel
extends PanelContainer
## Floating panel listing reusable groups: save the selection, place, export,
## import, delete. The logic lives in LayoutToolController and StampLibrary.

var tools: LayoutToolController
var modal_parent: Control

var _list: ItemList
var _ids: Array = []
var _empty: Label


func _ready() -> void:
	theme_type_variation = "FloatingPanel"
	var v := UI.vbox(8)
	add_child(v)
	var head := UI.hbox(6)
	head.add_child(UI.label("Stamps", "Heading"))
	head.add_child(UI.spacer())
	var close := UI.icon_button("x", "Close")
	close.pressed.connect(func():
		visible = false
		tools.dock.set_stamps_open(false))
	head.add_child(close)
	v.add_child(head)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.max_columns = 0
	_list.fixed_icon_size = Vector2i(64, 64)
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.same_column_width = true
	_list.fixed_column_width = 96
	_list.focus_mode = Control.FOCUS_NONE
	_list.item_activated.connect(func(_i: int): place_selected())
	v.add_child(_list)
	_empty = UI.label("Select some objects and press Save selection to keep them as a reusable group.", "Dim", true)
	v.add_child(_empty)
	var row := UI.hbox(6)
	var save := UI.button("Save selection", "save", "Save the selected objects as a stamp")
	save.pressed.connect(ask_save)
	row.add_child(save)
	var place := UI.button("Place", "paintbrush", "Place the chosen stamp (double-click also works)")
	place.pressed.connect(place_selected)
	row.add_child(place)
	row.add_child(UI.spacer())
	var imp := UI.icon_button("upload", "Import a .hdstamp file")
	imp.pressed.connect(_ask_import)
	row.add_child(imp)
	var exp := UI.icon_button("download", "Export the chosen stamp to a .hdstamp file")
	exp.pressed.connect(_ask_export)
	row.add_child(exp)
	var del := UI.icon_button("trash", "Delete the chosen stamp")
	del.pressed.connect(_ask_delete)
	row.add_child(del)
	v.add_child(row)


func refresh() -> void:
	if _list == null:
		return
	_list.clear()
	_ids.clear()
	for st: Dictionary in tools.stamps.list():
		var tex := _thumb(st)
		_list.add_item(str(st["name"]), tex)
		_list.set_item_tooltip(_list.item_count - 1, "%s · %d objects · %d×%d tiles" % [st["name"], (st["items"] as Array).size(), st["size"][0], st["size"][1]])
		_ids.append(str(st["id"]))
	_empty.visible = _ids.is_empty()
	_list.visible = not _ids.is_empty()


func _thumb(st: Dictionary) -> Texture2D:
	var path := tools.stamps.thumb_path(str(st["id"]))
	var img := Image.load_from_file(ProjectSettings.globalize_path(path)) if FileAccess.file_exists(path) else null
	if img == null or img.is_empty():
		img = StampLibrary.thumbnail_image(st, tools.session.db)
	return ImageTexture.create_from_image(img)


func selected_id() -> String:
	var sel := _list.get_selected_items()
	return _ids[sel[0]] if not sel.is_empty() and sel[0] < _ids.size() else ""


func place_selected() -> void:
	var id := selected_id()
	if id.is_empty():
		tools.session.message.emit("Choose a stamp first", "info")
		return
	tools.begin_stamp(tools.stamps.get_stamp(id))


func ask_save() -> void:
	if tools.session.selection.is_empty():
		tools.session.message.emit("Select some objects to save as a stamp", "info")
		return
	Modal.prompt(modal_parent, "Save as stamp", "Stamp %d" % (_ids.size() + 1), func(t: String):
		if not t.strip_edges().is_empty():
			tools.save_selection_stamp(t))


func _ask_delete() -> void:
	var id := selected_id()
	if id.is_empty():
		return
	Modal.confirm(modal_parent, "Delete stamp", "Delete this stamp? This can't be undone.", "Delete", true, func():
		tools.stamps.delete(id)
		refresh())


func _file_dialog(mode: FileDialog.FileMode, title: String) -> FileDialog:
	var fd := FileDialog.new()
	fd.file_mode = mode
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.title = title
	fd.filters = PackedStringArray(["*.%s ; Hayday Sandbox stamp" % StampLibrary.EXT])
	add_child(fd)
	fd.popup_centered_ratio(0.7)
	fd.close_requested.connect(fd.queue_free)
	fd.canceled.connect(fd.queue_free)
	return fd


func _ask_export() -> void:
	var id := selected_id()
	if id.is_empty():
		tools.session.message.emit("Choose a stamp first", "info")
		return
	var fd := _file_dialog(FileDialog.FILE_MODE_SAVE_FILE, "Export stamp")
	fd.file_selected.connect(func(path: String):
		fd.queue_free()
		var err := tools.stamps.export_file(id, path)
		if err == OK:
			tools.session.message.emit("Exported the stamp", "success")
		else:
			tools.session.message.emit("Export failed (%s)" % error_string(err), "error"))


func _ask_import() -> void:
	var fd := _file_dialog(FileDialog.FILE_MODE_OPEN_FILE, "Import stamp")
	fd.file_selected.connect(func(path: String):
		fd.queue_free()
		import_path(path))


func import_path(path: String) -> Dictionary:
	var s := tools.session
	var r := tools.stamps.import_file(path, s.stamp_refusal, s.db)
	if (r["stamp"] as Dictionary).is_empty():
		s.message.emit("Import failed: %s" % str(r["error"]), "error")
		return r
	if int(r["dropped"]) > 0:
		s.message.emit("Imported “%s”, %d item%s left out" % [r["stamp"]["name"], r["dropped"], "" if int(r["dropped"]) == 1 else "s"], "info")
	else:
		s.message.emit("Imported “%s”" % r["stamp"]["name"], "success")
	refresh()
	return r
