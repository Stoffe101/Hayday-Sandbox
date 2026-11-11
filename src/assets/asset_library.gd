class_name AssetLibrary
extends RefCounted
## Resolves item art from layered asset packs.
##
## Pack search order (highest priority wins per art key; ties by pack id):
##   1. user://asset_packs/<pack>/pack.json   (installed/imported by the user, never shipped) 100 + pack priority
##   2. res://assets/original/<pack>/pack.json (developer-local, git-ignored, never exported)   50 + pack priority
##   3. res://assets/placeholders/pack.json    (built-in original art, CC0)                    0
## Each non-built-in pack may carry `overrides.json` (local fine-tuning and
## review decisions, see PackOverrides) and `review.json` (images that still
## need an item). Textures load lazily on first use; per-sprite `thumb` images
## let catalogue thumbnails avoid loading full-size art.
## Missing art is never fatal: callers get null and draw a vector fallback.

const PACK_FORMAT := "hayday-sandbox-asset-pack"
const USER_PACKS := "user://asset_packs"
const DEV_PACKS := "res://assets/original"
const BUILTIN_PACK := "res://assets/placeholders/pack.json"
const BUILTIN_ID := "builtin_placeholders"
const OVERRIDES_FILE := "overrides.json"
const REVIEW_FILE := "review.json"
## Variant id meaning "the base image" even when the pack sets a default_variant.
const BASE_VARIANT := "@base"
## Item art for a world theme is the variant named THEME_VARIANT_PREFIX + theme.
const THEME_VARIANT_PREFIX := "theme_"
## Pack variants "<look>__<theme>" are the client's seasonal skins of a look (themed_variant).
const THEME_SKIN_SEP := "__"


## Ambient animation of a sprite (pack entry field "anim"):
## {"sheet": <image>, "frames": N, "fps": F, "mode": "overlay" | "replace",
##  "columns": <default N>, "anchor": [x, y] <frame pixel at the ground centre, default the sprite's>,
##  "rect": [x, y, w, h], "cell": [cw, ch], "cell_padding": p, "glow_sheet": <image>}.
## With "rect" the frames REPLACE that rectangle of the static image (static-image pixels): each cell (cw x ch
## px, drawn stretched over the rectangle) is a full re-render of it, so nothing is drawn twice; "cell_padding" px
## of edge pixels surround every cell in the sheet; "glow_sheet" holds the frames' additive glow (same cells).
## Such sheets load on first use (an object whose animation is off never loads them).
class AnimInfo:
	var sheet: Texture2D:
		get:
			if sheet == null and not _sheet_path.is_empty():
				sheet = AssetLibrary._load_texture(_sheet_path, _fix_edges)
				_sheet_path = ""
			return sheet
	var glow_sheet: Texture2D:
		get:
			if glow_sheet == null and not _glow_path.is_empty():
				glow_sheet = AssetLibrary._load_texture(_glow_path, _fix_edges)
				_glow_path = ""
			return glow_sheet
	var frames := 1
	var columns := 1
	var fps := 6.0
	var overlay := true          ## false = "replace": the frames take the place of the static image
	var frame_size := Vector2.ZERO
	var anchor := Vector2.ZERO
	var rect := Rect2()          ## "rect" (static px); empty = frames are whole images at `anchor`
	var padding := 0             ## "cell_padding"
	var has_glow := false        ## the sheet has a glow sheet
	var _sheet_path := ""
	var _glow_path := ""
	var _fix_edges := true

	func frame_rect(i: int) -> Rect2:
		var f := posmod(i, frames)
		var cell := frame_size + Vector2(2 * padding, 2 * padding)
		return Rect2(Vector2(f % columns, f / columns) * cell + Vector2(padding, padding), frame_size)

	func has_rect() -> bool:
		return rect.size.x > 0.0 and rect.size.y > 0.0

	func loaded_sheets() -> Array[Texture2D]:
		## The sheets already in memory (never loads one).
		var out: Array[Texture2D] = []
		if _sheet_path.is_empty() and sheet != null:
			out.append(sheet)
		if has_glow and _glow_path.is_empty() and glow_sheet != null:
			out.append(glow_sheet)
		return out

	func world_rect(center: Vector2, flipped: bool, sprite_scale: float) -> Rect2:
		var sz := (rect.size if has_rect() else frame_size) * sprite_scale
		var pos := center - (anchor - rect.position if has_rect() else anchor) * sprite_scale
		if flipped:
			pos.x = center.x - (pos.x - center.x) - sz.x
		return Rect2(pos, sz)


class SpriteInfo:
	var texture: Texture2D
	var anchor: Vector2          ## texture pixel at the footprint's ground centre
	var scale: float = 0.5       ## world px per texture px
	var shadow: Texture2D
	var shadow_anchor: Vector2
	var shadow_mirrored := false ## `shadow` is the base sprite's: draw it flipped (only on a mirror sprite)
	var pack_id: String = ""
	var path: String = ""
	var variant: String = ""     ## variant actually used ("" = base sprite)
	var anim: AnimInfo           ## null = static
	var glow: Texture2D          ## additive layer over the sprite (pack field "glow"), same size and anchor; null = none
	var mirror: SpriteInfo       ## drawn unflipped instead of flipping this sprite (pack field "mirror")
	var _hit: BitMap
	var _hit_failed := false

	func world_rect(center: Vector2, flipped: bool) -> Rect2:
		var sz := texture.get_size() * scale
		var pos := center - anchor * scale
		if flipped:
			pos.x = center.x - (sz.x - anchor.x * scale)
		return Rect2(pos, sz)

	func hit(center: Vector2, flipped: bool, world_pos: Vector2) -> bool:
		## Pixel-accurate (alpha) hit test.
		var r := world_rect(center, flipped)
		if not r.has_point(world_pos):
			return false
		if _hit == null and not _hit_failed:
			var img := texture.get_image()
			if img == null:
				_hit_failed = true
			else:
				if img.is_compressed():
					img.decompress()
				_hit = BitMap.new()
				_hit.create_from_image_alpha(img, 0.25)
		if _hit == null:
			return true
		var local := (world_pos - r.position) / scale
		if flipped:
			local.x = texture.get_width() - 1 - local.x
		var p := Vector2i(clampi(int(local.x), 0, _hit.get_size().x - 1), clampi(int(local.y), 0, _hit.get_size().y - 1))
		return _hit.get_bitv(p)


var packs: Array[Dictionary] = []      ## sorted, highest priority first
var errors: PackedStringArray = PackedStringArray()
var db: ItemDatabase                   ## optional: resolves overrides "assign" (item -> art key + footprint)
var user_packs_dir := USER_PACKS
var dev_packs_dir := DEV_PACKS
var builtin_pack_path := BUILTIN_PACK
var texture_loads := 0                 ## full-size sprite images decoded (lazy-loading diagnostics)
var thumb_loads := 0                   ## thumbnail images decoded
var _cache: Dictionary = {}            ## "key|variant|mask|scope" -> SpriteInfo or null
var _thumb_cache: Dictionary = {}      ## "key|variant|mask" -> Texture2D or null
var _tex_cache: Dictionary = {}        ## file path -> Texture2D (shared between keys/variants)
var _stats_cache: Dictionary = {}      ## pack id -> stats
var _item_themes: Variant = null       ## cached item_themes() (null = not computed)
var _terrain_cache: Dictionary = {}    ## manifest path -> TerrainPack (parsed once per load_all)


func load_all(item_db: ItemDatabase = null) -> void:
	if item_db:
		db = item_db
	packs.clear()
	_terrain_cache.clear()
	_cache.clear()
	_thumb_cache.clear()
	_tex_cache.clear()
	_stats_cache.clear()
	_item_themes = null
	errors.clear()
	_load_pack(builtin_pack_path, 0)
	_scan_dir(dev_packs_dir, 50)
	_scan_dir(user_packs_dir, 100)
	packs.sort_custom(_pack_order)
	# Terrain manifests are small: parse them now so their problems are listed
	# with the other pack diagnostics (images load only when drawn).
	for p in packs:
		var tp := pack_terrain(str(p["id"]))
		if tp:
			for e in tp.diagnostics():
				errors.append("%s: %s" % [p["id"], e])


static func _pack_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] > b["priority"]
	return str(a["id"]) < str(b["id"])


func _scan_dir(dir_path: String, base_priority: int) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var subs := Array(dir.get_directories())
	subs.sort()
	for sub: String in subs:
		if sub.begins_with("."):
			continue   # hidden, or an install in progress (PackInstaller temp dirs)
		_load_pack(dir_path.path_join(sub).path_join("pack.json"), base_priority)


func _load_pack(path: String, base_priority: int) -> void:
	if not FileAccess.file_exists(path):
		return
	var data: Variant = JsonUtil.read_json(path)
	if not data is Dictionary or str(data.get("format", "")) != PACK_FORMAT:
		errors.append("Invalid asset pack: %s" % path)
		return
	var sprites: Variant = data.get("sprites", {})
	if not sprites is Dictionary:
		errors.append("Asset pack has no sprites: %s" % path)
		return
	var base := path.get_base_dir()
	var builtin := path == builtin_pack_path
	var id := str(data.get("id", base.get_file()))
	var n := 2
	var unique := id
	while not pack_by_id(unique).is_empty():
		unique = "%s_%d" % [id, n]
		n += 1
	var p := {
		"id": unique,
		"name": str(data.get("name", "")),
		"license": str(data.get("license", "unknown")),
		"priority": base_priority + int(data.get("priority", 0)),
		"ppw": float(data.get("pixels_per_world_px", 1.0)),
		"base": base,
		"path": path,
		"builtin": builtin,
		"version": str(data.get("version", "")),
		"provenance": data.get("provenance", {}),
		"art_kind": str(data.get("art_kind", "placeholder" if builtin else "original")),
		## true when the pack's images already carry colour under transparent edges
		## (build_pack.py bleeds it), so the runtime alpha-edge fix can be skipped.
		"alpha_bleed": bool(data.get("alpha_bleed", false)),
		"writable": not builtin and (base.begins_with("user://") or not OS.has_feature("template")),
		"raw_sprites": sprites,
		"sprites": sprites,
		"overrides": PackOverrides.empty(),
		"override_errors": [],
		"rejected": {}, "verified": {}, "assigned": {},
		"_measure": {},
		## pack.json "world" / "catalog_overrides" / "terrain" (safe pack-relative paths, "" = none)
		"data_files": _declared_data_files(data),
	}
	if not builtin:
		var ov_path := base.path_join(OVERRIDES_FILE)
		if FileAccess.file_exists(ov_path):
			var errs: Array = []
			p["overrides"] = PackOverrides.parse(JsonUtil.read_json(ov_path), errs)
			p["override_errors"] = errs
			for e in errs:
				errors.append("%s: %s" % [unique, e])
		_apply_overrides(p)
	packs.append(p)


func _apply_overrides(p: Dictionary) -> void:
	var ov: Dictionary = p["overrides"]
	if (ov.get("sprites", {}) as Dictionary).is_empty() and (ov.get("assign", {}) as Dictionary).is_empty():
		p["sprites"] = p["raw_sprites"]
		p["rejected"] = {}
		p["assigned"] = {}
		var ver := {}
		for k in p["raw_sprites"]:
			if p["raw_sprites"][k] is Dictionary and bool(p["raw_sprites"][k].get("verified", false)):
				ver[k] = true
		p["verified"] = ver
		p["apply_errors"] = []
		return
	var res := PackOverrides.apply(p["raw_sprites"], ov, _item_info, func(rel: String) -> Dictionary: return _measure(p, rel))
	p["sprites"] = res["sprites"]
	p["rejected"] = res["rejected"]
	p["verified"] = res["verified"]
	p["assigned"] = res["assigned"]
	p["apply_errors"] = res["errors"]
	for e in res["errors"]:
		errors.append("%s: %s" % [p["id"], e])


func _item_info(item_id: String) -> Dictionary:
	if db == null:
		return {"art_key": item_id, "footprint": Vector2i.ONE}
	var it := db.get_item(item_id)
	if it == null:
		return {}
	return {"art_key": it.art_key, "footprint": it.footprint}


func _measure(p: Dictionary, rel: String) -> Dictionary:
	var m: Dictionary = p["_measure"]
	if m.has(rel):
		return m[rel]
	var img := _load_image(str(p["base"]).path_join(rel))
	var out := {}
	if img:
		if img.is_compressed():
			img.decompress()
		out = {"size": img.get_size(), "used": img.get_used_rect()}
	m[rel] = out
	return out


const DATA_FILE_KEYS := ["world", "catalog_overrides", "terrain"]


static func _declared_data_files(data: Dictionary) -> Dictionary:
	var out := {}
	for k in DATA_FILE_KEYS:
		var v: Variant = data.get(k, null)
		out[k] = PackOverrides.safe_rel_path(str(v)) if v is String else ""
	return out


func world_data_files() -> Array[Dictionary]:
	## Installed (non built-in) packs that declare world data in pack.json,
	## highest priority first. Each entry: {pack_id, name, version, priority,
	## base, world, catalog_overrides, terrain} where the three file entries are
	## full paths ("" when the pack does not declare that file; existence is
	## not checked here). Feed it to WorldLoader.load() / ItemDatabase.apply_overrides().
	var out: Array[Dictionary] = []
	for p in packs:
		if bool(p.get("builtin", false)):
			continue
		var df: Dictionary = p.get("data_files", {})
		var e := {"pack_id": str(p["id"]), "name": str(p.get("name", "")), "version": str(p.get("version", "")),
			"priority": int(p.get("priority", 0)), "base": str(p.get("base", ""))}
		var any := false
		for k in DATA_FILE_KEYS:
			var rel := str(df.get(k, ""))
			e[k] = "" if rel.is_empty() else str(p["base"]).path_join(rel)
			any = any or not rel.is_empty()
		if any:
			out.append(e)
	return out


# --- queries ---------------------------------------------------------------------

func pack_list() -> Array[Dictionary]:
	## Each entry: id, name, license, priority, version, provenance, art_kind,
	## builtin, writable, base, sprites (merged), raw_sprites, overrides, …
	return packs


func pack_by_id(id: String) -> Dictionary:
	for p in packs:
		if p["id"] == id:
			return p
	return {}


func has_art(art_key: String) -> bool:
	for p in packs:
		if p["sprites"].has(art_key):
			return true
	return false


func art_source(art_key: String) -> String:
	## Which pack provides this art ("" when none).
	for p in packs:
		if p["sprites"].has(art_key):
			return p["id"]
	return ""


func pack_of(art_key: String) -> Dictionary:
	for p in packs:
		if p["sprites"].has(art_key):
			return p
	return {}


func entry_of(art_key: String) -> Dictionary:
	## The winning (merged) pack entry for an art key, {} if none.
	for p in packs:
		var e: Variant = p["sprites"].get(art_key)
		if e is Dictionary:
			return e
	return {}


func art_status(art_key: String) -> String:
	## "original" (art from an installed/imported pack), "placeholder" or "none".
	var p := pack_of(art_key)
	if p.is_empty():
		return "none"
	return "placeholder" if p["art_kind"] == "placeholder" else "original"


func is_verified(art_key: String) -> bool:
	return bool(entry_of(art_key).get("verified", false))


func needs_review(art_key: String) -> bool:
	return art_status(art_key) == "original" and not is_verified(art_key)


func rejected_in(art_key: String) -> String:
	## Id of the pack whose sprite for this key the user rejected ("" = none).
	for p in packs:
		if (p["rejected"] as Dictionary).has(art_key):
			return p["id"]
	return ""


func is_rejected(art_key: String) -> bool:
	return not rejected_in(art_key).is_empty()


func variants_of(art_key: String) -> Array:
	## Variant ids offered by the winning pack for this art key (sorted).
	var e := entry_of(art_key)
	var out: Array = []
	if e.get("variants") is Dictionary:
		for k in e["variants"]:
			out.append(str(k))
	out.sort()
	return out


func default_variant_of(art_key: String) -> String:
	return str(entry_of(art_key).get("default_variant", ""))


func themed_variant(art_key: String, variant: String, theme: String) -> String:
	## The variant to draw under a world theme, when the winning pack really has
	## it (a look is never invented); otherwise `variant` unchanged:
	## * "theme_<theme>" for an object without a variant of its own;
	## * "<look>__<theme>": the client's own seasonal skin of that look ("" / BASE_VARIANT
	##   = the base image, e.g. "__winter", "lvl_2__winter"), as LandmarkView does for landmarks.
	if theme.is_empty() or theme == FarmLayout.DEFAULT_THEME:
		return variant
	var vs: Variant = entry_of(art_key).get("variants")
	if not vs is Dictionary:
		return variant
	if variant.is_empty() and (vs as Dictionary).has(THEME_VARIANT_PREFIX + theme):
		return THEME_VARIANT_PREFIX + theme
	if variant.find(THEME_SKIN_SEP) >= 0:
		return variant   # already a seasonal skin, chosen by hand
	var look := variant
	if look.is_empty():
		look = default_variant_of(art_key)
	elif look == BASE_VARIANT:
		look = ""
	var skin := look + THEME_SKIN_SEP + theme
	return skin if (vs as Dictionary).has(skin) else variant


func has_theme_variants(art_key: String) -> bool:
	var vs: Variant = entry_of(art_key).get("variants")
	if vs is Dictionary:
		for k: String in vs:
			if k.begins_with(THEME_VARIANT_PREFIX) or k.find(THEME_SKIN_SEP) >= 0:
				return true
	return false


func item_themes() -> Array:
	## Every theme that some item sprite has real art for (sorted, cached).
	if _item_themes == null:
		var found := {}
		for p in packs:
			for key in p["sprites"]:
				var e: Variant = p["sprites"][key]
				if e is Dictionary and (e as Dictionary).get("variants") is Dictionary:
					for k: String in e["variants"]:
						if k.begins_with(THEME_VARIANT_PREFIX):
							found[k.substr(THEME_VARIANT_PREFIX.length())] = true
						elif k.find(THEME_SKIN_SEP) >= 0:
							found[k.substr(k.find(THEME_SKIN_SEP) + THEME_SKIN_SEP.length())] = true
		var list: Array = found.keys()
		list.sort()
		_item_themes = list
	return _item_themes


func overrides_of(pack_id: String, art_key: String) -> Dictionary:
	var p := pack_by_id(pack_id)
	if p.is_empty():
		return {}
	return (p["overrides"]["sprites"] as Dictionary).get(art_key, {})


func get_sprite(art_key: String, variant: String = "", mask: int = -1) -> SpriteInfo:
	var ck := "%s|%s|%d|" % [art_key, variant, mask]
	if _cache.has(ck):
		return _cache[ck]
	var info: SpriteInfo = null
	for p in packs:
		var e: Variant = p["sprites"].get(art_key)
		if not e is Dictionary:
			continue
		info = _info_from(p, e, variant, mask)
		if info != null:
			break
	_cache[ck] = info
	return info


func get_sprite_in_pack(pack_id: String, art_key: String, variant: String = "", mask: int = -1, include_rejected: bool = false) -> SpriteInfo:
	## A sprite from one specific pack (e.g. to compare original vs placeholder).
	var ck := "%s|%s|%d|@%s%s" % [art_key, variant, mask, pack_id, "+r" if include_rejected else ""]
	if _cache.has(ck):
		return _cache[ck]
	var info: SpriteInfo = null
	var p := pack_by_id(pack_id)
	if not p.is_empty():
		var e: Variant = p["sprites"].get(art_key)
		if not e is Dictionary and include_rejected:
			e = p["raw_sprites"].get(art_key)
		if e is Dictionary:
			info = _info_from(p, e, variant, mask)
	_cache[ck] = info
	return info


func placeholder_pack_id() -> String:
	for p in packs:
		if p["builtin"]:
			return p["id"]
	return ""


func get_thumbnail(art_key: String, variant: String = "", mask: int = -1) -> Texture2D:
	## Small preview image: the sprite's `thumb` file when the pack provides
	## one (so browsing the catalogue never decodes full-size art), else the
	## sprite texture itself.
	var ck := "%s|%s|%d" % [art_key, variant, mask]
	if _thumb_cache.has(ck):
		return _thumb_cache[ck]
	var tex: Texture2D = null
	for p in packs:
		var e: Variant = p["sprites"].get(art_key)
		if not e is Dictionary:
			continue
		var entry: Dictionary = _resolve(e, variant, mask)[0]
		var thumb := str(entry.get("thumb", ""))
		if not thumb.is_empty():
			tex = _texture(str(p["base"]).path_join(thumb), true)
		if tex == null:
			# Just the image: a catalogue thumbnail never needs the sprite's shadow.
			var file := str(entry.get("file", ""))
			if not file.is_empty():
				tex = _texture(str(p["base"]).path_join(file), false, not p.get("alpha_bleed", false))
		if tex == null:
			var info := get_sprite(art_key, variant, mask)
			tex = info.texture if info else null
		break
	_thumb_cache[ck] = tex
	return tex


func connection_masks(art_key: String) -> Dictionary:
	for p in packs:
		var e: Variant = p["sprites"].get(art_key)
		if e is Dictionary:
			var out := {}
			if e.get("connections") is Dictionary:
				for k in e["connections"]:
					out[int(k)] = true
			return out
	return {}


func _resolve(e: Dictionary, variant: String, mask: int) -> Array:
	## -> [entry, variant actually used]
	var entry := e
	var used := ""
	var v := variant if not variant.is_empty() else str(e.get("default_variant", ""))
	if variant == BASE_VARIANT:
		v = ""
	if not v.is_empty() and e.get("variants") is Dictionary and (e["variants"] as Dictionary).get(v) is Dictionary:
		entry = _inherit(e, e["variants"][v])
		used = v
	if mask >= 0 and entry.get("connections") is Dictionary:
		var conns: Dictionary = entry["connections"]
		var avail := {}
		for k in conns:
			avail[int(k)] = true
		var best := Connections.best_variant(mask, avail)
		if best >= 0 and conns.get(str(best)) is Dictionary:
			entry = conns[str(best)]
	return [entry, used]


static func _inherit(base: Dictionary, v: Dictionary) -> Dictionary:
	## Variants share their base sprite's resolution unless they say otherwise.
	var out := v
	for f in ["pixels_per_world_px", "scale"]:
		if not v.has(f) and base.has(f):
			if out == v:
				out = v.duplicate()
			out[f] = base[f]
	return out


func _info_from(p: Dictionary, e: Dictionary, variant: String, mask: int) -> SpriteInfo:
	var r := _resolve(e, variant, mask)
	var info := _make_info(p, r[0])
	if info:
		info.variant = r[1]
	return info


func _make_info(pack: Dictionary, entry: Dictionary) -> SpriteInfo:
	var file := str(entry.get("file", ""))
	if file.is_empty():
		return null
	var tex := _texture(str(pack["base"]).path_join(file), false, not pack.get("alpha_bleed", false))
	if tex == null:
		errors.append("Missing image %s in pack %s" % [file, pack["id"]])
		return null
	var info := SpriteInfo.new()
	info.texture = tex
	info.pack_id = pack["id"]
	info.path = file
	var a: Variant = entry.get("anchor", null)
	if a is Array and a.size() == 2:
		info.anchor = Vector2(float(a[0]), float(a[1]))
	else:
		# Default anchor: bottom-centre of the image.
		info.anchor = Vector2(tex.get_width() * 0.5, tex.get_height())
	var ppw := float(entry.get("pixels_per_world_px", pack["ppw"]))
	info.scale = 1.0 / maxf(0.01, ppw) * float(entry.get("scale", 1.0))
	var sh: Variant = entry.get("shadow", null)
	if sh is Dictionary:
		var stex := _texture(str(pack["base"]).path_join(str(sh.get("file", ""))), false, not pack.get("alpha_bleed", false))
		if stex:
			info.shadow = stex
			var sa: Array = sh.get("anchor", [stex.get_width() * 0.5, stex.get_height() * 0.5])
			info.shadow_anchor = Vector2(float(sa[0]), float(sa[1]))
	info.glow = _glow_from(pack, entry, info)
	info.anim = _anim_from(pack, entry, info)
	var mv: Variant = entry.get("mirror", null)
	if mv is Dictionary:
		var mi := _make_info(pack, _inherit(entry, mv))
		if mi:
			if mi.shadow == null and info.shadow != null:
				mi.shadow = info.shadow
				mi.shadow_anchor = info.shadow_anchor
				mi.shadow_mirrored = true
			info.mirror = mi
	return info


func _anim_from(pack: Dictionary, entry: Dictionary, info: SpriteInfo) -> AnimInfo:
	## null when the entry has no usable "anim" (a bad one is reported, the sprite stays static).
	var d: Variant = entry.get("anim", null)
	if not d is Dictionary:
		return null
	var rel := PackOverrides.safe_rel_path(str((d as Dictionary).get("sheet", "")))
	var frames := int(d.get("frames", 0))
	var fps := float(d.get("fps", 0.0))
	if rel.is_empty() or frames < 1 or fps <= 0.0:
		errors.append("Bad animation on %s in pack %s" % [info.path, pack["id"]])
		return null
	var a := AnimInfo.new()
	a.frames = frames
	a.columns = clampi(int(d.get("columns", frames)), 1, frames)
	a.fps = fps
	a.overlay = str(d.get("mode", "overlay")) != "replace"
	var an: Variant = d.get("anchor", null)
	a.anchor = Vector2(float(an[0]), float(an[1])) if an is Array and (an as Array).size() == 2 else info.anchor
	var path := str(pack["base"]).path_join(rel)
	var rc: Variant = d.get("rect", null)
	var cell: Variant = d.get("cell", null)
	if rc is Array and (rc as Array).size() == 4 and cell is Array and (cell as Array).size() == 2:
		# Patch animation: lazily loaded sheet, frames replace a rectangle of the static image.
		a.rect = Rect2(float(rc[0]), float(rc[1]), float(rc[2]), float(rc[3]))
		a.frame_size = Vector2(float(cell[0]), float(cell[1]))
		a.padding = maxi(0, int(d.get("cell_padding", 0)))
		a.anchor = info.anchor
		a.overlay = false
		var tex_rect := Rect2(Vector2.ZERO, info.texture.get_size())
		if not tex_rect.encloses(a.rect) or a.frame_size.x < 1.0 or a.frame_size.y < 1.0:
			errors.append("Bad animation rect on %s in pack %s" % [info.path, pack["id"]])
			return null
		if not _exists(path):
			errors.append("Missing image %s in pack %s" % [rel, pack["id"]])
			return null
		a._sheet_path = path
		a._fix_edges = not pack.get("alpha_bleed", false)
		var grel := PackOverrides.safe_rel_path(str(d.get("glow_sheet", "")))
		if not grel.is_empty() and _exists(str(pack["base"]).path_join(grel)):
			a._glow_path = str(pack["base"]).path_join(grel)
			a.has_glow = true
		return a
	var sheet := _texture(path, false, not pack.get("alpha_bleed", false))
	if sheet == null:
		errors.append("Missing image %s in pack %s" % [rel, pack["id"]])
		return null
	a.sheet = sheet
	var rows := ceili(float(frames) / a.columns)
	a.frame_size = Vector2(sheet.get_width() / float(a.columns), sheet.get_height() / float(rows))
	return a


func _glow_from(pack: Dictionary, entry: Dictionary, info: SpriteInfo) -> Texture2D:
	## Additive glow layer (pack entry field "glow": {"file", "blend": "add"}); null when absent or unusable
	## (a bad one is reported, the sprite draws without it).
	var g: Variant = entry.get("glow", null)
	if not g is Dictionary:
		return null
	var rel := PackOverrides.safe_rel_path(str((g as Dictionary).get("file", "")))
	if rel.is_empty() or str(g.get("blend", "add")) != "add":
		errors.append("Bad glow on %s in pack %s" % [info.path, pack["id"]])
		return null
	var tex := _texture(str(pack["base"]).path_join(rel), false, not pack.get("alpha_bleed", false))
	if tex == null:
		errors.append("Missing image %s in pack %s" % [rel, pack["id"]])
		return null
	if Vector2(tex.get_size()) != Vector2(info.texture.get_size()):
		errors.append("Glow %s does not match the size of %s in pack %s" % [rel, info.path, pack["id"]])
		return null
	return tex


func pack_image(pack_id: String, rel: String) -> Texture2D:
	## Any image inside a pack (review queue previews).
	var p := pack_by_id(pack_id)
	var safe := PackOverrides.safe_rel_path(rel)
	if p.is_empty() or safe.is_empty():
		return null
	return _texture(str(p["base"]).path_join(safe))


func _texture(path: String, thumb: bool = false, fix_edges: bool = true) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex := _load_texture(path, fix_edges and not thumb)
	if tex:
		if thumb:
			thumb_loads += 1
		else:
			texture_loads += 1
	_tex_cache[path] = tex
	return tex


static func _load_texture(path: String, fix_edges: bool = true) -> Texture2D:
	if path.begins_with("res://") and ResourceLoader.exists(path):
		var res: Variant = load(path)
		if res is Texture2D:
			return res
	# Raw (non-imported) image: user packs and dev packs.
	var img := _load_image(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(prepare_image(img, fix_edges))


static func prepare_image(img: Image, fix_edges: bool = true) -> Image:
	## Runtime equivalent of the importer's "fix alpha border" + mipmaps. Raw
	## pack images are straight alpha and often store black under transparent
	## pixels; averaged into mipmaps that black shows as dark fringes when the
	## farm is zoomed out. fix_alpha_edges() spreads the edge colour outwards.
	## (Callers skip it for small catalogue thumbnails: ~0.4 ms each, no visible gain.)
	if img.is_compressed():
		img.decompress()
	if fix_edges and img.detect_alpha() != Image.ALPHA_NONE:
		img.fix_alpha_edges()
	img.generate_mipmaps()
	return img


static func _load_image(path: String) -> Image:
	var abs_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		abs_path = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path) or FileAccess.file_exists(abs_path):
		var img := Image.load_from_file(abs_path)
		if img != null and not img.is_empty():
			return img
	if path.begins_with("res://") and ResourceLoader.exists(path):
		var res: Variant = load(path)
		if res is Texture2D:
			return (res as Texture2D).get_image()
	return null


static func _exists(path: String) -> bool:
	if FileAccess.file_exists(path):
		return true
	return path.begins_with("res://") and ResourceLoader.exists(path)


func clear_cache() -> void:
	_cache.clear()
	_thumb_cache.clear()
	_tex_cache.clear()
	_item_themes = null


func _invalidate(keys: Array) -> void:
	var ks := {}
	for k in keys:
		ks[str(k)] = true
	for c in _cache.keys():
		if ks.has(str(c).get_slice("|", 0)):
			_cache.erase(c)
	for c in _thumb_cache.keys():
		if ks.has(str(c).get_slice("|", 0)):
			_thumb_cache.erase(c)


# --- overrides (fine-tuning, review decisions) -------------------------------------

func save_overrides(pack_id: String, art_key: String, changes: Dictionary, variant: String = "") -> Error:
	## Merges `changes` (anchor, pixels_per_world_px, scale, default_variant,
	## verified, rejected; null removes a field) into <pack>/overrides.json,
	## writes it atomically and re-applies it in memory (only this key's
	## cached sprites are dropped, so callers can refresh cheaply).
	return save_overrides_many(pack_id, {art_key: changes}, variant)


func save_overrides_many(pack_id: String, changes_by_key: Dictionary, variant: String = "") -> Error:
	var p := pack_by_id(pack_id)
	if p.is_empty():
		return ERR_DOES_NOT_EXIST
	if not p["writable"]:
		return ERR_FILE_NO_PERMISSION
	for k in changes_by_key:
		PackOverrides.set_sprite(p["overrides"], str(k), changes_by_key[k], variant)
	return _commit(p, changes_by_key.keys())


func assign_image(pack_id: String, rel: String, item_id: String) -> Error:
	## Review queue: use pack image `rel` for `item_id` ("" un-assigns).
	var p := pack_by_id(pack_id)
	if p.is_empty():
		return ERR_DOES_NOT_EXIST
	if not p["writable"]:
		return ERR_FILE_NO_PERMISSION
	var safe := PackOverrides.safe_rel_path(rel)
	if safe.is_empty():
		return ERR_INVALID_PARAMETER
	var keys: Array = []
	var prev := str((p["overrides"]["assign"] as Dictionary).get(safe, ""))
	if not prev.is_empty():
		keys.append(str(_item_info(prev).get("art_key", prev)))
	if not item_id.is_empty():
		var info := _item_info(item_id)
		if info.is_empty():
			return ERR_INVALID_PARAMETER
		keys.append(info["art_key"])
		# A new decision supersedes an earlier rejection / fine-tuning of another image.
		PackOverrides.set_sprite(p["overrides"], info["art_key"], {"rejected": null, "verified": null, "anchor": null, "pixels_per_world_px": null})
	PackOverrides.set_assign(p["overrides"], safe, item_id)
	(p["_measure"] as Dictionary).erase(safe)
	return _commit(p, keys)


func _commit(p: Dictionary, keys: Array) -> Error:
	var path := str(p["base"]).path_join(OVERRIDES_FILE)
	var err := JsonUtil.write_atomic(path, JsonUtil.stringify(p["overrides"], true))
	if err != OK:
		errors.append("Could not write %s: %s" % [path, error_string(err)])
		return err
	_apply_overrides(p)
	_invalidate(keys)
	_stats_cache.erase(p["id"])
	return OK


func review_queue(pack_id: String) -> Array:
	## Entries of <pack>/review.json: {file, suggestions[], reason, assigned}.
	var p := pack_by_id(pack_id)
	if p.is_empty():
		return []
	if not p.has("_review"):
		var items: Array = []
		var data: Variant = JsonUtil.read_json(str(p["base"]).path_join(REVIEW_FILE)) if FileAccess.file_exists(str(p["base"]).path_join(REVIEW_FILE)) else null
		if data is Dictionary and data.get("items") is Array:
			for e in data["items"]:
				if not e is Dictionary:
					continue
				var rel := PackOverrides.safe_rel_path(str(e.get("file", "")))
				if rel.is_empty():
					continue
				var sugg: Array = []
				if e.get("suggestions") is Array:
					for s in e["suggestions"]:
						sugg.append(str(s))
				items.append({"file": rel, "suggestions": sugg, "reason": str(e.get("reason", ""))})
		p["_review"] = items
	var out: Array = []
	var asg: Dictionary = p["overrides"]["assign"]
	for e: Dictionary in p["_review"]:
		var c := e.duplicate()
		c["assigned"] = str(asg.get(e["file"], ""))
		out.append(c)
	return out


func review_packs() -> Array:
	## Ids of packs that ship a non-empty review queue.
	var out: Array = []
	for p in packs:
		if not p["builtin"] and not review_queue(p["id"]).is_empty():
			out.append(p["id"])
	return out


# --- terrain (docs/TERRAIN_PACKS.md) ----------------------------------------------

func pack_terrain(pack_id: String) -> TerrainPack:
	## The parsed terrain manifest a pack declares in pack.json ("terrain"), or null.
	var p := pack_by_id(pack_id)
	if p.is_empty() or bool(p.get("builtin", false)):
		return null
	var rel := str((p.get("data_files", {}) as Dictionary).get("terrain", ""))
	if rel.is_empty():
		return null
	return _terrain_at(str(p["base"]).path_join(rel), pack_id)


func _terrain_at(path: String, pack_id: String) -> TerrainPack:
	if not _terrain_cache.has(path):
		_terrain_cache[path] = TerrainPack.load_file(path, pack_id)
	return _terrain_cache[path]


func terrain_for(m: FarmMap) -> TerrainPack:
	## Pack terrain to draw for a map, or null (procedural terrain only):
	##   1. the world file's own "terrain" (FarmMap.terrain_path),
	##   2. else the highest-priority installed pack whose pack.json declares
	##      "terrain" and whose manifest applies to this map (its own world,
	##      a listed map id, or any map in the game tile frame).
	if m == null:
		return null
	if not m.terrain_path.is_empty():
		var own := ""
		for p in packs:
			if not bool(p.get("builtin", false)) and m.terrain_path.begins_with(str(p["base"]) + "/"):
				own = str(p["id"])
				break
		var wt := _terrain_at(m.terrain_path, own)
		if wt.applies_to(m, true):
			return wt
	var world_pack := str(m.provenance.get("pack_id", "")) if str(m.provenance.get("active", "public")) != "public" else ""
	for p in packs:
		var tp := pack_terrain(str(p["id"]))
		if tp and tp.applies_to(m, str(p["id"]) == world_pack):
			return tp
	return null


func terrain_texture(tp: TerrainPack, rel: String) -> Texture2D:
	## An image of a terrain pack (cached with the other pack textures); null
	## when missing (reported once in the pack's diagnostics).
	if tp == null or rel.is_empty():
		return null
	var path := tp.base_dir.path_join(rel)
	var had := _tex_cache.has(path)
	var tex := _texture(path, false, not tp.alpha_bleed)
	if tex == null and not had:
		tp.report("missing image %s" % rel)
		errors.append("%s: terrain: missing image %s" % [tp.pack_id if not tp.pack_id.is_empty() else tp.id, rel])
	return tex


# --- statistics ------------------------------------------------------------------

func pack_stats(pack_id: String) -> Dictionary:
	## Counts + missing-file detection for one pack (computed on demand, cached).
	if _stats_cache.has(pack_id):
		return _stats_cache[pack_id]
	var p := pack_by_id(pack_id)
	if p.is_empty():
		return {}
	var files := {}
	var counts := {"variants": 0, "connections": 0, "shadows": 0, "thumbs": 0, "anims": 0, "mirrors": 0, "glows": 0}
	for key in p["sprites"]:
		if p["sprites"][key] is Dictionary:
			_collect_files(p["sprites"][key], files, counts)
	var missing: Array = []
	var base := str(p["base"])
	for rel in files:
		if not _exists(base.path_join(rel)):
			missing.append(rel)
	var terrain_problems: Array = []
	var tp := pack_terrain(str(p["id"]))
	if tp:
		var tdir := tp.base_dir.trim_prefix(base).trim_prefix("/")
		for rel in tp.files():
			files[tdir.path_join(rel) if not tdir.is_empty() else rel] = true
		for rel in tp.missing_files():
			missing.append(tdir.path_join(rel) if not tdir.is_empty() else rel)
		terrain_problems = Array(tp.diagnostics())
	missing.sort()
	var st := {"id": p["id"], "name": p["name"], "version": p["version"], "sprites": (p["sprites"] as Dictionary).size(),
		"variants": counts["variants"], "connections": counts["connections"], "shadows": counts["shadows"],
		"thumbs": counts["thumbs"], "anims": counts["anims"], "mirrors": counts["mirrors"], "glows": counts["glows"], "files": files.size(), "missing_files": missing,
		"verified": (p["verified"] as Dictionary).size(), "rejected": (p["rejected"] as Dictionary).size(),
		"assigned": (p["assigned"] as Dictionary).size(), "review_items": review_queue(p["id"]).size(),
		"override_errors": (p["override_errors"] as Array) + (p.get("apply_errors", []) as Array) + terrain_problems,
		"terrain": tp != null, "terrain_problems": terrain_problems}
	_stats_cache[pack_id] = st
	return st


func _collect_files(e: Dictionary, files: Dictionary, counts: Dictionary) -> void:
	var f := str(e.get("file", ""))
	if not f.is_empty():
		files[f] = true
	var t := str(e.get("thumb", ""))
	if not t.is_empty():
		files[t] = true
		counts["thumbs"] += 1
	if e.get("shadow") is Dictionary and not str(e["shadow"].get("file", "")).is_empty():
		files[str(e["shadow"]["file"])] = true
		counts["shadows"] += 1
	if e.get("anim") is Dictionary and not str(e["anim"].get("sheet", "")).is_empty():
		files[str(e["anim"]["sheet"])] = true
		counts["anims"] += 1
		if not str(e["anim"].get("glow_sheet", "")).is_empty():
			files[str(e["anim"]["glow_sheet"])] = true
	if e.get("glow") is Dictionary and not str(e["glow"].get("file", "")).is_empty():
		files[str(e["glow"]["file"])] = true
		counts["glows"] += 1
	if e.get("mirror") is Dictionary:
		counts["mirrors"] += 1
		_collect_files(e["mirror"], files, counts)
	for group in ["variants", "connections"]:
		if e.get(group) is Dictionary:
			for k in e[group]:
				if e[group][k] is Dictionary:
					counts[group] += 1
					_collect_files(e[group][k], files, counts)


func missing_files(pack_id: String = "") -> Array:
	## Pack-relative paths referenced but not found; for all packs when no id
	## is given (then prefixed "<pack id>: ").
	if not pack_id.is_empty():
		return pack_stats(pack_id).get("missing_files", [])
	var out: Array = []
	for p in packs:
		for rel in pack_stats(p["id"]).get("missing_files", []):
			out.append("%s: %s" % [p["id"], rel])
	return out


func stats(item_db: ItemDatabase) -> Dictionary:
	var with_art := 0
	var original := 0
	var by_pack := {}
	for it: ItemDef in item_db.ordered:
		var p := pack_of(it.art_key)
		if not p.is_empty():
			with_art += 1
			by_pack[p["id"]] = by_pack.get(p["id"], 0) + 1
			if p["art_kind"] != "placeholder":
				original += 1
	return {"items": item_db.count(), "with_art": with_art, "original": original, "by_pack": by_pack}
