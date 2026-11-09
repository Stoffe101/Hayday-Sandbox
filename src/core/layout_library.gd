class_name LayoutLibrary
extends RefCounted
## The user's collection of farm layouts on disk.
##
##   <root>/layouts/<id>.hdlayout        current version (atomic writes + .bak)
##   <root>/layouts/<id>.png             gallery thumbnail
##   <root>/history/<id>/<stamp>.hdlayout  snapshots taken on every manual save
##   <root>/autosave/<id>.hdlayout       crash-recovery copy
##   <root>/trash/                       deleted layouts (recoverable)
##   <root>/layouts/<id>.hdlayout.v1-backup  original bytes of a pre-v2 layout,
##                                       kept on its first save in the new format
##
## Every load/import goes through LayoutIO.from_dict (schema migration, landmark
## items taken out, footprint reconciliation, collision report).

const MAX_HISTORY := 30

var root: String
var db: ItemDatabase
## World the layouts are shown on (App keeps it current). Optional: lets loads
## name replaced landmarks and report collisions with the world.
var map: FarmMap = null


func _init(item_db: ItemDatabase, root_dir: String = "user://") -> void:
	db = item_db
	root = root_dir
	for d in ["layouts", "history", "autosave", "trash"]:
		DirAccess.make_dir_recursive_absolute(root.path_join(d))


func layouts_dir() -> String:
	return root.path_join("layouts")


func path_for(id: String) -> String:
	return layouts_dir().path_join(id + LayoutIO.FILE_EXT)


func thumb_for(id: String) -> String:
	return layouts_dir().path_join(id + ".png")


static func new_id() -> String:
	var t := Time.get_unix_time_from_system()
	return "L%d_%04x" % [int(t), randi() % 0xffff]


func list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(layouts_dir())
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(LayoutIO.FILE_EXT):
			continue
		var id := f.trim_suffix(LayoutIO.FILE_EXT)
		var path := layouts_dir().path_join(f)
		var data: Variant = JsonUtil.read_json(path)
		if not data is Dictionary:
			var rec := JsonUtil.recover(path)
			data = JsonUtil.read_json(rec) if not rec.is_empty() else null
		if not data is Dictionary:
			out.append({"id": id, "name": id + " (unreadable)", "path": path, "modified": "", "objects": 0, "broken": true})
			continue
		var meta: Dictionary = data.get("meta", {})
		out.append({
			"id": id, "name": str(meta.get("name", id)), "path": path,
			"modified": str(meta.get("modified", "")), "created": str(meta.get("created", "")),
			"mode": str(meta.get("mode", "creative")), "description": str(meta.get("description", "")),
			"objects": (data.get("objects", []) as Array).size(),
			"plots": (data.get("map", {}).get("unlocked_plots", []) as Array).size(),
			"thumb": thumb_for(id) if FileAccess.file_exists(thumb_for(id)) else "",
			"tags": meta.get("tags", []),
		})
	out.sort_custom(func(a, b): return str(a["modified"]) > str(b["modified"]))
	return out


func exists(id: String) -> bool:
	return FileAccess.file_exists(path_for(id))


func save(l: FarmLayout, snapshot: bool = true) -> Error:
	if l.id.is_empty():
		l.id = new_id()
	if l.created.is_empty():
		l.created = Time.get_datetime_string_from_system(true) + "Z"
	l.touch()
	var err := LayoutIO.save_file(l, path_for(l.id))
	if err == OK:
		if snapshot:
			_snapshot(l)
		# A successful manual save supersedes the crash-recovery copy.
		var auto := autosave_path(l.id)
		if FileAccess.file_exists(auto):
			DirAccess.remove_absolute(auto)
	return err


func _snapshot(l: FarmLayout) -> void:
	var dir := root.path_join("history").path_join(l.id)
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	LayoutIO.save_file(l, dir.path_join(stamp + LayoutIO.FILE_EXT))
	var snaps := history(l.id)
	while snaps.size() > MAX_HISTORY:
		var old: Dictionary = snaps.pop_back()
		DirAccess.remove_absolute(old["path"])
		if FileAccess.file_exists(old["path"] + ".bak"):
			DirAccess.remove_absolute(old["path"] + ".bak")


func history(id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir_path := root.path_join("history").path_join(id)
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(LayoutIO.FILE_EXT):
			out.append({"stamp": f.trim_suffix(LayoutIO.FILE_EXT), "path": dir_path.path_join(f)})
	out.sort_custom(func(a, b): return a["stamp"] > b["stamp"])
	return out


func load_layout(id: String, report: LayoutIO.LoadReport) -> FarmLayout:
	var l := LayoutIO.load_file(path_for(id), db, report, map)
	if l and l.id.is_empty():
		l.id = id
	if l and report.migrated_from >= 0 and report.recovered_from.is_empty():
		# Saving writes over this file: its pre-v2 original is kept next to it.
		report.backup_path = LayoutIO.backup_path_for(path_for(id), report.migrated_from)
	return l


func load_path(path: String, report: LayoutIO.LoadReport) -> FarmLayout:
	## Opens any layout file (template, sample, external file). The file itself
	## is never written: saving goes to the library.
	return LayoutIO.load_file(path, db, report, map)


func duplicate_layout(id: String, new_name: String = "") -> String:
	var rep := LayoutIO.LoadReport.new()
	var l := load_layout(id, rep)
	if l == null:
		return ""
	l.id = new_id()
	l.name = new_name if not new_name.is_empty() else l.name + " (copy)"
	l.created = ""
	if save(l, false) != OK:
		return ""
	if FileAccess.file_exists(thumb_for(id)):
		DirAccess.copy_absolute(thumb_for(id), thumb_for(l.id))
	return l.id


func rename(id: String, new_name: String) -> Error:
	var rep := LayoutIO.LoadReport.new()
	var l := load_layout(id, rep)
	if l == null:
		return ERR_FILE_CORRUPT
	l.name = new_name
	return save(l, false)


func delete(id: String) -> Error:
	## Moves the layout to trash (recoverable), never hard-deletes.
	var trash := root.path_join("trash")
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	var dst := trash.path_join("%s__%s%s" % [id, stamp, LayoutIO.FILE_EXT])
	var err := DirAccess.rename_absolute(path_for(id), dst)
	if err != OK:
		return err
	for extra in [path_for(id) + ".bak", thumb_for(id), autosave_path(id)]:
		if FileAccess.file_exists(extra):
			DirAccess.remove_absolute(extra)
	for v in range(LayoutIO.SCHEMA_VERSION):
		var bk := LayoutIO.backup_path_for(path_for(id), v)
		if FileAccess.file_exists(bk):
			DirAccess.rename_absolute(bk, LayoutIO.backup_path_for(dst, v))
	return OK


func autosave_path(id: String) -> String:
	return root.path_join("autosave").path_join(id + LayoutIO.FILE_EXT)


func autosave(l: FarmLayout) -> Error:
	if l.id.is_empty():
		l.id = new_id()
	return JsonUtil.write_atomic(autosave_path(l.id), JsonUtil.stringify(LayoutIO.to_dict(l), false), false)


func pending_recovery() -> Array[Dictionary]:
	## Autosaves newer than their saved layout (i.e. unsaved work after a crash).
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(root.path_join("autosave"))
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(LayoutIO.FILE_EXT):
			continue
		var id := f.trim_suffix(LayoutIO.FILE_EXT)
		var auto: Variant = JsonUtil.read_json(root.path_join("autosave").path_join(f))
		if not auto is Dictionary:
			continue
		var am := str(auto.get("meta", {}).get("modified", ""))
		var saved: Variant = JsonUtil.read_json(path_for(id))
		var sm := str(saved.get("meta", {}).get("modified", "")) if saved is Dictionary else ""
		if am > sm:
			out.append({"id": id, "name": str(auto.get("meta", {}).get("name", id)), "modified": am,
				"path": root.path_join("autosave").path_join(f)})
	return out


func discard_autosave(id: String) -> void:
	if FileAccess.file_exists(autosave_path(id)):
		DirAccess.remove_absolute(autosave_path(id))


func import_file(src_path: String, report: LayoutIO.LoadReport) -> String:
	## Copies an external layout into the library (migrated, landmark items
	## taken out). The source file is never modified.
	var l := LayoutIO.load_file(src_path, db, report, map)
	if l == null:
		return ""
	l.id = new_id()
	if save(l, false) != OK:
		return ""
	return l.id


func export_file(id: String, dst_path: String) -> Error:
	var text := JsonUtil.read_text(path_for(id))
	if text.is_empty():
		return ERR_FILE_NOT_FOUND
	var f := FileAccess.open(dst_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	return OK
