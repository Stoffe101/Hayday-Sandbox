class_name EditorSession
extends RefCounted
## Editing state for the open layout: command stack, selection, active tool,
## active catalogue item, clipboard. High-level edit operations live here so
## UI widgets and keyboard shortcuts share one implementation.
##
## Fixed things (W2 design s7):
##  * Landmarks (farmhouse, truck, ...) are world data (FarmMap.landmarks), not
##    PlacedObjects. They have their own selection (`selected_landmark`, mutually
##    exclusive with the object selection) and no edit operation here can move,
##    rotate, copy, group or delete them: every entry point checks the landmark
##    selection first and answers with explain_fixed() instead.
##  * Catalogue items that duplicate a landmark, and items of other areas
##    (scope != main_farm, e.g. the Fishing Lake), can't be placed, pasted,
##    duplicated or copied (place_objects / set_active_item / copy_selection /
##    clipboard_objects filter them).
##  * Obstacles (ItemDef.movable == false) can be removed but not moved or
##    rotated: editable_selection() (the set drag/nudge move) leaves them out.

signal selection_changed
signal active_item_changed
signal tool_changed
signal mode_changed
signal history_changed
signal message(text: String, kind: String)
## A fixed landmark was selected; "" when the landmark selection was cleared.
signal landmark_selected(id: String)

const TOOLS := ["select", "place", "erase", "pick", "land", "annotate", "pan"]
const OBSTACLE_MOVE_TEXT := "Obstacles can't be moved in Hay Day — remove it and place it again"
const OBSTACLE_ROTATE_TEXT := "Obstacles can't be rotated in Hay Day"

var layout: FarmLayout
var stack: CommandStack
var db: ItemDatabase
var map: FarmMap
var selection: Array = []
## Id of the selected fixed landmark ("" = none). Never part of `selection`.
var selected_landmark: String = ""
var tool: String = "select"
var brush: String = "single"     ## single | line | rect   (place tool)
var active_item: String = ""
var place_flipped := false
var place_variant := ""
var place_planned := false
var clipboard: Array = []        ## [{item, offset: Vector2i, flipped, variant, planned, note}]
var source_path: String = ""     ## file the layout came from ("" = library)
var load_report: LayoutIO.LoadReport


func _init(l: FarmLayout, item_db: ItemDatabase, farm_map: FarmMap) -> void:
	layout = l
	db = item_db
	map = farm_map
	stack = CommandStack.new(layout)
	stack.changed.connect(_on_stack_changed)
	layout.objects_removed.connect(_on_removed)
	layout.fixed_items = fixed_item_ids(db, map)


static func fixed_item_ids(item_db: ItemDatabase, farm_map: FarmMap) -> Dictionary:
	## Item ids (and their aliases) that duplicate a fixed landmark: they can
	## never become placed objects (FarmLayout.fixed_items).
	var out := {}
	if item_db:
		for it in item_db.landmark_items():
			out[it.id] = true
			for a in it.aliases:
				out[a] = true
	if farm_map:
		for lm in farm_map.landmarks:
			for iid in lm.replaces_items:
				out[iid] = true
	return out


func _on_stack_changed() -> void:
	history_changed.emit()


func _on_removed(uids: Array) -> void:
	var before := selection.size()
	for u in uids:
		selection.erase(u)
	if selection.size() != before:
		selection_changed.emit()


func execute(cmd: Command) -> void:
	stack.execute(cmd)


func set_map(m: FarmMap) -> void:
	## The world changed under the open layout (e.g. a private world pack was
	## installed). The layout itself is untouched.
	map = m
	layout.fixed_items = fixed_item_ids(db, map)
	if not selected_landmark.is_empty() and (map == null or map.landmark(selected_landmark) == null):
		clear_landmark_selection()


# --- fixed things ---------------------------------------------------------------

func landmark_for_item(item_id: String) -> String:
	## Id of the landmark the catalogue item duplicates ("" = ordinary item).
	return LayoutIO.landmark_of(db.resolve_id(item_id) if db else item_id, db.get_item(item_id) if db else null, map)


func is_fixed_item(item_id: String) -> bool:
	## True for catalogue copies of a fixed landmark (O(1), see FarmLayout.fixed_items).
	return layout.fixed_items.has(item_id) or (db != null and layout.fixed_items.has(db.resolve_id(item_id)))


func item_block_reason(item_id: String) -> String:
	## Why the item can't be placed / pasted / copied ("" = it can). Unknown
	## (missing) items are not blocked: there is nothing to say about them.
	if is_fixed_item(item_id):
		return explain_fixed(item_id, "place")
	var it := db.get_item(item_id) if db else null
	if it == null:
		return ""
	if not it.can_place():
		return it.not_placeable_reason()
	return ""


func level_block_reason(item_id: String) -> String:
	## Why Realistic mode refuses a NEW copy of the item at this farm level ("" =
	## it doesn't). Covers arming the brush, the eyedropper, paste and duplicate.
	## Objects already on the farm are left alone and listed as issues instead.
	var it := db.get_item(item_id) if db else null
	if it == null:
		return ""
	return RealisticAnalyzer.item_level_block(it, layout.mode, RealisticAnalyzer.farm_level(layout))


func can_move_object(o: PlacedObject) -> bool:
	if o == null or o.locked or is_fixed_item(o.item_id):
		return false
	var it := db.get_item(o.item_id) if db else null
	return it == null or it.movable


func can_rotate_object(o: PlacedObject) -> bool:
	if not can_move_object(o):
		return false
	var it := db.get_item(o.item_id) if db else null
	return it != null and it.flippable


func can_remove_object(o: PlacedObject) -> bool:
	return o != null and not o.locked


func can_copy_object(o: PlacedObject) -> bool:
	return o != null and item_block_reason(o.item_id).is_empty()


func explain_fixed(id: String, action: String = "move") -> String:
	## Short friendly text for why `id` (a landmark id or an item id) refuses
	## `action` (move, drag, nudge, rotate, flip, delete, erase, cut, copy,
	## duplicate, paste, place, group, lock). "" when nothing is fixed about it.
	var lm: Landmark = map.landmark(id) if map else null
	var it: ItemDef = null
	if lm == null:
		it = db.get_item(id) if db else null
		var lid := LayoutIO.landmark_of(db.resolve_id(id) if db else id, it, map)
		if not lid.is_empty():
			lm = map.landmark(lid) if map else null
			if lm == null:
				return _landmark_text(it.name if it else lid.capitalize(), action)
	if lm != null:
		return _landmark_text(lm.name, action)
	if it == null:
		return ""
	if not it.is_in_scope():
		return it.not_placeable_reason()
	if not it.movable:
		match action:
			"rotate", "flip":
				return OBSTACLE_ROTATE_TEXT
			"move", "drag", "nudge":
				return OBSTACLE_MOVE_TEXT
	if not it.placeable and action in ["place", "paste", "copy", "duplicate"]:
		return it.not_placeable_reason()
	return ""


static func _landmark_text(name: String, action: String) -> String:
	var the := name if name.begins_with("The ") else "The " + name
	match action:
		"delete", "erase", "remove", "cut":
			return "%s is part of the farm in Hay Day — it can't be removed." % the
		"copy", "duplicate", "paste", "place":
			return "There is only one %s in Hay Day — it's already part of the farm." % name.trim_prefix("The ")
		"group":
			return "%s is fixed in place in Hay Day — it can't be grouped with objects." % the
		"lock", "planned", "note":
			return "%s is fixed in place in Hay Day — it's always there." % the
	return "%s is fixed in place in Hay Day — it can't be moved or rotated." % the


func _refuse_if_landmark(action: String) -> bool:
	## True (and a subtle message) when a landmark is selected: no object edit
	## applies to it.
	if selected_landmark.is_empty():
		return false
	message.emit(explain_fixed(selected_landmark, action), "info")
	return true


# --- landmark selection & world state ---------------------------------------------

func select_landmark(id: String) -> bool:
	## Selects a fixed landmark (clears the object selection). Returns false for
	## unknown or non-selectable landmarks.
	var lm: Landmark = map.landmark(id) if map else null
	if lm == null or not lm.selectable:
		return false
	if not selection.is_empty():
		selection.clear()
		selection_changed.emit()
	if selected_landmark != id:
		selected_landmark = id
		landmark_selected.emit(id)
	return true


func clear_landmark_selection() -> void:
	if selected_landmark.is_empty():
		return
	selected_landmark = ""
	landmark_selected.emit("")


func selected_landmark_def() -> Landmark:
	return map.landmark(selected_landmark) if map and not selected_landmark.is_empty() else null


func has_selection() -> bool:
	return not selection.is_empty() or not selected_landmark.is_empty()


func set_theme(theme_id: String) -> void:
	execute(SetWorldStateCommand.for_theme(layout, theme_id))


func set_landmark_state(landmark_id: String, state: String) -> bool:
	## state "" = back to the landmark's default state.
	var lm: Landmark = map.landmark(landmark_id) if map else null
	if lm == null or (not state.is_empty() and not lm.has_state(state)):
		return false
	var v: Variant = null if state.is_empty() or state == lm.default_state else state
	execute(SetWorldStateCommand.for_landmark(layout, "landmark_states", landmark_id, v, "%s: %s" % [lm.name, state.replace("_", " ") if not state.is_empty() else "default"]))
	return true


func set_landmark_skin(landmark_id: String, skin_id: String) -> bool:
	## skin "" or "original" = the original look.
	var lm: Landmark = map.landmark(landmark_id) if map else null
	if lm == null or (not skin_id.is_empty() and not lm.has_skin(skin_id)):
		return false
	var v: Variant = null if skin_id.is_empty() or skin_id == "original" else skin_id
	execute(SetWorldStateCommand.for_landmark(layout, "landmark_skins", landmark_id, v, "%s skin" % lm.name))
	return true


func set_landmark_visible(landmark_id: String, visible: bool) -> bool:
	var lm: Landmark = map.landmark(landmark_id) if map else null
	if lm == null:
		return false
	var v: Variant = null if visible == (not lm.hidden_by_default) else visible
	execute(SetWorldStateCommand.for_landmark(layout, "landmark_visible", landmark_id, v, "%s %s" % ["Show" if visible else "Hide", lm.name]))
	return true


# --- tools & items ---------------------------------------------------------

func set_tool(t: String) -> void:
	if not t in TOOLS or t == tool:
		return
	tool = t
	tool_changed.emit()


func set_active_item(id: String) -> void:
	## Landmark duplicates and items of other areas can't become the brush.
	if not id.is_empty():
		var why := item_block_reason(id)
		if why.is_empty():
			why = level_block_reason(id)
		if not why.is_empty():
			message.emit(why, "info")
			return
	active_item = id
	place_variant = ""
	var it := db.get_item(id)
	if it and not it.flippable:
		place_flipped = false
	active_item_changed.emit()
	if not id.is_empty():
		set_tool("place")


func set_mode(m: String) -> void:
	if layout.mode == m:
		return
	layout.mode = m
	layout.meta_changed.emit()
	mode_changed.emit()


# --- selection ---------------------------------------------------------------

func select(uids: Array, additive: bool = false, expand_groups: bool = true) -> void:
	clear_landmark_selection()
	var list := layout.expand_to_groups(uids) if expand_groups else uids.duplicate()
	list = list.filter(func(u): return layout.objects.has(u))
	if additive:
		for u in list:
			if u in selection:
				selection.erase(u)
			else:
				selection.append(u)
	else:
		selection = list
	selection_changed.emit()


func clear_selection() -> void:
	## Clears the object selection and the landmark selection.
	clear_landmark_selection()
	if selection.is_empty():
		return
	selection.clear()
	selection_changed.emit()


func select_all() -> void:
	## Every placed object (landmarks are never part of an object selection).
	clear_landmark_selection()
	selection = layout.objects.keys()
	selection_changed.emit()


func selected_objects() -> Array:
	var out: Array = []
	for u in selection:
		var o := layout.get_obj(u)
		if o:
			out.append(o)
	return out


func editable_selection() -> Array:
	## Uids a MOVE may touch (drag, nudge): unlocked, movable objects. Locked
	## objects, obstacles and landmark duplicates are left out.
	return movable_selection()


func movable_selection() -> Array:
	var out: Array = []
	for o: PlacedObject in selected_objects():
		if can_move_object(o):
			out.append(o.uid)
	return out


func removable_selection() -> Array:
	## Uids Delete/Cut may remove: everything unlocked (obstacles included).
	var out: Array = []
	for o: PlacedObject in selected_objects():
		if can_remove_object(o):
			out.append(o.uid)
	return out


func rotatable_selection() -> Array:
	var out: Array = []
	for o: PlacedObject in selected_objects():
		if can_rotate_object(o):
			out.append(o.uid)
	return out


func move_refusal_message() -> String:
	## Why nothing in the current selection can be moved ("" = something can).
	if not selected_landmark.is_empty():
		return explain_fixed(selected_landmark, "move")
	if selection.is_empty() or not movable_selection().is_empty():
		return ""
	for o: PlacedObject in selected_objects():
		if not o.locked:
			var why := explain_fixed(o.item_id, "move")
			if not why.is_empty():
				return why
	return "Locked objects can't be moved — unlock with L"


# --- edit operations -----------------------------------------------------

func delete_selection() -> void:
	if _refuse_if_landmark("delete"):
		return
	var uids := removable_selection()
	if uids.is_empty():
		if not selection.is_empty():
			message.emit("Selection is locked — unlock it first (L)", "warn")
		return
	execute(EditCommands.RemoveObjects.new(uids))
	message.emit("Deleted %d object%s" % [uids.size(), "" if uids.size() == 1 else "s"], "info")


func nudge(delta: Vector2i) -> bool:
	if _refuse_if_landmark("nudge"):
		return false
	var uids := movable_selection()
	if uids.is_empty():
		var why := move_refusal_message()
		if not why.is_empty():
			message.emit(why, "info")
		return false
	var r := PlacementRules.check_group_move(layout, map, uids, delta)
	if not r.ok:
		message.emit(r.message(layout, db, map), "warn")
		return false
	execute(EditCommands.MoveObjects.new(uids, delta, "Nudge", "nudge"))
	return true


func flip_selection() -> void:
	if _refuse_if_landmark("rotate"):
		return
	var uids: Array = []
	var vals: Array = []
	var obstacle := ""
	for o: PlacedObject in selected_objects():
		if not can_rotate_object(o):
			var it := db.get_item(o.item_id)
			if it and not it.movable and not o.locked and obstacle.is_empty():
				obstacle = explain_fixed(o.item_id, "rotate")
			continue
		uids.append(o.uid)
		vals.append(not o.flipped)
	if uids.is_empty():
		message.emit(obstacle if not obstacle.is_empty() else "Nothing here can be rotated (mirrored) in the game", "warn")
		return
	execute(EditCommands.SetProperty.new(uids, "flipped", vals, "Rotate"))
	var conflicts := 0
	for u in uids:
		var o := layout.get_obj(u)
		if not PlacementRules.check_rect(layout, map, o.rect(), {u: true}).ok:
			conflicts += 1
	if conflicts > 0:
		message.emit("Rotated — %d object(s) now overlap or leave the land (shown in red)" % conflicts, "warn")


func set_flag(prop: String, value: bool, label: String) -> void:
	if _refuse_if_landmark("lock" if prop == "locked" else prop):
		return
	var uids: Array = []
	var vals: Array = []
	for o: PlacedObject in selected_objects():
		if prop != "locked" and o.locked:
			continue
		uids.append(o.uid)
		vals.append(value)
	if not uids.is_empty():
		execute(EditCommands.SetProperty.new(uids, prop, vals, label))


func group_selection() -> void:
	if _refuse_if_landmark("group"):
		return
	var uids: Array = []
	for o: PlacedObject in selected_objects():
		if not o.locked and not is_fixed_item(o.item_id):
			uids.append(o.uid)
	if uids.size() < 2:
		message.emit("Select at least two objects to group", "warn")
		return
	var gid := layout.next_group
	layout.next_group += 1
	layout.groups[gid] = {"name": "Group %d" % gid}
	var vals: Array = []
	vals.resize(uids.size())
	vals.fill(gid)
	execute(EditCommands.SetProperty.new(uids, "group_id", vals, "Group"))
	message.emit("Grouped %d objects — click any member to select the group" % uids.size(), "info")


func ungroup_selection() -> void:
	if _refuse_if_landmark("group"):
		return
	var uids: Array = []
	for o: PlacedObject in selected_objects():
		if o.group_id != 0:
			uids.append(o.uid)
	if uids.is_empty():
		return
	var vals: Array = []
	vals.resize(uids.size())
	vals.fill(0)
	execute(EditCommands.SetProperty.new(uids, "group_id", vals, "Ungroup"))


func copy_selection() -> int:
	## Copies the selected objects that can exist on the farm more than once.
	## Landmarks (and their catalogue duplicates, and items of other areas)
	## never reach the clipboard.
	if _refuse_if_landmark("copy"):
		return 0
	var objs: Array = []
	var refused := ""
	for o: PlacedObject in selected_objects():
		if can_copy_object(o):
			objs.append(o)
		elif refused.is_empty():
			refused = item_block_reason(o.item_id)
	if objs.is_empty():
		if not refused.is_empty():
			message.emit(refused, "info")
		return 0
	if not refused.is_empty():
		message.emit("Some objects were not copied: " + refused, "info")
	clipboard.clear()
	var uids: Array = []
	for o: PlacedObject in objs:
		uids.append(o.uid)
	var r := layout.bounds_of(uids)
	for o: PlacedObject in objs:
		clipboard.append({"item": o.item_id, "offset": o.origin - r.position, "flipped": o.flipped,
			"variant": o.variant, "planned": o.planned, "note": o.note, "size": o.size,
			"group": o.group_id})
	return clipboard.size()


func clipboard_objects(at: Vector2i) -> Array:
	## Fresh PlacedObjects for pasting with the clipboard's top corner at `at`.
	## Groups in the clipboard become new groups. Items that can't be placed
	## are skipped.
	var out: Array = []
	var new_groups := {}
	for c in clipboard:
		if not item_block_reason(str(c["item"])).is_empty() or not level_block_reason(str(c["item"])).is_empty():
			continue
		var o := PlacedObject.new()
		o.item_id = c["item"]
		o.origin = at + (c["offset"] as Vector2i)
		o.flipped = c["flipped"]
		o.size = c["size"]
		o.variant = c["variant"]
		o.planned = c["planned"]
		o.note = c["note"]
		var g: int = c["group"]
		if g != 0:
			if not new_groups.has(g):
				new_groups[g] = layout.next_group
				layout.next_group += 1
				layout.groups[new_groups[g]] = {"name": "Group %d" % new_groups[g]}
			o.group_id = new_groups[g]
		out.append(o)
	return out


func clipboard_size() -> Vector2i:
	var mx := Vector2i.ZERO
	for c in clipboard:
		mx = mx.max((c["offset"] as Vector2i) + (c["size"] as Vector2i))
	return mx


func place_objects(objs: Array, label: String) -> Array:
	## Adds objects as one undo step. Landmark duplicates and items that can't
	## be placed on the main farm are refused (with a message).
	var ok: Array = []
	var refused := ""
	for o: PlacedObject in objs:
		var why := item_block_reason(o.item_id)
		if why.is_empty():
			why = level_block_reason(o.item_id)
		if why.is_empty():
			ok.append(o)
		elif refused.is_empty():
			refused = why
	if not refused.is_empty():
		message.emit(refused, "info")
	if ok.is_empty():
		return []
	var cmd := EditCommands.AddObjects.new(ok, label)
	execute(cmd)
	return cmd.added_uids()


func make_object(item: ItemDef, origin: Vector2i) -> PlacedObject:
	var o := PlacedObject.new()
	o.item_id = item.id
	o.origin = origin
	o.flipped = place_flipped and item.flippable
	o.size = item.size_for(o.flipped)
	o.variant = place_variant
	o.planned = place_planned
	return o
