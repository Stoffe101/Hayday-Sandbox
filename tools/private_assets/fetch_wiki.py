#!/usr/bin/env python3
"""Fetch original-resolution object images from the Hay Day Wiki (Fandom) into PRIVATE storage.

Only the public MediaWiki API (``https://hayday.fandom.com[/ru]/api.php``) and the wiki's static image CDN
(``static.wikia.nocookie.net``) are used. Every file URL gets ``format=original`` so the CDN returns the uploaded
file byte-for-byte instead of an on-the-fly WebP re-encode; the bytes are checked against the API's SHA-1.

Discovery routes (recorded per file in ``matched_by``):

  category        files in the image categories reached from Category:Images, Category:Image Decos,
                  Category:Decorations (recursive ``cmtype=subcat`` walk up to ``--max-depth``) plus any other
                  file-holding category whose name looks object-related (``list=allcategories``). Files from
                  clearly non-object categories (UI, badges, products, NPCs, ...) are discovered but skipped.
  catalog_lookup  ``File:<catalog item name>.png`` for every item in data/items/*.json (several capitalisation
                  variants; on the ru wiki also the ru page titles the catalog cites), batches of 50 titles.
  catalog_page    images shown on the wiki pages the catalog cites (lead image via ``prop=pageimages`` plus
                  ``prop=images``); a page image is kept only if it is the page's lead image or sits in an
                  object category.

Skips (recorded with a reason in ``index.json`` -> ``skipped``): non-raster media, logos, icons < 48 px,
non-object categories, GIFs outside object categories, JPEG screenshots > 1600 px wide, opaque images > 1600 px
wide (checked after download, file deleted), ru files byte-identical to an en file already fetched.

LEGAL: the output is proprietary Supercell art. The user reports that Supercell support allowed them to use it
privately in this app on condition it is never redistributed. Output therefore goes to a PRIVATE directory
outside the repository (default /root/hayday-sandbox-private-assets, env HAYDAY_PRIVATE_ASSETS) and must never be
committed or shared; the tool refuses to write inside any git work tree. It never logs in, never solves or
bypasses bot challenges (it stops using a host that answers with one) and never contacts game servers.

Politeness: <= 3 concurrent downloads, global request spacing, exponential backoff honouring Retry-After,
resume of verified files and of partial downloads (HTTP Range) with ``--resume``.

Usage:
  python3 tools/private_assets/fetch_wiki.py --discover-only          # discovery + index, no downloads
  python3 tools/private_assets/fetch_wiki.py --resume                 # en wiki, all routes
  python3 tools/private_assets/fetch_wiki.py --wiki ru --resume       # ru wiki, catalog-driven routes only
Outputs (en: <out>/raw/wiki/, ru: <out>/raw/wiki_ru/):
  files/<slug>.<ext>   index.json   failed.json   fetch.log
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import glob
import hashlib
import io
import json
import os
import random
import re
import sys
import threading
import time
import unicodedata
import urllib.parse
from pathlib import Path

try:
	import requests
except ImportError:  # pragma: no cover
	sys.exit("requests is required: pip install requests")
try:
	from PIL import Image
	import numpy as np
except ImportError:  # pragma: no cover
	sys.exit("Pillow and numpy are required: pip install pillow numpy")

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = Path(os.environ.get("HAYDAY_PRIVATE_ASSETS", "/root/hayday-sandbox-private-assets"))
SOURCE = "Hay Day Wiki (Fandom) — CC BY-SA text; images are Supercell game art"
USER_AGENT = ("HaydaySandbox-wiki-fetch/1.0 (personal offline layout editor, non-redistributed; "
	"polite: <=3 concurrent) python-requests")
MAX_WORKERS = 3
API_INTERVAL = 0.4        # seconds between API requests (sequential)
DL_INTERVAL = 0.3         # min spacing between download request starts, across all workers
MAX_ATTEMPTS = 6
TIMEOUT = 90
Image.MAX_IMAGE_PIXELS = 300_000_000

WIKIS = {
	"en": {"api": "https://hayday.fandom.com/api.php", "subdir": "wiki", "lang": "en",
		"routes": "category,catalog_lookup,catalog_page"},
	"ru": {"api": "https://hayday.fandom.com/ru/api.php", "subdir": "wiki_ru", "lang": "ru",
		"routes": "catalog_lookup,catalog_page"},
}
ROOT_CATEGORIES = {
	"en": ["Category:Images", "Category:Image Decos", "Category:Decorations"],
	"ru": ["Категория:Картинки украшений", "Категория:Картинки зданий", "Категория:Картинки деревьев"],
}
RASTER_MIME = {"image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"}

# Category classification. "relevant": may hold object renders (kept). "excluded": clearly not placeable objects
# (a file only in excluded categories is skipped unless the catalog lookup matched it by name). Anything else is
# neutral (maintenance / licence categories) unless its name matches RELEVANT_KEYWORDS.
RELEVANT_CATEGORIES = {
	# en
	"Images", "Image Decos", "Decorations", "Image Production Buildings", "Image Service Buildings",
	"Image Storage Buildings", "Image Animal Shelters", "Image Animals", "Image Trees and Bushes", "Image Crops",
	"Image Farm", "Image Customization", "Image Themes", "Image Sanctuary", "Image Town", "Image Valley",
	"Image Fishing", "Image Boat", "Image Truck", "Image Events", "Image Derby", "Image Farm Pass",
	"Image Catalogue", "Image Neighborhood", "Image Shop", "Image Mystery Boxes", "Image Daily Dirt",
	# ru
	"Картинки украшений", "Картинки зданий", "Картинки деревьев", "Картинки культур", "Картинки событий",
	"Жилища для животных",
}
EXCLUDED_CATEGORIES = {
	"Image Achievements": "achievement badges (UI)",
	"Image Animal Goods": "product icons",
	"Image Boosters": "booster icons (UI)",
	"Image Currencies": "currency icons (UI)",
	"Image Daily Reward": "reward UI",
	"Image Experience Levels": "level-up screens (UI)",
	"Experience": "level-up screens (UI)",
	"Image FAQ": "help screenshots",
	"Image Fish": "fish item icons",
	"Image Lure": "lure item icons",
	"Image Masteries": "mastery badges (UI)",
	"Image News": "news banners",
	"Image NPC": "NPC characters, not placeable objects",
	"Image Products": "product icons",
	"Image Reputation Levels": "reputation UI",
	"Image Supplies": "supply item icons",
	"Image UI": "UI",
	"Image User": "user uploads / screenshots",
	"Image Vouchers": "voucher icons",
	"Image Wiki": "wiki branding",
	"Videos": "video embeds",
	"Audio": "audio",
	"Concept Art": "external concept art, not in-game renders",
	"Image Achievements ": "achievement badges (UI)",
	"Картинки продуктов": "product icons",
	"Иконки": "UI icons",
	"Картинки головных уборов": "avatar headwear icons",
}
RELEVANT_KEYWORDS = re.compile(r"deco|build|tree|bush|farm|animal|shelter|crop|field|fence|path|season|sanctuar|"
	r"town|valley|custom|theme|fishing|boat|truck|derby|catalog|neighbo|house|pen\b|plant|flower|nature|"
	r"украш|здани|дерев|культур|жилищ|событ", re.I)
LOGO_RE = re.compile(r"(^|[\s_\-])(logo|wordmark|favicon)([\s_\-.]|$)|^wiki\.png$|^site-|community-header|"
	r"wiki[\s_-]?background", re.I)
SMALL_WORDS = {"a", "an", "and", "the", "of", "in", "on", "at", "to", "for", "with", "or", "de", "la", "le", "du",
	"n", "o"}
TRANSLIT = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
	["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s", "t", "u", "f",
	"kh", "ts", "ch", "sh", "shch", "", "y", "", "e", "yu", "ya"]))


class Blocked(RuntimeError):
	"""A host answered with a bot challenge / access control. We never try to bypass it."""


class HttpError(RuntimeError):
	def __init__(self, status: int, msg: str):
		super().__init__(f"HTTP {status}: {msg}")
		self.status = status


# --------------------------------------------------------------------------------------------------------------
# helpers

def now_iso() -> str:
	return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def log(msg: str) -> None:
	line = f"[{dt.datetime.now().strftime('%H:%M:%S')}] {msg}"
	print(line, file=sys.stderr, flush=True)
	if LOG_FILE is not None:
		with LOG_LOCK, open(LOG_FILE, "a", encoding="utf-8") as fh:
			fh.write(line + "\n")


LOG_FILE: Path | None = None
LOG_LOCK = threading.Lock()


def inside_git_worktree(p: Path) -> Path | None:
	for parent in [p, *p.parents]:
		if (parent / ".git").exists():
			return parent
	return None


def slugify(title: str) -> str:
	name = title.split(":", 1)[1] if ":" in title else title
	name = re.sub(r"\.[A-Za-z0-9]{2,5}$", "", name)
	out = []
	for ch in name.lower():
		out.append(TRANSLIT.get(ch, ch))
	s = unicodedata.normalize("NFKD", "".join(out)).encode("ascii", "ignore").decode()
	s = re.sub(r"[^a-z0-9]+", "_", s).strip("_")
	return (s or "file")[:120]


def atomic_write_json(path: Path, data) -> None:
	tmp = path.with_suffix(path.suffix + ".tmp")
	tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
	os.replace(tmp, path)


def sha1_file(path: Path) -> str:
	h = hashlib.sha1()
	with open(path, "rb") as fh:
		for chunk in iter(lambda: fh.read(1 << 20), b""):
			h.update(chunk)
	return h.hexdigest()


def chunks(seq, n):
	seq = list(seq)
	for i in range(0, len(seq), n):
		yield seq[i:i + n]


def page_title_from_url(url: str, lang: str) -> str | None:
	u = urllib.parse.urlparse(url)
	if u.netloc != "hayday.fandom.com":
		return None
	prefix = "/wiki/" if lang == "en" else f"/{lang}/wiki/"
	if not u.path.startswith(prefix):
		return None
	return urllib.parse.unquote(u.path[len(prefix):]).replace("_", " ")


# --------------------------------------------------------------------------------------------------------------
# HTTP

class RateLimiter:
	def __init__(self, interval: float):
		self.interval = interval
		self.lock = threading.Lock()
		self.next_t = 0.0

	def wait(self) -> None:
		with self.lock:
			now = time.monotonic()
			t = max(now, self.next_t)
			self.next_t = t + self.interval
		if t > now:
			time.sleep(t - now)


class Http:
	def __init__(self):
		self.local = threading.local()
		self.api_rl = RateLimiter(API_INTERVAL)
		self.dl_rl = RateLimiter(DL_INTERVAL)
		self.blocked: dict[str, str] = {}
		self.counts = {"api_requests": 0, "download_requests": 0, "retries": 0}
		self.count_lock = threading.Lock()

	def session(self) -> requests.Session:
		s = getattr(self.local, "s", None)
		if s is None:
			s = requests.Session()
			s.headers["User-Agent"] = USER_AGENT
			s.headers["Accept-Encoding"] = "gzip, deflate"
			self.local.s = s
		return s

	@staticmethod
	def _challenge(r: requests.Response) -> bool:
		if r.headers.get("cf-mitigated", "").lower() == "challenge":
			return True
		if "text/html" in r.headers.get("content-type", "") and r.status_code in (403, 429, 503):
			head = r.content[:6000].decode("utf-8", "replace")
			return any(k in head for k in ("Just a moment", "challenge-platform", "cf-turnstile", "captcha"))
		return False

	def get(self, url: str, *, params=None, headers=None, stream=False, kind="api") -> requests.Response:
		host = urllib.parse.urlparse(url).hostname or ""
		if host in self.blocked:
			raise Blocked(f"{host}: {self.blocked[host]}")
		rl = self.api_rl if kind == "api" else self.dl_rl
		err = "?"
		for attempt in range(1, MAX_ATTEMPTS + 1):
			rl.wait()
			with self.count_lock:
				self.counts["api_requests" if kind == "api" else "download_requests"] += 1
				if attempt > 1:
					self.counts["retries"] += 1
			backoff = min(120.0, 2.0 * (2 ** (attempt - 1))) + random.uniform(0, 1.0)
			try:
				r = self.session().get(url, params=params, headers=headers, stream=stream, timeout=TIMEOUT)
			except (requests.ConnectionError, requests.Timeout) as e:
				err = f"{type(e).__name__}: {e}"[:300]
				log(f"  retry {attempt}/{MAX_ATTEMPTS} {host}: {err[:120]} (sleep {backoff:.0f}s)")
				time.sleep(backoff)
				continue
			if self._challenge(r):
				self.blocked[host] = f"bot challenge (HTTP {r.status_code}); not bypassed"
				r.close()
				raise Blocked(f"{host}: {self.blocked[host]}")
			if r.status_code in (429, 500, 502, 503, 504):
				ra = r.headers.get("Retry-After", "")
				wait = max(backoff, float(ra)) if ra.isdigit() else backoff
				err = f"HTTP {r.status_code}"
				r.close()
				log(f"  retry {attempt}/{MAX_ATTEMPTS} {host}: {err} (sleep {wait:.0f}s)")
				time.sleep(min(wait, 300.0))
				continue
			return r
		raise HttpError(0, f"gave up after {MAX_ATTEMPTS} attempts: {err}")


# --------------------------------------------------------------------------------------------------------------
# MediaWiki API

class Wiki:
	def __init__(self, http: Http, api: str):
		self.http = http
		self.api = api
		self.warned: set[str] = set()

	def call(self, params: dict) -> dict:
		p = {"format": "json", "formatversion": "2", **params}
		r = self.http.get(self.api, params=p, kind="api")
		if r.status_code != 200:
			raise HttpError(r.status_code, f"API {params.get('action')} failed")
		d = r.json()
		if "error" in d:
			raise RuntimeError(f"API error: {d['error']}")
		w = json.dumps(d.get("warnings", {}), ensure_ascii=False)[:300]
		if d.get("warnings") and w not in self.warned:
			self.warned.add(w)
			log(f"  API warning: {w}")
		return d

	def query_all(self, params: dict):
		"""Yield every response of a (generator) query, following `continue`. File-history continuation
		(`iistart`) is dropped: only the latest revision is wanted. Repeated continuations end the loop."""
		base = {"action": "query", **params}
		cont: dict = {}
		seen: set[str] = set()
		while True:
			d = self.call({**base, **cont})
			yield d
			c = d.get("continue")
			if not c:
				return
			c = {k: v for k, v in c.items() if k != "iistart"}
			key = json.dumps(c, sort_keys=True)
			if set(c) <= {"continue"} or key in seen:
				return
			seen.add(key)
			cont = c


IMAGE_PROPS = {"prop": "imageinfo|categories", "iiprop": "url|size|sha1|mime|timestamp", "iilimit": "1",
	"cllimit": "max"}


class Store:
	"""All discovered File: pages, keyed by canonical title."""

	def __init__(self):
		self.recs: dict[str, dict] = {}

	def rec(self, title: str) -> dict:
		r = self.recs.get(title)
		if r is None:
			r = self.recs[title] = {"title": title, "info": None, "categories": set(), "matched_by": set(),
				"catalog_ids": set(), "used_on": set(), "lead_image_of": set(), "found_in_categories": set(),
				"exists": None}
		return r

	def merge(self, d: dict, route: str | None) -> list[str]:
		titles = []
		for p in d.get("query", {}).get("pages", []):
			if p.get("ns") != 6 or p.get("invalid"):
				continue
			ii = p.get("imageinfo")
			if p.get("missing") and not ii:
				continue
			r = self.rec(p["title"])
			r["exists"] = True
			if ii and r["info"] is None:
				r["info"] = ii[0]
			for c in p.get("categories", []):
				r["categories"].add(c["title"].split(":", 1)[1])
			if route:
				r["matched_by"].add(route)
			titles.append(p["title"])
		return titles


def resolve_map(d: dict) -> dict[str, str]:
	"""requested title -> final title (normalisation then redirects) for one API response."""
	q = d.get("query", {})
	norm = {n["from"]: n["to"] for n in q.get("normalized", [])}
	redir = {n["from"]: n["to"] for n in q.get("redirects", [])}
	out = {}
	for src, dst in norm.items():
		out[src] = redir.get(dst, dst)
	for src, dst in redir.items():
		out.setdefault(src, dst)
	return out


# --------------------------------------------------------------------------------------------------------------
# discovery

def classify_category(name: str) -> tuple[str, str]:
	if name in EXCLUDED_CATEGORIES:
		return "excluded", EXCLUDED_CATEGORIES[name]
	if name in RELEVANT_CATEGORIES:
		return "relevant", "object category"
	if RELEVANT_KEYWORDS.search(name):
		return "relevant", "name looks object-related"
	return "neutral", "maintenance/licence/other"


def discover_categories(wiki: Wiki, store: Store, lang: str, max_depth: int) -> list[dict]:
	roots = list(ROOT_CATEGORIES[lang])
	# other file-holding categories whose names look object-related (not linked under Category:Images)
	extra = []
	for d in wiki.query_all({"list": "allcategories", "acprop": "size", "aclimit": "max", "acmin": "1"}):
		for c in d["query"]["allcategories"]:
			name = c.get("category") or c.get("*")
			if c.get("files", 0) > 0 and classify_category(name)[0] == "relevant":
				extra.append(("Category:" if lang == "en" else "Категория:") + name)
	cats: dict[str, dict] = {}
	queue = [(t, 0, None) for t in roots] + [(t, 0, "allcategories") for t in extra]
	while queue:
		title, depth, parent = queue.pop(0)
		if title in cats:
			continue
		cats[title] = {"title": title, "depth": depth, "parent": parent}
		if depth >= max_depth:
			continue
		for d in wiki.query_all({"list": "categorymembers", "cmtitle": title, "cmtype": "subcat", "cmlimit": "max"}):
			for m in d["query"]["categorymembers"]:
				queue.append((m["title"], depth + 1, title))
	report = []
	for title, meta in cats.items():
		name = title.split(":", 1)[1]
		cls, why = classify_category(name)
		members: set[str] = set()
		for d in wiki.query_all({"generator": "categorymembers", "gcmtitle": title, "gcmtype": "file",
				"gcmlimit": "200", **IMAGE_PROPS}):
			for t in store.merge(d, "category"):
				store.recs[t]["found_in_categories"].add(name)
				members.add(t)
		n = len(members)
		report.append({**meta, "files": n, "class": cls, "why": why})
		log(f"  category {title!r} depth={meta['depth']} files={n} [{cls}]")
	return report


def load_catalog() -> list[dict]:
	items = []
	for f in sorted(glob.glob(str(REPO_ROOT / "data/items/*.json"))):
		if f.endswith("categories.json"):
			continue
		items += json.loads(Path(f).read_text(encoding="utf-8"))["items"]
	return items


def _cap(w: str) -> str:
	return w[:1].upper() + w[1:]


def name_variants(name: str) -> list[str]:
	"""Plausible wiki file base names for a catalog name (wiki files are mostly Title Case)."""
	base = re.sub(r"\s+", " ", name).strip()
	forms = [base, re.sub(r"\s*\(.*?\)\s*", " ", base).strip(), re.sub(r"\s*:\s*", " ", base).strip()]
	m = re.match(r"^(.*?):\s*(.+)$", base)
	if m:  # "Rose Fence: Orange" -> "Orange Rose Fence"
		forms.append(f"{m.group(2)} {m.group(1)}")
	out = []
	for f in forms:
		if not f:
			continue
		words = f.split(" ")
		every = " ".join(_cap(w) for w in words)
		every_h = "-".join(_cap(p) for p in every.split("-"))
		small = " ".join(w if (i > 0 and w.lower() in SMALL_WORDS) else _cap(w) for i, w in enumerate(words))
		for v in (f, _cap(f), every, every_h, small):
			if v not in out and not re.search(r"[#<>\[\]|{}]", v):
				out.append(v)
	return out


def catalog_lookup(wiki: Wiki, en_wiki: Wiki, store: Store, items: list[dict], lang: str) -> dict:
	want: dict[str, set[str]] = {}  # requested File: title -> catalog ids

	def add(title_base: str, item_id: str):
		want.setdefault(f"File:{title_base}.png", set()).add(item_id)

	en_pages: dict[str, set[str]] = {}
	for it in items:
		if it.get("category") == "planning":
			continue
		for v in name_variants(it["name"]):
			add(v, it["id"])
		for s in it.get("sources", []):
			t = page_title_from_url(s, lang)
			if t and "/" not in t:
				for v in ([t] if lang == "ru" else name_variants(t)):
					add(v, it["id"])
			te = page_title_from_url(s, "en")
			if lang == "ru" and te and "/" not in te:
				en_pages.setdefault(te, set()).add(it["id"])
	langlinked = 0
	if lang == "ru" and en_pages:  # en item pages -> ru page titles via interlanguage links
		for batch in chunks(sorted(en_pages), 50):
			for d in en_wiki.query_all({"titles": "|".join(batch), "prop": "langlinks", "lllang": "ru",
					"lllimit": "max", "redirects": "1"}):
				rm = resolve_map(d)
				back = {}
				for t in batch:
					back.setdefault(rm.get(t, t), []).append(t)
				for p in d["query"].get("pages", []):
					for ll in p.get("langlinks", []):
						for src in back.get(p["title"], []):
							for iid in en_pages[src]:
								add(ll["title"], iid)
								langlinked += 1
	log(f"  catalog_lookup: {len(want)} candidate titles for {len(items)} items (langlink titles: {langlinked})")
	matched_items: dict[str, set[str]] = {}
	for batch in chunks(sorted(want), 50):
		for d in wiki.query_all({"titles": "|".join(batch), "redirects": "1", **IMAGE_PROPS}):
			rm = resolve_map(d)
			found = set(store.merge(d, "catalog_lookup"))
			for t in batch:
				final = rm.get(t, t)
				if final in found:
					r = store.recs[final]
					r["catalog_ids"] |= want[t]
					for iid in want[t]:
						matched_items.setdefault(iid, set()).add(final)
	n_items = sum(1 for it in items if it.get("category") != "planning")
	return {"items_considered": n_items, "candidate_titles": len(want), "items_matched": len(matched_items),
		"files_matched": len({t for s in matched_items.values() for t in s}),
		"unmatched_item_ids": sorted(it["id"] for it in items
			if it.get("category") != "planning" and it["id"] not in matched_items),
		"matches": {k: sorted(v) for k, v in sorted(matched_items.items())}}


def catalog_pages(wiki: Wiki, store: Store, items: list[dict], lang: str) -> dict:
	pages: dict[str, set[str]] = {}
	for it in items:
		for s in it.get("sources", []):
			t = page_title_from_url(s, lang)
			if t:
				pages.setdefault(t, set()).add(it["id"])
	page_images: dict[str, set[str]] = {}
	lead: dict[str, str] = {}
	for batch in chunks(sorted(pages), 50):
		for d in wiki.query_all({"titles": "|".join(batch), "redirects": "1", "prop": "images|pageimages",
				"imlimit": "max", "piprop": "name", "pilimit": "50"}):
			rm = resolve_map(d)
			back: dict[str, list[str]] = {}
			for t in batch:
				back.setdefault(rm.get(t, t), []).append(t)
			for p in d["query"].get("pages", []):
				srcs = back.get(p["title"], [p["title"]])
				for im in p.get("images", []):
					for s in srcs:
						page_images.setdefault(s, set()).add(im["title"])
				if p.get("pageimage"):
					for s in srcs:
						lead[s] = "File:" + p["pageimage"].replace("_", " ")
	all_files = {t for v in page_images.values() for t in v} | set(lead.values())
	log(f"  catalog_page: {len(pages)} cited pages -> {len(all_files)} distinct images ({len(lead)} lead images)")
	used_on: dict[str, set[str]] = {}
	for page, ims in page_images.items():
		for t in ims:
			used_on.setdefault(t, set()).add(page)
	lead_of: dict[str, set[str]] = {}
	for page, t in lead.items():
		lead_of.setdefault(t, set()).add(page)
	got: set[str] = set()
	for batch in chunks(sorted(all_files), 50):
		for d in wiki.query_all({"titles": "|".join(batch), "redirects": "1", **IMAGE_PROPS}):
			rm = resolve_map(d)
			found = set(store.merge(d, None))
			for t in batch:
				final = rm.get(t, t)
				if final in found:
					got.add(final)
					r = store.recs[final]
					r["matched_by"].add("catalog_page")
					r["used_on"] |= used_on.get(t, set())
					for page in lead_of.get(t, ()):
						r["lead_image_of"].add(page)
						r["catalog_ids"] |= pages[page]
	return {"cited_pages": len(pages), "pages_with_lead_image": len(lead), "distinct_page_images": len(all_files),
		"files_resolved": len(got)}


# --------------------------------------------------------------------------------------------------------------
# selection

def skip_reason(r: dict) -> str | None:
	info = r["info"]
	title = r["title"]
	base = title.split(":", 1)[1]
	if not info:
		return "no_imageinfo"
	mime = info.get("mime", "")
	if mime not in RASTER_MIME:
		return f"not_raster_image ({mime or 'unknown'})"
	if LOGO_RE.search(base):
		return "logo_or_branding"
	w, h = int(info.get("width") or 0), int(info.get("height") or 0)
	if max(w, h) < 48:
		return "icon_smaller_than_48px"
	classes = {c: classify_category(c) for c in r["categories"]}
	relevant = [c for c, (k, _) in classes.items() if k == "relevant"]
	excluded = [c for c, (k, _) in classes.items() if k == "excluded"]
	catalog = "catalog_lookup" in r["matched_by"]
	if excluded and not relevant and not catalog:
		c = sorted(excluded)[0]
		return f"non_object_category: {c} ({classes[c][1]})"
	if r["matched_by"] == {"catalog_page"} and not relevant and not r["lead_image_of"]:
		return "page_image_not_object (not lead image, no object category)"
	if mime == "image/gif" and not relevant and not catalog:
		return "gif_ui_or_uncategorised"
	if w > 1600 and mime == "image/jpeg":
		return "screenshot_no_alpha (jpeg wider than 1600px)"
	return None


def assign_paths(kept: list[dict], files_dir: Path) -> None:
	used: dict[str, str] = {}
	for r in sorted(kept, key=lambda r: r["title"]):
		ext = RASTER_MIME[r["info"]["mime"]]
		name = f"{slugify(r['title'])}.{ext}"
		if name in used:
			name = f"{slugify(r['title'])}_{hashlib.sha1(r['title'].encode()).hexdigest()[:6]}.{ext}"
		used[name] = r["title"]
		r["filename"] = name
		r["path"] = files_dir / name


# --------------------------------------------------------------------------------------------------------------
# download + verification

def analyse(data: bytes) -> dict:
	im = Image.open(io.BytesIO(data))
	fmt = im.format
	frames = getattr(im, "n_frames", 1)
	im.verify()
	im = Image.open(io.BytesIO(data))
	im.load()
	has_channel = im.mode in ("RGBA", "LA", "PA", "RGBa") or "transparency" in im.info
	out = {"format": fmt, "mode": im.mode, "decoded_width": im.width, "decoded_height": im.height,
		"frames": frames, "has_alpha_channel": bool(has_channel), "alpha_used": False,
		"visible_fraction": 1.0, "alpha_bbox": [0, 0, im.width, im.height]}
	if has_channel:
		rgba = im.convert("RGBA")
		a = np.asarray(rgba)[..., 3]
		out["alpha_used"] = bool((a < 255).any())
		out["visible_fraction"] = round(float((a > 0).mean()), 4)
		bb = rgba.getchannel("A").getbbox()
		out["alpha_bbox"] = list(bb) if bb else None
	return out


def original_url(url: str) -> str:
	return url + ("&" if "?" in url else "?") + "format=original"


def fetch_one(http: Http, r: dict, resume: bool) -> dict:
	"""Download + verify one file. Returns a result dict (never raises for ordinary failures)."""
	info = r["info"]
	path: Path = r["path"]
	want_sha = info.get("sha1", "")
	if resume and path.exists() and want_sha and sha1_file(path) == want_sha:
		try:
			meta = analyse(path.read_bytes())
			return {"status": "present", "meta": meta, "bytes": path.stat().st_size}
		except Exception as e:  # corrupt despite sha1? re-download
			log(f"  existing file failed to decode, re-downloading {path.name}: {e}")
	part = path.with_name(path.name + ".part")
	url = original_url(info["url"])
	last_err = "?"
	for attempt in range(1, 4):
		headers = {}
		if resume and part.exists() and part.stat().st_size > 0 and attempt == 1:
			headers["Range"] = f"bytes={part.stat().st_size}-"
		try:
			resp = http.get(url, headers=headers, stream=True, kind="dl")
		except Blocked as e:
			return {"status": "failed", "error": f"blocked_by_bot_protection: {e}"}
		except HttpError as e:
			last_err = str(e)
			continue
		try:
			if resp.status_code == 416:
				part.unlink(missing_ok=True)
				last_err = "HTTP 416 on resume"
				continue
			if resp.status_code not in (200, 206):
				last_err = f"HTTP {resp.status_code}"
				if resp.status_code in (403, 404, 410):
					break
				continue
			ctype = resp.headers.get("content-type", "")
			if not ctype.startswith("image/"):
				last_err = f"unexpected content-type {ctype!r}"
				continue
			mode = "ab" if resp.status_code == 206 and headers else "wb"
			with open(part, mode) as fh:
				for chunk in resp.iter_content(1 << 16):
					fh.write(chunk)
		except (requests.RequestException, OSError) as e:
			last_err = f"{type(e).__name__}: {e}"[:300]
			time.sleep(2.0 * attempt)
			continue
		finally:
			resp.close()
		got_sha = sha1_file(part)
		if want_sha and got_sha != want_sha:
			last_err = f"sha1 mismatch (api {want_sha}, got {got_sha}, {part.stat().st_size} bytes)"
			part.unlink(missing_ok=True)
			continue
		data = part.read_bytes()
		try:
			meta = analyse(data)
		except Exception as e:
			last_err = f"undecodable: {type(e).__name__}: {e}"[:300]
			part.unlink(missing_ok=True)
			continue
		if info.get("size") and len(data) != int(info["size"]):
			meta["size_mismatch_vs_api"] = [len(data), int(info["size"])]
		os.replace(part, path)
		return {"status": "downloaded", "meta": meta, "bytes": len(data), "sha1_verified": bool(want_sha)}
	if not resume:
		part.unlink(missing_ok=True)
	return {"status": "failed", "error": last_err}


# --------------------------------------------------------------------------------------------------------------
# main

def size_bucket(w: int, h: int) -> str:
	m = max(w, h)
	for lim, name in ((128, "<128"), (256, "128-255"), (512, "256-511"), (1024, "512-1023"), (2048, "1024-2047")):
		if m < lim:
			return name
	return ">=2048"


def main() -> int:
	global LOG_FILE
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--out", default=str(DEFAULT_OUT), help="private storage root (outside the repo)")
	ap.add_argument("--wiki", choices=sorted(WIKIS), default="en")
	ap.add_argument("--resume", action="store_true", help="keep verified files, continue partial downloads")
	ap.add_argument("--max-depth", type=int, default=3, help="category recursion depth (default 3)")
	ap.add_argument("--routes", default=None, help="comma list of category,catalog_lookup,catalog_page "
		"(default en: all three; ru: catalog_lookup,catalog_page)")
	ap.add_argument("--discover-only", action="store_true", help="discovery + index only, no downloads")
	ap.add_argument("--limit", type=int, default=0, help="download at most N files (testing)")
	ap.add_argument("--workers", type=int, default=MAX_WORKERS, help="concurrent downloads (max 3)")
	args = ap.parse_args()

	out = Path(args.out).expanduser().resolve()
	wt = inside_git_worktree(out)
	if wt is not None or out == REPO_ROOT or REPO_ROOT in out.parents:
		sys.exit(f"refusing to write proprietary images inside a git work tree ({wt or REPO_ROOT}); "
			f"use a private directory such as {DEFAULT_OUT}")
	cfg = WIKIS[args.wiki]
	lang = cfg["lang"]
	routes = [s.strip() for s in (args.routes or cfg["routes"]).split(",") if s.strip()]
	workers = max(1, min(MAX_WORKERS, args.workers))
	sub = out / "raw" / cfg["subdir"]
	files_dir = sub / "files"
	files_dir.mkdir(parents=True, exist_ok=True)
	LOG_FILE = sub / "fetch.log"
	log(f"fetch_wiki: wiki={args.wiki} routes={routes} out={sub} resume={args.resume} depth={args.max_depth}")

	http = Http()
	wiki = Wiki(http, cfg["api"])
	en_wiki = wiki if lang == "en" else Wiki(http, WIKIS["en"]["api"])
	store = Store()
	items = load_catalog()
	t0 = time.time()
	discovery: dict = {"routes": routes}
	try:
		if "category" in routes:
			discovery["categories"] = discover_categories(wiki, store, lang, args.max_depth)
		if "catalog_lookup" in routes:
			discovery["catalog_lookup"] = catalog_lookup(wiki, en_wiki, store, items, lang)
		if "catalog_page" in routes:
			discovery["catalog_page"] = catalog_pages(wiki, store, items, lang)
	except Blocked as e:
		log(f"STOP: API blocked by bot protection, not bypassing: {e}")
		atomic_write_json(sub / "failed.json", {"fetched_at": now_iso(), "fatal": f"blocked_by_bot_protection: {e}"})
		return 2
	log(f"discovery done in {time.time() - t0:.0f}s: {len(store.recs)} files, {http.counts['api_requests']} API requests")

	# selection
	en_sha1: dict[str, str] = {}
	if lang != "en":
		en_index = out / "raw" / WIKIS["en"]["subdir"] / "index.json"
		if en_index.exists():
			for f in json.loads(en_index.read_text(encoding="utf-8")).get("files", []):
				en_sha1.setdefault(f["sha1"], f["title"])
	kept, skipped = [], []
	for r in sorted(store.recs.values(), key=lambda r: r["title"]):
		reason = skip_reason(r)
		if reason is None and r["info"].get("sha1") in en_sha1:
			reason = f"duplicate_of_en_wiki: {en_sha1[r['info']['sha1']]}"
		if reason:
			skipped.append((r, reason))
		else:
			kept.append(r)
	assign_paths(kept, files_dir)
	# identical bytes under several titles: download once, hard-link the rest
	by_sha: dict[str, dict] = {}
	for r in kept:
		s = r["info"].get("sha1")
		if s and s in by_sha:
			r["duplicate_of"] = by_sha[s]["title"]
		elif s:
			by_sha[s] = r
	primaries = [r for r in kept if "duplicate_of" not in r]
	log(f"selection: kept {len(kept)} ({len(primaries)} unique by sha1), skipped {len(skipped)}")

	results: dict[str, dict] = {}
	todo = primaries if not args.limit else primaries[:args.limit]
	if args.discover_only:
		todo = []
	done = 0
	t1 = time.time()
	if todo:
		log(f"downloading {len(todo)} files with {workers} workers ...")
		with cf.ThreadPoolExecutor(max_workers=workers) as ex:
			futs = {ex.submit(fetch_one, http, r, args.resume): r for r in todo}
			for fut in cf.as_completed(futs):
				r = futs[fut]
				try:
					res = fut.result()
				except Exception as e:  # defensive: never lose the whole run
					res = {"status": "failed", "error": f"{type(e).__name__}: {e}"[:300]}
				results[r["title"]] = res
				done += 1
				if res["status"] == "failed":
					log(f"  FAILED {r['title']}: {res['error']}")
				if done % 100 == 0 or done == len(todo):
					st = {}
					for v in results.values():
						st[v["status"]] = st.get(v["status"], 0) + 1
					log(f"  {done}/{len(todo)} {st} ({time.time() - t1:.0f}s)")
	# duplicates -> hard links
	for r in kept:
		if "duplicate_of" not in r:
			continue
		src = by_sha[r["info"]["sha1"]]
		sres = results.get(src["title"])
		if not sres or sres["status"] == "failed":
			continue
		if not r["path"].exists():
			try:
				os.link(src["path"], r["path"])
			except OSError:
				r["path"].write_bytes(src["path"].read_bytes())
		results[r["title"]] = {**sres, "status": "duplicate_linked"}

	# post-download screenshot check: opaque images wider than 1600 px are not object renders
	files_out, failed = [], []
	for r in kept:
		res = results.get(r["title"])
		if res is None:
			continue
		if res["status"] == "failed":
			failed.append({"title": r["title"], "url": r["info"]["url"], "error": res["error"],
				"description_url": r["info"].get("descriptionurl")})
			continue
		meta = res["meta"]
		if int(r["info"].get("width") or 0) > 1600 and not meta["alpha_used"]:
			skipped.append((r, "screenshot_no_alpha (opaque, wider than 1600px; deleted after check)"))
			r["path"].unlink(missing_ok=True)
			continue
		info = r["info"]
		files_out.append({
			"title": r["title"], "categories": sorted(r["categories"]),
			"width": info.get("width"), "height": info.get("height"), "mime": info.get("mime"),
			"sha1": info.get("sha1"), "size_bytes": info.get("size"), "timestamp": info.get("timestamp"),
			"local_path": str(r["path"]), "rel_path": str(r["path"].relative_to(out)),
			"url": info.get("url"), "download_url": original_url(info["url"]),
			"description_url": info.get("descriptionurl"),
			"matched_by": "|".join(sorted(r["matched_by"])), "matched_by_list": sorted(r["matched_by"]),
			"catalog_ids": sorted(r["catalog_ids"]), "used_on": sorted(r["used_on"]),
			"lead_image_of": sorted(r["lead_image_of"]), "duplicate_of": r.get("duplicate_of"),
			"status": res["status"], "has_alpha_channel": meta["has_alpha_channel"], "alpha": meta["alpha_used"],
			"visible_fraction": meta["visible_fraction"], "alpha_bbox": meta["alpha_bbox"],
			"frames": meta["frames"], "format": meta["format"], "mode": meta["mode"],
			**({"size_mismatch_vs_api": meta["size_mismatch_vs_api"]} if "size_mismatch_vs_api" in meta else {}),
		})
	not_attempted = [r["title"] for r in kept if r["title"] not in results]

	reasons: dict[str, int] = {}
	for _, why in skipped:
		key = "duplicate_of_en_wiki" if why.startswith("duplicate_of_en_wiki") else why
		reasons[key] = reasons.get(key, 0) + 1
	sizes: dict[str, int] = {}
	for f in files_out:
		b = size_bucket(int(f["width"] or 0), int(f["height"] or 0))
		sizes[b] = sizes.get(b, 0) + 1
	status_counts: dict[str, int] = {}
	for f in files_out:
		status_counts[f["status"]] = status_counts.get(f["status"], 0) + 1
	stats = {
		"discovered": len(store.recs),
		"kept_after_metadata_filters": len(kept),
		"kept_unique_sha1": len(primaries),
		"skipped": len(skipped),
		"skipped_by_reason": dict(sorted(reasons.items(), key=lambda kv: -kv[1])),
		"stored_files": len(files_out),
		"stored_by_status": status_counts,
		"failed": len(failed),
		"not_attempted": len(not_attempted),
		"with_alpha": sum(1 for f in files_out if f["alpha"]),
		"with_alpha_channel": sum(1 for f in files_out if f["has_alpha_channel"]),
		"without_alpha": sum(1 for f in files_out if not f["alpha"]),
		"size_distribution_max_side": dict(sorted(sizes.items())),
		"stored_bytes_unique": sum(int(f["size_bytes"] or 0) for f in files_out if not f["duplicate_of"]),
		"by_matched_by": {},
		"http": dict(http.counts),
		"blocked_hosts": dict(http.blocked),
		"elapsed_s": round(time.time() - t0, 1),
	}
	for f in files_out:
		stats["by_matched_by"][f["matched_by"]] = stats["by_matched_by"].get(f["matched_by"], 0) + 1
	index = {
		"source": SOURCE,
		"wiki": args.wiki, "api": cfg["api"], "fetched_at": now_iso(),
		"tool": "tools/private_assets/fetch_wiki.py", "root": str(out),
		"private_use_only": "Proprietary Supercell art. Never commit, publish or redistribute.",
		"params": {"routes": routes, "max_depth": args.max_depth, "resume": args.resume,
			"discover_only": args.discover_only, "limit": args.limit},
		"stats": stats,
		"discovery": discovery,
		"files": files_out,
		"skipped": [{"title": r["title"], "reason": why, "categories": sorted(r["categories"]),
			"matched_by": "|".join(sorted(r["matched_by"])), "catalog_ids": sorted(r["catalog_ids"]),
			"width": (r["info"] or {}).get("width"), "height": (r["info"] or {}).get("height"),
			"mime": (r["info"] or {}).get("mime"), "sha1": (r["info"] or {}).get("sha1"),
			"url": (r["info"] or {}).get("url"), "description_url": (r["info"] or {}).get("descriptionurl")}
			for r, why in sorted(skipped, key=lambda x: x[0]["title"])],
		"not_attempted": not_attempted,
	}
	atomic_write_json(sub / "index.json", index)
	atomic_write_json(sub / "failed.json", {"fetched_at": now_iso(), "wiki": args.wiki, "failed": failed,
		"blocked_hosts": dict(http.blocked)})
	log("stats: " + json.dumps({k: v for k, v in stats.items() if k not in ("by_matched_by",)}, ensure_ascii=False))
	log(f"wrote {sub / 'index.json'} and {sub / 'failed.json'}")
	return 0 if not failed else 1


if __name__ == "__main__":
	sys.exit(main())
