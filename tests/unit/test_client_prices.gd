extends TestCase
## Client-price supplement (docs/research/CLIENT_PRICES.md): reading client
## tables / a reference file, matching records to catalogue items, the PriceBook
## client layer (precedence, not-for-sale, schedules), every-N price rises, the
## shop price -> purchase counter, appearance parts, and the budget / shopping
## list using the same prices. Every table and number here is invented.

const Fx := preload("res://tests/unit/test_budget.gd")
const DIR := "user://test_client_tables"
const SUPP := "user://test_private/client_prices.json"

var db: ItemDatabase
var pb: PriceBook


func before_each() -> void:
	db = Fx.make_db()
	pb = Fx.make_prices(db)


func after_each() -> void:
	for d in [DIR, SUPP.get_base_dir()]:
		var abs := ProjectSettings.globalize_path(d)
		if DirAccess.dir_exists_absolute(abs):
			for f in DirAccess.get_files_at(abs):
				DirAccess.remove_absolute(abs.path_join(f))
			DirAccess.remove_absolute(abs)


func _rec(table: String, name: String, price: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var r := {"table": table, "source_name": name, "purchase_price_fields": price, "voucher_requirements": [],
		"translation_id": "TID_" + name.to_upper().replace(" ", "_"), "asset_export": name.to_lower().replace(" ", "_") + "_x"}
	r.merge(extra, true)
	return r


func _ref(records: Array) -> Dictionary:
	return {"format": ClientPrices.REFERENCE_FORMAT, "game_version": "9.9.9", "records": records}


func _supp(items: Dictionary, components: Dictionary = {}) -> Dictionary:
	return {"format": PriceBook.CLIENT_FORMAT, "schema_version": 1, "game_version": "9.9.9", "items": items,
		"components": components}


func _write(path: String, lines: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(PackedStringArray(lines)) + "\n")
	f.close()


# --- currencies ----------------------------------------------------------------------------------

func test_game_vouchers_and_pearls() -> void:
	assert_eq(Currency.from_game_voucher("Voucher1"), "voucher_green")
	assert_eq(Currency.from_game_voucher("Voucher2"), "voucher_blue")
	assert_eq(Currency.from_game_voucher("Voucher3"), "voucher_purple")
	assert_eq(Currency.from_game_voucher("Voucher4"), "voucher_gold")
	assert_eq(Currency.from_game_voucher("Voucher5"), "voucher5", "an unnamed voucher keeps its own id")
	assert_eq(Currency.format_line({"pearls": 2}), "2 pearls")
	assert_eq(Currency.format_line({"pearls": 1, "coins": 5}), "5 coins · 1 pearl")
	assert_true(Currency.sort_index("pearls") < Currency.sort_index("film"))


# --- every-N price rises and the shop price -> counter -------------------------------------------

func test_step_every_n_copies() -> void:
	var r := PriceBook.empty_record()
	r.merge({"method": "shop", "price": {"coins": 10}, "step": {"coins": 4}, "step_every": 3}, true)
	var got: Array = []
	for k in range(1, 8):
		got.append(int(PriceBook.record_copy_price(r, k)["coins"]))
	assert_eq(got, [10, 10, 10, 14, 14, 14, 18])
	for x in 12:
		var brute := 0
		for i in x:
			@warning_ignore("integer_division")
			brute += i / 3
		assert_eq(PriceBook.steps_before(x, 3), brute, "steps_before(%d)" % x)


func test_price_of_copies_closed_form_matches_per_copy() -> void:
	pb.set_override("t_long", {"price": {"coins": 7}, "step": {"coins": 3}, "step_every": 2})
	for first in [1, 2, 5]:
		for n in [1, 2, 3, 7]:
			var sum := 0
			for k in range(first, first + n):
				sum += int(pb.copy_price("t_long", k)["coins"])
			assert_eq(int(pb.price_of_copies("t_long", first, n)["cost"]["coins"]), sum, "first %d n %d" % [first, n])


func test_copy_index_for_price() -> void:
	# t_long: 10 coins + 5 per copy.
	assert_eq(pb.copy_index_for_price("t_long", {"coins": 25}), {"copy": 4, "last": 4, "purchases": 3})
	assert_eq(int(pb.copy_index_for_price("t_long", {"coins": 12})["copy"]), -1, "not on the ladder")
	assert_eq(int(pb.copy_index_for_price("t_long", {"diamonds": 10})["copy"]), -1, "wrong currency")
	# every 3 copies: 14 coins is copies 4..6
	pb.set_override("t_long", {"price": {"coins": 10}, "step": {"coins": 4}, "step_every": 3})
	assert_eq(pb.copy_index_for_price("t_long", {"coins": 14}), {"copy": 4, "last": 6, "purchases": 3})
	# schedule: t_fence 5, 7, 9
	assert_eq(int(pb.copy_index_for_price("t_fence", {"coins": 9})["copy"]), 3)
	# constant price: the counter cannot be told
	var c := pb.copy_index_for_price("t_bakery", {"coins": 50})
	assert_eq(int(c["copy"]), 1)
	assert_true(int(c["last"]) > 1)
	assert_eq(int(pb.copy_index_for_price("t_prize", {"coins": 1})["copy"]), -1, "not buyable")


# --- reading client data -------------------------------------------------------------------------

func test_records_from_reference() -> void:
	var errs: Array = []
	var recs := ClientPrices.records_from_reference(_ref([
		_rec("decorations", "Voucher Tree", {}, {"voucher_requirements": [{"game_currency": "Voucher3", "amount": 10},
			{"game_currency": "Voucher4", "amount": 5}], "can_buy_game_flag": true}),
		_rec("decorations", "Pond Lily", {"pearls": 2}, {"can_buy_game_flag": true}),
		_rec("deco_fences", "Wood Fence", {"coins": 5}, {"price_increase": 2, "increase_every_n_objects": 1, "tile_width": 1, "tile_height": 1}),
		_rec("decorations", "Rare Relic", {}, {"diamond_999_sentinel": true}),
	]), errs)
	assert_eq(errs, [])
	assert_eq(recs.size(), 4)
	assert_eq(recs[0]["vouchers"], {"voucher_purple": 10, "voucher_gold": 5})
	assert_eq(recs[1]["price"], {"pearls": 2})
	assert_eq(int(recs[2]["increase"]), 2)
	assert_eq(recs[2]["footprint"], [1, 1])
	assert_true(bool(recs[3]["sentinel_999"]))
	assert_eq(ClientPrices.records_from_reference({"format": "x"}, errs), [])
	assert_eq(errs.size(), 1)


func test_records_from_tables() -> void:
	_write(DIR + "/decorations.csv", [
		"Name,UnlockLevel,ExportName,TileWidth,TileHeight,Price,DiamondPrice,Vouchers,VoucherCount,PriceIncrease,DoPriceIncreaseEveryNObject,TID,CanBuy,PearlPrice",
		"String,int,String,int,int,int,int,String,int,int,int,String,boolean,int",
		"Voucher Tree,5,vtree,1,1,,,Voucher1,7,,,TID_DECO_VOUCHER_TREE,TRUE,",
		",,,,,,,Voucher2,3,,,,,",
		"Rare Relic,1,relic,2,2,,999,,,,,TID_RARE,,",
		"Pond Lily,20,lily,1,1,,,,,,,TID_LILY,TRUE,4",
		"\"Odd, Thing\",3,odd,1,1,30,,,,6,4,TID_ODD,FALSE,",
	])
	_write(DIR + "/processing_buildings.csv", [
		"Name,UnlockLevel,Price,PriceIncrease,DoPriceIncreaseEveryNObject,MaxHabitatsColumnName,ExportName,TileWidth,TileHeight,TID",
		"String,int,int,int,int,String,String,int,int,String",
		"Mill,3,5,95,1,MaxMills,mill_01,3,3,TID_MILL",
		",,6,,,,,,,",
		",,9,,,,,,,",
	])
	_write(DIR + "/fields.csv", ["Name,Price,DiamondPrice,ExportName,TileWidth,TileHeight,TID",
		"String,int,int,String,int,int,String", "Wheat,,2,wheat,1,1,TID_WHEAT", "EmptyField,1,,field_empty,1,1,TID_EMPTY_FIELD"])
	_write(DIR + "/exp_levels.csv", ["Level,MaxMills,MaxFields", "int,int,int", "1,1,3", "2,1,4", "3,2,4", "4,2,6"])
	_write(DIR + "/customization_house.csv", ["Name,TID,GameObject,Part,Price,DiamondPrice,Default,Disabled,ExcludeFromNormalStock,TintPart",
		"String,String,String,String,int,int,boolean,boolean,boolean,String",
		"RoofPlain,TID_ROOF_PLAIN,Home,Roof,1000,,TRUE,,,", ",,,,,,,,,Tint01",
		"RoofGold,TID_ROOF_GOLD,Home,Roof,250000,,,,,", "RoofParty,TID_ROOF_PARTY,Home,Roof,,30,,,TRUE,"])
	var errs: Array = []
	var recs := ClientPrices.records_from_tables(DIR, errs)
	var by := {}
	for r in recs:
		by[r["name"]] = r
	assert_true(by.has("Voucher Tree") and by.has("Mill") and by.has("EmptyField") and by.has("RoofGold"))
	assert_false(by.has("Wheat"), "crop rows of fields.csv are not field prices")
	assert_eq(by["Voucher Tree"]["vouchers"], {"voucher_green": 7, "voucher_blue": 3}, "continuation row adds a currency")
	assert_eq(by["Rare Relic"]["price"], {}, "999 diamonds is a placeholder, never a price")
	assert_true(bool(by["Rare Relic"]["sentinel_999"]))
	assert_eq(by["Pond Lily"]["price"], {"pearls": 4})
	assert_eq(by["Odd, Thing"]["can_buy"], false)
	assert_eq(int(by["Odd, Thing"]["every"]), 4)
	assert_eq(int(by["Mill"]["extra_price_rows"]), 2, "further Price rows are counted, not used as copy prices")
	assert_eq(int(by["Mill"]["max_count"]), 2)
	assert_eq(by["Mill"]["copy_levels"], [1, 3])
	assert_eq(int(by["EmptyField"]["max_count"]), 6)
	assert_true(bool(by["RoofPlain"]["default"]))
	assert_true(bool(by["RoofParty"]["event"]))
	assert_eq(by["RoofGold"]["component"], "house")
	assert_true(errs.size() > 0, "missing tables are noted")


# --- matching --------------------------------------------------------------------------------------

func _build(records: Array, exports: Dictionary = {}, mapping: Dictionary = {}) -> Dictionary:
	var recs := ClientPrices.records_from_reference(_ref(records))
	return ClientPrices.new().build(recs, db, exports, mapping, "9.9.9", {"kind": "test"})


func test_matching_rules_and_review() -> void:
	var doc := _build([
		_rec("decorations", "Hedge Long", {"coins": 12}, {"asset_export": "hedge_a"}),         # export -> t_long
		_rec("decorations", "Lamp", {"coins": 40}, {"asset_export": "lamp_shared"}),           # export shared, name picks t_lamp
		_rec("decorations", "Something", {"coins": 1}, {"asset_export": "both"}),              # export shared, ambiguous
		_rec("decorations", "Odd Thing", {"coins": 100}, {"translation_id": "TID_NONE"}),  # exact name -> t_odd
		_rec("decorations", "Lampx", {"coins": 3}, {"translation_id": "TID_DECO_LIMITED_LAMP"}),  # tid -> t_limited
		_rec("decorations", "Stone Fences", {"coins": 9}),                                     # loose only: review
		_rec("decorations", "Mapped By Me", {"coins": 77}),                                    # user mapping -> t_path
		_rec("decorations", "Ignore Me", {"coins": 1}),                                        # user ignores
	], {"hedge_a": ["t_long"], "lamp_shared": ["t_lamp", "t_bakery"], "both": ["t_lamp", "t_bakery"]},
		{"decorations:mapped by me": "t_path", "decorations:ignore me": ""})
	var items: Dictionary = doc["items"]
	assert_eq(items["t_long"]["client"]["rule"], ClientPrices.RULE_EXPORT)
	assert_eq(items["t_lamp"]["client"]["rule"], ClientPrices.RULE_EXPORT)
	assert_eq(items["t_odd"]["client"]["rule"], ClientPrices.RULE_NAME)
	assert_eq(items["t_limited"]["client"]["rule"], ClientPrices.RULE_TID)
	assert_eq(items["t_path"]["client"]["rule"], ClientPrices.RULE_USER)
	assert_false(items.has("t_fence_stone"), "a loose name similarity is never applied")
	var kinds := {}
	for r in doc["review"]:
		kinds[r["name"]] = r
	assert_eq(kinds["Something"]["kind"], "ambiguous")
	assert_has(kinds["Stone Fences"]["candidates"], "t_fence_stone")
	assert_eq(int(doc["stats"]["ignored"]), 1)
	assert_eq(int(doc["stats"]["by_rule"][ClientPrices.RULE_EXPORT]), 2)


func test_conflicting_claims_and_shop_gift_twins() -> void:
	var doc := _build([
		_rec("decorations", "Lamp A", {"coins": 10}, {"asset_export": "lamp"}),
		_rec("decorations", "Lamp B", {"coins": 20}, {"asset_export": "lamp"}),
		_rec("decorations", "Snail", {}, {"asset_export": "snail"}),
		_rec("decorations", "SnailShop", {"coins": 1500}, {"asset_export": "snail"}),
	], {"lamp": ["t_lamp"], "snail": ["t_mystery"]})
	assert_false((doc["items"] as Dictionary).has("t_lamp"), "two different prices for one item: neither is applied")
	assert_eq(int(doc["stats"]["conflicting_claims"]), 1)
	assert_eq(doc["items"]["t_mystery"]["price"], {"coins": 1500}, "the one priced twin is the shop price")
	assert_has(doc["items"]["t_mystery"]["client"]["also_matched"], "decorations:snail")


func test_customization_parts_are_components_not_items() -> void:
	var doc := _build([_rec("customization_house", "RoofGold", {"coins": 250000})])
	assert_true((doc["items"] as Dictionary).is_empty())
	assert_eq(int(doc["stats"]["component_records"]), 1)
	assert_eq(doc["components"]["house"]["RoofGold"]["price"], {"coins": 250000})


# --- the PriceBook client layer ---------------------------------------------------------------

func test_client_layer_precedence() -> void:
	var n := pb.load_client_data(_supp({
		"t_long": {"client_status": "priced", "method": "shop", "price": {"coins": 11}, "step": {"coins": 2}, "step_every": 2},
		"t_voucher": {"client_status": "priced", "method": "vouchers", "price": {"voucher_purple": 10, "voucher_gold": 5}},
	}))
	assert_eq(n, 2)
	var r := pb.resolved("t_long")
	assert_eq(r["origin"], PriceBook.ORIGIN_CLIENT)
	assert_eq(r["confidence"], "game_data")
	assert_eq(pb.copy_price("t_long", 3), {"coins": 13})
	assert_true(str(r.get("client_conflict", "")).contains("10 coins"), "the researched price is kept for comparison")
	assert_eq(pb.copy_price("t_voucher", 1), {"voucher_purple": 10, "voucher_gold": 5})
	# the user's override still wins over client data
	pb.set_override("t_long", {"price": {"coins": 99}})
	assert_eq(pb.copy_price("t_long", 1), {"coins": 99})
	assert_eq(pb.resolved("t_long")["origin"], PriceBook.ORIGIN_USER)
	pb.remove_override("t_long")
	pb.clear_client()
	assert_eq(pb.copy_price("t_long", 1), {"coins": 10}, "without client data: research again")


func test_client_keeps_consistent_schedule_and_max_count() -> void:
	pb.load_client_data(_supp({
		"t_fence": {"client_status": "priced", "method": "shop", "price": {"coins": 5}, "max_count": 4, "copy_levels": [1, 1, 3, 9]},
		"t_fence_stone": {"client_status": "priced", "method": "shop", "price": {"coins": 25}},
	}))
	assert_eq(pb.copy_price("t_fence", 3), {"coins": 9}, "client agrees on copy 1 and gives no rise: schedule kept")
	assert_eq(int(pb.resolved("t_fence")["max_count"]), 4)
	assert_eq(pb.copy_price("t_fence_stone", 2), {"coins": 25}, "client disagrees on copy 1: its own price")


func test_client_not_sold() -> void:
	pb.load_client_data(_supp({
		"t_bakery": {"client_status": "not_sold", "client": {"can_buy": null, "sentinel_999": true}},
		"t_mystery": {"client_status": "not_sold"},
		"t_prize": {"client_status": "not_sold"},
		"t_odd": {"client_status": "no_price"},
	}))
	var b := pb.resolved("t_bakery")
	assert_eq(pb.copy_price("t_bakery", 1), {"coins": 50}, "a researched (offer) price is kept")
	assert_eq(b["confidence"], "unverified")
	assert_true(str(b["client_conflict"]).contains("999-diamond"))
	assert_eq(pb.method("t_mystery"), PriceBook.METHOD_NOT_IN_SHOP, "unknown + not for sale = not sold in the shop")
	assert_eq(pb.method("t_prize"), PriceBook.METHOD_REWARD, "a known route is kept")
	assert_eq(pb.copy_price("t_odd", 1), {"coins": 100, "moon_rocks": 2}, "no_price changes nothing")
	assert_null(pb.copy_price("t_mystery", 1), "never a 999-diamond price")


func test_bad_supplement_rejected() -> void:
	assert_eq(pb.load_client_data({"format": "nope"}), -1)
	assert_false(pb.has_client_data())
	assert_true(ClientPrices.validate({"format": PriceBook.CLIENT_FORMAT, "items": {}}).size() >= 1)
	assert_eq(ClientPrices.validate(_supp({"t_long": {"client_status": "priced", "price": {"coins": 1}}})), PackedStringArray())


func test_skin_cost() -> void:
	pb.load_client_data(_supp({}, {"house": {
		"RoofPlain": {"name": "RoofPlain", "slot": "Roof", "price": {"coins": 1000}, "default": true},
		"RoofGold": {"name": "RoofGold", "slot": "Roof", "price": {"coins": 250000}},
		"WallBlue": {"name": "WallBlue", "slot": "Building", "price": {"diamonds": 30}, "event": true},
	}}))
	var c := pb.skin_cost("house", {"Roof": "RoofGold", "Building": "WallBlue", "Porch": "PorchX"})
	assert_eq(c["cost"], {"coins": 250000, "diamonds": 30})
	assert_eq(c["unknown"], ["PorchX"])
	assert_eq(pb.skin_cost("house", {"Roof": "RoofPlain"})["cost"], {}, "a default part comes with the farm")
	assert_false(bool(pb.skin_cost("truck", {"TintBody": "X"})["known"]))


# --- install, report, rollback ------------------------------------------------------------------

func test_install_report_and_rollback() -> void:
	var doc := _build([_rec("decorations", "Odd Thing", {"coins": 120}), _rec("decorations", "Stone Path", {"coins": 15})])
	var rep := ClientPrices.build_report(doc, pb, db)
	assert_eq(int(rep["coverage"]["price_changed"]), 1, "t_odd: 100 coins + moon rocks -> 120 coins")
	assert_eq(int(rep["coverage"]["newly_priced"]), 1, "t_path had no price")
	assert_false(pb.has_client_data(), "building the report leaves the public book alone")
	assert_true(ClientPrices.report_markdown(rep).contains("Newly priced"))
	var res := ClientPrices.install(doc, rep, SUPP)
	assert_true(bool(res["ok"]), str(res["error"]))
	assert_eq(res["previous"], "")
	var doc2 := doc.duplicate(true)
	doc2["game_version"] = "10.0.0"
	assert_true(bool(ClientPrices.install(doc2, rep, SUPP)["ok"]))
	assert_eq(str(JsonUtil.read_json(SUPP)["game_version"]), "10.0.0")
	assert_true(bool(ClientPrices.rollback(SUPP)["ok"]))
	assert_eq(str(JsonUtil.read_json(SUPP)["game_version"]), "9.9.9", "rollback restores the previous version")
	var bad := ClientPrices.install({"format": "x"}, rep, SUPP)
	assert_false(bool(bad["ok"]))
	assert_eq(str(JsonUtil.read_json(SUPP)["game_version"]), "9.9.9", "a rejected supplement changes nothing")
	var book := PriceBook.new()
	book.set_catalogue(db)
	assert_true(book.load_client(SUPP))
	assert_eq(book.copy_price("t_path", 1), {"coins": 15})
	assert_true(ClientPrices.remove(SUPP))
	assert_false(FileAccess.file_exists(SUPP))


# --- one engine for every view -----------------------------------------------------------------

func test_budget_and_shopping_list_use_client_prices() -> void:
	var layout := FarmLayout.new()
	var eng := BudgetEngine.new(layout, db, pb, fixture_map())
	for i in 4:
		layout.add_objects([make_obj(db.get_item("t_long"), Vector2i(i, 0))])
	layout.add_objects([make_obj(db.get_item("t_voucher"), Vector2i(0, 3))])
	var before := int(eng.totals(null, BudgetEngine.MODE_DESIGN).cost.get("coins", 0))
	assert_eq(before, 10 + 15 + 20 + 25)
	pb.load_client_data(_supp({
		"t_long": {"client_status": "priced", "method": "shop", "price": {"coins": 10}, "step": {"coins": 4}, "step_every": 3},
		"t_voucher": {"client_status": "priced", "method": "shop", "price": {"pearls": 3, "voucher_gold": 1}},
	}))
	var t := eng.totals(null, BudgetEngine.MODE_DESIGN)
	assert_eq(int(t.cost.get("coins", 0)), 10 + 10 + 10 + 14, "the engine follows the price book")
	assert_eq(int(t.cost.get("pearls", 0)), 3)
	assert_eq(int(t.cost.get("voucher_gold", 0)), 1)
	# the purchase counter shifts the ladder (as when the player enters the shop price)
	var c := pb.copy_index_for_price("t_long", {"coins": 14})
	var p := layout.profile.duplicate(true)
	p["owned"] = {"t_long": 0}
	p["purchased"] = {"t_long": int(c["purchases"])}
	layout.profile = p
	layout.planning_changed.emit()
	assert_eq(int(eng.totals(null, BudgetEngine.MODE_TO_BUY).cost.get("coins", 0)), 14 + 14 + 14 + 18)
	var rows: Array = ShoppingList.build(eng, null, BudgetEngine.MODE_TO_BUY)
	var row := {}
	for r in rows:
		if r.get("item") == "t_long":
			row = r
	assert_eq(row.get("next_price"), {"coins": 14}, "the shopping list prices the next copy the same way")
	eng.dispose()


func test_price_summary_uses_the_price_book() -> void:
	assert_eq(PlanUiModels.price_summary(pb, "t_long"), "10 coins (+5 coins per copy)")
	assert_true(PlanUiModels.price_summary(pb, "t_prize").begins_with("Can't be bought"))
	assert_eq(PlanUiModels.price_summary(pb, "t_mystery"), "Price unknown")
	pb.load_client_data(_supp({"t_long": {"client_status": "priced", "method": "shop", "price": {"coins": 8},
		"step": {"coins": 2}, "step_every": 4}}))
	assert_eq(PlanUiModels.price_summary(pb, "t_long"), "8 coins (+2 coins every 4 copies)", "the card follows the client layer")
	assert_eq(PlanUiModels.price_summary(pb, "t_fence"), "5 coins (first copy; dearer later)")
