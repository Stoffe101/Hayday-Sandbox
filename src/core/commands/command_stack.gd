class_name CommandStack
extends RefCounted
## Bounded undo/redo history.

signal changed

const MERGE_WINDOW_MS := 900

var layout: FarmLayout
var max_size: int = 300
var _undo: Array[Command] = []
var _redo: Array[Command] = []
## Number of commands applied since the last save point (negative after
## undoing past it). The document is clean when this is 0.
var _dirty_counter: int = 0
var _save_point_lost := false
## Bumped by every do / undo / redo: "has the document changed since I looked?"
var version: int = 0


func _init(l: FarmLayout = null) -> void:
	layout = l


func execute(cmd: Command) -> void:
	if cmd == null or cmd.is_noop():
		return
	cmd.timestamp_ms = Time.get_ticks_msec()
	cmd.do(layout)
	version += 1
	if not _undo.is_empty() and not cmd.merge_key.is_empty():
		var top := _undo[_undo.size() - 1]
		if top.merge_key == cmd.merge_key and cmd.timestamp_ms - top.timestamp_ms < MERGE_WINDOW_MS and _redo.is_empty() and top.merge(cmd):
			top.timestamp_ms = cmd.timestamp_ms
			_mark_changed()
			changed.emit()
			return
	_undo.append(cmd)
	if _undo.size() > max_size:
		_undo.pop_front()
		if _dirty_counter > _undo.size():
			_save_point_lost = true
	if not _redo.is_empty():
		if _dirty_counter < 0:
			_save_point_lost = true
		_redo.clear()
	_mark_changed()
	changed.emit()


func _mark_changed() -> void:
	_dirty_counter += 1
	layout.touch()


func undo() -> String:
	if _undo.is_empty():
		return ""
	var cmd: Command = _undo.pop_back()
	cmd.undo(layout)
	version += 1
	_redo.append(cmd)
	_dirty_counter -= 1
	layout.touch()
	changed.emit()
	return cmd.label


func redo() -> String:
	if _redo.is_empty():
		return ""
	var cmd: Command = _redo.pop_back()
	cmd.do(layout)
	version += 1
	_undo.append(cmd)
	_dirty_counter += 1
	layout.touch()
	changed.emit()
	return cmd.label


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo_label() -> String:
	return "" if _undo.is_empty() else _undo[_undo.size() - 1].label


func redo_label() -> String:
	return "" if _redo.is_empty() else _redo[_redo.size() - 1].label


func history_labels() -> PackedStringArray:
	var out := PackedStringArray()
	for c in _undo:
		out.append(c.label)
	return out


func clear() -> void:
	_undo.clear()
	_redo.clear()
	_dirty_counter = 0
	_save_point_lost = false
	changed.emit()


func mark_saved() -> void:
	_dirty_counter = 0
	_save_point_lost = false
	changed.emit()


func is_dirty() -> bool:
	return _dirty_counter != 0 or _save_point_lost


func size() -> int:
	return _undo.size()
