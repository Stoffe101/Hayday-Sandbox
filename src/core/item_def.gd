class_name ItemDef
extends RefCounted
## Metadata for one placeable object type. Pure data: no textures here.
## Art is resolved separately by AssetLibrary using `art_key`, so artwork can
## be swapped without touching metadata or saved layouts.

## Confidence levels, best to worst. Used for footprints and general data.
const STATUS_ORDER := ["confirmed", "community", "approximation", "unverified", "unknown", "original"]

var id: String = ""
var name: String = ""
var category: String = "decoration"
var tags: PackedStringArray = PackedStringArray()
var footprint: Vector2i = Vector2i.ONE
## confirmed | community | approximation | unverified | unknown | original
var footprint_status: String = "unverified"
var unlock_level: int = -1           ## -1 = unknown
var cost_coins: int = -1             ## -1 = unknown / not applicable
var cost_diamonds: int = -1
var cost_other: String = ""
var max_count: int = -1              ## -1 = unlimited or unknown
var flippable: bool = false          ## Hay Day "rotate" (mirror) supported
var movable: bool = true
var placeable: bool = true
var connect_group: String = ""       ## items in the same group auto-connect
var connect_style: String = ""       ## "fence" | "path" | ""
## "object" (upright, depth-sorted) or "ground" (flat: paths, tiles — always
## drawn beneath upright objects, which is physically correct for flat items).
var layer: String = "object"
var season: String = ""
var data_status: String = "unverified"
var sources: PackedStringArray = PackedStringArray()
var notes: String = ""
var art_key: String = ""
var variants: Array[Dictionary] = []
var aliases: PackedStringArray = PackedStringArray()
var source_file: String = ""
## Lower-cased text used for catalogue search.
var search_text: String = ""


static func from_dict(d: Dictionary, errors: Array) -> ItemDef:
	## Parses one item record. Appends human-readable problems to `errors` and
	## returns null only when the record is unusable (no id).
	var it := ItemDef.new()
	it.id = str(d.get("id", "")).strip_edges()
	if it.id.is_empty():
		errors.append("item without id: %s" % str(d).left(80))
		return null
	if not _valid_id(it.id):
		errors.append("%s: id must be lowercase snake_case" % it.id)
	it.name = str(d.get("name", it.id))
	it.category = str(d.get("category", "decoration"))
	it.tags = PackedStringArray(_as_array(d.get("tags", [])))
	var fp: Variant = d.get("footprint", null)
	it.footprint_status = str(d.get("footprint_status", "unverified"))
	if fp is Array and fp.size() == 2 and int(fp[0]) > 0 and int(fp[1]) > 0:
		it.footprint = Vector2i(int(fp[0]), int(fp[1]))
	else:
		# Unknown size: keep the item browsable but flag it loudly. A provisional
		# size may be supplied explicitly; otherwise 1x1 is used.
		var prov: Variant = d.get("provisional_footprint", null)
		if prov is Array and prov.size() == 2:
			it.footprint = Vector2i(maxi(1, int(prov[0])), maxi(1, int(prov[1])))
		it.footprint_status = "unknown"
	if not it.footprint_status in STATUS_ORDER:
		errors.append("%s: bad footprint_status '%s'" % [it.id, it.footprint_status])
		it.footprint_status = "unverified"
	it.unlock_level = _int_or(d.get("unlock_level", null), -1)
	var cost: Variant = d.get("cost", {})
	if cost is Dictionary:
		it.cost_coins = _int_or(cost.get("coins", null), -1)
		it.cost_diamonds = _int_or(cost.get("diamonds", null), -1)
		it.cost_other = "" if cost.get("other", null) == null else str(cost.get("other"))
	it.max_count = _int_or(d.get("max_count", null), -1)
	it.flippable = bool(d.get("flippable", false))
	it.movable = bool(d.get("movable", true))
	it.placeable = bool(d.get("placeable", true))
	var conn: Variant = d.get("connect", null)
	if conn is Dictionary:
		it.connect_group = str(conn.get("group", ""))
		it.connect_style = str(conn.get("style", ""))
	it.layer = "ground" if str(d.get("layer", "object")) == "ground" else "object"
	it.season = str(d.get("season", ""))
	it.data_status = str(d.get("data_status", "unverified"))
	it.sources = PackedStringArray(_as_array(d.get("sources", [])))
	it.notes = str(d.get("notes", ""))
	it.art_key = str(d.get("art", it.id))
	for v in _as_array(d.get("variants", [])):
		if v is Dictionary and v.has("id"):
			it.variants.append({"id": str(v["id"]), "name": str(v.get("name", v["id"]))})
	it.aliases = PackedStringArray(_as_array(d.get("aliases", [])))
	it.rebuild_search_text()
	return it


func rebuild_search_text() -> void:
	search_text = (" ".join([name, id.replace("_", " "), category, " ".join(tags), season])).to_lower()


func size_for(flipped: bool) -> Vector2i:
	## Hay Day's "rotate" mirrors the sprite, which swaps the footprint axes.
	return Vector2i(footprint.y, footprint.x) if flipped else footprint


func is_footprint_trusted() -> bool:
	return footprint_status in ["confirmed", "community", "original"]


func has_known_cost() -> bool:
	return cost_coins >= 0 or cost_diamonds >= 0


func to_dict() -> Dictionary:
	var d := {
		"id": id, "name": name, "category": category,
		"footprint": [footprint.x, footprint.y], "footprint_status": footprint_status,
		"unlock_level": null if unlock_level < 0 else unlock_level,
		"cost": {
			"coins": null if cost_coins < 0 else cost_coins,
			"diamonds": null if cost_diamonds < 0 else cost_diamonds,
			"other": null if cost_other.is_empty() else cost_other,
		},
		"max_count": null if max_count < 0 else max_count,
		"flippable": flippable, "movable": movable, "placeable": placeable,
		"data_status": data_status, "art": art_key,
	}
	if not tags.is_empty(): d["tags"] = Array(tags)
	if not connect_group.is_empty(): d["connect"] = {"group": connect_group, "style": connect_style}
	if not season.is_empty(): d["season"] = season
	if layer != "object": d["layer"] = layer
	if not sources.is_empty(): d["sources"] = Array(sources)
	if not notes.is_empty(): d["notes"] = notes
	if not variants.is_empty(): d["variants"] = variants.duplicate(true)
	if not aliases.is_empty(): d["aliases"] = Array(aliases)
	return d


static func _int_or(v: Variant, fallback: int) -> int:
	if v == null:
		return fallback
	if v is int or v is float:
		return int(v)
	if v is String and (v as String).is_valid_int():
		return (v as String).to_int()
	return fallback


static func _as_array(v: Variant) -> Array:
	if v is Array:
		return v
	if v is PackedStringArray:
		return Array(v)
	if v == null:
		return []
	return [v]


static func _valid_id(s: String) -> bool:
	var re := RegEx.create_from_string("^[a-z0-9][a-z0-9_]*$")
	return re.search(s) != null
