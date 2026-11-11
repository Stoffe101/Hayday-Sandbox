extends SceneTree
## Checks every bundled sample and every new-layout template against the ACTIVE
## world (public map, or the private world data of an installed pack):
##   godot --headless --path . --script res://tools/ci/check_samples.gd
## Per sample: objects on fixed ground (road, water, landmarks, outside) as they
## are, then after WorldFit (what opening the sample as a new layout does).
## Templates (starter, expanded, new_farm) must have none at all.
## Exit 1 when a template has collisions or a fitted sample still has any.

func _init() -> void:
	await process_frame
	var app = root.get_node("/root/App")
	var bad := 0
	print("World: %s (%s)" % [app.map.id, "game data" if app.map.is_game_data() else "public approximation"])
	var files := DirAccess.get_files_at("res://data/samples")
	for f in files:
		if not f.ends_with(".hdlayout"):
			continue
		var rep := LayoutIO.LoadReport.new()
		var l: FarmLayout = app.library.load_path("res://data/samples/" + f, rep)
		if l == null:
			print("SAMPLE %s: does not load (%s)" % [f, rep.error])
			bad += 1
			continue
		var col: Array = LayoutIO.find_collisions(l, app.map)
		var reasons := {}
		for c in col:
			var o: PlacedObject = l.get_obj(c["uid"])
			var k := "%s: %s" % [o.item_id, c["reason"]]
			reasons[k] = int(reasons.get(k, 0)) + 1
		var fit := WorldFit.plan(l, app.map, app.db)
		WorldFit.apply_to_new(l, fit)
		var after: Array = LayoutIO.find_collisions(l, app.map)
		print("SAMPLE %s: %d objects, %d on fixed ground%s; after fitting: %d" % [f, l.count() + (fit["removes"] as Array).size(), col.size(),
			(" (" + WorldFit.summary(fit) + ")") if not WorldFit.is_empty(fit) else "", after.size()])
		for k in reasons:
			print("    %3d × %s" % [reasons[k], k])
		bad += after.size()
	for t in ["starter", "expanded", "new_farm", "empty"]:
		var nl: FarmLayout = app.new_layout("check", t)
		var c2: Array = LayoutIO.find_collisions(nl, app.map)
		print("TEMPLATE %s: %d objects, %d on fixed ground" % [t, nl.count(), c2.size()])
		bad += c2.size()
	print("SAMPLES %s" % ("OK" if bad == 0 else "FAILED (%d)" % bad))
	quit(0 if bad == 0 else 1)
