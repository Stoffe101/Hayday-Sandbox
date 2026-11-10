extends TestCase
## Design-customization budget (SkinBudget, docs/PLANNING.md §4): the chosen
## look of the farmhouse / truck / roadside shop priced from appearance parts,
## default and owned parts never charged, optional toggle, the same result in
## the totals, the shopping-list rows / CSV and the guide. Invented data only.

var db: ItemDatabase
var pb: PriceBook
var map: FarmMap
var layout: FarmLayout


func before_each() -> void:
	db = fixture_db()
	pb = PriceBook.new()
	pb.overrides_path = "user://__no_price_overrides__.json"
	pb.set_catalogue(db)
	pb.load_client_data({"format": PriceBook.CLIENT_FORMAT, "schema_version": 1, "game_version": "9.9.9", "items": {},
		"components": {
			"house": {
				"RoofPlain": {"name": "RoofPlain", "slot": "Roof", "price": {"coins": 1000}, "default": true},
				"RoofGold": {"name": "RoofGold", "slot": "Roof", "price": {"coins": 250000}},
				"WallBlue": {"name": "WallBlue", "slot": "Building", "price": {"diamonds": 30}},
				"WallPlain": {"name": "WallPlain", "slot": "Building", "default": true},
				"PorchParty": {"name": "PorchParty", "slot": "Porch", "event": true},
			},
			"truck": {"WheelsGold": {"name": "WheelsGold", "slot": "Wheels", "price": {"coins": 9000}}},
		}})
	map = FarmMap.from_data({"format": "hayday-sandbox-map", "schema_version": 2, "id": "skin_map", "frame": "game",
		"size": [20, 20], "regions": [{"id": "start", "kind": "buildable", "rects": [[0, 0, 20, 20]]}],
		"landmarks": [
			{"id": "farmhouse", "name": "Farmhouse", "origin": [8, 8], "footprint": [4, 4], "confidence": "strong", "skin_kind": "house",
				"skins": [{"id": "original", "name": "Original", "parts": {"Roof": "RoofPlain", "Building": "WallPlain"}},
					{"id": "gold", "name": "Gold style", "parts": {"Roof": "RoofGold", "Building": "WallBlue", "Porch": "PorchParty"}},
					{"id": "plain_roof", "name": "Plain", "parts": {"Roof": "RoofPlain", "Building": "WallPlain"}}]},
			{"id": "truck", "name": "Truck", "origin": [2, 2], "footprint": [2, 2], "confidence": "strong", "skin_kind": "truck",
				"skins": [{"id": "shiny", "name": "Shiny", "parts": {"Wheels": "WheelsGold"}}]},
			{"id": "mailbox", "name": "Mailbox", "origin": [0, 0], "footprint": [1, 1], "confidence": "strong"},
		]})
	layout = FarmLayout.new()


func _lms() -> Array:
	var a: Array = []
	a.assign(map.landmarks)
	return a


func test_original_look_costs_nothing() -> void:
	var r := SkinBudget.compute(layout, _lms(), pb, {}, {})
	assert_true(bool(r["known"]))
	assert_false(bool(r["enabled"]), "off by default")
	assert_eq(r["rows"], [])
	assert_eq(r["cost"], {})
	assert_eq(SkinBudget.summary_text(r), "")
	layout.set_world_value("landmark_skins", "farmhouse", "plain_roof")
	var r2 := SkinBudget.compute(layout, _lms(), pb, {}, {})
	assert_eq(r2["cost"], {}, "only default parts")
	assert_eq(int(r2["defaults"]), 2)
	assert_eq(int(r2["charged"]), 0)
	layout.set_world_value("landmark_skins", "farmhouse", "no_such_skin")
	assert_eq(SkinBudget.compute(layout, _lms(), pb, {}, {})["rows"], [], "an unknown preset is the original look")


func test_charged_owned_unknown_parts() -> void:
	layout.set_world_value("landmark_skins", "farmhouse", "gold")
	layout.set_world_value("landmark_skins", "truck", "shiny")
	var plan := SkinBudget.with_enabled({}, true)
	assert_true(SkinBudget.is_enabled(plan))
	var r := SkinBudget.compute(layout, _lms(), pb, {}, plan)
	assert_eq(r["cost"], {"coins": 259000, "diamonds": 30})
	assert_eq(r["unknown_parts"], ["Farmhouse: PorchParty"], "an event part without a price is unknown, never 0")
	assert_eq(int(r["charged"]), 4)
	assert_eq((r["landmarks"] as Array).size(), 2)
	# Owned parts are never charged.
	var prof := SkinBudget.with_owned({}, "house", ["RoofGold", "PorchParty"], true)
	assert_eq(prof[SkinBudget.OWNED_KEY], {"house": ["PorchParty", "RoofGold"]})
	var r2 := SkinBudget.compute(layout, _lms(), pb, prof, plan)
	assert_eq(r2["cost"], {"coins": 9000, "diamonds": 30})
	assert_eq(r2["unknown_parts"], [])
	assert_eq(int(r2["owned"]), 2)
	var back := SkinBudget.with_owned(prof, "house", ["RoofGold", "PorchParty"], false)
	assert_false(back.has(SkinBudget.OWNED_KEY), "empty inventory entries are removed")
	# Whole farm only, and only when switched on.
	assert_eq(SkinBudget.total_cost({"coins": 1}, r2, "farm"), {"coins": 9001, "diamonds": 30})
	assert_eq(SkinBudget.total_cost({"coins": 1}, r2, "area"), {"coins": 1}, "areas and phases never include the look")
	var off := SkinBudget.compute(layout, _lms(), pb, prof, SkinBudget.with_enabled(plan, false))
	assert_eq(SkinBudget.total_cost({"coins": 1}, off, "farm"), {"coins": 1})
	assert_eq(SkinBudget.unknown_count(r, "farm"), 1)
	assert_eq(SkinBudget.unknown_count(off, "farm"), 0)
	assert_true(SkinBudget.summary_text(off).ends_with("not in the totals"))


func test_no_client_data_is_unknown() -> void:
	layout.set_world_value("landmark_skins", "truck", "shiny")
	var r := SkinBudget.compute(layout, _lms(), PriceBook.new(), {}, SkinBudget.with_enabled({}, true))
	assert_false(bool(r["known"]))
	assert_eq(r["cost"], {})
	assert_eq(r["unknown_parts"], ["Truck: WheelsGold"])


func test_shop_rows_csv_and_guide_agree() -> void:
	layout.set_world_value("landmark_skins", "farmhouse", "gold")
	var prof := SkinBudget.with_owned({}, "house", ["WallBlue"], true)
	var r := SkinBudget.compute(layout, _lms(), pb, prof, SkinBudget.with_enabled({}, true))
	var rows := SkinBudget.shop_rows(r)
	assert_eq(rows.size(), 3, "default parts are left out")
	var by := {}
	for x in rows:
		by[x["part"]] = x
	assert_eq(by["RoofGold"]["item"], "part:house:RoofGold")
	assert_eq(by["WallBlue"]["status"], "owned")
	assert_eq(by["PorchParty"]["status"], "unknown")
	assert_eq(PlanUiModels.customization_text(by["RoofGold"]), "Farmhouse: RoofGold (Roof): 250,000 coins")
	var csv := PlanUiModels.shop_csv([], [], rows)
	assert_true(csv.contains("Design customization,part:house:RoofGold,Farmhouse: RoofGold (Roof),1,0,,1,"), csv)
	assert_true(csv.contains("part:house:WallBlue") and csv.contains("appearance part"))
	var g := RecreationGuide.build(layout, map, {}, {"db": db, "customization": r})
	var look: Array = (g["steps"] as Array).filter(func(s): return s["kind"] == "customize")
	assert_eq(look.size(), 1)
	var st: Dictionary = look[0]
	assert_eq(int(st["stage"]), 8)
	assert_eq(st["cost"], {"coins": 250000})
	assert_true(str(st["title"]).contains("Gold style"))
	assert_true(str(st["description"]).contains("RoofGold (250,000 coins)") and str(st["description"]).contains("already owned: WallBlue"), str(st["description"]))
	assert_false(bool(st["done"]))
	# Ticking it by hand marks it done; the id is stable for the same look.
	var plan := {"steps_done": {str(st["id"]): true}}
	var g2 := RecreationGuide.build(layout, map, plan, {"db": db, "customization": r})
	var st2: Dictionary = (g2["steps"] as Array).filter(func(s): return s["kind"] == "customize")[0]
	assert_eq(st2["id"], st["id"])
	assert_true(bool(st2["done"]))
	assert_eq(GuideExport.to_csv(g).count("Give the Farmhouse"), 1)
	# Without the option the guide is unchanged.
	assert_eq((RecreationGuide.build(layout, map, {}, {"db": db})["steps"] as Array).size(), 0)


func test_owned_parts_in_inventory_json() -> void:
	var prof := SkinBudget.with_owned({"owned": {"t_lamp": 2}}, "house", ["RoofGold"], true)
	var txt := InventoryIO.export_json(prof)
	assert_true(txt.contains("RoofGold"))
	var back := InventoryIO.import_json(txt, db, {})
	assert_eq(back["profile"][SkinBudget.OWNED_KEY], {"house": ["RoofGold"]})
	var merged := InventoryIO.import_json(txt, db, SkinBudget.with_owned({}, "truck", ["WheelsGold"], true))
	assert_eq(merged["profile"][SkinBudget.OWNED_KEY], {"house": ["RoofGold"], "truck": ["WheelsGold"]})
	var replaced := InventoryIO.import_json(txt, db, SkinBudget.with_owned({}, "truck", ["WheelsGold"], true), true)
	assert_eq(replaced["profile"][SkinBudget.OWNED_KEY], {"house": ["RoofGold"]})
	assert_false(InventoryIO.export_json({"owned": {}}).contains(SkinBudget.OWNED_KEY))
