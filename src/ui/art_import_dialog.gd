class_name ArtImportDialog
extends RefCounted
## In-app artwork import: pick a folder, confirm usage rights, import into a
## private pack under the user data folder, show the report, reload art.


func show(parent: Control) -> void:
	var m := Modal.open(parent, "Import artwork", 600, "upload")
	m.body.add_child(UI.label("Use your own images for catalogue items. Files are matched by name (e.g. “Feed Mill.png” or “feed_mill.webp”), or by a manifest.json / manifest.csv in the folder. TexturePacker-style sprite sheets (sheet.png + sheet.json) are cut into frames automatically.", "Dim", true))
	var row := UI.hbox(8)
	var path := LineEdit.new()
	path.placeholder_text = "Folder with images…"
	path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(path)
	var browse := UI.button("Browse…", "folder-open")
	browse.pressed.connect(func():
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.use_native_dialog = true
		fd.dir_selected.connect(func(d): path.text = d)
		parent.add_child(fd)
		fd.popup_centered_ratio(0.6))
	row.add_child(browse)
	m.body.add_child(row)
	var name := LineEdit.new()
	name.placeholder_text = "Pack name"
	name.text = "my_art"
	m.body.add_child(name)
	var rights := CheckBox.new()
	rights.text = "I have the right to use these images for my own private planning."
	m.body.add_child(rights)
	m.body.add_child(UI.label("Imported art stays in your private data folder and is never added to the project or shared. Images taken from games may be protected by copyright; see docs/research/LEGAL_AND_LICENSING.md.", "Faint", true))
	var result := UI.label("", "Dim", true)
	m.body.add_child(result)
	m.add_button("Close", "", m.close)
	var go := m.add_button("Import", "Accent", Callable(), "upload")
	go.pressed.connect(func():
		if not rights.button_pressed:
			result.text = "Please confirm you may use these images."
			return
		if path.text.strip_edges().is_empty() or not DirAccess.dir_exists_absolute(path.text):
			result.text = "Choose an existing folder."
			return
		var rep := AssetImporter.run(path.text.strip_edges(), name.text.strip_edges().validate_filename(), App.db)
		result.text = rep.summary()
		if not rep.unmatched.is_empty():
			result.text += "\nUnmatched: " + ", ".join(PackedStringArray(rep.unmatched.slice(0, 8))) + ("…" if rep.unmatched.size() > 8 else "")
		if not rep.no_alpha.is_empty():
			result.text += "\n%d image(s) have no transparency — they will cover the ground." % rep.no_alpha.size()
		App.reload_assets()
		App.toast("Imported art: %s" % rep.summary(), "success" if rep.errors.is_empty() else "warn"))
