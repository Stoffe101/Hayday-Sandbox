class_name PackInstaller
extends RefCounted
## Installs an asset pack from a .zip into user://asset_packs/<pack id>/.
##
##   * pack.json must be at the zip root or exactly one folder deep;
##   * it must be a valid "hayday-sandbox-asset-pack" with a sprites object;
##   * entries that could escape the pack folder (absolute, "..") are skipped;
##   * extraction goes to a hidden temp folder which is then renamed into place,
##     so a failed/interrupted install never leaves a half-written pack, and an
##     existing pack is only replaced once the new one is complete;
##   * the user's overrides.json (anchor/scale fine-tuning, review decisions) is
##     carried over to the new version unless the zip ships its own.
## No App/UI dependencies (usable from the command line and from tests).

const TMP_PREFIX := ".installing_"
const OLD_PREFIX := ".replaced_"


class Result:
	var ok := false
	var error := ""
	var pack_id := ""
	var pack_name := ""
	var version := ""
	var dir := ""
	var files := 0
	var bytes := 0
	var sprites := 0
	var replaced := false
	var kept_overrides := false
	var skipped: Array = []

	func summary() -> String:
		if not ok:
			return "FAILED: %s" % error
		return "installed “%s” (%s%s) — %d files, %.1f MB, %d sprites%s%s%s" % [pack_name if not pack_name.is_empty() else pack_id,
			pack_id, (" v" + version) if not version.is_empty() else "", files, bytes / 1048576.0, sprites,
			" · replaced the previous version" if replaced else "", " · kept your overrides" if kept_overrides else "",
			(" · skipped %d unsafe entries" % skipped.size()) if not skipped.is_empty() else ""]


static func find_pack_json(files: PackedStringArray) -> String:
	## "pack.json" at the root wins; otherwise exactly one "<folder>/pack.json".
	var deep: Array = []
	for f in files:
		var n := f.replace("\\", "/")
		if n == "pack.json" or n == "./pack.json":
			return f
		var parts := n.split("/", false)
		if parts.size() == 2 and parts[1] == "pack.json" and not parts[0].begins_with("__MACOSX") and not parts[0].begins_with("."):
			deep.append(f)
	return deep[0] if deep.size() == 1 else ""


static func sanitize_id(id: String) -> String:
	var out := ""
	for ch in id.strip_edges():
		var ok := (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch in ["_", "-", "."]
		out += ch if ok else "_"
	while out.begins_with(".") or out.begins_with("_"):
		out = out.substr(1)
	return out.left(64)


static func validate_pack(data: Variant) -> String:
	## "" when the pack.json content is usable, else a human-readable reason.
	if not data is Dictionary:
		return "pack.json is not valid JSON"
	if str(data.get("format", "")) != AssetLibrary.PACK_FORMAT:
		return "pack.json has format “%s”, expected “%s”" % [str(data.get("format", "")), AssetLibrary.PACK_FORMAT]
	if not data.get("sprites") is Dictionary:
		return "pack.json has no sprites object"
	return ""


static func install_zip(zip_path: String, root: String = AssetLibrary.USER_PACKS) -> Result:
	var r := Result.new()
	var src := zip_path.strip_edges()
	if not FileAccess.file_exists(src):
		r.error = "file not found: %s" % src
		return r
	var zr := ZIPReader.new()
	var err := zr.open(src)
	if err != OK:
		r.error = "not a readable .zip (%s)" % error_string(err)
		return r
	var files := zr.get_files()
	var pj := find_pack_json(files)
	if pj.is_empty():
		zr.close()
		r.error = "no pack.json at the top of the zip or one folder deep"
		return r
	var data: Variant = JSON.parse_string(zr.read_file(pj).get_string_from_utf8())
	var why := validate_pack(data)
	if not why.is_empty():
		zr.close()
		r.error = why
		return r
	var prefix := pj.replace("\\", "/").trim_prefix("./").get_base_dir()
	if not prefix.is_empty():
		prefix += "/"
	var pid := sanitize_id(str(data.get("id", "")))
	if pid.is_empty():
		pid = sanitize_id(prefix.trim_suffix("/") if not prefix.is_empty() else src.get_file().get_basename())
	if pid.is_empty() or pid == AssetLibrary.BUILTIN_ID:
		zr.close()
		r.error = "pack id “%s” is missing or reserved" % str(data.get("id", ""))
		return r
	r.pack_id = pid
	r.pack_name = str(data.get("name", pid))
	r.version = str(data.get("version", ""))
	r.sprites = (data["sprites"] as Dictionary).size()
	var root_abs := _abs(root)
	DirAccess.make_dir_recursive_absolute(root_abs)
	_clean_stale(root_abs)
	var stamp := "%s_%d" % [pid, Time.get_ticks_usec()]
	var tmp := root_abs.path_join(TMP_PREFIX + stamp)
	if DirAccess.make_dir_recursive_absolute(tmp) != OK:
		zr.close()
		r.error = "cannot create %s" % tmp
		return r
	for f in files:
		var n := f.replace("\\", "/").trim_prefix("./")
		if n.ends_with("/"):
			continue
		if not prefix.is_empty():
			if not n.begins_with(prefix):
				continue   # outside the pack folder
			n = n.substr(prefix.length())
		if n.begins_with("__MACOSX/") or n.get_file() == ".DS_Store" or n.get_file() == "Thumbs.db":
			continue
		var rel := PackOverrides.safe_rel_path(n)
		if rel.is_empty():
			r.skipped.append(f)
			continue
		var bytes := zr.read_file(f)
		var dst := tmp.path_join(rel)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var fa := FileAccess.open(dst, FileAccess.WRITE)
		if fa == null:
			zr.close()
			remove_recursive(tmp)
			r.error = "cannot write %s (%s)" % [rel, error_string(FileAccess.get_open_error())]
			return r
		fa.store_buffer(bytes)
		fa.close()
		r.files += 1
		r.bytes += bytes.size()
	zr.close()
	# The pack.json we validated must have landed (e.g. a pack.json name clash).
	if not FileAccess.file_exists(tmp.path_join("pack.json")):
		remove_recursive(tmp)
		r.error = "pack.json could not be extracted"
		return r
	var target := root_abs.path_join(pid)
	var old := ""
	if DirAccess.dir_exists_absolute(target):
		var ov_old := target.path_join(AssetLibrary.OVERRIDES_FILE)
		var ov_new := tmp.path_join(AssetLibrary.OVERRIDES_FILE)
		if FileAccess.file_exists(ov_old) and not FileAccess.file_exists(ov_new):
			r.kept_overrides = DirAccess.copy_absolute(ov_old, ov_new) == OK
		old = root_abs.path_join(OLD_PREFIX + stamp)
		if DirAccess.rename_absolute(target, old) != OK:
			remove_recursive(tmp)
			r.error = "the existing pack folder is in use and could not be replaced"
			return r
		r.replaced = true
	if DirAccess.rename_absolute(tmp, target) != OK:
		if not old.is_empty():
			DirAccess.rename_absolute(old, target)   # roll back
		remove_recursive(tmp)
		r.error = "could not move the extracted pack into place"
		r.replaced = false
		return r
	if not old.is_empty():
		remove_recursive(old)
	r.dir = target
	r.ok = true
	return r


static func uninstall(pack_id: String, root: String = AssetLibrary.USER_PACKS) -> Error:
	var pid := sanitize_id(pack_id)
	if pid.is_empty() or pid == AssetLibrary.BUILTIN_ID:
		return ERR_INVALID_PARAMETER
	var target := _abs(root).path_join(pid)
	if not DirAccess.dir_exists_absolute(target):
		return ERR_DOES_NOT_EXIST
	return remove_recursive(target)


static func remove_recursive(path: String) -> Error:
	var d := DirAccess.open(path)
	if d == null:
		return ERR_DOES_NOT_EXIST
	d.include_hidden = true
	for sub in d.get_directories():
		remove_recursive(path.path_join(sub))
	for f in d.get_files():
		d.remove(f)
	return DirAccess.remove_absolute(path)


static func _clean_stale(root_abs: String) -> void:
	## Leftovers of an interrupted install (never loaded: hidden names).
	var d := DirAccess.open(root_abs)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		if sub.begins_with(TMP_PREFIX):
			remove_recursive(root_abs.path_join(sub))
		elif sub.begins_with(OLD_PREFIX):
			# Interrupted between "move old aside" and "move new in": restore
			# the previous version instead of losing it.
			var pid := sub.substr(OLD_PREFIX.length()).rsplit("_", true, 1)[0]
			var target := root_abs.path_join(pid)
			if not pid.is_empty() and not DirAccess.dir_exists_absolute(target):
				DirAccess.rename_absolute(root_abs.path_join(sub), target)
			else:
				remove_recursive(root_abs.path_join(sub))


static func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p) if (p.begins_with("user://") or p.begins_with("res://")) else p
