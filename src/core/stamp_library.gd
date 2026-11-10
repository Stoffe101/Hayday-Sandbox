class_name StampLibrary
extends RefCounted
## Reusable groups ("stamps"): a named set of items with positions relative to
## the group's top corner, kept as one .hdstamp JSON file per stamp plus a small
## generated thumbnail. Files can be exported and imported between farms.
##
## A stamp never contains a landmark, a landmark duplicate or an item of another
## area: every way in (from_objects, parse) runs the caller's `refuse` check
## (EditorSession.stamp_refusal), and placing re-checks through EditorSession.
##
## A stamp dictionary: {"id", "name", "created", "size": [w, h],
##   "items": [{"item", "x", "y", "flip", "variant", "planned"}]}
## Items may also carry "w" / "h" (the size when saved, used only to draw the
## thumbnail); placing takes footprints from the catalogue, so a corrected item
## size can't be contradicted by an old stamp.

const FORMAT := "hayday-sandbox-stamp"
const VERSION := 1
const EXT := "hdstamp"
const ROOT := "user://stamps"
const MAX_ITEMS := 2000
const MAX_NAME := 60
const MAX_OFFSET := 512          ## largest relative tile offset accepted from a file
const MAX_FILE_BYTES := 4194304  ## imported files are read whole
const THUMB_PX := 96

var root := ROOT


func _init(dir: String = ROOT) -> void:
	root = dir


# --- building & validating ------------------------------------------------------------

static func from_objects(stamp_name: String, objs: Array, refuse: Callable) -> Dictionary:
	## Builds a stamp from PlacedObjects. {"stamp": {} when nothing was usable,
	## "dropped": n, "reason": first refusal text}.
	var kept: Array = []
	var dropped := 0
	var reason := ""
	for o: PlacedObject in objs:
		var why: String = refuse.call(o.item_id)
		if why.is_empty():
			kept.append(o)
		else:
			dropped += 1
			if reason.is_empty():
				reason = why
	if kept.is_empty():
		return {"stamp": {}, "dropped": dropped, "reason": reason}
	var lo := Vector2i(2147483647, 2147483647)
	for o: PlacedObject in kept:
		lo = lo.min(o.origin)
	var items: Array = []
	for o: PlacedObject in kept:
		items.append({"item": o.item_id, "x": o.origin.x - lo.x, "y": o.origin.y - lo.y, "w": o.size.x, "h": o.size.y,
			"flip": o.flipped, "variant": o.variant, "planned": o.planned})
	var stamp := {"id": new_id(), "name": clean_name(stamp_name), "created": Time.get_datetime_string_from_system(true) + "Z",
		"size": _size_of(items), "items": items}
	return {"stamp": stamp, "dropped": dropped, "reason": reason}


static func from_area(layout: FarmLayout, area: Dictionary, refuse: Callable, stamp_name: String = "") -> Dictionary:
	## A planning area as a reusable design: every object with a footprint tile in
	## the area (PlanDoc membership), relative positions kept, refused items left
	## out like from_objects(). {"stamp", "dropped", "reason", "objects": in the area}.
	var objs: Array = []
	for u in PlanDoc.objects_in_area(layout, area):
		var o := layout.get_obj(int(u))
		if o != null:
			objs.append(o)
	var nm := stamp_name if not stamp_name.strip_edges().is_empty() else str(area.get("name", "Area"))
	var r := from_objects(nm, objs, refuse) if not objs.is_empty() else {"stamp": {}, "dropped": 0, "reason": ""}
	r["objects"] = objs.size()
	return r


static func parse(data: Variant, refuse: Callable) -> Dictionary:
	## Validates a parsed file. {"stamp": {} on error, "dropped": n, "reason",
	## "error": text or ""}. Entries that are malformed or refused are dropped;
	## the id is always new, so a file can't address another stamp's path.
	if not data is Dictionary or str(data.get("format", "")) != FORMAT:
		return {"stamp": {}, "dropped": 0, "reason": "", "error": "Not a stamp file"}
	var version: Variant = data.get("version", 0)
	if not (version is int or version is float) or int(version) < 1 or int(version) > VERSION:
		return {"stamp": {}, "dropped": 0, "reason": "", "error": "Unsupported stamp version"}
	var raw: Variant = data.get("items", null)
	if not raw is Array:
		return {"stamp": {}, "dropped": 0, "reason": "", "error": "Stamp has no items"}
	var items: Array = []
	var dropped := 0
	var reason := ""
	for e: Variant in raw:
		var entry := _clean_entry(e)
		if entry.is_empty() or items.size() >= MAX_ITEMS:
			dropped += 1
			continue
		var why: String = refuse.call(str(entry["item"]))
		if not why.is_empty():
			dropped += 1
			if reason.is_empty():
				reason = why
			continue
		items.append(entry)
	if items.is_empty():
		return {"stamp": {}, "dropped": dropped, "reason": reason, "error": "Nothing usable in this stamp"}
	_normalize(items)
	var stamp := {"id": new_id(), "name": clean_name(str(data.get("name", "Imported stamp"))),
		"created": str(data.get("created", "")).left(32), "size": _size_of(items), "items": items}
	return {"stamp": stamp, "dropped": dropped, "reason": reason, "error": ""}


static func _clean_entry(e: Variant) -> Dictionary:
	if not e is Dictionary:
		return {}
	var d: Dictionary = e
	var id := str(d.get("item", ""))
	if id.is_empty() or id.length() > 128 or not _is_number(d.get("x")) or not _is_number(d.get("y")):
		return {}
	var x := int(d["x"])
	var y := int(d["y"])
	if absi(x) > MAX_OFFSET or absi(y) > MAX_OFFSET:
		return {}
	var out := {"item": id, "x": x, "y": y, "flip": d.get("flip") == true, "variant": str(d.get("variant", "")).left(64), "planned": d.get("planned") == true}
	if _is_number(d.get("w")) and _is_number(d.get("h")):
		out["w"] = clampi(int(d["w"]), 1, 64)
		out["h"] = clampi(int(d["h"]), 1, 64)
	return out


static func _is_number(v: Variant) -> bool:
	return v is int or v is float


static func _normalize(items: Array) -> void:
	## Relative positions start at (0, 0), whatever the file said.
	var lo := Vector2i(2147483647, 2147483647)
	for e: Dictionary in items:
		lo = lo.min(Vector2i(e["x"], e["y"]))
	for e: Dictionary in items:
		e["x"] = int(e["x"]) - lo.x
		e["y"] = int(e["y"]) - lo.y


static func _size_of(items: Array) -> Array:
	var hi := Vector2i.ZERO
	for e: Dictionary in items:
		hi = hi.max(Vector2i(int(e["x"]) + int(e.get("w", 1)), int(e["y"]) + int(e.get("h", 1))))
	return [hi.x, hi.y]


static func clean_name(text: String) -> String:
	var t := text.strip_edges().left(MAX_NAME)
	return t if not t.is_empty() else "Stamp"


static func new_id() -> String:
	return "%d_%04x" % [Time.get_ticks_usec(), randi() % 65536]


static func to_text(stamp: Dictionary) -> String:
	var d := stamp.duplicate(true)
	d["format"] = FORMAT
	d["version"] = VERSION
	return JsonUtil.stringify(d, true)


# --- files ------------------------------------------------------------------------------

func path_for(id: String) -> String:
	return root.path_join("%s.%s" % [id, EXT])


func thumb_path(id: String) -> String:
	return root.path_join("%s.png" % id)


func save(stamp: Dictionary, db: ItemDatabase = null) -> Error:
	## Writes the stamp (and its thumbnail when a database is given).
	var id := str(stamp.get("id", ""))
	if not id.is_valid_filename() or id.is_empty():
		return ERR_INVALID_PARAMETER
	var err := JsonUtil.write_atomic(path_for(id), to_text(stamp), false)
	if err != OK:
		return err
	if db != null:
		thumbnail_image(stamp, db).save_png(thumb_path(id))
	return OK


func list() -> Array:
	## Every stored stamp, by name.
	var out: Array = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.get_extension() != EXT:
			continue
		var r := parse(JsonUtil.read_json(root.path_join(f)), func(_id: String) -> String: return "")
		if not (r["stamp"] as Dictionary).is_empty():
			var s: Dictionary = r["stamp"]
			s["id"] = f.get_basename()   # the file name is the identity on disk
			out.append(s)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out


func get_stamp(id: String) -> Dictionary:
	if id.is_empty() or not id.is_valid_filename():
		return {}
	var r := parse(JsonUtil.read_json(path_for(id)), func(_id: String) -> String: return "")
	var s: Dictionary = r["stamp"]
	if not s.is_empty():
		s["id"] = id
	return s


func delete(id: String) -> Error:
	if id.is_empty() or not id.is_valid_filename():
		return ERR_INVALID_PARAMETER
	if FileAccess.file_exists(thumb_path(id)):
		DirAccess.remove_absolute(thumb_path(id))
	return DirAccess.remove_absolute(path_for(id))


func export_file(id: String, path: String) -> Error:
	## Writes a stored stamp to any path (usually chosen in a file dialog).
	var s := get_stamp(id)
	if s.is_empty():
		return ERR_FILE_NOT_FOUND
	return JsonUtil.write_atomic(path, to_text(s), false)


func import_file(path: String, refuse: Callable, db: ItemDatabase = null) -> Dictionary:
	## Reads a .hdstamp file and stores it under a new id. {"stamp", "dropped",
	## "reason", "error"}: `stamp` is {} and `error` says why on failure.
	if not FileAccess.file_exists(path):
		return {"stamp": {}, "dropped": 0, "reason": "", "error": "File not found"}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() > MAX_FILE_BYTES:
		return {"stamp": {}, "dropped": 0, "reason": "", "error": "Can't read this file"}
	var text := f.get_as_text()
	f.close()
	var r := parse(JsonUtil.parse(text), refuse)
	if not (r["stamp"] as Dictionary).is_empty():
		var err := save(r["stamp"], db)
		if err != OK:
			r["error"] = "Can't save the stamp (%s)" % error_string(err)
			r["stamp"] = {}
	return r


# --- thumbnail --------------------------------------------------------------------------

static func thumbnail_image(stamp: Dictionary, db: ItemDatabase, px: int = THUMB_PX) -> Image:
	## A small isometric footprint diagram (category colours), generated from
	## the stamp's own data, so a thumbnail never comes from an imported file.
	var img := Image.create_empty(px, px, false, Image.FORMAT_RGBA8)
	var items: Array = stamp.get("items", [])
	if items.is_empty():
		return img
	var bounds: Array = stamp.get("size", [1, 1])
	var w := maxi(1, int(bounds[0]))
	var h := maxi(1, int(bounds[1]))
	var unit := (px - 4.0) / float(w + h)   # half tile width in pixels
	var half := unit * 0.5
	var top := Vector2((px - (w + h) * unit) * 0.5 + h * unit, (px - (w + h) * half) * 0.5)
	for e: Dictionary in items:
		var it := db.get_item(str(e["item"])) if db else null
		var size := Vector2i(1, 1)
		if it:
			size = it.size_for(bool(e.get("flip", false)))
		elif e.has("w") and e.has("h"):
			size = Vector2i(int(e["w"]), int(e["h"]))
		var col: Color = db.category(it.category)["color"] if db and it else Color(0.6, 0.6, 0.6)
		_fill_diamond(img, top, unit, half, Vector2i(int(e["x"]), int(e["y"])), size, col)
	return img


static func _fill_diamond(img: Image, top: Vector2, unit: float, half: float, o: Vector2i, size: Vector2i, col: Color) -> void:
	## Footprint (o, size) as an isometric diamond, with a darker rim.
	var p := func(gx: float, gy: float) -> Vector2:
		return top + Vector2((gx - gy) * unit, (gx + gy) * half)
	var a: Vector2 = p.call(float(o.x), float(o.y))
	var c: Vector2 = p.call(float(o.x + size.x), float(o.y + size.y))
	var x0 := clampi(floori(p.call(float(o.x), float(o.y + size.y)).x), 0, img.get_width() - 1)
	var x1 := clampi(ceili(p.call(float(o.x + size.x), float(o.y)).x), 0, img.get_width() - 1)
	var y0 := clampi(floori(a.y), 0, img.get_height() - 1)
	var y1 := clampi(ceili(c.y), 0, img.get_height() - 1)
	var rim := col.darkened(0.25)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var g := _to_grid(Vector2(x + 0.5, y + 0.5), top, unit, half)
			if g.x < o.x or g.y < o.y or g.x > o.x + size.x or g.y > o.y + size.y:
				continue
			var edge := minf(minf(g.x - o.x, o.x + size.x - g.x), minf(g.y - o.y, o.y + size.y - g.y))
			img.set_pixel(x, y, rim if edge * unit < 1.2 else col)


static func _to_grid(pt: Vector2, top: Vector2, unit: float, half: float) -> Vector2:
	var a := (pt.x - top.x) / unit
	var b := (pt.y - top.y) / half
	return Vector2((a + b) * 0.5, (b - a) * 0.5)
