extends SceneTree
## Writes the synthetic test pack (recoloured CC0 placeholders, no proprietary
## art) to a zip, for smoke-testing pack installation in an exported build.
##   godot --headless --path . --script res://tools/build/make_synthetic_pack.gd -- <out.zip>

const SyntheticPack := preload("res://tests/fixtures/synthetic_pack.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: -- <out.zip>")
		quit(2)
		return
	var db := ItemDatabase.new()
	db.load_default()
	var lib := AssetLibrary.new()
	lib.load_all(db)
	var r: Dictionary = SyntheticPack.build_zip(args[0], lib, db)
	print("SYNTHETIC-PACK %s" % JSON.stringify(r))
	quit(0 if FileAccess.file_exists(args[0]) else 1)
