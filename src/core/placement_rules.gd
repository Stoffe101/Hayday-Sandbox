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
const LANDMARK := 8          ## tile blocked by a fixed world landmark (every mode)
## A water decoration (zone item) on a tile outside the map's water-decoration zones.
const WATER_DECO_ZONE := 9
## Catalogue tag of items that go only into the river's water-decoration zones
## (the game's WaterDeco decorations; tools/private_assets/client_catalog.py sets it).
const ZONE_TAG := "water_deco"

const REASON_TEXT := {
	OUT_OF_BOUNDS: "Outside the farm",
	OCCUPIED: "Tiles already occupied",
	LOCKED_LAND: "Expansion land is locked",
	ROAD: "Can't build on the road",
	WATER: "Can't build on water",
	BLOCKED: "Restricted area",
	NOT_PLACEABLE: "This item can't be placed",
	LANDMARK: "Fixed landmark",
	WATER_DECO_ZONE: "Water decorations go only in the river's decoration zones",
}
## Order in which reasons are listed in messages (most specific first).
const MESSAGE_ORDER := [NOT_PLACEABLE, LANDMARK, WATER_DECO_ZONE, OUT_OF_BOUNDS, OCCUPIED, LOCKED_LAND, ROAD, WATER, BLOCKED]


class Result:
	var ok: bool = true
	## Per tile verdict, parallel arrays.
	var tiles: Array[Vector2i] = []
	var codes: PackedInt32Array = PackedInt32Array()
	## code -> count
	var reason_counts: Dictionary = {}
	var blocking_uids: Dictionary = {}
	var locked_plots: Dictionary = {}
	## landmark id -> true for LANDMARK tiles
	var landmark_ids: Dictionary = {}
	## Item-specific explanation for NOT_PLACEABLE (set by check_item).
	var not_placeable_text: String = ""

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
		return " · ".join(reasons(layout, db, map))

	func reasons(layout: FarmLayout = null, db: ItemDatabase = null, map: FarmMap = null) -> PackedStringArray:
		## One human-readable line per kind of problem, most specific first.
		var parts: PackedStringArray = []
		for c in MESSAGE_ORDER:
			if not reason_counts.has(c):
				continue
			var t: String = REASON_TEXT[c]
			if c == NOT_PLACEABLE and not not_placeable_text.is_empty():
				t = not_placeable_text
			elif c == OCCUPIED and layout and db:
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
			elif c == WATER_DECO_ZONE and map and not map.has_water_deco_zones():
				t = "Water decorations go only in the river's decoration zones, and this world has none (needs world data with them)"
			elif c == LANDMARK and map:
				var ln: Array = []
				for lid in landmark_ids:
					var lm := map.landmark(lid)
					ln.append(lm.name if lm else str(lid))
				ln.sort()
				if not ln.is_empty():
					t = "Fixed landmark: %s" % ", ".join(PackedStringArray(ln.slice(0, 3)))
			parts.append(t)
		return parts


static func is_zone_item(it: ItemDef) -> bool:
	## True for items that may stand only in the map's water-decoration zones.
	return it != null and ZONE_TAG in it.tags


static func zone_item_ids(db: ItemDatabase) -> Dictionary:
	## Ids (and aliases) of the zone items in the catalogue (FarmLayout.zone_items).
	var out := {}
	if db == null:
		return out
	for it: ItemDef in db.ordered:
		if is_zone_item(it):
			out[it.id] = true
			for a in it.aliases:
				out[a] = true
	return out


static func is_zone_object(layout: FarmLayout, o: PlacedObject) -> bool:
	return o != null and layout.zone_items.has(o.item_id)


static func check_rect(layout: FarmLayout, map: FarmMap, r: Rect2i, ignore: Dictionary = {}, placeable: bool = true,
		zone_item: bool = false) -> Result:
	## Per-tile verdict for a footprint. `zone_item`: the rect belongs to a water
	## decoration, which may stand only on water-decoration zone tiles (see
	## tile_code()); other items never may (those tiles are water or outside the
	## placement grid).
	var res := Result.new()
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var t := Vector2i(x, y)
			var code := tile_code(layout, map, t, ignore, zone_item)
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
				elif code == LANDMARK:
					res.landmark_ids[map.landmark_id_at(t)] = true
	return res


static func tile_code(layout: FarmLayout, map: FarmMap, t: Vector2i, ignore: Dictionary = {}, zone_item: bool = false) -> int:
	if zone_item:
		# Water decorations: only zone tiles (world data), never land; a fixed
		# landmark or another object there still blocks.
		if map.water_deco_zone_at(t) < 0:
			return WATER_DECO_ZONE
		if map.kind_at(t) != FarmMap.Kind.VOID and map.blocking_landmark_at(t) >= 0:
			return LANDMARK
		if not layout.occupancy.is_free(t, ignore):
			return OCCUPIED
		return OK_TILE
	var k := map.kind_at(t)
	if k != FarmMap.Kind.VOID and map.blocking_landmark_at(t) >= 0:
		return LANDMARK
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
			if not map.is_plot_unlocked(map.plot_id_at(t), layout.unlocked_plots):
				return LOCKED_LAND
	if not layout.occupancy.is_free(t, ignore):
		return OCCUPIED
	return OK_TILE


static func check_item(layout: FarmLayout, map: FarmMap, item: ItemDef, origin: Vector2i, flipped: bool, ignore: Dictionary = {}) -> Result:
	## Items that duplicate a fixed landmark or belong to another area (e.g.
	## the Fishing Lake) are never placeable: NOT_PLACEABLE on every free tile.
	var size := item.size_for(flipped) if item else Vector2i.ONE
	var res := check_rect(layout, map, Rect2i(origin, size), ignore, item != null and item.can_place(), is_zone_item(item))
	if item:
		res.not_placeable_text = item.not_placeable_reason()
	return res


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
		var r := check_rect(layout, map, Rect2i(o.origin + delta, o.size), ignore, true, is_zone_object(layout, o))
		_merge(total, r)
	return total


static func check_stamp(layout: FarmLayout, map: FarmMap, rects: Array, ignore: Dictionary = {}, zones: Variant = false) -> Result:
	## Validates a set of new rects (paste / multi-place) against the layout
	## and against each other. `zones`: true when every rect is a water
	## decoration, or one bool per rect (a paste mixes items).
	var total := Result.new()
	var seen := {}
	for i in rects.size():
		var r: Rect2i = rects[i]
		var z := bool(zones[i]) if zones is Array and i < (zones as Array).size() else (zones is bool and bool(zones))
		var res := check_rect(layout, map, r, ignore, true, z)
		for j in res.tiles.size():
			var t := res.tiles[j]
			var k := Occupancy.key(t)
			if seen.has(k) and res.codes[j] == OK_TILE:
				res.codes[j] = OCCUPIED
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
	total.landmark_ids.merge(r.landmark_ids)


static func find_conflicts(layout: FarmLayout, map: FarmMap) -> Dictionary:
	## Every object that currently violates placement (after load, land
	## changes, or metadata changes). uid -> Result.
	var out := {}
	for o: PlacedObject in layout.objects.values():
		var ignore := {o.uid: true}
		var r := check_rect(layout, map, o.rect(), ignore, true, is_zone_object(layout, o))
		if not r.ok:
			out[o.uid] = r
	return out


static func check_object(layout: FarmLayout, map: FarmMap, o: PlacedObject) -> Result:
	## The placement verdict of an object where it stands (itself ignored).
	return check_rect(layout, map, o.rect(), {o.uid: true}, true, is_zone_object(layout, o))
