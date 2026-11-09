class_name DragMath
extends RefCounted
## Pure maths for dragging objects on the tile grid (unit-tested).

## How far past a tile boundary (in tiles) the pointer must go before an object
## changes tile. Stops objects flickering between two tiles when the pointer
## rests on a boundary.
const HYSTERESIS := 0.12
const SNAP_RADIUS := 3


static func hysteresis_axis(cont: float, cur: int, h: float = HYSTERESIS) -> int:
	## `cur` stays until the continuous delta is more than 0.5 + h away from it.
	if cont > float(cur) + 0.5 + h or cont < float(cur) - 0.5 - h:
		return roundi(cont)
	return cur


static func hysteresis(cont: Vector2, cur: Vector2i, h: float = HYSTERESIS) -> Vector2i:
	## Next integer drag delta from the continuous one (grid units).
	return Vector2i(hysteresis_axis(cont.x, cur.x, h), hysteresis_axis(cont.y, cur.y, h))


static func offsets_by_distance(radius: int) -> Array:
	## Every offset within the square `radius`, nearest first (ties in a fixed order).
	var out: Array = []
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			out.append(Vector2i(x, y))
	out.sort_custom(_nearer)
	return out


static func _nearer(a: Vector2i, b: Vector2i) -> bool:
	var da := a.x * a.x + a.y * a.y
	var db := b.x * b.x + b.y * b.y
	if da != db:
		return da < db
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


static func nearest_valid(wanted: Vector2i, radius: int, is_valid: Callable) -> Variant:
	## The delta closest to `wanted` for which is_valid(delta) holds, or null.
	for off: Vector2i in offsets_by_distance(radius):
		var d: Vector2i = wanted + off
		if is_valid.call(d):
			return d
	return null
