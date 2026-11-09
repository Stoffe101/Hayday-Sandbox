class_name Icons
extends RefCounted
## Lucide icons (ISC) rasterised from SVG at the current UI scale.

static var _svgs: Dictionary = {}
static var _cache: Dictionary = {}
static var scale := 1.0


static func _load() -> void:
	if not _svgs.is_empty():
		return
	var data: Variant = JsonUtil.read_json("res://assets/ui/icons.json")
	if data is Dictionary:
		_svgs = data.get("icons", {})


static func set_scale(s: float) -> void:
	if not is_equal_approx(s, scale):
		scale = s
		_cache.clear()


static func get_icon(name: String, size: int = 20) -> Texture2D:
	_load()
	var key := "%s@%d" % [name, size]
	if _cache.has(key):
		return _cache[key]
	var svg: String = _svgs.get(name, _svgs.get("box", ""))
	var tex: Texture2D = null
	if not svg.is_empty():
		var img := Image.new()
		# Lucide's viewBox is 24px.
		var px_scale := float(size) * scale / 24.0 * 1.0
		if img.load_svg_from_string(svg, px_scale) == OK:
			var it := ImageTexture.create_from_image(img)
			# High-res pixels, logical-size layout: crisp at any UI scale.
			it.set_size_override(Vector2i(size, size))
			tex = it
	_cache[key] = tex
	return tex


static func has_icon(name: String) -> bool:
	_load()
	return _svgs.has(name)
