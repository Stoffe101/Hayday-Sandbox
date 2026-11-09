class_name ReferenceLayer
extends Node2D
## A screenshot of the real farm, drawn in world space for tracing.
## Placement is a full affine transform so it can be calibrated from three
## point pairs (handles the game's own scale/ratio, not true perspective).
## Settings persist in FarmLayout.reference; the image itself is copied into
## user://references/ (never into the project).

const DIR := "user://references"

var texture: Texture2D
var settings: Dictionary = {}
var image_size := Vector2.ZERO


func load_from_settings(s: Dictionary) -> bool:
	settings = s
	texture = null
	var f := str(s.get("file", ""))
	if f.is_empty():
		visible = false
		return false
	var img := Image.load_from_file(ProjectSettings.globalize_path(f))
	if img == null or img.is_empty():
		visible = false
		return false
	img.generate_mipmaps()
	texture = ImageTexture.create_from_image(img)
	image_size = Vector2(img.get_size())
	apply()
	return true


static func import_image(src: String, layout_id: String) -> String:
	## Copies an external screenshot into the user data folder. Returns the
	## user:// path, or "" on failure.
	DirAccess.make_dir_recursive_absolute(DIR)
	var img := Image.load_from_file(src)
	if img == null or img.is_empty():
		return ""
	var dst := DIR.path_join("%s_%d.png" % [layout_id, Time.get_unix_time_from_system()])
	if img.save_png(dst) != OK:
		return ""
	return dst


func default_settings(file: String, world_center: Vector2, world_width: float) -> Dictionary:
	var img := Image.load_from_file(ProjectSettings.globalize_path(file))
	var sz := Vector2(img.get_size()) if img else Vector2(1000, 1000)
	var sc := world_width / maxf(1.0, sz.x)
	return {"file": file, "opacity": 0.5, "visible": true, "locked": false, "above": false,
		"x": world_center.x - sz.x * sc * 0.5, "y": world_center.y - sz.y * sc * 0.5, "scale": sc, "rotation": 0.0}


func xform() -> Transform2D:
	if settings.has("affine"):
		var a: Array = settings["affine"]
		return Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))
	var sc := float(settings.get("scale", 1.0))
	return Transform2D(deg_to_rad(float(settings.get("rotation", 0.0))), Vector2(sc, sc), 0.0,
		Vector2(float(settings.get("x", 0.0)), float(settings.get("y", 0.0))))


func apply() -> void:
	visible = texture != null and bool(settings.get("visible", true))
	modulate.a = float(settings.get("opacity", 0.5))
	queue_redraw()


func _draw() -> void:
	if texture == null:
		return
	draw_set_transform_matrix(xform())
	draw_texture(texture, Vector2.ZERO)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func world_to_image(w: Vector2) -> Vector2:
	return xform().affine_inverse() * w


func move_by(delta: Vector2) -> void:
	if settings.has("affine"):
		var a: Array = settings["affine"]
		a[4] += delta.x
		a[5] += delta.y
	else:
		settings["x"] = float(settings.get("x", 0.0)) + delta.x
		settings["y"] = float(settings.get("y", 0.0)) + delta.y
	queue_redraw()


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
