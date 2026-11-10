extends SceneTree
## Builds the PRIVATE client-price supplement from your own Hay Day client data
## (docs/research/CLIENT_PRICES.md) and writes it, with its report, OUTSIDE the
## repository. The app does the same from Asset Manager > Game data.
##   godot --headless --path . --script res://tools/private_assets/import_client_prices.gd -- \
##     (--tables=<folder with decorations.csv ...> | --reference=<price_reference.json>)
##     [--pack=<installed art pack folder or its pack.json>]   export names -> items (strongest match);
##                                                              its catalog_overrides (incl. additions) are applied
##     [--mapping=<your mapping json>]                          default user://private_data/client_price_mapping.json
##     [--game-version=1.73.89]                                 default: from the reference / the pack provenance
##     (--install | --out=<supplement.json>)                    --install = user://private_data/client_prices.json
## Exit code 0 = written, 1 = rejected input, 2 = usage.


func _initialize() -> void:
	var a := {}
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--") and "=" in s:
			a[s.substr(2, s.find("=") - 2)] = s.substr(s.find("=") + 1)
		elif s.begins_with("--"):
			a[s.substr(2)] = "true"
	if not (a.has("tables") or a.has("reference")) or not (a.has("install") or a.has("out")):
		printerr("usage: -- (--tables=DIR | --reference=FILE) [--pack=DIR] [--mapping=FILE] [--game-version=V] (--install | --out=FILE)")
		quit(2)
		return
	var out_path := PriceBook.DEFAULT_CLIENT if a.has("install") else str(a["out"])
	var repo := ProjectSettings.globalize_path("res://").simplify_path()
	if out_path.begins_with("res://") or ProjectSettings.globalize_path(out_path).simplify_path().begins_with(repo):
		printerr("Refusing to write private game data inside the repository: " + out_path)
		quit(2)
		return
	var db := ItemDatabase.new()
	db.load_default()
	var errs: Array = []
	var records: Array = []
	var game_version := str(a.get("game-version", ""))
	var source := {}
	if a.has("tables"):
		records = ClientPrices.records_from_tables(str(a["tables"]), errs)
		source = {"kind": "tables", "path": str(a["tables"]).get_file(), "records": records.size()}
	else:
		var ref: Variant = JsonUtil.read_json(str(a["reference"]))
		if ref is Dictionary:
			records = ClientPrices.records_from_reference(ref, errs)
			if game_version.is_empty():
				game_version = str(ref.get("game_version", ""))
		else:
			errs.append("cannot read %s" % str(a["reference"]))
		source = {"kind": "reference", "path": str(a["reference"]).get_file(), "records": records.size()}
	for e in errs:
		print("note: ", e)
	if records.is_empty():
		printerr("no client records read")
		quit(1)
		return
	var exports := {}
	var hints := {}
	if a.has("pack"):
		var pp := str(a["pack"])
		if not pp.ends_with(".json"):
			pp = pp.path_join("pack.json")
		var pack: Variant = JsonUtil.read_json(pp)
		# The pack's catalogue corrections and additions (client-only items), as the app applies them.
		var cov := pp.get_base_dir().path_join(str(pack.get("catalog_overrides", ""))) if pack is Dictionary and not str(pack.get("catalog_overrides", "")).is_empty() else ""
		if not cov.is_empty() and FileAccess.file_exists(cov):
			var crep := db.apply_overrides(PackOverrides.parse_catalog_overrides(JsonUtil.read_json(cov)), str(pack.get("id", "pack")))
			print("note: pack catalogue: %d corrected, %d added" % [int(crep["applied"]), (crep["added"] as Array).size()])
		if pack is Dictionary and pack.get("sprites") is Dictionary:
			exports = ClientPrices.export_index_from_sprites(pack["sprites"], db)
			hints = ClientPrices.art_hints_from_sprites(pack["sprites"], db)
			if game_version.is_empty() and pack.get("provenance") is Dictionary:
				game_version = str(pack["provenance"].get("client_build", ""))
		else:
			print("note: no art pack sprites in %s (export-name matching off)" % pp)
	if game_version.is_empty():
		printerr("the game version is unknown: pass --game-version=")
		quit(1)
		return
	var mapping := ClientPrices.load_mapping(str(a.get("mapping", ClientPrices.MAPPING_PATH)))
	var cp := ClientPrices.new()
	var t0 := Time.get_ticks_msec()
	var doc := cp.build(records, db, exports, mapping, game_version, source, hints)
	var t1 := Time.get_ticks_msec()
	var pb := PriceBook.load_default(db)
	pb.clear_client()
	var prev: Variant = JsonUtil.read_json(out_path) if FileAccess.file_exists(out_path) else null
	var rep := ClientPrices.build_report(doc, pb, db, prev if prev is Dictionary else {})
	var res := ClientPrices.install(doc, rep, out_path)
	if not bool(res["ok"]):
		printerr("not written: ", res["error"])
		quit(1)
		return
	if a.has("install"):
		# The app's "Re-import with my decisions" uses the same source.
		ClientPrices.set_last_source(str(a.get("tables", a.get("reference", ""))))
	var c: Dictionary = rep["coverage"]
	print("CLIENT-PRICES OK records=%d items=%d components=%d review=%d known_before=%d known_after=%d newly=%d changed=%d build_ms=%d -> %s" % [
		records.size(), (doc["items"] as Dictionary).size(), int(doc["stats"]["component_records"]),
		(doc["review"] as Array).size(), int(c["known_before"]), int(c["known_after"]), int(c["newly_priced"]),
		int(c["price_changed"]), t1 - t0, ProjectSettings.globalize_path(out_path)])
	quit(0)
