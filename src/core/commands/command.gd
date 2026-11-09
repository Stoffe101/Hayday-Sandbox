class_name Command
extends RefCounted
## Base class for undoable edits. Subclasses implement do()/undo(); both must
## be exact inverses and must only touch the layout through FarmLayout APIs.

var label: String = "Edit"
## Commands with the same non-empty merge_key issued within MERGE_WINDOW_MS are
## merged into one undo step (e.g. repeated arrow-key nudges).
var merge_key: String = ""
var timestamp_ms: int = 0


func do(_layout: FarmLayout) -> void:
	pass


func undo(_layout: FarmLayout) -> void:
	pass


func merge(_other: Command) -> bool:
	## Absorb a following command; return true when merged.
	return false


func is_noop() -> bool:
	return false
