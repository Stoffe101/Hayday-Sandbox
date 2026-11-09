#!/usr/bin/env python3
"""Verify that exported builds contain only public data (no private asset packs, no original art).

Reads the file directory of Godot PCK packages (standalone ``.pck`` or embedded in the exported ``.exe`` /
Linux binary; PCK format versions 2-4, no Godot needed) and the names inside build zips/folders, and fails if:

  * a PCK entry or build file path contains ``asset_packs/``, ``hayday_original``, ``private-assets``,
    ``assets/original/``, ``raw/fankit``, ``raw/wiki`` or ``fankit``;
  * an imported resource (``*.import`` / ``*.remap`` entry) has its source outside the public art folders
    (``assets/placeholders/``, ``assets/ui/``) or the app's own scenes/scripts;
  * a PCK has an encrypted directory (cannot be verified) or cannot be parsed;
  * a build folder/zip contains game-package formats (.sc .sctx .ktx .zktx .apk .xapk .obb ...).

If a private storage root exists on this machine, raw image entries inside zips/PCKs are also compared by hash
with the private images (same database as tools/ci/check_private_leaks.py).

Usage:
  python3 tools/ci/check_export_contents.py build/windows/HaydaySandbox.exe build/linux/HaydaySandbox.x86_64 \\
      build/HaydaySandbox-windows-x86_64.zip
  python3 tools/ci/check_export_contents.py --list build/windows/HaydaySandbox.exe   # print the PCK file list
  python3 tools/ci/check_export_contents.py --self-test
Exit status: 0 clean, 1 problems, 2 usage/parse error.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import os
import struct
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import BinaryIO

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_private_leaks as clk  # noqa: E402  (same folder)

PCK_MAGIC = b"GDPC"
FORBIDDEN_TOKENS = ("asset_packs/", "hayday_original", "private-assets", "assets/original/", "raw/fankit",
                    "raw/wiki", "fankit")
PUBLIC_ART_PREFIXES = ("assets/placeholders/", "assets/ui/")
PACKAGE_EXT = clk.PROHIBITED_EXT - {".zip"}  # the release bundle itself is a zip


class PckError(RuntimeError):
    pass


def _u32(f: BinaryIO) -> int:
    b = f.read(4)
    if len(b) != 4:
        raise PckError("unexpected end of file")
    return struct.unpack("<I", b)[0]


def _u64(f: BinaryIO) -> int:
    b = f.read(8)
    if len(b) != 8:
        raise PckError("unexpected end of file")
    return struct.unpack("<Q", b)[0]


def read_pck_directory(f: BinaryIO) -> dict:
    """Return {"version", "godot", "entries": [(path, offset, size)], "file_base"} for a .pck or a file with an
    embedded PCK (Godot appends: <pck> <u64 pck size> 'GDPC')."""
    f.seek(0)
    start = 0
    if f.read(4) != PCK_MAGIC:
        f.seek(0, os.SEEK_END)
        end = f.tell()
        if end < 16:
            raise PckError("no PCK found")
        f.seek(end - 4)
        if f.read(4) != PCK_MAGIC:
            raise PckError("no PCK found (no GDPC header or trailer)")
        f.seek(end - 12)
        size = _u64(f)
        start = end - 12 - size
        if start < 0:
            raise PckError("bad embedded PCK size")
        f.seek(start)
        if f.read(4) != PCK_MAGIC:
            raise PckError("embedded PCK header not found")
    version = _u32(f)
    major, minor, patch = _u32(f), _u32(f), _u32(f)
    if version not in (2, 3, 4):
        raise PckError(f"unsupported PCK format version {version}")
    flags = _u32(f)
    if flags & 1:
        raise PckError("PCK directory is encrypted; its contents cannot be verified")
    file_base = _u64(f)
    if version >= 3 or flags & 2:
        file_base += start
    if version >= 3:
        f.seek(_u64(f) + start)
    else:
        f.read(16 * 4)  # reserved
    count = _u32(f)
    if count > 1_000_000:
        raise PckError(f"implausible file count {count}")
    entries = []
    for _ in range(count):
        n = _u32(f)
        if n > 4096:
            raise PckError("implausible path length")
        path = f.read(n).rstrip(b"\0").decode("utf-8", "replace")
        if path.startswith("res://"):
            path = path[6:]
        ofs, size = _u64(f), _u64(f)
        f.read(16)  # md5
        _u32(f)     # flags
        entries.append((path, file_base + ofs, size))
    return {"version": version, "godot": f"{major}.{minor}.{patch}", "entries": entries, "file_base": file_base}


def check_name(path: str, where: str) -> list[str]:
    low = path.replace("\\", "/").lower()
    probs = [f"{where}: {path}: path contains '{t}'" for t in FORBIDDEN_TOKENS if t in low]
    if "asset_packs" in low.split("/")[:-1] and not any("asset_packs/" in p for p in probs):
        probs.append(f"{where}: {path}: inside an asset_packs folder")
    ext = clk.full_ext(low.rsplit("/", 1)[-1])
    if ext in PACKAGE_EXT or ext == ".hdpack.zip":
        probs.append(f"{where}: {path}: game/package file type '{ext}'")
    return probs


def check_pck(f: BinaryIO, label: str, db: clk.PrivateHashDB | None, listing: bool = False) -> tuple[list[str], str]:
    try:
        d = read_pck_directory(f)
    except PckError as ex:
        return [f"{label}: cannot verify PCK: {ex}"], ""
    probs: list[str] = []
    imports = remaps = ctex = raw_images = 0
    for path, ofs, size in d["entries"]:
        if listing:
            print(f"{size:>12}  {path}")
        probs += check_name(path, label)
        low = path.lower()
        if low.endswith((".import", ".remap")):
            src = path.rsplit(".", 1)[0]
            if low.endswith(".import"):
                imports += 1
            else:
                remaps += 1
            src_ext = clk.full_ext(src.lower().rsplit("/", 1)[-1])
            is_media = clk.media_kind(src_ext) is not None
            # imported media (textures, sounds) may only come from the public art folders; compiled scripts and
            # scenes (.gd.remap / .tscn.remap) are code, not art
            if (low.endswith(".import") or is_media) and not src.startswith(PUBLIC_ART_PREFIXES):
                probs.append(f"{label}: imported media from a non-public folder: {src}")
        elif low.endswith(".ctex"):
            ctex += 1
        ext = clk.full_ext(low.rsplit("/", 1)[-1])
        if ext in clk.IMAGE_EXT and ext != ".ctex":
            raw_images += 1
            if not path.startswith(PUBLIC_ART_PREFIXES):
                probs.append(f"{label}: raw image outside the public art folders: {path}")
            if db is not None and db.available and size <= 64 * 1024 * 1024:
                f.seek(ofs)
                src = db.match(f.read(size))
                if src:
                    probs.append(f"{label}: {path} is identical to a private file ({src})")
    summary = (f"{label}: PCK v{d['version']} (Godot {d['godot']}), {len(d['entries'])} entries: {imports} imported "
               f"resources, {ctex} textures, {remaps} remaps, {raw_images} raw images")
    return probs, summary


def check_target(p: Path, db: clk.PrivateHashDB | None, listing: bool, rel: str | None = None
                 ) -> tuple[list[str], list[str]]:
    """``rel`` = the name checked for forbidden tokens (relative to the folder given on the command line)."""
    probs: list[str] = []
    notes: list[str] = []
    if p.is_dir():
        for dirpath, _dirs, files in os.walk(p):
            for fn in files:
                q = Path(dirpath) / fn
                pp, nn = check_target(q, db, listing, f"{p.name}/{q.relative_to(p).as_posix()}")
                probs += pp
                notes += nn
        return probs, notes
    label = str(p)
    probs += check_name(rel or p.name, "build file")
    low = p.name.lower()
    if low.endswith(".zip"):
        try:
            with zipfile.ZipFile(p) as z:
                names = z.namelist()
                for n in names:
                    probs += check_name(n, f"{label}!")
                    ext = clk.full_ext(n.lower().rsplit("/", 1)[-1])
                    if ext in clk.IMAGE_EXT and db is not None and db.available:
                        src = db.match(z.read(n))
                        if src:
                            probs.append(f"{label}!{n}: identical to a private file ({src})")
                    if n.lower().endswith((".exe", ".pck", ".x86_64")):
                        with z.open(n) as zf, tempfile.TemporaryFile() as tf:
                            while True:
                                chunk = zf.read(1 << 20)
                                if not chunk:
                                    break
                                tf.write(chunk)
                            pp, s = check_pck(tf, f"{label}!{n}", db, listing)
                            probs += pp
                            if s:
                                notes.append(s)
                notes.append(f"{label}: zip with {len(names)} entries")
        except zipfile.BadZipFile as ex:
            probs.append(f"{label}: unreadable zip: {ex}")
        return probs, notes
    if low.endswith((".exe", ".pck", ".x86_64")) or (p.stat().st_size > 1_000_000 and _has_trailer(p)):
        with open(p, "rb") as f:
            pp, s = check_pck(f, label, db, listing)
        probs += pp
        if s:
            notes.append(s)
    return probs, notes


def _has_trailer(p: Path) -> bool:
    with open(p, "rb") as f:
        f.seek(-4, os.SEEK_END)
        return f.read(4) == PCK_MAGIC


def self_test() -> int:
    fails = []

    def pck_bytes(version: int, paths: list[str]) -> bytes:
        body = b"".join(f"data:{p}".encode() for p in paths)
        directory = struct.pack("<I", len(paths))
        ofs = 0
        for p in paths:
            pb = p.encode()
            pb += b"\0" * ((4 - len(pb) % 4) % 4)
            n = len(f"data:{p}")
            directory += struct.pack("<I", len(pb)) + pb + struct.pack("<QQ", ofs, n) + b"\0" * 16 + struct.pack("<I", 0)
            ofs += n
        if version == 2:
            head = PCK_MAGIC + struct.pack("<IIIII", 2, 4, 2, 0, 2)  # flags: relative file base
            file_base = len(head) + 8 + 64 + len(directory)
            return head + struct.pack("<Q", file_base) + b"\0" * 64 + directory + body
        head = PCK_MAGIC + struct.pack("<IIIII", version, 4, 7, 2, 2)
        file_base = len(head) + 16
        return head + struct.pack("<QQ", file_base, file_base + len(body)) + body + directory

    good = ["src/app/main.gd", "assets/placeholders/items/bakery.png.import", ".godot/imported/bakery.png-1.ctex",
            "assets/placeholders/pack.json", "assets/ui/icons.json"]
    good += ["tests/run_tests.gd.remap", "src/app/main.tscn.remap"]
    bad = good + ["asset_packs/hayday_original/pack.json", "assets/original/bakery.png.import",
                  "art/private/thing.png.import"]
    for v in (2, 3, 4):
        for embed in (False, True):
            data = pck_bytes(v, good)
            if embed:
                data = b"MZ fake executable" + data + struct.pack("<Q", len(data)) + PCK_MAGIC
            d = read_pck_directory(io.BytesIO(data))
            if [e[0] for e in d["entries"]] != good:
                fails.append(f"v{v} embed={embed}: wrong listing {d['entries']}")
            f = io.BytesIO(data)
            f.seek(d["entries"][0][1])
            if f.read(len("data:" + good[0])) != b"data:" + good[0].encode():
                fails.append(f"v{v} embed={embed}: wrong offsets")
            probs, _ = check_pck(io.BytesIO(data), "t", None)
            if probs:
                fails.append(f"v{v} embed={embed}: false positives {probs}")
        probs, _ = check_pck(io.BytesIO(pck_bytes(v, bad)), "t", None)
        if len(probs) < 4:
            fails.append(f"v{v}: expected >= 4 problems, got {probs}")
    enc = bytearray(pck_bytes(3, good))
    enc[20] |= 1  # flags word: directory encrypted
    probs, _ = check_pck(io.BytesIO(bytes(enc)), "t", None)
    if not probs or "encrypted" not in probs[0]:
        fails.append(f"encrypted directory must fail: {probs}")
    probs, _ = check_pck(io.BytesIO(b"not a pck at all" * 10), "t", None)
    if not probs:
        fails.append("non-PCK must fail")
    with tempfile.TemporaryDirectory() as td:
        z = Path(td) / "bundle.zip"
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr("windows/HaydaySandbox.exe", b"MZ" + pck_bytes(4, good) + struct.pack("<Q", len(pck_bytes(4, good)))
                        + PCK_MAGIC)
            zf.writestr("windows/licenses/OFL.txt", "x")
        probs, notes = check_target(z, None, False)
        if probs or not any("PCK v4" in n for n in notes):
            fails.append(f"zip: {probs} {notes}")
        with zipfile.ZipFile(z, "a") as zf:
            zf.writestr("windows/asset_packs/hayday_original/pack.json", "{}")
        probs, _ = check_target(z, None, False)
        if not probs:
            fails.append("zip with asset_packs must fail")
    for f in fails:
        print("SELF-TEST FAIL:", f)
    print(f"check_export_contents self-test: {'OK' if not fails else f'{len(fails)} failure(s)'}")
    return 1 if fails else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("targets", nargs="*", type=Path, help="exported binaries, .pck files, build zips or folders")
    ap.add_argument("--list", action="store_true", help="print every PCK entry")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--no-private-hashes", action="store_true")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.targets:
        ap.error("no targets given")
    db = None if args.no_private_hashes else clk.PrivateHashDB(clk.default_private_roots(),
                                                               clk.default_private_pack_dirs())
    probs: list[str] = []
    notes: list[str] = []
    for t in args.targets:
        if not t.exists():
            probs.append(f"{t}: missing")
            continue
        pp, nn = check_target(t, db, args.list)
        probs += pp
        notes += nn
    for n in notes:
        print(n)
    for p in probs:
        print("EXPORT LEAK:", p)
    if probs:
        print(f"Export content check FAILED: {len(probs)} problem(s). Exports must contain public data only "
              "(see docs/PRIVATE_ASSETS.md).")
        return 1
    print(f"Export content check OK: {len(args.targets)} target(s), no private/original art paths.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
