extends SceneTree
## Validates a terrain pack manifest (format "hayday-sandbox-terrain",
## docs/TERRAIN_PACKS.md) for pack authors and CI:
##   godot --headless --path . --script res://tools/ci/check_terrain_pack.gd -- <path/to/terrain.json>
## Without a path it validates a freshly generated synthetic pack (self-test).
## Prints every diagnostic; exit status 1 when there are errors or missing files.
## It reads only JSON and checks that referenced files exist (images are never opened).


func _initialize() -> void:
	var path := ""
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			path = a
	if path.is_empty():
		var syn: GDScript = load("res://tests/fixtures/synthetic_terrain.gd")
		var dir := "user://check_terrain_pack"
		var w: Dictionary = syn.write_dir(dir, FarmMap.load_file("res://data/maps/hayday_farm.json"))
		if not w["ok"]:
			print("FAIL could not write the synthetic pack: ", w.get("error", ""))
			quit(1)
			return
		path = dir.path_join("terrain/terrain.json")
	var r := TerrainPack.validate_file(path)
	print("terrain pack: %s" % path)
	print("  variants: %s  pieces: %s  files: %d" % [", ".join(PackedStringArray(r["variants"])), str(r["pieces"]), r["files"]])
	for e in r["errors"]:
		print("  ERROR ", e)
	for w2 in r["warnings"]:
		print("  warning ", w2)
	for m in r["missing"]:
		print("  MISSING ", m)
	print("TERRAIN PACK " + ("OK" if r["ok"] else "FAIL"))
	quit(0 if r["ok"] else 1)
