extends TestCase
## Currency helpers and PriceBook: catalogue parsing, layering, per-copy prices,
## unknowns, overrides IO, and the real data/prices file.

const Fx := preload("res://tests/unit/test_budget.gd")
const OVR := "user://test_price_overrides.json"

var db: ItemDatabase
var pb: PriceBook


func before_each() -> void:
	db = Fx.make_db()
	pb = Fx.make_prices(db)


func after_each() -> void:
	for p in [OVR, OVR + ".tmp", OVR + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _item(cost: Dictionary, extra: Dictionary = {}) -> ItemDef:
	var d := {"id": "x_item", "name": "X", "category": "decoration", "footprint": [1, 1], "cost": cost,
		"data_status": "community"}
	d.merge(extra, true)
	return ItemDef.from_dict(d, [])


# --- Currency ------------------------------------------------------------------------------------

func test_currency_format_and_order() -> void:
	assert_eq(Currency.format_amount(142500), "142,500")
	assert_eq(Currency.format_amount(999), "999")
	assert_eq(Currency.format_amount(1000), "1,000")
	assert_eq(Currency.format_amount(-1234567), "-1,234,567")
	assert_eq(Currency.sorted_ids(["zzz", "mallet", "film", "coins", "voucher_gold", "diamonds", "voucher_green", "abc"]),
		["coins", "diamonds", "voucher_green", "voucher_gold", "film", "mallet", "abc", "zzz"])
	assert_eq(Currency.name_of("voucher_purple"), "Purple vouchers")
	assert_eq(Currency.name_of("moon_rocks"), "moon_rocks", "unknown ids shown by id")
	assert_eq(Currency.format_line({"diamonds": 1, "coins": 142500}), "142,500 coins · 1 diamond")
	assert_eq(Currency.format_line({}), "Free")
	assert_eq(Currency.format_line(null), "Price unknown")
	assert_eq(Currency.format_range({"coins": 349}, {"coins": 649}), "349–649 coins")


func test_cost_helpers() -> void:
	assert_eq(Currency.add({"coins": 5}, {"coins": 2, "film": 1}), {"coins": 7, "film": 1})
	assert_eq(Currency.scale({"coins": 5, "diamonds": 1}, 3), {"coins": 15, "diamonds": 3})
	assert_true(Currency.is_zero({}))
	assert_true(Currency.is_zero({"coins": 0}))
	assert_false(Currency.is_zero(null), "unknown is not zero")
	assert_false(Currency.is_zero({"coins": 1}))
	assert_eq(Currency.normalize({"coins": 349.0, "film": 0}), {"coins": 349})
	assert_null(Currency.normalize({"coins": -1}))
	assert_null(Currency.normalize({"coins": "lots"}))
	assert_true(Currency.covers({"coins": 10, "diamonds": 2}, {"coins": 10}))
	assert_false(Currency.covers({"coins": 10, "diamonds": 100}, {"coins": 11}), "no conversion")
	assert_eq(Currency.shortfall({"coins": 3}, {"coins": 10, "film": 2}), {"coins": 7, "film": 2})


# --- catalogue parsing ---------------------------------------------------------------------------------

func test_catalogue_cost_other_parsing() -> void:
	var r := PriceBook.parse_catalogue(_item({"coins": 349, "other": "+150 coins per additional purchase"}))
	assert_eq(r["method"], PriceBook.METHOD_SHOP)
	assert_eq(r["price"], {"coins": 349})
	assert_eq(r["step"], {"coins": 150})
	assert_eq(r["origin"], PriceBook.ORIGIN_CATALOGUE)
	r = PriceBook.parse_catalogue(_item({"other": "5 green voucher + 1 purple voucher"}))
	assert_eq(r["method"], PriceBook.METHOD_VOUCHERS)
	assert_eq(r["price"], {"voucher_green": 5, "voucher_purple": 1})
	r = PriceBook.parse_catalogue(_item({"other": "400 film (event currency)"}))
	assert_eq(r["method"], PriceBook.METHOD_EVENT)
	assert_eq(r["price"], {"film": 400})
	r = PriceBook.parse_catalogue(_item({"other": "490 golden keys"}))
	assert_eq(r["price"], {"golden_keys": 490})
	r = PriceBook.parse_catalogue(_item({"other": "not sold in shop (source lists 999-diamond placeholder)"}))
	assert_eq(r["method"], PriceBook.METHOD_NOT_IN_SHOP)
	assert_null(r["price"], "placeholder never a price")
	r = PriceBook.parse_catalogue(_item({"other": "no price in source (reward/prize item)"}))
	assert_eq(r["method"], PriceBook.METHOD_REWARD)
	r = PriceBook.parse_catalogue(_item({"coins": 0, "other": "free"}))
	assert_eq(r["method"], PriceBook.METHOD_FREE)
	assert_eq(r["price"], {})
	r = PriceBook.parse_catalogue(_item({"other": "removal tool: Axe"}))
	assert_eq(r["method"], PriceBook.METHOD_UNKNOWN, "a removal tool is not a purchase price")
	assert_eq(r["info"], "removal tool: Axe")
	r = PriceBook.parse_catalogue(_item({"diamonds": 25}))
	assert_eq(r["price"], {"diamonds": 25})
	r = PriceBook.parse_catalogue(_item({"other": "something odd"}))
	assert_eq(r["method"], PriceBook.METHOD_UNKNOWN)
	assert_eq(r["notes"], "something odd")
	assert_eq(PriceBook.parse_catalogue(_item({})), {}, "no information at all")


func test_every_real_catalogue_cost_text_is_understood() -> void:
	var real := ItemDatabase.new()
	real.load_default()
	var unparsed: Array = []
	for it: ItemDef in real.ordered:
		if it.cost_other.is_empty():
			continue
		var r := PriceBook.parse_catalogue(it)
		if not str(r.get("notes", "")).is_empty() and r["method"] == PriceBook.METHOD_UNKNOWN:
			unparsed.append(it.cost_other)
		if r["method"] in [PriceBook.METHOD_SHOP, PriceBook.METHOD_VOUCHERS, PriceBook.METHOD_EVENT] and r["price"] != null:
			assert_false(Currency.is_zero(r["price"]) and it.cost_other != "free", "%s: no silent zero" % it.id)
	assert_eq(unparsed, [], "unrecognised cost texts")


# --- layering and prices ------------------------------------------------------------------------------

func test_layering_and_origin() -> void:
	assert_eq(pb.resolved("t_lamp")["origin"], PriceBook.ORIGIN_CATALOGUE, "fallback to the catalogue")
	assert_eq(pb.copy_price("t_lamp", 1), {"diamonds": 5})
	assert_eq(pb.resolved("t_bakery")["origin"], PriceBook.ORIGIN_PRICE_DB)
	assert_eq(pb.resolved("t_bakery")["confidence"], "confirmed")
	assert_eq(pb.resolved("t_path")["origin"], PriceBook.ORIGIN_NONE)
	assert_eq(pb.resolved("old_fence")["item"], "t_fence", "aliases resolve")
	var v := pb.version
	pb.set_override("t_bakery", {"price": {"coins": 60}})
	assert_true(pb.version > v)
	assert_eq(pb.resolved("t_bakery")["origin"], PriceBook.ORIGIN_USER)
	assert_eq(pb.copy_price("t_bakery", 1), {"coins": 60})
	assert_eq(pb.resolved("t_bakery")["max_count"], 1, "fields the override leaves out fall back")
	assert_eq(pb.layer("t_bakery", PriceBook.ORIGIN_PRICE_DB)["price"], {"coins": 50})
	pb.remove_override("t_bakery")
	assert_eq(pb.copy_price("t_bakery", 1), {"coins": 50})


func test_step_prices() -> void:
	assert_eq(pb.copy_price("t_long", 1), {"coins": 10})
	assert_eq(pb.copy_price("t_long", 3), {"coins": 20})
	assert_true(pb.resolved("t_long")["progressive"])
	var r := pb.price_of_copies("t_long", 2, 3)
	assert_eq(r["cost"], {"coins": 15 + 20 + 25})
	assert_eq(r["known"], 3)
	assert_eq(r["unknown"], 0)
	assert_null(pb.copy_price("t_long", 0))


func test_schedule_prices() -> void:
	assert_eq(pb.copy_price("t_fence", 2), {"coins": 7})
	assert_null(pb.copy_price("t_fence", 4), "past the table: unknown")
	var r := pb.price_of_copies("t_fence", 1, 5)
	assert_eq(r["cost"], {"coins": 21})
	assert_eq(r["unknown"], 2)
	assert_eq(pb.copy_price("t_fence_stone", 9), {"coins": 30}, "schedule_repeats_last")


func test_unknown_prices_are_never_zero() -> void:
	for id in ["t_path", "t_mystery", "nonexistent_item"]:
		assert_null(pb.copy_price(id, 1), id)
		assert_false(pb.has_known_price(id))
		var r := pb.price_of_copies(id, 1, 2)
		assert_eq(r["unknown"], 2)
		assert_eq(r["known"], 0)
		assert_eq(r["cost"], {})
	assert_eq(pb.method_text("t_path"), "Price unknown")


func test_methods_and_buyability() -> void:
	assert_true(pb.is_buyable("t_voucher"))
	assert_eq(pb.copy_price("t_voucher", 3), {"voucher_green": 5, "voucher_purple": 1})
	assert_eq(pb.copy_price("t_film", 1), {"film": 400})
	assert_eq(pb.copy_price("t_free", 4), {}, "free is a known zero")
	assert_false(pb.is_buyable("t_prize"))
	assert_true(pb.is_not_buyable("t_prize"))
	assert_null(pb.copy_price("t_prize", 1))
	assert_eq(pb.method_text("t_prize"), "Can't be bought: derby reward")
	assert_true(pb.is_not_buyable("t_rare"))
	assert_null(pb.resolved("t_rare")["price"], "placeholder dropped")
	assert_eq(pb.method_text("t_rare"), "Can't be bought: not sold in the shop")


func test_override_price_wins_over_schedule_and_reward() -> void:
	pb.set_override("t_fence", {"price": {"coins": 4}})
	assert_eq(pb.copy_price("t_fence", 7), {"coins": 4}, "a user price replaces the old schedule")
	pb.set_override("t_prize", {"price": {"diamonds": 9}})
	assert_eq(pb.method("t_prize"), PriceBook.METHOD_SHOP)
	assert_eq(pb.copy_price("t_prize", 1), {"diamonds": 9})
	pb.set_override("t_long", {"method": "reward", "routes": ["collection"]})
	assert_null(pb.copy_price("t_long", 1))


func test_overrides_save_and_load() -> void:
	pb.overrides_path = OVR
	pb.set_override("t_path", {"price": {"coins": 3}, "confidence": "unverified", "notes": "my guess"})
	assert_eq(pb.save_overrides(), OK)
	var pb2 := PriceBook.new()
	pb2.overrides_path = OVR
	pb2.set_catalogue(db)
	pb2.load_file("res://tests/fixtures/prices.json")
	assert_eq(pb2.load_overrides(), 1)
	assert_eq(pb2.copy_price("t_path", 2), {"coins": 3})
	assert_eq(pb2.resolved("t_path")["origin"], PriceBook.ORIGIN_USER)
	assert_eq(pb2.resolved("t_path")["notes"], "my guess")
	var raw: Variant = JsonUtil.read_json(OVR)
	assert_eq(raw["format"], PriceBook.OVERRIDES_FORMAT)


func test_bad_price_data_is_reported_not_guessed() -> void:
	var p := PriceBook.new()
	p.set_catalogue(db)
	assert_eq(p.load_data({"format": "other"}), -1)
	assert_true(p.errors.size() > 0)
	var n := p.load_data({"format": PriceBook.FORMAT, "schema_version": 1,
		"items": {"t_long": {"method": "shop", "price": {"coins": -5}}, "t_lamp": {"method": "teleport", "price": {"coins": 1}}}})
	assert_eq(n, 2)
	assert_null(p.copy_price("t_long", 1), "negative price kept unknown")
	assert_eq(p.method("t_lamp"), PriceBook.METHOD_UNKNOWN)
	assert_true(p.warnings.size() >= 2)


func test_real_price_file_loads() -> void:
	if not FileAccess.file_exists(PriceBook.DEFAULT_PATH):
		assert_true(true)
		return
	var real := ItemDatabase.new()
	real.load_default()
	var p := PriceBook.load_default(real, "user://__no_price_overrides__.json", PriceBook.DEFAULT_PATH, "")
	assert_eq(p.errors.size(), 0, "errors: %s" % str(p.errors))
	assert_eq(p.warnings.size(), 0, "warnings: %s" % str(p.warnings).left(300))
	assert_true(p.price_db_count() > 1000)
	# Feed Mill: explicit schedule 5 then 3200, nothing known past it.
	assert_eq(p.copy_price("feed_mill", 1), {"coins": 5})
	assert_eq(p.copy_price("feed_mill", 2), {"coins": 3200})
	assert_null(p.copy_price("feed_mill", 3))
	assert_eq(p.resolved("feed_mill")["copy_levels"], [2, 12], "extra fields kept")
	# A coins step.
	var bh := p.resolved("birdhouse")
	assert_eq(bh["origin"], PriceBook.ORIGIN_PRICE_DB)
	assert_eq(p.copy_price("birdhouse", 3), {"coins": 349 + 2 * 150})
	assert_eq(bh["step_confidence"], "community")
	# Vouchers.
	assert_eq(p.method("acacia_tree"), PriceBook.METHOD_VOUCHERS)
	assert_eq(p.copy_price("acacia_tree", 1), {"voucher_purple": 1, "voucher_blue": 3})
	# Not in the shop: no price, can't be bought.
	assert_true(p.is_not_buyable("abandoned_tombs"))
	assert_null(p.resolved("abandoned_tombs")["price"])
	# Free records carry coins 0: a known zero.
	assert_eq(p.copy_price("lure_workbench", 1), {})
	# Repair costs and removal tools are never acquisition prices.
	for id in ["fishing_boat", "neighborhood_house"]:
		if real.has_item(id):
			assert_null(p.copy_price(id, 1), id + " repair is not a price")
