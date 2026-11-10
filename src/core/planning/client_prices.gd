class_name ClientPrices
extends RefCounted
## Builds the private client-price supplement from the user's own Hay Day client
## data (docs/research/CLIENT_PRICES.md). Pure: no file writes except install().
##
## Input, either:
##   * a normalized reference file ("hayday-client-price-reference", one record
##     per source row group), or
##   * the client's data tables themselves (a folder with decorations.csv,
##     deco_fences.csv, ... and optionally exp_levels.csv for copy limits).
## Output: a "hayday-sandbox-client-prices" document (PriceBook layer 3) with
##   items (catalogue id -> price record + provenance), components (appearance
##   parts of the farmhouse, truck and roadside shop: never ordinary items),
##   review (records that were not applied, with candidates and the reason) and
##   stats; plus a report (build_report()).
##
## Matching a client record to a catalogue item, strongest first:
##   1. the user's own decision (mapping file: key -> item id, "" = ignore),
##   2. the asset export name, through the installed art pack's verified
##      sprite sources (export -> catalogue id),
##   3. a catalogue alias, 4. the translation id (TID_DECO_X -> x),
##   5. the exact (normalized) item name.
## Looser name similarities only produce review candidates, never a price: a
## wrong price is worse than a clearly unknown one. When two records claim one
## item with the same strength and different prices, neither is applied.

const REFERENCE_FORMAT := "hayday-client-price-reference"
const FORMAT := PriceBook.CLIENT_FORMAT
const REPORT_FORMAT := "hayday-sandbox-client-price-report"
const SCHEMA_VERSION := 1
const DATA_DIR := "user://private_data"
const MAPPING_PATH := "user://private_data/client_price_mapping.json"
const REPORT_PATH := "user://private_data/client_price_report.json"
const PREVIOUS_SUFFIX := ".prev.json"

## Tables with purchasable objects, and the appearance tables (-> component kind).
const ITEM_TABLES := ["decorations", "deco_fences", "deco_ditches", "processing_buildings", "animal_habitats",
	"fruit_trees", "gatherer_habitats", "fields", "modular_decorations"]
const COMPONENT_TABLES := {"customization_house": "house", "customization_truck": "truck",
	"customization_rss": "roadside_shop"}
## fields.csv lists crops; only this row is the field plot itself (its DiamondPrice
## columns are crop speed-ups, never a field price).
const FIELD_ROW := "EmptyField"
const SENTINEL_DIAMONDS := 999

const RULE_USER := "user_mapping"
const RULE_EXPORT := "asset_export"
const RULE_ALIAS := "alias"
const RULE_TID := "translation_id"
const RULE_NAME := "name"
const RULES := [RULE_USER, RULE_EXPORT, RULE_ALIAS, RULE_TID, RULE_NAME]
const RULE_CONFIDENCE := {RULE_USER: "user", RULE_EXPORT: "high", RULE_ALIAS: "high", RULE_TID: "medium",
	RULE_NAME: "medium"}

var errors: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()


# --- reading the client data ------------------------------------------------------------------

static func records_from_reference(d: Dictionary, errs: Array = []) -> Array:
	## Normalized records (see _record()) from a reference document; [] + error when invalid.
	if str(d.get("format", "")) != REFERENCE_FORMAT or not d.get("records") is Array:
		errs.append("not a client price reference (format '%s')" % REFERENCE_FORMAT)
		return []
	var out: Array = []
	for r in d["records"]:
		if not r is Dictionary:
			continue
		var pf: Dictionary = r.get("purchase_price_fields", {}) if r.get("purchase_price_fields") is Dictionary else {}
		var vouchers := {}
		for v in (r.get("voucher_requirements", []) if r.get("voucher_requirements") is Array else []):
			if v is Dictionary and int(v.get("amount", 0)) > 0:
				var cur := Currency.from_game_voucher(str(v.get("game_currency", "")))
				vouchers[cur] = int(vouchers.get(cur, 0)) + int(v["amount"])
		var price := {}
		for k in pf:
			var cur := str(k)
			if int(pf[k]) > 0:
				price[cur] = int(pf[k])
		var fp: Variant = null
		if r.get("tile_width") != null and r.get("tile_height") != null:
			fp = [int(r["tile_width"]), int(r["tile_height"])]
		var cb: Variant = r.get("can_buy_game_flag")
		var extra: Array = r.get("additional_price_rows_need_review", []) if r.get("additional_price_rows_need_review") is Array else []
		out.append(_record(str(r.get("table", "")), str(r.get("source_name", "")), str(r.get("translation_id", "")),
			str(r.get("asset_export", "")), price, vouchers, int(r.get("price_increase", 0)) if r.get("price_increase") != null else 0,
			int(r.get("increase_every_n_objects", 1)) if r.get("increase_every_n_objects") != null else 1,
			cb if cb is bool else null, bool(r.get("diamond_999_sentinel", false)),
			int(r.get("unlock_level", -1)) if r.get("unlock_level") != null else -1, fp, extra.size(), {}))
	return out


static func records_from_tables(dir: String, errs: Array = []) -> Array:
	## Normalized records straight from the client's CSV tables in `dir` (a folder
	## holding decorations.csv etc., or its assets/data). Missing tables are skipped
	## with a note in `errs`; exp_levels.csv (when present) adds copy limits.
	var base := dir
	if not FileAccess.file_exists(base.path_join("decorations.csv")) and FileAccess.file_exists(base.path_join("assets/data/decorations.csv")):
		base = base.path_join("assets/data")
	var limits := _level_limits(base.path_join("exp_levels.csv"))
	var out: Array = []
	var found := 0
	for t in ITEM_TABLES + COMPONENT_TABLES.keys():
		var path := base.path_join("%s.csv" % t)
		if not FileAccess.file_exists(path):
			errs.append("table not found: %s.csv" % t)
			continue
		found += 1
		for g in read_table(path):
			var rec := _record_from_rows(str(t), g, limits)
			if not rec.is_empty():
				out.append(rec)
	if found == 0:
		errs.append("no client price tables in %s" % dir)
	return out


static func read_table(path: String) -> Array:
	## A client CSV table as groups: [{"row": {column: value}, "more": [{...}, ...]}]
	## (row 2 holds the column types and is skipped; rows with an empty Name continue
	## the row group above them, e.g. a second voucher currency).
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var header := f.get_csv_line()
	if f.eof_reached():
		return []
	f.get_csv_line()   # types
	var groups: Array = []
	var key_col := header[0] if not header.is_empty() else "Name"
	while not f.eof_reached():
		var line := f.get_csv_line()
		if line.size() <= 1 and (line.is_empty() or line[0].strip_edges().is_empty()):
			continue
		var row := {}
		var any := false
		for i in mini(line.size(), header.size()):
			var v := line[i].strip_edges()
			if not v.is_empty():
				row[header[i]] = v
				any = true
		if not any:
			continue
		if str(row.get(key_col, "")).is_empty():
			if not groups.is_empty():
				(groups[groups.size() - 1]["more"] as Array).append(row)
			continue
		groups.append({"row": row, "more": []})
	return groups


static func _level_limits(path: String) -> Dictionary:
	## exp_levels.csv: column (MaxHammermills, MaxFields, ...) -> {max, levels: [level per extra copy]}.
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var by_level: Array = []
	for g in read_table(path):
		by_level.append(g["row"])
		for m in g["more"]:
			by_level.append(m)
	for row: Dictionary in by_level:
		var lvl := str(row.get("Level", "")).to_int()
		for col in row:
			var c := str(col)
			if not c.begins_with("Max") or not str(row[col]).is_valid_int():
				continue
			var n := str(row[col]).to_int()
			var e: Dictionary = out.get(c, {"max": 0, "levels": []})
			while (e["levels"] as Array).size() < n:
				(e["levels"] as Array).append(lvl)
			e["max"] = maxi(int(e["max"]), n)
			out[c] = e
	return out


static func _record_from_rows(table: String, g: Dictionary, limits: Dictionary) -> Dictionary:
	var row: Dictionary = g["row"]
	var more: Array = g["more"]
	var name := str(row.get("Name", ""))
	if table == "fields" and name != FIELD_ROW:
		return {}
	var price := {}
	var sentinel := false
	for field in Currency.GAME_FIELDS:
		var v := str(row.get(field, ""))
		if not v.is_valid_int() or v.to_int() <= 0:
			continue
		if field == "DiamondPrice" and v.to_int() == SENTINEL_DIAMONDS:
			sentinel = true
			continue
		price[Currency.GAME_FIELDS[field]] = v.to_int()
	var vouchers := {}
	var extra_prices := 0
	var all_rows: Array = [row] + more
	for i in all_rows.size():
		var r: Dictionary = all_rows[i]
		var vt := str(r.get("Vouchers", ""))
		var vc := str(r.get("VoucherCount", ""))
		if not vt.is_empty() and vc.is_valid_int() and vc.to_int() > 0:
			var cur := Currency.from_game_voucher(vt)
			vouchers[cur] = int(vouchers.get(cur, 0)) + vc.to_int()
		if i > 0 and str(r.get("Price", "")).is_valid_int():
			extra_prices += 1
	var cb_s := str(row.get("CanBuy", "")).to_upper()
	var cb: Variant = true if cb_s == "TRUE" else (false if cb_s == "FALSE" else null)
	var fp: Variant = null
	if str(row.get("TileWidth", "")).is_valid_int() and str(row.get("TileHeight", "")).is_valid_int():
		fp = [str(row["TileWidth"]).to_int(), str(row["TileHeight"]).to_int()]
	var extra := {}
	if COMPONENT_TABLES.has(table):
		extra = {"slot": str(row.get("Part", "")), "default": str(row.get("Default", "")).to_upper() == "TRUE",
			"disabled": str(row.get("Disabled", "")).to_upper() == "TRUE",
			"event": str(row.get("ExcludeFromNormalStock", "")).to_upper() == "TRUE"}
	var col := str(row.get("MaxHabitatsColumnName", ""))
	if table == "fields":
		col = "MaxFields"
	if not col.is_empty() and limits.has(col):
		extra["max_count"] = int(limits[col]["max"])
		extra["copy_levels"] = (limits[col]["levels"] as Array).duplicate()
		extra["limit_column"] = col
	return _record(table, name, str(row.get("TID", "")), str(row.get("ExportName", "")), price, vouchers,
		str(row.get("PriceIncrease", "0")).to_int(), maxi(1, str(row.get("DoPriceIncreaseEveryNObject", "1")).to_int()),
		cb, sentinel, str(row.get("UnlockLevel", "-1")).to_int() if str(row.get("UnlockLevel", "")).is_valid_int() else -1,
		fp, extra_prices, extra)


static func _record(table: String, name: String, tid: String, export: String, price: Dictionary, vouchers: Dictionary,
		increase: int, every: int, can_buy: Variant, sentinel: bool, unlock: int, fp: Variant, extra_rows: int,
		extra: Dictionary) -> Dictionary:
	var r := {"table": table, "name": name, "key": "%s:%s" % [table, name.to_lower()], "tid": tid, "export": export,
		"price": price, "vouchers": vouchers, "increase": maxi(0, increase), "every": maxi(1, every),
		"can_buy": can_buy, "sentinel_999": sentinel, "unlock_level": unlock, "footprint": fp,
		"extra_price_rows": extra_rows, "component": COMPONENT_TABLES.get(table, "")}
	r.merge(extra)
	return r


# --- matching --------------------------------------------------------------------------------

static func normalize_name(s: String) -> String:
	## "Water dragon steps" / "water-dragon_steps" -> "water_dragon_steps".
	var out := ""
	var sep := false
	for ch in s.to_lower():
		var ok := (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9")
		if ok:
			if sep and not out.is_empty():
				out += "_"
			out += ch
			sep = false
		else:
			sep = true
	return out


static func tid_name(tid: String) -> String:
	## TID_DECO_WATER_DRAGON_STEPS -> water_dragon_steps ("" for TID_NONE).
	var t := tid.to_upper()
	if not t.begins_with("TID_") or t == "TID_NONE":
		return ""
	t = t.substr(4)
	for pre in ["DECO_", "DECORATION_"]:
		if t.begins_with(pre):
			t = t.substr(pre.length())
	return normalize_name(t)


static func export_index_from_sprites(sprites: Dictionary, db: ItemDatabase = null, out: Dictionary = {}) -> Dictionary:
	## Art-pack sprite entries (keyed by art key) -> {export name: [catalogue ids]}
	## for entries whose art came from the game client with an exact or
	## user-verified match. Art keys map to the items that use them (`db`; without
	## one the key is taken as the item id). Exports already in `out` are kept
	## (call highest-priority pack first).
	var by_art := {}
	if db != null:
		for it: ItemDef in db.items.values():
			var a: Array = by_art.get(it.art_key, [])
			a.append(it.id)
			by_art[it.art_key] = a
	var seen := out.duplicate()
	for key in sprites:
		var s: Variant = sprites[key]
		if not s is Dictionary or not s.get("source") is Dictionary:
			continue
		var src: Dictionary = s["source"]
		var ex := str(src.get("export", ""))
		if ex.is_empty() or str(src.get("kind", "")) != "apk" or seen.has(ex):
			continue
		var m: Dictionary = s.get("match", {}) if s.get("match") is Dictionary else {}
		if not (bool(s.get("verified", false)) or str(m.get("confidence", "")) == "exact" or str(m.get("status", "")) == "confirmed"):
			continue
		var ids: Array = by_art.get(str(key), []) if db != null else [str(key)]
		var a: Array = out.get(ex, [])
		for id in ids:
			if not str(id) in a:
				a.append(str(id))
		if not a.is_empty():
			out[ex] = a
	return out


static func export_index_from_library(lib: AssetLibrary, db: ItemDatabase) -> Dictionary:
	## The same index over every installed pack, highest priority first (the
	## pack whose art the app shows decides an export).
	var out := {}
	if lib == null:
		return out
	for p in lib.pack_list():
		if p.get("sprites") is Dictionary:
			export_index_from_sprites(p["sprites"], db, out)
	return out


static func name_index(db: ItemDatabase) -> Dictionary:
	## {normalized name or id: [catalogue ids]}.
	var out := {}
	for it: ItemDef in db.items.values():
		for k in [normalize_name(it.id), normalize_name(it.name)]:
			if k.is_empty():
				continue
			var a: Array = out.get(k, [])
			if not it.id in a:
				a.append(it.id)
			out[k] = a
	return out


static func match_record(rec: Dictionary, db: ItemDatabase, exports: Dictionary, names: Dictionary,
		mapping: Dictionary) -> Dictionary:
	## {item ("" = none), rule, confidence, candidates: [ids], reason}.
	var key := str(rec["key"])
	if mapping.has(key):
		var to := str(mapping[key])
		if to.is_empty():
			return {"item": "", "rule": RULE_USER, "confidence": "user", "candidates": [], "reason": "ignored by you"}
		if db.get_item(to) != null:
			return {"item": db.resolve_id(to), "rule": RULE_USER, "confidence": "user", "candidates": [], "reason": ""}
	var nm := normalize_name(str(rec["name"]))
	var ex := str(rec["export"])
	if not ex.is_empty() and exports.has(ex):
		var ids: Array = exports[ex]
		if ids.size() == 1:
			return {"item": str(ids[0]), "rule": RULE_EXPORT, "confidence": "high", "candidates": [], "reason": ""}
		var by_name: Array = ids.filter(func(i): return i in names.get(nm, []))
		if by_name.size() == 1:
			return {"item": str(by_name[0]), "rule": RULE_EXPORT, "confidence": "high", "candidates": ids, "reason": ""}
		return {"item": "", "rule": "", "confidence": "", "candidates": ids,
			"reason": "the art export '%s' is used by several items" % ex}
	if db.aliases.has(nm):
		return {"item": str(db.aliases[nm]), "rule": RULE_ALIAS, "confidence": "high", "candidates": [], "reason": ""}
	var tn := tid_name(str(rec["tid"]))
	if not tn.is_empty():
		var t_ids: Array = names.get(tn, [])
		if t_ids.size() == 1:
			return {"item": str(t_ids[0]), "rule": RULE_TID, "confidence": "medium", "candidates": [], "reason": ""}
		if db.aliases.has(tn):
			return {"item": str(db.aliases[tn]), "rule": RULE_TID, "confidence": "medium", "candidates": [], "reason": ""}
	var n_ids: Array = names.get(nm, [])
	if n_ids.size() == 1:
		return {"item": str(n_ids[0]), "rule": RULE_NAME, "confidence": "medium", "candidates": [], "reason": ""}
	if n_ids.size() > 1:
		return {"item": "", "rule": "", "confidence": "", "candidates": n_ids, "reason": "the name fits several items"}
	return {"item": "", "rule": "", "confidence": "", "candidates": loose_candidates(nm, tn, names),
		"reason": "no reliable identifier matched"}


static func loose_candidates(nm: String, tn: String, names: Dictionary, limit: int = 5) -> Array:
	## Review suggestions only (never applied): names that equal after dropping a
	## trailing number / plural "s", or that contain each other.
	var out: Array = []
	var stems := {}
	for s in [nm, tn]:
		if s.is_empty():
			continue
		var x: String = s
		var re := RegEx.create_from_string("(_?[0-9]+)$")
		x = re.sub(x, "")
		stems[x] = true
		if x.ends_with("s"):
			stems[x.substr(0, x.length() - 1)] = true
		else:
			stems[x + "s"] = true
	for st in stems:
		for id in names.get(st, []):
			if not id in out:
				out.append(id)
	if out.size() < limit and nm.length() >= 6:
		for k in names:
			if out.size() >= limit:
				break
			var ks := str(k)
			if ks.length() >= 6 and (ks.begins_with(nm) or nm.begins_with(ks)):
				for id in names[k]:
					if not id in out and out.size() < limit:
						out.append(id)
	return out


# --- building the supplement --------------------------------------------------------------------

static func item_record(rec: Dictionary, m: Dictionary) -> Dictionary:
	## The PriceBook layer-3 record for one matched client record.
	var price: Dictionary = (rec["price"] as Dictionary).duplicate()
	Currency.add_into(price, rec["vouchers"])
	var status := PriceBook.CLIENT_NO_PRICE
	if rec["can_buy"] == false:
		status = PriceBook.CLIENT_NOT_SOLD
	elif not price.is_empty():
		status = PriceBook.CLIENT_PRICED
	elif bool(rec["sentinel_999"]):
		status = PriceBook.CLIENT_NOT_SOLD
	var out := {"client_status": status, "confidence": "game_data"}
	if status == PriceBook.CLIENT_PRICED:
		var only_vouchers := (rec["price"] as Dictionary).is_empty() and not (rec["vouchers"] as Dictionary).is_empty()
		out["method"] = PriceBook.METHOD_VOUCHERS if only_vouchers else PriceBook.METHOD_SHOP
		out["price"] = price
		if int(rec["increase"]) > 0:
			var cur := Currency.COINS
			var base_keys: Array = (rec["price"] as Dictionary).keys()
			if base_keys.size() == 1:
				cur = str(base_keys[0])
			out["step"] = {cur: int(rec["increase"])}
			out["step_every"] = int(rec["every"])
			out["step_basis"] = "purchases"
			out["step_confidence"] = "unverified"   # the client stores the rise, not the counter it uses
	if int(rec.get("max_count", 0)) > 0:
		out["max_count"] = int(rec["max_count"])
		out["copy_levels"] = rec.get("copy_levels", [])
	var prov := {"table": rec["table"], "name": rec["name"], "key": rec["key"], "tid": rec["tid"],
		"export": rec["export"], "can_buy": rec["can_buy"], "sentinel_999": rec["sentinel_999"],
		"unlock_level": rec["unlock_level"], "footprint": rec["footprint"], "rule": m.get("rule", ""),
		"match_confidence": m.get("confidence", "")}
	if not (rec["price"] as Dictionary).is_empty() and rec["can_buy"] == false:
		prov["listed_price"] = (rec["price"] as Dictionary).duplicate()
	if int(rec.get("extra_price_rows", 0)) > 0:
		prov["note"] = "%d further Price rows are not copy prices (per-level values such as production slots); ignored" % int(rec["extra_price_rows"])
	if rec.has("limit_column"):
		prov["limit_column"] = rec["limit_column"]
	out["client"] = prov
	return out


func build(records: Array, db: ItemDatabase, exports: Dictionary, mapping: Dictionary, game_version: String,
		source: Dictionary) -> Dictionary:
	## The supplement document (see class doc). `source`: {kind, file, ...} for provenance.
	var names := name_index(db)
	var claims := {}          # item -> [{rec, m}]
	var review: Array = []
	var components := {}
	var stats := {"records": records.size(), "item_records": 0, "component_records": 0, "by_rule": {},
		"ambiguous": 0, "unmatched": 0, "ignored": 0, "conflicting_claims": 0}
	for rec: Dictionary in records:
		var kind := str(rec.get("component", ""))
		if not kind.is_empty():
			stats["component_records"] += 1
			var parts: Dictionary = components.get(kind, {})
			var price: Dictionary = (rec["price"] as Dictionary).duplicate()
			Currency.add_into(price, rec["vouchers"])
			parts[str(rec["name"])] = {"name": rec["name"], "slot": rec.get("slot", ""),
				"price": price if not price.is_empty() else null, "default": rec.get("default", false),
				"disabled": rec.get("disabled", false), "event": rec.get("event", false), "tid": rec["tid"]}
			components[kind] = parts
			continue
		stats["item_records"] += 1
		var m := match_record(rec, db, exports, names, mapping)
		if str(m["item"]).is_empty():
			if str(m["rule"]) == RULE_USER:
				stats["ignored"] += 1
				continue
			var amb := not (m["candidates"] as Array).is_empty() and str(m["reason"]) != "no reliable identifier matched"
			stats["ambiguous" if amb else "unmatched"] += 1
			review.append(_review_row(rec, m["candidates"], str(m["reason"]), "ambiguous" if amb else "unmatched"))
			continue
		var a: Array = claims.get(m["item"], [])
		a.append({"rec": rec, "m": m})
		claims[m["item"]] = a
	var items := {}
	var ids := claims.keys()
	ids.sort()
	for id in ids:
		var a: Array = claims[id]
		a.sort_custom(func(x, y): return RULES.find(x["m"]["rule"]) < RULES.find(y["m"]["rule"]))
		var best: Dictionary = a[0]
		var tied: Array = a.filter(func(x): return x["m"]["rule"] == best["m"]["rule"])
		var chosen := best
		if tied.size() > 1:
			var first := item_record(best["rec"], best["m"])
			var same := tied.all(func(x): return _same_price(item_record(x["rec"], x["m"]), first))
			# A shop variant and its gift / prize twin (SnailShop + Snail) share the
			# art: when exactly one of them has a price, that is the shop price.
			var priced: Array = tied.filter(func(x): return str(item_record(x["rec"], x["m"])["client_status"]) == PriceBook.CLIENT_PRICED)
			if not same and priced.size() == 1:
				chosen = priced[0]
				same = true
			if not same:
				stats["conflicting_claims"] += 1
				for x in tied:
					review.append(_review_row(x["rec"], [id], "several client records claim this item with different prices", "conflict"))
				continue
		var r := item_record(chosen["rec"], chosen["m"])
		if a.size() > 1:
			var others: Array = []
			for x in a:
				if x != chosen:
					others.append(str(x["rec"]["key"]))
			(r["client"] as Dictionary)["also_matched"] = others
		items[id] = r
		var rule := str(chosen["m"]["rule"])
		stats["by_rule"][rule] = int(stats["by_rule"].get(rule, 0)) + 1
	return {"format": FORMAT, "schema_version": SCHEMA_VERSION, "game_version": game_version,
		"generated": Time.get_datetime_string_from_system(true) + "Z", "PRIVATE": "Derived from the user's own game files. Never commit or share.",
		"source": source, "items": items, "components": components, "review": review, "stats": stats}


static func _same_price(a: Dictionary, b: Dictionary) -> bool:
	return str(a.get("client_status")) == str(b.get("client_status")) and Currency.equal(a.get("price"), b.get("price")) \
		and Currency.equal(a.get("step"), b.get("step")) and int(a.get("step_every", 1)) == int(b.get("step_every", 1))


static func _review_row(rec: Dictionary, candidates: Array, reason: String, kind: String) -> Dictionary:
	var price: Dictionary = (rec["price"] as Dictionary).duplicate()
	Currency.add_into(price, rec["vouchers"])
	return {"key": rec["key"], "table": rec["table"], "name": rec["name"], "tid": rec["tid"], "export": rec["export"],
		"price": price, "can_buy": rec["can_buy"], "kind": kind, "reason": reason, "candidates": candidates.duplicate()}


# --- report -------------------------------------------------------------------------------------

static func build_report(doc: Dictionary, public_book: PriceBook, db: ItemDatabase, previous: Dictionary = {}) -> Dictionary:
	## Coverage before (public layers + overrides, no client data) and after (with
	## this supplement). `public_book` itself is not changed.
	var after := public_book.derived(doc)
	public_book = public_book.derived(null)
	var c := {"catalogue_items": db.items.size(), "known_before": 0, "known_after": 0, "newly_priced": 0,
		"price_confirmed": 0, "price_changed": 0, "now_not_sold": 0, "still_unknown": 0, "not_buyable_after": 0,
		"override_shadows_client": 0}
	var newly: Array = []
	var changed: Array = []
	var not_sold: Array = []
	var unknown: Array = []
	var shadowed: Array = []
	var ids := db.items.keys()
	ids.sort()
	for id in ids:
		var b := public_book.has_known_price(id)
		var a := after.has_known_price(id)
		if b:
			c["known_before"] += 1
		if a:
			c["known_after"] += 1
		if after.is_not_buyable(id):
			c["not_buyable_after"] += 1
		elif not a:
			c["still_unknown"] += 1
			unknown.append(id)
		if not (doc["items"] as Dictionary).has(id):
			continue
		var r := after.resolved(id)
		if public_book.has_override(id) and str(doc["items"][id].get("client_status")) == PriceBook.CLIENT_PRICED:
			c["override_shadows_client"] += 1
			shadowed.append(id)
		if a and not b:
			c["newly_priced"] += 1
			newly.append(id)
		elif a and b:
			if Currency.equal(public_book.copy_price(id, 1), after.copy_price(id, 1)):
				c["price_confirmed"] += 1
			else:
				c["price_changed"] += 1
				changed.append({"item": id, "before": public_book.copy_price(id, 1), "after": after.copy_price(id, 1)})
		if str(r.get("client_status")) == PriceBook.CLIENT_NOT_SOLD and r.has("client_conflict"):
			c["now_not_sold"] += 1   # research price kept, flagged (see PriceBook.merge_client)
			not_sold.append({"item": id, "was": public_book.copy_price(id, 1)})
	var st: Dictionary = doc.get("stats", {})
	var cur := {}
	for id in doc["items"]:
		for k in ((doc["items"][id] as Dictionary).get("price", {}) as Dictionary):
			cur[k] = int(cur.get(k, 0)) + 1
	var prev_info := {}
	if not previous.is_empty():
		var diff := 0
		for id in doc["items"]:
			var p: Variant = (previous.get("items", {}) as Dictionary).get(id)
			if p == null or not _same_price(p, doc["items"][id]):
				diff += 1
		prev_info = {"game_version": str(previous.get("game_version", "")), "generated": str(previous.get("generated", "")),
			"items": (previous.get("items", {}) as Dictionary).size(), "items_differing": diff}
	return {"format": REPORT_FORMAT, "schema_version": SCHEMA_VERSION, "game_version": doc.get("game_version", ""),
		"generated": doc.get("generated", ""), "source": doc.get("source", {}), "stats": st, "coverage": c,
		"currency_records": cur, "components": _component_counts(doc), "previous": prev_info,
		"newly_priced": newly, "price_changed": changed, "now_not_sold": not_sold, "still_unknown": unknown,
		"override_shadows_client": shadowed, "review": doc.get("review", [])}


static func _component_counts(doc: Dictionary) -> Dictionary:
	var out := {}
	for k in (doc.get("components", {}) as Dictionary):
		var parts: Dictionary = doc["components"][k]
		var priced := 0
		for p in parts:
			if parts[p].get("price") != null:
				priced += 1
		out[k] = {"parts": parts.size(), "priced": priced}
	return out


static func report_markdown(rep: Dictionary) -> String:
	var c: Dictionary = rep["coverage"]
	var st: Dictionary = rep["stats"]
	var L: PackedStringArray = []
	L.append("# Client price import report (game version %s)" % str(rep.get("game_version", "?")))
	L.append("")
	L.append("PRIVATE: derived from your own game files. Do not commit or share.")
	L.append("")
	L.append("| | Count |")
	L.append("|---|---|")
	for row in [["Catalogue items", c["catalogue_items"]], ["Client records read", st.get("records", 0)],
			["  of which object records", st.get("item_records", 0)], ["  of which appearance parts (not items)", st.get("component_records", 0)],
			["Matched by your own mapping", st.get("by_rule", {}).get(RULE_USER, 0)],
			["Matched by art export name (exact)", st.get("by_rule", {}).get(RULE_EXPORT, 0)],
			["Matched by alias", st.get("by_rule", {}).get(RULE_ALIAS, 0)],
			["Matched by translation id", st.get("by_rule", {}).get(RULE_TID, 0)],
			["Matched by exact name", st.get("by_rule", {}).get(RULE_NAME, 0)],
			["Ambiguous (review)", st.get("ambiguous", 0)], ["Unmatched (review)", st.get("unmatched", 0)],
			["Conflicting claims (review)", st.get("conflicting_claims", 0)], ["Ignored by you", st.get("ignored", 0)],
			["Items with a known price before", c["known_before"]], ["Items with a known price after", c["known_after"]],
			["Newly priced", c["newly_priced"]], ["Price confirmed", c["price_confirmed"]],
			["Price changed (client differs from research)", c["price_changed"]],
			["Researched price kept although the client lists none (offer?)", c["now_not_sold"]], ["Can't be bought (after)", c["not_buyable_after"]],
			["Still without a price", c["still_unknown"]], ["Your overrides hiding a client price", c["override_shadows_client"]]]:
		L.append("| %s | %s |" % [row[0], str(row[1])])
	L.append("")
	if not (rep.get("previous", {}) as Dictionary).is_empty():
		var p: Dictionary = rep["previous"]
		L.append("Replaces the supplement for game version %s (%d items); %d items differ." % [p["game_version"], p["items"], p["items_differing"]])
		L.append("")
	L.append("## Price changes (client vs research)")
	for ch in rep["price_changed"]:
		L.append("- %s: %s -> %s" % [ch["item"], Currency.format_line(ch["before"]), Currency.format_line(ch["after"])])
	L.append("")
	L.append("## Researched prices the client does not list (kept, marked unverified)")
	for ns in rep["now_not_sold"]:
		L.append("- %s: %s" % [ns["item"], Currency.format_line(ns["was"])])
	L.append("")
	L.append("## Review queue (%d)" % (rep["review"] as Array).size())
	for r in rep["review"]:
		L.append("- [%s] %s (%s): %s; candidates: %s" % [r["kind"], r["name"], r["table"], r["reason"], ", ".join(PackedStringArray(r["candidates"]))])
	return "\n".join(L) + "\n"


# --- one-call import (app and tool) ---------------------------------------------------------------

static func import_from(path: String, db: ItemDatabase, exports: Dictionary, public_book: PriceBook,
		game_version: String = "", mapping: Variant = null, installed: String = PriceBook.DEFAULT_CLIENT) -> Dictionary:
	## Reads `path` (a folder with the client tables, or a reference .json), builds
	## the supplement and its report against the installed one. Nothing is written.
	## {ok, error, notes, doc, report}. The game version comes from the reference,
	## else `game_version`, else the active art pack's client build (caller).
	var notes: Array = []
	var records: Array = []
	var source := {}
	var gv := game_version
	if DirAccess.dir_exists_absolute(path):
		records = records_from_tables(path, notes)
		source = {"kind": "tables", "path": path, "records": records.size()}
	else:
		var ref: Variant = JsonUtil.read_json(path)
		if not ref is Dictionary:
			return {"ok": false, "error": "cannot read %s" % path.get_file(), "notes": notes, "doc": {}, "report": {}}
		if str(ref.get("format", "")) == FORMAT:
			return {"ok": false, "error": "this is an already built supplement, not client data", "notes": notes, "doc": {}, "report": {}}
		records = records_from_reference(ref, notes)
		if not str(ref.get("game_version", "")).is_empty():
			gv = str(ref["game_version"])
		source = {"kind": "reference", "path": path, "records": records.size()}
	if records.is_empty():
		return {"ok": false, "error": "no client price records found (%s)" % "; ".join(PackedStringArray(notes)),
			"notes": notes, "doc": {}, "report": {}}
	if gv.is_empty():
		return {"ok": false, "error": "the game version is unknown", "notes": notes, "doc": {}, "report": {}}
	var m: Dictionary = mapping if mapping is Dictionary else load_mapping()
	var doc := ClientPrices.new().build(records, db, exports, m, gv, source)
	var prev: Variant = JsonUtil.read_json(installed) if FileAccess.file_exists(installed) else null
	var rep := build_report(doc, public_book, db, prev if prev is Dictionary else {})
	return {"ok": true, "error": "", "notes": notes, "doc": doc, "report": rep}


# --- files ---------------------------------------------------------------------------------------

static func load_mapping(path: String = MAPPING_PATH) -> Dictionary:
	var d: Variant = JsonUtil.read_json(path)
	if d is Dictionary and d.get("mapping") is Dictionary:
		return d["mapping"]
	return {}


static func save_mapping(mapping: Dictionary, path: String = MAPPING_PATH) -> Error:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var keys := mapping.keys()
	keys.sort()
	var m := {}
	for k in keys:
		m[k] = mapping[k]
	var old: Variant = JsonUtil.read_json(path)
	var doc := {"format": "hayday-sandbox-client-price-mapping", "schema_version": 1,
		"PRIVATE": "Your matching decisions for client price records.", "mapping": m}
	if old is Dictionary and old.get("last_source") is String:
		doc["last_source"] = old["last_source"]
	return JsonUtil.write_atomic(path, JsonUtil.stringify(doc), false)


static func last_source(path: String = MAPPING_PATH) -> String:
	## The folder / file of the last import from the app ("" = none).
	var d: Variant = JsonUtil.read_json(path)
	return str(d.get("last_source", "")) if d is Dictionary else ""


static func set_last_source(src: String, path: String = MAPPING_PATH) -> void:
	var d: Variant = JsonUtil.read_json(path)
	var doc: Dictionary = d if d is Dictionary else {"format": "hayday-sandbox-client-price-mapping", "schema_version": 1,
		"PRIVATE": "Your matching decisions for client price records.", "mapping": {}}
	doc["last_source"] = src
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	JsonUtil.write_atomic(path, JsonUtil.stringify(doc), false)


static func validate(doc: Dictionary) -> PackedStringArray:
	## Problems that make a supplement unusable ([] = fine).
	var out := PackedStringArray()
	if str(doc.get("format", "")) != FORMAT:
		out.append("not a client price supplement (format '%s')" % FORMAT)
		return out
	if int(doc.get("schema_version", 0)) > SCHEMA_VERSION:
		out.append("made by a newer app (schema %s)" % str(doc.get("schema_version")))
	if not doc.get("items") is Dictionary:
		out.append("'items' is missing")
	elif (doc["items"] as Dictionary).is_empty() and (doc.get("components", {}) as Dictionary).is_empty():
		out.append("contains no prices")
	if str(doc.get("game_version", "")).is_empty():
		out.append("the game version is not stated")
	return out


static func install(doc: Dictionary, report: Dictionary, path: String = PriceBook.DEFAULT_CLIENT) -> Dictionary:
	## Writes the supplement (keeping the previous one for rollback) and its report.
	## {ok, error, previous (path or "")}.
	var probs := validate(doc)
	if not probs.is_empty():
		return {"ok": false, "error": "; ".join(probs), "previous": ""}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var prev := ""
	if FileAccess.file_exists(path):
		prev = path.get_basename() + PREVIOUS_SUFFIX
		var txt := FileAccess.get_file_as_string(path)
		if JsonUtil.write_atomic(prev, txt, false) != OK:
			return {"ok": false, "error": "could not keep the previous supplement", "previous": ""}
	var err := JsonUtil.write_atomic(path, JsonUtil.stringify(doc), false)
	if err != OK:
		return {"ok": false, "error": "could not write %s (%s)" % [path, error_string(err)], "previous": prev}
	var rp := path.get_base_dir().path_join(REPORT_PATH.get_file())
	JsonUtil.write_atomic(rp, JsonUtil.stringify(report), false)
	JsonUtil.write_atomic(rp.get_basename() + ".md", report_markdown(report), false)
	return {"ok": true, "error": "", "previous": prev}


static func rollback(path: String = PriceBook.DEFAULT_CLIENT) -> Dictionary:
	## Restores the previous supplement (swaps it with the current one). {ok, error}.
	var prev := path.get_basename() + PREVIOUS_SUFFIX
	if not FileAccess.file_exists(prev):
		return {"ok": false, "error": "there is no previous supplement"}
	var old := FileAccess.get_file_as_string(prev)
	var cur := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	if JsonUtil.write_atomic(path, old, false) != OK:
		return {"ok": false, "error": "could not restore"}
	if cur.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(prev))
	else:
		JsonUtil.write_atomic(prev, cur, false)
	return {"ok": true, "error": ""}


static func remove(path: String = PriceBook.DEFAULT_CLIENT) -> bool:
	## Uninstalls the supplement (kept as the "previous" one, so it can be restored).
	if not FileAccess.file_exists(path):
		return false
	var txt := FileAccess.get_file_as_string(path)
	JsonUtil.write_atomic(path.get_basename() + PREVIOUS_SUFFIX, txt, false)
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
