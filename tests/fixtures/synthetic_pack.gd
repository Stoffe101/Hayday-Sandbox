extends RefCounted
## Builds a synthetic asset-pack .zip at runtime from the built-in CC0
## placeholder PNGs (recoloured and upscaled so it is visibly "different art"),
## for the self-test and the visual tests. It exercises every pack feature —
## higher resolution (3 px per world px), exact and auto-estimated anchors, a
## variant, a thumbnail, a missing file and a review queue — WITHOUT any
## proprietary artwork. Nothing is written into the project folder.

const PACK_ID := "synthetic_original"
const UPSCALE := 1.5

## item -> how the synthetic sprite is made
const SPRITES := {
	"bakery": {"hue": 0.07, "thumb": true, "variant": "winter"},
	"feed_mill": {"hue": -0.06, "auto": true},
	"dairy": {"hue": 0.5},
	"silo": {"hue": 0.12},
	"apple_tree": {"hue": -0.12},
}


static func _placeholder_image(lib: AssetLibrary, art_key: String) -> Array:
	## -> [Image, anchor: Vector2] of the built-in placeholder, or [] if absent.
	var spr := lib.get_sprite_in_pack(lib.placeholder_pack_id(), art_key)
	if spr == null:
		return []
	var path := str(lib.pack_by_id(lib.placeholder_pack_id())["base"]).path_join(spr.path)
	var img: Image = null
	if FileAccess.file_exists(path):
		img = Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		img = spr.texture.get_image()
	if img == null:
		return []
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	return [img, spr.anchor]


static func recolour(img: Image, hue: float, sat: float = 1.2, val: float = 1.0) -> void:
	var data := img.get_data()
	for i in range(0, data.size(), 4):
		if data[i + 3] == 0:
			continue
		var c := Color8(data[i], data[i + 1], data[i + 2])
		var c2 := Color.from_hsv(fposmod(c.h + hue, 1.0), clampf(c.s * sat, 0.0, 1.0), clampf(c.v * val, 0.0, 1.0))
		data[i] = clampi(roundi(c2.r * 255.0), 0, 255)
		data[i + 1] = clampi(roundi(c2.g * 255.0), 0, 255)
		data[i + 2] = clampi(roundi(c2.b * 255.0), 0, 255)
	img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)


static func build_zip(zip_path: String, lib: AssetLibrary, db: ItemDatabase, pack_id: String = PACK_ID) -> Dictionary:
	var out := {"ok": false, "zip": zip_path, "id": pack_id, "files": 0, "sprites": 0, "error": ""}
	var files := {}        # zip entry -> PackedByteArray
	var sprites := {}
	for id in SPRITES:
		var it := db.get_item(id)
		var src := _placeholder_image(lib, it.art_key if it else id) if it else []
		if src.is_empty():
			continue
		var opt: Dictionary = SPRITES[id]
		var img: Image = src[0]
		img.resize(roundi(img.get_width() * UPSCALE), roundi(img.get_height() * UPSCALE), Image.INTERPOLATE_LANCZOS)
		recolour(img, float(opt["hue"]))
		var rel := "items/%s.png" % id
		files[rel] = img.save_png_to_buffer()
		var entry := {"file": rel}
		if opt.get("auto", false):
			var aa := PackOverrides.auto_anchor(img.get_size(), img.get_used_rect(), it.footprint)
			entry["anchor"] = aa["anchor"]
			entry["pixels_per_world_px"] = aa["pixels_per_world_px"]
			entry["auto_anchor"] = true
		else:
			var a: Vector2 = src[1] * UPSCALE
			entry["anchor"] = [a.x, a.y]
		if opt.get("thumb", false):
			var th := img.duplicate() as Image
			var tw := 64
			th.resize(tw, maxi(1, roundi(img.get_height() * float(tw) / img.get_width())), Image.INTERPOLATE_LANCZOS)
			files["thumbs/%s.png" % id] = th.save_png_to_buffer()
			entry["thumb"] = "thumbs/%s.png" % id
		if opt.has("variant"):
			var v := img.duplicate() as Image
			recolour(v, 0.5, 0.35, 1.18)
			var vrel := "items/%s__%s.png" % [id, opt["variant"]]
			files[vrel] = v.save_png_to_buffer()
			entry["variants"] = {opt["variant"]: {"file": vrel, "anchor": entry["anchor"]}}
		sprites[it.art_key] = entry
	# A sprite whose image is missing (missing-file detection).
	var pp := db.get_item("popcorn_pot")
	if pp:
		sprites[pp.art_key] = {"file": "items/popcorn_pot.png", "anchor": [10, 10]}
	# A review-queue image that couldn't be matched automatically.
	var review: Array = []
	var sm := db.get_item("sugar_mill")
	var src2 := _placeholder_image(lib, sm.art_key) if sm else []
	if not src2.is_empty():
		var rimg: Image = src2[0]
		rimg.resize(roundi(rimg.get_width() * UPSCALE), roundi(rimg.get_height() * UPSCALE), Image.INTERPOLATE_LANCZOS)
		recolour(rimg, 0.3)
		files["review/unmatched_0042.png"] = rimg.save_png_to_buffer()
		review.append({"file": "review/unmatched_0042.png", "suggestions": ["sugar_mill", "popcorn_pot", "feed_mill"],
			"reason": "File name “unmatched_0042” matched no item; similar size to 2×2 production buildings."})
	var pack := {"format": AssetLibrary.PACK_FORMAT, "schema_version": 1, "id": pack_id, "name": "Synthetic test pack",
		"version": "1.0-test", "license": "CC0-1.0 (derived from the built-in placeholders)",
		"provenance": {"source": "generated at runtime from the built-in placeholder PNGs (recoloured, 1.5× upscaled)",
			"generator": "tests/fixtures/synthetic_pack.gd"},
		"priority": 500, "pixels_per_world_px": 2.0 * UPSCALE, "sprites": sprites}
	files["pack.json"] = JSON.stringify(pack, "  ").to_utf8_buffer()
	files["review.json"] = JSON.stringify({"items": review}, "  ").to_utf8_buffer()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(zip_path.get_base_dir()) if zip_path.begins_with("user://") else zip_path.get_base_dir())
	var zp := ZIPPacker.new()
	var err := zp.open(zip_path)
	if err != OK:
		out["error"] = "cannot create zip: %s" % error_string(err)
		return out
	# One folder deep, like a typical hand-made zip.
	for rel in files:
		zp.start_file("%s/%s" % [pack_id, rel])
		zp.write_file(files[rel])
		zp.close_file()
	zp.close()
	out["ok"] = true
	out["files"] = files.size()
	out["sprites"] = sprites.size()
	return out
