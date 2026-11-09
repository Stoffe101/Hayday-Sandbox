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
