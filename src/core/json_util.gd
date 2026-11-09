class_name JsonUtil
extends RefCounted
## Small JSON + filesystem helpers, including crash-safe atomic writes.


static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


static func read_json(path: String) -> Variant:
	## Returns parsed data, or null when the file is missing or malformed.
	if not FileAccess.file_exists(path):
		return null
	var text := read_text(path)
	if text.is_empty():
		return null
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("JSON parse error in %s line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


static func parse(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func write_atomic(path: String, text: String, keep_backup: bool = true) -> Error:
	## Crash-safe write: write to `path.tmp`, verify it reads back identically,
	## move the previous file to `path.bak`, then rename the temp file into
	## place. A crash at any point leaves either the old file, the .bak, or a
	## complete .tmp that recover() can pick up.
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var mk := DirAccess.make_dir_recursive_absolute(dir_path)
		if mk != OK:
			return mk
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr != OK:
		return werr
	# Verify the bytes actually landed.
	if read_text(tmp) != text:
		return ERR_FILE_CORRUPT
	if FileAccess.file_exists(path):
		var bak := path + ".bak"
		if keep_backup:
			if FileAccess.file_exists(bak):
				DirAccess.remove_absolute(bak)
			var rerr := DirAccess.rename_absolute(path, bak)
			if rerr != OK:
				return rerr
		else:
			DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp, path)


static func recover(path: String) -> String:
	## If `path` is missing or unreadable, returns the best intact sibling
	## (.tmp written completely, then .bak). Returns "" when nothing usable.
	for candidate in [path, path + ".tmp", path + ".bak"]:
		if FileAccess.file_exists(candidate) and parse(read_text(candidate)) != null:
			return candidate
	return ""


static func stringify(data: Variant, pretty: bool = true) -> String:
	return JSON.stringify(data, "\t" if pretty else "", false)
