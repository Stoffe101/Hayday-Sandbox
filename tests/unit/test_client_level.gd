extends TestCase
## ClientLevel: the multi-section level CSV and the plain data tables of the
## game client. Synthetic fixtures only (tests/fixtures/client_level, invented numbers).

const DIR := "res://tests/fixtures/client_level"


static func level() -> Dictionary:
	return ClientLevel.parse_level(JsonUtil.read_text(DIR.path_join("level_0.csv")))


static func table(name: String) -> Dictionary:
	return ClientLevel.read_table(JsonUtil.read_text(DIR.path_join(name + ".csv")))


func test_csv_reader() -> void:
	var rows := ClientLevel.parse_csv("a,b,,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"two\nlines\",z\n,,\n")
	assert_eq(rows.size(), 3)
	assert_eq(rows[0], ["a", "b", "", "c"])
	assert_eq(rows[1], ["x, y", "say \"hi\"", "two\nlines", "z"])
	assert_eq(rows[2], ["", "", ""])
	assert_eq(ClientLevel.parse_csv(""), [])


func test_level_sections_and_tilemap() -> void:
	var lv := level()
	assert_true(lv["ok"], str(lv["errors"]))
	assert_eq(lv["sections"], ["TileMap", "SpecialObjects", "Objects", "Sounds", "Objects1"])
	var tm: Dictionary = lv["tilemap"]
	assert_eq(tm["width"], 8, "trailing empty label column ignored")
	assert_eq(tm["height"], 6)
	assert_eq((tm["labels"] as Array).count("t"), 4)
	assert_eq(ClientLevel.raw_at(lv, 0, 3), 0, "blank cell = 0")
	assert_eq(ClientLevel.raw_at(lv, 2, 1), 2)
	assert_eq(ClientLevel.raw_at(lv, 7, 3), 403)
	assert_eq(ClientLevel.raw_at(lv, 8, 0), -1, "outside the map")
	assert_eq(ClientLevel.raw_at(lv, 0, -1), -1)
	assert_eq(ClientLevel.ground_of(403), 3)
	assert_eq(ClientLevel.expansion_of(403), 4)
	assert_eq(ClientLevel.expansion_of(2), 0)
	assert_eq(ClientLevel.expansion_ids(lv), {1: 4, 2: 4, 4: 8})


func test_special_objects_objects_and_flat_sections() -> void:
	var lv := level()
	var so: Array = lv["special_objects"]
	assert_eq(so.size(), 3)
	assert_eq(so[1]["name"], "Car")
	assert_eq([so[1]["x"], so[1]["y"]], [2, 2])
	assert_eq([so[2]["x"], so[2]["y"]], [1, -2], "negative coordinates are valid")
	assert_false(so[0]["mirrored"])
	assert_eq((lv["objects"]["Objects"] as Array).size(), 2)
	assert_true(lv["objects"]["Objects"][1]["mirrored"])
	assert_eq(lv["objects"]["Objects1"][0], {"name": "Rock", "x": 4, "y": 0, "mirrored": false})
	var all := ClientLevel.all_objects(lv)
	assert_eq(all.size(), 3)
	assert_eq(all[2]["group"], "Objects1")
	var snd: Dictionary = lv["tables"]["Sounds"]
	assert_eq(snd["header"], ["SoundName", "X", "Y", "Loop"])
	assert_eq(snd["rows"][0]["Y"], "", "blank stays blank in a flat section")


func test_bad_level_text() -> void:
	var lv := ClientLevel.parse_level(",,\n,,\n")
	assert_false(lv["ok"])
	assert_true((lv["errors"] as Array).size() > 0)
	var lv2 := ClientLevel.parse_level("SpecialObjects,,\n,Name,X\n,string,int\n,Thing,3\n")
	assert_false(lv2["ok"], "no TileMap")
	assert_eq(lv2["special_objects"][0]["x"], 3)


func test_tables_group_continuation_rows() -> void:
	var ex := table("expansions")
	assert_eq((ex["rows"] as Array).size(), 5, "one row per definition")
	assert_eq(ex["rows"][2]["Name"], "30")
	assert_eq(ex["rows"][2]["_index"], 3)
	assert_eq((ex["rows"][2]["_extra"] as Array).size(), 1)
	assert_eq(ClientLevel.tool_amounts(ex["rows"][2]), {"Spade": 1000, "Rake": 1000})
	assert_eq(ClientLevel.table_row(ex, "40")["LimitedCollectionToolAmount"], "3")
	assert_eq(ClientLevel.table_row(ex, "nope"), {})
	var d := table("decos")
	assert_true(ClientLevel.has_size(d))
	assert_false(ClientLevel.has_size(ex))
	assert_eq(ClientLevel.tile_size(ClientLevel.table_row(d, "LongThing")), Vector2i(4, 1))
	assert_eq(ClientLevel.tile_size({}), Vector2i.ZERO)
	assert_eq(ClientLevel.table_row(d, "Bakery")["Note"], "plain, with a comma")
	assert_eq(ClientLevel.table_row(d, "Bakery")["_extra"][0]["Note"], "level 2 row \"quoted\"")
	var t := table("tiles")
	assert_eq(t["rows"][2]["Name"], "Road_A_Parked", "tile type id = data row index")
