extends TestCase
## Asset packs: overrides.json parsing/merging (PackOverrides), zip install
## (PackInstaller) and AssetLibrary features for large private packs
## (thumbnails, lazy loading, variants, overrides, review queue, missing files).
## Everything is generated at runtime from flat-colour images: no artwork.

const ROOT := "user://test_asset_packs"


func before_each() -> void:
	PackInstaller.remove_recursive(ProjectSettings.globalize_path(ROOT))


func after_each() -> void:
	PackInstaller.remove_recursive(ProjectSettings.globalize_path(ROOT))


# --- helpers -----------------------------------------------------------------------

static func _img(w: int, h: int, used: Rect2i, col: Color = Color(0.8, 0.4, 0.2)) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(used, col)
	return img


static func _write_json(path: String, data: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  "))
	f.close()


static func _fake_info(item_id: String) -> Dictionary:
	match item_id:
		"c_item": return {"art_key": "c", "footprint": Vector2i(2, 2)}
		"b_item": return {"art_key": "b", "footprint": Vector2i(1, 1)}
	return {}


static func _fake_measure(rel: String) -> Dictionary:
	if rel == "items/x.png":
		return {"size": Vector2i(300, 260), "used": Rect2i(10, 20, 256, 220)}
	return {}


func _raw() -> Dictionary:
	return {
		"a": {"file": "items/a.png", "anchor": [50.0, 90.0], "variants": {"winter": {"file": "items/a__winter.png", "anchor": [51.0, 91.0]}}},
		"b": {"file": "items/b.png", "anchor": [10.0, 20.0]},
		"c": {"file": "items/c_wrong.png", "anchor": [1.0, 2.0], "verified": true},
	}


# --- PackOverrides -------------------------------------------------------------------

func test_safe_rel_path() -> void:
	assert_eq(PackOverrides.safe_rel_path("items/a.png"), "items/a.png")
	assert_eq(PackOverrides.safe_rel_path("./items\\sub\\a.png"), "items/sub/a.png")
	assert_eq(PackOverrides.safe_rel_path("items//a.png"), "items/a.png")
	for bad in ["../a.png", "items/../../a.png", "/etc/passwd", "C:/x.png", "user://x.png", "res://x.png", "", "  "]:
		assert_eq(PackOverrides.safe_rel_path(bad), "", "unsafe path rejected: '%s'" % bad)


func test_parse_normalizes_and_reports() -> void:
	var errs: Array = []
	var ov := PackOverrides.parse({
		"version": 1,
		"sprites": {
			"a": {"anchor": [12, 34.5], "scale": 1.25, "pixels_per_world_px": 2, "verified": true, "default_variant": "winter",
				"note": "kept", "variants": {"winter": {"anchor": [1, 2], "verified": true}}},
			"bad": {"anchor": [1], "scale": -2, "rejected": "yes"},
			"b": {"rejected": true},
			"not_obj": 5,
		},
		"assign": {"items\\x.png": "c_item", "../evil.png": "c_item", "items/y.png": ""},
		"future_field": {"x": 1},
	}, errs)
	assert_eq(ov["version"], 1)
	assert_eq(ov["sprites"]["a"]["anchor"], [12.0, 34.5])
	assert_eq(ov["sprites"]["a"]["scale"], 1.25)
	assert_eq(ov["sprites"]["a"]["pixels_per_world_px"], 2.0)
	assert_true(ov["sprites"]["a"]["verified"])
	assert_eq(ov["sprites"]["a"]["default_variant"], "winter")
	assert_eq(ov["sprites"]["a"]["note"], "kept", "unknown sprite fields survive")
	assert_eq(ov["sprites"]["a"]["variants"]["winter"], {"anchor": [1.0, 2.0]}, "variants only keep placement fields")
	assert_false(ov["sprites"].has("bad"), "a record with only invalid fields is dropped")
	assert_true(ov["sprites"]["b"]["rejected"])
	assert_false(ov["sprites"].has("not_obj"))
	assert_eq(ov["assign"], {"items/x.png": "c_item"}, "paths normalised; unsafe/empty assignments dropped")
	assert_eq(ov["future_field"], {"x": 1}, "unknown top-level fields kept")
	assert_true(errs.size() >= 6, "problems reported (%d)" % errs.size())
	# Garbage in -> empty, never a crash.
	assert_eq(PackOverrides.parse(null), PackOverrides.empty())
	var e2: Array = []
	assert_eq(PackOverrides.parse("nope", e2), PackOverrides.empty())
	assert_eq(e2.size(), 1)
	var e3: Array = []
	PackOverrides.parse({"version": 9}, e3)
	assert_eq(e3.size(), 1, "newer version is reported")


func test_set_sprite_merges_and_prunes() -> void:
	var ov := PackOverrides.empty()
	PackOverrides.set_sprite(ov, "a", {"anchor": [5, 6], "scale": 1.1})
	PackOverrides.set_sprite(ov, "a", {"verified": true})
	assert_eq(ov["sprites"]["a"], {"anchor": [5.0, 6.0], "scale": 1.1, "verified": true})
	PackOverrides.set_sprite(ov, "a", {"anchor": [7, 8]}, "winter")
	assert_eq(ov["sprites"]["a"]["variants"]["winter"]["anchor"], [7.0, 8.0])
	PackOverrides.set_sprite(ov, "a", {"verified": false, "scale": null})
	assert_eq(ov["sprites"]["a"].get("verified"), false, "verified=false is kept (it overrides a pack-level verified)")
	PackOverrides.set_sprite(ov, "a", {"verified": null})
	assert_false(ov["sprites"]["a"].has("verified"), "null removes the flag")
	assert_false(ov["sprites"]["a"].has("scale"), "null removes a field")
	PackOverrides.set_sprite(ov, "a", {"anchor": null}, "winter")
	assert_false(ov["sprites"]["a"].has("variants"), "empty variant records are pruned")
	PackOverrides.set_sprite(ov, "a", {"anchor": null})
	assert_false(ov["sprites"].has("a"), "empty sprite records are pruned")
	assert_true(PackOverrides.set_assign(ov, "items/x.png", "c_item"))
	assert_eq(ov["assign"]["items/x.png"], "c_item")
	assert_false(PackOverrides.set_assign(ov, "../x.png", "c_item"))
	PackOverrides.set_assign(ov, "items/x.png", "")
	assert_false(ov["assign"].has("items/x.png"))


func test_auto_anchor_math() -> void:
	# 2×2 footprint: diamond is 4 half-tiles wide = 128 world px; the opaque
	# area is 256 px wide -> 2 texture px per world px. The diamond's bottom
	# vertex sits on the lowest opaque row, its centre 32 world px above it.
	var aa := PackOverrides.auto_anchor(Vector2i(300, 260), Rect2i(10, 20, 256, 220), Vector2i(2, 2))
	assert_almost(aa["pixels_per_world_px"], 2.0)
	assert_almost(aa["anchor"][0], 138.0)
	assert_almost(aa["anchor"][1], 240.0 - 64.0)
	# Non-square footprints are symmetric about the centre too.
	var bb := PackOverrides.auto_anchor(Vector2i(100, 100), Rect2i(0, 0, 100, 100), Vector2i(1, 4))
	assert_almost(bb["anchor"][0], 50.0)
	# Empty alpha -> whole image.
	var cc := PackOverrides.auto_anchor(Vector2i(64, 64), Rect2i(), Vector2i(1, 1))
	assert_almost(cc["pixels_per_world_px"], 1.0)


func test_apply_merges_without_mutating_raw() -> void:
	var raw := _raw()
	var before := JSON.stringify(raw)
	var ov := PackOverrides.parse({"sprites": {
		"a": {"anchor": [60, 100], "scale": 1.5, "verified": true, "default_variant": "winter", "variants": {"winter": {"anchor": [70, 110]}}},
		"b": {"rejected": true},
		"zz": {"anchor": [1, 1]},
	}, "assign": {"items/x.png": "c_item", "items/nope.png": "c_item", "items/x2.png": "ghost"}})
	var res := PackOverrides.apply(raw, ov, _fake_info, _fake_measure)
	assert_eq(JSON.stringify(raw), before, "raw pack sprites are never modified")
	var sp: Dictionary = res["sprites"]
	assert_eq(sp["a"]["anchor"], [60.0, 100.0])
	assert_eq(sp["a"]["scale"], 1.5)
	assert_eq(sp["a"]["default_variant"], "winter")
	assert_eq(sp["a"]["variants"]["winter"]["anchor"], [70.0, 110.0])
	assert_eq(sp["a"]["file"], "items/a.png", "untouched fields kept")
	assert_false(sp.has("b"), "rejected sprite removed -> lower-priority pack shows")
	assert_true(res["rejected"].has("b"))
	assert_false(sp.has("zz"), "override for a sprite the pack lacks is ignored")
	assert_eq(sp["c"]["file"], "items/x.png", "assign replaces the item's sprite")
	assert_true(sp["c"]["auto_anchor"])
	assert_almost(sp["c"]["pixels_per_world_px"], 2.0)
	assert_eq(sp["c"]["anchor"], [138.0, 176.0])
	assert_false(sp["c"].has("verified"), "a newly assigned image is not verified")
	assert_eq(res["assigned"], {"c": "items/x.png"})
	assert_true(res["verified"].has("a"))
	assert_false(res["verified"].has("c"))
	assert_eq((res["errors"] as Array).size(), 2, "unreadable image + unknown item reported")
	# No overrides: identical content.
	var res2 := PackOverrides.apply(raw, PackOverrides.empty(), _fake_info, _fake_measure)
	assert_eq(JSON.stringify(res2["sprites"]), before)
	assert_true(res2["verified"].has("c"), "verified flags from pack.json count")
	# The user can un-verify art the pack itself marks as verified (e.g. builder QA): explicit false wins.
	var raw3: Dictionary = raw.duplicate(true)
	raw3["c"]["verified_by"] = "qa"
	var res3 := PackOverrides.apply(raw3, {"version": 1, "sprites": {"c": {"verified": false}}}, _fake_info, _fake_measure)
	assert_false(res3["verified"].has("c"), "verified=false in overrides.json overrides pack.json")
	assert_false((res3["sprites"]["c"] as Dictionary).has("verified_by"))


func test_assigned_image_keeps_known_thumb() -> void:
	var raw := {"b": {"file": "items/x.png", "thumb": "thumbs/x.png", "anchor": [1.0, 1.0]}}
	var ov := PackOverrides.parse({"assign": {"items/x.png": "c_item"}})
	var res := PackOverrides.apply(raw, ov, _fake_info, _fake_measure)
	assert_eq(res["sprites"]["c"]["thumb"], "thumbs/x.png")


func test_hand_set_anchor_clears_auto_flag() -> void:
	var raw := {"c": {"file": "items/c.png", "anchor": [1.0, 2.0], "auto_anchor": true}}
	var ov := PackOverrides.parse({"sprites": {"c": {"anchor": [3, 4]}}})
	var res := PackOverrides.apply(raw, ov, _fake_info, _fake_measure)
	assert_false(res["sprites"]["c"].has("auto_anchor"))
	assert_true(raw["c"]["auto_anchor"])


# --- PackInstaller ---------------------------------------------------------------------

func test_find_pack_json_and_ids() -> void:
	assert_eq(PackInstaller.find_pack_json(PackedStringArray(["a.png", "pack.json"])), "pack.json")
	assert_eq(PackInstaller.find_pack_json(PackedStringArray(["p/pack.json", "p/items/a.png"])), "p/pack.json")
	assert_eq(PackInstaller.find_pack_json(PackedStringArray(["pack.json", "p/pack.json"])), "pack.json", "root wins")
	assert_eq(PackInstaller.find_pack_json(PackedStringArray(["a/pack.json", "b/pack.json"])), "", "ambiguous")
	assert_eq(PackInstaller.find_pack_json(PackedStringArray(["a/b/pack.json"])), "", "two folders deep is not accepted")
	assert_eq(PackInstaller.find_pack_json(PackedStringArray(["__MACOSX/pack.json", "p/pack.json"])), "p/pack.json")
	assert_eq(PackInstaller.sanitize_id("My Pack/../x"), "My_Pack_.._x")
	assert_eq(PackInstaller.sanitize_id("..hidden"), "hidden")
	assert_eq(PackInstaller.validate_pack({"format": "x", "sprites": {}}).is_empty(), false)
	assert_eq(PackInstaller.validate_pack({"format": AssetLibrary.PACK_FORMAT, "sprites": {}}), "")
	assert_false(PackInstaller.validate_pack({"format": AssetLibrary.PACK_FORMAT}).is_empty())


func _make_zip(path: String, entries: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var zp := ZIPPacker.new()
	assert_eq(zp.open(path), OK, "zip opened")
	for name in entries:
		zp.start_file(name)
		var v: Variant = entries[name]
		zp.write_file(v if v is PackedByteArray else str(v).to_utf8_buffer())
		zp.close_file()
	zp.close()


func _pack_json(id: String, version: String) -> String:
	return JSON.stringify({"format": AssetLibrary.PACK_FORMAT, "schema_version": 1, "id": id, "name": "Test pack", "version": version,
		"provenance": {"source": "unit test"}, "priority": 5, "pixels_per_world_px": 1.0,
		"sprites": {"t_lamp": {"file": "items/lamp.png", "anchor": [16, 40]}}})


func test_zip_install_is_atomic_and_keeps_overrides() -> void:
	var root := ROOT.path_join("packs")
	var png := _img(32, 48, Rect2i(4, 4, 24, 40)).save_png_to_buffer()
	var z1 := ROOT.path_join("v1.zip")
	_make_zip(z1, {"mypack/pack.json": _pack_json("my_pack", "1.0"), "mypack/items/lamp.png": png,
		"mypack/../../escape.txt": "x", "other/readme.txt": "outside the pack folder"})
	var r := PackInstaller.install_zip(ProjectSettings.globalize_path(z1), root)
	assert_true(r.ok, "installed: %s" % r.error)
	assert_eq(r.pack_id, "my_pack")
	assert_eq(r.version, "1.0")
	assert_eq(r.files, 2, "pack.json + image extracted")
	assert_eq(r.skipped.size(), 1, "zip-slip entry skipped")
	var dir := ProjectSettings.globalize_path(root).path_join("my_pack")
	assert_true(FileAccess.file_exists(dir.path_join("items/lamp.png")))
	assert_false(FileAccess.file_exists(ProjectSettings.globalize_path(ROOT).path_join("escape.txt")))
	# The user fine-tunes the pack, then installs v2 (which ships no overrides).
	_write_json(dir.path_join("overrides.json"), {"version": 1, "sprites": {"t_lamp": {"verified": true}}})
	var z2 := ROOT.path_join("v2.zip")
	_make_zip(z2, {"pack.json": _pack_json("my_pack", "2.0"), "items/lamp.png": png})
	var r2 := PackInstaller.install_zip(ProjectSettings.globalize_path(z2), root)
	assert_true(r2.ok, "re-installed: %s" % r2.error)
	assert_true(r2.replaced)
	assert_true(r2.kept_overrides, "overrides carried over to the new version")
	assert_true(FileAccess.file_exists(dir.path_join("overrides.json")))
	var pj: Variant = JsonUtil.read_json(dir.path_join("pack.json"))
	assert_eq(pj["version"], "2.0")
	var left := DirAccess.open(ProjectSettings.globalize_path(root))
	left.include_hidden = true
	assert_eq(Array(left.get_directories()), ["my_pack"], "no temp/old folders left behind")
	# Bad zips are rejected without touching the installed pack.
	var bad := ROOT.path_join("bad.zip")
	_make_zip(bad, {"items/lamp.png": png})
	var rb := PackInstaller.install_zip(ProjectSettings.globalize_path(bad), root)
	assert_false(rb.ok)
	assert_has(rb.error, "pack.json")
	var wrong := ROOT.path_join("wrong.zip")
	_make_zip(wrong, {"pack.json": JSON.stringify({"format": "something-else", "sprites": {}})})
	assert_false(PackInstaller.install_zip(ProjectSettings.globalize_path(wrong), root).ok)
	var reserved := ROOT.path_join("reserved.zip")
	_make_zip(reserved, {"pack.json": _pack_json(AssetLibrary.BUILTIN_ID, "1")})
	assert_false(PackInstaller.install_zip(ProjectSettings.globalize_path(reserved), root).ok, "built-in id is reserved")
	assert_false(PackInstaller.install_zip(ProjectSettings.globalize_path(ROOT.path_join("missing.zip")), root).ok)
	var notzip := ROOT.path_join("not.zip")
	var f := FileAccess.open(notzip, FileAccess.WRITE)
	f.store_string("definitely not a zip")
	f.close()
	assert_false(PackInstaller.install_zip(ProjectSettings.globalize_path(notzip), root).ok)
	assert_eq(JsonUtil.read_json(dir.path_join("pack.json"))["version"], "2.0", "installed pack untouched by failures")
	assert_eq(PackInstaller.uninstall("my_pack", root), OK)
	assert_false(DirAccess.dir_exists_absolute(dir))


func test_interrupted_swap_is_restored() -> void:
	var root := ProjectSettings.globalize_path(ROOT.path_join("packs"))
	DirAccess.make_dir_recursive_absolute(root.path_join(".replaced_my_pack_123"))
	_write_json(root.path_join(".replaced_my_pack_123/pack.json"), {"format": AssetLibrary.PACK_FORMAT, "sprites": {}})
	DirAccess.make_dir_recursive_absolute(root.path_join(".installing_other_456"))
	PackInstaller._clean_stale(root)
	assert_true(FileAccess.file_exists(root.path_join("my_pack/pack.json")), "previous version restored")
	assert_false(DirAccess.dir_exists_absolute(root.path_join(".installing_other_456")), "temp folder removed")


# --- AssetLibrary ------------------------------------------------------------------------

func _lib_fixture() -> AssetLibrary:
	## builtin pack (placeholder) + one user pack with thumbs, variants,
	## a missing file and a review queue.
	var base := ROOT.path_join("builtin")
	_img(64, 64, Rect2i(8, 8, 48, 48), Color(0.5, 0.5, 0.5)).save_png(_mk(base.path_join("items/ph.png")))
	_write_json(base.path_join("pack.json"), {"format": AssetLibrary.PACK_FORMAT, "id": AssetLibrary.BUILTIN_ID, "name": "PH",
		"priority": 0, "pixels_per_world_px": 2.0, "sprites": {
			"t_bakery": {"file": "items/ph.png", "anchor": [32, 56]}, "t_lamp": {"file": "items/ph.png"}, "t_long": {"file": "items/ph.png"}}})
	var up := ROOT.path_join("user/orig")
	_img(200, 160, Rect2i(4, 10, 192, 140)).save_png(_mk(up.path_join("items/bakery.png")))
	_img(200, 160, Rect2i(4, 10, 192, 140), Color(0.3, 0.5, 0.9)).save_png(up.path_join("items/bakery__winter.png"))
	_img(32, 24, Rect2i(0, 0, 32, 24)).save_png(up.path_join("items/bakery.thumb.png"))
	_img(40, 80, Rect2i(10, 5, 20, 70)).save_png(up.path_join("items/lamp.png"))
	_img(96, 140, Rect2i(0, 12, 96, 128), Color(0.2, 0.8, 0.3)).save_png(_mk(up.path_join("review/long_thing.png")))
	_write_json(up.path_join("pack.json"), {"format": AssetLibrary.PACK_FORMAT, "id": "orig", "name": "Original", "version": "3.1",
		"provenance": {"source": "test", "date": "2026-11-09"}, "priority": 10, "pixels_per_world_px": 1.0, "sprites": {
			"t_bakery": {"file": "items/bakery.png", "thumb": "items/bakery.thumb.png", "anchor": [100, 130],
				"variants": {"winter": {"file": "items/bakery__winter.png", "anchor": [100, 131]}}},
			"t_lamp": {"file": "items/lamp.png", "anchor": [20, 70], "auto_anchor": true},
			"t_fence": {"file": "items/does_not_exist.png"}}})
	_write_json(up.path_join("review.json"), {"items": [
		{"file": "review/long_thing.png", "suggestions": ["t_long", "t_lamp"], "reason": "no name match"},
		{"file": "../outside.png", "suggestions": []}]})
	var lib := AssetLibrary.new()
	lib.builtin_pack_path = base.path_join("pack.json")
	lib.dev_packs_dir = ROOT.path_join("no_dev_packs")
	lib.user_packs_dir = ROOT.path_join("user")
	lib.load_all(fixture_db())
	return lib


static func _mk(path: String) -> String:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return path


func test_library_priority_version_provenance() -> void:
	var lib := _lib_fixture()
	assert_eq(lib.pack_list().size(), 2)
	assert_eq(lib.pack_list()[0]["id"], "orig", "user pack (100 + 10) before the built-in placeholders")
	assert_eq(lib.pack_list()[0]["priority"], 110)
	assert_eq(lib.pack_list()[0]["version"], "3.1")
	assert_eq(lib.pack_list()[0]["provenance"]["source"], "test")
	assert_eq(lib.art_source("t_bakery"), "orig")
	assert_eq(lib.art_status("t_bakery"), "original")
	assert_eq(lib.art_status("t_long"), "placeholder")
	assert_eq(lib.art_status("t_path"), "none")
	assert_true(lib.needs_review("t_bakery"))
	assert_false(lib.pack_list()[0]["alpha_bleed"], "alpha_bleed defaults to false (runtime edge fix on)")


func test_thumbnails_do_not_load_full_textures() -> void:
	var lib := _lib_fixture()
	assert_eq(lib.texture_loads, 0, "loading packs decodes no images")
	var th := lib.get_thumbnail("t_bakery")
	assert_not_null(th)
	assert_eq(th.get_width(), 32, "the small thumb file is used")
	assert_eq(lib.thumb_loads, 1)
	assert_eq(lib.texture_loads, 0, "thumbnail did not force the full texture")
	var th2 := lib.get_thumbnail("t_lamp")
	assert_eq(th2.get_width(), 40, "no thumb -> falls back to the sprite texture")
	assert_eq(lib.texture_loads, 1)
	var spr := lib.get_sprite("t_bakery")
	assert_eq(spr.texture.get_width(), 200)
	assert_eq(lib.texture_loads, 2)
	lib.get_sprite("t_bakery")
	lib.get_thumbnail("t_bakery")
	assert_eq(lib.texture_loads + lib.thumb_loads, 3, "everything is cached")


func test_prepare_image_fixes_dark_alpha_edges() -> void:
	# White opaque left half, transparent BLACK right half (as many pack WebPs store it).
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(Rect2i(0, 0, 4, 8), Color(1, 1, 1, 1))
	var raw_mip := img.duplicate() as Image
	raw_mip.generate_mipmaps()
	var out := AssetLibrary.prepare_image(img)
	assert_true(out.has_mipmaps(), "mipmaps generated")
	var edge := out.get_pixel(4, 3)
	assert_eq(edge.a, 0.0, "transparent pixels stay transparent")
	assert_true(edge.r > 0.9 and edge.g > 0.9 and edge.b > 0.9, "edge colour spread under transparency (%s)" % str(edge))
	assert_true(out.get_pixel(0, 0) == Color(1, 1, 1, 1), "opaque pixels untouched")
	# The first mip level's edge texel is no longer darkened by the black under alpha 0.
	var m1 := out.duplicate() as Image
	m1.resize(4, 4, Image.INTERPOLATE_BILINEAR)
	var r1 := raw_mip.duplicate() as Image
	r1.resize(4, 4, Image.INTERPOLATE_BILINEAR)
	assert_true(m1.get_pixel(2, 1).r >= r1.get_pixel(2, 1).r, "downscaled edge not darker than before")
	var plain := AssetLibrary.prepare_image(_img(8, 8, Rect2i(0, 0, 4, 8), Color(1, 1, 1)), false)
	assert_true(plain.has_mipmaps() and plain.get_pixel(4, 3).r < 0.1, "fix_edges=false leaves the image as is")


func test_variants_and_default_variant() -> void:
	var lib := _lib_fixture()
	assert_eq(lib.variants_of("t_bakery"), ["winter"])
	assert_eq(lib.variants_of("t_lamp"), [])
	assert_eq(lib.get_sprite("t_bakery", "winter").path, "items/bakery__winter.png")
	assert_eq(lib.get_sprite("t_bakery", "winter").scale, 1.0, "variant inherits the pack resolution")
	assert_eq(lib.get_sprite("t_bakery", "nope").path, "items/bakery.png", "unknown variant -> base")
	assert_eq(lib.save_overrides("orig", "t_bakery", {"default_variant": "winter"}), OK)
	assert_eq(lib.get_sprite("t_bakery").path, "items/bakery__winter.png", "default variant applies to objects without one")
	assert_eq(lib.get_sprite("t_bakery", AssetLibrary.BASE_VARIANT).path, "items/bakery.png", "@base still reaches the base image")


func test_overrides_save_apply_reload() -> void:
	var lib := _lib_fixture()
	assert_eq(lib.get_sprite("t_bakery").anchor, Vector2(100, 130))
	assert_eq(lib.save_overrides("orig", "t_bakery", {"anchor": [90, 120], "scale": 1.5, "verified": true}), OK)
	assert_eq(lib.get_sprite("t_bakery").anchor, Vector2(90, 120), "cache invalidated for the edited key")
	assert_almost(lib.get_sprite("t_bakery").scale, 1.5)
	assert_true(lib.is_verified("t_bakery"))
	assert_false(lib.needs_review("t_bakery"))
	assert_eq(lib.save_overrides("orig", "t_bakery", {"anchor": [7, 8]}, "winter"), OK)
	assert_eq(lib.get_sprite("t_bakery", "winter").anchor, Vector2(7, 8))
	assert_eq(lib.get_sprite("t_bakery").anchor, Vector2(90, 120), "variant override doesn't touch the base")
	var ov_path := ROOT.path_join("user/orig/overrides.json")
	assert_true(FileAccess.file_exists(ov_path))
	var raw: Variant = JsonUtil.read_json(ROOT.path_join("user/orig/pack.json"))
	assert_eq(raw["sprites"]["t_bakery"]["anchor"], [100.0, 130.0], "pack.json is never modified")
	# Survives a reload.
	lib.load_all()
	assert_eq(lib.get_sprite("t_bakery").anchor, Vector2(90, 120))
	assert_true(lib.is_verified("t_bakery"))
	# Rejected -> the placeholder shows; restoring brings the original back.
	assert_eq(lib.save_overrides("orig", "t_bakery", {"rejected": true}), OK)
	assert_eq(lib.art_source("t_bakery"), AssetLibrary.BUILTIN_ID)
	assert_eq(lib.get_sprite("t_bakery").path, "items/ph.png")
	assert_eq(lib.rejected_in("t_bakery"), "orig")
	assert_not_null(lib.get_sprite_in_pack("orig", "t_bakery", "", -1, true), "rejected original can still be previewed")
	assert_eq(lib.save_overrides("orig", "t_bakery", {"rejected": null}), OK)
	assert_eq(lib.art_source("t_bakery"), "orig")
	# The built-in pack is read-only.
	assert_eq(lib.save_overrides(AssetLibrary.BUILTIN_ID, "t_lamp", {"scale": 2.0}), ERR_FILE_NO_PERMISSION)
	assert_eq(lib.save_overrides("nope", "t_lamp", {"scale": 2.0}), ERR_DOES_NOT_EXIST)


func test_review_queue_and_assign() -> void:
	var lib := _lib_fixture()
	var q := lib.review_queue("orig")
	assert_eq(q.size(), 1, "unsafe review entry dropped")
	assert_eq(q[0]["file"], "review/long_thing.png")
	assert_eq(q[0]["suggestions"], ["t_long", "t_lamp"])
	assert_eq(q[0]["assigned"], "")
	assert_eq(lib.review_packs(), ["orig"])
	assert_eq(lib.art_status("t_long"), "placeholder")
	assert_eq(lib.assign_image("orig", "review/long_thing.png", "t_long"), OK)
	assert_eq(lib.art_source("t_long"), "orig")
	var spr := lib.get_sprite("t_long")
	assert_eq(spr.path, "review/long_thing.png")
	# 1×4 footprint: diamond 5 half-tiles = 160 world px over 96 opaque px.
	assert_almost(spr.scale, 160.0 / 96.0, 0.001)
	assert_almost(spr.anchor.x, 48.0)
	assert_true(lib.entry_of("t_long")["auto_anchor"])
	assert_eq(lib.review_queue("orig")[0]["assigned"], "t_long")
	assert_eq(lib.assign_image("orig", "review/long_thing.png", "unknown_item"), ERR_INVALID_PARAMETER)
	assert_eq(lib.assign_image("orig", "../x.png", "t_long"), ERR_INVALID_PARAMETER)
	lib.load_all()
	assert_eq(lib.art_source("t_long"), "orig", "assignment persists")
	assert_eq(lib.assign_image("orig", "review/long_thing.png", ""), OK)
	assert_eq(lib.art_source("t_long"), AssetLibrary.BUILTIN_ID, "un-assigning restores the placeholder")


func test_missing_files_and_stats() -> void:
	var lib := _lib_fixture()
	assert_eq(lib.missing_files("orig"), ["items/does_not_exist.png"])
	assert_eq(lib.missing_files(AssetLibrary.BUILTIN_ID), [])
	assert_has(lib.missing_files(), "orig: items/does_not_exist.png")
	var st := lib.pack_stats("orig")
	assert_eq(st["sprites"], 3)
	assert_eq(st["variants"], 1)
	assert_eq(st["thumbs"], 1)
	assert_eq(st["files"], 5)
	assert_eq(st["review_items"], 1)
	# A sprite whose image is missing falls through to the next pack.
	assert_eq(lib.get_sprite("t_fence"), null)
	var s := lib.stats(fixture_db())
	assert_eq(s["original"], 3)
	assert_eq(s["with_art"], 4)
	# Hidden folders (interrupted installs) are never loaded as packs.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT.path_join("user/.installing_x_1")))
	_write_json(ROOT.path_join("user/.installing_x_1/pack.json"), {"format": AssetLibrary.PACK_FORMAT, "id": "x", "sprites": {}})
	lib.load_all()
	assert_eq(lib.pack_list().size(), 2)
