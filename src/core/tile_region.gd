class_name TileRegion
extends RefCounted
## A set of ground tiles: the area the Select tool's tile selection covers
## (docs/ARCHITECTURE.md "Tile selection"). Pure logic, no rendering.
##
## Objects belong to a region when their logical footprint (PlacedObject.rect())
## overlaps at least one of its tiles; artwork that hangs over other tiles never
## counts. Regions are built from tile rectangles (drag from corner to corner)
## and combined with add_rect() / remove_rect(), so Shift/Ctrl drags can grow or
## cut an existing selection.

var _tiles: Dictionary = {}       ## Occupancy.key(tile) -> true
var _bounds := Rect2i()
var _bounds_dirty := false
var _edges_cache: PackedVector2Array
var _edges_dirty := true


static func from_rect(r: Rect2i) -> TileRegion:
	var t := TileRegion.new()
	t.add_rect(r)
	return t


func duplicate_region() -> TileRegion:
	var t := TileRegion.new()
	t._tiles = _tiles.duplicate()
	t._bounds = _bounds
	t._bounds_dirty = _bounds_dirty
	return t


func size() -> int:
	return _tiles.size()


func is_empty() -> bool:
	return _tiles.is_empty()


func has(t: Vector2i) -> bool:
	return _tiles.has(Occupancy.key(t))


func tiles() -> Array:
	var out: Array = []
	for k in _tiles:
		out.append(Occupancy.unkey(k))
	return out


func add_rect(r: Rect2i) -> void:
	if r.size.x <= 0 or r.size.y <= 0:
		return
	var was_empty := _tiles.is_empty()
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			_tiles[Occupancy.key(Vector2i(x, y))] = true
	if was_empty:
		_bounds = r
		_bounds_dirty = false
	elif not _bounds_dirty:
		_bounds = _bounds.merge(r)
	_edges_dirty = true


func remove_rect(r: Rect2i) -> void:
	if r.size.x <= 0 or r.size.y <= 0 or _tiles.is_empty():
		return
	var c := r.intersection(bounds())
	for y in range(c.position.y, c.end.y):
		for x in range(c.position.x, c.end.x):
			_tiles.erase(Occupancy.key(Vector2i(x, y)))
	_bounds_dirty = true
	_edges_dirty = true


func translate(delta: Vector2i) -> void:
	## Moves every tile (a moved selection takes its area along).
	if delta == Vector2i.ZERO or _tiles.is_empty():
		return
	var moved := {}
	for k in _tiles:
		moved[Occupancy.key(Occupancy.unkey(k) + delta)] = true
	_tiles = moved
	var b := bounds()
	_bounds = Rect2i(b.position + delta, b.size)
	_edges_dirty = true


func bounds() -> Rect2i:
	## Smallest tile rectangle holding every tile (empty region: zero rect).
	if _tiles.is_empty():
		return Rect2i()
	if _bounds_dirty:
		var first := true
		var lo := Vector2i.ZERO
		var hi := Vector2i.ZERO
		for k in _tiles:
			var t := Occupancy.unkey(k)
			if first:
				lo = t
				hi = t
				first = false
			else:
				lo = Vector2i(mini(lo.x, t.x), mini(lo.y, t.y))
				hi = Vector2i(maxi(hi.x, t.x), maxi(hi.y, t.y))
		_bounds = Rect2i(lo, hi - lo + Vector2i.ONE)
		_bounds_dirty = false
	return _bounds


func is_rect() -> bool:
	## True when the region is exactly one filled rectangle.
	var b := bounds()
	return not _tiles.is_empty() and b.size.x * b.size.y == _tiles.size()


func uids_in(layout: FarmLayout, keep: Callable = Callable()) -> Array:
	## Placed objects whose footprint overlaps the region (each once, in no
	## particular order). `keep(uid) -> bool` leaves objects out (hidden layers).
	## Uses the occupancy index when the region is small and the object list
	## when the farm has fewer objects than the region has tiles.
	var seen := {}
	if _tiles.is_empty() or layout == null:
		return []
	if _tiles.size() <= layout.count():
		for k in _tiles:
			for u in layout.occupancy.all_at(Occupancy.unkey(k)):
				seen[u] = true
	else:
		var b := bounds()
		var whole := is_rect()
		for o: PlacedObject in layout.objects.values():
			var r := o.rect()
			if not r.intersects(b):
				continue
			if whole or _overlaps(r):
				seen[o.uid] = true
	var out: Array = []
	for u in seen:
		if layout.objects.has(u) and (not keep.is_valid() or keep.call(int(u))):
			out.append(u)
	return out


func overlaps(r: Rect2i) -> bool:
	## True when any tile of the rectangle is in the region.
	if _tiles.is_empty() or not r.intersects(bounds()):
		return false
	return is_rect() or _overlaps(r)


func _overlaps(r: Rect2i) -> bool:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if _tiles.has(Occupancy.key(Vector2i(x, y))):
				return true
	return false


static func rect_uids(layout: FarmLayout, r: Rect2i, keep: Callable = Callable()) -> Array:
	## uids_in() for a single rectangle without building a region (live drag).
	if layout == null or r.size.x <= 0 or r.size.y <= 0:
		return []
	var seen := {}
	if r.size.x * r.size.y <= layout.count():
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				for u in layout.occupancy.all_at(Vector2i(x, y)):
					seen[u] = true
	else:
		for u in layout.uids_in_rect(r):
			seen[u] = true
	var out: Array = []
	for u in seen:
		if layout.objects.has(u) and (not keep.is_valid() or keep.call(int(u))):
			out.append(u)
	return out


static func of_footprints(layout: FarmLayout, uids: Array) -> TileRegion:
	## The tiles the objects' footprints cover (a selection's combined area).
	var t := TileRegion.new()
	for u in uids:
		var o := layout.get_obj(u) if layout else null
		if o != null:
			t.add_rect(o.rect())
	return t


func boundary_edges() -> PackedVector2Array:
	## The outside edges of the region as world-space segment pairs
	## (p0, p1, p0, p1, …): every tile side whose neighbour is not in the region,
	## so holes and separate islands each get their own outline. Cached.
	if not _edges_dirty:
		return _edges_cache
	var out := PackedVector2Array()
	for k in _tiles:
		var t := Occupancy.unkey(k)
		# Corners of tile t in the grid: (x,y) (x+1,y) (x+1,y+1) (x,y+1).
		if not _tiles.has(Occupancy.key(t + Vector2i(0, -1))):
			out.append(Iso.grid_to_world(Vector2(t.x, t.y)))
			out.append(Iso.grid_to_world(Vector2(t.x + 1, t.y)))
		if not _tiles.has(Occupancy.key(t + Vector2i(1, 0))):
			out.append(Iso.grid_to_world(Vector2(t.x + 1, t.y)))
			out.append(Iso.grid_to_world(Vector2(t.x + 1, t.y + 1)))
		if not _tiles.has(Occupancy.key(t + Vector2i(0, 1))):
			out.append(Iso.grid_to_world(Vector2(t.x + 1, t.y + 1)))
			out.append(Iso.grid_to_world(Vector2(t.x, t.y + 1)))
		if not _tiles.has(Occupancy.key(t + Vector2i(-1, 0))):
			out.append(Iso.grid_to_world(Vector2(t.x, t.y + 1)))
			out.append(Iso.grid_to_world(Vector2(t.x, t.y)))
	_edges_cache = out
	_edges_dirty = false
	return out


static func rect_inner_lines(r: Rect2i) -> PackedVector2Array:
	## World-space segment pairs of the tile lines inside a rectangle (its grid).
	var out := PackedVector2Array()
	for x in range(r.position.x + 1, r.end.x):
		out.append(Iso.grid_to_world(Vector2(x, r.position.y)))
		out.append(Iso.grid_to_world(Vector2(x, r.end.y)))
	for y in range(r.position.y + 1, r.end.y):
		out.append(Iso.grid_to_world(Vector2(r.position.x, y)))
		out.append(Iso.grid_to_world(Vector2(r.end.x, y)))
	return out
