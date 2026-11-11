extends TestCase
## Ambient animation, world-theme variants and mirror art, on synthetic packs
## generated at runtime from flat-colour images (no artwork).

const TMP := "user://test_ambient"
const VIEW := Rect2(-100000, -100000, 200000, 200000)
const NOWHERE := Rect2(900000, 900000, 10, 10)


func before_each() -> void:
	PackInstaller.remove_recursive(ProjectSettings.globalize_path(TMP))


func after_each() -> void:
	PackInstaller.remove_recursive(ProjectSettings.globalize_path(TMP))


static func _save(w: int, h: int, c: Color, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	img.save_png(path)


func _lib(extra: Dictionary = {}) -> AssetLibrary:
	var base := TMP.path_join("builtin")
	_save(40, 80, Color.RED, base.path_join("lamp.png"))
	_save(80, 40, Color.WHITE, base.path_join("lamp_sheet.png"))   # 4 frames of 40x20 in 2 columns (2 rows)
	_save(120, 100, Color.BLUE, base.path_join("bakery.png"))
	_save(120, 100, Color.CYAN, base.path_join("bakery_winter.png"))
	_save(360, 100, Color.GREEN, base.path_join("bakery_sheet.png"))
	_save(64, 160, Color.GRAY, base.path_join("long.png"))
	_save(70, 150, Color.YELLOW, base.path_join("long_m.png"))
	_save(64, 32, Color.BLACK, base.path_join("long.shadow.png"))
	_save(64, 32, Color.ORANGE, base.path_join("path.png"))
	var sprites := {
		"t_lamp": {"file": "lamp.png", "anchor": [20, 70],
			"anim": {"sheet": "lamp_sheet.png", "frames": 4, "columns": 2, "fps": 4.0, "mode": "overlay"}},
		"t_bakery": {"file": "bakery.png", "anchor": [60, 80],
			"anim": {"sheet": "bakery_sheet.png", "frames": 3, "fps": 2.0, "mode": "replace", "anchor": [55, 85]},
			"variants": {"theme_winter": {"file": "bakery_winter.png", "anchor": [60, 80]}, "red": {"file": "bakery.png", "anchor": [60, 80]}}},
		"t_long": {"file": "long.png", "anchor": [32, 120], "shadow": {"file": "long.shadow.png", "anchor": [32, 16]},
			"mirror": {"file": "long_m.png", "anchor": [40, 110]}},
		"t_path": {"file": "path.png", "anchor": [32, 16]},
	}
	sprites.merge(extra, true)
	var f := FileAccess.open(base.path_join("pack.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"format": AssetLibrary.PACK_FORMAT, "id": AssetLibrary.BUILTIN_ID, "priority": 0,
		"pixels_per_world_px": 1.0, "sprites": sprites}))
	f.close()
	var lib := AssetLibrary.new()
	lib.builtin_pack_path = base.path_join("pack.json")
	lib.dev_packs_dir = TMP.path_join("no_dev")
	lib.user_packs_dir = TMP.path_join("no_user")
	lib.load_all()
	return lib


func _renderer(layout: FarmLayout, db: ItemDatabase, lib: AssetLibrary) -> ObjectRenderer:
	var r := ObjectRenderer.new()
	r._ready()
	r.bind(layout, db, lib)
	r.ensure_sorted()
	return r


func _dispose(r: ObjectRenderer) -> void:
	r._exit_tree()
	r.free()


func _lamps(layout: FarmLayout, db: ItemDatabase, n: int) -> Array:
	var objs: Array = []
	for i in n:
		objs.append(make_obj(db.get_item("t_lamp"), Vector2i(i * 2, 0)))
	return layout.add_objects(objs, false)


# --- pack parsing ----------------------------------------------------------------------

func test_anim_entry_is_parsed() -> void:
	var lib := _lib()
	var a := lib.get_sprite("t_lamp").anim
	assert_not_null(a)
	assert_eq(a.frames, 4)
	assert_true(a.overlay, "overlay mode")
	assert_eq(a.frame_size, Vector2(40, 20))
	assert_eq(a.anchor, Vector2(20, 70), "anchor defaults to the sprite's")
	assert_eq(a.frame_rect(3), Rect2(40, 20, 40, 20))
	assert_eq(a.frame_rect(5), Rect2(40, 0, 40, 20), "frames wrap")
	var b := lib.get_sprite("t_bakery").anim
	assert_false(b.overlay, "replace mode")
	assert_eq(b.frame_size, Vector2(120, 100), "columns default to the frame count")
	assert_eq(b.anchor, Vector2(55, 85))
	assert_null(lib.get_sprite("t_path").anim, "no anim entry -> static")
	assert_null(lib.get_sprite("t_bakery", "theme_winter").anim, "a variant does not inherit the base animation")


func test_bad_anim_entries_stay_static_and_are_reported() -> void:
	var lib := _lib({
		"t_fence": {"file": "path.png", "anchor": [1, 1], "anim": {"sheet": "nope.png", "frames": 2, "fps": 3.0}},
		"t_fence_stone": {"file": "path.png", "anchor": [1, 1], "anim": {"sheet": "../up.png", "frames": 2, "fps": 3.0}},
		"t_mystery": {"file": "path.png", "anchor": [1, 1], "anim": {"sheet": "lamp_sheet.png", "frames": 0, "fps": 3.0}}})
	for k in ["t_fence", "t_fence_stone", "t_mystery"]:
		var s := lib.get_sprite(k)
		assert_not_null(s, "%s still draws" % k)
		assert_null(s.anim, "%s is static" % k)
	assert_true(lib.errors.size() >= 3, "each bad entry is reported: %s" % str(lib.errors))


func test_pack_stats_count_sheets_and_mirrors() -> void:
	var lib := _lib({"t_fence": {"file": "path.png", "anchor": [1, 1], "anim": {"sheet": "gone.png", "frames": 2, "fps": 3.0}}})
	var st := lib.pack_stats(AssetLibrary.BUILTIN_ID)
	assert_eq(st["anims"], 3)
	assert_eq(st["mirrors"], 1)
	assert_has(st["missing_files"], "gone.png")


# --- playback --------------------------------------------------------------------------

func test_one_clock_drives_every_sprite() -> void:
	var db := fixture_db()
	var layout := FarmLayout.new()
	var uids := _lamps(layout, db, 6)
	var r := _renderer(layout, db, _lib())
	for u: int in uids:
		assert_eq(r.anim_frame_of(u), posmod(u * 7, 4), "starts at its stable phase")
	r.advance_anim(0.26, VIEW)   # 4 fps: one frame later
	for u: int in uids:
		assert_eq(r.anim_frame_of(u), (1 + posmod(u * 7, 4)) % 4, "advanced together")
	assert_eq(r.anim_stats()["frame_updates"], 6)
	r.advance_anim(0.01, VIEW)
	assert_eq(r.anim_stats()["frame_updates"], 0, "no redraw until the frame changes")
	_dispose(r)


func test_only_visible_sprites_animate() -> void:
	var db := fixture_db()
	var layout := FarmLayout.new()
	var uids := _lamps(layout, db, 3)
	var r := _renderer(layout, db, _lib())
	var before: int = r.anim_frame_of(uids[0])
	r.advance_anim(0.3, NOWHERE)
	assert_eq(r.anim_stats()["ticked"], 0)
	assert_eq(r.anim_frame_of(uids[0]), before, "off-screen: frame unchanged")
	r.advance_anim(0.0, r.bounds_of(uids[0]))
	assert_eq(r.anim_stats()["ticked"], 1, "only the sprite in view")
	assert_ne(r.anim_frame_of(uids[0]), before, "catches up from the shared clock when it comes into view")
	r.set_hidden([uids[0]])
	r.advance_anim(0.3, VIEW)
	assert_eq(r.anim_stats()["ticked"], 2, "hidden objects don't animate")
	_dispose(r)


func test_modes_off_and_reduced() -> void:
	var db := fixture_db()
	var layout := FarmLayout.new()
	var uids := _lamps(layout, db, 9)
	var r := _renderer(layout, db, _lib())
	r.set_ambient_mode(ObjectRenderer.Ambient.OFF)
	for u: int in uids:
		assert_eq(r.anim_frame_of(u), -1, "Off: static")
	r.advance_anim(1.0, VIEW)
	assert_eq(r.anim_stats()["frame_updates"], 0)
	r.set_ambient_mode(ObjectRenderer.Ambient.REDUCED)
	var moving: Array = []
	for u: int in uids:
		if r.anim_frame_of(u) != -1:
			moving.append(u)
	assert_eq(moving.size(), 3, "Reduced: one third of the instances")
	var f0: int = r.anim_frame_of(moving[0])
	r.advance_anim(0.3, VIEW)   # 1.3 s * 2 fps = same half-speed frame as 1.0 s
	assert_eq(r.anim_frame_of(moving[0]), f0, "half speed: not yet")
	r.advance_anim(0.25, VIEW)  # 1.55 s * 2 fps -> next frame
	assert_eq(r.anim_frame_of(moving[0]), (f0 + 1) % 4, "half speed: next frame")
	r.set_ambient_mode(ObjectRenderer.Ambient.FULL)
	for u: int in uids:
		assert_true(r.anim_frame_of(u) >= 0, "Full: everything")
	_dispose(r)


func test_playback_leaves_draw_order_alone() -> void:
	var db := fixture_db()
	var lib := _lib()
	var layout := FarmLayout.new()
	var objs: Array = []
	for i in 40:
		objs.append(make_obj(db.get_item("t_lamp" if i % 3 else "t_bakery"), Vector2i(i * 4, (i % 5) * 4)))
	layout.add_objects(objs, false)
	var r := _renderer(layout, db, lib)
	var di: int = r.depth_stats()["draw_index_updates"]
	var sorts: int = r.depth_stats()["incremental"] + r.depth_stats()["full"] + r.depth_stats()["fallback"]
	for i in 30:
		r.advance_anim(0.2, VIEW)
		r.ensure_sorted()
	var st := r.depth_stats()
	assert_eq(st["draw_index_updates"], di, "no draw index changed")
	assert_eq(st["incremental"] + st["full"] + st["fallback"], sorts, "no re-sort")
	var chk := r.check_order()
	assert_eq(chk["violations"], 0)
	assert_eq(chk["mismatch"], 0)
	_dispose(r)


func test_overlay_bounds_cover_the_frames() -> void:
	var db := fixture_db()
	var layout := FarmLayout.new()
	var u: int = layout.add_objects([make_obj(db.get_item("t_bakery"), Vector2i(0, 0))], false)[0]
	var r := _renderer(layout, db, _lib())
	var spr := r.sprite_of(u)
	var c := Iso.footprint_center(Vector2i.ZERO, Vector2i(3, 3))
	var want := spr.world_rect(c, false).merge(spr.anim.world_rect(c, false, spr.scale))
	assert_eq(r.bounds_of(u), want, "depth sorting and culling see the whole animation")
	_dispose(r)


func test_settings_default_follows_reduce_motion() -> void:
	assert_eq(AppSettings.ambient_default(1), "reduced")
	assert_eq(AppSettings.ambient_default(0), "full")
	assert_eq(AppSettings.ambient_default(-1), "full", "unknown preference: full")
	var s := AppSettings.new("user://test_ambient_settings.cfg")
	assert_eq(s.get_v("ambient_animation"), "auto")
	assert_true(s.ambient_animation() in AppSettings.AMBIENT_CHOICES, "auto resolves to a real choice")
	s.set_v("ambient_animation", "off", false)
	assert_eq(s.ambient_animation(), "off")
	s.set_v("ambient_animation", "nonsense", false)
	assert_true(s.ambient_animation() in AppSettings.AMBIENT_CHOICES, "a bad value falls back")


# --- themes ----------------------------------------------------------------------------

func test_item_theme_variant_only_when_it_exists() -> void:
	var lib := _lib()
	assert_eq(lib.themed_variant("t_bakery", "", "winter"), "theme_winter")
	assert_eq(lib.themed_variant("t_bakery", "", "autumn"), "", "no such art: nothing invented")
	assert_eq(lib.themed_variant("t_bakery", "", FarmLayout.DEFAULT_THEME), "")
	assert_eq(lib.themed_variant("t_bakery", "red", "winter"), "red", "an object's own variant wins")
	assert_eq(lib.themed_variant("t_lamp", "", "winter"), "")
	assert_eq(lib.item_themes(), ["winter"])


func test_client_seasonal_skins() -> void:
	## Packs built from the client name seasonal skins "<look>__<theme>" ("" = the base image).
	var base := TMP.path_join("builtin")
	_save(30, 30, Color.WHITE, base.path_join("tree_w.png"))
	_save(30, 30, Color.WHITE, base.path_join("mill_l2.png"))
	var lib := _lib({"t_tree": {"file": "path.png", "anchor": [32, 16], "variants": {
			"__winter": {"file": "tree_w.png", "anchor": [15, 25]}, "__halloween": {"file": "tree_w.png", "anchor": [15, 25]}}},
		"t_mill": {"file": "path.png", "anchor": [32, 16], "variants": {
			"lvl_2": {"file": "mill_l2.png", "anchor": [15, 25]}, "lvl_2__winter": {"file": "tree_w.png", "anchor": [15, 25]}}}})
	assert_eq(lib.themed_variant("t_tree", "", "winter"), "__winter", "the base image's winter skin")
	assert_eq(lib.themed_variant("t_tree", AssetLibrary.BASE_VARIANT, "winter"), "__winter")
	assert_eq(lib.themed_variant("t_tree", "", "autumn"), "", "no autumn skin: nothing invented")
	assert_eq(lib.themed_variant("t_mill", "lvl_2", "winter"), "lvl_2__winter", "a look's own winter skin")
	assert_eq(lib.themed_variant("t_mill", "", "winter"), "", "the base image has no winter skin here")
	assert_eq(lib.themed_variant("t_mill", "lvl_2__winter", FarmLayout.DEFAULT_THEME), "lvl_2__winter", "a skin chosen by hand stays")
	assert_true(lib.has_theme_variants("t_tree") and not lib.has_theme_variants("t_lamp"))
	assert_eq(lib.item_themes(), ["halloween", "winter"])
	assert_eq(lib.get_sprite("t_tree", lib.themed_variant("t_tree", "", "winter")).path, "tree_w.png")


func test_theme_change_redraws_only_themed_items() -> void:
	var db := fixture_db()
	var lib := _lib()
	var layout := FarmLayout.new()
	var bakery: int = layout.add_objects([make_obj(db.get_item("t_bakery"), Vector2i(0, 0))], false)[0]
	var lamp: int = layout.add_objects([make_obj(db.get_item("t_lamp"), Vector2i(8, 0))], false)[0]
	var r := _renderer(layout, db, lib)
	var lamp_sprite := r.sprite_of(lamp)
	assert_eq(r.sprite_of(bakery).path, "bakery.png")
	layout.set_world_value("theme", "", "winter")
	r.refresh_theme()
	assert_eq(r.sprite_of(bakery).variant, "theme_winter")
	assert_eq(r.sprite_of(bakery).path, "bakery_winter.png")
	assert_true(r.sprite_of(lamp) == lamp_sprite, "items without theme art are left alone")
	layout.set_world_value("theme", "", "autumn")
	r.refresh_theme()
	assert_eq(r.sprite_of(bakery).path, "bakery.png", "a theme without art shows the base image")
	_dispose(r)


# --- mirror ----------------------------------------------------------------------------

func test_flipped_object_draws_mirror_art_unflipped() -> void:
	var db := fixture_db()
	var lib := _lib()
	var layout := FarmLayout.new()
	var plain: int = layout.add_objects([make_obj(db.get_item("t_long"), Vector2i(0, 0))], false)[0]
	var turned: int = layout.add_objects([make_obj(db.get_item("t_long"), Vector2i(10, 0), true)], false)[0]
	var r := _renderer(layout, db, lib)
	assert_eq(r.sprite_of(plain).path, "long.png")
	var spr := r.sprite_of(turned)
	assert_eq(spr.path, "long_m.png", "flipped: the mirror texture")
	assert_eq(spr.anchor, Vector2(40, 110), "with its own anchor")
	var o := layout.get_obj(turned)
	assert_true(o.flipped, "the document still says flipped")
	var c := Iso.footprint_center(o.origin, o.size)
	assert_eq(r.bounds_of(turned), spr.world_rect(c, false), "drawn unflipped")
	assert_true(spr.shadow_mirrored, "no own shadow: the base shadow is reused, flipped")
	assert_eq(r.pick(c + Vector2(0, -40)), turned, "picks on the mirror art")
	_dispose(r)


# --- patch animations ("rect") and glow layers ------------------------------------------

func _patch_lib() -> AssetLibrary:
	## t_mystery: 60x50 static with an 8-frame patch animation over its rectangle
	## (10, 6, 20, 16) at half resolution (10x8 cells, 1 px padding) + a glow
	## layer and glow frames; t_fence: glow only; t_fence_stone: a bad rect.
	var base := TMP.path_join("builtin")
	_save(60, 50, Color.DIM_GRAY, base.path_join("mill.png"))
	_save(60, 50, Color(1.0, 0.8, 0.2, 0.5), base.path_join("mill.glow.png"))
	_save(4 * 12, 2 * 10, Color.WHITE, base.path_join("mill.anim.png"))
	_save(4 * 12, 2 * 10, Color(1.0, 0.5, 0.1, 0.8), base.path_join("mill.anim.glow.png"))
	_save(30, 30, Color.BLACK, base.path_join("lantern.png"))
	_save(30, 30, Color.YELLOW, base.path_join("lantern.glow.png"))
	_save(31, 30, Color.YELLOW, base.path_join("lantern.glow_bad.png"))
	return _lib({
		"t_mystery": {"file": "mill.png", "anchor": [30, 40], "glow": {"file": "mill.glow.png", "blend": "add"},
			"anim": {"sheet": "mill.anim.png", "glow_sheet": "mill.anim.glow.png", "frames": 8, "columns": 4, "fps": 8.0,
				"mode": "replace", "rect": [10, 6, 20, 16], "cell": [10, 8], "cell_padding": 1}},
		"t_fence": {"file": "lantern.png", "anchor": [15, 28], "glow": {"file": "lantern.glow.png", "blend": "add"}},
		"t_fence_stone": {"file": "lantern.png", "anchor": [15, 28], "glow": {"file": "lantern.glow_bad.png"},
			"anim": {"sheet": "mill.anim.png", "frames": 8, "columns": 4, "fps": 8.0, "rect": [20, 20, 20, 16], "cell": [10, 8]}},
	})


func test_patch_anim_entry_is_parsed_and_sheet_loads_lazily() -> void:
	var lib := _patch_lib()
	var loads := lib.texture_loads
	var spr := lib.get_sprite("t_mystery")
	var a := spr.anim
	assert_not_null(a)
	assert_true(a.has_rect())
	assert_false(a.overlay, "a rect animation replaces part of the static image")
	assert_eq(a.rect, Rect2(10, 6, 20, 16))
	assert_eq(a.frame_size, Vector2(10, 8), "cell size from the entry")
	assert_eq(a.padding, 1)
	assert_true(a.has_glow)
	assert_eq(a.frame_rect(0), Rect2(1, 1, 10, 8), "cells skip their padding")
	assert_eq(a.frame_rect(5), Rect2(13, 11, 10, 8), "row 2, column 2")
	assert_eq(lib.texture_loads, loads + 2, "static + glow loaded, the sheets not yet")
	assert_not_null(a.sheet)
	assert_not_null(a.glow_sheet)
	assert_eq(lib.texture_loads, loads + 2, "sheets load outside the shared cache")
	var c := Vector2(100, 100)
	assert_eq(a.world_rect(c, false, spr.scale), Rect2(c + (Vector2(10, 6) - Vector2(30, 40)) * spr.scale, Vector2(20, 16) * spr.scale))
	var fl := a.world_rect(c, true, spr.scale)
	assert_true(absf(fl.position.x - (c.x - (10.0 + 20.0 - 30.0) * spr.scale)) < 0.001, "flipped about the anchor")
	assert_true(spr.world_rect(c, false).encloses(a.world_rect(c, false, spr.scale)), "the rect lies on the sprite")


func test_glow_layer_is_parsed_and_checked() -> void:
	var lib := _patch_lib()
	var g := lib.get_sprite("t_fence")
	assert_not_null(g.glow, "glow texture")
	assert_eq(g.glow.get_size(), g.texture.get_size())
	assert_null(g.anim)
	var bad := lib.get_sprite("t_fence_stone")
	assert_not_null(bad, "still draws")
	assert_null(bad.glow, "a glow of another size is refused")
	assert_null(bad.anim, "a rect outside the image is refused")
	var joined := "\n".join(lib.errors)
	assert_true(joined.contains("does not match the size"), joined)
	assert_true(joined.contains("Bad animation rect"), joined)
	var st := lib.pack_stats(AssetLibrary.BUILTIN_ID)
	assert_eq(st["glows"], 3)
	assert_false(st["missing_files"].has("mill.anim.glow.png"), "glow sheets are counted as pack files")


func test_renderer_draws_glow_on_an_additive_child_and_plays_patches() -> void:
	var db := fixture_db()
	var layout := FarmLayout.new()
	var mill: int = layout.add_objects([make_obj(db.get_item("t_mystery"), Vector2i(0, 0))], false)[0]
	var lantern: int = layout.add_objects([make_obj(db.get_item("t_fence"), Vector2i(6, 0))], false)[0]
	var plain: int = layout.add_objects([make_obj(db.get_item("t_path"), Vector2i(10, 0))], false)[0]
	var r := _renderer(layout, db, _patch_lib())
	var vm: ObjectRenderer.Vis = r._vis[mill]
	var vl: ObjectRenderer.Vis = r._vis[lantern]
	assert_true(vl.gci.is_valid(), "glow child canvas item")
	assert_false((r._vis[plain] as ObjectRenderer.Vis).gci.is_valid(), "no glow, no child")
	assert_not_null(r._add_mat)
	assert_eq(r._add_mat.blend_mode, CanvasItemMaterial.BLEND_MODE_ADD)
	assert_true(vm.gci.is_valid())
	assert_false(vm.aci.is_valid(), "a rect animation needs no overlay item")
	assert_eq(r.anim_frame_of(mill), -1, "static (= frame 0) until it is first seen")
	assert_eq(r.anim_memory()["sheets"], 0, "so no sheet is loaded yet")
	r.advance_anim(0.0, NOWHERE)
	assert_eq(r.anim_frame_of(mill), -1, "not in view: still static")
	r.advance_anim(0.0, VIEW)
	var f0: int = r.anim_frame_of(mill)
	assert_true(f0 >= 0, "in view: frames")
	assert_eq(r.anim_memory()["sheets"], 2, "sheet + glow sheet loaded on first sight")
	r.advance_anim(0.126, VIEW)
	assert_eq(r.anim_frame_of(mill), (f0 + 1) % 8, "8 fps")
	r.set_ambient_mode(ObjectRenderer.Ambient.OFF)
	assert_eq(r.anim_frame_of(mill), -1, "Off: static image")
	assert_true(vm.gci.is_valid(), "the static glow stays")
	var c := Iso.footprint_center(Vector2i.ZERO, layout.get_obj(mill).size)
	assert_eq(r.bounds_of(mill), vm.sprite.world_rect(c, false), "a rect inside the image adds no bounds")
	# the glow goes with its sprite
	layout.remove_objects([lantern])
	assert_false(vl.gci.is_valid(), "freed with the object")
	_dispose(r)
