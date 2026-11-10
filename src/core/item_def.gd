class_name ItemDef
extends RefCounted
## Metadata for one placeable object type. Pure data: no textures here.
## Art is resolved separately by AssetLibrary using `art_key`, so artwork can
## be swapped without touching metadata or saved layouts.

## Confidence levels, best to worst. Used for footprints and general data.
## "game_data" = read from the user's own game files (private pack catalogue
## overrides, see ItemDatabase.apply_overrides); never present in public data.
const STATUS_ORDER := ["confirmed", "game_data", "community", "approximation", "unverified", "unknown", "original"]
const TRUSTED_STATUSES := ["confirmed", "game_data", "community", "original"]
const STATUS_LABELS := {
	"confirmed": "Confirmed", "game_data": "From your game files (private pack)", "community": "Community data",
	"approximation": "Approximate", "unverified": "Unverified", "unknown": "Size unknown", "original": "Editor item",
}
const SCOPE_MAIN_FARM := "main_farm"
const SCOPES := ["main_farm", "fishing_lake"]
const SCOPE_NAMES := {"main_farm": "the main farm", "fishing_lake": "the Fishing Lake"}

var id: String = ""
var name: String = ""
var category: String = "decoration"
var tags: PackedStringArray = PackedStringArray()
var footprint: Vector2i = Vector2i.ONE
## confirmed | game_data | community | approximation | unverified | unknown | original
var footprint_status: String = "unverified"
var unlock_level: int = -1           ## -1 = unknown
## Values from the public catalogue, kept while a private pack's catalogue
## overrides are applied (ItemDatabase.revert_overrides restores them).
var public_footprint: Vector2i = Vector2i.ONE
var public_footprint_status: String = "unverified"
var public_unlock_level: int = -1
## "" = public catalogue; else the id of the pack whose overrides set footprint/unlock level.
var footprint_source: String = ""
## "" = public catalogue item; else the id of the private pack whose catalogue
## additions (catalog_overrides.json "additions") added this item. Such items come
## from the user's own game files only and disappear when the pack is removed.
var added_by_pack: String = ""
## Id of the fixed world landmark this catalogue entry duplicates ("" = none).
## Such items are kept so old layouts resolve, but are never placeable and are
## hidden from the catalogue (the world layer draws the landmark itself).
var landmark: String = ""
var landmarks: PackedStringArray = PackedStringArray()   ## all duplicated landmarks (first == landmark)
## Where the item exists in the game: "main_farm" (default) or e.g. "fishing_lake".
var scope: String = SCOPE_MAIN_FARM
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
	# Natural obstacles are removed, never moved, in Hay Day.
	it.movable = bool(d.get("movable", it.category != "obstacle"))
	it.placeable = bool(d.get("placeable", true))
	var lms := _as_array(d.get("landmarks", []))
	var lm: Variant = d.get("landmark", null)
	if lm is Array:
		lms = (lm as Array) + lms
	elif lm != null and str(lm) != "":
		lms = [lm] + lms
	for l in lms:
		var ls := str(l).strip_edges()
		if not ls.is_empty() and not ls in it.landmarks:
			if not _valid_id(ls):
				errors.append("%s: landmark id '%s' must be lowercase snake_case" % [it.id, ls])
			it.landmarks.append(ls)
	it.landmark = it.landmarks[0] if not it.landmarks.is_empty() else ""
	it.scope = str(d.get("scope", SCOPE_MAIN_FARM)) if d.get("scope") != null else SCOPE_MAIN_FARM
	if it.scope.is_empty():
		it.scope = SCOPE_MAIN_FARM
	if not _valid_id(it.scope):
		errors.append("%s: bad scope '%s'" % [it.id, it.scope])
		it.scope = SCOPE_MAIN_FARM
	if not it.landmark.is_empty() or it.scope != SCOPE_MAIN_FARM:
		# Landmark duplicates / other areas: never placeable, whatever the record says.
		it.placeable = false
	if not it.landmark.is_empty():
		it.movable = false
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
	it.public_footprint = it.footprint
	it.public_footprint_status = it.footprint_status
	it.public_unlock_level = it.unlock_level
	it.rebuild_search_text()
	return it


func rebuild_search_text() -> void:
	search_text = (" ".join([name, id.replace("_", " "), category, " ".join(tags), season])).to_lower()


func size_for(flipped: bool) -> Vector2i:
	## Hay Day's "rotate" mirrors the sprite, which swaps the footprint axes.
	return Vector2i(footprint.y, footprint.x) if flipped else footprint


func is_footprint_trusted() -> bool:
	return footprint_status in TRUSTED_STATUSES


static func status_label(status: String) -> String:
	## Human text for a footprint/data status ("game_data" -> "From your game files (private pack)").
	return STATUS_LABELS.get(status, status.capitalize())


func is_landmark_duplicate() -> bool:
	return not landmark.is_empty()


func is_in_scope() -> bool:
	return scope == SCOPE_MAIN_FARM


func is_catalogue_hidden() -> bool:
	## Landmark duplicates and items of other areas never show in the catalogue
	## (ItemDatabase.search hides them unless filters.include_hidden).
	return not landmark.is_empty() or scope != SCOPE_MAIN_FARM


func can_place() -> bool:
	return placeable and landmark.is_empty() and scope == SCOPE_MAIN_FARM


func not_placeable_reason() -> String:
	## Why the item can't be placed ("" when it can).
	if not landmark.is_empty():
		return "%s is a fixed landmark — it is already part of the farm" % name
	if scope != SCOPE_MAIN_FARM:
		return "%s belongs to %s, not the main farm" % [name, SCOPE_NAMES.get(scope, scope.replace("_", " "))]
	if not placeable:
		return "%s can't be placed (listed for reference only)" % name
	return ""


func level_state(level: int) -> String:
	## "unlocked" | "locked" | "unknown" for a farm at `level` (unknown unlock
	## levels are never guessed; a negative level means "no level limit").
	if unlock_level < 0:
		return "unknown"
	if level < 0 or unlock_level <= level:
		return "unlocked"
	return "locked"


func has_overrides() -> bool:
	return not footprint_source.is_empty()


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
	if not landmarks.is_empty():
		d["landmark"] = landmark
		if landmarks.size() > 1:
			d["landmarks"] = Array(landmarks)
	if scope != SCOPE_MAIN_FARM: d["scope"] = scope
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
