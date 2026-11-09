class_name Iso
extends RefCounted
## Isometric (2:1 dimetric) projection math.
##
## Coordinate spaces used throughout the app:
##   * Grid space (Vector2, float): continuous tile-axis coordinates. Integer
##     values are tile *corners*. +x runs towards the screen's lower-right,
##     +y runs towards the screen's lower-left.
##   * Tile space (Vector2i): the tile whose top corner is (x, y) in grid space.
##   * World space (Vector2, pixels): the unscaled 2D canvas the farm is drawn
##     in. Grid (0,0) maps to world (0,0).
##   * Screen space (Vector2, pixels): what the camera shows. Converted to/from
##     world with the camera centre and zoom (see screen_to_world()).
##
## The logical grid is independent of the art scale: sprites declare their own
## pixels-per-world-pixel scale in their asset pack manifest.

const TILE_W := 64.0
const TILE_H := 32.0
const HALF_W := TILE_W * 0.5
const HALF_H := TILE_H * 0.5
## World pixels per unit of vertical height (one tile-edge length) for a 2:1
## projection viewed from 30 degrees: TILE_W / sqrt(2) * cos(30deg).
const Z_UNIT := TILE_W * 0.6123724


static func grid_to_world(g: Vector2) -> Vector2:
	return Vector2((g.x - g.y) * HALF_W, (g.x + g.y) * HALF_H)


static func world_to_grid(w: Vector2) -> Vector2:
	var a := w.x / HALF_W
	var b := w.y / HALF_H
	return Vector2((a + b) * 0.5, (b - a) * 0.5)


static func world_to_tile(w: Vector2) -> Vector2i:
	var g := world_to_grid(w)
	return Vector2i(floori(g.x), floori(g.y))


static func tile_to_world(t: Vector2i) -> Vector2:
	## World position of the tile's top corner.
	return grid_to_world(Vector2(t.x, t.y))


static func tile_center(t: Vector2i) -> Vector2:
	return grid_to_world(Vector2(t.x + 0.5, t.y + 0.5))


static func footprint_center(origin: Vector2i, size: Vector2i) -> Vector2:
	## World position of the ground centre of a footprint (the sprite anchor).
	return grid_to_world(Vector2(origin.x + size.x * 0.5, origin.y + size.y * 0.5))


static func footprint_polygon(origin: Vector2i, size: Vector2i) -> PackedVector2Array:
	## Ground diamond of a footprint: top, right, bottom, left corners.
	return PackedVector2Array([
		grid_to_world(Vector2(origin.x, origin.y)),
		grid_to_world(Vector2(origin.x + size.x, origin.y)),
		grid_to_world(Vector2(origin.x + size.x, origin.y + size.y)),
		grid_to_world(Vector2(origin.x, origin.y + size.y)),
	])


static func grid_rect_polygon(r: Rect2i) -> PackedVector2Array:
	return footprint_polygon(r.position, r.size)


static func footprint_world_bounds(origin: Vector2i, size: Vector2i) -> Rect2:
	## Axis-aligned world bounds of the ground diamond.
	var top := grid_to_world(Vector2(origin.x, origin.y))
	var right := grid_to_world(Vector2(origin.x + size.x, origin.y))
	var bottom := grid_to_world(Vector2(origin.x + size.x, origin.y + size.y))
	var left := grid_to_world(Vector2(origin.x, origin.y + size.y))
	return Rect2(Vector2(left.x, top.y), Vector2(right.x - left.x, bottom.y - top.y))


static func screen_to_world(screen: Vector2, camera_center: Vector2, zoom: float, view_size: Vector2) -> Vector2:
	return camera_center + (screen - view_size * 0.5) / zoom


static func world_to_screen(world: Vector2, camera_center: Vector2, zoom: float, view_size: Vector2) -> Vector2:
	return (world - camera_center) * zoom + view_size * 0.5


static func depth_key(origin: Vector2i, size: Vector2i) -> float:
	## Painter's-order key of the footprint centre (larger = closer to viewer).
	return origin.x + origin.y + (size.x + size.y) * 0.5


static func tiles_of(origin: Vector2i, size: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(origin.y, origin.y + size.y):
		for x in range(origin.x, origin.x + size.x):
			out.append(Vector2i(x, y))
	return out


static func tiles_on_line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	## Tiles from a to b along the dominant grid axis (an L-free straight run,
	## the way fences and paths are usually drawn). Includes both ends.
	var out: Array[Vector2i] = []
	var d := b - a
	if absi(d.x) >= absi(d.y):
		var step := 1 if d.x >= 0 else -1
		for i in range(absi(d.x) + 1):
			out.append(Vector2i(a.x + i * step, a.y))
	else:
		var step := 1 if d.y >= 0 else -1
		for i in range(absi(d.y) + 1):
			out.append(Vector2i(a.x, a.y + i * step))
	return out


static func rect_from_corners(a: Vector2i, b: Vector2i) -> Rect2i:
	var p := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var q := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	return Rect2i(p, q - p + Vector2i.ONE)
