extends TestCase
## Client-only catalogue items and the stronger client-record matching
## (docs/research/CLIENT_PRICES.md "Records the catalogue does not have"):
## a private pack's catalog_overrides "additions", the game-text rule, art-pack
## hints as review candidates. Every name, size and price here is invented.

const DIR := "user://test_client_catalog"


func after_each() -> void:
	var abs := ProjectSettings.globalize_path(DIR)
	for sub in ["localization", "data", ""]:
		var d := abs.path_join(sub)
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(d.path_join(f))
			DirAccess.remove_absolute(d)


func _write(path: String, lines: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(PackedStringArray(lines)) + "\n")
	f.close()


func _additions() -> Dictionary:
	return {"format": ItemDatabase.OVERRIDES_FORMAT, "version": 1,
		"items": {"t_lamp": {"footprint": [1, 2], "footprint_status": "game_data"}},
		"additions": {
			"glow_buoy": {"name": "Glow buoy", "category": "decoration", "footprint": [2, 2], "footprint_status": "game_data",
				"data_status": "game_data", "unlock_level": 12, "tags": ["client_only", "water_deco"], "client": {"table": "decorations"}},
			"moss_tile": {"name": "Moss tile", "category": "path", "footprint": [1, 1], "footprint_status": "game_data",
				"connect": {"group": "moss_tile", "style": "path"}, "layer": "ground"},
			"t_lamp": {"name": "Clash", "category": "decoration", "footprint": [1, 1]},
			"bad_cat": {"name": "Bad", "category": "spaceship", "footprint": [1, 1]},
			"BadId": {"name": "Bad id", "category": "decoration", "footprint": [1, 1]},
		}}


func test_additions_apply_and_revert() -> void:
	var db := TestCase.fixture_db()
	var n0 := db.count()
	var rep := db.apply_overrides(PackOverrides.parse_catalog_overrides(_additions()), "priv")
	assert_eq(rep["added"], ["glow_buoy", "moss_tile"])
	assert_eq(int(rep["applied"]), 1, "footprint corrections are counted apart")
	assert_eq((rep["invalid"] as Array).size(), 3, str(rep["invalid"]))
	assert_eq(db.count(), n0 + 2)
	var b := db.get_item("glow_buoy")
	assert_not_null(b)
	assert_eq(b.added_by_pack, "priv")
	assert_eq(b.footprint, Vector2i(2, 2))
	assert_eq(b.footprint_status, "game_data")
	assert_true(b.is_footprint_trusted())
	assert_eq(b.unlock_level, 12)
	assert_true(b.can_place())
	assert_eq(db.get_item("moss_tile").connect_style, "path")
	assert_eq(db.get_item("moss_tile").layer, "ground")
	assert_eq(db.get_item("t_lamp").name, "Lamp", "an addition never replaces a catalogue item")
	assert_eq(db.overrides_pack, "priv")
	assert_eq(db.added_items().size(), 2)
	assert_eq(db.search("glow").size(), 1, "added items are searchable")
	# Ordered by category then name, like the public catalogue.
	var ids: Array = []
	for it in db.ordered:
		ids.append(it.id)
	assert_true(ids.find("moss_tile") > ids.find("glow_buoy"), "path category sorts after decoration")
	# Idempotent; revert removes the items again.
	var rep2 := db.apply_overrides(PackOverrides.parse_catalog_overrides(_additions()), "priv")
	assert_eq(rep2["added"], ["glow_buoy", "moss_tile"])
	assert_eq(db.count(), n0 + 2)
	assert_eq(rep2["hash"], rep["hash"])
	db.revert_overrides()
	assert_eq(db.count(), n0)
	assert_null(db.get_item("glow_buoy"))
	assert_eq(db.overrides_pack, "")
	assert_eq(db.get_item("t_lamp").footprint, db.get_item("t_lamp").public_footprint)


func test_additions_only_pack_counts_as_applied() -> void:
	var db := TestCase.fixture_db()
	var d := _additions()
	d["items"] = {}
	var rep := db.apply_overrides(PackOverrides.parse_catalog_overrides(d), "priv")
	assert_eq(int(rep["applied"]), 0)
	assert_eq((rep["added"] as Array).size(), 2)
	assert_eq(db.overrides_pack, "priv", "a pack that only adds items is active")
	var bad := db.apply_overrides({"format": ItemDatabase.OVERRIDES_FORMAT, "items": {}, "additions": [1]}, "priv")
	assert_eq((bad["added"] as Array).size(), 0)
	assert_true((bad["invalid"] as Array).size() >= 1)
	assert_eq(db.overrides_pack, "")


func test_added_item_gets_its_client_price() -> void:
	# An added item is matched like any catalogue item: by its art export
	# (the pack's sprite entry) or by the game text.
	var db := TestCase.fixture_db()
	db.apply_overrides(PackOverrides.parse_catalog_overrides(_additions()), "priv")
	var sprites := {"glow_buoy": {"source": {"kind": "apk", "export": "buoy_x"}, "match": {"confidence": "exact"}}}
	var exports := ClientPrices.export_index_from_sprites(sprites, db)
	assert_eq(exports, {"buoy_x": ["glow_buoy"]})
	var recs := ClientPrices.records_from_reference({"format": ClientPrices.REFERENCE_FORMAT, "records": [
		{"table": "decorations", "source_name": "Buoy glow", "purchase_price_fields": {"pearls": 40}, "asset_export": "buoy_x",
			"translation_id": "TID_DECO_BUOY_GLOW", "can_buy_game_flag": true}]})
	var doc := ClientPrices.new().build(recs, db, exports, {}, "9.9.9", {})
	assert_eq(doc["items"]["glow_buoy"]["price"], {"pearls": 40})
	var pb := PriceBook.new()
	pb.overrides_path = "user://__no_price_overrides__.json"
	pb.set_catalogue(db)
	pb.load_client_data(doc)
	assert_eq(pb.copy_price("glow_buoy", 1), {"pearls": 40})
	assert_eq(pb.resolved("glow_buoy")["confidence"], "game_data")


func test_game_text_rule() -> void:
	_write(DIR + "/data/decorations.csv", [
		"Name,ExportName,TileWidth,TileHeight,Price,TID,CanBuy",
		"String,String,int,int,int,String,boolean",
		"lamp_v2,lamp_shared,1,1,40,TID_DECO_LAMP_V2,TRUE",
		"hedgy,hedge_z,1,2,12,TID_DECO_HEDGY,TRUE",
		"twin,twin_x,1,1,5,TID_DECO_TWIN,TRUE",
		"nothing,none_x,1,1,5,TID_DECO_NOTHING,TRUE",
	])
	_write(DIR + "/localization/texts.csv", ["Name,EN,comments", "string,string,string",
		"TID_DECO_LAMP_V2,Lamp,", "TID_DECO_HEDGY,Long hedge,", "TID_DECO_TWIN,Twin,", "\"TID_DECO_NOTHING\",\"Nothing, really\","])
	var errs: Array = []
	var recs := ClientPrices.records_from_tables(DIR + "/data", errs)
	var by := {}
	for r in recs:
		by[r["name"]] = r
	assert_eq(by["hedgy"]["text"], "Long hedge", "English text from ../localization/texts.csv")
	assert_eq(by["nothing"]["text"], "Nothing, really")
	var db := TestCase.fixture_db()
	db.add_item(ItemDef.from_dict({"id": "twin_a", "name": "Twin", "category": "decoration", "footprint": [1, 1]}, []))
	db.add_item(ItemDef.from_dict({"id": "twin_b", "name": "Twin", "category": "fence", "footprint": [1, 1]}, []))
	db.finalize()
	# lamp_shared is used by two items: the game text names one of them.
	var doc := ClientPrices.new().build(recs, db, {"lamp_shared": ["t_lamp", "t_bakery"]}, {}, "9.9.9", {})
	assert_eq(doc["items"]["t_lamp"]["client"]["rule"], ClientPrices.RULE_EXPORT)
	assert_eq(doc["items"]["t_long"]["client"]["rule"], ClientPrices.RULE_TEXT, "game text equals a catalogue name")
	assert_eq(doc["items"]["t_long"]["client"]["text"], "Long hedge")
	assert_eq(doc["items"]["t_long"]["price"], {"coins": 12})
	var kinds := {}
	for r in doc["review"]:
		kinds[r["name"]] = [r["kind"], r["candidates"]]
	assert_eq(kinds["twin"][0], "ambiguous", "a text naming two items stays unassigned")
	assert_eq((kinds["twin"][1] as Array).size(), 2)
	assert_eq(kinds["nothing"][0], "unmatched")
	# Without texts nothing changes: the record stays in review.
	for r in recs:
		r["text"] = ""
	var doc2 := ClientPrices.new().build(recs, db, {}, {}, "9.9.9", {})
	assert_false((doc2["items"] as Dictionary).has("t_long"))


func test_art_hints_are_candidates_only() -> void:
	var db := TestCase.fixture_db()
	var sprites := {
		"t_mystery": {"source": {"kind": "apk", "export": "statue_m"}, "match": {"confidence": "high"}},
		"t_lamp": {"source": {"kind": "apk", "export": "lamp_e"}, "match": {"confidence": "exact"}},
		"t_path": {"source": {"kind": "wiki", "export": "path_w"}, "match": {"confidence": "high"}},
	}
	assert_eq(ClientPrices.export_index_from_sprites(sprites, db), {"lamp_e": ["t_lamp"]}, "only exact / verified apply prices")
	var hints := ClientPrices.art_hints_from_sprites(sprites, db)
	assert_eq(hints, {"statue_m": ["t_mystery"], "lamp_e": ["t_lamp"]})
	var recs := ClientPrices.records_from_reference({"format": ClientPrices.REFERENCE_FORMAT, "records": [
		{"table": "decorations", "source_name": "Mistery statue", "purchase_price_fields": {"coins": 9}, "asset_export": "statue_m",
			"translation_id": "TID_DECO_MISTERY"}]})
	var doc := ClientPrices.new().build(recs, db, {}, {}, "9.9.9", {}, hints)
	assert_false((doc["items"] as Dictionary).has("t_mystery"), "a hint never applies a price")
	var row: Dictionary = doc["review"][0]
	assert_eq(row["kind"], "unmatched")
	assert_eq(row["candidates"][0], "t_mystery")
	assert_true(str(row["reason"]).begins_with(ClientPrices.UNMATCHED_REASON))
	assert_true("t_mystery" in str(row["reason"]))
	# The user's choice applies it.
	var doc2 := ClientPrices.new().build(recs, db, {}, {"decorations:mistery statue": "t_mystery"}, "9.9.9", {}, hints)
	assert_eq(doc2["items"]["t_mystery"]["price"], {"coins": 9})
	assert_eq(doc2["items"]["t_mystery"]["client"]["rule"], ClientPrices.RULE_USER)


func test_review_candidates_side_by_side() -> void:
	var db := TestCase.fixture_db()
	var pb := PriceBook.new()
	pb.overrides_path = "user://__no_price_overrides__.json"
	pb.set_catalogue(db)
	pb.set_override("t_lamp", {"price": {"coins": 40}})
	var lamp := db.get_item("t_lamp")
	var row := {"key": "decorations:lamp twin", "footprint": [lamp.footprint.y, lamp.footprint.x], "candidates": ["t_lamp", "ghost", "t_bakery"]}
	var c := ClientPrices.review_candidates(row, db, pb, ["t_path", "t_lamp"])
	var ids: Array = c.map(func(x): return x["id"])
	assert_eq(ids, ["t_lamp", "t_bakery", "t_path"], "unknown ids skipped, extra picks appended once")
	assert_eq(c[0]["price"], {"coins": 40})
	assert_eq(c[0]["price_text"], "40 coins")
	assert_eq(c[0]["origin"], PriceBook.ORIGIN_USER)
	assert_true(bool(c[0]["size_match"]), "a mirrored size still matches")
	assert_eq(c[0]["footprint"], lamp.footprint)
	assert_false(bool(c[0]["added"]))
	var no_fp := ClientPrices.review_candidates({"candidates": ["t_lamp"]}, db, null)
	assert_null(no_fp[0]["size_match"], "client size unknown")
	assert_eq(no_fp[0]["price_text"], "unknown")
	assert_eq(ClientPrices.decision_of("k", {}), {"state": "unassigned", "item": ""})
	assert_eq(ClientPrices.decision_of("k", {"k": ""}), {"state": "ignored", "item": ""})
	assert_eq(ClientPrices.decision_of("k", {"k": "t_lamp"}), {"state": "chosen", "item": "t_lamp"})
