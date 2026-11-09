class_name FarmCamera
extends Camera2D
## Pan / zoom-at-cursor camera with smooth zoom and fit-to-rect.
## `limits` keeps the centre of the visible canvas inside the farm world
## (FarmMap.world_bounds, set by main.gd), so the farm can't be lost off
## screen; `home` is the world point "Home" returns to (the farmhouse).

signal view_changed

const MIN_ZOOM := 0.12
const MAX_ZOOM := 4.0

var target_zoom := 1.0
var _zoom_anchor_screen := Vector2.ZERO
var _zoom_anchor_world := Vector2.ZERO
var smooth := true
## Visible canvas region in viewport coordinates (excludes floating panels).
var view_rect := Rect2()
## World-px rectangle the centre of view_rect is kept inside (empty = no limit).
var limits := Rect2()
## World point Home (Home key / Shift+H / dock button) centres on.
var home := Vector2.ZERO
const HOME_ZOOM := 1.0


func _ready() -> void:
	zoom = Vector2.ONE
	target_zoom = 1.0
	position_smoothing_enabled = false


func current_zoom() -> float:
	return zoom.x


func screen_to_world(p: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * p


func world_to_screen(p: Vector2) -> Vector2:
	return get_canvas_transform() * p


func zoom_at(screen_pos: Vector2, factor: float) -> void:
	target_zoom = clampf(target_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	_zoom_anchor_screen = screen_pos
	_zoom_anchor_world = screen_to_world(screen_pos)
	if not smooth:
		_apply_zoom(target_zoom)


func set_zoom_level(z: float, screen_pos: Variant = null) -> void:
	var sp: Vector2 = screen_pos if screen_pos != null else _viewport_center()
	target_zoom = clampf(z, MIN_ZOOM, MAX_ZOOM)
	_zoom_anchor_screen = sp
	_zoom_anchor_world = screen_to_world(sp)
	if not smooth:
		_apply_zoom(target_zoom)


func _apply_zoom(z: float) -> void:
	zoom = Vector2(z, z)
	# Keep the anchored world point under the same screen point.
	force_update_scroll()
	var now := screen_to_world(_zoom_anchor_screen)
	position += _zoom_anchor_world - now
	_clamp()
	force_update_scroll()
	view_changed.emit()


func _process(dt: float) -> void:
	if absf(zoom.x - target_zoom) > 0.0005:
		var z := lerpf(zoom.x, target_zoom, 1.0 - exp(-dt * 18.0))
		if absf(z - target_zoom) < 0.001:
			z = target_zoom
		_apply_zoom(z)


func pan_screen(delta: Vector2) -> void:
	position -= delta / zoom.x
	_clamp()
	view_changed.emit()


func center_on(world: Vector2) -> void:
	## Centres `world` inside view_rect (not the full window).
	var vr := _view()
	var vp_center := get_viewport_rect().size * 0.5
	var offset_screen := vr.get_center() - vp_center
	position = world - offset_screen / zoom.x
	_clamp()
	force_update_scroll()
	view_changed.emit()


func fit_world_rect(r: Rect2, margin: float = 40.0) -> void:
	var vr := _view()
	var zx := (vr.size.x - margin * 2) / maxf(1.0, r.size.x)
	var zy := (vr.size.y - margin * 2) / maxf(1.0, r.size.y)
	var z := clampf(minf(zx, zy), MIN_ZOOM, MAX_ZOOM)
	zoom = Vector2(z, z)
	target_zoom = z
	center_on(r.get_center())


func set_limits(r: Rect2) -> void:
	## Keep the view centre inside `r` (world px); Rect2() removes the limit.
	limits = r
	if _clamp():
		force_update_scroll()
		view_changed.emit()


func view_center() -> Vector2:
	## World point at the centre of view_rect (independent of force_update_scroll).
	var off := (_view().get_center() - get_viewport_rect().size * 0.5) / maxf(zoom.x, 0.0001)
	return position + off


func _clamp() -> bool:
	## Moves the camera so the view centre lies inside `limits`. True if it moved.
	if limits.size.x <= 0.0 or limits.size.y <= 0.0:
		return false
	var c := view_center()
	var cc := Vector2(clampf(c.x, limits.position.x, limits.end.x), clampf(c.y, limits.position.y, limits.end.y))
	if cc.is_equal_approx(c):
		return false
	position += cc - c
	return true


func go_home(z: float = HOME_ZOOM) -> void:
	## Centres `home` at zoom z (immediately; no smooth zoom).
	z = clampf(z, MIN_ZOOM, MAX_ZOOM)
	zoom = Vector2(z, z)
	target_zoom = z
	center_on(home)


func _view() -> Rect2:
	if view_rect.size.x > 10 and view_rect.size.y > 10:
		return view_rect
	return get_viewport_rect()


func _viewport_center() -> Vector2:
	return _view().get_center()


func visible_world_rect() -> Rect2:
	var vr := get_viewport_rect()
	var a := screen_to_world(vr.position)
	var b := screen_to_world(vr.end)
	return Rect2(a, b - a)
