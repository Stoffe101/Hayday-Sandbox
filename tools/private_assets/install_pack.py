#!/usr/bin/env python3
"""Install a built asset pack (folder or .zip) into Hayday Sandbox's user folder, outside any git repository.

  python tools/private_assets/install_pack.py <pack folder | pack.zip | pack.hdpack.zip> [options]
  python tools/private_assets/install_pack.py --find-in <private root>        # newest built pack under <root>

Destination (the folder the app reads, ``user://asset_packs/<pack id>/``):
  Windows  %APPDATA%\\HaydaySandbox\\asset_packs\\<id>
  Linux    ~/.local/share/HaydaySandbox/asset_packs/<id>   ($XDG_DATA_HOME honoured)
  macOS    ~/Library/Application Support/HaydaySandbox/asset_packs/<id>
or ``--dest <folder>`` (the pack folder itself) / ``--dest-root <asset_packs folder>``.

What it does
  * finds pack.json at the root of the folder/zip or exactly one folder deep (same rule as the in-app installer);
  * validates it: format "hayday-sandbox-asset-pack", a safe id, a "sprites" object, safe relative file paths
    (sprites and the optional "world" / "catalog_overrides" / "terrain" data files), anchors as [x, y]; counts
    referenced files that are missing (warning; an error with --strict);
  * refuses a destination inside a git work tree (private art must never land in a repository);
  * skips unsafe zip entries (absolute paths, '..', symlinks), copies/extracts into a hidden temporary folder next to
    the destination and swaps it into place, so an interrupted install never leaves a half-written pack; the
    previous version is removed only after the swap; your overrides.json (review work done in the app) is kept
    when the new pack does not ship one;
  * records the install in <private root>/.leakcheck/installed_packs.json (when a private root exists) so the
    git leak guard (tools/ci/check_private_leaks.py) also knows these images.

The in-app alternative is Settings -> "Install asset pack (.zip)..." or ``godot --path . -- --install-pack=<zip>``.
Personal use only: never commit, share or upload the pack. See docs/PRIVATE_ASSETS.md.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parents[1]
PACK_FORMAT = "hayday-sandbox-asset-pack"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
KEEP_FILES = ("overrides.json",)
WORLD_FIELDS = ("world", "catalog_overrides", "terrain")   # optional pack-level JSON files (map v2 world, overrides)


class PackError(RuntimeError):
	pass


def godot_user_dir() -> Path:
	if os.name == "nt":
		return Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))) / "HaydaySandbox"
	if sys.platform == "darwin":
		return Path.home() / "Library" / "Application Support" / "HaydaySandbox"
	return Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share")) / "HaydaySandbox"


def default_private_roots() -> list[Path]:
	c = []
	if os.environ.get("HAYDAY_PRIVATE_ASSETS"):
		c.append(Path(os.environ["HAYDAY_PRIVATE_ASSETS"]).expanduser())
	if os.name == "nt" and os.environ.get("USERPROFILE"):
		c.append(Path(os.environ["USERPROFILE"]) / "hayday-sandbox-private-assets")
	c += [Path.home() / "hayday-sandbox-private-assets", Path("/root/hayday-sandbox-private-assets")]
	return [p for p in c if p.is_dir()]


def git_worktree_of(p: Path) -> Path | None:
	p = p.expanduser().resolve()
	for parent in [p, *p.parents]:
		if (parent / ".git").exists():
			return parent
	try:
		probe = next(q for q in [p, *p.parents] if q.exists())
		r = subprocess.run(["git", "-C", str(probe), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
		if r.returncode == 0 and r.stdout.strip():
			return Path(r.stdout.strip())
	except (StopIteration, OSError):
		pass
	return None


def safe_rel(name: str) -> str | None:
	"""Normalised safe relative POSIX path, or None for absolute / parent-escaping / drive paths."""
	n = name.replace("\\", "/")
	if not n or n.startswith("/") or re.match(r"^[A-Za-z]:", n):
		return None
	parts = [p for p in PurePosixPath(n).parts if p not in ("", ".")]
	if not parts or any(p == ".." for p in parts):
		return None
	return "/".join(parts)


def referenced_files(pack: dict) -> tuple[list[str], list[str]]:
	"""(files, problems) for every file a pack.json references."""
	files: list[str] = []
	probs: list[str] = []

	def add(key: str, entry: dict, field: str = "file", required: bool = True) -> None:
		v = entry.get(field)
		if v is None:
			if required:
				probs.append(f"{key}: missing '{field}'")
			return
		if not isinstance(v, str) or safe_rel(v) is None:
			probs.append(f"{key}: unsafe or invalid {field} {v!r}")
			return
		files.append(safe_rel(v))

	def anchor(key: str, e: dict) -> None:
		a = e.get("anchor")
		if a is not None and not (isinstance(a, list) and len(a) == 2 and all(isinstance(x, (int, float)) for x in a)):
			probs.append(f"{key}: anchor must be [x, y], got {a!r}")

	# pack-level data files (private world data written by build_world.py): safe relative paths, counted like images
	for field in WORLD_FIELDS:
		if field in pack:
			add(f"pack.{field}", pack, field)
	for key, e in pack["sprites"].items():
		if not isinstance(e, dict):
			probs.append(f"{key}: sprite entry must be an object")
			continue
		add(key, e)
		add(key, e, "thumb", required=False)
		anchor(key, e)
		if isinstance(e.get("shadow"), dict):
			add(f"{key}.shadow", e["shadow"])
		for sub in ("variants", "connections"):
			block = e.get(sub)
			if block is None:
				continue
			if not isinstance(block, dict):
				probs.append(f"{key}: '{sub}' must be an object")
				continue
			for vid, ve in block.items():
				if not isinstance(ve, dict):
					probs.append(f"{key}.{sub}.{vid}: must be an object")
					continue
				add(f"{key}.{sub}.{vid}", ve)
				add(f"{key}.{sub}.{vid}", ve, "thumb", required=False)
				anchor(f"{key}.{sub}.{vid}", ve)
	return files, probs


def validate_pack_json(data: bytes) -> tuple[dict, list[str]]:
	try:
		pack = json.loads(data.decode("utf-8-sig"))
	except (UnicodeDecodeError, ValueError) as ex:
		raise PackError(f"pack.json is not valid JSON: {ex}")
	if not isinstance(pack, dict):
		raise PackError("pack.json must be a JSON object")
	if pack.get("format") != PACK_FORMAT:
		raise PackError(f"pack.json format is {pack.get('format')!r}, expected {PACK_FORMAT!r}")
	pid = pack.get("id")
	if not isinstance(pid, str) or not ID_RE.match(pid):
		raise PackError(f"pack id {pid!r} is not a safe folder name (lowercase letters, digits, _ . -)")
	if not isinstance(pack.get("sprites"), dict):
		raise PackError("pack.json has no 'sprites' object")
	sv = pack.get("schema_version", 1)
	if not isinstance(sv, int) or sv < 1:
		raise PackError(f"bad schema_version {sv!r}")
	files, probs = referenced_files(pack)
	if probs:
		raise PackError("pack.json problems:\n  " + "\n  ".join(probs[:20]) + (f"\n  ... {len(probs) - 20} more"
			if len(probs) > 20 else ""))
	return pack, files


# ---- sources -----------------------------------------------------------------------------------------------

class FolderSource:
	def __init__(self, folder: Path):
		cands = [folder] if (folder / "pack.json").is_file() else \
			[d for d in folder.iterdir() if d.is_dir() and (d / "pack.json").is_file()]
		if len(cands) != 1:
			raise PackError(f"{folder}: expected pack.json at the top or exactly one folder deep "
				f"(found {len(cands)})")
		self.base = cands[0]
		self.label = str(self.base)

	def pack_json(self) -> bytes:
		return (self.base / "pack.json").read_bytes()

	def members(self) -> list[str]:
		out = []
		for dirpath, dirnames, filenames in os.walk(self.base):
			dirnames[:] = [d for d in dirnames if not d.startswith(".")]
			for fn in filenames:
				p = Path(dirpath) / fn
				if p.is_symlink():
					continue
				out.append(p.relative_to(self.base).as_posix())
		return out

	def extract(self, rel: str, dest: Path) -> None:
		dest.parent.mkdir(parents=True, exist_ok=True)
		shutil.copy2(self.base / rel, dest)


class ZipSource:
	def __init__(self, path: Path):
		self.z = zipfile.ZipFile(path)
		self.label = str(path)
		names = [n for n in self.z.namelist() if not n.endswith("/")]
		if "pack.json" in names:
			self.prefix = ""
		else:
			deep = sorted({n.split("/")[0] for n in names if n.count("/") == 1 and n.endswith("/pack.json")})
			if len(deep) != 1:
				raise PackError(f"{path}: expected pack.json at the zip root or exactly one folder deep "
					f"(found {len(deep)})")
			self.prefix = deep[0] + "/"
		self.skipped: list[str] = []

	def pack_json(self) -> bytes:
		return self.z.read(self.prefix + "pack.json")

	def members(self) -> list[str]:
		out = []
		for info in self.z.infolist():
			n = info.filename
			if n.endswith("/") or not n.startswith(self.prefix):
				continue
			rel = safe_rel(n[len(self.prefix):])
			is_link = stat.S_ISLNK(info.external_attr >> 16)
			if rel is None or is_link:
				self.skipped.append(n)
				continue
			if any(p.startswith(".") for p in rel.split("/")[:-1]):
				continue
			out.append(rel)
		return out

	def extract(self, rel: str, dest: Path) -> None:
		dest.parent.mkdir(parents=True, exist_ok=True)
		with self.z.open(self.prefix + rel) as src, open(dest, "wb") as dst:
			shutil.copyfileobj(src, dst, 1 << 20)

	def total_size(self) -> int:
		return sum(i.file_size for i in self.z.infolist() if i.filename.startswith(self.prefix))


def open_source(src: Path):
	if src.is_dir():
		return FolderSource(src)
	if src.is_file() and zipfile.is_zipfile(src):
		return ZipSource(src)
	raise PackError(f"{src}: not a pack folder or a zip file")


def find_built_pack(root: Path) -> Path:
	"""Newest pack under a private root: packs/*/pack.json, dist/*.zip, or any */pack.json two levels deep."""
	cands: list[Path] = []
	for pattern in ("packs/*/pack.json", "dist/*.zip", "*/pack.json", "out/*/pack.json", "build/*/pack.json"):
		for p in root.glob(pattern):
			cands.append(p.parent if p.name == "pack.json" else p)
	if not cands:
		raise PackError(f"no built pack found under {root} (looked for packs/*/pack.json, dist/*.zip)")
	return max(cands, key=lambda p: (p / "pack.json").stat().st_mtime if p.is_dir() else p.stat().st_mtime)


# ---- install -----------------------------------------------------------------------------------------------

def record_install(dest: Path, pack_id: str, roots: list[Path]) -> None:
	for root in roots[:1]:
		f = root / ".leakcheck" / "installed_packs.json"
		try:
			doc = json.loads(f.read_text(encoding="utf-8")) if f.is_file() else {}
		except (OSError, ValueError):
			doc = {}
		packs = doc.get("packs") if isinstance(doc.get("packs"), list) else []
		if str(dest) not in packs:
			packs.append(str(dest))
		doc.update({"format": "hayday-sandbox-installed-packs", "packs": packs, "updated": dt.datetime.now(
			dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
		f.parent.mkdir(parents=True, exist_ok=True)
		tmp = f.with_suffix(f".tmp{os.getpid()}")
		tmp.write_text(json.dumps(doc, indent=1), encoding="utf-8")
		os.replace(tmp, f)


def install(src_path: Path, dest: Path | None, dest_root: Path | None, strict: bool, dry_run: bool,
		private_roots: list[Path], log=print) -> dict:
	source = open_source(src_path)
	pack, files = validate_pack_json(source.pack_json())
	pid = pack["id"]
	if dest is None:
		dest = (dest_root or (godot_user_dir() / "asset_packs")) / pid
	dest = dest.expanduser().resolve()
	if dest.name != pid:
		log(f"note: pack id is '{pid}' but the destination folder is '{dest.name}'")
	wt = git_worktree_of(dest)
	if wt is not None or dest == REPO_ROOT or REPO_ROOT in dest.parents:
		raise PackError(f"refusing to install into {dest}: it is inside a git work tree ({wt or REPO_ROOT}). "
			"Private art must never land in a repository.")
	src_real = (source.base if isinstance(source, FolderSource) else src_path).resolve()
	if dest == src_real or src_real in dest.parents:
		raise PackError(f"destination {dest} is inside the source {src_real}")
	members = source.members()
	have = set(members)
	missing = sorted(set(files) - have)
	images = sum(1 for m in members if m.lower().endswith((".png", ".webp", ".jpg", ".jpeg")))
	info = {"id": pid, "version": pack.get("version"), "sprites": len(pack["sprites"]), "files": len(members),
		"images": images, "missing": len(missing), "dest": str(dest), "source": source.label,
		"skipped_unsafe": len(getattr(source, "skipped", []))}
	if missing:
		msg = f"{len(missing)} referenced file(s) are missing from the pack, e.g. {missing[:3]}"
		if strict:
			raise PackError(msg)
		log("warning: " + msg + " (the app falls back to placeholder art for those)")
	if info["skipped_unsafe"]:
		log(f"warning: skipped {info['skipped_unsafe']} unsafe zip entr(y/ies): {source.skipped[:3]}")
	if dry_run:
		log(f"DRY RUN: would install pack '{pid}' ({info['sprites']} sprites, {info['files']} files) into {dest}")
		return info
	dest.parent.mkdir(parents=True, exist_ok=True)
	need = source.total_size() if isinstance(source, ZipSource) else sum((source.base / m).stat().st_size
		for m in members)
	free = shutil.disk_usage(dest.parent).free
	if need > free:
		raise PackError(f"not enough disk space: need {need / 1e6:.0f} MB, {free / 1e6:.0f} MB free")
	stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
	tmp = dest.parent / f".{pid}.installing-{os.getpid()}"
	old = dest.parent / f".{pid}.old-{stamp}"
	if tmp.exists():
		shutil.rmtree(tmp)
	try:
		for m in members:
			source.extract(m, tmp / m)
		for keep in KEEP_FILES:
			if (dest / keep).is_file() and not (tmp / keep).exists():
				shutil.copy2(dest / keep, tmp / keep)
				log(f"kept your existing {keep}")
		moved_old = False
		if dest.exists():
			os.replace(dest, old)
			moved_old = True
		try:
			os.replace(tmp, dest)
		except OSError:
			if moved_old:
				os.replace(old, dest)
			raise
		if moved_old:
			shutil.rmtree(old, ignore_errors=True)
	finally:
		if tmp.exists():
			shutil.rmtree(tmp, ignore_errors=True)
	record_install(dest, pid, private_roots)
	log(f"installed pack '{pid}' v{info['version']}: {info['sprites']} sprites, {info['files']} files "
		f"({images} images) -> {dest}")
	return info


def main(argv: list[str] | None = None) -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
		formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
	ap.add_argument("source", nargs="?", type=Path, help="pack folder, .zip or .hdpack.zip")
	ap.add_argument("--find-in", type=Path, help="use the newest built pack under this private root")
	g = ap.add_mutually_exclusive_group()
	g.add_argument("--dest", type=Path, help="destination pack folder (default <user dir>/asset_packs/<id>)")
	g.add_argument("--dest-root", type=Path, help="destination asset_packs folder")
	ap.add_argument("--strict", action="store_true", help="fail when referenced files are missing")
	ap.add_argument("--dry-run", action="store_true", help="validate and report; install nothing")
	ap.add_argument("--self-test", action="store_true")
	args = ap.parse_args(argv)
	if args.self_test:
		return self_test()
	try:
		src = args.source or (find_built_pack(args.find_in.expanduser().resolve()) if args.find_in else None)
		if src is None:
			ap.error("give a pack folder/zip or --find-in <private root>")
		install(src.expanduser().resolve(), args.dest, args.dest_root, args.strict, args.dry_run,
			default_private_roots())
	except (PackError, zipfile.BadZipFile, OSError) as ex:
		print(f"install_pack: error: {ex}", file=sys.stderr)
		return 1
	return 0


def self_test() -> int:
	fails: list[str] = []
	tmp = Path(tempfile.mkdtemp(prefix="install-pack-selftest-"))
	quiet = lambda *_a, **_k: None  # noqa: E731
	try:
		def make_pack(folder: Path, pid: str = "hayday_original", extra: dict | None = None) -> Path:
			(folder / "items").mkdir(parents=True, exist_ok=True)
			(folder / "items" / "bakery.png").write_bytes(b"\x89PNG\r\n\x1a\n-test-")
			doc = {"format": PACK_FORMAT, "schema_version": 1, "id": pid, "version": "1",
				"sprites": {"bakery": {"file": "items/bakery.png", "anchor": [10, 20],
					"variants": {"w": {"file": "items/bakery.png"}}}}}
			doc.update(extra or {})
			(folder / "pack.json").write_text(json.dumps(doc))
			return folder

		user = tmp / "user" / "asset_packs"
		priv = tmp / "private"
		priv.mkdir()
		src = make_pack(tmp / "build" / "hayday_original")
		info = install(src, None, user, False, False, [priv], quiet)
		if not (user / "hayday_original" / "items" / "bakery.png").is_file() or info["sprites"] != 1:
			fails.append(f"folder install: {info}")
		(user / "hayday_original" / "overrides.json").write_text('{"version": 1}')
		z = tmp / "pack.hdpack.zip"
		with zipfile.ZipFile(z, "w") as zf:
			for p in src.rglob("*"):
				if p.is_file():
					zf.write(p, "hayday_original/" + p.relative_to(src).as_posix())
			zf.writestr("hayday_original/../../evil.txt", "x")
			zf.writestr("/abs.txt", "x")
		info = install(z, None, user, False, False, [priv], quiet)
		if info["skipped_unsafe"] < 1 or (tmp / "evil.txt").exists() or (tmp / "user" / "evil.txt").exists():
			fails.append(f"unsafe zip entries must be skipped: {info}")
		if not (user / "hayday_original" / "overrides.json").is_file():
			fails.append("overrides.json must be kept on update")
		if [p.name for p in user.iterdir() if p.name.startswith(".")]:
			fails.append(f"temporary folders left: {list(user.iterdir())}")
		recf = priv / ".leakcheck" / "installed_packs.json"
		rec = json.loads(recf.read_text()) if recf.is_file() else {"packs": []}
		if str((user / "hayday_original").resolve()) not in rec["packs"]:
			fails.append(f"install not recorded for the leak guard: {rec}")
		repo = tmp / "repo"
		(repo / ".git").mkdir(parents=True)
		try:
			install(src, repo / "packs" / "hayday_original", None, False, False, [priv], quiet)
			fails.append("install into a git work tree must be refused")
		except PackError as ex:
			if "git work tree" not in str(ex):
				fails.append(f"wrong refusal: {ex}")
		for bad, why in ((make_pack(tmp / "b1", extra={"format": "other"}), "format"),
				(make_pack(tmp / "b2", pid="../evil"), "id"),
				(make_pack(tmp / "b3", extra={"sprites": {"x": {"file": "../../etc/passwd"}}}), "unsafe"),
				(make_pack(tmp / "b4", extra={"sprites": {"x": {"file": "a.png", "anchor": [1]}}}), "anchor")):
			try:
				install(bad, None, user, False, True, [priv], quiet)
				fails.append(f"bad pack ({why}) must be rejected")
			except PackError as ex:
				if why not in str(ex):
					fails.append(f"bad pack ({why}) rejected for the wrong reason: {ex}")
		try:
			install(make_pack(tmp / "b5", extra={"world": "../world.json"}), None, user, False, True, [priv], quiet)
			fails.append("an unsafe world path must be rejected")
		except PackError as ex:
			if "unsafe" not in str(ex):
				fails.append(f"unsafe world path rejected for the wrong reason: {ex}")
		wpack = make_pack(tmp / "w1", extra={"world": "world/world.json", "catalog_overrides": "catalog_overrides.json"})
		(wpack / "world").mkdir()
		(wpack / "world" / "world.json").write_text('{"format": "hayday-sandbox-map", "schema_version": 2}')
		if install(wpack, None, user, False, True, [priv], quiet)["missing"] != 1:
			fails.append("a declared but missing catalog_overrides.json must be counted as missing")
		miss = make_pack(tmp / "m1", extra={"sprites": {"x": {"file": "items/nope.png"}}})
		if install(miss, None, user, False, True, [priv], quiet)["missing"] != 1:
			fails.append("missing files must be counted")
		try:
			install(miss, None, user, True, True, [priv], quiet)
			fails.append("--strict must fail on missing files")
		except PackError:
			pass
		(priv / "packs").mkdir()
		built = make_pack(priv / "packs" / "hayday_original")
		if find_built_pack(priv) != built:
			fails.append("find_built_pack should find packs/<id>")
		r = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--find-in", str(priv), "--dest-root",
			str(user), "--dry-run"], capture_output=True, text=True)
		if r.returncode != 0 or "DRY RUN" not in r.stdout:
			fails.append(f"cli --find-in dry run: rc={r.returncode} {r.stdout} {r.stderr}")
	finally:
		shutil.rmtree(tmp, ignore_errors=True)
	for f in fails:
		print("SELF-TEST FAIL:", f)
	print(f"install_pack self-test: {'OK' if not fails else f'{len(fails)} failure(s)'}")
	return 1 if fails else 0


if __name__ == "__main__":
	sys.exit(main())
