class_name Currency
extends RefCounted
## Currency ids, display names, sort order and formatting (docs/PLANNING.md §1).
##
## A "Cost" is a Dictionary currency_id -> int (amounts >= 0). An empty Cost is
## a known zero ("free"); an UNKNOWN cost is `null`, never {} and never 0.
## Currencies are never converted into each other: every helper keeps them apart.

const COINS := "coins"
const DIAMONDS := "diamonds"
const VOUCHER_GREEN := "voucher_green"
const VOUCHER_BLUE := "voucher_blue"
const VOUCHER_PURPLE := "voucher_purple"
const VOUCHER_GOLD := "voucher_gold"
const FILM := "film"
const GOLDEN_KEYS := "golden_keys"
const PEARLS := "pearls"
const LAND_DEED := "land_deed"
const MALLET := "mallet"
const MARKER_STAKE := "marker_stake"
const EXPANSION_PERMIT := "expansion_permit"

## Display order; ids not listed sort after these, alphabetically.
const ORDER := [COINS, DIAMONDS, VOUCHER_GREEN, VOUCHER_BLUE, VOUCHER_PURPLE, VOUCHER_GOLD, PEARLS, FILM, GOLDEN_KEYS,
	LAND_DEED, MALLET, MARKER_STAKE, EXPANSION_PERMIT]
const NAMES := {
	COINS: "Coins", DIAMONDS: "Diamonds",
	VOUCHER_GREEN: "Green vouchers", VOUCHER_BLUE: "Blue vouchers", VOUCHER_PURPLE: "Purple vouchers",
	VOUCHER_GOLD: "Gold vouchers", PEARLS: "Pearls", FILM: "Film", GOLDEN_KEYS: "Golden keys",
	LAND_DEED: "Land deeds", MALLET: "Mallets", MARKER_STAKE: "Marker stakes", EXPANSION_PERMIT: "Expansion permits",
}
## Singular names ("1 land deed").
const SINGULAR := {
	COINS: "coin", DIAMONDS: "diamond",
	VOUCHER_GREEN: "green voucher", VOUCHER_BLUE: "blue voucher", VOUCHER_PURPLE: "purple voucher",
	VOUCHER_GOLD: "gold voucher", PEARLS: "pearl", FILM: "film", GOLDEN_KEYS: "golden key",
	LAND_DEED: "land deed", MALLET: "mallet", MARKER_STAKE: "marker stake", EXPANSION_PERMIT: "expansion permit",
}
const VOUCHERS := [VOUCHER_GREEN, VOUCHER_BLUE, VOUCHER_PURPLE, VOUCHER_GOLD]
const EXPANSION_SUPPLIES := [LAND_DEED, MALLET, MARKER_STAKE, EXPANSION_PERMIT]
const EVENT_CURRENCIES := [FILM, GOLDEN_KEYS]

## The client's numbered vouchers (vouchers.csv VoucherType 1..4 = common, uncommon,
## rare, epic) and the voucher colours players and the wiki use. Established by
## comparison, not assumed: over the items both sources price in vouchers, the
## amounts agree as Voucher1 = green (43 items), Voucher2 = blue (23), Voucher3 =
## purple (38), Voucher4 = gold (15); the few cross-pairs are amount coincidences
## (<= 2 each). Voucher5 ("black", a Farm Pass reward) has no colour name and no
## item uses it in 1.73.89, so it keeps its own id. See docs/research/CLIENT_PRICES.md.
const GAME_VOUCHERS := {"Voucher1": VOUCHER_GREEN, "Voucher2": VOUCHER_BLUE, "Voucher3": VOUCHER_PURPLE,
	"Voucher4": VOUCHER_GOLD}
## The client's own currency field names (decorations.csv etc.) -> currency ids.
const GAME_FIELDS := {"Price": COINS, "DiamondPrice": DIAMONDS, "PearlPrice": PEARLS}


static func from_game_voucher(game_id: String) -> String:
	## "Voucher3" -> "voucher_purple"; unmapped ones keep a stable id ("voucher5").
	return str(GAME_VOUCHERS.get(game_id, game_id.to_lower()))


# --- ids and names ------------------------------------------------------------------------

static func is_known(id: String) -> bool:
	return NAMES.has(id)


static func name_of(id: String) -> String:
	## "Green vouchers"; unknown ids are shown by id (never dropped).
	return str(NAMES.get(id, id))


static func unit_name(id: String, amount: int) -> String:
	## "1 land deed" / "3 land deeds" wording for an amount (unknown ids: the id).
	if not SINGULAR.has(id):
		return id
	if amount == 1:
		return str(SINGULAR[id])
	return str(NAMES[id]).to_lower()


static func is_supply(id: String) -> bool:
	return id in EXPANSION_SUPPLIES


static func is_voucher(id: String) -> bool:
	return id in VOUCHERS


static func sort_index(id: String) -> int:
	var i := ORDER.find(id)
	return i if i >= 0 else ORDER.size()


static func sorted_ids(ids: Array) -> Array:
	## Currency ids in display order (known ones first, then the rest by id).
	var out: Array = []
	for k in ids:
		out.append(str(k))
	out.sort_custom(func(a: String, b: String) -> bool: return Currency._less(a, b))
	return out


static func _less(a: String, b: String) -> bool:
	var ia := sort_index(a)
	var ib := sort_index(b)
	if ia != ib:
		return ia < ib
	return a < b


# --- numbers -------------------------------------------------------------------------------

static func format_amount(n: int) -> String:
	## Thousands separators: 142500 -> "142,500".
	var neg := n < 0
	var s := str(absi(n))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if neg else out


# --- Cost helpers (Dictionary currency -> int) ------------------------------------------------

static func normalize(v: Variant) -> Variant:
	## A clean Cost from loose data ({"coins": 349.0} -> {"coins": 349}); zero
	## amounts are dropped. Returns null when `v` is not a valid cost (not a
	## dictionary, a negative or non-numeric amount): such data is unknown, not 0.
	if not v is Dictionary:
		return null
	var out := {}
	for k in v:
		var a: Variant = v[k]
		if a is float and is_equal_approx(a, roundf(a)):
			a = int(a)
		if not a is int:
			if a is String and (a as String).is_valid_int():
				a = (a as String).to_int()
			else:
				return null
		if int(a) < 0:
			return null
		if int(a) > 0:
			out[str(k)] = int(a)
	return out


static func add(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate()
	add_into(out, b)
	return out


static func add_into(acc: Dictionary, b: Dictionary, times: int = 1) -> void:
	## acc += b × times (in place).
	if times == 0:
		return
	for k in b:
		acc[k] = int(acc.get(k, 0)) + int(b[k]) * times


static func scale(c: Dictionary, k: int) -> Dictionary:
	var out := {}
	if k == 0:
		return out
	for key in c:
		out[key] = int(c[key]) * k
	return out


static func subtract(a: Dictionary, b: Dictionary) -> Dictionary:
	## a - b per currency (may go negative; zeros dropped).
	var out := a.duplicate()
	for k in b:
		out[k] = int(out.get(k, 0)) - int(b[k])
	for k in out.keys():
		if int(out[k]) == 0:
			out.erase(k)
	return out


static func is_zero(c: Variant) -> bool:
	## True for a known zero cost ({} or all amounts 0). null (unknown) is NOT zero.
	if not c is Dictionary:
		return false
	for k in c:
		if int(c[k]) != 0:
			return false
	return true


static func equal(a: Variant, b: Variant) -> bool:
	## Same amounts in every currency (missing == 0). null only equals null.
	if a == null or b == null:
		return a == null and b == null
	for k in a:
		if int(a[k]) != int(b.get(k, 0)):
			return false
	for k in b:
		if int(b[k]) != int(a.get(k, 0)):
			return false
	return true


static func covers(balances: Dictionary, cost: Dictionary) -> bool:
	## True when `balances` hold at least `cost` in EVERY currency (no conversion).
	for k in cost:
		if int(cost[k]) > int(balances.get(k, 0)):
			return false
	return true


static func shortfall(balances: Dictionary, cost: Dictionary) -> Dictionary:
	## What is still missing per currency to pay `cost` ({} when covered).
	var out := {}
	for k in cost:
		var miss := int(cost[k]) - int(balances.get(k, 0))
		if miss > 0:
			out[k] = miss
	return out


static func currencies_of(c: Variant) -> Array:
	return sorted_ids((c as Dictionary).keys()) if c is Dictionary else []


static func format_line(c: Variant, empty_text: String = "Free", unknown_text: String = "Price unknown") -> String:
	## "142,500 coins · 12 diamonds · 5 green vouchers" in display order.
	## null -> `unknown_text`; {} -> `empty_text`.
	if c == null or not c is Dictionary:
		return unknown_text
	var parts: PackedStringArray = []
	for k in sorted_ids((c as Dictionary).keys()):
		var a := int(c[k])
		if a == 0:
			continue
		parts.append("%s %s" % [format_amount(a), unit_name(k, a)])
	return empty_text if parts.is_empty() else " · ".join(parts)


static func format_range(lo: Variant, hi: Variant) -> String:
	## "349–499 coins" for two costs in the same single currency, else "a – b".
	if lo == null or hi == null:
		return format_line(lo if hi == null else hi)
	if equal(lo, hi):
		return format_line(lo)
	var lk: Array = (lo as Dictionary).keys()
	var hk: Array = (hi as Dictionary).keys()
	if lk.size() == 1 and hk.size() == 1 and lk[0] == hk[0]:
		var k := str(lk[0])
		return "%s–%s %s" % [format_amount(int(lo[k])), format_amount(int(hi[k])), unit_name(k, int(hi[k]))]
	return "%s – %s" % [format_line(lo), format_line(hi)]
