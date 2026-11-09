class_name FarmLayout
extends RefCounted
## The document being edited: placed objects, unlocked land, planning data and
## metadata. All mutation goes through these methods (normally via Commands so
## it is undoable); they keep the occupancy index consistent and emit signals
## that the renderer and UI listen to.

signal objects_added(uids: Array)
signal objects_removed(uids: Array)
signal objects_changed(uids: Array)
signal land_changed
signal meta_changed
signal annotations_changed
signal planning_changed

const MODE_CREATIVE := "creative"
const MODE_REALISTIC := "realistic"

var id: String = ""
var name: String = "Untitled farm"
var description: String = ""
var tags: PackedStringArray = PackedStringArray()
var created: String = ""
var modified: String = ""
var mode: String = MODE_CREATIVE
var map_id: String = "hayday_farm"

var objects: Dictionary = {}            ## uid -> PlacedObject
var occupancy := Occupancy.new()
var next_uid: int = 1
var next_group: int = 1
var unlocked_plots: Dictionary = {}     ## plot id -> true
var groups: Dictionary = {}             ## group id -> {name, locked}
var annotations: Array[Dictionary] = [] ## {id, kind: "label"|"zone", rect:[x,y,w,h], text, color}
var next_annotation: int = 1
## Realistic-mode profile: what the player actually owns.
var profile: Dictionary = {"level": 1, "owned": {}, "budget_coins": -1, "budget_diamonds": -1, "treat_unknown_as_owned": true}
var reference: Dictionary = {}          ## screenshot overlay settings
var camera: Dictionary = {}             ## last view {x, y, zoom}
var extra: Dictionary = {}              ## unknown top-level keys preserved


func new_uid() -> int:
	var u := next_uid
	next_uid += 1
	return u


func get_obj(uid: int) -> PlacedObject:
	return objects.get(uid)


func count() -> int:
	return objects.size()


func add_objects(list: Array, emit: bool = true) -> Array:
	## Adds PlacedObjects (uids assigned if 0). Returns their uids.
	var uids: Array = []
	for o: PlacedObject in list:
		if o.uid <= 0 or objects.has(o.uid):
			o.uid = new_uid()
		else:
			next_uid = maxi(next_uid, o.uid + 1)
		objects[o.uid] = o
		occupancy.add_rect(o.uid, o.rect())
		uids.append(o.uid)
	if emit and not uids.is_empty():
		objects_added.emit(uids)
	return uids


func remove_objects(uids: Array, emit: bool = true) -> Array:
	## Removes and returns the PlacedObjects (for undo).
	var removed: Array = []
	var done: Array = []
	for u in uids:
		var o: PlacedObject = objects.get(u)
		if o == null:
			continue
		occupancy.remove_rect(o.uid, o.rect())
		objects.erase(u)
		removed.append(o)
		done.append(u)
	if emit and not done.is_empty():
		objects_removed.emit(done)
	return removed


func move_objects(uids: Array, delta: Vector2i, emit: bool = true) -> void:
	if delta == Vector2i.ZERO:
		return
	for u in uids:
		var o: PlacedObject = objects.get(u)
		if o:
			occupancy.remove_rect(o.uid, o.rect())
	for u in uids:
		var o: PlacedObject = objects.get(u)
		if o:
			o.origin += delta
			occupancy.add_rect(o.uid, o.rect())
	if emit:
		objects_changed.emit(uids)


func set_object_rect(uid: int, origin: Vector2i, size: Vector2i, emit: bool = true) -> void:
	var o: PlacedObject = objects.get(uid)
	if o == null:
		return
	occupancy.remove_rect(uid, o.rect())
	o.origin = origin
	o.size = size
	occupancy.add_rect(uid, o.rect())
	if emit:
		objects_changed.emit([uid])


func set_property(uids: Array, prop: String, values: Array, emit: bool = true) -> void:
	## Sets a simple property per object (values[i] for uids[i]).
	for i in uids.size():
		var o: PlacedObject = objects.get(uids[i])
		if o:
			o.set(prop, values[i])
	if emit:
		objects_changed.emit(uids)


func object_at(t: Vector2i) -> PlacedObject:
	var u := occupancy.at(t)
	return objects.get(u) if u != 0 else null


func uids_in_rect(r: Rect2i) -> Array:
	var seen := {}
	for o: PlacedObject in objects.values():
		if o.rect().intersects(r):
			seen[o.uid] = true
	return seen.keys()


func bounds_of(uids: Array) -> Rect2i:
	var first := true
	var r := Rect2i()
	for u in uids:
		var o: PlacedObject = objects.get(u)
		if o == null:
			continue
		if first:
			r = o.rect()
			first = false
		else:
			r = r.merge(o.rect())
	return r


func group_members(group_id: int) -> Array:
	var out: Array = []
	if group_id == 0:
		return out
	for o: PlacedObject in objects.values():
		if o.group_id == group_id:
			out.append(o.uid)
	return out


func expand_to_groups(uids: Array) -> Array:
	## Selection helper: clicking one member of a group selects the group.
	var seen := {}
	for u in uids:
		seen[u] = true
		var o: PlacedObject = objects.get(u)
		if o and o.group_id != 0:
			for m in group_members(o.group_id):
				seen[m] = true
	return seen.keys()


func set_unlocked(plot_ids: Array, emit: bool = true) -> void:
	unlocked_plots.clear()
	for p in plot_ids:
		unlocked_plots[str(p)] = true
	if emit:
		land_changed.emit()


func item_counts(include_planned: bool = true) -> Dictionary:
	var counts := {}
	for o: PlacedObject in objects.values():
		if o.planned and not include_planned:
			continue
		counts[o.item_id] = counts.get(o.item_id, 0) + 1
	return counts


func clear_all() -> void:
	objects.clear()
	occupancy.clear()
	next_uid = 1


func touch() -> void:
	modified = Time.get_datetime_string_from_system(true) + "Z"
