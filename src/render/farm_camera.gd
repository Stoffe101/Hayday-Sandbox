class_name FarmCamera
extends Camera2D
## Pan / zoom-at-cursor camera. The motion itself is CameraMath.State; this node
## feeds it input, steps it every frame and copies the result to the Camera2D.
##
## Two paths on purpose:
## * animated: zoom_at, set_zoom_level, fly_to, fly_to_rect, fly_home, pan with
##   inertia (all immediate when `smooth` is false);
## * immediate, always: center_on, fit_world_rect, go_home, restore.
##
## `limits` keeps the centre of the visible canvas inside the world
## (FarmMap.world_bounds + LIMIT_MARGIN, set by main.gd) with a rubber band while
## animating. `home` is the world point "Home" returns to (the farmhouse).

signal view_changed

## Zoom-out limit when no world is known; with one, min_zoom comes from fitting it.
const MIN_ZOOM := 0.12
const ABS_MIN_ZOOM := 0.02
const MAX_ZOOM := 4.0
const HOME_ZOOM := 1.0
const LIMIT_MARGIN := 128.0
## min_zoom = this share of the zoom that fits the whole world.
const WORLD_FIT_SHARE := 0.9

var smooth := true:
	set(v):
		if v == smooth:
			return
		smooth = v
		_m.soft = v
		if not v and is_inside_tree():
			_adopt_external()
			_m.settle()
			_write()
## Wheel notch zoom factor (settings: "wheel_zoom_factor").
var wheel_factor := 1.15
## Visible canvas region in viewport coordinates (excludes floating panels).
var view_rect := Rect2()
## World-px rectangle the centre of view_rect is kept inside (empty = no limit).
var limits := Rect2():
	set(r):
		limits = r
		_m.limits = r
var min_zoom := MIN_ZOOM
## World point Home (Home key / H / dock button) centres on.
var home := Vector2.ZERO
var target_zoom: float:
	get:
		return exp(_m.target_log_z)
	set(v):
		_m.target_log_z = _m.clamp_log_z(log(maxf(v, 0.0001)))

var _m := CameraMath.State.new()
var _tracker := CameraMath.PanTracker.new()
var _world_rect := Rect2()
var _fit_view_size := Vector2.ZERO
var _shown_pos := Vector2.ZERO
var _shown_z := 1.0


func _ready() -> void:
	zoom = Vector2.ONE
	position_smoothing_enabled = false
	_m.soft = smooth
	_m.reset(position, 1.0)
	_shown_pos = position
	_shown_z = zoom.x


func current_zoom() -> float:
	return zoom.x


func screen_to_world(p: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * p


func world_to_screen(p: Vector2) -> Vector2:
	return get_canvas_transform() * p


# --- keeping the state in step with the node ------------------------------------------

func _adopt_external() -> void:
	## Someone wrote position / zoom directly: that is the view now.
	if position != _shown_pos or zoom.x != _shown_z:
		_m.reset(position, zoom.x)
		_shown_pos = position
		_shown_z = zoom.x


func _sync_view() -> void:
	var vr := _view()
	_m.view_off = vr.get_center() - get_viewport_rect().size * 0.5
	_m.view_size = vr.size
	if vr.size != _fit_view_size:
		_update_min_zoom()


func _begin_op() -> void:
	_adopt_external()
	_sync_view()


func _update_min_zoom() -> void:
	var vr := _view()
	_fit_view_size = vr.size
	if _world_rect.size.x > 0.0 and _world_rect.size.y > 0.0:
		min_zoom = clampf(CameraMath.fit_zoom(vr.size, _world_rect.size) * WORLD_FIT_SHARE, ABS_MIN_ZOOM, MAX_ZOOM)
	else:
		min_zoom = MIN_ZOOM
	_m.min_log_z = log(min_zoom)
	_m.max_log_z = log(MAX_ZOOM)


func _write() -> void:
	## Shows the state; force_update_scroll keeps screen_to_world correct at once.
	position = _m.shown_pos()
	zoom = Vector2.ONE * _m.zoom()
	_shown_pos = position
	_shown_z = zoom.x
	force_update_scroll()
	view_changed.emit()


func _process(dt: float) -> void:
	_adopt_external()
	if not _m.is_animating():
		return
	_sync_view()
	if _m.step(dt):
		_write()


func is_animating() -> bool:
	return _m.is_animating()


# --- animated (immediate when smooth is off) ------------------------------------------

func zoom_at(screen_pos: Vector2, factor: float) -> void:
	_zoom_about(screen_pos, _m.target_log_z + log(maxf(factor, 0.0001)))


func set_zoom_level(z: float, screen_pos: Variant = null) -> void:
	var sp: Vector2 = screen_pos if screen_pos != null else _viewport_center()
	_zoom_about(sp, log(maxf(z, 0.0001)))


func _zoom_about(screen_pos: Vector2, new_log: float) -> void:
	_begin_op()
	force_update_scroll()
	# Measured through the canvas transform so any canvas scale is included.
	var off := (screen_to_world(screen_pos) - position) * zoom.x
	_m.zoom_about(off, new_log)
	if not smooth:
		_write()


func wheel_zoom(screen_pos: Vector2, notches: float) -> void:
	## notches > 0 zooms in (fractions come from high-precision wheels).
	zoom_at(screen_pos, pow(wheel_factor, notches))


func pan_screen(delta: Vector2) -> void:
	_begin_op()
	if _m.held:
		_tracker.add(delta, Time.get_ticks_msec())
	_m.pan_world(-delta / zoom.x)
	_write()


func pan_world(d: Vector2) -> void:
	_begin_op()
	_m.pan_world(d)
	_write()


func begin_user_pan() -> void:
	_begin_op()
	_tracker.clear()
	_m.begin_hold()


func end_user_pan() -> void:
	## Pointer released: the view coasts on if it was moving fast enough.
	_m.end_hold(_tracker.velocity(Time.get_ticks_msec()) if smooth else Vector2.ZERO)
	_tracker.clear()


func stop_motion() -> void:
	## A press on the canvas: stop coasting so nothing slides under the pointer.
	_m.inertia = Vector2.ZERO


func throw(screen_velocity: Vector2) -> void:
	## Starts coasting at this speed (px/s), as a released drag does.
	_begin_op()
	_m.end_hold(screen_velocity)


func fly_to(world: Vector2, z: float = -1.0) -> void:
	## Moves `world` to the view centre (at zoom z; < 0 keeps the target zoom).
	_begin_op()
	_m.fly_to(world, log(z) if z > 0.0 else _m.target_log_z)
	if not smooth:
		_write()


func fly_to_rect(r: Rect2, margin: float = 40.0, max_zoom: float = MAX_ZOOM) -> void:
	_begin_op()
	fly_to(r.get_center(), minf(CameraMath.fit_zoom(_view().size, r.size, margin), max_zoom))


func fly_home(z: float = HOME_ZOOM) -> void:
	fly_to(home, z)


# --- immediate ---------------------------------------------------------------------------

func center_on(world: Vector2) -> void:
	## Centres `world` inside view_rect (not the full window), right now.
	_begin_op()
	_m.stop()
	_m.pos = _m.clamp_pos(world - _m.view_off / _m.zoom(), _m.zoom())
	_m.target_pos = _m.pos
	_write()


func fit_world_rect(r: Rect2, margin: float = 40.0) -> void:
	_begin_op()
	var z := clampf(CameraMath.fit_zoom(_view().size, r.size, margin), min_zoom, MAX_ZOOM)
	_m.reset(position, z)
	zoom = Vector2.ONE * z
	_shown_z = zoom.x
	center_on(r.get_center())


func go_home(z: float = HOME_ZOOM) -> void:
	## Centres `home` at zoom z (immediately; see fly_home).
	_begin_op()
	z = clampf(z, min_zoom, MAX_ZOOM)
	_m.reset(position, z)
	zoom = Vector2.ONE * z
	_shown_z = zoom.x
	center_on(home)


func set_limits(r: Rect2) -> void:
	## Keep the view centre inside `r` (world px); Rect2() removes the limit.
	_begin_op()
	limits = r
	_hard_clamp()


func set_world_bounds(world: Rect2) -> void:
	## The world: limits = world + LIMIT_MARGIN, min_zoom = fit the whole world.
	_begin_op()
	_world_rect = world
	limits = world.grow(LIMIT_MARGIN) if world.size != Vector2.ZERO else Rect2()
	_update_min_zoom()
	_hard_clamp()


func _hard_clamp() -> void:
	if not _m.is_busy():
		var p := _m.clamp_pos(_m.pos, _m.zoom())
		if not p.is_equal_approx(_m.pos):
			_m.pos = p
			_m.target_pos = p
			_write()


func view_center() -> Vector2:
	## World point at the centre of view_rect (independent of force_update_scroll).
	var off := (_view().get_center() - get_viewport_rect().size * 0.5) / maxf(zoom.x, 0.0001)
	return position + off


func settled_position() -> Vector2:
	## Camera position once the running animation ends (what gets saved).
	_sync_view()
	return _m.settled_pos()


func settled_view_center() -> Vector2:
	_sync_view()
	return _m.settled_pos() + _m.view_off / exp(_m.target_log_z)


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
