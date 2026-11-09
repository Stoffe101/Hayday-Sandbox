#!/usr/bin/env python3
"""Private-art leak guard: make sure proprietary Hay Day art never enters git.

The user may keep ORIGINAL Hay Day art for personal use in a private folder (default
``/root/hayday-sandbox-private-assets`` or ``~/hayday-sandbox-private-assets``) and in the app's user folder
(``.../HaydaySandbox/asset_packs/hayday_original``). None of it may ever be committed, pushed or uploaded. This
tool is the guard. See docs/PRIVATE_ASSETS.md.

Modes (pick one; default = the whole tracked tree as recorded in the git index, which is what CI checks):
  (default)            every tracked file (``git ls-files``), contents read from the index
  --include-untracked  ... plus untracked files that are not git-ignored (local pre-flight)
  --staged             only files staged for the next commit (pre-commit hook; contents = staged blobs)
  --range "REVS"       every file version added/changed by the commits ``git rev-list REVS`` lists (pre-push hook)
  --rev REV            the whole tree of one commit
  --paths P [P ...]    plain files/directories on disk (no git); add --artifact for CI artifact folders
                       (screenshots allowed there) instead of repository rules
  --self-test          run the built-in tests in temporary directories and exit

Rules (each failure prints the rule id, the path and what to do):
  media-outside-public  image/audio/video file outside assets/placeholders/items/, assets/ui/, docs/screenshots/
  archive               archives (zip/7z/rar/tar/gz/...) anywhere; also a file whose CONTENT is an archive
  prohibited-type       game/package formats anywhere: .zip .xapk .apk .apks .aab .obb .ipa .sc .sctx .ktx .zktx
                        .pvr .astc .pck (+ .hdpack.zip)
  disguised-media       a file whose bytes are an image/audio/video/archive although its extension says otherwise
  private-path          path contains private-assets, hayday_original, raw/fankit, raw/wiki, an asset_packs/
                        folder, or is inside assets/original/ (README.md/.gdignore excepted)
  official-art-name     image named like official art: 'hayday_'/'hayday-'/'hay_day' prefix, '<digits>__hayday',
                        'fankit' or 'supercell' anywhere in the name (applies inside the public folders too)
  too-large             any file > 5 MB
  fankit-token          Fan Kit download tokens / signed download URLs, or media.ffycdn.net URLs together with a
                        "token": "..." JSON field; many ffycdn URLs in one file (an index dump)
  private-index         a .json file that is one of the private acquisition indexes
  private-hash          a file whose SHA-256 or SHA-1 equals a file known to the private storage:
                        <root>/raw/**/index.json, <root>/packs/**/hashes.json, any other hashes.json there, and
                        (cached) hashes of every image under the private roots and the installed private pack, plus
                        every other file (64 B - 5 MB: game data CSVs, fonts, indexes, pack manifests, mapping DBs)
                        under <root>/raw/, packs/, mapping/, dashboard/ and the installed private packs (generic
                        LICENSE/README/NOTICE files excepted). Every checked file >= 64 B (text too) and every
                        image/binary is compared.
                        Only runs where such a private root exists (never in CI).
  symlink               a symlink that points outside the repository or at private storage

Exit status: 0 = clean, 1 = problems found, 2 = usage/internal error.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import dataclasses
import hashlib
import json
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable, Iterator

REPO_ROOT = Path(__file__).resolve().parents[2]
MAX_FILE_BYTES = 5 * 1024 * 1024
ALLOWED_MEDIA_DIRS = ("assets/placeholders/items/", "assets/ui/", "docs/screenshots/")
IMAGE_EXT = {".png", ".webp", ".jpg", ".jpeg", ".gif", ".bmp", ".tga", ".ico", ".tif", ".tiff", ".svg", ".psd",
             ".avif", ".heic", ".heif", ".jxl", ".dds", ".exr", ".hdr", ".ctex", ".stex", ".basis", ".ktx2"}
AUDIO_EXT = {".wav", ".mp3", ".ogg", ".oga", ".flac", ".m4a", ".aac", ".opus", ".wma", ".aif", ".aiff", ".mid",
             ".midi", ".caf", ".bnk", ".fsb"}
VIDEO_EXT = {".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v", ".wmv", ".flv", ".ogv", ".mpg", ".mpeg", ".ivf"}
ARCHIVE_EXT = {".7z", ".rar", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".zst", ".lz4", ".lzma", ".cab", ".iso",
               ".dmg", ".jar", ".war", ".cpio"}
PROHIBITED_EXT = {".zip", ".xapk", ".apk", ".apks", ".apkm", ".aab", ".obb", ".ipa", ".sc", ".sctx", ".ktx",
                  ".zktx", ".pvr", ".astc", ".pck"}
PRIVATE_SUBSTRINGS = ("private-assets", "hayday_original")
PRIVATE_DIR_RE = re.compile(r"(^|/)raw/(fankit|wiki)", re.I)
OFFICIAL_NAME_RE = re.compile(r"^(hay[ _-]?day[ _-]|\d+__hay[ _-]?day)|fankit|fan[ _-]kit|supercell", re.I)
# Fan Kit (Frontify) download tokens look like eyJ...:...:... ; never store or commit them.
FANKIT_TOKEN_RE = re.compile(r"eyJ[A-Za-z0-9_\-]{8,}:[A-Za-z0-9_\-]{8,}:[A-Za-z0-9_\-]{8,}")
DOWNLOAD_URL_RE = re.compile(r"/screen/download/[A-Za-z0-9_\-:.%]{16,}")
FFY_URL_RE = re.compile(r"https?://media\.ffycdn\.net/[^\s\"'<>)\]]+", re.I)
FFY_SIGNED_RE = re.compile(r"media\.ffycdn\.net/[^\s\"'<>]*[?&](token|signature|sig|expires|key-pair-id|policy)=",
                           re.I)
TOKEN_FIELD_RE = re.compile(r"\"token\"\s*:\s*\"[^\"\s<>{}]{8,}\"")
PRIVATE_INDEX_RE = re.compile(r"\"(private_use_only|download_method|sha1_local)\"\s*:")
FFY_INDEX_THRESHOLD = 20
HEX_RE = re.compile(r"^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$")
SWEEP_SKIP_DIRS = {".leakcheck", ".venv", "venv", "__pycache__", ".git"}
CACHE_DIR = ".leakcheck"
# Besides images, the sweep hashes EVERY file where acquired/proprietary content lives (game data CSVs, fonts,
# private indexes, pack manifests, mapping DBs ...): <root>/raw/**, packs/**, mapping/**, dashboard/** and the
# installed private packs. Tiny files and generic licence/readme files are skipped so that trivial or widely shared
# content cannot cause false matches.
SWEEP_ALL_FILES_UNDER = ("raw/", "packs/", "mapping/", "dashboard/")
MIN_HASHED_NONMEDIA_BYTES = 64
GENERIC_NAME_RE = re.compile(r"^(licen[cs]e|notice|copying|readme|authors|third[_-]?party)", re.I)


# ---------------------------------------------------------------------------------------------------------------
# Defaults for where private art lives (local machine only)
# ---------------------------------------------------------------------------------------------------------------

def _is_dir(p: Path) -> bool:
    """Path.is_dir() that treats an unreadable location as absent (e.g. /root on a CI runner): this user cannot
    have private art there, and the check must not crash on it."""
    try:
        return p.is_dir()
    except OSError:
        return False


def _is_file(p: Path) -> bool:
    try:
        return p.is_file()
    except OSError:
        return False


def default_private_roots() -> list[Path]:
    cands: list[Path] = []
    env = os.environ.get("HAYDAY_PRIVATE_ASSETS")
    if env:
        cands.append(Path(env).expanduser())
    cands.append(Path("/root/hayday-sandbox-private-assets"))
    cands.append(Path.home() / "hayday-sandbox-private-assets")
    if os.name == "nt" and os.environ.get("USERPROFILE"):
        cands.append(Path(os.environ["USERPROFILE"]) / "hayday-sandbox-private-assets")
    out: list[Path] = []
    for c in cands:
        try:
            r = c.resolve()
        except OSError:
            continue
        if r not in out:
            out.append(r)
    return out


def godot_user_dir() -> Path:
    if os.name == "nt":
        return Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))) / "HaydaySandbox"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "HaydaySandbox"
    return Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share")) / "HaydaySandbox"


def default_private_pack_dirs() -> list[Path]:
    """The app's installed private packs: asset_packs/hayday_original* (other user packs are not assumed private;
    tools/private_assets/install_pack.py additionally records every pack it installs, see PrivateHashDB)."""
    base = godot_user_dir() / "asset_packs"
    found = sorted(base.glob("hayday_original*")) if _is_dir(base) else []
    return [p for p in found if _is_dir(p)] or [base / "hayday_original"]


# ---------------------------------------------------------------------------------------------------------------
# Entries (what gets checked)
# ---------------------------------------------------------------------------------------------------------------

@dataclasses.dataclass
class Entry:
    path: str                       # repo-relative, '/'-separated (or display path for --paths)
    size: int
    read: Callable[[], bytes]       # full content (lazy)
    symlink_target: str | None = None
    where: str = ""                 # e.g. "staged", "commit abc123"


@dataclasses.dataclass
class Finding:
    rule: str
    path: str
    message: str
    where: str = ""


def git(repo: Path, *args: str, env: dict | None = None, binary: bool = False) -> str | bytes:
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True, env=env)
    return out.stdout if binary else out.stdout.decode("utf-8", "surrogateescape")


class BlobReader:
    """One long-lived ``git cat-file --batch`` process: cheap random access to blobs."""

    def __init__(self, repo: Path, env: dict | None = None):
        self.repo, self.env, self.proc = repo, env, None
        self.cache_sizes: dict[str, int] = {}

    def _ensure(self) -> subprocess.Popen:
        if self.proc is None:
            self.proc = subprocess.Popen(["git", "-C", str(self.repo), "cat-file", "--batch"], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, env=self.env)
        return self.proc

    def read(self, oid: str) -> bytes:
        p = self._ensure()
        p.stdin.write(oid.encode() + b"\n")
        p.stdin.flush()
        header = p.stdout.readline().decode().split()
        if len(header) < 3 or header[1] == "missing":
            raise RuntimeError(f"git object {oid} missing")
        size = int(header[2])
        data = p.stdout.read(size)
        p.stdout.read(1)
        return data

    def sizes(self, oids: Iterable[str]) -> dict[str, int]:
        todo = [o for o in dict.fromkeys(oids) if o not in self.cache_sizes]
        if todo:
            out = subprocess.run(["git", "-C", str(self.repo), "cat-file", "--batch-check"],
                                 input=("\n".join(todo) + "\n").encode(), capture_output=True, check=True,
                                 env=self.env).stdout.decode()
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 3 and parts[1] != "missing":
                    self.cache_sizes[parts[0]] = int(parts[2])
        return self.cache_sizes

    def close(self) -> None:
        if self.proc is not None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=10)
            except Exception:
                self.proc.kill()
            self.proc = None


def _blob_entries(reader: BlobReader, rows: list[tuple[str, str, str]], where: str | list[str]) -> list[Entry]:
    """rows = (mode, oid, path); ``where`` is one label or one per row. Gitlinks (submodules) are skipped."""
    wheres = where if isinstance(where, list) else [where] * len(rows)
    keep = [(r, w) for r, w in zip(rows, wheres) if r[0] != "160000"]
    sizes = reader.sizes(r[1] for r, _w in keep)
    out = []
    for (mode, oid, path), w in keep:
        target = reader.read(oid).decode("utf-8", "replace") if mode == "120000" else None
        out.append(Entry(path, sizes.get(oid, 0), lambda o=oid: reader.read(o), target, w))
    return out


def index_rows(repo: Path, env: dict | None = None) -> dict[str, tuple[str, str]]:
    raw = git(repo, "ls-files", "-s", "-z", env=env)
    rows: dict[str, tuple[str, str]] = {}
    for rec in raw.split("\0"):
        if not rec:
            continue
        meta, path = rec.split("\t", 1)
        mode, oid, _stage = meta.split()
        rows[path] = (mode, oid)
    return rows


def tracked_entries(repo: Path, reader: BlobReader, env: dict | None = None) -> list[Entry]:
    return _blob_entries(reader, [(m, o, p) for p, (m, o) in index_rows(repo, env).items()], "index")


def staged_entries(repo: Path, reader: BlobReader, env: dict | None = None) -> list[Entry]:
    names = git(repo, "diff", "--cached", "--name-only", "-z", "--no-renames", "--diff-filter=ACMRT", env=env)
    wanted = [n for n in names.split("\0") if n]
    rows = index_rows(repo, env)
    return _blob_entries(reader, [(rows[n][0], rows[n][1], n) for n in wanted if n in rows], "staged")


def range_entries(repo: Path, reader: BlobReader, spec: str, env: dict | None = None) -> list[Entry]:
    commits = [c for c in git(repo, "rev-list", *spec.split(), env=env).split() if c]
    seen: dict[tuple[str, str], tuple[str, str]] = {}
    for c in commits:
        raw = git(repo, "diff-tree", "-r", "-m", "--root", "--raw", "-z", "--no-commit-id", "--no-renames",
                  "--diff-filter=ACMRT", c, env=env)
        parts = raw.split("\0")
        i = 0
        while i < len(parts) - 1:
            meta = parts[i]
            if not meta.startswith(":"):
                i += 1
                continue
            fields = meta[1:].split()
            path = parts[i + 1]
            i += 2
            dst_mode, dst_oid = fields[1], fields[3]
            seen.setdefault((path, dst_oid), (dst_mode, c[:12]))
    rows = [(m, oid, p) for (p, oid), (m, _c) in seen.items()]
    return _blob_entries(reader, rows, [f"commit {c}" for (m, c) in seen.values()])


def rev_entries(repo: Path, reader: BlobReader, rev: str, env: dict | None = None) -> list[Entry]:
    raw = git(repo, "ls-tree", "-r", "-z", "--full-tree", rev, env=env)
    rows = []
    for rec in raw.split("\0"):
        if not rec:
            continue
        meta, path = rec.split("\t", 1)
        mode, _typ, oid = meta.split()
        rows.append((mode, oid, path))
    return _blob_entries(reader, rows, f"rev {rev}")


def untracked_entries(repo: Path, env: dict | None = None) -> list[Entry]:
    names = [n for n in git(repo, "ls-files", "--others", "--exclude-standard", "-z", env=env).split("\0") if n]
    return [fs_entry(repo / n, n, "untracked") for n in names if os.path.lexists(repo / n)]


def fs_entry(p: Path, display: str, where: str = "") -> Entry:
    if os.path.islink(p):
        target = os.readlink(p)
        return Entry(display, len(target), lambda t=target: t.encode(), target, where)
    return Entry(display, p.stat().st_size, lambda q=p: q.read_bytes(), None, where)


def path_entries(paths: list[Path]) -> list[Entry]:
    out = []
    for root in paths:
        if root.is_file() or os.path.islink(root):
            out.append(fs_entry(root, root.as_posix()))
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            for fn in filenames:
                p = Path(dirpath) / fn
                out.append(fs_entry(p, p.relative_to(root).as_posix() if root != p else fn))
    return out


# ---------------------------------------------------------------------------------------------------------------
# Content sniffing
# ---------------------------------------------------------------------------------------------------------------

def sniff(data: bytes) -> str | None:
    """Return 'image' / 'audio' / 'video' / 'archive' / 'package' for well-known binary signatures."""
    h = data[:32]
    if h.startswith(b"\x89PNG\r\n\x1a\n") or h.startswith(b"\xff\xd8\xff") or h[:6] in (b"GIF87a", b"GIF89a"):
        return "image"
    if h[:4] == b"RIFF" and h[8:12] == b"WEBP":
        return "image"
    if h[:4] == b"RIFF" and h[8:12] in (b"WAVE", b"AVI "):
        return "audio" if h[8:12] == b"WAVE" else "video"
    if h[:4] in (b"8BPS",) or h[:12] == b"\xabKTX 11\xbb\r\n\x1a\n" or h[:12] == b"\xabKTX 20\xbb\r\n\x1a\n":
        return "image"
    if h[:4] == b"\x13\xab\xa1\x5c":  # ASTC
        return "image"
    if h[:4] == b"PK\x03\x04" or h[:4] == b"PK\x05\x06":
        return "archive"
    if h[:6] == b"7z\xbc\xaf\x27\x1c" or h[:4] == b"Rar!" or h[:2] == b"\x1f\x8b" or h[:3] == b"BZh" \
            or h[:6] == b"\xfd7zXZ\x00" or h[:4] == b"\x28\xb5\x2f\xfd":
        return "archive"
    if h[:4] == b"GDPC":
        return "package"
    if h[:4] == b"OggS" or h[:3] == b"ID3" or h[:4] == b"fLaC":
        return "audio"
    if h[4:8] == b"ftyp" or h[:4] == b"\x1aE\xdf\xa3":
        return "video"
    return None


def is_binary(data: bytes) -> bool:
    return b"\0" in data[:8192]


# ---------------------------------------------------------------------------------------------------------------
# Private hash database (local only)
# ---------------------------------------------------------------------------------------------------------------

def _hashes_in_json(obj, any_key: bool, label: str, out: dict[str, str], key: str = "", ctx: str = "") -> None:
    if isinstance(obj, dict):
        name = ""
        for k in ("local_path", "rel_path", "file", "title"):
            if isinstance(obj.get(k), str):
                name = obj[k]
                break
        for k, v in obj.items():
            if any_key and isinstance(k, str) and HEX_RE.match(k):
                out.setdefault(k.lower(), f"{label}: {v if isinstance(v, str) else name or k[:12]}")
            _hashes_in_json(v, any_key, label, out, str(k), name or ctx)
    elif isinstance(obj, list):
        for v in obj:
            _hashes_in_json(v, any_key, label, out, key, ctx)
    elif isinstance(obj, str) and HEX_RE.match(obj):
        k = key.lower()
        if any_key or "sha" in k or "hash" in k or "digest" in k:
            out.setdefault(obj.lower(), f"{label}: {ctx}" if ctx else label)


class PrivateHashDB:
    def __init__(self, roots: list[Path], pack_dirs: list[Path], sweep: bool = True,
                 log: Callable[[str], None] = lambda s: print(s, file=sys.stderr)):
        self.roots = [r for r in roots if _is_dir(r)]
        # packs installed by tools/private_assets/install_pack.py are recorded in <root>/.leakcheck/installed_packs.json
        recorded: list[Path] = []
        for r in self.roots:
            try:
                doc = json.loads((r / CACHE_DIR / "installed_packs.json").read_text(encoding="utf-8"))
                recorded += [Path(x) for x in doc.get("packs", []) if isinstance(x, str)]
            except (OSError, ValueError, AttributeError):
                pass
        self.pack_dirs = []
        for p in list(pack_dirs) + recorded:
            if _is_dir(p) and p.resolve() not in [q.resolve() for q in self.pack_dirs]:
                self.pack_dirs.append(p)
        self.sweep = sweep
        self.log = log
        self.hashes: dict[str, str] = {}
        self.loaded = False
        self.stats = {"index_files": 0, "swept_images": 0, "swept_other": 0, "hashed_now": 0}

    @property
    def available(self) -> bool:
        return bool(self.roots or self.pack_dirs)

    def describe(self) -> str:
        return ", ".join(str(p) for p in self.roots + self.pack_dirs) or "(none)"

    def load(self) -> None:
        if self.loaded:
            return
        self.loaded = True
        for root in self.roots:
            files = sorted((root / "raw").rglob("index.json")) if (root / "raw").is_dir() else []
            files += sorted(p for p in root.rglob("hashes.json") if not _skipped(p, root))
            for f in files:
                try:
                    doc = json.loads(f.read_text(encoding="utf-8"))
                except (OSError, ValueError, UnicodeDecodeError) as ex:
                    self.log(f"leak-check: warning: cannot read {f}: {ex}")
                    continue
                self.stats["index_files"] += 1
                _hashes_in_json(doc, f.name == "hashes.json", str(f.relative_to(root)), self.hashes)
        for pd in self.pack_dirs:
            hj = pd / "hashes.json"
            if hj.is_file():
                try:
                    _hashes_in_json(json.loads(hj.read_text(encoding="utf-8")), True, str(hj), self.hashes)
                    self.stats["index_files"] += 1
                except (OSError, ValueError, UnicodeDecodeError):
                    pass
        if self.sweep:
            for base in self.roots:
                self._sweep(base, SWEEP_ALL_FILES_UNDER)
            for base in self.pack_dirs:
                self._sweep(base, ("",))

    def _cache_dir(self) -> Path:
        if self.roots:
            return self.roots[0] / CACHE_DIR
        return Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "hayday-sandbox-leakcheck"

    def _sweep(self, base: Path, all_files_under: tuple[str, ...] = ()) -> None:
        """Hash every image under ``base``, plus every other file (MIN_HASHED_NONMEDIA_BYTES..MAX_FILE_BYTES, generic
        licence/readme names excepted) in the sub-folders listed in ``all_files_under`` ("" = the whole base)."""
        key = hashlib.sha1(str(base.resolve()).encode()).hexdigest()[:12]
        cache_file = self._cache_dir() / f"sweep_{base.name}_{key}.json"
        cache: dict[str, list] = {}
        if cache_file and cache_file.is_file():
            try:
                cache = json.loads(cache_file.read_text()).get("files", {})
            except (OSError, ValueError):
                cache = {}
        current: dict[str, list] = {}
        todo: list[tuple[str, Path, int, int]] = []
        for dirpath, dirnames, filenames in os.walk(base):
            # scratch folders last, so a match names the canonical copy (raw/..., packs/...) when there are several
            dirnames[:] = sorted((d for d in dirnames if d not in SWEEP_SKIP_DIRS and not d.startswith(".")),
                                 key=lambda d: (d.lower() in ("tmp", "temp", "scratch"), d))
            rel_dir = Path(dirpath).relative_to(base).as_posix()
            rel_dir = "" if rel_dir == "." else rel_dir + "/"
            all_here = any(rel_dir.startswith(prefix) for prefix in all_files_under)
            for fn in sorted(filenames):
                is_image = Path(fn).suffix.lower() in IMAGE_EXT
                if not is_image and (not all_here or GENERIC_NAME_RE.match(fn)):
                    continue
                p = Path(dirpath) / fn
                try:
                    st = p.stat()
                except OSError:
                    continue
                if not is_image and not (MIN_HASHED_NONMEDIA_BYTES <= st.st_size <= MAX_FILE_BYTES):
                    continue
                rel = p.relative_to(base).as_posix()
                c = cache.get(rel)
                if c and c[0] == st.st_size and c[1] == st.st_mtime_ns:
                    current[rel] = c
                else:
                    todo.append((rel, p, st.st_size, st.st_mtime_ns))
        if todo:
            if len(todo) > 200:
                self.log(f"leak-check: hashing {len(todo)} private files under {base} (one-time; cached) ...")

            def h(item):
                rel, p, size, mt = item
                d = hashlib.sha256()
                with open(p, "rb") as fh:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        d.update(chunk)
                return rel, [size, mt, d.hexdigest()]

            with cf.ThreadPoolExecutor(max_workers=4) as ex:
                for rel, rec in ex.map(h, todo):
                    current[rel] = rec
            self.stats["hashed_now"] += len(todo)
        if cache_file and (todo or len(current) != len(cache)):
            try:
                cache_file.parent.mkdir(parents=True, exist_ok=True)
                tmp = cache_file.with_suffix(f".tmp{os.getpid()}")
                tmp.write_text(json.dumps({"version": 1, "base": str(base), "files": current}))
                os.replace(tmp, cache_file)
            except OSError:
                pass
        for rel, rec in current.items():
            self.hashes.setdefault(rec[2], f"{base.name}/{rel}")
        n_images = sum(1 for rel in current if PurePosixPath(rel).suffix.lower() in IMAGE_EXT)
        self.stats["swept_images"] += n_images
        self.stats["swept_other"] += len(current) - n_images

    def match(self, data: bytes) -> str | None:
        self.load()
        for digest in (hashlib.sha256(data).hexdigest(), hashlib.sha1(data).hexdigest()):
            if digest in self.hashes:
                return self.hashes[digest]
        return None


def _skipped(p: Path, root: Path) -> bool:
    return any(part in SWEEP_SKIP_DIRS for part in p.relative_to(root).parts)


# ---------------------------------------------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------------------------------------------

def media_kind(ext: str) -> str | None:
    if ext in IMAGE_EXT:
        return "image"
    if ext in AUDIO_EXT:
        return "audio"
    if ext in VIDEO_EXT:
        return "video"
    return None


def full_ext(name: str) -> str:
    low = name.lower()
    return ".hdpack.zip" if low.endswith(".hdpack.zip") else PurePosixPath(low).suffix


def check_path_rules(path: str, artifact: bool) -> list[Finding]:
    f: list[Finding] = []
    low = path.replace("\\", "/").lower()
    parts = low.split("/")
    name = parts[-1]
    ext = full_ext(name)
    for s in PRIVATE_SUBSTRINGS:
        if s in low:
            f.append(Finding("private-path", path, f"path contains '{s}' (private storage / private pack)"))
    if "asset_packs" in parts[:-1] or name == "asset_packs" or name.startswith("asset_packs."):
        f.append(Finding("private-path", path, "path is inside an 'asset_packs' folder (the app's private packs)"))
    if PRIVATE_DIR_RE.search(low):
        f.append(Finding("private-path", path, "path looks like private raw storage (raw/fankit, raw/wiki*)"))
    if not artifact and low.startswith("assets/original/") and name not in ("readme.md", ".gdignore"):
        f.append(Finding("private-path", path, "assets/original/ is local-only (developer art) and git-ignored"))
    if ext in PROHIBITED_EXT or ext == ".hdpack.zip":
        f.append(Finding("prohibited-type", path, f"'{ext}' files (game/package/archive formats) are never committed"))
    elif ext in ARCHIVE_EXT or low.endswith((".tar.gz", ".tar.xz", ".tar.zst")):
        f.append(Finding("archive", path, "archives are never committed (they can hide private art)"))
    kind = media_kind(ext)
    if kind and not artifact and not low.startswith(ALLOWED_MEDIA_DIRS):
        f.append(Finding("media-outside-public", path, f"{kind} file outside the public folders "
                         f"({', '.join(ALLOWED_MEDIA_DIRS)}); only original/generated art may be committed"))
    if kind == "image" and OFFICIAL_NAME_RE.search(name):
        f.append(Finding("official-art-name", path, "image file name looks like official Hay Day / Fan Kit art"))
    return f


def check_content_rules(e: Entry, data: bytes, artifact: bool) -> list[Finding]:
    f: list[Finding] = []
    low = e.path.lower()
    ext = full_ext(PurePosixPath(low).name)
    kind = sniff(data)
    if kind and media_kind(ext) is None and ext not in PROHIBITED_EXT and ext not in ARCHIVE_EXT:
        f.append(Finding("disguised-media", e.path, f"content is {kind} data although the extension is "
                         f"'{ext or '(none)'}'"))
    if not is_binary(data) and len(data) <= MAX_FILE_BYTES:
        text = data.decode("utf-8", "ignore")
        if FANKIT_TOKEN_RE.search(text):
            f.append(Finding("fankit-token", e.path, "contains a Fan Kit download token (eyJ...:...:...)"))
        if DOWNLOAD_URL_RE.search(text):
            f.append(Finding("fankit-token", e.path, "contains a Fan Kit download URL with a token"))
        if FFY_SIGNED_RE.search(text):
            f.append(Finding("fankit-token", e.path, "contains a signed media.ffycdn.net URL"))
        urls = set(FFY_URL_RE.findall(text))
        if urls and TOKEN_FIELD_RE.search(text):
            f.append(Finding("fankit-token", e.path, "contains media.ffycdn.net URLs together with a \"token\" field"))
        if len(urls) >= FFY_INDEX_THRESHOLD:
            f.append(Finding("fankit-token", e.path, f"contains {len(urls)} media.ffycdn.net URLs (looks like a "
                             "private Fan Kit index dump)"))
        if ext == ".json" and PRIVATE_INDEX_RE.search(text):
            f.append(Finding("private-index", e.path, "looks like a private acquisition index (private_use_only / "
                             "download_method / sha1_local fields)"))
    return f


def check_symlink(e: Entry) -> list[Finding]:
    t = (e.symlink_target or "").replace("\\", "/")
    low = t.lower()
    bad = t.startswith(("/", "~")) or bool(re.match(r"^[a-zA-Z]:", t))
    if not bad:
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(e.path.replace("\\", "/")), t))
        bad = resolved == ".." or resolved.startswith("../")
    if bad or any(s in low for s in PRIVATE_SUBSTRINGS) or "asset_packs" in low:
        return [Finding("symlink", e.path, f"symlink points outside the repository / at private storage ({t})")]
    return []


def run_checks(entries: list[Entry], db: PrivateHashDB | None, artifact: bool = False) -> list[Finding]:
    findings: list[Finding] = []
    for e in entries:
        ff: list[Finding] = []
        if e.symlink_target is not None:
            ff += check_symlink(e)
            for x in ff:
                x.where = e.where
            findings += ff
            continue
        ff += check_path_rules(e.path, artifact)
        if e.size > MAX_FILE_BYTES and not artifact:
            ff.append(Finding("too-large", e.path, f"file is {e.size / 1048576:.1f} MB (limit 5 MB)"))
        try:
            data = e.read()
        except Exception as ex:  # unreadable: fail closed
            ff.append(Finding("unreadable", e.path, f"could not read content: {ex}"))
            data = b""
        if data:
            ff += check_content_rules(e, data, artifact)
            ext = full_ext(PurePosixPath(e.path.lower()).name)
            if db is not None and db.available and (is_binary(data) or media_kind(ext) or sniff(data)
                                                    or len(data) >= MIN_HASHED_NONMEDIA_BYTES):
                src = db.match(data)
                if src:
                    ff.append(Finding("private-hash", e.path, f"identical to a file in private storage ({src})"))
        for x in ff:
            x.where = e.where
        findings += ff
    return findings


# ---------------------------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------------------------

def report(findings: list[Finding], n_entries: int, mode: str, db: PrivateHashDB | None, quiet: bool) -> None:
    by_path: dict[str, list[Finding]] = {}
    for f in findings:
        by_path.setdefault(f.path, []).append(f)
    for path, ff in by_path.items():
        where = f"  ({ff[0].where})" if ff[0].where and ff[0].where not in ("index", "staged") else ""
        print(f"LEAK [{', '.join(sorted({x.rule for x in ff}))}] {path}{where}")
        for x in ff:
            print(f"    - {x.message}")
    if db is None or not db.available:
        hash_note = "private hash check: skipped (no private storage on this machine)"
    elif db.loaded:
        hash_note = (f"private hash check: {len(db.hashes)} known hashes from {db.stats['index_files']} index files "
                     f"+ {db.stats['swept_images']} private images + {db.stats['swept_other']} other private files")
    else:
        hash_note = "private hash check: not needed (no binary files to compare)"
    if findings:
        print(f"\nPrivate-art leak check FAILED ({mode}): {len(findings)} problem(s) in {len(by_path)} of "
              f"{n_entries} file(s). {hash_note}.")
        if mode == "staged":
            print("  Unstage with:  git restore --staged -- <path>   then move the file out of the repository.")
        elif mode in ("tracked", "tracked+untracked", "rev"):
            print("  Remove from git with:  git rm --cached -- <path>   (and move the file out of the repository).")
        elif mode == "range":
            print("  These commits contain private art: rewrite them (e.g. interactive rebase) before pushing.")
        print("  Original Hay Day art lives ONLY in the private storage folder or the app's user folder; it must never "
              "be committed, pushed or uploaded. See docs/PRIVATE_ASSETS.md.")
    elif not quiet:
        print(f"Private-art leak check OK ({mode}): {n_entries} file(s) checked. {hash_note}.")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--staged", action="store_true", help="check only staged files (pre-commit hook)")
    g.add_argument("--range", metavar="REVS", help="check files changed by the commits `git rev-list REVS` lists")
    g.add_argument("--rev", metavar="REV", help="check the whole tree of commit REV")
    g.add_argument("--paths", nargs="+", type=Path, metavar="P", help="check plain files/folders (no git)")
    g.add_argument("--self-test", action="store_true", help="run built-in tests and exit")
    ap.add_argument("--include-untracked", action="store_true", help="also check untracked, non-ignored files")
    ap.add_argument("--artifact", action="store_true", help="with --paths: CI artifact folder rules (media allowed)")
    ap.add_argument("--repo", type=Path, default=None, help="repository (default: the one containing this script)")
    ap.add_argument("--private-root", type=Path, action="append", default=None,
                    help="private storage root(s) for the hash check (default: $HAYDAY_PRIVATE_ASSETS, "
                         "/root/hayday-sandbox-private-assets, ~/hayday-sandbox-private-assets)")
    ap.add_argument("--private-pack", type=Path, action="append", default=None,
                    help="installed private pack folder(s) to include (default: the app's asset_packs/hayday_original)")
    ap.add_argument("--no-private-hashes", action="store_true", help="skip the private hash comparison")
    ap.add_argument("--no-sweep", action="store_true", help="hash check uses index/hashes.json files only")
    ap.add_argument("--quiet", action="store_true", help="print nothing when clean")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    db = None
    if not args.no_private_hashes:
        db = PrivateHashDB(args.private_root or default_private_roots(),
                           args.private_pack if args.private_pack is not None else default_private_pack_dirs(),
                           sweep=not args.no_sweep)
    if args.paths:
        entries = path_entries(args.paths)
        findings = run_checks(entries, db, artifact=args.artifact)
        report(findings, len(entries), "artifact" if args.artifact else "paths", db, args.quiet)
        return 1 if findings else 0

    repo = args.repo
    if repo is None:
        try:
            repo = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, check=True,
                                       text=True).stdout.strip())
        except (subprocess.CalledProcessError, FileNotFoundError):
            repo = REPO_ROOT
    try:
        git(repo, "rev-parse", "--git-dir")
    except (subprocess.CalledProcessError, FileNotFoundError):
        print(f"check_private_leaks: {repo} is not a git work tree (use --paths for plain folders)", file=sys.stderr)
        return 2
    reader = BlobReader(repo)
    try:
        if args.staged:
            mode, entries = "staged", staged_entries(repo, reader)
        elif args.range:
            mode, entries = "range", range_entries(repo, reader, args.range)
        elif args.rev:
            mode, entries = "rev", rev_entries(repo, reader, args.rev)
        else:
            mode, entries = "tracked", tracked_entries(repo, reader)
        if args.include_untracked:
            mode = mode + "+untracked" if mode == "tracked" else mode
            entries += untracked_entries(repo)
        findings = run_checks(entries, db)
    except subprocess.CalledProcessError as ex:
        print(f"check_private_leaks: git failed: {' '.join(map(str, ex.cmd))}: "
              f"{(ex.stderr or b'').decode(errors='replace').strip()}", file=sys.stderr)
        return 2
    finally:
        reader.close()
    report(findings, len(entries), mode, db, args.quiet)
    return 1 if findings else 0


# ---------------------------------------------------------------------------------------------------------------
# Self-test (no pytest; temporary git repositories)
# ---------------------------------------------------------------------------------------------------------------

def _png_bytes(seed: int, w: int = 2, h: int = 2) -> bytes:
    """A tiny valid PNG generated from scratch (no art involved)."""
    def chunk(t: bytes, d: bytes) -> bytes:
        return len(d).to_bytes(4, "big") + t + d + zlib.crc32(t + d).to_bytes(4, "big")
    rows = b"".join(b"\0" + bytes([(seed * 37 + x * 11 + y * 5) % 256 for x in range(w * 4)]) for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", w.to_bytes(4, "big") + h.to_bytes(4, "big") + b"\x08\x06\0\0\0")
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def self_test() -> int:
    failures: list[str] = []
    checks = 0

    def expect(cond: bool, msg: str) -> None:
        nonlocal checks
        checks += 1
        if not cond:
            failures.append(msg)

    tmp = Path(tempfile.mkdtemp(prefix="leakcheck-selftest-"))
    (tmp / "home").mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid", "HOME": str(tmp / "home"),
                "XDG_CONFIG_HOME": str(tmp / "home"), "XDG_CACHE_HOME": str(tmp / "home" / "cache")})
    try:
        repo = tmp / "repo"
        priv = tmp / "private-root"
        pack = tmp / "userdir" / "hayday_original"
        repo.mkdir()

        def run_git(*a: str) -> str:
            return subprocess.run(["git", "-C", str(repo), *a], env=env, capture_output=True, text=True,
                                  check=True).stdout

        run_git("init", "-q")
        run_git("config", "core.hooksPath", "/dev/null")
        token = "ey" + "J" + "a" * 20 + ":" + "b" * 12 + ":" + "c" * 12
        ffy = "https://media." + "ffycdn.net/eu/x/" + "abc.png"
        files: dict[str, bytes] = {
            # clean files
            "assets/placeholders/items/ok.png": _png_bytes(1),
            "assets/ui/icon.png": _png_bytes(2),
            "docs/screenshots/overview.png": _png_bytes(3),
            "tests/unit/test_asset_packs.gd": b"extends Node # asset_packs in a file name is fine\n",
            "tools/private_assets/fetch.py": ('URL = "' + ffy + '"\nx = d.get("token")\npayload = {"token": tok}\n'
                                              'DOC = "/screen/download/<token>"\n').encode(),
            "data/maps/hayday_farm.json": b'{"size": [1, 1]}\n',
            "assets/original/README.md": b"local only\n",
            # violations
            "docs/screenshots/HayDay_Test.png": _png_bytes(4),
            "assets/placeholders/items/59170__hayday_cow.png": _png_bytes(5),
            "assets/ui/fankit_logo.png": _png_bytes(6),
            "src/stray.png": _png_bytes(7),
            "src/disguised.txt": _png_bytes(8),
            "music/theme.ogg": b"OggS\0\2" + b"\0" * 40,
            "data/pack.zip": b"PK\x03\x04" + b"\0" * 40,
            "data/client.sc": b"SC\0\0",
            "data/x.hdpack.zip": b"PK\x03\x04" + b"\0" * 10,
            "misc/archive.tar.gz": b"\x1f\x8b\x08\0" + b"\0" * 20,
            "user/asset_packs/hayday_original/pack.json": b"{}\n",
            "backup/hayday-sandbox-private-assets/notes.txt": b"x\n",
            "mirror/raw/fankit/index.json": b"{}\n",
            "mirror/raw/wiki_ru/readme.txt": b"x\n",
            "assets/original/bakery.png": _png_bytes(9),
            "notes/tokens.md": f"download with {token}\n".encode(),
            "notes/url.md": b"GET https://fankit.supercell.com/api/screen/download/" + b"Q" * 30 + b"\n",
            "notes/dump.json": ('{"url": "' + ffy + '", "token": "' + "z" * 24 + '"}\n').encode(),
            "notes/signed.txt": (ffy + "?format=png&token=" + "k" * 10 + "\n").encode(),
            "notes/many.txt": "\n".join(ffy.replace("abc", f"a{i}") for i in range(25)).encode(),
            "notes/wiki_index.json": b'{"files": [{"title": "x", "private_use_only": true}]}\n',
            "big/blob.bin": b"\0" * (MAX_FILE_BYTES + 1),
            # private hash matches (innocent names inside public folders)
            "assets/placeholders/items/leak_by_index.png": _png_bytes(10),
            "assets/placeholders/items/leak_by_packhash.png": _png_bytes(11),
            "docs/screenshots/leak_by_sweep.png": _png_bytes(12),
            "assets/ui/leak_by_sha1.png": _png_bytes(13),
            "assets/placeholders/items/leak_by_record.png": _png_bytes(14),
            # non-image private content (e.g. game data extracted from the client) copied into the repository
            "data/research/animals.csv": b"Name,Cost,Level\n" + b"Cow,100,6\nPig,200,10\nSheep,300,32\n" * 3,
            "assets/ui/fonts/game_font.ttf": b"\0\1\0\0" + bytes(range(256)) * 2,
            # ... but tiny files, generic licence texts and files outside raw/ + packs/ are not compared
            "notes/tiny.txt": b"x\n",
            "third_party/LICENSE": b"Permission is hereby granted, free of charge, to any person obtaining it.\n" * 3,
            "notes/run.log": b"run finished: 1941 sprites, 0 errors, nothing else of interest in this line\n",
        }
        expected = {
            "docs/screenshots/HayDay_Test.png": {"official-art-name"},
            "assets/placeholders/items/59170__hayday_cow.png": {"official-art-name"},
            "assets/ui/fankit_logo.png": {"official-art-name"},
            "src/stray.png": {"media-outside-public"},
            "src/disguised.txt": {"disguised-media"},
            "music/theme.ogg": {"media-outside-public"},
            "data/pack.zip": {"prohibited-type"},
            "data/client.sc": {"prohibited-type"},
            "data/x.hdpack.zip": {"prohibited-type"},
            "misc/archive.tar.gz": {"archive"},
            "user/asset_packs/hayday_original/pack.json": {"private-path"},
            "backup/hayday-sandbox-private-assets/notes.txt": {"private-path"},
            "mirror/raw/fankit/index.json": {"private-path"},
            "mirror/raw/wiki_ru/readme.txt": {"private-path"},
            "assets/original/bakery.png": {"private-path", "media-outside-public"},
            "notes/tokens.md": {"fankit-token"},
            "notes/url.md": {"fankit-token"},
            "notes/dump.json": {"fankit-token"},
            "notes/signed.txt": {"fankit-token"},
            "notes/many.txt": {"fankit-token"},
            "notes/wiki_index.json": {"private-index"},
            "big/blob.bin": {"too-large"},
            "assets/placeholders/items/leak_by_index.png": {"private-hash"},
            "assets/placeholders/items/leak_by_packhash.png": {"private-hash"},
            "docs/screenshots/leak_by_sweep.png": {"private-hash"},
            "assets/ui/leak_by_sha1.png": {"private-hash"},
            "assets/placeholders/items/leak_by_record.png": {"private-hash"},
            "data/research/animals.csv": {"private-hash"},
            "assets/ui/fonts/game_font.ttf": {"private-hash"},
            "link_out": {"symlink"},
        }
        for rel, data in files.items():
            p = repo / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        symlinks_ok = True
        try:
            os.symlink(str(priv), repo / "link_out")
            os.symlink("ok.png", repo / "assets/placeholders/items/link_in.png")
        except (OSError, NotImplementedError):
            symlinks_ok = False
            expected.pop("link_out")
        # private storage fixtures
        (priv / "raw" / "fankit").mkdir(parents=True)
        (priv / "raw" / "fankit" / "index.json").write_text(json.dumps({"assets": [
            {"title": "HayDay_Thing", "sha256": hashlib.sha256(files["assets/placeholders/items/leak_by_index.png"])
             .hexdigest(), "local_path": "files/1__hayday_thing.png"}]}))
        (priv / "raw" / "wiki").mkdir(parents=True)
        (priv / "raw" / "wiki" / "index.json").write_text(json.dumps({"files": [
            {"title": "File:Thing.png", "sha1_local": hashlib.sha1(files["assets/ui/leak_by_sha1.png"]).hexdigest()}]}))
        (priv / "packs" / "hayday_original").mkdir(parents=True)
        (priv / "packs" / "hayday_original" / "hashes.json").write_text(json.dumps(
            {"items/x.png": hashlib.sha256(files["assets/placeholders/items/leak_by_packhash.png"]).hexdigest()}))
        (priv / "raw" / "apk_sprites" / "v" / "sheet").mkdir(parents=True)
        (priv / "raw" / "apk_sprites" / "v" / "sheet" / "s.png").write_bytes(files["docs/screenshots/leak_by_sweep.png"])
        apk_x = priv / "raw" / "apk_extracted" / "v"
        (apk_x / "csv_logic").mkdir(parents=True)
        (apk_x / "csv_logic" / "animals.csv").write_bytes(files["data/research/animals.csv"])
        (apk_x / "fonts").mkdir()
        (apk_x / "fonts" / "won.ttf").write_bytes(files["assets/ui/fonts/game_font.ttf"])
        (apk_x / "tiny.txt").write_bytes(files["notes/tiny.txt"])
        (apk_x / "LICENSE").write_bytes(files["third_party/LICENSE"])
        (priv / "logs").mkdir()
        (priv / "logs" / "run.log").write_bytes(files["notes/run.log"])
        pack.mkdir(parents=True)
        (pack / "items").mkdir()
        (pack / "items" / "unrelated.png").write_bytes(_png_bytes(99))

        recorded_pack = tmp / "elsewhere" / "my_private_pack"
        (recorded_pack / "items").mkdir(parents=True)
        (recorded_pack / "items" / "r.png").write_bytes(files["assets/placeholders/items/leak_by_record.png"])
        (priv / CACHE_DIR).mkdir(parents=True)
        (priv / CACHE_DIR / "installed_packs.json").write_text(json.dumps({"packs": [str(recorded_pack)]}))
        db = PrivateHashDB([priv], [pack])
        reader = BlobReader(repo, env)

        # 1) full tracked tree
        run_git("add", "-A")
        ents = tracked_entries(repo, reader, env)
        found = run_checks(ents, db)
        got: dict[str, set[str]] = {}
        for f in found:
            got.setdefault(f.path, set()).add(f.rule)
        for path, rules in expected.items():
            expect(rules <= got.get(path, set()), f"tracked: {path}: expected {sorted(rules)}, got "
                                                  f"{sorted(got.get(path, set()))}")
        clean = {p for p in files if p not in expected} | ({"assets/placeholders/items/link_in.png"} if symlinks_ok
                                                           else set())
        for p in clean:
            expect(p not in got, f"tracked: false positive on {p}: {sorted(got.get(p, set()))}")
        expect(set(got) <= set(expected), f"tracked: unexpected findings {sorted(set(got) - set(expected))}")
        expect(db.stats["swept_images"] >= 2, "sweep should hash private images")
        expect(db.stats["swept_other"] >= 2, f"sweep should hash non-image files under raw/ (csv, ttf), got "
                                             f"{db.stats['swept_other']}")
        skipped = [files["notes/tiny.txt"], files["third_party/LICENSE"], files["notes/run.log"]]
        expect(not any(hashlib.sha256(b).hexdigest() in db.hashes for b in skipped),
               "sweep must skip tiny files, generic licence files and folders outside raw/ + packs/")
        expect(len(list((priv / CACHE_DIR).glob("sweep_*.json"))) == 3, "sweep caches should be written")
        db2 = PrivateHashDB([priv], [pack])
        db2.load()
        expect(db2.stats["hashed_now"] == 0, "second run must reuse the sweep cache")

        # 2) staged-only. A base commit (throwaway repo) already holds a violation that must NOT be reported,
        #    because --staged only looks at what the next commit changes.
        run_git("rm", "-r", "-q", "--cached", ".")
        run_git("add", "--", "assets/placeholders/items/ok.png", "music/theme.ogg")
        run_git("commit", "-q", "--no-verify", "-m", "base")
        run_git("add", "--", "docs/screenshots/HayDay_Test.png", "assets/ui/icon.png")
        st = staged_entries(repo, reader, env)
        expect(sorted(e.path for e in st) == ["assets/ui/icon.png", "docs/screenshots/HayDay_Test.png"],
               f"staged: wrong entry set {[e.path for e in st]}")
        sf = run_checks(st, db)
        expect({(f.path, f.rule) for f in sf} == {("docs/screenshots/HayDay_Test.png", "official-art-name")},
               f"staged: unexpected findings {[(f.path, f.rule) for f in sf]}")
        # staged content wins over the working tree: stage a clean blob, then make the working file bad
        run_git("rm", "-q", "--cached", "--", "docs/screenshots/HayDay_Test.png", "assets/ui/icon.png")
        (repo / "notes" / "later.md").write_text("fine\n")
        run_git("add", "--", "notes/later.md")
        (repo / "notes" / "later.md").write_text(f"now with {token}\n")
        sf = run_checks(staged_entries(repo, reader, env), db)
        expect(not sf, f"staged: working-tree change must not affect the staged blob: {[(f.path, f.rule) for f in sf]}")

        # 3) range / rev
        run_git("commit", "-q", "--no-verify", "-m", "one")
        run_git("add", "--", "src/stray.png")
        run_git("commit", "-q", "--no-verify", "-m", "two")
        run_git("rm", "-q", "--", "src/stray.png")
        run_git("commit", "-q", "--no-verify", "-m", "three (deleted again)")
        rf = run_checks(range_entries(repo, reader, "HEAD~2..HEAD", env), db)
        expect({(f.path, f.rule) for f in rf} == {("src/stray.png", "media-outside-public")},
               f"range: expected only the deleted-again image, got {[(f.path, f.rule) for f in rf]}")
        expect(all(f.where.startswith("commit ") for f in rf), "range: findings must name the commit")
        rf = run_checks(range_entries(repo, reader, "HEAD --not HEAD~3", env), db)
        expect({f.path for f in rf} == {"src/stray.png"}, f"range --not: got {[(f.path, f.rule) for f in rf]}")
        rf = run_checks(rev_entries(repo, reader, "HEAD", env), db)
        expect({(f.path, f.rule) for f in rf} == {("music/theme.ogg", "media-outside-public")},
               f"rev: got {[(f.path, f.rule) for f in rf]}")

        # 4) artifact mode: screenshots allowed, official names / private hashes / prohibited types are not
        art = tmp / "artifacts" / "screens"
        art.mkdir(parents=True)
        (art / "overview_1080p.png").write_bytes(_png_bytes(20))
        (art / "big_4k.png").write_bytes(_png_bytes(21) + b"\0" * (MAX_FILE_BYTES + 10))
        (art / "HayDay_shot.png").write_bytes(_png_bytes(22))
        (art / "leak.png").write_bytes(files["docs/screenshots/leak_by_sweep.png"])
        (art / "bundle.zip").write_bytes(b"PK\x03\x04")
        af = run_checks(path_entries([art]), db, artifact=True)
        expect({(f.path, f.rule) for f in af} == {("HayDay_shot.png", "official-art-name"), ("leak.png", "private-hash"),
                                                 ("bundle.zip", "prohibited-type")},
               f"artifact: got {sorted((f.path, f.rule) for f in af)}")
        reader.close()

        # 5) CLI exit codes (separate process, explicit private root, isolated repo)
        clean_repo = tmp / "clean"
        clean_repo.mkdir()
        subprocess.run(["git", "-C", str(clean_repo), "init", "-q"], env=env, check=True)
        (clean_repo / "README.md").write_text("hello\n")
        subprocess.run(["git", "-C", str(clean_repo), "add", "README.md"], env=env, check=True)
        base = [sys.executable, str(Path(__file__).resolve()), "--repo", str(clean_repo), "--private-root", str(priv),
                "--private-pack", str(pack)]
        r = subprocess.run(base, env=env, capture_output=True, text=True)
        expect(r.returncode == 0, f"cli: clean repo should pass (rc={r.returncode}): {r.stdout} {r.stderr}")
        (clean_repo / "HayDay_Test.png").write_bytes(_png_bytes(30))
        subprocess.run(["git", "-C", str(clean_repo), "add", "HayDay_Test.png"], env=env, check=True)
        r = subprocess.run(base + ["--staged"], env=env, capture_output=True, text=True)
        expect(r.returncode == 1 and "official-art-name" in r.stdout and "media-outside-public" in r.stdout,
               f"cli: staged HayDay_Test.png must fail (rc={r.returncode}): {r.stdout}")
        r = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--repo", str(tmp / "nope")], env=env,
                           capture_output=True, text=True)
        expect(r.returncode == 2, f"cli: non-repo must exit 2 (rc={r.returncode})")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in failures:
        print("SELF-TEST FAIL:", f)
    print(f"check_private_leaks self-test: {checks - len(failures)}/{checks} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
