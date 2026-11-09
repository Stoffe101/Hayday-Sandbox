class_name SetWorldStateCommand
extends Command
## Undoable change of a layout's cosmetic world state (FarmLayout.world_state):
## the theme and, per fixed landmark, its state, skin and visibility.
## Landmarks themselves are world data and can never be moved, rotated, copied
## or deleted; this command only touches how they look in this design.
##
## One command may carry several changes (e.g. a skin preset for the house and
## the truck = one gesture = one undo step). Repeated changes of the same
## fields within CommandStack.MERGE_WINDOW_MS merge into one undo step (e.g.
## scrubbing through skins or states in a picker).
##
##   var cmd := SetWorldStateCommand.for_theme(layout, "winter")
##   var cmd := SetWorldStateCommand.for_landmark(layout, "landmark_skins", "farmhouse", "skin_id")
##   var cmd := SetWorldStateCommand.new([{"field": "landmark_visible", "id": "truck", "value": false}], "Hide truck", layout)
## A change's "value" null means "back to the landmark's default" (the key is removed).

const FIELDS := ["theme", "landmark_states", "landmark_skins", "landmark_visible"]

var _changes: Array = []   ## [{field, id, value}]
var _old: Array = []       ## value before do() per change (null = absent)


func _init(changes: Array, text: String = "", layout: FarmLayout = null) -> void:
	for c in changes:
		if not c is Dictionary:
			continue
		var f := str(c.get("field", ""))
		if not f in FIELDS:
			push_warning("SetWorldStateCommand: unknown field '%s' ignored" % f)
			continue
		var lid := "" if f == "theme" else str(c.get("id", ""))
		if f != "theme" and lid.is_empty():
			continue
		var v: Variant = c.get("value")
		if f == "landmark_visible" and v != null:
			v = bool(v)
		elif v != null:
			v = str(v)
			if (v as String).is_empty():
				v = null
		_changes.append({"field": f, "id": lid, "value": v})
	label = text if not text.is_empty() else _default_label()
	var keys: Array = []
	for c in _changes:
		keys.append("%s/%s" % [c["field"], c["id"]])
	keys.sort()
	merge_key = "world:" + ",".join(PackedStringArray(keys))
	# With the layout at hand, a change to the current values is a no-op.
	if layout != null:
		var same := true
		for c in _changes:
			if not _equal(_current(layout, c), c["value"], c["field"]):
				same = false
				break
		if same:
			_changes.clear()


static func for_theme(layout: FarmLayout, theme_id: String, text: String = "") -> SetWorldStateCommand:
	return SetWorldStateCommand.new([{"field": "theme", "value": theme_id}],
		text if not text.is_empty() else "Theme: %s" % theme_id.capitalize(), layout)


static func for_landmark(layout: FarmLayout, field: String, landmark_id: String, value: Variant, text: String = "") -> SetWorldStateCommand:
	return SetWorldStateCommand.new([{"field": field, "id": landmark_id, "value": value}], text, layout)


func do(layout: FarmLayout) -> void:
	_old = []
	var keys: Array = []
	for c in _changes:
		_old.append(_current(layout, c))
		layout.set_world_value(c["field"], c["id"], c["value"], false)
		keys.append(_key(c))
	if not keys.is_empty():
		layout.world_changed.emit(keys)


func undo(layout: FarmLayout) -> void:
	var keys: Array = []
	for i in range(_changes.size() - 1, -1, -1):
		var c: Dictionary = _changes[i]
		layout.set_world_value(c["field"], c["id"], _old[i], false)
		keys.append(_key(c))
	if not keys.is_empty():
		layout.world_changed.emit(keys)


func is_noop() -> bool:
	return _changes.is_empty()


func merge(other: Command) -> bool:
	## Same fields/landmarks again: keep our original "old" values, take the
	## newer "new" values -> one undo step for the whole gesture.
	if not other is SetWorldStateCommand or other.merge_key != merge_key:
		return false
	var o := other as SetWorldStateCommand
	if o._changes.size() != _changes.size():
		return false
	var newer := {}
	for c in o._changes:
		newer[_key(c)] = c["value"]
	for c in _changes:
		if not newer.has(_key(c)):
			return false
	for c in _changes:
		c["value"] = newer[_key(c)]
	return true


func changes() -> Array:
	return _changes.duplicate(true)


func _default_label() -> String:
	if _changes.size() != 1:
		return "Change farm look"
	var c: Dictionary = _changes[0]
	match str(c["field"]):
		"theme": return "Change theme"
		"landmark_states": return "Change %s state" % str(c["id"]).capitalize()
		"landmark_skins": return "Change %s skin" % str(c["id"]).capitalize()
		"landmark_visible": return "%s %s" % ["Show" if c["value"] == null or bool(c["value"]) else "Hide", str(c["id"]).capitalize()]
	return "Change farm look"


static func _key(c: Dictionary) -> String:
	return "theme" if c["field"] == "theme" else "%s/%s" % [c["field"], c["id"]]


static func _current(layout: FarmLayout, c: Dictionary) -> Variant:
	if c["field"] == "theme":
		var t := layout.theme()
		return null if t == FarmLayout.DEFAULT_THEME else t
	return layout.world_value(c["field"], c["id"])


static func _equal(a: Variant, b: Variant, field: String) -> bool:
	if field == "theme":
		var sa := FarmLayout.DEFAULT_THEME if a == null else str(a)
		var sb := FarmLayout.DEFAULT_THEME if b == null else str(b)
		return sa == sb
	if a == null or b == null:
		return a == null and b == null
	return typeof(a) == typeof(b) and a == b
