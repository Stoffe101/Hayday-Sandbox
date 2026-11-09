class_name Exporter
extends Node
## Renders the farm world (never the UI) to an Image at any scale.
## Uses an offscreen SubViewport that shares the main World2D, rendering in
## tiles of at most TILE px so very large exports don't need a huge viewport.
## Editor overlays are excluded via visibility layers (no on-screen flicker).

const TILE := 2048
const MAX_PIXELS := 16384 * 16384
const LAYER_WORLD := 1
const LAYER_GRID := 2
const LAYER_OVERLAY := 4
const LAYER_LABELS := 8


func capture(world_rect: Rect2, scale: float, transparent: bool = false, include_grid: bool = false, include_overlay: bool = false) -> Image:
	var total := Vector2i((world_rect.size * scale).ceil())
	total = total.max(Vector2i.ONE)
	if total.x * total.y > MAX_PIXELS:
		push_warning("Export too large: %s" % total)
		return null
	var out := Image.create(total.x, total.y, false, Image.FORMAT_RGBA8)
	var vp := SubViewport.new()
	vp.world_2d = get_viewport().world_2d
	vp.transparent_bg = transparent
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var mask := LAYER_WORLD
	if include_grid:
		mask |= LAYER_GRID
	if include_overlay:
		mask |= LAYER_OVERLAY | LAYER_LABELS
	vp.canvas_cull_mask = mask
	var cam := Camera2D.new()
	cam.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	cam.zoom = Vector2(scale, scale)
	vp.add_child(cam)
	add_child(vp)
	cam.make_current()
	var nx := ceili(float(total.x) / TILE)
	var ny := ceili(float(total.y) / TILE)
	for ty in ny:
		for tx in nx:
			var w := mini(TILE, total.x - tx * TILE)
			var h := mini(TILE, total.y - ty * TILE)
			vp.size = Vector2i(w, h)
			cam.position = world_rect.position + Vector2(tx * TILE, ty * TILE) / scale
			cam.force_update_scroll()
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			if img == null:
				continue
			img.convert(Image.FORMAT_RGBA8)
			out.blit_rect(img, Rect2i(0, 0, w, h), Vector2i(tx * TILE, ty * TILE))
	vp.queue_free()
	return out


static func farm_world_rect(map: FarmMap, layout: FarmLayout, mode: String) -> Rect2:
	## mode: "land" (all land + plots), "unlocked" (owned land only), "objects".
	var r := Rect2()
	var first := true
	if mode == "objects" and layout.count() > 0:
		var tr := layout.bounds_of(layout.objects.keys())
		r = Iso.footprint_world_bounds(tr.position, tr.size)
		r = r.grow_individual(0, 160, 0, 0)
		return r.grow(48)
	var lb := map.land_bounds()
	r = Iso.footprint_world_bounds(lb.position, lb.size)
	if mode == "unlocked":
		var tiles := Rect2i()
		for y in map.size.y:
			for x in map.size.x:
				if map.is_land(Vector2i(x, y), layout.unlocked_plots):
					if first:
						tiles = Rect2i(x, y, 1, 1)
						first = false
					else:
						tiles = tiles.expand(Vector2i(x, y)).expand(Vector2i(x + 1, y + 1))
		if not first:
			r = Iso.footprint_world_bounds(tiles.position, tiles.size)
	return r.grow_individual(32, 220, 32, 32)
