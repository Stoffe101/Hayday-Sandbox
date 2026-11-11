extends RefCounted
## Builds a synthetic asset pack (.zip) at runtime that exercises the pack's
## glow layers and patch animations (docs/ASSET_PIPELINE.md "glow", "anim" with
## "rect") with flat-colour, procedurally drawn art (no artwork of any game):
##   garden_torch  a post with a flame: glow layer + a flickering flame patch with glow frames
##   windmill      a tower with four sails: a 12-frame patch over the sails at 2/3 resolution
##   lantern       a lamp post with a glow layer only
## Used by the "object_glow" visual scenario. Nothing is written into the project folder.

const PACK_ID := "synthetic_glow"
const PPW := 3.0
const TILE := Vector2(64.0, 32.0) * PPW   # one tile in texture px


static func _blank(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img


static func _disc(img: Image, c: Vector2, r: float, col: Color, soft := false) -> void:
	for y in range(maxi(0, floori(c.y - r)), mini(img.get_height(), ceili(c.y + r) + 1)):
		for x in range(maxi(0, floori(c.x - r)), mini(img.get_width(), ceili(c.x + r) + 1)):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / r
			if d > 1.0:
				continue
			var k := col
			if soft:
				k.a *= pow(1.0 - d, 1.6)
			_over(img, x, y, k)


static func _over(img: Image, x: int, y: int, c: Color) -> void:
	var d := img.get_pixel(x, y)
	var a := c.a + d.a * (1.0 - c.a)
	if a <= 0.0:
		return
	var rgb := (Vector3(c.r, c.g, c.b) * c.a + Vector3(d.r, d.g, d.b) * d.a * (1.0 - c.a)) / a
	img.set_pixel(x, y, Color(rgb.x, rgb.y, rgb.z, a))


static func _quad(img: Image, pts: PackedVector2Array, col: Color) -> void:
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	for y in range(maxi(0, floori(r.position.y)), mini(img.get_height(), ceili(r.end.y) + 1)):
		for x in range(maxi(0, floori(r.position.x)), mini(img.get_width(), ceili(r.end.x) + 1)):
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), pts):
				_over(img, x, y, col)


static func _base_diamond(img: Image, anchor: Vector2, col: Color) -> void:
	var h := TILE / 2.0 * 0.8
	_quad(img, PackedVector2Array([anchor + Vector2(0, -h.y), anchor + Vector2(h.x, 0), anchor + Vector2(0, h.y), anchor + Vector2(-h.x, 0)]), col)


# --- the three objects --------------------------------------------------------------------

static func torch(flame: float) -> Array:
	## [static image, glow image, anchor]; flame 0..1 = flicker phase.
	var w := 120
	var h := 260
	var anchor := Vector2(60, 230)
	var img := _blank(w, h)
	var glow := _blank(w, h)
	_base_diamond(img, anchor, Color(0.45, 0.42, 0.36))
	_quad(img, PackedVector2Array([Vector2(55, 90), Vector2(65, 90), Vector2(67, 232), Vector2(53, 232)]), Color(0.36, 0.24, 0.14))
	_quad(img, PackedVector2Array([Vector2(46, 78), Vector2(74, 78), Vector2(68, 94), Vector2(52, 94)]), Color(0.18, 0.16, 0.15))
	var fh := 26.0 + 10.0 * sin(flame * TAU)
	var fc := Vector2(60, 76 - fh * 0.5)
	_quad(img, PackedVector2Array([Vector2(50, 78), Vector2(60 + 4.0 * sin(flame * TAU * 2.0), 78 - fh), Vector2(70, 78)]), Color(1.0, 0.55, 0.12))
	_disc(img, fc + Vector2(0, 6), 6.0, Color(1.0, 0.85, 0.35))
	_disc(glow, fc, 46.0 + 8.0 * sin(flame * TAU), Color(1.0, 0.62, 0.22, 0.9), true)
	return [img, glow, anchor]


static func windmill(angle: float) -> Array:
	var w := 200
	var h := 300
	var anchor := Vector2(100, 268)
	var img := _blank(w, h)
	_base_diamond(img, anchor, Color(0.5, 0.47, 0.4))
	_quad(img, PackedVector2Array([Vector2(78, 120), Vector2(122, 120), Vector2(132, 270), Vector2(68, 270)]), Color(0.92, 0.9, 0.84))
	_quad(img, PackedVector2Array([Vector2(70, 120), Vector2(100, 92), Vector2(130, 120)]), Color(0.75, 0.2, 0.18))
	var hub := Vector2(100, 112)
	for k in 4:
		var a := angle + k * PI / 2.0
		var d := Vector2(cos(a), sin(a))
		var n := Vector2(-d.y, d.x)
		_quad(img, PackedVector2Array([hub + n * 3.0, hub + d * 84.0 + n * 14.0, hub + d * 84.0 - n * 2.0, hub - n * 3.0]), Color(0.98, 0.97, 0.93))
	_disc(img, hub, 7.0, Color(0.55, 0.15, 0.12))
	return [img, null, anchor]


static func lantern() -> Array:
	var w := 110
	var h := 230
	var anchor := Vector2(55, 205)
	var img := _blank(w, h)
	var glow := _blank(w, h)
	_base_diamond(img, anchor, Color(0.42, 0.42, 0.42))
	_quad(img, PackedVector2Array([Vector2(52, 70), Vector2(58, 70), Vector2(59, 207), Vector2(51, 207)]), Color(0.16, 0.17, 0.2))
	_quad(img, PackedVector2Array([Vector2(42, 48), Vector2(68, 48), Vector2(64, 72), Vector2(46, 72)]), Color(0.95, 0.85, 0.5))
	_disc(glow, Vector2(55, 60), 50.0, Color(1.0, 0.86, 0.45, 0.95), true)
	return [img, glow, anchor]


# --- sheets ---------------------------------------------------------------------------------

static func _sheet(frames: Array, rect: Rect2i, cell: Vector2i, pad: int, cols: int, glow: bool) -> Image:
	## Cells (rect of each frame image, resized to `cell`) with `pad` px of edge extrusion.
	var rows := ceili(float(frames.size()) / cols)
	var cw := cell.x + 2 * pad
	var ch := cell.y + 2 * pad
	var sheet := _blank(cols * cw, rows * ch)
	for i in frames.size():
		var src: Image = frames[i][1] if glow else frames[i][0]
		var c := src.get_region(rect)
		c.resize(cell.x, cell.y, Image.INTERPOLATE_BILINEAR)
		var ox := (i % cols) * cw
		var oy := (i / cols) * ch
		for y in ch:
			for x in cw:
				sheet.set_pixel(ox + x, oy + y, c.get_pixel(clampi(x - pad, 0, cell.x - 1), clampi(y - pad, 0, cell.y - 1)))
	return sheet


static func build_zip(zip_path: String) -> Dictionary:
	var out := {"ok": false, "zip": zip_path, "id": PACK_ID, "files": 0, "sprites": 0, "error": ""}
	var files := {}
	var sprites := {}
	# torch: glow + flickering flame patch (6 frames, full resolution, glow frames)
	var tf: Array = []
	for i in 6:
		tf.append(torch(i / 6.0))
	var trect := Rect2i(0, 0, 120, 130)   # the flame and every frame's glow
	files["items/garden_torch.png"] = (tf[0][0] as Image).save_png_to_buffer()
	files["items/garden_torch.glow.png"] = (tf[0][1] as Image).save_png_to_buffer()
	files["anims/garden_torch.png"] = _sheet(tf, trect, trect.size, 2, 3, false).save_png_to_buffer()
	files["anims/garden_torch.glow.png"] = _sheet(tf, trect, trect.size, 2, 3, true).save_png_to_buffer()
	sprites["garden_torch"] = {"file": "items/garden_torch.png", "anchor": [tf[0][2].x, tf[0][2].y],
		"glow": {"file": "items/garden_torch.glow.png", "blend": "add"},
		"anim": {"sheet": "anims/garden_torch.png", "glow_sheet": "anims/garden_torch.glow.png", "frames": 6, "columns": 3,
			"fps": 10.0, "mode": "replace", "rect": [trect.position.x, trect.position.y, trect.size.x, trect.size.y],
			"cell": [trect.size.x, trect.size.y], "cell_padding": 2}}
	# windmill: 12 frames of the sails at 2/3 resolution (a quarter turn: the sails are 4-fold symmetric)
	var wf: Array = []
	for i in 12:
		wf.append(windmill(i * (PI / 2.0) / 12.0))
	var wrect := Rect2i(0, 10, 200, 210)
	var wcell := Vector2i(134, 140)
	files["items/windmill.png"] = (wf[0][0] as Image).save_png_to_buffer()
	files["anims/windmill.png"] = _sheet(wf, wrect, wcell, 2, 4, false).save_png_to_buffer()
	sprites["windmill"] = {"file": "items/windmill.png", "anchor": [wf[0][2].x, wf[0][2].y],
		"anim": {"sheet": "anims/windmill.png", "frames": 12, "columns": 4, "fps": 12.0, "mode": "replace",
			"rect": [wrect.position.x, wrect.position.y, wrect.size.x, wrect.size.y], "cell": [wcell.x, wcell.y], "cell_padding": 2}}
	# lantern: glow only
	var lf := lantern()
	files["items/lantern.png"] = (lf[0] as Image).save_png_to_buffer()
	files["items/lantern.glow.png"] = (lf[1] as Image).save_png_to_buffer()
	sprites["lantern"] = {"file": "items/lantern.png", "anchor": [lf[2].x, lf[2].y],
		"glow": {"file": "items/lantern.glow.png", "blend": "add"}}
	var pack := {"format": AssetLibrary.PACK_FORMAT, "schema_version": 1, "id": PACK_ID, "name": "Synthetic glow + animation test pack",
		"version": "1.0-test", "license": "CC0-1.0 (procedural flat-colour shapes)",
		"provenance": {"source": "drawn at runtime by tests/fixtures/synthetic_glow_pack.gd"},
		"priority": 600, "pixels_per_world_px": PPW, "sprites": sprites}
	files["pack.json"] = JSON.stringify(pack, "  ").to_utf8_buffer()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(zip_path.get_base_dir()))
	var zp := ZIPPacker.new()
	var err := zp.open(zip_path)
	if err != OK:
		out["error"] = "cannot create zip: %s" % error_string(err)
		return out
	for rel in files:
		zp.start_file("%s/%s" % [PACK_ID, rel])
		zp.write_file(files[rel])
		zp.close_file()
	zp.close()
	out["ok"] = true
	out["files"] = files.size()
	out["sprites"] = sprites.size()
	return out
