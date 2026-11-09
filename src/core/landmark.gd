class_name Landmark
extends RefCounted
## A permanent, fixed structure of the farm world (farmhouse, truck, roadside
## shop, mailbox, ...). Landmarks are NOT PlacedObjects: they never enter
## layout.objects, selections, the clipboard or move/flip/delete commands, so
## moving or rotating one is impossible by construction. They come from the map
## file (`landmarks: [...]`, see docs / W2 design s3) and block placement on the
## tiles listed in `blocks` (default: the footprint rect).
##
## Pure data, no scene/UI/App dependencies: unit-tested in --script mode.

const AREAS := ["farm_side", "road_verge", "across_road", "river", "cliff"]
const DRAW_ANCHORS := ["top_corner", "center"]
const CONFIDENCES := ["verified-in-data", "strong", "plausible", "approximate"]
const SKIN_KINDS := ["", "house", "truck", "roadside_shop"]
## Keys this class understands; anything else is kept verbatim in `extra`
## so newer files survive a round trip.
const KNOWN_KEYS := ["id", "name", "area", "origin", "footprint", "mirrored", "blocks", "draw_anchor", "art",
	"fallback_art", "states", "default_state", "skin_kind", "skins", "themes", "movable", "rotatable",
	"selectable", "transient", "hidden_by_default", "unlock_level", "replaces_items", "evidence", "confidence",
	"game_version", "note"]

var id: String = ""
var name: String = ""
var area: String = "farm_side"
var origin: Vector2i = Vector2i.ZERO        ## top (north) corner tile; may be negative
var footprint: Vector2i = Vector2i.ONE      ## [x, y] = client [TileWidth, TileHeight]
var mirrored: bool = false
## Placement-blocking tile rects. `blocks_explicit == false` means "default =
## footprint rect" (the key was absent); an explicit [] blocks nothing.
var blocks: Array[Rect2i] = []
var blocks_explicit: bool = false
var draw_anchor: String = "top_corner"
var art: String = ""
var fallback_art: String = ""
var states: PackedStringArray = PackedStringArray()
var default_state: String = ""
var skin_kind: String = ""
var skins: Array[Dictionary] = []           ## [{id, name}] (private packs only)
var themes: PackedStringArray = PackedStringArray()
var selectable: bool = true
var transient: bool = false
var hidden_by_default: bool = false
var unlock_level: int = -1                  ## -1 = unknown
var replaces_items: PackedStringArray = PackedStringArray()
var evidence: String = ""
var confidence: String = "approximate"
var game_version: String = ""
var note: String = ""
var extra: Dictionary = {}

## Landmarks can never be moved or rotated (fixed in the game). These are
## constants on purpose: a map file cannot switch them on.
var movable: bool:
	get: return false
var rotatable: bool:
	get: return false


static func from_dict(d: Variant, errors: Array, warnings: Array = []) -> Landmark:
	## Parses and validates one landmark record. Problems that make the record
	## unusable (bad id, origin, footprint, blocks, anchor, states, confidence)
	## go to `errors` and return null; cosmetic issues go to `warnings`.
	if not d is Dictionary:
		errors.append("landmark: not an object")
		return null
	var r: Dictionary = d
	var lm := Landmark.new()
	lm.id = str(r.get("id", "")).strip_edges()
	var tag := "landmark %s" % (lm.id if not lm.id.is_empty() else "?")
	var n_err := errors.size()
	if lm.id.is_empty():
		errors.append("landmark without id")
	elif not _valid_id(lm.id):
		errors.append("%s: id must be lowercase snake_case" % tag)
	lm.name = str(r.get("name", lm.id.capitalize()))
	lm.area = str(r.get("area", "farm_side"))
	if not lm.area in AREAS:
		warnings.append("%s: unknown area '%s'" % [tag, lm.area])
	var o := _vec2i(r.get("origin", null))
	if o.is_empty():
		errors.append("%s: origin must be [x, y] integers" % tag)
	else:
		lm.origin = Vector2i(o[0], o[1])
	var fp := _vec2i(r.get("footprint", null))
	if fp.is_empty() or fp[0] <= 0 or fp[1] <= 0:
		errors.append("%s: footprint must be [w, h] positive integers" % tag)
	else:
		lm.footprint = Vector2i(fp[0], fp[1])
	lm.mirrored = _bool(r.get("mirrored", false))
	if r.has("blocks") and r["blocks"] != null:
		lm.blocks_explicit = true
		if not r["blocks"] is Array:
			errors.append("%s: blocks must be a list of [x, y, w, h]" % tag)
		else:
			for b in r["blocks"]:
				var rect := _rect(b)
				if rect.size.x <= 0 or rect.size.y <= 0:
					errors.append("%s: bad blocks rect %s" % [tag, str(b)])
				else:
					lm.blocks.append(rect)
	lm.draw_anchor = str(r.get("draw_anchor", "top_corner"))
	if not lm.draw_anchor in DRAW_ANCHORS:
		errors.append("%s: draw_anchor must be one of %s" % [tag, ", ".join(DRAW_ANCHORS)])
	lm.art = str(r.get("art", "lm_" + lm.id))
	lm.fallback_art = "" if r.get("fallback_art") == null else str(r.get("fallback_art"))
	lm.states = PackedStringArray(_str_list(r.get("states", [])))
	lm.default_state = "" if r.get("default_state") == null else str(r.get("default_state"))
	if lm.default_state.is_empty() and not lm.states.is_empty():
		lm.default_state = lm.states[0]
	if not lm.states.is_empty() and not lm.default_state in lm.states:
		errors.append("%s: default_state '%s' is not one of its states" % [tag, lm.default_state])
	lm.skin_kind = "" if r.get("skin_kind") == null else str(r.get("skin_kind"))
	if not lm.skin_kind in SKIN_KINDS:
		warnings.append("%s: unknown skin_kind '%s'" % [tag, lm.skin_kind])
	var sk: Variant = r.get("skins", [])
	if sk is Array:
		for s in sk:
			if s is Dictionary and str(s.get("id", "")) != "":
				var entry: Dictionary = (s as Dictionary).duplicate(true)
				entry["id"] = str(s["id"])
				entry["name"] = str(s.get("name", s["id"]))
				lm.skins.append(entry)
			else:
				warnings.append("%s: skin entry without id ignored" % tag)
	lm.themes = PackedStringArray(_str_list(r.get("themes", [])))
	if _bool(r.get("movable", false)) or _bool(r.get("rotatable", false)):
		warnings.append("%s: landmarks are fixed; movable/rotatable ignored" % tag)
	lm.selectable = _bool(r.get("selectable", true))
	lm.transient = _bool(r.get("transient", false))
	lm.hidden_by_default = _bool(r.get("hidden_by_default", false))
	var ul: Variant = r.get("unlock_level", -1)
	lm.unlock_level = int(ul) if (ul is int or ul is float) else -1
	lm.replaces_items = PackedStringArray(_str_list(r.get("replaces_items", [])))
	lm.evidence = str(r.get("evidence", ""))
	lm.confidence = str(r.get("confidence", "approximate"))
	if not lm.confidence in CONFIDENCES:
		errors.append("%s: confidence must be one of %s" % [tag, ", ".join(CONFIDENCES)])
	lm.game_version = "" if r.get("game_version") == null else str(r.get("game_version"))
	lm.note = str(r.get("note", ""))
	for k in r:
		if not str(k) in KNOWN_KEYS:
			lm.extra[str(k)] = r[k]
	if errors.size() > n_err:
		return null
	return lm


func to_dict() -> Dictionary:
	var d := {
		"id": id, "name": name, "area": area,
		"origin": [origin.x, origin.y], "footprint": [footprint.x, footprint.y], "mirrored": mirrored,
		"draw_anchor": draw_anchor, "art": art, "fallback_art": fallback_art,
		"states": Array(states), "default_state": default_state, "skin_kind": skin_kind,
		"skins": skins.duplicate(true), "themes": Array(themes),
		"movable": false, "rotatable": false, "selectable": selectable, "transient": transient,
		"hidden_by_default": hidden_by_default, "unlock_level": unlock_level,
		"replaces_items": Array(replaces_items), "evidence": evidence, "confidence": confidence,
		"game_version": game_version, "note": note,
	}
	if blocks_explicit:
		var bl: Array = []
		for b in blocks:
			bl.append([b.position.x, b.position.y, b.size.x, b.size.y])
		d["blocks"] = bl
	for k in extra:
		if not d.has(k):
			d[k] = extra[k]
	return d


func duplicate_landmark() -> Landmark:
	var errs: Array = []
	return Landmark.from_dict(to_dict(), errs)


func rect() -> Rect2i:
	## Footprint rect in game tiles (may have negative coordinates).
	return Rect2i(origin, footprint)


func block_rects() -> Array[Rect2i]:
	## Tiles this landmark makes unbuildable: `blocks` when given (possibly
	## none), else the whole footprint.
	if blocks_explicit:
		return blocks.duplicate()
	var out: Array[Rect2i] = [rect()]
	return out


func blocks_placement() -> bool:
	## Approximate positions are a visual guide only: they must not raise false
	## conflicts against objects the user could really place there.
	return confidence != "approximate"


func blocks_tile(t: Vector2i) -> bool:
	for r in block_rects():
		if r.has_point(t):
			return true
	return false


func has_state(s: String) -> bool:
	return s in states


func has_skin(skin_id: String) -> bool:
	if skin_id == "original":
		return true
	for s in skins:
		if str(s["id"]) == skin_id:
			return true
	return false


func is_customizable() -> bool:
	return not skin_kind.is_empty()


func can_hide() -> bool:
	## Only landmarks that are not always there in the game (transient, or
	## hidden by default) may be shown / hidden per design; a permanent one is
	## always drawn, whatever a layout file says (hiding = removing it).
	return transient or hidden_by_default


static func _valid_id(s: String) -> bool:
	var re := RegEx.create_from_string("^[a-z0-9][a-z0-9_]*$")
	return re.search(s) != null


static func _is_int(v: Variant) -> bool:
	return v is int or (v is float and is_finite(v) and float(v) == floorf(v))


static func _vec2i(v: Variant) -> Array:
	if not v is Array or (v as Array).size() != 2:
		return []
	if not _is_int(v[0]) or not _is_int(v[1]):
		return []
	return [int(v[0]), int(v[1])]


static func _rect(v: Variant) -> Rect2i:
	if not v is Array or (v as Array).size() != 4:
		return Rect2i()
	for e in v:
		if not _is_int(e):
			return Rect2i()
	return Rect2i(int(v[0]), int(v[1]), int(v[2]), int(v[3]))


static func _bool(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	return false


static func _str_list(v: Variant) -> Array:
	var out: Array = []
	if v is Array or v is PackedStringArray:
		for e in v:
			if e != null and str(e) != "":
				out.append(str(e))
	elif v is String and not (v as String).is_empty():
		out.append(v)
	return out
