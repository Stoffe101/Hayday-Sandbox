class_name EditCommands
extends RefCounted
## Concrete undoable commands. Kept in one file so the full edit vocabulary is
## easy to review.


class AddObjects extends Command:
	var _objs: Array = []   ## PlacedObject templates (uids fixed after first do)
	var _uids: Array = []

	func _init(objs: Array, text: String = "") -> void:
		_objs = objs
		label = text if not text.is_empty() else ("Place %d objects" % objs.size() if objs.size() != 1 else "Place object")

	func do(layout: FarmLayout) -> void:
		var copies: Array = []
		for o: PlacedObject in _objs:
			copies.append(o.duplicate_obj())
		_uids = layout.add_objects(copies)
		for i in _objs.size():
			# stable uids across undo/redo (objects the layout refused keep theirs)
			if layout.objects.get(copies[i].uid) == copies[i]:
				_objs[i].uid = copies[i].uid

	func undo(layout: FarmLayout) -> void:
		layout.remove_objects(_uids)

	func is_noop() -> bool:
		return _objs.is_empty()

	func added_uids() -> Array:
		return _uids


class RemoveObjects extends Command:
	var _uids: Array
	var _removed: Array = []

	func _init(uids: Array, text: String = "") -> void:
		_uids = uids.duplicate()
		label = text if not text.is_empty() else ("Delete %d objects" % uids.size() if uids.size() != 1 else "Delete object")

	func do(layout: FarmLayout) -> void:
		_removed = []
		for o in layout.remove_objects(_uids):
			_removed.append(o.duplicate_obj())

	func undo(layout: FarmLayout) -> void:
		var copies: Array = []
		for o: PlacedObject in _removed:
			copies.append(o.duplicate_obj())
		layout.add_objects(copies, true, true)   # put back exactly what was removed

	func is_noop() -> bool:
		return _uids.is_empty()


class MoveObjects extends Command:
	var _uids: Array
	var _delta: Vector2i

	func _init(uids: Array, delta: Vector2i, text: String = "", key: String = "") -> void:
		_uids = uids.duplicate()
		_delta = delta
		label = text if not text.is_empty() else ("Move %d objects" % uids.size() if uids.size() != 1 else "Move object")
		merge_key = key

	func do(layout: FarmLayout) -> void:
		layout.move_objects(_uids, _delta)

	func undo(layout: FarmLayout) -> void:
		layout.move_objects(_uids, -_delta)

	func is_noop() -> bool:
		return _uids.is_empty() or _delta == Vector2i.ZERO

	func merge(other: Command) -> bool:
		if not other is MoveObjects:
			return false
		var m := other as MoveObjects
		var a := _uids.duplicate()
		var b := m._uids.duplicate()
		a.sort()
		b.sort()
		if a != b:
			return false
		_delta += m._delta
		return true


class SetProperty extends Command:
	## Sets PlacedObject.<prop> on several objects. For "flipped" the footprint
	## is swapped too (Hay Day's rotate mirrors the art and the footprint).
	var _uids: Array
	var _prop: String
	var _new: Array
	var _old: Array = []
	var _old_sizes: Array = []

	func _init(uids: Array, prop: String, new_values: Array, text: String = "") -> void:
		_uids = uids.duplicate()
		_prop = prop
		_new = new_values.duplicate()
		label = text if not text.is_empty() else "Change %s" % prop

	func do(layout: FarmLayout) -> void:
		_old = []
		_old_sizes = []
		for u in _uids:
			var o := layout.get_obj(u)
			_old.append(o.get(_prop) if o else null)
			_old_sizes.append(o.size if o else Vector2i.ONE)
		if _prop == "flipped":
			for i in _uids.size():
				var o := layout.get_obj(_uids[i])
				if o and bool(_new[i]) != o.flipped:
					o.flipped = bool(_new[i])
					layout.set_object_rect(o.uid, o.origin, Vector2i(o.size.y, o.size.x), false)
			layout.objects_changed.emit(_uids)
		else:
			layout.set_property(_uids, _prop, _new)

	func undo(layout: FarmLayout) -> void:
		if _prop == "flipped":
			for i in _uids.size():
				var o := layout.get_obj(_uids[i])
				if o:
					o.flipped = bool(_old[i])
					layout.set_object_rect(o.uid, o.origin, _old_sizes[i], false)
			layout.objects_changed.emit(_uids)
		else:
			layout.set_property(_uids, _prop, _old)

	func is_noop() -> bool:
		return _uids.is_empty()


class SetLand extends Command:
	var _old: Array
	var _new: Array

	func _init(old_ids: Array, new_ids: Array, text: String = "Change unlocked land") -> void:
		_old = old_ids.duplicate()
		_new = new_ids.duplicate()
		label = text

	func do(layout: FarmLayout) -> void:
		layout.set_unlocked(_new)

	func undo(layout: FarmLayout) -> void:
		layout.set_unlocked(_old)

	func is_noop() -> bool:
		var a := _old.duplicate()
		var b := _new.duplicate()
		a.sort()
		b.sort()
		return a == b


class SetAnnotations extends Command:
	## Replaces the annotation list (annotations are few; snapshotting is simplest).
	var _old: Array
	var _new: Array

	func _init(old_list: Array, new_list: Array, text: String = "Edit annotation") -> void:
		_old = old_list.duplicate(true)
		_new = new_list.duplicate(true)
		label = text

	func do(layout: FarmLayout) -> void:
		_apply(layout, _new)

	func undo(layout: FarmLayout) -> void:
		_apply(layout, _old)

	func _apply(layout: FarmLayout, list: Array) -> void:
		layout.annotations.clear()
		for a in list:
			layout.annotations.append(a.duplicate(true))
			layout.next_annotation = maxi(layout.next_annotation, int(a.get("id", 0)) + 1)
		layout.annotations_changed.emit()


class SetProfile extends Command:
	var _old: Dictionary
	var _new: Dictionary

	func _init(old_profile: Dictionary, new_profile: Dictionary, text: String = "Edit planning profile") -> void:
		_old = old_profile.duplicate(true)
		_new = new_profile.duplicate(true)
		label = text
		merge_key = "profile"

	func do(layout: FarmLayout) -> void:
		layout.profile = _new.duplicate(true)
		layout.planning_changed.emit()

	func undo(layout: FarmLayout) -> void:
		layout.profile = _old.duplicate(true)
		layout.planning_changed.emit()

	func merge(other: Command) -> bool:
		if other is SetProfile:
			_new = (other as SetProfile)._new.duplicate(true)
			return true
		return false


class SetCameraBookmark extends Command:
	## Stores a saved view in layout.camera.bookmarks[slot]; leaves the current
	## view and the other slots alone.
	var _slot: String
	var _new: Dictionary
	var _old: Variant = null

	func _init(slot: String, view: Dictionary) -> void:
		_slot = slot
		_new = view.duplicate(true)
		label = "Save view %s" % slot

	func do(layout: FarmLayout) -> void:
		var b: Dictionary = layout.camera.get("bookmarks", {})
		_old = b[_slot].duplicate(true) if b.get(_slot) is Dictionary else null
		b[_slot] = _new.duplicate(true)
		layout.camera["bookmarks"] = b

	func undo(layout: FarmLayout) -> void:
		var b: Dictionary = layout.camera.get("bookmarks", {})
		if _old == null:
			b.erase(_slot)
		else:
			b[_slot] = (_old as Dictionary).duplicate(true)
		if b.is_empty():
			layout.camera.erase("bookmarks")
		else:
			layout.camera["bookmarks"] = b


class SetMeta extends Command:
	## Renames the layout.
	var _old: String
	var _new: String

	func _init(old_name: String, new_name: String, text: String = "Rename layout") -> void:
		_old = old_name
		_new = new_name
		label = text

	func do(layout: FarmLayout) -> void:
		layout.name = _new
		layout.meta_changed.emit()

	func undo(layout: FarmLayout) -> void:
		layout.name = _old
		layout.meta_changed.emit()

	func is_noop() -> bool:
		return _old == _new


class SetReference extends Command:
	## Replaces the screenshot-reference settings. An empty dictionary = no reference.
	var _old: Dictionary
	var _new: Dictionary

	func _init(old_settings: Dictionary, new_settings: Dictionary, text: String = "Edit reference", key: String = "") -> void:
		_old = old_settings.duplicate(true)
		_new = new_settings.duplicate(true)
		label = text
		merge_key = key

	func do(layout: FarmLayout) -> void:
		layout.reference = _new.duplicate(true)
		layout.reference_changed.emit()

	func undo(layout: FarmLayout) -> void:
		layout.reference = _old.duplicate(true)
		layout.reference_changed.emit()

	func is_noop() -> bool:
		return _old == _new

	func merge(other: Command) -> bool:
		if other is SetReference:
			_new = (other as SetReference)._new.duplicate(true)
			return true
		return false


class Composite extends Command:
	var _cmds: Array[Command] = []

	func _init(cmds: Array, text: String) -> void:
		for c in cmds:
			if c and not c.is_noop():
				_cmds.append(c)
		label = text

	func do(layout: FarmLayout) -> void:
		for c in _cmds:
			c.do(layout)

	func undo(layout: FarmLayout) -> void:
		for i in range(_cmds.size() - 1, -1, -1):
			_cmds[i].undo(layout)

	func is_noop() -> bool:
		return _cmds.is_empty()


class MoveEach extends Command:
	## Moves each object by its own delta in one step (align, distribute).
	var _uids: Array
	var _deltas: Array

	func _init(uids: Array, deltas: Array, text: String) -> void:
		_uids = uids.duplicate()
		_deltas = deltas.duplicate()
		label = text

	func do(layout: FarmLayout) -> void:
		_apply(layout, 1)

	func undo(layout: FarmLayout) -> void:
		_apply(layout, -1)

	func _apply(layout: FarmLayout, sign_of: int) -> void:
		var moved: Array = []
		for i in _uids.size():
			var o := layout.get_obj(_uids[i])
			if o:
				layout.set_object_rect(o.uid, o.origin + (_deltas[i] as Vector2i) * sign_of, o.size, false)
				moved.append(o.uid)
		layout.objects_changed.emit(moved)

	func is_noop() -> bool:
		return _uids.is_empty()


class SetGeometry extends Command:
	## Sets footprint size and orientation of objects together, keeping each
	## origin (top corner). Used to apply corrected catalogue footprints to an
	## open layout (LayoutIO.reconcile_footprint: an axis-only change toggles
	## `flipped` on the same tiles). values[i] = {"size": Vector2i, "flipped": bool}.
	var _uids: Array
	var _new: Array
	var _old: Array = []

	func _init(uids: Array, values: Array, text: String = "Apply corrected footprints") -> void:
		_uids = uids.duplicate()
		_new = values.duplicate(true)
		label = text

	func do(layout: FarmLayout) -> void:
		_old = []
		for i in _uids.size():
			var o := layout.get_obj(_uids[i])
			_old.append({"size": o.size, "flipped": o.flipped} if o else {})
			if o:
				o.flipped = bool(_new[i].get("flipped", o.flipped))
				layout.set_object_rect(o.uid, o.origin, _new[i].get("size", o.size), false)
		layout.objects_changed.emit(_uids)

	func undo(layout: FarmLayout) -> void:
		for i in _uids.size():
			var o := layout.get_obj(_uids[i])
			if o and not (_old[i] as Dictionary).is_empty():
				o.flipped = bool(_old[i]["flipped"])
				layout.set_object_rect(o.uid, o.origin, _old[i]["size"], false)
		layout.objects_changed.emit(_uids)

	func is_noop() -> bool:
		return _uids.is_empty()
