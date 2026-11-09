class_name PlacedObject
extends RefCounted
## One object instance on the farm. Stores its own footprint size so a layout
## stays geometrically intact even if the item definition goes missing.

var uid: int = 0
var item_id: String = ""
var origin: Vector2i = Vector2i.ZERO
var size: Vector2i = Vector2i.ONE      ## effective footprint (already flipped)
var flipped: bool = false
var variant: String = ""
var planned: bool = false              ## future-planning ghost (not yet owned/unlocked)
var locked: bool = false               ## protected from accidental edits
var group_id: int = 0
var note: String = ""
var missing: bool = false              ## item id unknown to the current database
var extra: Dictionary = {}             ## unknown save fields, preserved verbatim


func rect() -> Rect2i:
	return Rect2i(origin, size)


func duplicate_obj() -> PlacedObject:
	var o := PlacedObject.new()
	o.uid = uid
	o.item_id = item_id
	o.origin = origin
	o.size = size
	o.flipped = flipped
	o.variant = variant
	o.planned = planned
	o.locked = locked
	o.group_id = group_id
	o.note = note
	o.missing = missing
	o.extra = extra.duplicate(true)
	return o


func to_dict() -> Dictionary:
	var d := extra.duplicate(true)
	d["uid"] = uid
	d["item"] = item_id
	d["x"] = origin.x
	d["y"] = origin.y
	d["w"] = size.x
	d["h"] = size.y
	if flipped: d["flip"] = true
	if not variant.is_empty(): d["variant"] = variant
	if planned: d["planned"] = true
	if locked: d["locked"] = true
	if group_id != 0: d["group"] = group_id
	if not note.is_empty(): d["note"] = note
	return d


const KNOWN_KEYS := ["uid", "item", "x", "y", "w", "h", "flip", "variant", "planned", "locked", "group", "note"]


static func from_dict(d: Dictionary) -> PlacedObject:
	var o := PlacedObject.new()
	o.uid = int(d.get("uid", 0))
	o.item_id = str(d.get("item", ""))
	o.origin = Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	o.size = Vector2i(maxi(1, int(d.get("w", 1))), maxi(1, int(d.get("h", 1))))
	o.flipped = bool(d.get("flip", false))
	o.variant = str(d.get("variant", ""))
	o.planned = bool(d.get("planned", false))
	o.locked = bool(d.get("locked", false))
	o.group_id = int(d.get("group", 0))
	o.note = str(d.get("note", ""))
	for k in d.keys():
		if not k in KNOWN_KEYS:
			o.extra[k] = d[k]
	return o
