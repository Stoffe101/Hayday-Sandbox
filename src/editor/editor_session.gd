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
## Symmetry settings changed (see `symmetry`).
signal tools_changed

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
## Tile selection (Select tool, drag on empty ground): the ground area the
## object selection was made from. null when the selection came from clicks,
## the catalogue, commands, … A drag-move of the selection takes it along
## (move_selection_region); it is dropped when an edit moves a selected object
## off it (undo of that move, resize, …), never by planning or inventory edits.
var selection_region: TileRegion = null
var _region_move := Vector2i.ZERO
var _region_moving := false
var tool: String = "select"
var brush: String = "single"     ## single | line | rect   (place tool)
var active_item: String = ""
var place_flipped := false
var place_variant := ""
var place_planned := false
var clipboard: Array = []        ## [{item, offset: Vector2i, flipped, variant, planned, note}]
var source_path: String = ""     ## file the layout came from ("" = library)
var load_report: LayoutIO.LoadReport
## Keeps "which objects break the placement rules" current incrementally.
var conflict_index: ConflictIndex
## Mirror placement: while on, placing also places the mirrored copy.
## {enabled, kind: LayoutTools.KIND_*, pos} (see LayoutTools for the line maths).
var symmetry := {"enabled": false, "kind": LayoutTools.KIND_SCREEN, "pos": 0}
## Budget of this layout (docs/PLANNING.md §4); null when the session was made
## without a price book (some unit tests). Owned by the session: dispose() disconnects it.
var budget: BudgetEngine
var _analysis: RealisticAnalyzer.Cached


func _init(l: FarmLayout, item_db: ItemDatabase, farm_map: FarmMap, prices: PriceBook = null) -> void:
	layout = l
	db = item_db
	map = farm_map
	stack = CommandStack.new(layout)
	stack.changed.connect(_on_stack_changed)
	layout.objects_removed.connect(_on_removed)
	layout.objects_changed.connect(_on_objects_changed)
	layout.fixed_items = fixed_item_ids(db, map)
	layout.zone_items = PlacementRules.zone_item_ids(db)
	conflict_index = ConflictIndex.new(layout, map)
	_analysis = RealisticAnalyzer.Cached.new(layout, stack, conflict_index)
	symmetry["pos"] = default_mirror_pos(symmetry["kind"])
	if prices != null:
		budget = BudgetEngine.new(layout, db, prices, map)
		# The Realistic report's coin / diamond figures are the budget's To-buy totals.
		_analysis.budget = budget


func dispose() -> void:
	## The session is being replaced: its budget engine lets go of the layout and
	## the shared price book (no handlers left behind on long-lived emitters).
	if budget != null:
		budget.dispose()


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
	if selection_region != null and _region_moving:
		selection_region.translate(_region_move)
	_region_moving = false
	history_changed.emit()


func _on_objects_changed(uids: Array) -> void:
	## A selected object left the selected ground: the area no longer describes the selection.
	if selection_region == null or _region_moving:
		return
	var sel := {}
	for u in selection:
		sel[u] = true
	for u in uids:
		var o := layout.get_obj(u)
		if o != null and sel.has(u) and not selection_region.overlaps(o.rect()):
			selection_region = null
			return


func move_selection_region(delta: Vector2i) -> void:
	## The next command moves the selection by `delta`: the tile area moves with it.
	_region_move = delta
	_region_moving = selection_region != null


func select_tiles(rect: Rect2i, op: String = "replace", keep: Callable = Callable()) -> Array:
	## Tile selection: objects whose footprint overlaps the tile rectangle
	## (groups complete), combined with the current selection by `op`:
	## "replace", "add" (Shift) or "subtract" (Ctrl). Remembers the tile area in
	## selection_region. Returns the objects the rectangle covered.
	clear_landmark_selection()
	var found := layout.expand_to_groups(TileRegion.rect_uids(layout, rect, keep))
	var region: TileRegion = null
	match op:
		"add":
			var have := {}
			for u in selection:
				have[u] = true
			for u in found:
				if not have.has(u):
					selection.append(u)
			region = selection_region.duplicate_region() if selection_region != null else TileRegion.new()
			region.add_rect(rect)
		"subtract":
			var drop := {}
			for u in found:
				drop[u] = true
			selection = selection.filter(func(u): return not drop.has(u))
			if selection_region != null:
				region = selection_region.duplicate_region()
				region.remove_rect(rect)
		_:
			selection = found.duplicate()   # never share the returned array with `selection`
			region = TileRegion.from_rect(rect)
	selection_region = region if region != null and not region.is_empty() and not selection.is_empty() else null
	selection_changed.emit()
	return found


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
	layout.zone_items = PlacementRules.zone_item_ids(db)
	conflict_index.set_map(map)
	_analysis.invalidate()
	if budget != null:
		budget.map = map
		budget.invalidate()
	if not selected_landmark.is_empty() and (map == null or map.landmark(selected_landmark) == null):
		clear_landmark_selection()


func refresh_catalogue_rules() -> void:
	## The catalogue changed (pack reload): items that are landmark copies or
	## water decorations may differ; placement verdicts are re-checked.
	layout.fixed_items = fixed_item_ids(db, map)
	layout.zone_items = PlacementRules.zone_item_ids(db)
	conflict_index.invalidate_all()
	_analysis.invalidate()


func conflicts() -> Dictionary:
	## uid -> PlacementRules.Result for every object breaking the placement rules
	## (same answer as PlacementRules.find_conflicts, kept current incrementally).
	## Shared: don't modify.
	return conflict_index.conflicts()


func analysis() -> RealisticAnalyzer.Report:
	## The Realistic analysis of the document as it is now (recomputed only after
	## a change). Shared: don't modify.
	return _analysis.report(db, map)


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
	selection_region = null
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
	## Only transient / hidden-by-default landmarks can be hidden (Landmark.can_hide):
	## hiding a permanent one would remove it from the farm.
	var lm: Landmark = map.landmark(landmark_id) if map else null
	if lm == null:
		return false
	if not lm.can_hide():
		if not visible:
			message.emit(explain_fixed(landmark_id, "delete"), "info")
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
	selection_region = null
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
	selection_region = null
	if selection.is_empty():
		return
	selection.clear()
	selection_changed.emit()


func select_all(keep: Callable = Callable()) -> void:
	## Every placed object (landmarks are never part of an object selection).
	## `keep(uid) -> bool` leaves objects out (main.gd: those hidden by an object
	## layer, which can't be picked either).
	clear_landmark_selection()
	selection_region = null
	selection = layout.objects.keys()
	if keep.is_valid():
		selection = selection.filter(func(u): return keep.call(int(u)))
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
		if not PlacementRules.check_object(layout, map, o).ok:
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


func cut_selection() -> int:
	## Ctrl+X: copies, then removes exactly the objects that reached the
	## clipboard (one undo step). Objects that can't be copied stay on the farm.
	if _refuse_if_landmark("cut"):
		return 0
	var n := copy_selection()
	if n == 0:
		return 0
	var uids: Array = []
	for o: PlacedObject in selected_objects():
		if can_copy_object(o) and can_remove_object(o):
			uids.append(o.uid)
	if not uids.is_empty():
		execute(EditCommands.RemoveObjects.new(uids, "Cut %d object%s" % [uids.size(), "" if uids.size() == 1 else "s"]))
	return n


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


func place_objects(objs: Array, label: String, mirror: bool = false) -> Array:
	## Adds objects as one undo step. Landmark duplicates and items that can't
	## be placed on the main farm are refused (with a message). With symmetry on,
	## the place tool (and `mirror` callers) also adds what fits of the mirrored copy.
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
	if bool(symmetry["enabled"]) and (mirror or tool == "place"):
		var m := mirrored_objects(ok)
		ok = ok + (m["objs"] as Array)
		if int(m["skipped"]) > 0:
			message.emit("Mirrored copy: %d item%s didn't fit" % [m["skipped"], "" if int(m["skipped"]) == 1 else "s"], "info")
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


# --- layout tools: symmetry ------------------------------------------------------

func default_mirror_pos(kind: String) -> int:
	## A mirror line through the middle of the farm.
	var c: Vector2i = (map.size / 2) if map else Vector2i.ZERO
	return int(LayoutTools.line_for_tile(kind, c)["pos"])


func mirror_line() -> Dictionary:
	return {"kind": symmetry["kind"], "pos": symmetry["pos"]}


func set_symmetry_enabled(on: bool) -> void:
	if bool(symmetry["enabled"]) == on:
		return
	symmetry["enabled"] = on
	tools_changed.emit()


func set_symmetry_kind(kind: String) -> void:
	if not kind in LayoutTools.KINDS or symmetry["kind"] == kind:
		return
	symmetry["kind"] = kind
	symmetry["pos"] = default_mirror_pos(kind)
	tools_changed.emit()


func set_symmetry_tile(t: Vector2i) -> void:
	## Puts the mirror line through tile t.
	symmetry["pos"] = int(LayoutTools.line_for_tile(str(symmetry["kind"]), t)["pos"])
	tools_changed.emit()


func mirrored_objects(objs: Array) -> Dictionary:
	## Fresh PlacedObjects mirroring `objs` over the current line, keeping only
	## copies the placement rules accept (next to `objs` themselves too).
	## {"objs": [...], "skipped": n}. A copy equal to its original is not made.
	var line := mirror_line()
	var rects: Array = []
	for o: PlacedObject in objs:
		rects.append(o.rect())
	var copies: Array = []
	var skipped := 0
	for o: PlacedObject in objs:
		var it := db.get_item(o.item_id)
		var m := LayoutTools.mirror_placement(o.rect(), o.flipped, it != null and it.flippable, line)
		if m.is_empty():
			skipped += 1
			continue
		var r: Rect2i = m["rect"]
		if r == o.rect():
			continue
		var c := o.duplicate_obj()
		c.uid = 0
		c.group_id = 0
		c.origin = r.position
		c.size = r.size
		c.flipped = m["flipped"]
		copies.append(c)
		rects.append(r)
	var fit := LayoutTools.fit_mask(layout, map, rects, {}, LayoutTools.zone_flags(layout, objs) + LayoutTools.zone_flags(layout, copies))
	var out: Array = []
	for i in copies.size():
		if fit[objs.size() + i]:
			out.append(copies[i])
		else:
			skipped += 1
	return {"objs": out, "skipped": skipped}


# --- layout tools: align, distribute, repeat -------------------------------------

func align_selection(op: String) -> bool:
	return _move_each("align", "Align", 2, func(rects: Array) -> Array: return LayoutTools.align_deltas(rects, op))


func distribute_selection(axis: String) -> bool:
	return _move_each("distribute", "Distribute", 3, func(rects: Array) -> Array: return LayoutTools.distribute_deltas(rects, axis))


func _move_each(verb: String, label: String, minimum: int, compute: Callable) -> bool:
	## One undo step moving each selected, movable object by its own delta.
	## Whatever the rules refuse stays where it is.
	if _refuse_if_landmark("move"):
		return false
	var uids := movable_selection()
	if uids.size() < minimum:
		var why := move_refusal_message()
		message.emit(why if not why.is_empty() else "Select at least %d movable objects to %s" % [minimum, verb], "info")
		return false
	var rects: Array = []
	for u in uids:
		rects.append(layout.get_obj(u).rect())
	var fit := LayoutTools.resolve_moves(layout, map, uids, compute.call(rects))
	var moved: Array = fit["uids"]
	if moved.is_empty():
		message.emit("Nothing can move there" if int(fit["skipped"]) > 0 else "Already in place", "info")
		return false
	execute(EditCommands.MoveEach.new(moved, fit["deltas"], label))
	if int(fit["skipped"]) > 0:
		message.emit("%s: %d object%s blocked and left in place" % [label, fit["skipped"], "" if int(fit["skipped"]) == 1 else "s"], "info")
	return true


func repeat_plan(cols: int, rows: int, spacing: Vector2i) -> Dictionary:
	## What repeating the selection as a cols x rows array would do:
	## {"objs": copies that fit, "rects": every wanted rect, "zones": water-decoration
	## flag per rect, "skipped": n}.
	## {} when nothing in the selection may be copied.
	var src: Array = []
	var uids: Array = []
	if not selected_landmark.is_empty():
		return {}
	for o: PlacedObject in selected_objects():
		if can_copy_object(o) and level_block_reason(o.item_id).is_empty():
			src.append(o)
			uids.append(o.uid)
	if src.is_empty():
		return {}
	var rects: Array = []
	var copies: Array = []
	for off: Vector2i in LayoutTools.repeat_offsets(layout.bounds_of(uids).size, cols, rows, spacing):
		for o: PlacedObject in src:
			var c := o.duplicate_obj()
			c.uid = 0
			c.group_id = 0
			c.locked = false
			c.origin += off
			copies.append(c)
			rects.append(c.rect())
	var zones := LayoutTools.zone_flags(layout, copies)
	var fit := LayoutTools.fit_mask(layout, map, rects, {}, zones)
	var out: Array = []
	for i in copies.size():
		if fit[i]:
			out.append(copies[i])
	return {"objs": out, "rects": rects, "zones": zones, "skipped": copies.size() - out.size()}


func apply_repeat(cols: int, rows: int, spacing: Vector2i) -> Array:
	## Adds the array as one undo step; returns the new uids.
	if _refuse_if_landmark("copy"):
		return []
	var plan := repeat_plan(cols, rows, spacing)
	if plan.is_empty():
		message.emit("Select something that can be copied first", "info")
		return []
	var objs: Array = plan["objs"]
	if objs.is_empty():
		message.emit("None of the copies fit", "warn")
		return []
	var uids := place_objects(objs, "Repeat %d object%s" % [objs.size(), "" if objs.size() == 1 else "s"])
	if int(plan["skipped"]) > 0:
		message.emit("Placed %d, skipped %d blocked spot%s" % [uids.size(), plan["skipped"], "" if int(plan["skipped"]) == 1 else "s"], "info")
	return uids


# --- layout tools: stamps ----------------------------------------------------------

func stamp_refusal(item_id: String) -> String:
	## Why a stamp may not contain this item ("" = it may). Unknown items are
	## refused too: nothing could say whether they duplicate a landmark.
	if db == null or db.get_item(item_id) == null:
		return "Unknown item: %s" % item_id
	return item_block_reason(item_id)


func make_stamp(stamp_name: String) -> Dictionary:
	## The selection as a stamp (landmarks and out-of-scope items never enter).
	## {} when there is nothing usable (with a message).
	if _refuse_if_landmark("copy"):
		return {}
	if selection.is_empty():
		message.emit("Select some objects to save as a stamp", "info")
		return {}
	var r := StampLibrary.from_objects(stamp_name, selected_objects(), stamp_refusal)
	if (r["stamp"] as Dictionary).is_empty():
		if not str(r["reason"]).is_empty():
			message.emit(str(r["reason"]), "info")
		return {}
	if int(r["dropped"]) > 0:
		message.emit("Left out of the stamp: %s" % str(r["reason"]), "info")
	return r["stamp"]


func stamp_plan(stamp: Dictionary, at: Vector2i) -> Dictionary:
	## Fresh objects for a stamp with its top corner at `at`, keeping what the
	## catalogue, farm level and placement rules allow.
	## {"objs": those that fit, "rects": every wanted rect, "zones": water-decoration
	## flag per rect, "skipped": n}.
	var wanted: Array = []
	var rects: Array = []
	var skipped := 0
	for e: Dictionary in stamp.get("items", []):
		var id := str(e.get("item", ""))
		var it := db.get_item(id)
		if it == null or not item_block_reason(id).is_empty() or not level_block_reason(id).is_empty():
			skipped += 1
			continue
		var o := make_object(it, at + Vector2i(int(e["x"]), int(e["y"])))
		o.flipped = bool(e.get("flip", false)) and it.flippable
		o.size = it.size_for(o.flipped)
		o.variant = str(e.get("variant", ""))
		o.planned = bool(e.get("planned", false))
		wanted.append(o)
		rects.append(o.rect())
	var zones := LayoutTools.zone_flags(layout, wanted)
	var fit := LayoutTools.fit_mask(layout, map, rects, {}, zones)
	var out: Array = []
	for i in wanted.size():
		if fit[i]:
			out.append(wanted[i])
		else:
			skipped += 1
	return {"objs": out, "rects": rects, "zones": zones, "skipped": skipped}


func place_stamp(stamp: Dictionary, at: Vector2i) -> Array:
	## One undo step (with the mirrored copy when symmetry is on).
	var plan := stamp_plan(stamp, at)
	var objs: Array = plan["objs"]
	if objs.is_empty():
		message.emit("This stamp doesn't fit here", "warn")
		return []
	var uids := place_objects(objs, "Stamp %s" % str(stamp.get("name", "")), true)
	if int(plan["skipped"]) > 0:
		message.emit("Placed %d, skipped %d item%s" % [objs.size(), plan["skipped"], "" if int(plan["skipped"]) == 1 else "s"], "info")
	return uids
