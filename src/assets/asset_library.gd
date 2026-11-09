class_name AssetLibrary
extends RefCounted
## Resolves item art from layered asset packs.
##
## Pack search order (highest priority wins per art key):
##   1. user://asset_packs/<pack>/pack.json   (imported by the user, never shipped)
##   2. res://assets/original/<pack>/pack.json (developer-local, git-ignored, never exported)
##   3. res://assets/placeholders/pack.json    (built-in original art, CC0)
## Missing art is never fatal: callers get null and draw a vector fallback.

const PACK_FORMAT := "hayday-sandbox-asset-pack"
const USER_PACKS := "user://asset_packs"


class SpriteInfo:
	var texture: Texture2D
	var anchor: Vector2          ## texture pixel at the footprint's ground centre
	var scale: float = 0.5       ## world px per texture px
	var shadow: Texture2D
	var shadow_anchor: Vector2
	var pack_id: String = ""
	var path: String = ""
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
var _cache: Dictionary = {}            ## cache key -> SpriteInfo or null
var errors: PackedStringArray = PackedStringArray()


func load_all() -> void:
	packs.clear()
	_cache.clear()
	errors.clear()
	_load_pack("res://assets/placeholders/pack.json", 0)
	_scan_dir("res://assets/original", 50)
	_scan_dir(USER_PACKS, 100)
	packs.sort_custom(func(a, b): return a["priority"] > b["priority"])


func _scan_dir(dir_path: String, base_priority: int) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
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
	packs.append({
		"id": str(data.get("id", path.get_base_dir().get_file())),
		"name": str(data.get("name", "")),
		"license": str(data.get("license", "unknown")),
		"priority": base_priority + int(data.get("priority", 0)),
		"ppw": float(data.get("pixels_per_world_px", 1.0)),
		"base": path.get_base_dir(),
		"sprites": sprites,
		"builtin": path.begins_with("res://assets/placeholders"),
	})


func pack_list() -> Array[Dictionary]:
	return packs


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


func get_sprite(art_key: String, variant: String = "", mask: int = -1) -> SpriteInfo:
	var ck := "%s|%s|%d" % [art_key, variant, mask]
	if _cache.has(ck):
		return _cache[ck]
	var info: SpriteInfo = null
	for p in packs:
		var e: Variant = p["sprites"].get(art_key)
		if not e is Dictionary:
			continue
		var entry: Dictionary = e
		if not variant.is_empty() and entry.get("variants", {}) is Dictionary and entry.get("variants", {}).has(variant):
			entry = entry["variants"][variant]
		if mask >= 0 and entry.get("connections") is Dictionary:
			var conns: Dictionary = entry["connections"]
			var avail := {}
			for k in conns:
				avail[int(k)] = true
			var best := Connections.best_variant(mask, avail)
			if best >= 0:
				entry = conns[str(best)]
		info = _make_info(p, entry)
		if info != null:
			break
	_cache[ck] = info
	return info


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


func _make_info(pack: Dictionary, entry: Dictionary) -> SpriteInfo:
	var file := str(entry.get("file", ""))
	if file.is_empty():
		return null
	var tex := _load_texture(str(pack["base"]).path_join(file))
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
		var stex := _load_texture(str(pack["base"]).path_join(str(sh.get("file", ""))))
		if stex:
			info.shadow = stex
			var sa: Array = sh.get("anchor", [stex.get_width() * 0.5, stex.get_height() * 0.5])
			info.shadow_anchor = Vector2(float(sa[0]), float(sa[1]))
	return info


static func _load_texture(path: String) -> Texture2D:
	if path.begins_with("res://") and ResourceLoader.exists(path):
		var res: Variant = load(path)
		if res is Texture2D:
			return res
	# Raw (non-imported) image: user packs and dev packs.
	var abs_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		abs_path = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path) and not FileAccess.file_exists(abs_path):
		return null
	var img := Image.load_from_file(abs_path)
	if img == null or img.is_empty():
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func clear_cache() -> void:
	_cache.clear()


func stats(db: ItemDatabase) -> Dictionary:
	var with_art := 0
	var by_pack := {}
	for it: ItemDef in db.ordered:
		var src := art_source(it.art_key)
		if not src.is_empty():
			with_art += 1
			by_pack[src] = by_pack.get(src, 0) + 1
	return {"items": db.count(), "with_art": with_art, "by_pack": by_pack}
