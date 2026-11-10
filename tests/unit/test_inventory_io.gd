extends TestCase
## InventoryIO: CSV / JSON export and tolerant import.

var db: ItemDatabase


func before_each() -> void:
	db = fixture_db()


func _profile() -> Dictionary:
	return {"level": 30, "owned": {"t_bakery": 1, "t_long": 12}, "purchased": {"t_long": 15},
		"balances": {"coins": 142500, "voucher_green": 7}}


func test_csv_round_trip() -> void:
	var csv := InventoryIO.export_csv(_profile(), db)
	assert_has(csv, "item_id,name,owned,purchased")
	assert_has(csv, "currency:coins,Coins,142500,")
	assert_has(csv, "t_long,Long Hedge,12,15")
	var rep := InventoryIO.import_csv(csv, db, {"level": 30}, true)
	assert_true(rep["ok"])
	assert_eq(rep["unknown"], [])
	assert_eq(rep["errors"], [])
	var p: Dictionary = rep["profile"]
	assert_eq(p["owned"], _profile()["owned"])
	assert_eq(p["purchased"], _profile()["purchased"])
	assert_eq(p["balances"], _profile()["balances"])
	assert_eq(p["level"], 30, "other profile keys kept")


func test_json_round_trip() -> void:
	var text := InventoryIO.export_json(_profile())
	var rep := InventoryIO.import_text(text, db, {}, true)
	assert_true(rep["ok"])
	assert_eq(rep["profile"]["owned"], _profile()["owned"])
	assert_eq(rep["profile"]["balances"], _profile()["balances"])
	assert_eq(rep["owned"], 2)


func test_tolerant_csv_import() -> void:
	var text := "﻿Name;Owned;Item_ID\n\"long hedge\";3;\nWood Fence;2;old_fence\nNope Thing;1;nope_id\nTest Bakery;x;t_bakery\n;;\ndiamonds;40;\nLAMP;5;T_LAMP\n"
	var start := {"owned": {"t_path": 9, "t_long": 1}}
	var rep := InventoryIO.import_csv(text, db, start)
	var p: Dictionary = rep["profile"]
	assert_eq(p["owned"]["t_long"], 3, "matched by name, case-insensitive")
	assert_eq(p["owned"]["t_fence"], 2, "alias resolved")
	assert_eq(p["owned"]["t_lamp"], 5, "id case-insensitive")
	assert_eq(p["owned"]["t_path"], 9, "merge keeps entries not in the file")
	assert_false(p["owned"].has("t_bakery"), "invalid number not imported")
	assert_eq(p["balances"], {"diamonds": 40})
	assert_eq(rep["unknown"], ["nope_id"])
	assert_eq(rep["errors"].size(), 1)
	assert_eq(rep["by_name"].size(), 1)
	assert_eq(rep["aliases"], [{"from": "old_fence", "to": "t_fence"}])
	assert_eq(start["owned"]["t_long"], 1, "input profile not mutated")


func test_headerless_and_replace() -> void:
	var rep := InventoryIO.import_csv("t_long,Long Hedge,4,6\nt_lamp,,2,\n", db, {"owned": {"t_path": 1}}, true)
	assert_eq(rep["profile"]["owned"], {"t_long": 4, "t_lamp": 2}, "replace drops old entries")
	assert_eq(rep["profile"]["purchased"], {"t_long": 6})


func test_ambiguous_names_reported() -> void:
	db.add_item(ItemDef.from_dict({"id": "t_lamp_2", "name": "Lamp", "category": "decoration", "footprint": [1, 1]}, []))
	db.finalize()
	var rep := InventoryIO.import_csv("name,owned\nlamp,1\n", db, {})
	assert_eq(rep["ambiguous"], [{"name": "lamp", "items": ["t_lamp", "t_lamp_2"]}])
	assert_eq((rep["profile"]["owned"] as Dictionary).size(), 0)


func test_bad_json() -> void:
	var rep := InventoryIO.import_json("{not json", db, {"owned": {"t_long": 1}})
	assert_false(rep["ok"])
	assert_eq(rep["profile"]["owned"], {"t_long": 1})
	rep = InventoryIO.import_json('{"owned": {"t_long": -2, "Lamp": 3, "zzz": 1}}', db, {})
	assert_eq(rep["profile"]["owned"], {"t_lamp": 3})
	assert_eq(rep["unknown"], ["zzz"])
	assert_eq(rep["errors"].size(), 1)


func test_quoted_csv_fields() -> void:
	var rows := InventoryIO.parse_csv("a,\"b, with comma\",\"say \"\"hi\"\"\"\nx,y,z")
	assert_eq(rows.size(), 2)
	assert_eq(rows[0][1], "b, with comma")
	assert_eq(rows[0][2], "say \"hi\"")
