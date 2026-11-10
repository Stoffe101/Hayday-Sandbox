extends RefCounted
## Builds a synthetic terrain asset pack (docs/TERRAIN_PACKS.md) at runtime:
## flat colours, stripes, checkers and dots (clearly not game art) laid out on
## a given map. It exercises every part of the format: an atlas of tile
## textures with a seasonal variant (suffix rule and explicit "variants"),
## per-kind tile fallbacks, image pieces with transparency and "repeat", a
## textured cliff polygon, a river polygon with clip animations (glints), road
## polygons and a bridge beyond the grid, mesh pieces with colour-add ops, an
## animated sprite-sheet piece, a theme -> variant table and per-piece variant
## overrides, a foreground canopy drawn over the objects ("layer"), pieces
## with the add / multiply / screen blend modes, a mesh with both an add op and
## the add blend, and clip colour transforms (element add terms, an instance
## mul and add). Used by the unit tests and the "terrain_pack*" visual scenarios.
## Nothing is written into the project folder.
##
## Each tile texture has a small red square at its (u0, v0) corner: on screen
## it sits at the top corner of the diamond (u runs along +x, v along +y).

const PACK_ID := "synthetic_terrain"
const T := 64   ## tile texture size in the atlas (texels)
## Atlas cells (column, row) of the tile textures.
const CELLS := {"syn_grass": Vector2i(0, 0), "syn_plot": Vector2i(1, 0), "syn_locked": Vector2i(2, 0), "syn_road": Vector2i(3, 0),
	"syn_blocked": Vector2i(0, 1), "syn_grass_winter": Vector2i(1, 1), "syn_road_snow": Vector2i(2, 1), "glint": Vector2i(3, 1)}


# --- images --------------------------------------------------------------------------

static func _px(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, c)


static func _tile(img: Image, cell: Vector2i, base: Color, pattern: String, accent: Color) -> void:
	var o := cell * T
	for y in T:
		for x in T:
			var c := base
			match pattern:
				"stripes":
					if (x + y) % 12 < 3:
						c = accent
				"dots":
					if (x % 16 - 8) * (x % 16 - 8) + (y % 16 - 8) * (y % 16 - 8) < 10:
						c = accent
				"checker":
					if ((x / 8) + (y / 8)) % 2 == 0:
						c = accent
				"dashes":
					if y % 16 < 3 and x % 16 < 10:
						c = accent
				"hatch":
					if (x + y) % 10 < 2 or (x - y + 64) % 10 < 2:
						c = accent
				"glint":
					var d := absf(y - T * 0.5) / (T * 0.5)
					c = Color(1, 1, 1, clampf(1.0 - d, 0.0, 1.0))
			if pattern != "glint" and (x < 2 or y < 2 or x >= T - 2 or y >= T - 2):
				c = c.darkened(0.18)   # a thin frame shows the tile grid
			img.set_pixel(o.x + x, o.y + y, c)
	if pattern != "glint":
		for y in 6:
			for x in 6:
				img.set_pixel(o.x + 3 + x, o.y + 3 + y, Color(0.85, 0.1, 0.1))   # the (u0, v0) corner


static func atlas_image() -> Image:
	var img := Image.create(T * 4, T * 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_tile(img, CELLS["syn_grass"], Color("#6fae6a"), "stripes", Color("#82c07c"))
	_tile(img, CELLS["syn_plot"], Color("#8cc46e"), "dots", Color("#a7d98a"))
	_tile(img, CELLS["syn_locked"], Color("#7d8f78"), "checker", Color("#6d7e69"))
	_tile(img, CELLS["syn_road"], Color("#d7b98a"), "dashes", Color("#f2e6c8"))
	_tile(img, CELLS["syn_blocked"], Color("#8a9a5b"), "hatch", Color("#76854b"))
	_tile(img, CELLS["syn_grass_winter"], Color("#e6eef5"), "stripes", Color("#cfdbe8"))
	_tile(img, CELLS["syn_road_snow"], Color("#c9c3bb"), "dashes", Color("#f4f4f4"))
	_tile(img, CELLS["glint"], Color.WHITE, "glint", Color.WHITE)
	return img


static func forest_image() -> Image:
	## Round "tree" blobs on transparency (a hedge band, drawn with repeat).
	var img := Image.create(320, 200, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.4, 0.2, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 26:
		var cx := rng.randi_range(24, 296)
		var cy := rng.randi_range(40, 170)
		var r := rng.randi_range(18, 30)
		var col := Color("#2f6b45").lerp(Color("#4f8f3f"), rng.randf())
		for y in range(cy - r, cy + r):
			for x in range(cx - r, cx + r):
				var d := Vector2(x - cx, y - cy).length()
				if d < r:
					_px(img, x, y, col.lightened(0.25) if d < r * 0.45 and x < cx and y < cy else col)
	return img


static func cliff_image() -> Image:
	## Horizontal grey-brown strata with a green lip (repeats along the cliff).
	var img := Image.create(128, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 128:
			var c := Color("#8d7b68") if (y / 8) % 2 == 0 else Color("#a08e78")
			if y < 8:
				c = Color("#7fb35f")
			elif (x + y * 3) % 37 < 2:
				c = Color("#5e5044")
			img.set_pixel(x, y, c)
	return img


static func water_image() -> Image:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var wave := sin((x + y) * TAU / 32.0) * 3.0
			var c := Color("#3f8fc0")
			if absf(fposmod(y + wave, 16.0) - 8.0) < 1.0:
				c = Color("#7cc0e4")
			img.set_pixel(x, y, c)
	return img


static func beacon_sheet() -> Image:
	## 4 frames of 32x48: a grey pole with a head that changes colour.
	var img := Image.create(128, 48, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var heads: Array[Color] = [Color("#e53935"), Color("#fb8c00"), Color("#fdd835"), Color("#fb8c00")]
	for f in 4:
		var ox := f * 32
		for y in range(16, 48):
			for x in range(14, 18):
				img.set_pixel(ox + x, y, Color("#606060"))
		for y in range(2, 16):
			for x in range(8, 24):
				img.set_pixel(ox + x, y, heads[f])
	return img


static func canopy_image() -> Image:
	## A leafy canopy (green blobs, see-through holes): a foreground piece.
	var img := Image.create(256, 160, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.45, 0.2, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 40:
		var cx := rng.randi_range(20, 236)
		var cy := rng.randi_range(20, 120)
		var r := rng.randi_range(10, 22)
		var col := Color("#3e7f3a").lerp(Color("#79b552"), rng.randf())
		for y in range(cy - r, cy + r):
			for x in range(cx - r, cx + r):
				if Vector2(x - cx, y - cy).length() < r:
					_px(img, x, y, col)
	for y in range(110, 160):   # a trunk
		for x in range(120, 136):
			_px(img, x, y, Color("#6b4a2b"))
	return img


static func rays_image() -> Image:
	## Soft white light shafts on black-transparent: drawn with the add blend.
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var band := absf(sin((x + y * 0.5) * TAU / 40.0))
			var fade := clampf(1.0 - absf(y - 64.0) / 64.0, 0.0, 1.0)
			var a := band * fade * 0.8
			img.set_pixel(x, y, Color(1.0, 0.95, 0.7, a))
	return img


# --- data ----------------------------------------------------------------------------

static func _cell_rect(key: String) -> Array:
	var c: Vector2i = CELLS[key]
	return [c.x * T, c.y * T, T, T]


static func _river(m: FarmMap) -> Rect2i:
	for s in m.scenery:
		if str(s["kind"]) == "river":
			return s["rect"]
	return Rect2i(-5, 0, 4, m.size.y)


static func _roads(m: FarmMap) -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	for r in m.regions:
		if r["kind"] == FarmMap.Kind.ROAD:
			for rc in r["rects"]:
				if (rc as Rect2i).size.x >= (rc as Rect2i).size.y:
					out.append(rc)
	return out


static func mesh_data() -> Dictionary:
	## A 6-point star (world px around its anchor), textured with the plot
	## tile, half its triangles brightened through an add op.
	var pos: Array = []
	var uvs: Array = []
	var cols: Array = []
	var idx: Array = []
	var u0 := float(CELLS["syn_plot"].x * T) / (T * 4)
	var v0 := float(CELLS["syn_plot"].y * T) / (T * 2)
	pos.append_array([0.0, 0.0])
	uvs.append_array([u0 + 0.125 * 0.5, v0 + 0.5 * 0.5])
	cols.append_array([1.0, 1.0, 1.0, 1.0])
	for i in 12:
		var a := TAU * i / 12.0
		var r := 46.0 if i % 2 == 0 else 20.0
		pos.append_array([cos(a) * r, sin(a) * r * 0.5 - 6.0])
		uvs.append_array([u0 + 0.125 * (0.5 + cos(a) * 0.4), v0 + 0.5 * (0.5 + sin(a) * 0.4)])
		cols.append_array([0.9, 1.0, 0.9, 0.95])
	for i in 12:
		idx.append_array([0, 1 + i, 1 + (i + 1) % 12])
	return {"atlas": "tiles", "vertex_count": 13, "positions": pos, "uvs": uvs, "colors": cols, "indices": idx,
		"add_ops": [{"first_index": 0, "index_count": 18, "add_rgb": [0.25, 0.05, 0.0]}]}


static func clips_data() -> Dictionary:
	var g: Vector2i = CELLS["glint"]
	var u0 := float(g.x * T) / (T * 4)
	var v0 := float(g.y * T) / (T * 2)
	var u1 := u0 + 1.0 / 4.0
	var v1 := v0 + 1.0 / 2.0
	var frames: Array = []
	for f in 24:
		if f < 4:
			frames.append([])   # like the game's clips: the first frames are empty
			continue
		var t := float(f - 4) / 19.0
		var a := sin(t * PI) * 0.85
		# A warm colour-add term on every other frame (drawn by the add pass).
		var add := [0.3, 0.15, 0.0] if f % 2 == 0 else [0, 0, 0]
		frames.append([{"shape": "streak", "m": [1.0, 0.0, 0.0, 1.0, -20.0 + 40.0 * t, 0.0], "mul": [1.0, 1.0, 1.0, a], "add": add}])
	return {"shapes": {"streak": {"atlas": "tiles", "polygon_world": [[0, -3], [26, -6], [30, 0], [4, 3]],
			"uv": [[u0, v0], [u1, v0], [u1, v1], [u0, v1]]}},
		"clips": {"glint_a": {"fps": 12, "frame_count": 24, "frames": frames}}}


static func manifest(m: FarmMap, opts: Dictionary = {}) -> Dictionary:
	var wb := m.world_bounds if m.world_bounds.size != Vector2i.ZERO else Rect2i(Vector2i.ZERO, m.size)
	var river := _river(m)
	var tiles := {}
	for k in CELLS:
		if k != "glint":
			tiles[k] = {"atlas": "tiles", "rect_px": _cell_rect(k)}
	# Explicit variant (road) next to the suffix rule (syn_grass_winter).
	tiles["syn_road"]["variants"] = {"winter": {"atlas": "tiles", "rect_px": _cell_rect("syn_road_snow")}}
	# Art keys used by the unit-test world (tile_types[].art).
	tiles["grass"] = {"atlas": "tiles", "rect_px": _cell_rect("syn_grass")}
	tiles["path"] = {"atlas": "tiles", "rect_px": _cell_rect("syn_road")}
	var pieces: Array = []
	# North: a hedge band standing on the world's north edge (image + repeat).
	var n := ceili((wb.size.x + 12) / 6.0)
	pieces.append({"id": "north_hedge", "kind": "edge", "z": 1, "file": "pieces/hedge.png", "origin": [160, 190],
		"anchor_tile": [wb.position.x - 6, wb.position.y], "repeat": {"count": n, "step_tile": [6, 0]},
		"variants": {"winter": {"modulate": "#dfe9f5"}}})
	# A cliff face along the north edge of the grid (textured polygon).
	var cx0 := float(river.end.x)
	var cx1 := float(wb.end.x)
	var a := Iso.grid_to_world(Vector2(cx0, 0))
	var b := Iso.grid_to_world(Vector2(cx1, 0))
	pieces.append({"id": "cliff", "kind": "cliff", "z": 2, "anchor_tile": [cx0, 0],
		"polygon_world": [[0, 0], [b.x - a.x, b.y - a.y], [b.x - a.x, b.y - a.y - 34], [0, -34]],
		"texture": "pieces/cliff.png", "uv_world": 64})
	# The river through the whole world, with glints.
	var rv := Rect2i(river.position.x, wb.position.y - 30, river.size.x, wb.size.y + 60)
	var glints: Array = []
	for i in 8:
		var gp := Iso.grid_to_world(Vector2(river.position.x + river.size.x * (0.3 + 0.4 * (i % 2)), river.position.y + 3 + i * maxf(1.0, river.size.y / 8.0)))
		var g := {"clip": "glint_a", "x_axis": [0.89, -0.45], "y_axis": [0.88, 0.47], "origin_world": [gp.x, gp.y]}
		if i == 1:
			g["mul"] = [1.0, 0.7, 0.7, 1.0]   # an instance colour transform
			g["add"] = [0.0, 0.1, 0.3]
		glints.append(g)
	pieces.append({"id": "river", "kind": "river", "z": 3, "rect_tiles": [rv.position.x, rv.position.y, rv.size.x, rv.size.y],
		"color": "#ffffff", "texture": "pieces/water.png", "uv_world": 96, "clips": glints})
	# Roads beyond the grid (west across the river, east to the edge), and a bridge.
	for r in _roads(m):
		var west := wb.position.x - 40
		pieces.append({"id": "road_west", "kind": "road", "z": 4, "rect_tiles": [west, r.position.y, river.position.x - west, r.size.y], "color": "#cfae7c"})
		if river.end.x < 0:
			pieces.append({"id": "road_bank", "kind": "road", "z": 4, "rect_tiles": [river.end.x, r.position.y, -river.end.x, r.size.y], "color": "#cfae7c"})
		pieces.append({"id": "road_east", "kind": "road", "z": 4, "rect_tiles": [m.size.x, r.position.y, wb.end.x + 40 - m.size.x, r.size.y], "color": "#cfae7c"})
		pieces.append({"id": "bridge", "kind": "road", "z": 5, "rect_tiles": [river.position.x - 0.25, r.position.y + 0.4, river.size.x + 0.5, r.size.y - 0.8], "color": "#8a5a32"})
	# Star meshes along the south (mesh + colour-add ops).
	pieces.append({"id": "stars", "kind": "deco", "z": 6, "mesh": "mesh/star.mesh.json",
		"anchor_tile": [8, m.size.y + 2], "repeat": {"count": maxi(1, m.size.x / 16), "step_tile": [16, 0]}})
	# Animated beacons on the north edge (hidden in winter).
	pieces.append({"id": "beacon", "kind": "deco", "z": 7, "anim": {"sheet": "anim/beacon.png", "frames": 4, "columns": 4, "fps": 4},
		"origin": [16, 46], "scale": 1.0, "anchor_tile": [12, -1], "repeat": {"count": 3, "step_tile": [24, 0]},
		"variants": {"winter": {"hidden": true}}})
	# A tree canopy near the land's south-west corner, drawn over the objects.
	pieces.append({"id": "canopy", "kind": "deco", "layer": "foreground", "z": 8, "file": "pieces/canopy.png",
		"origin": [128, 150], "anchor_tile": [4, mini(31, m.size.y - 1)], "modulate": "#ffffffe6"})
	# Blend modes: light shafts (add) over the north-east land, a cloud shadow
	# (multiply) over the east land, a haze (screen) over the south-east land,
	# and a glowing star mesh (add op + add blend) beside the south road.
	pieces.append({"id": "rays", "kind": "deco", "layer": "foreground", "blend": "add", "z": 9, "file": "pieces/rays.png",
		"origin": [64, 64], "scale": 1.5, "anchor_tile": [m.size.x - 6, 6]})
	var e0 := Vector2(m.size.x - 12, m.size.y * 0.3)
	pieces.append({"id": "cloud_shadow", "kind": "deco", "blend": "multiply", "z": 9,
		"polygon_tiles": [[e0.x, e0.y], [e0.x + 8, e0.y - 1], [e0.x + 10, e0.y + 5], [e0.x + 3, e0.y + 8]], "color": "#5a6a9acc"})
	var h0 := Vector2(m.size.x - 12, m.size.y * 0.65)
	pieces.append({"id": "haze", "kind": "deco", "blend": "screen", "z": 9,
		"polygon_tiles": [[h0.x, h0.y], [h0.x + 9, h0.y], [h0.x + 9, h0.y + 6], [h0.x, h0.y + 6]], "color": "#6f4fa0b0"})
	pieces.append({"id": "star_glow", "kind": "deco", "blend": 8, "z": 6, "mesh": "mesh/star.mesh.json",
		"anchor_tile": [m.size.x - 4, m.size.y + 2]})
	if bool(opts.get("bad_piece", false)):
		pieces.append({"id": "lost", "kind": "edge", "file": "pieces/does_not_exist.png", "anchor_tile": [0, 0]})
	var maps: Array = opts.get("maps", [m.id])
	return {"format": TerrainPack.FORMAT, "schema_version": 1, "id": PACK_ID, "name": "Synthetic terrain (generated, test only)",
		"frame": "game_tile", "maps": maps, "base": str(opts.get("base", "color")), "background_color": "#4d7d68",
		"scatter": false, "land_edge": false, "pixels_per_world_px": 1.0,
		"atlases": {"tiles": {"file": "atlas/tiles.png"}},
		"tiles": tiles,
		"kind_tiles": {"buildable": "syn_grass", "plot": "syn_plot", "plot_locked": "syn_locked", "road": "syn_road", "blocked": "syn_blocked"},
		"themes": {"winter": "winter", "christmas": "winter"},
		"variants": {"winter": {"background_color": "#b9cbd6"}},
		"pieces": pieces,
		"clips": "clips/glints.json"}


static func files_for(m: FarmMap, opts: Dictionary = {}) -> Dictionary:
	## Pack-relative path -> PackedByteArray (pack.json at the root, terrain/ below).
	var out := {}
	out["terrain/atlas/tiles.png"] = atlas_image().save_png_to_buffer()
	out["terrain/pieces/hedge.png"] = forest_image().save_png_to_buffer()
	out["terrain/pieces/cliff.png"] = cliff_image().save_png_to_buffer()
	out["terrain/pieces/water.png"] = water_image().save_png_to_buffer()
	out["terrain/anim/beacon.png"] = beacon_sheet().save_png_to_buffer()
	out["terrain/pieces/canopy.png"] = canopy_image().save_png_to_buffer()
	out["terrain/pieces/rays.png"] = rays_image().save_png_to_buffer()
	out["terrain/mesh/star.mesh.json"] = JSON.stringify(mesh_data()).to_utf8_buffer()
	out["terrain/clips/glints.json"] = JSON.stringify(clips_data()).to_utf8_buffer()
	out["terrain/terrain.json"] = JSON.stringify(manifest(m, opts), "  ").to_utf8_buffer()
	for rel in opts.get("omit", []):
		out.erase(rel)
	var pack := {"format": AssetLibrary.PACK_FORMAT, "schema_version": 1, "id": str(opts.get("id", PACK_ID)),
		"name": "Synthetic terrain pack", "version": "1.0-test", "license": "CC0-1.0 (generated at runtime)",
		"provenance": {"source": "generated flat colours and patterns", "generator": "tests/fixtures/synthetic_terrain.gd"},
		"priority": 400, "sprites": {}, "terrain": "terrain/terrain.json"}
	out["pack.json"] = JSON.stringify(pack, "  ").to_utf8_buffer()
	return out


static func write_dir(dir: String, m: FarmMap, opts: Dictionary = {}) -> Dictionary:
	## Writes the pack into dir (e.g. user://asset_packs/synthetic_terrain).
	var files := files_for(m, opts)
	for rel: String in files:
		var path := dir.path_join(rel)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return {"ok": false, "error": "cannot write %s" % path}
		f.store_buffer(files[rel])
		f.close()
	return {"ok": true, "files": files.size()}


static func build_zip(zip_path: String, m: FarmMap, opts: Dictionary = {}) -> Dictionary:
	var files := files_for(m, opts)
	var abs_dir := ProjectSettings.globalize_path(zip_path.get_base_dir()) if zip_path.begins_with("user://") else zip_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var zp := ZIPPacker.new()
	var err := zp.open(zip_path)
	if err != OK:
		return {"ok": false, "error": "cannot create zip: %s" % error_string(err)}
	for rel: String in files:
		zp.start_file("%s/%s" % [PACK_ID, rel])
		zp.write_file(files[rel])
		zp.close_file()
	zp.close()
	return {"ok": true, "zip": zip_path, "files": files.size()}
