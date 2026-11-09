class_name AssetImporter
extends RefCounted
## Imports user-provided artwork into a private asset pack.
##
## Input: a folder containing PNG / WebP / JPG images, optionally:
##   * manifest.json  {"sprites": {"<file>": {"item": id, "anchor": [x,y], "scale": s,
##                     "variant": v, "mask": n, "shadow": bool}}}
##   * manifest.csv   file,item[,anchor_x,anchor_y,scale,variant,mask]
##   * <sheet>.json next to <sheet>.png in TexturePacker "hash" or "array"
##     format: frames are cut out and imported as individual sprites.
## Without a manifest, files are matched to items by normalised name/id
## (e.g. "Feed Mill.png", "feed_mill.webp"); "__mNN" suffix = connection
## shape NN, "_shadow" suffix = shadow image.
##
## Output (default root user://asset_packs/<pack>/): pack.json, items/*.png,
## import_report.json. Nothing is ever written into the project folder.

const IMAGE_EXT := ["png", "webp", "jpg", "jpeg"]


class Report:
	var pack_dir := ""
	var images := 0
	var matched: Dictionary = {}      ## item id -> file
	var unmatched: Array = []         ## files with no item
	var duplicates: Array = []        ## [file, same_as]
	var no_alpha: Array = []          ## opaque images (probably screenshots / need cut-out)
	var errors: Array = []
	var trimmed_px := 0
	var atlas_frames := 0

	func to_dict() -> Dictionary:
		return {"pack_dir": pack_dir, "images": images, "matched": matched.size(), "unmatched": unmatched,
			"duplicates": duplicates, "opaque_images": no_alpha, "errors": errors, "atlas_frames": atlas_frames,
			"trimmed_pixels": trimmed_px}

	func summary() -> String:
		return "%d images · %d matched to items · %d unmatched · %d duplicates%s" % [images, matched.size(),
			unmatched.size(), duplicates.size(), (" · %d errors" % errors.size()) if not errors.is_empty() else ""]


static func normalize(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


static func build_name_index(db: ItemDatabase) -> Dictionary:
	var idx := {}
	for it: ItemDef in db.ordered:
		idx[normalize(it.id)] = it.id
		idx[normalize(it.name)] = it.id
		for a in it.aliases:
			idx[normalize(a)] = it.id
	return idx


static func run(src_dir: String, pack_id: String, db: ItemDatabase, license_note: String = "user-provided (private use)",
		root: String = "user://asset_packs") -> Report:
	var rep := Report.new()
	var pack_dir := root.path_join(pack_id.validate_filename())
	rep.pack_dir = pack_dir
	DirAccess.make_dir_recursive_absolute(pack_dir.path_join("items"))
	var manifest := _read_manifest(src_dir)
	var name_index := build_name_index(db)
	var sprites := {}
	var hashes := {}
	var files := _collect(src_dir)
	# Expand atlases into frames first.
	var frames: Array = []   # [label, Image]
	for f: String in files.duplicate():
		var sheet_json := f.get_basename() + ".json"
		if FileAccess.file_exists(sheet_json) and not manifest.has(f.get_file()):
			var got := _atlas_frames(f, sheet_json)
			if not got.is_empty():
				frames.append_array(got)
				files.erase(f)
				rep.atlas_frames += got.size()
	for f: String in files:
		var img := Image.load_from_file(f)
		if img == null or img.is_empty():
			rep.errors.append("Unreadable image: %s" % f.get_file())
			continue
		frames.append([f.get_file(), img, _hash_file(f)])
	for fr in frames:
		var label: String = fr[0]
		var img: Image = fr[1]
		rep.images += 1
		var h: String = fr[2] if fr.size() > 2 else _hash_image(img)
		if hashes.has(h):
			rep.duplicates.append([label, hashes[h]])
			continue
		hashes[h] = label
		var spec: Dictionary = manifest.get(label, {})
		var base := label.get_basename()
		var mask := -1
		var is_shadow := bool(spec.get("shadow", false))
		var m := RegEx.create_from_string("__m(\\d{1,2})$").search(base)
		if m:
			mask = int(m.get_string(1))
			base = base.substr(0, m.get_start())
		if base.to_lower().ends_with("_shadow"):
			is_shadow = true
			base = base.left(base.length() - 7)
		if spec.has("mask"):
			mask = int(spec["mask"])
		var item_id := str(spec.get("item", name_index.get(normalize(base), "")))
		var it := db.get_item(item_id)
		if it == null:
			rep.unmatched.append(label)
			continue
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		if not _has_transparency(img):
			rep.no_alpha.append(label)
		# Trim transparent padding (never affects placement: anchors are
		# re-expressed relative to the trimmed image).
		var used := img.get_used_rect()
		var trim_off := Vector2.ZERO
		if used.size.x > 0 and used.size != img.get_size():
			rep.trimmed_px += img.get_width() * img.get_height() - used.size.x * used.size.y
			img = img.get_region(used)
			trim_off = Vector2(used.position)
		var variant := str(spec.get("variant", ""))
		var out_name := "%s%s%s%s.png" % [it.id, ("__" + variant) if not variant.is_empty() else "",
			("__m%02d" % mask) if mask >= 0 else "", ".shadow" if is_shadow else ""]
		if img.save_png(pack_dir.path_join("items").path_join(out_name)) != OK:
			rep.errors.append("Could not write %s" % out_name)
			continue
		var entry := {"file": "items/" + out_name}
		var fp := it.footprint
		if spec.has("anchor"):
			var a: Array = spec["anchor"]
			entry["anchor"] = [float(a[0]) - trim_off.x, float(a[1]) - trim_off.y]
		else:
			# Estimate: footprint diamond spans the image width; ground centre
			# sits half a diamond above the lowest opaque pixel.
			var ppw := img.get_width() / ((fp.x + fp.y) * Iso.HALF_W)
			entry["anchor"] = [img.get_width() * 0.5, img.get_height() - (fp.x + fp.y) * Iso.HALF_H * 0.5 * ppw]
			entry["pixels_per_world_px"] = ppw
			entry["auto_anchor"] = true
		if spec.has("scale"):
			entry["scale"] = float(spec["scale"])
		_store(sprites, it.art_key, variant, mask, is_shadow, entry)
		rep.matched[it.id] = label
	var pack := {"format": AssetLibrary.PACK_FORMAT, "schema_version": 1, "id": pack_id, "name": pack_id,
		"license": license_note, "priority": 10, "pixels_per_world_px": 1.0, "sprites": sprites,
		"imported": Time.get_datetime_string_from_system(true) + "Z", "source_folder": src_dir}
	JsonUtil.write_atomic(pack_dir.path_join("pack.json"), JsonUtil.stringify(pack, true))
	JsonUtil.write_atomic(pack_dir.path_join("import_report.json"), JsonUtil.stringify(rep.to_dict(), true))
	return rep


static func _store(sprites: Dictionary, key: String, variant: String, mask: int, is_shadow: bool, entry: Dictionary) -> void:
	if not sprites.has(key):
		sprites[key] = {}
	var target: Dictionary = sprites[key]
	if not variant.is_empty():
		if not target.has("variants"):
			target["variants"] = {}
		if not target["variants"].has(variant):
			target["variants"][variant] = {}
		target = target["variants"][variant]
	if mask >= 0:
		if not target.has("connections"):
			target["connections"] = {}
		if not target["connections"].has(str(mask)):
			target["connections"][str(mask)] = {}
		target = target["connections"][str(mask)]
	if is_shadow:
		target["shadow"] = {"file": entry["file"], "anchor": entry["anchor"]}
	else:
		for k in entry:
			target[k] = entry[k]


static func _collect(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.get_extension().to_lower() in IMAGE_EXT:
			out.append(dir_path.path_join(f))
	for d in dir.get_directories():
		if not d.begins_with("."):
			out.append_array(_collect(dir_path.path_join(d)))
	out.sort()
	return out


static func _read_manifest(dir_path: String) -> Dictionary:
	var out := {}
	var j: Variant = JsonUtil.read_json(dir_path.path_join("manifest.json"))
	if j is Dictionary and j.get("sprites") is Dictionary:
		for k in j["sprites"]:
			out[str(k)] = j["sprites"][k]
	var csv_path := dir_path.path_join("manifest.csv")
	if FileAccess.file_exists(csv_path):
		var f := FileAccess.open(csv_path, FileAccess.READ)
		var header := f.get_csv_line()
		while not f.eof_reached():
			var row := f.get_csv_line()
			if row.size() < 2 or row[0].strip_edges().is_empty():
				continue
			var spec := {"item": row[1].strip_edges()}
			for i in range(2, mini(row.size(), header.size())):
				var key := header[i].strip_edges()
				var val := row[i].strip_edges()
				if val.is_empty():
					continue
				match key:
					"anchor_x": spec["anchor"] = [float(val), spec.get("anchor", [0, 0])[1]]
					"anchor_y": spec["anchor"] = [spec.get("anchor", [0, 0])[0], float(val)]
					"scale": spec["scale"] = float(val)
					"variant": spec["variant"] = val
					"mask": spec["mask"] = int(val)
					"shadow": spec["shadow"] = val.to_lower() in ["1", "true", "yes"]
			out[row[0].strip_edges()] = spec
	return out


static func _atlas_frames(png_path: String, json_path: String) -> Array:
	var data: Variant = JsonUtil.read_json(json_path)
	if not data is Dictionary or not data.has("frames"):
		return []
	var sheet := Image.load_from_file(png_path)
	if sheet == null:
		return []
	sheet.convert(Image.FORMAT_RGBA8)
	var out: Array = []
	var frames: Variant = data["frames"]
	var list: Array = []
	if frames is Dictionary:
		for k in frames:
			var e: Dictionary = frames[k].duplicate()
			e["filename"] = k
			list.append(e)
	elif frames is Array:
		list = frames
	for e in list:
		var fr: Dictionary = e.get("frame", {})
		var r := Rect2i(int(fr.get("x", 0)), int(fr.get("y", 0)), int(fr.get("w", 0)), int(fr.get("h", 0)))
		var rotated := bool(e.get("rotated", false))
		if rotated:
			r.size = Vector2i(r.size.y, r.size.x)
		if r.size.x <= 0 or r.size.y <= 0:
			continue
		var img := sheet.get_region(r)
		if rotated:
			img.rotate_90(COUNTERCLOCKWISE)
		# Restore trimmed frames to their source size so anchors stay valid.
		if bool(e.get("trimmed", false)) and e.has("sourceSize") and e.has("spriteSourceSize"):
			var ss: Dictionary = e["sourceSize"]
			var sss: Dictionary = e["spriteSourceSize"]
			var full := Image.create(int(ss["w"]), int(ss["h"]), false, Image.FORMAT_RGBA8)
			full.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(int(sss["x"]), int(sss["y"])))
			img = full
		var name := str(e.get("filename", "frame_%d" % out.size()))
		if name.get_extension().is_empty():
			name += ".png"
		out.append([name.get_file(), img])
	return out


static func _has_transparency(img: Image) -> bool:
	if not img.detect_alpha():
		return false
	return img.detect_alpha() != Image.ALPHA_NONE


static func _hash_file(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return path
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(65536))
	return ctx.finish().hex_encode()


static func _hash_image(img: Image) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(img.get_data())
	return ctx.finish().hex_encode()
