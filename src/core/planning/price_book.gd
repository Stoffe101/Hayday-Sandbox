class_name PriceBook
extends RefCounted
## Resolved item prices (docs/PLANNING.md §1). Four layers, later ones win:
##   1. the catalogue's own `cost` fields (ItemDef.cost_coins / cost_diamonds and
##      the free text cost_other, parsed),
##   2. data/prices/hayday_prices.json (researched, with sources and confidence),
##   3. the private client-price supplement (user://private_data/client_prices.json,
##      built by ClientPrices from the user's own game files; never in the
##      repository): the base client configuration of one game version,
##   4. the user's overrides (user://price_overrides.json, never in the repository):
##      prices seen in the live game, offers, corrections.
## Every resolved record says where it came from (`origin`). Unknown prices stay
## unknown: copy_price() returns null, never 0, and a placeholder never counts.

signal changed

const FORMAT := "hayday-sandbox-prices"
const OVERRIDES_FORMAT := "hayday-sandbox-price-overrides"
const SCHEMA_VERSION := 1
const DEFAULT_PATH := "res://data/prices/hayday_prices.json"
const DEFAULT_OVERRIDES := "user://price_overrides.json"
const CLIENT_FORMAT := "hayday-sandbox-client-prices"
const DEFAULT_CLIENT := "user://private_data/client_prices.json"

const METHOD_SHOP := "shop"
const METHOD_VOUCHERS := "vouchers"
const METHOD_EVENT := "event_currency"
const METHOD_REWARD := "reward"
const METHOD_NOT_IN_SHOP := "not_in_shop"
const METHOD_FREE := "free"
const METHOD_UNKNOWN := "unknown"
const METHODS := [METHOD_SHOP, METHOD_VOUCHERS, METHOD_EVENT, METHOD_REWARD, METHOD_NOT_IN_SHOP, METHOD_FREE, METHOD_UNKNOWN]
## Methods that produce a cost (when the price itself is known).
const COST_METHODS := [METHOD_SHOP, METHOD_VOUCHERS, METHOD_EVENT, METHOD_FREE]
## "Cannot be bought" (counted separately from "price unknown").
const NOT_BUYABLE_METHODS := [METHOD_REWARD, METHOD_NOT_IN_SHOP]
const METHOD_NAMES := {
	METHOD_SHOP: "Shop", METHOD_VOUCHERS: "Vouchers", METHOD_EVENT: "Event currency", METHOD_REWARD: "Reward",
	METHOD_NOT_IN_SHOP: "Not sold in the shop", METHOD_FREE: "Free", METHOD_UNKNOWN: "Unknown",
}
const AVAILABILITY := ["current", "seasonal", "event", "retired", "unknown"]
## game_data: read from the user's own game client files (private supplement).
const CONFIDENCE := ["game_data", "confirmed", "community", "unverified", "unknown"]
const ROUTES := ["derby", "event", "package", "secret", "reward", "collection", "expansion", "season_pass", "other"]
const ROUTE_NAMES := {
	"derby": "derby reward", "event": "event reward", "package": "special package", "secret": "secret item",
	"reward": "reward / prize", "collection": "collection prize", "expansion": "comes with an expansion",
	"season_pass": "season pass", "other": "other",
}
const ORIGIN_NONE := "none"
const ORIGIN_CATALOGUE := "catalogue"
const ORIGIN_PRICE_DB := "price_db"
const ORIGIN_CLIENT := "client"
const ORIGIN_USER := "user"
## Client-record status (see merge_client()).
const CLIENT_PRICED := "priced"        ## the client lists a purchase price
const CLIENT_NOT_SOLD := "not_sold"    ## CanBuy=FALSE or only the 999-diamond placeholder
const CLIENT_NO_PRICE := "no_price"    ## the client says nothing about a price
## Appearance (customization) part kinds.
const COMPONENT_KINDS := ["house", "truck", "roadside_shop"]
## Keys that describe the price itself: an override that sets any of them
## replaces all of them (so an old schedule never hides a user's new price).
const PRICE_KEYS := ["price", "step", "step_every", "schedule", "schedule_repeats_last"]

var version: int = 0
var overrides_path: String = DEFAULT_OVERRIDES
var errors: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()
## Price file metadata: {format, schema_version, generated, game_version, path}.
var file_info: Dictionary = {}
var sources: Dictionary = {}        ## source id -> {id, url, accessed, license, ...}
var currencies: Dictionary = {}     ## currency id -> {name} from the price file

var _db: ItemDatabase = null
var _catalogue: Dictionary = {}     ## item -> normalized record (origin catalogue)
var _price_db: Dictionary = {}      ## item -> normalized record (origin price_db)
var _overrides: Dictionary = {}     ## item -> raw user record (as saved)
var _client: Dictionary = {}        ## item -> normalized client record (origin client)
var _components: Dictionary = {}    ## kind -> {part name -> component record}
## Client supplement metadata: {format, schema_version, game_version, generated, source, items, components, path}.
var client_info: Dictionary = {}
var _resolved: Dictionary = {}      ## item -> resolved record (cache, cleared on change)


static func load_default(db: ItemDatabase, overrides: String = DEFAULT_OVERRIDES, price_path: String = DEFAULT_PATH) -> PriceBook:
	## Catalogue + the price file (when present) + the user's overrides (when present).
	var pb := PriceBook.new()
	pb.overrides_path = overrides
	pb.set_catalogue(db)
	if FileAccess.file_exists(price_path):
		pb.load_file(price_path)
	if FileAccess.file_exists(DEFAULT_CLIENT):
		pb.load_client(DEFAULT_CLIENT)
	pb.load_overrides()
	return pb


# --- layers ---------------------------------------------------------------------------------

func set_catalogue(db: ItemDatabase) -> void:
	## Layer 1: parse every catalogue item's cost fields.
	_db = db
	_catalogue.clear()
	if db != null:
		for it: ItemDef in db.items.values():
			var rec := parse_catalogue(it)
			if not rec.is_empty():
				_catalogue[it.id] = rec
	_bump()


func load_file(path: String) -> bool:
	## Layer 2 from a hayday_prices.json file (replaces the previous layer 2).
	var data: Variant = JsonUtil.read_json(path)
	if not data is Dictionary:
		errors.append("price file missing or invalid: %s" % path)
		return false
	var n := load_data(data)
	file_info["path"] = path
	return n >= 0


func load_data(d: Dictionary) -> int:
	## Layer 2 from parsed data; returns the number of item records (-1 = rejected).
	if str(d.get("format", "")) != FORMAT:
		errors.append("price data: format must be '%s'" % FORMAT)
		return -1
	if int(d.get("schema_version", 0)) > SCHEMA_VERSION:
		warnings.append("price data: schema_version %s is newer than this app (%d)" % [str(d.get("schema_version")), SCHEMA_VERSION])
	file_info = {"format": FORMAT, "schema_version": d.get("schema_version"), "generated": str(d.get("generated", "")),
		"game_version": str(d.get("game_version", ""))}
	sources.clear()
	for s in (d.get("sources", []) if d.get("sources") is Array else []):
		if s is Dictionary and str(s.get("id", "")) != "":
			sources[str(s["id"])] = (s as Dictionary).duplicate(true)
	currencies = (d.get("currencies") as Dictionary).duplicate(true) if d.get("currencies") is Dictionary else {}
	_price_db.clear()
	var items: Variant = d.get("items", {})
	if not items is Dictionary:
		errors.append("price data: 'items' must be an object")
		_bump()
		return 0
	for id in items:
		if not items[id] is Dictionary:
			warnings.append("price data: record for %s is not an object" % str(id))
			continue
		var w: Array = []
		_price_db[str(id)] = normalize_record(items[id], ORIGIN_PRICE_DB, w)
		for m in w:
			warnings.append("price data: %s: %s" % [str(id), m])
	_bump()
	return _price_db.size()


func load_client(path: String = DEFAULT_CLIENT) -> bool:
	## Layer 3 from a client-price supplement file (replaces the previous layer 3).
	var data: Variant = JsonUtil.read_json(path)
	if not data is Dictionary:
		errors.append("client price supplement missing or invalid: %s" % path)
		return false
	var n := load_client_data(data)
	if n >= 0:
		client_info["path"] = path
	return n >= 0


func load_client_data(d: Dictionary) -> int:
	## Layer 3 from parsed supplement data; returns the number of item records
	## (-1 = rejected, the layer is left empty).
	_client.clear()
	_components.clear()
	client_info = {}
	if str(d.get("format", "")) != CLIENT_FORMAT:
		errors.append("client price supplement: format must be '%s'" % CLIENT_FORMAT)
		_bump()
		return -1
	if int(d.get("schema_version", 0)) > SCHEMA_VERSION:
		warnings.append("client price supplement: schema_version %s is newer than this app (%d)" % [str(d.get("schema_version")), SCHEMA_VERSION])
	var items: Variant = d.get("items", {})
	if not items is Dictionary:
		errors.append("client price supplement: 'items' must be an object")
		_bump()
		return -1
	for id in items:
		if not items[id] is Dictionary:
			warnings.append("client price supplement: record for %s is not an object" % str(id))
			continue
		var w: Array = []
		var rec := normalize_record(items[id], ORIGIN_CLIENT, w)
		var st := str((items[id] as Dictionary).get("client_status", CLIENT_NO_PRICE))
		rec["client_status"] = st if st in [CLIENT_PRICED, CLIENT_NOT_SOLD, CLIENT_NO_PRICE] else CLIENT_NO_PRICE
		_client[str(id)] = rec
		for m in w:
			warnings.append("client price supplement: %s: %s" % [str(id), m])
	var n_comp := 0
	var comps: Variant = d.get("components", {})
	if comps is Dictionary:
		for kind in comps:
			if not str(kind) in COMPONENT_KINDS or not comps[kind] is Dictionary:
				continue
			var parts := {}
			for part in comps[kind]:
				var c: Variant = comps[kind][part]
				if c is Dictionary:
					parts[str(part)] = normalize_component(c)
			_components[str(kind)] = parts
			n_comp += parts.size()
	client_info = {"format": CLIENT_FORMAT, "schema_version": d.get("schema_version"),
		"game_version": str(d.get("game_version", "")), "generated": str(d.get("generated", "")),
		"source": d.get("source", {}), "items": _client.size(), "components": n_comp}
	_bump()
	return _client.size()


func derived(client_doc: Variant) -> PriceBook:
	## A book sharing this one's catalogue, price file and override layers (read
	## only), with `client_doc` (a supplement Dictionary, or null for none) as layer 3.
	var pb := PriceBook.new()
	pb._db = _db
	pb._catalogue = _catalogue
	pb._price_db = _price_db
	pb._overrides = _overrides
	pb.file_info = file_info
	pb.sources = sources
	pb.currencies = currencies
	pb.overrides_path = overrides_path
	if client_doc is Dictionary:
		pb.load_client_data(client_doc)
	return pb


func clear_client() -> void:
	if not _client.is_empty() or not _components.is_empty() or not client_info.is_empty():
		_client.clear()
		_components.clear()
		client_info = {}
		_bump()


func client_count() -> int:
	return _client.size()


func has_client_data() -> bool:
	return not _client.is_empty() or not _components.is_empty()


func load_overrides(path: String = "") -> int:
	## Layer 3 (user overrides). A missing file is an empty layer, not an error.
	var p := overrides_path if path.is_empty() else path
	_overrides.clear()
	var data: Variant = JsonUtil.read_json(p)
	if data is Dictionary and data.get("items") is Dictionary:
		for id in data["items"]:
			if data["items"][id] is Dictionary:
				_overrides[str(id)] = (data["items"][id] as Dictionary).duplicate(true)
	elif data != null:
		warnings.append("price overrides file invalid: %s" % p)
	_bump()
	return _overrides.size()


func save_overrides(path: String = "") -> Error:
	var p := overrides_path if path.is_empty() else path
	var ids := _overrides.keys()
	ids.sort()
	var items := {}
	for id in ids:
		items[id] = _overrides[id]
	var doc := {"format": OVERRIDES_FORMAT, "schema_version": SCHEMA_VERSION, "items": items}
	return JsonUtil.write_atomic(p, JsonUtil.stringify(doc), false)


func set_override(item_id: String, rec: Dictionary) -> void:
	## Stores the user's record for an item (same shape as the price file; keys
	## left out fall back to the lower layers, except that setting any of
	## price/step/schedule replaces all three). Call save_overrides() to persist.
	var r := rec.duplicate(true)
	r["origin"] = ORIGIN_USER
	_overrides[_key(item_id)] = r
	_bump()


func remove_override(item_id: String) -> void:
	if _overrides.erase(_key(item_id)):
		_bump()


func clear_overrides() -> void:
	if not _overrides.is_empty():
		_overrides.clear()
		_bump()


func override(item_id: String) -> Dictionary:
	return (_overrides.get(_key(item_id), {}) as Dictionary).duplicate(true)


func overrides() -> Dictionary:
	return _overrides.duplicate(true)


func has_override(item_id: String) -> bool:
	return _overrides.has(_key(item_id))


func layer(item_id: String, origin: String) -> Dictionary:
	## One layer's own record ({} when that layer says nothing about the item).
	var id := _key(item_id)
	match origin:
		ORIGIN_CATALOGUE: return (_catalogue.get(id, {}) as Dictionary).duplicate(true)
		ORIGIN_PRICE_DB: return (_price_db.get(id, {}) as Dictionary).duplicate(true)
		ORIGIN_CLIENT: return (_client.get(id, {}) as Dictionary).duplicate(true)
		ORIGIN_USER: return override(id)
	return {}


func price_db_count() -> int:
	return _price_db.size()


# --- queries --------------------------------------------------------------------------------

func resolved(item_id: String) -> Dictionary:
	## The effective record (shared, read-only: duplicate before changing it):
	## {item, method, price, step, step_every, step_basis, schedule,
	##  schedule_repeats_last, max_count (-1 none known), availability, confidence,
	##  routes, origin, sources, notes, info, progressive}; with client data also
	##  client_status, client (provenance) and maybe client_conflict.
	##  price/step/schedule entries are Costs or null.
	var id := _key(item_id)
	var r: Variant = _resolved.get(id)
	if r != null:
		return r
	var rec: Dictionary = _price_db[id] if _price_db.has(id) else (_catalogue[id] if _catalogue.has(id) else empty_record())
	rec = rec.duplicate(true)
	if _price_db.has(id) and int(rec.get("max_count", -1)) < 0 and _catalogue.has(id):
		rec["max_count"] = int(_catalogue[id].get("max_count", -1))   # an item fact, not a price
	if _client.has(id):
		rec = merge_client(rec, _client[id])
	if _overrides.has(id):
		var ov: Dictionary = _overrides[id]
		var w: Array = []
		var n := normalize_record(ov, ORIGIN_USER, w)
		var sets_price := false
		for k in PRICE_KEYS:
			if ov.has(k):
				sets_price = true
		for k in n:
			if ov.has(k) or (sets_price and k in PRICE_KEYS):
				rec[k] = n[k]
		if not ov.has("method") and sets_price and rec["method"] in [METHOD_UNKNOWN, METHOD_REWARD, METHOD_NOT_IN_SHOP] and n["price"] != null:
			rec["method"] = METHOD_SHOP
		rec["origin"] = ORIGIN_USER
	rec["item"] = id
	rec["progressive"] = rec["schedule"] != null or (rec["step"] != null and not Currency.is_zero(rec["step"]))
	_resolved[id] = rec
	return rec


func method(item_id: String) -> String:
	return str(resolved(item_id)["method"])


func is_buyable(item_id: String) -> bool:
	## True when the method is a purchase (shop, vouchers, event currency, free).
	## The price itself may still be unknown (see has_known_price()).
	return resolved(item_id)["method"] in COST_METHODS


func is_not_buyable(item_id: String) -> bool:
	## Reward / not sold in the shop ("can't be bought", not "price unknown").
	return resolved(item_id)["method"] in NOT_BUYABLE_METHODS


func has_known_price(item_id: String) -> bool:
	return copy_price(item_id, 1) != null


func is_constant(item_id: String) -> bool:
	## Every copy costs the same (no step, no schedule).
	return not bool(resolved(item_id)["progressive"])


func copy_price(item_id: String, k: int) -> Variant:
	## Cost of copy #k (1-based) or null when unknown / not purchasable:
	## schedule[k-1] when there is a schedule (past its end: the last entry only
	## when schedule_repeats_last, else unknown), else price + step × (k - 1).
	return record_copy_price(resolved(item_id), k)


static func record_copy_price(r: Dictionary, k: int) -> Variant:
	## copy_price() for an already resolved record (see resolved()): callers that
	## hold the record (shopping list rows) skip the id lookups.
	var m: String = r["method"]
	if not m in COST_METHODS or k < 1:
		return null
	if m == METHOD_FREE:
		return {}
	var sch: Variant = r["schedule"]
	if sch != null:
		var a: Array = sch
		if k <= a.size():
			return a[k - 1]
		if bool(r["schedule_repeats_last"]) and not a.is_empty():
			return a[a.size() - 1]
		return null
	var p: Variant = r["price"]
	if p == null:
		return null
	var st: Variant = r["step"]
	if st == null or k == 1:
		return p
	@warning_ignore("integer_division")
	var steps := (k - 1) / maxi(1, int(r.get("step_every", 1)))
	if steps == 0:
		return p
	var out: Dictionary = (p as Dictionary).duplicate()
	Currency.add_into(out, st, steps)
	return out


static func steps_before(x: int, every: int) -> int:
	## Sum of floor(i / every) for i in 0 .. x-1: how many price steps copies
	## 1..x add up to when the price rises every `every` copies.
	var n := maxi(1, every)
	if x <= 0:
		return 0
	@warning_ignore("integer_division")
	var q := x / n
	var rm := x % n
	@warning_ignore("integer_division")
	return n * q * (q - 1) / 2 + q * rm


func price_of_copies(item_id: String, first_k: int, count: int) -> Dictionary:
	## Sum for copies first_k .. first_k + count - 1:
	## {"cost": known part, "known": copies priced, "unknown": copies without a price}.
	var out := {"cost": {}, "known": 0, "unknown": 0}
	if count <= 0:
		return out
	var r := resolved(item_id)
	var cost: Dictionary = out["cost"]
	if r["schedule"] == null and r["method"] in COST_METHODS and (r["price"] != null or r["method"] == METHOD_FREE):
		if r["method"] == METHOD_FREE:
			out["known"] = count
			return out
		# price × count + step × (sum of floor((k-1) / every)) in closed form.
		Currency.add_into(cost, r["price"], count)
		if r["step"] != null:
			var a := first_k - 1
			var every := maxi(1, int(r.get("step_every", 1)))
			var steps := steps_before(a + count, every) - steps_before(a, every)
			Currency.add_into(cost, r["step"], steps)
		out["known"] = count
		return out
	for i in count:
		var c: Variant = copy_price(item_id, first_k + i)
		if c == null:
			out["unknown"] = int(out["unknown"]) + 1
		else:
			Currency.add_into(cost, c)
			out["known"] = int(out["known"]) + 1
	return out


func copy_index_for_price(item_id: String, current: Dictionary, limit: int = 100000) -> Dictionary:
	## The copy number whose price equals `current` (the price the game shows now
	## for the next purchase): {copy (1-based, -1 = no copy has that price),
	## last (the last copy with that price; > copy when the price rises only every
	## N copies or never), purchases (copies bought before it = copy - 1)}. Sets
	## the purchase counter from the price the player sees in the shop.
	var r := resolved(item_id)
	var out := {"copy": -1, "last": -1, "purchases": -1}
	if not r["method"] in COST_METHODS or current.is_empty():
		return out
	var first := -1
	var last := -1
	var p: Variant = r["price"]
	var st: Variant = r["step"]
	if r["schedule"] == null and p is Dictionary and st is Dictionary and not Currency.is_zero(st):
		# Arithmetic: price + step * floor((k-1)/N) == current in every currency.
		var every := maxi(1, int(r.get("step_every", 1)))
		var t := -1
		var keys: Array = (st as Dictionary).keys() + (current as Dictionary).keys() + (p as Dictionary).keys()
		for cur in keys:
			var s := int((st as Dictionary).get(cur, 0))
			var diff := int(current.get(cur, 0)) - int((p as Dictionary).get(cur, 0))
			if s == 0:
				if diff != 0:
					return out
				continue
			if diff < 0 or diff % s != 0:
				return out
			@warning_ignore("integer_division")
			var tt := diff / s
			if t >= 0 and tt != t:
				return out
			t = tt
		if t < 0:
			return out
		first = t * every + 1
		last = first + every - 1
	else:
		for k in range(1, limit + 1):
			var c: Variant = record_copy_price(r, k)
			if c == null:
				break
			if Currency.equal(c, current):
				if first < 0:
					first = k
				last = k
			elif first >= 0:
				break
			if r["schedule"] == null and not bool(r["progressive"]):
				if first >= 0:
					last = limit   # every copy costs the same: the counter cannot be told
				break
	if first < 0:
		return out
	return {"copy": first, "last": last, "purchases": first - 1}


# --- appearance parts (customization) -------------------------------------------------------

func components(kind: String) -> Dictionary:
	## part name -> component record for "house" / "truck" / "roadside_shop" ({} without client data).
	return (_components.get(kind, {}) as Dictionary)


func component(kind: String, part: String) -> Dictionary:
	return (components(kind).get(part, {}) as Dictionary)


func skin_cost(kind: String, parts: Dictionary) -> Dictionary:
	## Cost of the appearance parts `parts` (slot -> part name, as in a landmark
	## skin preset). Default parts come with the farm, so they cost nothing.
	## {cost (known part), unknown: [part names without a price or record],
	##  rows: [{slot, part, name, cost (Cost|null), default, disabled, event}],
	##  known: bool (data for this kind is installed)}.
	var comp := components(kind)
	var out := {"cost": {}, "unknown": [], "rows": [], "known": not comp.is_empty()}
	var slots := parts.keys()
	slots.sort()
	for slot in slots:
		var part := str(parts[slot])
		var c: Dictionary = comp.get(part, {})
		var row := {"slot": str(slot), "part": part, "name": str(c.get("name", part)), "cost": null,
			"default": bool(c.get("default", false)), "disabled": bool(c.get("disabled", false)),
			"event": bool(c.get("event", false))}
		if c.is_empty():
			(out["unknown"] as Array).append(part)
		elif bool(row["default"]):
			row["cost"] = {}
		elif c.get("price") is Dictionary:
			row["cost"] = c["price"]
			Currency.add_into(out["cost"], c["price"])
		else:
			(out["unknown"] as Array).append(part)
		(out["rows"] as Array).append(row)
	return out


static func normalize_component(v: Dictionary) -> Dictionary:
	## {name, slot, price (Cost|null), default, disabled, event, tid, unlock_level}.
	var price: Variant = Currency.normalize(v.get("price")) if v.get("price") != null else null
	return {"name": str(v.get("name", "")), "slot": str(v.get("slot", "")), "price": price,
		"default": bool(v.get("default", false)), "disabled": bool(v.get("disabled", false)),
		"event": bool(v.get("event", false)), "tid": str(v.get("tid", "")),
		"unlock_level": int(v.get("unlock_level")) if (v.get("unlock_level") is int or v.get("unlock_level") is float) else -1}


# --- client layer merge ---------------------------------------------------------------------

static func merge_client(base: Dictionary, c: Dictionary) -> Dictionary:
	## The client record `c` (normalized, with client_status) on top of the
	## researched / catalogue record `base`:
	## * priced: the client's base price, step and step_every replace the lower
	##   ones. A researched per-copy schedule is kept when the client gives no
	##   rise and agrees on copy 1 (it only knows the base price then).
	## * not_sold (CanBuy=FALSE or only the 999-diamond placeholder): unknown
	##   records become "not sold in the shop"; reward / event / not-in-shop records
	##   keep their route; a researched shop price is kept (it is usually an offer
	##   price) but marked unverified, with `client_conflict` saying why.
	## * no_price: provenance only.
	## Availability stays from research: CanBuy=TRUE in the client does not prove
	## that the live shop sells the item today.
	var rec := base.duplicate(true)
	var st := str(c.get("client_status", CLIENT_NO_PRICE))
	rec["client_status"] = st
	rec["client"] = c.get("client", {})
	if int(c.get("max_count", -1)) > 0:
		rec["max_count"] = int(c["max_count"])   # exp_levels.csv: the most copies any level allows
		if c.get("copy_levels") is Array:
			rec["copy_levels"] = c["copy_levels"]
	match st:
		CLIENT_PRICED:
			var lower: Variant = rec.get("schedule")
			var keep_schedule: bool = lower is Array and not (lower as Array).is_empty() and c.get("step") == null \
				and c.get("schedule") == null and Currency.equal((lower as Array)[0], c.get("price"))
			var was: Variant = record_copy_price(rec, 1) if rec.get("method") in COST_METHODS else null
			rec["method"] = str(c.get("method", METHOD_SHOP))
			rec["price"] = c.get("price")
			rec["step"] = c.get("step")
			rec["step_every"] = maxi(1, int(c.get("step_every", 1)))
			rec["step_basis"] = str(c.get("step_basis", ""))
			if c.get("step") != null:
				rec["step_confidence"] = str(c.get("step_confidence", "unverified"))
			if not keep_schedule:
				rec["schedule"] = c.get("schedule")
				rec["schedule_repeats_last"] = bool(c.get("schedule_repeats_last", false))
			if was != null and not Currency.equal(was, rec["price"]):
				rec["client_conflict"] = "research said %s" % Currency.format_line(was)
			rec["confidence"] = "game_data"
			rec["origin"] = ORIGIN_CLIENT
		CLIENT_NOT_SOLD:
			var m := str(rec.get("method", METHOD_UNKNOWN))
			if m in [METHOD_SHOP, METHOD_VOUCHERS, METHOD_FREE]:
				# Research has a price the client's shop table does not: usually a
				# server-side offer. Keep it (a known-cost subtotal stays useful) but
				# say so and stop calling it confirmed.
				rec["client_conflict"] = "your game files list no regular shop price for this item (%s); the researched price may be a limited offer" % [
					"marked not for sale" if (c.get("client", {}) as Dictionary).get("can_buy") == false else "999-diamond placeholder"]
				if str(rec.get("confidence", "")) in ["confirmed", "community"]:
					rec["confidence"] = "unverified"
				if str(rec.get("availability", "unknown")) == "current":
					rec["availability"] = "unknown"
			elif m == METHOD_UNKNOWN:
				rec["method"] = METHOD_NOT_IN_SHOP
				rec["confidence"] = "game_data"
				rec["origin"] = ORIGIN_CLIENT
	return rec


func method_text(item_id: String) -> String:
	## Friendly how-to-get text: "Shop", "Vouchers", "Can't be bought: derby reward".
	return record_method_text(resolved(item_id))


static func record_method_text(r: Dictionary) -> String:
	## method_text() for an already resolved record.
	var m: String = r["method"]
	if m in NOT_BUYABLE_METHODS:
		var why: PackedStringArray = []
		for rt in r["routes"]:
			why.append(str(ROUTE_NAMES.get(rt, rt)))
		if why.is_empty():
			why.append("reward / prize" if m == METHOD_REWARD else "not sold in the shop")
		return "Can't be bought: %s" % ", ".join(why)
	if m == METHOD_UNKNOWN:
		return "Price unknown"
	return str(METHOD_NAMES.get(m, m))


# --- parsing --------------------------------------------------------------------------------

static func empty_record() -> Dictionary:
	return {"method": METHOD_UNKNOWN, "price": null, "step": null, "step_every": 1, "step_basis": "", "schedule": null,
		"schedule_repeats_last": false, "max_count": -1, "availability": "unknown", "confidence": "unknown",
		"routes": [], "origin": ORIGIN_NONE, "sources": [], "notes": "", "info": ""}


static func normalize_record(v: Dictionary, origin: String, warn: Array = []) -> Dictionary:
	## A price-file / override record in canonical shape (see empty_record()).
	var r := empty_record()
	r["origin"] = origin
	var placeholder := bool(v.get("placeholder", false))
	if v.has("price") and v["price"] != null:
		r["price"] = Currency.normalize(v["price"])
		if r["price"] == null:
			warn.append("invalid price %s (kept unknown)" % str(v["price"]))
	if v.has("step") and v["step"] != null:
		r["step"] = Currency.normalize(v["step"])
		if r["step"] == null:
			warn.append("invalid step %s" % str(v["step"]))
	r["step_basis"] = str(v.get("step_basis", "")) if v.get("step_basis") != null else ""
	if v.get("schedule") is Array:
		var sch: Array = []
		for e in v["schedule"]:
			var c: Variant = Currency.normalize(e) if e != null else null
			if e != null and c == null:
				warn.append("invalid schedule entry %s (kept unknown)" % str(e))
			sch.append(c)
		r["schedule"] = sch if not sch.is_empty() else null
	r["schedule_repeats_last"] = bool(v.get("schedule_repeats_last", false))
	var se: Variant = v.get("step_every")
	r["step_every"] = maxi(1, int(se)) if (se is int or se is float) else 1
	if placeholder:
		r["price"] = null
		r["schedule"] = null
		r["step"] = null
	var mc: Variant = v.get("max_count")
	r["max_count"] = int(mc) if (mc is int or mc is float) and int(mc) > 0 else -1
	var m := str(v.get("method", "")) if v.get("method") != null else ""
	if m.is_empty():
		m = METHOD_SHOP if (r["price"] != null or r["schedule"] != null) else METHOD_UNKNOWN
	elif not m in METHODS:
		warn.append("unknown method '%s'" % m)
		m = METHOD_UNKNOWN
	r["method"] = m
	if m == METHOD_FREE:
		r["price"] = {}
		r["step"] = null
		r["schedule"] = null
	var av := str(v.get("availability", "unknown"))
	r["availability"] = av if av in AVAILABILITY else "unknown"
	var cf := str(v.get("confidence", "unknown"))
	r["confidence"] = cf if cf in CONFIDENCE else "unknown"
	for rt in (v.get("routes", []) if v.get("routes") is Array else []):
		(r["routes"] as Array).append(str(rt))
	for s in (v.get("sources", []) if v.get("sources") is Array else []):
		(r["sources"] as Array).append(str(s))
	r["notes"] = str(v.get("notes", "")) if v.get("notes") != null else ""
	r["info"] = str(v.get("info", "")) if v.get("info") != null else ""
	# Extra research fields (step_confidence, copy_levels, removal, repair, ...) are
	# kept (whole JSON numbers as ints). They are information only, never a cost.
	for k in v:
		var ks := str(k)
		if not r.has(ks) and ks != "placeholder":
			r[ks] = _ints(v[k])
	return r


static func _ints(v: Variant) -> Variant:
	## Deep copy with whole floats (JSON numbers) turned into ints.
	if v is float and is_equal_approx(v, roundf(v)):
		return int(v)
	if v is Array:
		var a: Array = []
		for e in v:
			a.append(_ints(e))
		return a
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _ints(v[k])
		return d
	return v


static func parse_catalogue(it: ItemDef) -> Dictionary:
	## Layer-1 record from an ItemDef's cost fields ({} when the catalogue has no
	## price information at all). The free text cost_other is parsed:
	##   "+N coins per additional purchase"      -> step
	##   "N green voucher + N purple voucher"    -> voucher price
	##   "N film (event currency)", "N golden keys" -> event currency
	##   "not sold in shop ..."                  -> not_in_shop (placeholder prices ignored)
	##   "no price in source (reward/prize item)" -> reward
	##   "free"                                  -> free
	##   "removal tool: X"                       -> info only (not a purchase price)
	## Anything else is kept verbatim in `notes`.
	var other := it.cost_other.strip_edges()
	if it.cost_coins < 0 and it.cost_diamonds < 0 and other.is_empty():
		return {}
	var r := empty_record()
	r["origin"] = ORIGIN_CATALOGUE
	r["max_count"] = it.max_count if it.max_count > 0 else -1
	r["sources"] = Array(it.sources)
	r["confidence"] = it.data_status if it.data_status in ["confirmed", "community"] else "unverified"
	var price := {}
	if it.cost_coins >= 0:
		price[Currency.COINS] = it.cost_coins
	if it.cost_diamonds >= 0:
		price[Currency.DIAMONDS] = it.cost_diamonds
	var has_price := it.cost_coins >= 0 or it.cost_diamonds >= 0
	var low := other.to_lower()
	var parsed := false
	if not other.is_empty():
		var step: Variant = _parse_step(low)
		if step != null:
			r["step"] = step
			r["step_basis"] = "purchases"
			if r["confidence"] == "confirmed":
				r["confidence"] = "community"   # the progression rule itself is community data
			parsed = true
		elif low == "free":
			r["method"] = METHOD_FREE
			r["price"] = {}
			return r
		elif low.begins_with("not sold in shop"):
			r["method"] = METHOD_NOT_IN_SHOP
			r["notes"] = other
			return r
		elif low.begins_with("no price in source"):
			r["method"] = METHOD_REWARD
			r["routes"] = ["reward"] if "reward" in low or "prize" in low else []
			r["notes"] = other
			return r
		elif low.begins_with("removal tool"):
			r["info"] = other
			parsed = true
		else:
			var vou: Variant = _parse_amounts(low, "voucher")
			if vou != null:
				r["method"] = METHOD_VOUCHERS
				r["price"] = vou
				return r
			var film := _parse_single(low, "film")
			if film >= 0:
				r["method"] = METHOD_EVENT
				r["price"] = {Currency.FILM: film}
				return r
			var keys := _parse_single(low, "golden key")
			if keys >= 0:
				r["method"] = METHOD_EVENT
				r["price"] = {Currency.GOLDEN_KEYS: keys}
				return r
		if not parsed:
			r["notes"] = other
	if has_price:
		r["method"] = METHOD_SHOP
		r["price"] = price
	return r


static func _parse_step(low: String) -> Variant:
	var re := RegEx.create_from_string("^\\+\\s*([0-9][0-9,]*)\\s+(coins?|diamonds?)\\s+per\\s+additional\\s+purchase")
	var m := re.search(low)
	if m == null:
		return null
	var n := m.get_string(1).replace(",", "").to_int()
	return {Currency.COINS if m.get_string(2).begins_with("coin") else Currency.DIAMONDS: n}


static func _parse_amounts(low: String, _word: String) -> Variant:
	## "5 green voucher + 1 purple voucher" -> {voucher_green: 5, voucher_purple: 1}; null if not that shape.
	var re := RegEx.create_from_string("^([0-9]+)\\s+(green|blue|purple|gold)\\s+vouchers?$")
	var out := {}
	for part in low.split("+"):
		var m := re.search(part.strip_edges())
		if m == null:
			return null
		var cur := "voucher_" + m.get_string(2)
		out[cur] = int(out.get(cur, 0)) + m.get_string(1).to_int()
	return out if not out.is_empty() else null


static func _parse_single(low: String, word: String) -> int:
	## "400 film (event currency)" / "490 golden keys" -> amount, -1 when not that shape.
	var re := RegEx.create_from_string("^([0-9][0-9,]*)\\s+%ss?\\b" % word)
	var m := re.search(low)
	return -1 if m == null else m.get_string(1).replace(",", "").to_int()


func _key(item_id: String) -> String:
	return _db.resolve_id(item_id) if _db != null else item_id


func _bump() -> void:
	_resolved.clear()
	version += 1
	changed.emit()
