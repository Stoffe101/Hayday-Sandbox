class_name TestCase
extends RefCounted
## Minimal xUnit-style base class. Test methods are named test_*.
## Assertions record failures instead of throwing so one run reports all.

var failures: Array[String] = []
var current_test: String = ""
var assertions: int = 0


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func fail(msg: String) -> void:
	failures.append("%s: %s" % [current_test, msg])


func assert_true(cond: bool, msg: String = "expected true") -> void:
	assertions += 1
	if not cond:
		fail(msg)


func assert_false(cond: bool, msg: String = "expected false") -> void:
	assert_true(not cond, msg)


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	assertions += 1
	var same := false
	if typeof(actual) == typeof(expected):
		same = actual == expected
	elif (actual is int or actual is float) and (expected is int or expected is float):
		same = float(actual) == float(expected)
	if not same:
		fail("%s expected <%s> got <%s>" % [msg, str(expected), str(actual)])


func assert_ne(actual: Variant, expected: Variant, msg: String = "") -> void:
	assertions += 1
	if typeof(actual) == typeof(expected) and actual == expected:
		fail("%s expected value different from <%s>" % [msg, str(expected)])


func assert_almost(actual: float, expected: float, eps: float = 0.0001, msg: String = "") -> void:
	assertions += 1
	if absf(actual - expected) > eps:
		fail("%s expected ~%f got %f" % [msg, expected, actual])


func assert_vec_almost(actual: Vector2, expected: Vector2, eps: float = 0.0001, msg: String = "") -> void:
	assertions += 1
	if actual.distance_to(expected) > eps:
		fail("%s expected ~%s got %s" % [msg, str(expected), str(actual)])


func assert_not_null(v: Variant, msg: String = "expected non-null") -> void:
	assertions += 1
	if v == null:
		fail(msg)


func assert_null(v: Variant, msg: String = "expected null") -> void:
	assertions += 1
	if v != null:
		fail(msg)


func assert_has(container: Variant, value: Variant, msg: String = "") -> void:
	assertions += 1
	var ok := false
	if container is Dictionary:
		ok = container.has(value)
	elif container is Array or container is PackedStringArray or container is PackedInt32Array:
		ok = value in container
	elif container is String:
		ok = (container as String).find(str(value)) >= 0
	if not ok:
		fail("%s expected %s to contain %s" % [msg, str(container).left(200), str(value)])


# ---- shared fixtures -------------------------------------------------------

static func fixture_db() -> ItemDatabase:
	## Small, art-free item database used by unit tests.
	var db := ItemDatabase.new()
	db.load_categories("res://tests/fixtures/categories.json")
	db.load_file("res://tests/fixtures/items.json")
	db.finalize()
	return db


static func fixture_map() -> FarmMap:
	return FarmMap.load_file("res://tests/fixtures/map.json")


static func make_obj(item: ItemDef, origin: Vector2i, flipped: bool = false) -> PlacedObject:
	var o := PlacedObject.new()
	o.item_id = item.id
	o.origin = origin
	o.flipped = flipped
	o.size = item.size_for(flipped)
	return o
