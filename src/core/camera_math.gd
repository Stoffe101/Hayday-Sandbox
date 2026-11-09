class_name CameraMath
extends RefCounted
## Pure camera maths (no scene dependencies, unit-tested): critically damped
## springs on the camera position and the log of the zoom, zoom anchored to a
## world point, pan inertia and rubber-band limits. FarmCamera owns one State
## and copies its result to the Camera2D.
##
## Coordinates: `pos` is the Camera2D position (world px); the world point at
## the centre of the visible canvas is pos + view_off / zoom. `limits` applies
## to that centre.

## How fast each animation closes in (rad/s; settles in about 5 / omega).
const OMEGA_ZOOM := 20.0
const OMEGA_FLY := 8.0
const OMEGA_BACK := 14.0
const EPS_LOG := 0.0003
const EPS_POS := 0.05
## Inertia: exponential friction (1/s), much stronger past the limits.
const FRICTION := 5.0
const FRICTION_OVER := 30.0
const INERTIA_STOP := 12.0     ## screen px/s
const THROW_MIN := 140.0       ## screen px/s below which a release doesn't coast
const THROW_MAX := 5000.0
const THROW_WINDOW_MS := 90
const THROW_STALE_MS := 60     ## pointer held still this long before release: no coast
## Rubber band: resistance factor, and the overshoot limit as a share of the view.
const RUBBER_C := 0.55
const RUBBER_VIEW_SHARE := 0.25


static func spring(x: float, v: float, target: float, omega: float, dt: float) -> Vector2:
	## One step of a critically damped spring (exact solution, stable for any
	## dt, never overshoots a target it starts at rest from). -> (x, v).
	var d := x - target
	var j := (v + omega * d) * dt
	var e := exp(-omega * dt)
	return Vector2(target + (d + j) * e, (v - omega * j) * e)


static func rubber(over: float, dim: float) -> float:
	## Displayed distance past a limit for a raw overshoot `over` >= 0. Starts
	## with slope RUBBER_C and approaches `dim` for huge overshoots.
	if over <= 0.0 or dim <= 0.0:
		return 0.0
	return (1.0 - 1.0 / (over * RUBBER_C / dim + 1.0)) * dim


static func rubber_axis(v: float, lo: float, hi: float, dim: float) -> float:
	if v < lo:
		return lo - rubber(lo - v, dim)
	if v > hi:
		return hi + rubber(v - hi, dim)
	return v


static func rubber_point(p: Vector2, r: Rect2, dim: Vector2) -> Vector2:
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return p
	return Vector2(rubber_axis(p.x, r.position.x, r.end.x, dim.x), rubber_axis(p.y, r.position.y, r.end.y, dim.y))


static func fit_zoom(view_size: Vector2, rect_size: Vector2, margin: float = 0.0) -> float:
	## Largest zoom at which a rect of rect_size fits into the view.
	var zx := maxf(1.0, view_size.x - margin * 2.0) / maxf(1.0, rect_size.x)
	var zy := maxf(1.0, view_size.y - margin * 2.0) / maxf(1.0, rect_size.y)
	return minf(zx, zy)


class PanTracker:
	## Recent drag deltas, to work out how fast the pointer was moving when it
	## let go.
	var samples: Array = []          ## [[t_ms, delta], ...] oldest first

	func clear() -> void:
		samples.clear()

	func add(delta: Vector2, t_ms: int) -> void:
		samples.append([t_ms, delta])
		while samples.size() > 2 and int(samples[0][0]) < t_ms - CameraMath.THROW_WINDOW_MS:
			samples.pop_front()

	func velocity(now_ms: int) -> Vector2:
		## Screen px/s at release (ZERO: too slow, too few samples or held still).
		if samples.size() < 2:
			return Vector2.ZERO
		var last_t: int = samples[-1][0]
		if now_ms - last_t > CameraMath.THROW_STALE_MS:
			return Vector2.ZERO
		var first_t: int = samples[0][0]
		if last_t <= first_t:
			return Vector2.ZERO
		var sum := Vector2.ZERO
		for i in range(1, samples.size()):
			sum += samples[i][1]
		var v := sum * 1000.0 / float(last_t - first_t)
		if v.length() < CameraMath.THROW_MIN:
			return Vector2.ZERO
		return v.limit_length(CameraMath.THROW_MAX)


class State:
	## pos is the raw position; shown_pos() is what the camera displays (the
	## same unless it is being pulled past the limits).
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var log_z := 0.0
	var log_z_vel := 0.0
	var target_log_z := 0.0
	var omega_zoom := CameraMath.OMEGA_ZOOM
	## pos springs towards target_pos while `flying`.
	var flying := false
	var target_pos := Vector2.ZERO
	var omega_pos := CameraMath.OMEGA_FLY
	## Zoom anchor: while anchored, pos = anchor_world - anchor_off / zoom, so the
	## anchor stays under the same screen point. Pans shift anchor_world.
	var anchored := false
	var anchor_world := Vector2.ZERO
	var anchor_off := Vector2.ZERO   ## screen px from the viewport centre
	var inertia := Vector2.ZERO      ## screen px/s
	var held := false                ## the pointer is dragging the view
	var soft := true                 ## false: no animation, limits are hard
	var limits := Rect2()            ## the view centre stays inside (empty = none)
	var view_off := Vector2.ZERO     ## view centre - viewport centre, screen px
	var view_size := Vector2(1280, 720)
	var min_log_z := log(0.02)
	var max_log_z := log(4.0)

	func zoom() -> float:
		return exp(log_z)

	func clamp_log_z(l: float) -> float:
		return clampf(l, min_log_z, max_log_z)

	func reset(p: Vector2, z: float) -> void:
		## Adopt a view set from outside: everything stops there.
		pos = p
		log_z = log(maxf(z, 0.0001))
		target_log_z = log_z
		stop()

	func stop() -> void:
		## Ends every animation at the current view.
		target_log_z = log_z
		log_z_vel = 0.0
		vel = Vector2.ZERO
		flying = false
		anchored = false
		inertia = Vector2.ZERO
		target_pos = pos

	# --- limits ------------------------------------------------------------

	func clamp_pos(p: Vector2, z: float) -> Vector2:
		## p moved the least so that the view centre is inside the limits at zoom z.
		if limits.size.x <= 0.0 or limits.size.y <= 0.0:
			return p
		var off := view_off / z
		var c := p + off
		return Vector2(clampf(c.x, limits.position.x, limits.end.x), clampf(c.y, limits.position.y, limits.end.y)) - off

	func is_outside() -> bool:
		return not clamp_pos(pos, zoom()).is_equal_approx(pos)

	func shown_pos() -> Vector2:
		if not soft:
			return pos
		var z := zoom()
		var off := view_off / z
		return CameraMath.rubber_point(pos + off, limits, view_size / z * CameraMath.RUBBER_VIEW_SHARE) - off

	# --- gestures ----------------------------------------------------------

	func pan_world(d: Vector2) -> void:
		## Moves the view by d world px and keeps the move: flight and zoom
		## destinations shift with it.
		pos += d
		target_pos += d
		anchor_world += d
		if not soft:
			pos = clamp_pos(pos, zoom())

	func zoom_about(off: Vector2, new_target_log: float) -> void:
		## Starts (or retargets) a zoom keeping the world point at screen offset
		## `off` from the viewport centre where it is.
		anchor_world = pos + off / zoom()
		anchor_off = off
		anchored = true
		flying = false
		vel = Vector2.ZERO
		target_log_z = clamp_log_z(new_target_log)
		omega_zoom = CameraMath.OMEGA_ZOOM
		if not soft:
			settle()

	func fly_to(center: Vector2, new_target_log: float) -> void:
		## Flies so that `center` ends at the view centre at the target zoom.
		target_log_z = clamp_log_z(new_target_log)
		target_pos = clamp_pos(center - view_off / exp(target_log_z), exp(target_log_z))
		anchored = false
		flying = true
		inertia = Vector2.ZERO
		omega_pos = CameraMath.OMEGA_FLY
		omega_zoom = CameraMath.OMEGA_FLY
		if not soft:
			settle()

	func begin_hold() -> void:
		held = true
		inertia = Vector2.ZERO
		if flying:
			flying = false
			vel = Vector2.ZERO

	func end_hold(release_velocity: Vector2) -> void:
		held = false
		inertia = release_velocity if soft else Vector2.ZERO

	func settle() -> void:
		## Jumps to where the running animations would end, inside the limits.
		log_z = target_log_z
		log_z_vel = 0.0
		if anchored:
			pos = anchor_world - anchor_off / zoom()
		elif flying:
			pos = target_pos
		anchored = false
		flying = false
		vel = Vector2.ZERO
		inertia = Vector2.ZERO
		pos = clamp_pos(pos, zoom())
		target_pos = pos

	func settled_pos() -> Vector2:
		## Where the camera will come to rest (ignoring inertia).
		var z := exp(target_log_z)
		var p := pos
		if anchored:
			p = anchor_world - anchor_off / z
		elif flying:
			p = target_pos
		return clamp_pos(p, z)

	func is_busy() -> bool:
		## A zoom, flight or coast is running (spring-back not counted).
		return anchored or flying or inertia != Vector2.ZERO or log_z != target_log_z

	func is_animating() -> bool:
		return is_busy() or (soft and not held and is_outside())

	# --- animation ---------------------------------------------------------

	func step(dt: float) -> bool:
		## Advances all animations by dt seconds. True when the view changed.
		if dt <= 0.0:
			return false
		var was_pos := pos
		var was_z := log_z
		_step_inertia(dt)
		_step_zoom(dt)
		_step_pos(dt)
		return pos != was_pos or log_z != was_z

	func _step_inertia(dt: float) -> void:
		if inertia == Vector2.ZERO or held:
			return
		var z := zoom()
		var c := pos + view_off / z
		var out := Vector2.ZERO
		out.x = CameraMath.FRICTION_OVER if limits.size.x > 0.0 and (c.x < limits.position.x or c.x > limits.end.x) else CameraMath.FRICTION
		out.y = CameraMath.FRICTION_OVER if limits.size.y > 0.0 and (c.y < limits.position.y or c.y > limits.end.y) else CameraMath.FRICTION
		var e := Vector2(exp(-out.x * dt), exp(-out.y * dt))
		var moved := Vector2(inertia.x * (1.0 - e.x) / out.x, inertia.y * (1.0 - e.y) / out.y)
		inertia = Vector2(inertia.x * e.x, inertia.y * e.y)
		if inertia.length() < CameraMath.INERTIA_STOP:
			inertia = Vector2.ZERO
		pan_world(-moved / z)

	func _step_zoom(dt: float) -> void:
		var settled := false
		if log_z != target_log_z or log_z_vel != 0.0:
			var s := CameraMath.spring(log_z, log_z_vel, target_log_z, omega_zoom, dt)
			log_z = s.x
			log_z_vel = s.y
			if absf(log_z - target_log_z) < CameraMath.EPS_LOG and absf(log_z_vel) < CameraMath.EPS_LOG * omega_zoom:
				log_z = target_log_z
				log_z_vel = 0.0
				settled = true
		else:
			settled = true
		if anchored:
			var p := anchor_world - anchor_off / zoom()
			vel = (p - pos) / dt
			pos = p
			if settled:
				anchored = false
				vel = Vector2.ZERO

	func _step_pos(dt: float) -> void:
		if not flying:
			if anchored or held or inertia != Vector2.ZERO or log_z != target_log_z or not is_outside():
				return
			# Nothing is holding the view past its limits any more: ease back.
			flying = true
			target_pos = clamp_pos(pos, zoom())
			omega_pos = CameraMath.OMEGA_BACK
		var sx := CameraMath.spring(pos.x, vel.x, target_pos.x, omega_pos, dt)
		var sy := CameraMath.spring(pos.y, vel.y, target_pos.y, omega_pos, dt)
		pos = Vector2(sx.x, sy.x)
		vel = Vector2(sx.y, sy.y)
		if pos.distance_to(target_pos) < CameraMath.EPS_POS and vel.length() < CameraMath.EPS_POS * omega_pos:
			pos = target_pos
			vel = Vector2.ZERO
			flying = false
