class_name TerrainTextures
extends RefCounted
## Procedural, seamless terrain textures generated at startup (no art files).

static var _cache: Dictionary = {}


static func get_tex(kind: String) -> Texture2D:
	if _cache.has(kind):
		return _cache[kind]
	var tex: Texture2D
	match kind:
		"grass": tex = _noise_tex(Color("#7fb85a"), Color("#6aa64c"), Color("#93c66a"), 7, 0.012, true)
		"meadow": tex = _noise_tex(Color("#5f9a49"), Color("#4f8a3e"), Color("#6ba653"), 11, 0.01, true)
		"road": tex = _noise_tex(Color("#d8c08a"), Color("#c7ab73"), Color("#e4d0a0"), 3, 0.03, false)
		"water": tex = _noise_tex(Color("#5cb7dc"), Color("#4aa4cf"), Color("#7dcbe8"), 5, 0.02, false)
		"forest": tex = _noise_tex(Color("#4e8a43"), Color("#3f7838"), Color("#5c9a4c"), 13, 0.02, true)
		"sand": tex = _noise_tex(Color("#e2cd98"), Color("#cfb780"), Color("#efdfb2"), 19, 0.03, false)
		"rock": tex = _noise_tex(Color("#a39a86"), Color("#80776a"), Color("#bdb4a0"), 23, 0.035, false)
		"grass_patch": tex = _patch_tex()
		"grass_tone": tex = _tone_tex()
		"grass_detail": tex = _detail_tex()
		"pebbles": tex = _pebble_tex()
		"hatch": tex = _hatch_tex()
		_: tex = _noise_tex(Color.GRAY, Color.DIM_GRAY, Color.LIGHT_GRAY, 1, 0.02, false)
	_cache[kind] = tex
	return tex


static func _noise_tex(base: Color, dark: Color, light: Color, seed_v: int, freq: float, blades: bool) -> Texture2D:
	var size := 256
	var n := FastNoiseLite.new()
	n.seed = seed_v
	n.frequency = freq
	n.fractal_octaves = 4
	var n2 := FastNoiseLite.new()
	n2.seed = seed_v * 7 + 1
	n2.frequency = freq * 6.0
	var img_a := n.get_seamless_image(size, size, false, false, 0.15)
	var img_b := n2.get_seamless_image(size, size, false, false, 0.15)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	for y in size:
		for x in size:
			var a := img_a.get_pixel(x, y).r
			var b := img_b.get_pixel(x, y).r
			var c := base
			if a < 0.5:
				c = base.lerp(dark, (0.5 - a) * 1.4)
			else:
				c = base.lerp(light, (a - 0.5) * 1.2)
			c = c.lerp(dark if b < 0.5 else light, absf(b - 0.5) * 0.35)
			img.set_pixel(x, y, c)
	if blades:
		for i in 900:
			var x := rng.randi_range(0, size - 1)
			var y := rng.randi_range(0, size - 3)
			var c := light if rng.randf() < 0.6 else dark
			for k in 2:
				img.set_pixel(x, (y + k) % size, img.get_pixel(x, (y + k) % size).lerp(c, 0.55))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _patch_tex() -> Texture2D:
	## Broad, seamless light and dark patches (alpha), laid over plain grass.
	var size := 128
	var n := FastNoiseLite.new()
	n.seed = 29
	n.frequency = 0.022
	n.fractal_octaves = 3
	var src := n.get_seamless_image(size, size, false, false, 0.2)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var dark := Color("#4b8a3c")
	var light := Color("#bcd576")
	for y in size:
		for x in size:
			var a := src.get_pixel(x, y).r
			if a < 0.5:
				img.set_pixel(x, y, Color(dark.r, dark.g, dark.b, clampf((0.5 - a) * 1.5, 0.0, 0.5)))
			else:
				img.set_pixel(x, y, Color(light.r, light.g, light.b, clampf((a - 0.5) * 1.3, 0.0, 0.45)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _tone_tex() -> Texture2D:
	## Very broad, soft tone variation (alpha): sunny yellow-green and cool
	## deep-green areas several plots wide, so large lawns don't read as one flat
	## colour. Drawn stretched over thousands of world px (TerrainLayer.UV_TONE).
	var size := 128
	var n := FastNoiseLite.new()
	n.seed = 53
	n.frequency = 0.03
	n.fractal_octaves = 2
	var src := n.get_seamless_image(size, size, false, false, 0.25)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var warm := Color("#d9e27a")
	var cool := Color("#2f6b3a")
	for y in size:
		for x in size:
			var a := src.get_pixel(x, y).r
			if a < 0.5:
				img.set_pixel(x, y, Color(cool.r, cool.g, cool.b, clampf((0.5 - a) * 0.9, 0.0, 0.22)))
			else:
				img.set_pixel(x, y, Color(warm.r, warm.g, warm.b, clampf((a - 0.5) * 0.8, 0.0, 0.2)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _pebble_tex() -> Texture2D:
	## Sparse small stones on transparent ground (road shoulders, river banks).
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.6, 0.55, 0.45, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 67
	var tones: Array[Color] = [Color("#b8ab95"), Color("#9d917c"), Color("#cfc4ae"), Color("#8a7e6b")]
	for i in 110:
		var cx := rng.randi_range(0, size - 1)
		var cy := rng.randi_range(0, size - 1)
		var rx := rng.randi_range(2, 4)
		var ry := maxi(1, rx - rng.randi_range(0, 2))
		var col: Color = tones[rng.randi() % tones.size()]
		for dy in range(-ry - 1, ry + 2):
			for dx in range(-rx - 1, rx + 2):
				var d := (float(dx) / (rx + 0.5)) ** 2 + (float(dy) / (ry + 0.5)) ** 2
				var px := posmod(cx + dx, size)
				var py := posmod(cy + dy, size)
				if d <= 1.0:
					var lit := col.lightened(0.25) if dy < 0 and dx < 0 else col
					img.set_pixel(px, py, Color(lit.r, lit.g, lit.b, 0.95))
				elif d <= 1.7 and dy > 0 and img.get_pixel(px, py).a < 0.1:
					img.set_pixel(px, py, Color(0.15, 0.12, 0.08, 0.3))   # contact shadow below the stone
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _detail_tex() -> Texture2D:
	## Seamless scatter of grass tufts and a few small flowers on transparent ground.
	var size := 512
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.45, 0.65, 0.32, 0.0))   # green under alpha 0, so mipmaps get no dark fringe
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	var blades: Array[Color] = [Color("#5b9a44"), Color("#a5cf6d"), Color("#4c8a3a")]
	for i in 420:
		var cx := rng.randi_range(0, size - 1)
		var cy := rng.randi_range(0, size - 1)
		for b in rng.randi_range(3, 5):
			var col: Color = blades[rng.randi() % blades.size()]
			var x := float(cx + rng.randi_range(-3, 3))
			var lean := rng.randf_range(-0.45, 0.45)
			for k in rng.randi_range(4, 8):
				img.set_pixel(posmod(roundi(x + lean * k), size), posmod(cy - k, size), Color(col.r, col.g, col.b, 0.8))
	var petals: Array[Color] = [Color("#f6f2e8"), Color("#efc94c"), Color("#e389a8")]
	for i in 70:
		var cx := rng.randi_range(0, size - 1)
		var cy := rng.randi_range(0, size - 1)
		var col: Color = petals[rng.randi() % petals.size()]
		for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			img.set_pixel(posmod(cx + d.x, size), posmod(cy + d.y, size), Color(col.r, col.g, col.b, 0.95))
		img.set_pixel(cx, cy, Color(0.9, 0.7, 0.2, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _hatch_tex() -> Texture2D:
	var size := 32
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var d := (x + y) % 16
			var a := 0.22 if d < 3 else 0.0
			img.set_pixel(x, y, Color(0.1, 0.12, 0.1, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
