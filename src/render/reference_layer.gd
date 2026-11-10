class_name ReferenceLayer
extends Node2D
## Screenshots of the real farm, drawn in world space for tracing. A layout can
## hold several (FarmLayout.reference, see LayoutIO.normalize_reference): the
## list order is the stacking order, first = bottom, each with its own opacity,
## visibility and lock. Placement is a full affine transform so an image can be
## calibrated from point pairs (handles the game's own scale/ratio, not true
## perspective). Each image keeps its own calibration record ("calibration":
## points in image px + grid, the fit and its errors, see CalibrationMath); the
## active image's points and residual vectors are drawn on the canvas, and an
## image's "grid" flag draws the tile grid through it. The images are copied
## into user://references/ (never into the project).

const DIR := "user://references"

## The canonical document being shown. A private copy: move_by() previews a
## drag here, and the layout only changes when the gesture is committed.
var settings: Dictionary = {}
## Image the inspector edits and calibration applies to ("" = none).
var active_id := ""
var missing: Array[String] = []    ## files of listed images that could not be read
## Draw the active image's calibration points, residual vectors and errors
## (view setting, not part of the document). Each image's own "grid" flag
## draws the tile grid through that screenshot.
var show_calibration := true
var _loaded: Dictionary = {}       ## file -> {"texture": Texture2D, "size": Vector2}
var _drawn_zoom := 1.0

const C_GOOD := Color(0.35, 0.9, 0.45)
const C_FAIR := Color(1.0, 0.8, 0.25)
const C_POOR := Color(1.0, 0.35, 0.35)
const C_APPROX := Color(1.0, 0.55, 0.15)


func images() -> Array:
	return settings.get("images", [])


func load_from_settings(s: Dictionary) -> bool:
	## Shows a reference document; only files not loaded yet are read, so sliders
	## stay smooth. True when at least one image is available.
	settings = LayoutIO.normalize_reference(s)
	missing.clear()
	var keep := {}
	for im: Dictionary in images():
		var f := str(im.get("file", ""))
		if f.is_empty():
			continue
		keep[f] = true
		if not _loaded.has(f):
			var rec := _read(f)
			if rec.is_empty():
				missing.append(f)
				continue
			_loaded[f] = rec
	for f in _loaded.keys():
		if not keep.has(f):
			_loaded.erase(f)
	if image_by_id(settings, active_id).is_empty():
		active_id = str(images()[-1].get("id", "")) if not images().is_empty() else ""
	apply()
	return not _loaded.is_empty()


static func _read(file: String) -> Dictionary:
	var img := Image.load_from_file(ProjectSettings.globalize_path(file))
	if img == null or img.is_empty():
		return {}
	var size := Vector2(img.get_size())
	img.generate_mipmaps()
	return {"texture": ImageTexture.create_from_image(img), "size": size}


static func import_image(src: String, layout_id: String) -> String:
	## Copies an external screenshot into the user data folder. Returns the
	## user:// path, or "" on failure.
	DirAccess.make_dir_recursive_absolute(DIR)
	var img := Image.load_from_file(src)
	if img == null or img.is_empty():
		return ""
	var dst := DIR.path_join("%s_%d_%d.png" % [layout_id, Time.get_unix_time_from_system(), Time.get_ticks_usec()])
	if img.save_png(dst) != OK:
		return ""
	return dst


static func default_image(file: String, world_center: Vector2, world_width: float) -> Dictionary:
	## Settings of a new image: centred on `world_center`, `world_width` wide.
	var img := Image.load_from_file(ProjectSettings.globalize_path(file))
	var sz := Vector2(img.get_size()) if img else Vector2(1000, 1000)
	var sc := world_width / maxf(1.0, sz.x)
	return {"file": file, "name": file.get_file().get_basename(), "opacity": 0.5, "visible": true, "locked": false,
		"x": world_center.x - sz.x * sc * 0.5, "y": world_center.y - sz.y * sc * 0.5, "scale": sc, "rotation": 0.0}


static func image_by_id(doc: Dictionary, id: String) -> Dictionary:
	## The image's dictionary in `doc` (not a copy), {} when there is none.
	for im: Dictionary in doc.get("images", []):
		if str(im.get("id", "")) == id:
			return im
	return {}


static func new_id(doc: Dictionary) -> String:
	var n := 1
	while not image_by_id(doc, "r%d" % n).is_empty():
		n += 1
	return "r%d" % n


func active_image() -> Dictionary:
	return image_by_id(settings, active_id)


func is_loaded(im: Dictionary) -> bool:
	return _loaded.has(str(im.get("file", "")))


static func xform_of(im: Dictionary) -> Transform2D:
	## Image px -> world px ("affine" wins over x/y/scale/rotation).
	return CalibrationMath.image_xform(im)


func xform() -> Transform2D:
	return xform_of(active_image())


func apply() -> void:
	var any := false
	for im: Dictionary in images():
		any = any or (bool(im.get("visible", true)) and is_loaded(im))
	visible = any
	set_process(any and _needs_zoom_redraw())
	queue_redraw()


func set_show_calibration(on: bool) -> void:
	## Residual vectors and per-point errors of the active image (view setting).
	show_calibration = on
	apply()


func _needs_zoom_redraw() -> bool:
	## Markers, labels and grid lines keep a constant screen size, so they are
	## redrawn when the zoom changes (only while something like that is shown).
	if show_calibration and not CalibrationMath.record_of(active_image()).is_empty():
		return true
	for im: Dictionary in images():
		if bool(im.get("grid", false)) and bool(im.get("visible", true)):
			return true
	return false


func _process(_dt: float) -> void:
	var z := _zoom()
	if not is_equal_approx(z, _drawn_zoom):
		queue_redraw()


func _zoom() -> float:
	return maxf(0.02, get_canvas_transform().get_scale().x) if is_inside_tree() else 1.0


func _draw() -> void:
	_drawn_zoom = _zoom()
	for im: Dictionary in images():
		if not bool(im.get("visible", true)):
			continue
		var rec: Variant = _loaded.get(str(im.get("file", "")))
		if rec == null:
			continue
		draw_set_transform_matrix(xform_of(im))
		draw_texture(rec["texture"], Vector2.ZERO, Color(1, 1, 1, float(im.get("opacity", 0.5))))
	draw_set_transform_matrix(Transform2D.IDENTITY)
	for im: Dictionary in images():
		if bool(im.get("grid", false)) and bool(im.get("visible", true)) and _loaded.has(str(im.get("file", ""))):
			_draw_grid_on(im, _loaded[str(im["file"])]["size"])
	if show_calibration:
		_draw_calibration(active_image())


static func image_quad(im: Dictionary, size: Vector2) -> PackedVector2Array:
	## World polygon of an image's rectangle under its transform.
	var xf := xform_of(im)
	return PackedVector2Array([xf * Vector2.ZERO, xf * Vector2(size.x, 0.0), xf * size, xf * Vector2(0.0, size.y)])


static func grid_lines_in(quad: PackedVector2Array, max_lines: int = 600) -> PackedVector2Array:
	## Tile-edge segments (pairs of world points) clipped to a convex world
	## polygon: the grid drawn through a screenshot. Empty when the polygon
	## would need more than max_lines lines per axis.
	var out := PackedVector2Array()
	if quad.size() < 3:
		return out
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in quad:
		var g := Iso.world_to_grid(p)
		lo = lo.min(g)
		hi = hi.max(g)
	var x0 := floori(lo.x)
	var x1 := ceili(hi.x)
	var y0 := floori(lo.y)
	var y1 := ceili(hi.y)
	if x1 - x0 > max_lines or y1 - y0 > max_lines:
		return out
	for x in range(x0, x1 + 1):
		_clip_into(out, Iso.grid_to_world(Vector2(x, y0)), Iso.grid_to_world(Vector2(x, y1)), quad)
	for y in range(y0, y1 + 1):
		_clip_into(out, Iso.grid_to_world(Vector2(x0, y)), Iso.grid_to_world(Vector2(x1, y)), quad)
	return out


static func _clip_into(out: PackedVector2Array, a: Vector2, b: Vector2, quad: PackedVector2Array) -> void:
	for seg: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([a, b]), quad):
		for i in range(seg.size() - 1):
			out.append(seg[i])
			out.append(seg[i + 1])


func _draw_grid_on(im: Dictionary, size: Vector2) -> void:
	var segs := grid_lines_in(image_quad(im, size))
	if segs.is_empty():
		return
	var z := _drawn_zoom
	var a := clampf(0.25 + float(im.get("opacity", 0.5)) * 0.5, 0.3, 0.8)
	draw_multiline(segs, Color(0.05, 0.08, 0.1, a * 0.6), 2.2 / z)
	draw_multiline(segs, Color(1.0, 0.95, 0.55, a), 1.0 / z)


func _draw_calibration(im: Dictionary) -> void:
	## For each stored point: the true grid point (ring), where its clicked
	## screenshot pixel lies now (dot), the residual vector between them and an
	## "#n 0.12 t" label. Approximate landmark anchors are drawn hollow orange.
	var live := CalibrationMath.live_residuals(im)
	if live.is_empty():
		return
	var z := _drawn_zoom
	var font := ThemeDB.fallback_font
	var fs := 13
	for r: Dictionary in live:
		var wg: Vector2 = r["world_grid"]
		var wi: Vector2 = r["world_img"]
		var t := float(r["tiles"])
		var col := C_GOOD if t < CalibrationMath.GOOD_MAX_TILES else (C_FAIR if t < CalibrationMath.FAIR_MAX_TILES else C_POOR)
		if bool(r["approximate"]):
			col = C_APPROX
		draw_line(wg, wi, Color(0, 0, 0, 0.55), 3.5 / z)
		draw_line(wg, wi, col, 1.8 / z)
		draw_arc(wg, 7.0 / z, 0.0, TAU, 20, Color(0, 0, 0, 0.6), 3.0 / z)
		draw_arc(wg, 7.0 / z, 0.0, TAU, 20, col, 1.6 / z)
		draw_circle(wi, 3.2 / z, col)
		var txt := "#%d  %.2f t" % [int(r["index"]) + 1, t]
		if not str(r["landmark"]).is_empty():
			txt += "  %s%s" % [str(r["landmark"]), " (approx.)" if bool(r["approximate"]) else ""]
		draw_set_transform(wg + Vector2(10.0, -8.0) / z, 0.0, Vector2.ONE / z)
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_rect(Rect2(Vector2(-4, -fs - 2), Vector2(w + 8, fs + 8)), Color(0.06, 0.08, 0.1, 0.72))
		draw_string(font, Vector2(0, 0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func world_to_image(w: Vector2) -> Vector2:
	return xform().affine_inverse() * w


func move_by(delta: Vector2) -> void:
	## Live preview of a drag of the active image (committed as one command).
	var im := active_image()
	if im.is_empty():
		return
	if im.get("affine") is Array:
		var a: Array = im["affine"]
		a[4] += delta.x
		a[5] += delta.y
	else:
		im["x"] = float(im.get("x", 0.0)) + delta.x
		im["y"] = float(im.get("y", 0.0)) + delta.y
	queue_redraw()


static func solve_calibration(img_pts: Array, world_pts: Array) -> Variant:
	## Transform from two point pairs (position, rotation, uniform scale) or
	## more (least-squares affine, CalibrationMath.fit). Returns
	## [ax, ay, bx, by, ox, oy] (image px -> world px), or null if the points are
	## unusable.
	if img_pts.size() != world_pts.size() or img_pts.size() < 2:
		return null
	var f := CalibrationMath.fit(calibration_points(img_pts, world_pts))
	return f["image_to_world"] if bool(f["ok"]) else null


static func calibration_points(img_pts: Array, world_pts: Array) -> Array:
	## Point records (CalibrationMath.make_point) from image px and world px lists.
	var out: Array = []
	for i in mini(img_pts.size(), world_pts.size()):
		out.append(CalibrationMath.make_point(img_pts[i], Iso.world_to_grid(world_pts[i])))
	return out


static func solve_affine(img_pts: Array, world_pts: Array) -> Variant:
	## Affine transform mapping three image points onto three world points.
	## Returns [ax, ay, bx, by, ox, oy] or null if the points are degenerate.
	var u1: Vector2 = img_pts[0]
	var u2: Vector2 = img_pts[1]
	var u3: Vector2 = img_pts[2]
	var w1: Vector2 = world_pts[0]
	var w2: Vector2 = world_pts[1]
	var w3: Vector2 = world_pts[2]
	var d1 := u2 - u1
	var d2 := u3 - u1
	var det := d1.x * d2.y - d1.y * d2.x
	if absf(det) < 1e-6:
		return null
	var e1 := w2 - w1
	var e2 := w3 - w1
	# Solve [x_axis y_axis] * [d1 d2] = [e1 e2]
	var inv := Transform2D(Vector2(d2.y, -d1.y) / det, Vector2(-d2.x, d1.x) / det, Vector2.ZERO)
	var x_axis := e1 * inv.x.x + e2 * inv.x.y
	var y_axis := e1 * inv.y.x + e2 * inv.y.y
	var origin := w1 - x_axis * u1.x - y_axis * u1.y
	return [x_axis.x, x_axis.y, y_axis.x, y_axis.y, origin.x, origin.y]
