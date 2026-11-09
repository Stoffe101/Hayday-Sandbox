#!/usr/bin/env python3
"""Fetch the official Supercell *Hay Day Fan Kit* (fankit.supercell.com, project 361) into PRIVATE storage.

The Fan Kit is Supercell's public, unauthenticated asset portal (a Frontify brand portal). This tool:

  1. enumerates every asset of the project through the public search API (paginated), and re-queries every
     facet value (``asset-type91`` and ``characters85``) separately so each asset gets all of its type tags;
  2. downloads each image asset's ORIGINAL file through the portal's own "Download" endpoint
     (``/api/screen/download/<token>``, the token comes from the public search response and is never stored),
     verifying HTTP 200, content type, Pillow decodability and dimensions vs. metadata, and sha256-hashing it;
  3. writes ``<out>/raw/fankit/index.json`` and ``<out>/raw/fankit/failed.json``.

NOTE on the CDN: ``generic_url`` (media.ffycdn.net) without query parameters is *not* the original file: the CDN
re-encodes on the fly (opaque images come back as JPEG q85, or WebP if the Accept header allows it). Only the
download endpoint returns the byte-original file. ``?format=png&quality=100`` on the CDN gives a pixel-identical
(but larger) PNG re-encode; it is used only as a last-resort fallback for PNGs and is flagged in the index.

LEGAL: the output is proprietary Supercell art. It goes to a PRIVATE directory outside the repository
(default /root/hayday-sandbox-private-assets) and must never be committed or redistributed. The tool refuses to
write inside the repository. It never handles logins/challenges: if the portal starts answering with a bot
challenge it stops and records that.

Politeness: at most 3 concurrent requests, a small per-request delay, exponential backoff with Retry-After,
and resume (already verified files are not downloaded again).

Usage:
  python3 tools/private_assets/fetch_fankit.py --dry-run
  python3 tools/private_assets/fetch_fankit.py                      # everything
  python3 tools/private_assets/fetch_fankit.py --types Buildings,Fences
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import hashlib
import io
import json
import os
import random
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
	from PIL import Image
except ImportError:  # pragma: no cover
	sys.exit("Pillow is required: pip install pillow")

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = Path(os.environ.get("HAYDAY_PRIVATE_ASSETS", "/root/hayday-sandbox-private-assets"))
PORTAL = "https://fankit.supercell.com"
API = PORTAL + "/api"
PROJECT_ID = 361
PAGE_LIMIT = 100
MAX_WORKERS = 3
SOURCE = "Supercell Fan Kit (fankit.supercell.com/hayday)"
USER_AGENT = "HaydaySandbox-fankit-fetch/1.0 (personal offline layout editor; polite: <=3 concurrent)"
EXT_MIME = {
	"png": ("image/png",), "gif": ("image/gif",), "jpg": ("image/jpeg",), "jpeg": ("image/jpeg",),
	"webp": ("image/webp",), "bmp": ("image/bmp",), "tif": ("image/tiff",), "tiff": ("image/tiff",),
}
EXT_PIL = {"png": "PNG", "gif": "GIF", "jpg": "JPEG", "jpeg": "JPEG", "webp": "WEBP", "bmp": "BMP",
	"tif": "TIFF", "tiff": "TIFF"}
Image.MAX_IMAGE_PIXELS = 300_000_000  # fan-kit posters can be large; still bounded


class BlockedError(RuntimeError):
	"""The portal answered with a bot challenge / access control. We never try to bypass it."""


class HttpError(RuntimeError):
	def __init__(self, status: int, msg: str):
		super().__init__(f"HTTP {status}: {msg}")
		self.status = status


class Http:
	"""Tiny polite HTTP client: global concurrency cap, per-request delay, retries with backoff."""

	def __init__(self, delay: float, max_tries: int, timeout: float):
		self.delay = delay
		self.max_tries = max_tries
		self.timeout = timeout
		self.sem = threading.BoundedSemaphore(MAX_WORKERS)
		self.lock = threading.Lock()
		self.requests = 0
		self.retries = 0

	def get(self, url: str, accept: str = "*/*") -> tuple[int, dict, bytes]:
		last: Exception | None = None
		for attempt in range(1, self.max_tries + 1):
			wait = None
			with self.sem:
				try:
					req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
					with urllib.request.urlopen(req, timeout=self.timeout) as r:
						body = r.read()
						status, headers = r.status, {k.lower(): v for k, v in r.headers.items()}
				except urllib.error.HTTPError as e:
					body = e.read() if e.fp else b""
					status, headers = e.code, {k.lower(): v for k, v in (e.headers or {}).items()}
				except Exception as e:  # network error, timeout, reset ...
					status, headers, body, last = None, {}, b"", e
				finally:
					with self.lock:
						self.requests += 1
					time.sleep(self.delay)
			if status is not None:
				_check_blocked(status, headers, body)
				if status == 429 or 500 <= status < 600:
					last = HttpError(status, "retryable")
					ra = headers.get("retry-after", "")
					wait = float(ra) if ra.replace(".", "", 1).isdigit() else None
				else:
					return status, headers, body
			if attempt < self.max_tries:
				with self.lock:
					self.retries += 1
				time.sleep(min(60.0, wait if wait is not None else (2 ** (attempt - 1)) + random.random()))
		raise HttpError(getattr(last, "status", 0) or 0, f"giving up after {self.max_tries} tries: {last}")

	def get_json(self, url: str) -> dict:
		status, headers, body = self.get(url, accept="application/json")
		if status != 200:
			raise HttpError(status, url_for_log(url))
		try:
			return json.loads(body)
		except ValueError as e:
			raise HttpError(status, f"invalid JSON from {url_for_log(url)}: {e}")


def _check_blocked(status: int, headers: dict, body: bytes) -> None:
	ctype = headers.get("content-type", "")
	if headers.get("cf-mitigated") or (
		"text/html" in ctype and status in (403, 429, 503) and
		(b"Just a moment" in body[:20000] or b"challenge-platform" in body[:20000] or b"turnstile" in body[:20000])):
		raise BlockedError(f"bot challenge / access control (HTTP {status}); not bypassing")


def url_for_log(url: str) -> str:
	"""Never log download tokens."""
	url = re.sub(r"/screen/download/[^/?#\s]+", "/screen/download/<token>", url)
	return re.sub(r"eyJ[A-Za-z0-9_\-]+:[A-Za-z0-9_\-]+:[A-Za-z0-9_\-]+", "<token>", url)


def slug(text: str, max_len: int = 90) -> str:
	s = re.sub(r"[^A-Za-z0-9]+", "_", text or "").strip("_").lower()
	return (s[:max_len].rstrip("_")) or "untitled"


def now_iso() -> str:
	return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def as_int(v) -> int | None:
	try:
		return int(v)
	except (TypeError, ValueError):
		return None


def as_bool(v) -> bool:
	return v is True or str(v).lower() == "true"


# ---------------------------------------------------------------------------------------------------------------
# Enumeration
# ---------------------------------------------------------------------------------------------------------------

def search_all(http: Http, params: dict, order: str = "NEWEST") -> tuple[list[dict], int]:
	out, total, page = [], 0, 1
	while True:
		q = {"limit": PAGE_LIMIT, "page": page, "order": order, **params}
		d = http.get_json(f"{API}/assets/search/{PROJECT_ID}?" + urllib.parse.urlencode(q))
		if not d.get("success"):
			raise HttpError(200, f"search not successful for {params} page {page}")
		data = d.get("data") or []
		total = int(d.get("total") or 0)
		out.extend(data)
		if not d.get("hasMore") or not data:
			break
		page += 1
		if page > 1000:
			raise RuntimeError("pagination runaway")
	return out, total


def enumerate_assets(http: Http, log) -> dict:
	facets_raw = http.get_json(f"{API}/facette/list/{PROJECT_ID}").get("facettes") or []
	facets = {f["key"]: {"title": f.get("title", f["key"]), "values": [i["value"] for i in f.get("items", [])]}
		for f in facets_raw}
	log(f"facets: " + "; ".join(f"{k} ({v['title']}): {len(v['values'])} values" for k, v in facets.items()))

	assets: dict[int, dict] = {}
	all_list, total = search_all(http, {}, "NEWEST")
	for a in all_list:
		assets[int(a["id"])] = a
	log(f"search NEWEST: {len(all_list)} rows, {len(assets)} unique ids, API total {total}")
	if len(assets) < total:
		extra, _ = search_all(http, {}, "OLDEST")
		before = len(assets)
		for a in extra:
			assets.setdefault(int(a["id"]), a)
		log(f"search OLDEST pass added {len(assets) - before} ids (now {len(assets)})")

	tags: dict[int, dict[str, set]] = {i: {} for i in assets}
	facet_totals: dict[str, dict[str, int]] = {}
	only_in_facets = 0
	for key, f in facets.items():
		facet_totals[key] = {}
		for value in f["values"]:
			rows, t = search_all(http, {key: value}, "NEWEST")
			ids = {int(r["id"]) for r in rows}
			facet_totals[key][value] = t
			if len(ids) != t:
				log(f"  WARN facet {key}={value}: API total {t} but {len(ids)} unique ids returned")
			for r in rows:
				i = int(r["id"])
				if i not in assets:
					assets[i] = r
					only_in_facets += 1
				tags.setdefault(i, {}).setdefault(key, set()).add(value)
			log(f"  facet {key}={value}: {t}")
	if only_in_facets:
		log(f"WARN {only_in_facets} assets appeared only in facet queries (added)")
	return {"facets": facets, "assets": assets, "tags": tags, "api_total": total, "facet_totals": facet_totals}


# ---------------------------------------------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------------------------------------------

def inspect_image(data: bytes, ext: str, want_w: int | None, want_h: int | None) -> dict:
	"""Decode fully with Pillow; raise ValueError on any mismatch. Returns image facts for the index."""
	with Image.open(io.BytesIO(data)) as im:
		im.verify()
	with Image.open(io.BytesIO(data)) as im:
		fmt = im.format
		want_fmt = EXT_PIL.get(ext)
		if want_fmt and fmt != want_fmt:
			raise ValueError(f"format {fmt} != extension {ext}")
		frames = getattr(im, "n_frames", 1)
		im.load()
		w, h = im.size
		if want_w and want_h and (w, h) != (want_w, want_h):
			raise ValueError(f"dimensions {w}x{h} != metadata {want_w}x{want_h}")
		mode = im.mode
		has_alpha = mode in ("RGBA", "LA", "PA") or (mode == "P" and "transparency" in im.info) \
			or (mode in ("RGB", "L") and "transparency" in im.info)
		alpha_bbox = None
		if has_alpha:
			alpha = im.convert("RGBA").getchannel("A")
			bb = alpha.getbbox()
			alpha_bbox = list(bb) if bb else [0, 0, 0, 0]
	return {"format": fmt, "mode": mode, "frames": frames, "has_alpha": has_alpha, "alpha_bbox": alpha_bbox,
		"actual_width": w, "actual_height": h}


def sha256_bytes(b: bytes) -> str:
	return hashlib.sha256(b).hexdigest()


# ---------------------------------------------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------------------------------------------

class Downloader:
	def __init__(self, http: Http, files_dir: Path, resume: bool, prev: dict[int, dict], allow_cdn_fallback: bool):
		self.http = http
		self.files_dir = files_dir
		self.resume = resume
		self.prev = prev
		self.allow_cdn_fallback = allow_cdn_fallback
		self.lock = threading.Lock()
		self.bytes_new = 0

	def local_name(self, a: dict) -> str:
		ext = (a.get("ext") or "bin").lower()
		return f"{int(a['id'])}__{slug(a.get('title') or '')}.{ext}"

	def try_resume(self, a: dict, path: Path) -> dict | None:
		if not (self.resume and path.exists()):
			return None
		data = path.read_bytes()
		sha = sha256_bytes(data)
		p = self.prev.get(int(a["id"]))
		if p and p.get("sha256") == sha and p.get("modified") == a.get("modified") and p.get("status") == "ok":
			return {k: p[k] for k in ("sha256", "bytes", "format", "mode", "frames", "has_alpha", "alpha_bbox",
				"download_method") if k in p} | {"resumed": True}
		try:  # file exists but no matching index entry: re-verify it instead of re-downloading
			facts = inspect_image(data, (a.get("ext") or "").lower(), as_int(a.get("width")), as_int(a.get("height")))
		except Exception:
			return None
		method = (p or {}).get("download_method", "fankit_download_endpoint")
		return {"sha256": sha, "bytes": len(data), **facts, "download_method": method, "resumed": True}

	def fetch(self, a: dict, token: str | None, allow_fallback: bool = False) -> dict:
		"""Download + verify one asset. Returns {status: ok|failed, ...}."""
		ext = (a.get("ext") or "").lower()
		path = self.files_dir / self.local_name(a)
		r = self.try_resume(a, path)
		if r:
			return {"status": "ok", "path": path, **r}
		want_w, want_h = as_int(a.get("width")), as_int(a.get("height"))
		errors = []
		attempts = []
		if token:
			attempts.append(("fankit_download_endpoint", f"{API}/screen/download/{token}"))
		gen = (a.get("generic_url") or "").split("?")[0]
		if allow_fallback and self.allow_cdn_fallback and gen and ext == "png":
			attempts.append(("cdn_png_reencode_q100", gen + "?format=png&quality=100"))
		for method, url in attempts:
			try:
				status, headers, body = self.http.get(url)
			except BlockedError:
				raise
			except Exception as e:
				errors.append(f"{method}: {e}")
				continue
			if status != 200:
				errors.append(f"{method}: HTTP {status}")
				continue
			ctype = headers.get("content-type", "").split(";")[0].strip().lower()
			allowed = EXT_MIME.get(ext, ())
			if allowed and ctype not in allowed and ctype != "application/octet-stream":
				errors.append(f"{method}: content-type {ctype} not in {allowed}")
				continue
			try:
				facts = inspect_image(body, ext, want_w, want_h)
			except Exception as e:
				errors.append(f"{method}: verify failed: {e}")
				continue
			tmp = path.with_suffix(path.suffix + ".part")
			tmp.write_bytes(body)
			os.replace(tmp, path)
			with self.lock:
				self.bytes_new += len(body)
			return {"status": "ok", "path": path, "sha256": sha256_bytes(body), "bytes": len(body),
				"content_type": ctype, **facts, "download_method": method, "resumed": False}
		return {"status": "failed", "error": " | ".join(errors) or "no download route"}


# ---------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------

def guard_out(out: Path) -> Path:
	out = out.expanduser().resolve()
	try:
		out.relative_to(REPO_ROOT)
	except ValueError:
		return out
	sys.exit(f"refusing to write proprietary art inside the repository ({out}); use a private directory")


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
	ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"private storage root (default {DEFAULT_OUT})")
	ap.add_argument("--types", default="", help="comma-separated asset-type / characters values to download "
		"(e.g. 'Buildings,Fences'); enumeration and index always cover everything")
	ap.add_argument("--resume", dest="resume", action="store_true", default=True, help="skip verified files (default)")
	ap.add_argument("--no-resume", dest="resume", action="store_false", help="re-download everything")
	ap.add_argument("--dry-run", action="store_true", help="enumerate and report; download/write nothing")
	ap.add_argument("--workers", type=int, default=3, help="concurrent downloads (capped at 3)")
	ap.add_argument("--delay", type=float, default=0.3, help="pause after each request per worker (s)")
	ap.add_argument("--tries", type=int, default=5, help="attempts per request (exponential backoff)")
	ap.add_argument("--timeout", type=float, default=120.0)
	ap.add_argument("--include-non-image", action="store_true", help="also download non-image assets (unverified)")
	ap.add_argument("--no-cdn-fallback", action="store_true",
		help="do not fall back to a CDN PNG re-encode when the download endpoint fails")
	ap.add_argument("--limit", type=int, default=0, help="download at most N assets (testing)")
	args = ap.parse_args()

	out = guard_out(args.out)
	base = out / "raw" / "fankit"
	files_dir = base / "files"
	http = Http(args.delay, max(1, args.tries), args.timeout)
	t0 = time.time()

	def log(msg: str) -> None:
		print(f"[{time.time() - t0:7.1f}s] {msg}", flush=True)

	log(f"enumerating project {PROJECT_ID} at {PORTAL} ...")
	try:
		en = enumerate_assets(http, log)
	except BlockedError as e:
		log(f"BLOCKED during enumeration: {e}")
		if not args.dry_run:
			base.mkdir(parents=True, exist_ok=True)
			(base / "failed.json").write_text(json.dumps({"fetched_at": now_iso(), "blocked": str(e)}, indent=1))
		return 2
	assets, tags, facets = en["assets"], en["tags"], en["facets"]
	type_key = next((k for k in facets if k.startswith("asset-type")), None)
	char_key = next((k for k in facets if k.startswith("characters")), None)

	def types_of(i: int) -> list[str]:
		return sorted(tags.get(i, {}).get(type_key, set())) if type_key else []

	def chars_of(i: int) -> list[str]:
		return sorted(tags.get(i, {}).get(char_key, set())) if char_key else []

	want_types = {t.strip() for t in args.types.split(",") if t.strip()}
	known_values = {v for f in facets.values() for v in f["values"]}
	unknown = want_types - known_values
	if unknown:
		sys.exit(f"unknown --types {sorted(unknown)}; known: {sorted(known_values)}")

	def selected(i: int, a: dict) -> bool:
		if not (as_bool(a.get("is_image")) or args.include_non_image):
			return False
		if want_types and not (want_types & (set(types_of(i)) | set(chars_of(i)))):
			return False
		return True

	sel = [i for i in sorted(assets) if selected(i, assets[i])]
	if args.limit:
		sel = sel[:args.limit]
	non_image = [i for i in assets if not as_bool(assets[i].get("is_image"))]
	est = sum((as_int(assets[i].get("file_size")) or 0) for i in sel) * 1024
	exts = {}
	for i in assets:
		exts[assets[i].get("ext")] = exts.get(assets[i].get("ext"), 0) + 1
	log(f"listed {len(assets)} assets (API total {en['api_total']}); non-image {len(non_image)}; "
		f"ext {exts}; selected {len(sel)}; est. ~{est / 1e6:.1f} MB (metadata file_size is KiB)")
	untagged = sum(1 for i in assets if not types_of(i))
	log(f"assets without any asset-type tag: {untagged}")
	if args.dry_run:
		log("dry run: nothing downloaded or written")
		return 0

	files_dir.mkdir(parents=True, exist_ok=True)
	prev: dict[int, dict] = {}
	idx_path = base / "index.json"
	if idx_path.exists():
		try:
			prev = {int(e["id"]): e for e in json.loads(idx_path.read_text()).get("assets", [])}
		except Exception as e:
			log(f"WARN could not read previous index: {e}")

	dl = Downloader(http, files_dir, args.resume, prev, not args.no_cdn_fallback)
	results: dict[int, dict] = {}
	blocked: str | None = None

	def run_batch(ids: list[int], token_map: dict[int, str], allow_fallback: bool) -> None:
		nonlocal blocked
		done = 0
		with cf.ThreadPoolExecutor(max_workers=max(1, min(args.workers, MAX_WORKERS))) as ex:
			futs = {ex.submit(dl.fetch, assets[i], token_map.get(i), allow_fallback): i for i in ids}
			for fut in cf.as_completed(futs):
				i = futs[fut]
				try:
					results[i] = fut.result()
				except BlockedError as e:
					blocked = str(e)
					results[i] = {"status": "failed", "error": f"blocked: {e}"}
					for f in futs:
						f.cancel()
				except Exception as e:
					results[i] = {"status": "failed", "error": f"{type(e).__name__}: {e}"}
				done += 1
				if done % 100 == 0 or done == len(ids):
					ok = sum(1 for j in ids if results.get(j, {}).get("status") == "ok")
					log(f"  {done}/{len(ids)} processed, ok {ok}, new bytes {dl.bytes_new / 1e6:.1f} MB, "
						f"requests {http.requests}, retries {http.retries}")
				if done % 250 == 0:
					write_index(partial=True)

	def write_index(partial: bool = False) -> dict:
		rows, failed = [], []
		for i in sorted(assets):
			a = assets[i]
			r = results.get(i)
			row = {
				"id": i, "title": a.get("title"), "types": types_of(i), "characters": chars_of(i),
				"ext": (a.get("ext") or "").lower(), "width": as_int(a.get("width")), "height": as_int(a.get("height")),
				"file_size": as_int(a.get("file_size")), "file_size_unit": "KiB (Frontify metadata)",
				"object_type": a.get("object_type"), "is_image": as_bool(a.get("is_image")),
				"url": (a.get("generic_url") or "").split("?")[0] or None,
				"created": a.get("created"), "modified": a.get("modified"),
			}
			alt = a.get("computed_alternative_text")
			if alt and alt != a.get("title"):
				row["alt_text"] = alt
			if a.get("description"):
				row["description"] = a.get("description")
			if r is None:
				row["status"] = "not_selected" if i not in sel_set else "pending"
				p = prev.get(i)
				if p and p.get("status") == "ok" and (files_dir / Path(p.get("local_path", "")).name).exists():
					row.update({k: p[k] for k in ("sha256", "bytes", "local_path", "format", "mode", "frames",
						"has_alpha", "alpha_bbox", "download_method") if k in p})
					row["status"] = "ok"
			elif r["status"] == "ok":
				row.update({
					"status": "ok", "sha256": r["sha256"], "bytes": r["bytes"],
					"local_path": str(r["path"].relative_to(base)),
					"format": r.get("format"), "mode": r.get("mode"), "frames": r.get("frames"),
					"has_alpha": r.get("has_alpha"), "alpha_bbox": r.get("alpha_bbox"),
					"download_method": r.get("download_method"),
				})
			else:
				row["status"] = r["status"]
				row["error"] = url_for_log(r.get("error") or "")
				failed.append({"id": i, "title": a.get("title"), "url": row["url"], "error": row["error"]})
			rows.append(row)
		ok_rows = [r for r in rows if r["status"] == "ok"]
		by_sha: dict[str, list[int]] = {}
		for r in ok_rows:
			by_sha.setdefault(r["sha256"], []).append(r["id"])
		dups = {s: ids for s, ids in by_sha.items() if len(ids) > 1}
		totals = {v: 0 for v in (facets.get(type_key, {}).get("values", []) if type_key else [])}
		ok_totals = dict.fromkeys(totals, 0)
		for r in rows:
			for t in r["types"]:
				totals[t] = totals.get(t, 0) + 1
				if r["status"] == "ok":
					ok_totals[t] = ok_totals.get(t, 0) + 1
		ch_totals: dict[str, int] = {}
		for r in rows:
			for c in r["characters"]:
				ch_totals[c] = ch_totals.get(c, 0) + 1
		index = {
			"source": SOURCE, "project_id": PROJECT_ID, "portal": PORTAL, "fetched_at": now_iso(),
			"partial": partial,
			"note": "PROPRIETARY Supercell art for personal use only. Never commit or redistribute. "
				"Files come from the portal's download endpoint (byte-original) unless download_method says "
				"otherwise. Download tokens are deliberately not stored.",
			"facets": facets,
			"api_total": en["api_total"], "api_totals_by_facet": en["facet_totals"],
			"listed": len(rows), "downloaded_ok": len(ok_rows), "failed": len(failed),
			"total_bytes": sum(r.get("bytes") or 0 for r in ok_rows),
			"totals_by_type": totals, "downloaded_by_type": ok_totals, "totals_by_character_group": ch_totals,
			"untagged": sum(1 for r in rows if not r["types"]),
			"duplicates_by_sha256": [{"sha256": s, "ids": ids} for s, ids in sorted(dups.items())],
			"assets": rows,
		}
		tmp = idx_path.with_suffix(".json.part")
		tmp.write_text(json.dumps(index, indent=1, ensure_ascii=False))
		os.replace(tmp, idx_path)
		fp = base / "failed.json"
		fp.write_text(json.dumps({"fetched_at": now_iso(), "blocked": blocked, "failed": failed}, indent=1,
			ensure_ascii=False))
		return index

	sel_set = set(sel)
	tokens = {i: assets[i].get("token") for i in sel}
	log(f"downloading {len(sel)} assets with {min(args.workers, MAX_WORKERS)} workers ...")
	try:
		run_batch(sel, tokens, allow_fallback=False)
		# Download tokens are minted per search request and may expire: refresh them and retry once; only then
		# allow the (pixel-exact, not byte-original) CDN PNG re-encode as a last resort.
		retry = [i for i in sel if results.get(i, {}).get("status") == "failed"] if not blocked else []
		if retry:
			log(f"{len(retry)} failed; refreshing tokens and retrying once ...")
			fresh, _ = search_all(http, {}, "NEWEST")
			fresh_tokens = {int(a["id"]): a.get("token") for a in fresh}
			for a in fresh:
				if int(a["id"]) in assets:
					assets[int(a["id"])].update({k: v for k, v in a.items() if k != "token"})
			run_batch(retry, fresh_tokens, allow_fallback=True)
	except KeyboardInterrupt:
		log("interrupted; writing partial index")
		write_index(partial=True)
		return 130
	index = write_index(partial=False)
	log(f"done: listed {index['listed']}, ok {index['downloaded_ok']}, failed {index['failed']}, "
		f"bytes {index['total_bytes']}, dup groups {len(index['duplicates_by_sha256'])}, "
		f"requests {http.requests}, retries {http.retries}" + (f", BLOCKED: {blocked}" if blocked else ""))
	log(f"index: {idx_path}")
	return 0 if not index["failed"] and not blocked else 1


if __name__ == "__main__":
	sys.exit(main())
