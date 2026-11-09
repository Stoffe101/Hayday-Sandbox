class_name ReferenceLayer
extends Node2D
## Screenshots of the real farm, drawn in world space for tracing. A layout can
## hold several (FarmLayout.reference, see LayoutIO.normalize_reference): the
## list order is the stacking order, first = bottom, each with its own opacity,
## visibility and lock. Placement is a full affine transform so an image can be
## calibrated from point pairs (handles the game's own scale/ratio, not true
## perspective). The images are copied into user://references/ (never into the
## project).

const DIR := "user://references"

## The canonical document being shown. A private copy: move_by() previews a
## drag here, and the layout only changes when the gesture is committed.
var settings: Dictionary = {}
## Image the inspector edits and calibration applies to ("" = none).
var active_id := ""
var missing: Array[String] = []    ## files of listed images that could not be read
var _loaded: Dictionary = {}       ## file -> {"texture": Texture2D, "size": Vector2}


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
	if im.get("affine") is Array and (im["affine"] as Array).size() == 6:
		var a: Array = im["affine"]
		return Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))
	var sc := float(im.get("scale", 1.0))
	return Transform2D(deg_to_rad(float(im.get("rotation", 0.0))), Vector2(sc, sc), 0.0,
		Vector2(float(im.get("x", 0.0)), float(im.get("y", 0.0))))


func xform() -> Transform2D:
	return xform_of(active_image())


func apply() -> void:
	var any := false
	for im: Dictionary in images():
		any = any or (bool(im.get("visible", true)) and is_loaded(im))
	visible = any
	queue_redraw()


func _draw() -> void:
	for im: Dictionary in images():
		if not bool(im.get("visible", true)):
			continue
		var rec: Variant = _loaded.get(str(im.get("file", "")))
		if rec == null:
			continue
		draw_set_transform_matrix(xform_of(im))
		draw_texture(rec["texture"], Vector2.ZERO, Color(1, 1, 1, float(im.get("opacity", 0.5))))
	draw_set_transform_matrix(Transform2D.IDENTITY)


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
	## three (full affine). Returns [ax, ay, bx, by, ox, oy], or null if the
	## points are unusable.
	if img_pts.size() != world_pts.size():
		return null
	if img_pts.size() == 3:
		return solve_affine(img_pts, world_pts)
	if img_pts.size() != 2:
		return null
	var u1: Vector2 = img_pts[0]
	var u2: Vector2 = img_pts[1]
	var w1: Vector2 = world_pts[0]
	var w2: Vector2 = world_pts[1]
	if u1.distance_to(u2) < 1e-3 or w1.distance_to(w2) < 1e-3:
		return null
	# A third pair at a right angle on both sides pins the transform to a similarity.
	return solve_affine([u1, u2, u1 + (u2 - u1).orthogonal()], [w1, w2, w1 + (w2 - w1).orthogonal()])


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
