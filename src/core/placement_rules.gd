class_name PlacementRules
extends RefCounted
## Decides whether objects can stand on given tiles, and explains why not.
## Validity depends only on footprints and map data — never on sprite pixels.

const OK_TILE := 0
const OUT_OF_BOUNDS := 1
const OCCUPIED := 2
const LOCKED_LAND := 3
const ROAD := 4
const WATER := 5
const BLOCKED := 6
const NOT_PLACEABLE := 7

const REASON_TEXT := {
	OUT_OF_BOUNDS: "Outside the farm",
	OCCUPIED: "Tiles already occupied",
	LOCKED_LAND: "Expansion land is locked",
	ROAD: "Can't build on the road",
	WATER: "Can't build on water",
	BLOCKED: "Restricted area",
	NOT_PLACEABLE: "This item can't be placed",
}


class Result:
	var ok: bool = true
	## Per tile verdict, parallel arrays.
	var tiles: Array[Vector2i] = []
	var codes: PackedInt32Array = PackedInt32Array()
	## code -> count
	var reason_counts: Dictionary = {}
	var blocking_uids: Dictionary = {}
	var locked_plots: Dictionary = {}

	func primary_reason() -> int:
		var best := OK_TILE
		var best_n := 0
		for c in reason_counts:
			if reason_counts[c] > best_n:
				best = c
				best_n = reason_counts[c]
		return best

	func message(layout: FarmLayout = null, db: ItemDatabase = null, map: FarmMap = null) -> String:
		if ok:
			return "Fits here"
		var parts: PackedStringArray = []
		var order := [NOT_PLACEABLE, OUT_OF_BOUNDS, OCCUPIED, LOCKED_LAND, ROAD, WATER, BLOCKED]
		for c in order:
			if not reason_counts.has(c):
				continue
			var t: String = REASON_TEXT[c]
			if c == OCCUPIED and layout and db:
				var names := {}
				for u in blocking_uids:
					var o: PlacedObject = layout.get_obj(u)
					if o:
						var it := db.get_item(o.item_id)
						names[it.name if it else o.item_id] = true
				if not names.is_empty():
					var list: Array = names.keys()
					list.sort()
					t = "Blocked by %s" % ", ".join(PackedStringArray(list.slice(0, 3)))
					if list.size() > 3:
						t += " +%d more" % (list.size() - 3)
			elif c == LOCKED_LAND and map:
				var pn: Array = []
				for p in locked_plots:
					pn.append(str(map.plot(p).get("name", p)))
				pn.sort()
				t = "Locked land: %s" % ", ".join(PackedStringArray(pn.slice(0, 3)))
			parts.append(t)
		return " · ".join(parts)


static func check_rect(layout: FarmLayout, map: FarmMap, r: Rect2i, ignore: Dictionary = {}, placeable: bool = true) -> Result:
	var res := Result.new()
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var t := Vector2i(x, y)
			var code := tile_code(layout, map, t, ignore)
			if not placeable and code == OK_TILE:
				code = NOT_PLACEABLE
			res.tiles.append(t)
			res.codes.append(code)
			if code != OK_TILE:
				res.ok = false
				res.reason_counts[code] = res.reason_counts.get(code, 0) + 1
				if code == OCCUPIED:
					for u in layout.occupancy.blockers(t, ignore):
						res.blocking_uids[u] = true
				elif code == LOCKED_LAND:
					res.locked_plots[map.plot_id_at(t)] = true
	return res


static func tile_code(layout: FarmLayout, map: FarmMap, t: Vector2i, ignore: Dictionary = {}) -> int:
	var k := map.kind_at(t)
	match k:
		FarmMap.Kind.VOID:
			return OUT_OF_BOUNDS
		FarmMap.Kind.ROAD:
			return ROAD
		FarmMap.Kind.WATER:
			return WATER
		FarmMap.Kind.BLOCKED, FarmMap.Kind.SCENERY:
			return BLOCKED
		FarmMap.Kind.PLOT:
			if not layout.unlocked_plots.has(map.plot_id_at(t)):
				return LOCKED_LAND
	if not layout.occupancy.is_free(t, ignore):
		return OCCUPIED
	return OK_TILE


static func check_item(layout: FarmLayout, map: FarmMap, item: ItemDef, origin: Vector2i, flipped: bool, ignore: Dictionary = {}) -> Result:
	var size := item.size_for(flipped) if item else Vector2i.ONE
	return check_rect(layout, map, Rect2i(origin, size), ignore, item != null and item.placeable)


static func check_group_move(layout: FarmLayout, map: FarmMap, uids: Array, delta: Vector2i) -> Result:
	## Validates moving several objects together (they may not collide with
	## each other's old positions, only with objects outside the group).
	var ignore := {}
	for u in uids:
		ignore[u] = true
	var total := Result.new()
	for u in uids:
		var o := layout.get_obj(u)
		if o == null:
			continue
		var r := check_rect(layout, map, Rect2i(o.origin + delta, o.size), ignore)
		_merge(total, r)
	return total


static func check_stamp(layout: FarmLayout, map: FarmMap, rects: Array, ignore: Dictionary = {}) -> Result:
	## Validates a set of new rects (paste / multi-place) against the layout
	## and against each other.
	var total := Result.new()
	var seen := {}
	for r: Rect2i in rects:
		var res := check_rect(layout, map, r, ignore)
		for i in res.tiles.size():
			var t := res.tiles[i]
			var k := Occupancy.key(t)
			if seen.has(k) and res.codes[i] == OK_TILE:
				res.codes[i] = OCCUPIED
				res.ok = false
				res.reason_counts[OCCUPIED] = res.reason_counts.get(OCCUPIED, 0) + 1
			seen[k] = true
		_merge(total, res)
	return total


static func _merge(total: Result, r: Result) -> void:
	total.tiles.append_array(r.tiles)
	total.codes.append_array(r.codes)
	if not r.ok:
		total.ok = false
	for c in r.reason_counts:
		total.reason_counts[c] = total.reason_counts.get(c, 0) + r.reason_counts[c]
	total.blocking_uids.merge(r.blocking_uids)
	total.locked_plots.merge(r.locked_plots)


static func find_conflicts(layout: FarmLayout, map: FarmMap) -> Dictionary:
	## Every object that currently violates placement (after load, land
	## changes, or metadata changes). uid -> Result.
	var out := {}
	for o: PlacedObject in layout.objects.values():
		var ignore := {o.uid: true}
		var r := check_rect(layout, map, o.rect(), ignore)
		if not r.ok:
			out[o.uid] = r
	return out
