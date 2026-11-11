class_name WorldFit
extends RefCounted
## Fitting a layout to the world it is opened in (docs/ARCHITECTURE.md).
##
## Layouts made for one world can stand on another world's fixed ground: the
## bundled samples were drawn on the public approximate map, so with private
## world data (the real road, driveway, truck, order board …) some of their
## fences, paths and buildings stand on road tiles or landmarks — places the game
## never allows. plan() lists those objects (the "world" collision codes of
## LayoutIO.COLLISION_CODES, never overlaps between objects, which are a design
## choice) and proposes, per object:
##   * connecting pieces (fences, paths, hedges …) and 1×1 items: remove — a
##     single fence piece moved elsewhere is meaningless;
##   * anything larger: the nearest spot (ring search up to MOVE_RADIUS tiles)
##     where it stands legally and overlaps nothing; else remove.
## The caller decides how to apply it: a new layout from a sample applies it
## directly (and says so); an open layout only through an explicit, undoable
## command (EditorSession.fit_to_world). Objects are never touched silently.

const MOVE_RADIUS := 6


static func world_problem(l: FarmLayout, map: FarmMap, o: PlacedObject) -> Array:
	## The world collision codes of an object where it stands ([] = fits the world).
	var r := PlacementRules.check_object(l, map, o)
	var out: Array = []
	if r.ok:
		return out
	for c in LayoutIO.COLLISION_CODES:
		if r.reason_counts.has(c):
			out.append(c)
	return out


static func plan(l: FarmLayout, map: FarmMap, db: ItemDatabase, uids: Variant = null) -> Dictionary:
	## {moves: [{uid, delta: Vector2i}], removes: [uid], reasons: {uid: text}}
	## for the objects (all when uids == null) that stand on fixed ground.
	var out := {"moves": [], "removes": [], "reasons": {}}
	var list: Array = l.objects.keys() if uids == null else (uids as Array).duplicate()
	list.sort()
	var bad: Array = []
	for u in list:
		var o := l.get_obj(int(u))
		if o == null:
			continue
		var codes := world_problem(l, map, o)
		if codes.is_empty():
			continue
		bad.append(o)
		var why: PackedStringArray = []
		for c in codes:
			why.append(str(PlacementRules.REASON_TEXT.get(c, "Can't stand here")))
		out["reasons"][o.uid] = " · ".join(why)
	# Spots taken by moved objects must not be handed out twice.
	var taken: Array[Rect2i] = []
	var ignore := {}
	for o: PlacedObject in bad:
		ignore[o.uid] = true
	for o: PlacedObject in bad:
		var it := db.get_item(o.item_id) if db else null
		var piece := it != null and not it.connect_group.is_empty()
		if piece or (o.size.x * o.size.y <= 1):
			out["removes"].append(o.uid)
			continue
		var at: Variant = _nearest_spot(l, map, o, ignore, taken)
		if at == null:
			out["removes"].append(o.uid)
		else:
			out["moves"].append({"uid": o.uid, "delta": (at as Vector2i) - o.origin})
			taken.append(Rect2i(at, o.size))
	return out


static func _nearest_spot(l: FarmLayout, map: FarmMap, o: PlacedObject, ignore: Dictionary, taken: Array[Rect2i]) -> Variant:
	var zone := l.zone_items.has(o.item_id)
	for d in range(1, MOVE_RADIUS + 1):
		for dy in range(-d, d + 1):
			for dx in range(-d, d + 1):
				if absi(dx) != d and absi(dy) != d:
					continue
				var r := Rect2i(o.origin + Vector2i(dx, dy), o.size)
				var clash := false
				for t: Rect2i in taken:
					if t.intersects(r):
						clash = true
						break
				if clash:
					continue
				if PlacementRules.check_rect(l, map, r, ignore.merged({o.uid: true}), true, zone).ok:
					return r.position
	return null


static func apply_to_new(l: FarmLayout, p: Dictionary) -> void:
	## Applies a plan to a layout nobody has edited yet (a fresh copy of a sample):
	## no undo history needed.
	for m: Dictionary in p["moves"]:
		var o := l.get_obj(int(m["uid"]))
		if o:
			l.set_object_rect(o.uid, o.origin + (m["delta"] as Vector2i), o.size, false)
	if not (p["removes"] as Array).is_empty():
		l.remove_objects(p["removes"], false)


static func summary(p: Dictionary) -> String:
	## "4 moved to a free spot nearby, 9 left out (on the road or a fixed landmark)".
	var parts: PackedStringArray = []
	var nm := (p["moves"] as Array).size()
	var nr := (p["removes"] as Array).size()
	if nm > 0:
		parts.append("%d moved to a free spot nearby" % nm)
	if nr > 0:
		parts.append("%d left out" % nr)
	return ", ".join(parts)


static func is_empty(p: Dictionary) -> bool:
	return (p["moves"] as Array).is_empty() and (p["removes"] as Array).is_empty()
