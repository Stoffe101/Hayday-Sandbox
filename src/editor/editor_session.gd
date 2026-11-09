class_name EditorSession
extends RefCounted
## Editing state for the open layout: command stack, selection, active tool,
## active catalogue item, clipboard. High-level edit operations live here so
## UI widgets and keyboard shortcuts share one implementation.

signal selection_changed
signal active_item_changed
signal tool_changed
signal mode_changed
signal history_changed
signal message(text: String, kind: String)

const TOOLS := ["select", "place", "erase", "pick", "land", "annotate", "pan"]

var layout: FarmLayout
var stack: CommandStack
var db: ItemDatabase
var map: FarmMap
var selection: Array = []
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
	stack.changed.connect(func(): history_changed.emit())
	layout.objects_removed.connect(_on_removed)


func _on_removed(uids: Array) -> void:
	var before := selection.size()
	for u in uids:
		selection.erase(u)
	if selection.size() != before:
		selection_changed.emit()


func execute(cmd: Command) -> void:
	stack.execute(cmd)


# --- tools & items ---------------------------------------------------------

func set_tool(t: String) -> void:
	if not t in TOOLS or t == tool:
		return
	tool = t
	tool_changed.emit()


func set_active_item(id: String) -> void:
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
	var list := layout.expand_to_groups(uids) if expand_groups else uids.duplicate()
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
	if selection.is_empty():
		return
	selection.clear()
	selection_changed.emit()


func select_all() -> void:
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
	## Selection minus locked objects.
	var out: Array = []
	for o: PlacedObject in selected_objects():
		if not o.locked:
			out.append(o.uid)
	return out


# --- edit operations -----------------------------------------------------

func delete_selection() -> void:
	var uids := editable_selection()
	if uids.is_empty():
		if not selection.is_empty():
			message.emit("Selection is locked — unlock it first (L)", "warn")
		return
	execute(EditCommands.RemoveObjects.new(uids))
	message.emit("Deleted %d object%s" % [uids.size(), "" if uids.size() == 1 else "s"], "info")


func nudge(delta: Vector2i) -> bool:
	var uids := editable_selection()
	if uids.is_empty():
		return false
	var r := PlacementRules.check_group_move(layout, map, uids, delta)
	if not r.ok:
		message.emit(r.message(layout, db, map), "warn")
		return false
	execute(EditCommands.MoveObjects.new(uids, delta, "Nudge", "nudge"))
	return true


func flip_selection() -> void:
	var uids: Array = []
	var vals: Array = []
	for o: PlacedObject in selected_objects():
		var it := db.get_item(o.item_id)
		if o.locked or it == null or not it.flippable:
			continue
		uids.append(o.uid)
		vals.append(not o.flipped)
	if uids.is_empty():
		message.emit("Nothing here can be rotated (mirrored) in the game", "warn")
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
	var uids := editable_selection()
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
	clipboard.clear()
	var objs := selected_objects()
	if objs.is_empty():
		return 0
	var r := layout.bounds_of(selection)
	var group_map := {}
	for o: PlacedObject in objs:
		clipboard.append({"item": o.item_id, "offset": o.origin - r.position, "flipped": o.flipped,
			"variant": o.variant, "planned": o.planned, "note": o.note, "size": o.size,
			"group": o.group_id})
	return clipboard.size()


func clipboard_objects(at: Vector2i) -> Array:
	## Fresh PlacedObjects for pasting with the clipboard's top corner at `at`.
	## Groups in the clipboard become new groups.
	var out: Array = []
	var new_groups := {}
	for c in clipboard:
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
	var cmd := EditCommands.AddObjects.new(objs, label)
	execute(cmd)
	for o: PlacedObject in objs:
		if not o.item_id.is_empty():
			pass
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
