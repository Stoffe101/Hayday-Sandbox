extends SceneTree
## Compares a private world (world.json) and the pack's catalogue corrections
## with the game client's own level data and tables (WorldValidator), and
## writes a JSON report plus a readable .md next to it.
##
##   godot --headless --path . --script res://tools/private_assets/validate_world.gd -- \
##     --tables <client assets/data dir> --world <world.json> [--overrides <catalog_overrides.json>] \
##     [--pack <pack.json>] [--out <report.json>] [--md <report.md>] [--game-version <x.y.z>] [--max-examples N]
## Windows: powershell -ExecutionPolicy Bypass -File tools\ci\run_godot.ps1 --script res://tools/private_assets/validate_world.gd -- ...
##
## Defaults: --out user://private_data/world_validation.json (read by the Farm
## Accuracy Report), --md = --out with .md, --pack = pack.json next to the
## overrides file. The inputs and outputs are PRIVATE (derived from the user's
## own client): never write them inside the repository.
## Exit code: 0 when the report was written (whatever its status), 1 on bad input,
## 2 when --fail-on-fail is given and a check failed.

const LEVEL_FILE := "level_0.csv"


func _initialize() -> void:
	var a := _args(OS.get_cmdline_user_args())
	if not a.has("tables") or not a.has("world"):
		printerr("usage: -- --tables <client data dir> --world <world.json> [--overrides f] [--pack f] [--out f] [--md f]")
		quit(1)
		return
	var tables_dir := str(a["tables"])
	var level_path := tables_dir.path_join(LEVEL_FILE)
	if not FileAccess.file_exists(level_path):
		printerr("no %s in %s" % [LEVEL_FILE, tables_dir])
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var level := ClientLevel.parse_level(JsonUtil.read_text(level_path))
	if not bool(level["ok"]):
		printerr("level file: %s" % ", ".join(PackedStringArray(level["errors"])))
	var world: Variant = JsonUtil.read_json(str(a["world"]))
	if not world is Dictionary:
		printerr("cannot read the world file %s" % a["world"])
		quit(1)
		return
	# Client tables: every CSV with TileWidth/TileHeight, plus expansions and tiles;
	# other TileMap level files only to explain absent expansion ids.
	var tables := {}
	var other_levels := {}
	var expansions := {}
	var tiles := {}
	var dir := DirAccess.open(tables_dir)
	var files := Array(dir.get_files()) if dir != null else []
	files.sort()
	for f: String in files:
		if not f.ends_with(".csv") or f == LEVEL_FILE:
			continue
		var p := tables_dir.path_join(f)
		var head := _first_line(p)
		var nm := f.get_basename()
		if head.begins_with("TileMap"):
			other_levels[nm] = ClientLevel.parse_level(JsonUtil.read_text(p))
		elif nm == "expansions":
			expansions = ClientLevel.read_table(JsonUtil.read_text(p))
		elif nm == "tiles":
			tiles = ClientLevel.read_table(JsonUtil.read_text(p))
		elif head.contains("TileWidth") and head.contains("TileHeight"):
			tables[nm] = ClientLevel.read_table(JsonUtil.read_text(p))
	# Catalogue as the app uses it: public items + the pack's corrections.
	var footprints := {}
	var overrides: Variant = null
	if a.has("overrides"):
		overrides = JsonUtil.read_json(str(a["overrides"]))
		var pack_path := str(a.get("pack", str(a["overrides"]).get_base_dir().path_join("pack.json")))
		var pack: Variant = JsonUtil.read_json(pack_path) if FileAccess.file_exists(pack_path) else {}
		var sprites: Dictionary = pack.get("sprites", {}) if pack is Dictionary and pack.get("sprites") is Dictionary else {}
		var db := ItemDatabase.new()
		db.load_default()
		var errs: Array = []
		var parsed := PackOverrides.parse_catalog_overrides(overrides, errs)
		for e in errs:
			print("overrides: %s" % e)
		var pack_id := str(pack.get("id", "pack")) if pack is Dictionary else "pack"
		var rep := db.apply_overrides(parsed, pack_id)
		print("catalogue: %d items, %d pack corrections applied (%d unknown ids)" % [db.ordered.size(), int(rep.get("applied", 0)), (rep.get("unknown", []) as Array).size()])
		footprints = WorldValidator.compare_footprints(db, tables, overrides, sprites, int(a.get("max-examples", WorldValidator.MAX_EXAMPLES)))
		# The same comparison without the pack: what the corrections fix.
		var pub := ItemDatabase.new()
		pub.load_default()
		var before: Dictionary = WorldValidator.compare_footprints(pub, tables, overrides, sprites, 100)["item_footprints"]
		var ids: Array = []
		for e: Dictionary in before["examples"]:
			ids.append(str(e["item"]))
		footprints["footprint_corrections"]["public_catalogue"] = {"compared": before["compared"], "mismatches": before["mismatches"],
			"axis_swapped": before["axis_swapped"], "items": ids}
	var opts := {"expansions": expansions, "tiles": tiles, "tables": tables, "other_levels": other_levels,
		"max_examples": int(a.get("max-examples", WorldValidator.MAX_EXAMPLES)), "tool": "tools/private_assets/validate_world.gd (%s)" % WorldValidator.TOOL}
	if not footprints.is_empty():
		opts["footprints"] = footprints
	if a.has("game-version"):
		opts["game_version"] = str(a["game-version"])
	var report := WorldValidator.validate(level, world, opts)
	report["inputs"] = {"level_file": LEVEL_FILE, "tables_read": tables.size(), "other_levels": other_levels.keys(),
		"world_file": str(a["world"]).get_file(), "overrides_file": str(a.get("overrides", "")).get_file()}
	var out := str(a.get("out", WorldValidator.DEFAULT_PATH))
	var md := str(a.get("md", out.get_basename() + ".md"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out.get_base_dir()))
	var err := JsonUtil.write_atomic(out, JSON.stringify(report, "\t", false), false)
	if err != OK:
		printerr("cannot write %s (%s)" % [out, error_string(err)])
		quit(1)
		return
	JsonUtil.write_atomic(md, WorldValidator.to_markdown(report), false)
	for c: Dictionary in report["checks"]:
		print("%-5s %-24s compared %6d  mismatches %4d" % [str(c["status"]).to_upper(), c["id"], int(c["compared"]), int(c["mismatches"])])
	print("status %s (%d pass, %d warn, %d fail) in %.1fs -> %s" % [report["status"], int(report["counts"]["pass"]),
		int(report["counts"]["warn"]), int(report["counts"]["fail"]), (Time.get_ticks_msec() - t0) / 1000.0, ProjectSettings.globalize_path(out)])
	quit(2 if a.has("fail-on-fail") and report["status"] == "fail" else 0)


static func _args(list: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < list.size():
		var s := list[i]
		if s.begins_with("--"):
			var k := s.substr(2)
			if k.contains("="):
				out[k.get_slice("=", 0)] = k.substr(k.find("=") + 1)
			elif i + 1 < list.size() and not list[i + 1].begins_with("--"):
				out[k] = list[i + 1]
				i += 1
			else:
				out[k] = true
		i += 1
	return out


static func _first_line(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_line()
