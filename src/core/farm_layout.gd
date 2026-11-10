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
signal reference_changed
## Per-layout world state changed (theme, landmark state/skin/visibility).
## `keys` lists what changed: "theme" and/or "<field>/<landmark id>"
## (field = landmark_states | landmark_skins | landmark_visible).
signal world_changed(keys: Array)

const MODE_CREATIVE := "creative"
const MODE_REALISTIC := "realistic"
const DEFAULT_THEME := "default"
## Per-landmark world-state maps (landmark id -> value). Landmarks themselves are
## world data (FarmMap.landmarks) and never PlacedObjects; a layout only stores
## how they look in this design.
const WORLD_FIELDS := ["landmark_states", "landmark_skins", "landmark_visible"]

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
## {id, kind: "label"|"zone", rect:[x,y,w,h], text, color}. Since schema 4,
## loading an older file turns its "zone" annotations into planning areas.
var annotations: Array[Dictionary] = []
var next_annotation: int = 1
## Realistic-mode profile: what the player actually owns.
var profile: Dictionary = {"level": 1, "owned": {}, "budget_coins": -1, "budget_diamonds": -1, "treat_unknown_as_owned": true}
## Planning document (schema 4, docs/PLANNING.md §3): areas, phases, phase
## assignments, placed/acquired progress, baseline. Pure data, see PlanDoc.
## Edited only through EditCommands.SetPlanning (emits planning_changed).
var planning: Dictionary = PlanDoc.empty()
var reference: Dictionary = {}          ## screenshot overlay settings
var camera: Dictionary = {}             ## last view {x, y, zoom}
var extra: Dictionary = {}              ## unknown top-level keys preserved
## Cosmetic world state of this design (schema v2 "world"):
## {theme, landmark_states: {id: state}, landmark_skins: {id: skin}, landmark_visible: {id: bool}}.
## Absent entries mean "the landmark's default". Edited only via SetWorldStateCommand.
var world_state: Dictionary = default_world_state()
## Record of the schema 1 -> 2 upgrade (schema v2 "migration"), {} when none.
## Kept and saved so landmark objects taken out of old layouts are never lost.
var migration: Dictionary = {}
## Which catalogue footprints the object sizes were reconciled with (schema v2
## "footprint_source": {pack, pack_version, overrides_hash}); {} = public catalogue.
var footprint_source: Dictionary = {}
## Item ids that may never become placed objects: catalogue entries that
## duplicate a fixed world landmark (EditorSession fills it from the item
## database and map). add_objects() refuses them, so no command or import
## can put a landmark copy into `objects`. Not saved.
var fixed_items: Dictionary = {}
## Schema version of the file this layout was read from (-1 = created in this
## session). LayoutIO.save_file backs up an older-schema file before overwriting it.
var loaded_schema: int = -1


func new_uid() -> int:
	var u := next_uid
	next_uid += 1
	return u


func get_obj(uid: int) -> PlacedObject:
	return objects.get(uid)


func count() -> int:
	return objects.size()


func add_objects(list: Array, emit: bool = true, restore: bool = false) -> Array:
	## Adds PlacedObjects (uids assigned if 0). Returns their uids. Objects
	## whose item is in `fixed_items` (landmark duplicates) are refused, except
	## with `restore` (undoing a removal puts back exactly what was there, e.g.
	## an object whose item a world change made a landmark copy).
	var uids: Array = []
	for o: PlacedObject in list:
		if fixed_items.has(o.item_id) and not restore:
			push_warning("FarmLayout: '%s' is a fixed landmark and can't be placed as an object" % o.item_id)
			continue
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


# --- world state ------------------------------------------------------------------

static func default_world_state() -> Dictionary:
	return {"theme": DEFAULT_THEME, "landmark_states": {}, "landmark_skins": {}, "landmark_visible": {}}


static func normalize_world_state(v: Variant) -> Dictionary:
	## Sanitises a saved "world" dictionary (wrong types are dropped, unknown
	## keys are kept verbatim).
	var out := default_world_state()
	if not v is Dictionary:
		return out
	var d: Dictionary = v
	for k in d:
		var ks := str(k)
		if ks == "theme":
			var t := str(d[k]).strip_edges() if d[k] != null else ""
			out["theme"] = t if not t.is_empty() else DEFAULT_THEME
		elif ks in WORLD_FIELDS:
			if not d[k] is Dictionary:
				continue
			for lid in d[k]:
				var val: Variant = d[k][lid]
				if ks == "landmark_visible":
					if val is bool:
						out[ks][str(lid)] = val
				elif val is String and not (val as String).is_empty():
					out[ks][str(lid)] = val
		else:
			out[ks] = d[k]
	return out


func theme() -> String:
	return str(world_state.get("theme", DEFAULT_THEME))


func world_value(field: String, landmark_id: String = "") -> Variant:
	## field "theme" -> the theme; a WORLD_FIELDS field -> the landmark's value or null.
	if field == "theme":
		return theme()
	var m: Variant = world_state.get(field, {})
	return (m as Dictionary).get(landmark_id) if m is Dictionary else null


func set_world_value(field: String, landmark_id: String, value: Variant, emit: bool = true) -> void:
	## Sets (value != null) or clears (null = back to the landmark's default) one
	## world-state value. Use SetWorldStateCommand so the change is undoable.
	if field == "theme":
		world_state["theme"] = DEFAULT_THEME if value == null or str(value).is_empty() else str(value)
		if emit:
			world_changed.emit(["theme"])
		return
	if not field in WORLD_FIELDS:
		push_warning("FarmLayout: unknown world field '%s'" % field)
		return
	if not world_state.get(field) is Dictionary:
		world_state[field] = {}
	var m: Dictionary = world_state[field]
	if value == null:
		m.erase(landmark_id)
	else:
		m[landmark_id] = value
	if emit:
		world_changed.emit(["%s/%s" % [field, landmark_id]])


func landmark_state(landmark_id: String, fallback: String = "") -> String:
	var v: Variant = world_value("landmark_states", landmark_id)
	return fallback if v == null else str(v)


func landmark_skin(landmark_id: String, fallback: String = "") -> String:
	var v: Variant = world_value("landmark_skins", landmark_id)
	return fallback if v == null else str(v)


func is_landmark_visible(landmark_id: String, fallback: bool = true) -> bool:
	var v: Variant = world_value("landmark_visible", landmark_id)
	return fallback if v == null else bool(v)


func set_planning(plan: Dictionary, emit: bool = true) -> void:
	## Replaces the planning document with a deep copy of `plan`. Use
	## EditCommands.SetPlanning so the change is undoable.
	planning = plan.duplicate(true)
	if emit:
		planning_changed.emit()


func clear_all() -> void:
	objects.clear()
	occupancy.clear()
	next_uid = 1


func touch() -> void:
	modified = Time.get_datetime_string_from_system(true) + "Z"
