#!/usr/bin/env python3
"""Extract Hay Day sprites from an APK/XAPK the user ALREADY HAS, into PRIVATE storage (user-side tool).

Typical input: the APK(s) pulled from your own phone (``adb shell pm path com.supercell.hayday`` then ``adb pull``
of ``base.apk`` and any ``split_*.apk``), or an XAPK/APKS/APKM bundle, or a folder that holds those, or a folder
of already-extracted ``assets/sc`` files. The tool never downloads anything and never talks to any server.

Pipeline (sub-commands):

  verify   APK Signature Scheme v2/v3 (+ v1 JAR when pyasn1 is installed) verification of every APK in the
           input, and the signer certificate compared with the known Supercell Hay Day certificate.
  list     Inventory: counts of .sc / _tex.sc / .sctx / .ktx / .zktx / .csv files and fingerprint.json version.
  extract  verify -> copy assets/sc/* (+ fingerprint.json) -> decompress .sc -> decode texture atlases ->
           parse shapes / movie clips / matrix banks / colour transforms -> render every EXPORTED movie clip
           (its "IdleStart" frame when it has one, else frame 0) as one composited PNG, with its registration
           point recorded in index.json.

Output (default root ``/root/hayday-sandbox-private-assets``, override with ``--out`` or env
``HAYDAY_PRIVATE_ASSETS``; the tool REFUSES to write inside the git repository):

  <root>/raw/apk_extracted/<version>/assets/sc/...      raw container files copied from the APK
  <root>/raw/apk_atlases/<version>/<sc>_<i>.png         decoded atlases (only with --atlases)
  <root>/raw/apk_sprites/<version>/<sc>/<export>.png    rendered exports (movie clip frame / shape)
  <root>/raw/apk_sprites/<version>/<sc>/index.json      per export: size, origin (= registration point in PNG
                                                        pixels), scale, frame count, warnings
  <root>/raw/apk_sprites/<version>/extract_report.json  what was processed, skipped, failed and why

Huge exports (e.g. background.sc bg_edge_* / deco_layer_01, > 64 megapixels at the default scale) fail by default
(``--huge error``, recorded in index.json). ``--huge downscale`` renders them at the largest scale that fits
``--max-pixels``; ``--huge chunk`` renders them at full scale as ``<export>__chunks/r<row>_c<col>.png`` tiles
(``--chunk-size``, default 2048) whose pixel offsets are listed in the index entry's ``chunks`` (no ``file`` key).

Degenerate-uv fills (uv points on one texel or one line) are drawn: Supercell uses them for solid colours and 1-D
gradients (river water, doorways). Pure-red single-texel fills are runtime placeholder slots that the game fills
itself (collected-item icons, reward slots, emblems) and are dropped; so are exports made only of single-texel fills
(marker layers such as habitat animal slots). Such fills under screen/add blending become fills whose alpha is their
brightest channel (black = invisible, as in the game); under other non-normal blend modes they are not drawn. ``extract --only-degenerate`` re-renders only
the exports that contain degenerate-uv fills, i.e. the ones whose output changed with that fix (2026-11-09).

Nested clips are drawn at their frame 0 by default (the root clip at ``--frame`` / ``--frame-label``). Map objects keep
their ambient motion in nested clips, and a few (seasonal-creature decorations) show only a closed prop at frame 0:
``--nested-frame G`` plays every nested clip at ``G mod <its length>`` (Flash/SC playback of instances placed at frame
0), which renders a representative pose. Every index entry records ``render_rev`` (``RENDER_REV``): consumers that
cache derived renders (build_pack.py) re-render when it changes.

Every rendered PNG is proprietary Supercell art: personal use only, never commit, never redistribute.

What is TESTED (2026-11-09) on three Supercell-signed builds (signer SHA-256 2265e901...0cc1bab):
  * 1.73.89 XAPK (current; 5 split APKs): SC2 container version 5 (FlatBuffers header + Zstandard body, inline
    matrix banks with float matrices), ``.sctx`` textures with ASTC payloads, XAPK unpacking, v2/v3 verification;
  * 1.60.231 APK: "SC" v4 wrapper + version 3 + Zstandard + MD5; SC1 tags: textures 1/28 (raw, incl. 32x32 tiled)
    and 45 (embedded KTX 1.1, ASTC 4x4/6x6/8x8), shapes 18 / command 22, movie clips 12/35, matrix banks 42,
    matrices 8, colour transforms 9, modifiers 37-40, text fields (skipped); v1+v2+v3 verification;
  * 1.28.146 APK (2016): SC version 1 + LZMA, raw RGBA8888 texture tag 1, v1-only signature verification;
  * rejection of deliberately corrupted copies (one flipped byte) of a v2 APK and of a v1-only APK;
  * rendering: affine-exact polygon warping, nested matrices, colour transforms, premultiplied-alpha compositing.
    Renders were inspected by eye against nothing but plausibility (no ground truth from the game is available).
  * Masks (modifiers 38/39/40) are implemented as "mask layer alpha x masked content"; they render plausibly,
    but are NOT verified against the game.

What is IMPLEMENTED BUT UNTESTED (no sample files; treat output with suspicion):
  * raw pixel formats 2/3/4/10 and texture tags 16/19/24/27/29/34; draw-command tags 4 / 17 (UV convention
    differs between community tools); KTX with ETC1/ETC2; ``.zktx``; SCTX with RGBA8/ETC payloads; SC2 half-precision
    matrices; KTX/SCTX mip levels other than 0 are ignored.
What is NOT IMPLEMENTED (the tool reports it and skips the file):
  * SC2 version 6 ("compressed movie clips") and SC2 external delta-compressed matrix banks;
  * LZHAM-compressed SC ("SCLZ") unless the ``lzham`` module is importable;
  * text fields (rendered as nothing), 9-slice scaling grids. Blend modes: render() draws them as normal (see the
    degenerate-fill rule above); Renderer.render_layers() composites add (8), screen (4) and multiply (3) exactly
    over an opaque backdrop and returns the additive excess as a separate glow image (used by build_anims.py);
    ids 8/4 = add/screen are strong (visual), 3 = multiply and 64 (drawn as normal) are plausible / unknown.

Dependencies: Python 3.10+, Pillow, numpy, zstandard, texture2ddecoder (ASTC/ETC), cryptography
(signature check); optional pyasn1 + pyasn1-modules (v1 JAR signature check).
  python3 -m venv /tmp/hd_venv && /tmp/hd_venv/bin/pip install pillow numpy zstandard texture2ddecoder \
      cryptography pyasn1 pyasn1-modules

Usage:
  python3 tools/private_assets/extract_from_apk.py verify  ~/hayday/base.apk
  python3 tools/private_assets/extract_from_apk.py list    ~/hayday/hayday.xapk
  python3 tools/private_assets/extract_from_apk.py extract ~/hayday/base.apk --only buildings_new,decos01_generic
  python3 tools/private_assets/extract_from_apk.py extract ~/hayday/ --exports "bakery|feed_mill" --atlases
  python3 tools/private_assets/extract_from_apk.py extract <root>/raw/apk_extracted/1.73.89 --only buildings_new \
      --only-degenerate        # refresh the renders affected by the degenerate-uv fix, from already-copied files
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import lzma
import math
import os
import re
import shutil
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = Path(os.environ.get("HAYDAY_PRIVATE_ASSETS", "/root/hayday-sandbox-private-assets"))
PACKAGE = "com.supercell.hayday"

# Signer certificates seen on Supercell-published Hay Day APKs (SHA-256 of the DER certificate).
# Evidence: identical on four independently uploaded copies (1.24.92, 1.28.146, 1.54.71 XAPK incl. all splits,
# 1.60.231), subject "CN=Wayne Lu ZhongWei, OU=Hayday, O=Supercell, L=Helsinki, ST=Uusimaa, C=FI", valid from
# 2013-09-18. Repackaged/modded copies carry different certificates and are rejected by default.
KNOWN_SIGNERS = {
	"2265e9019d3e0afc1a05531d14f4ff5346a323f7edd1f7221671b764c0cc1bab": "Supercell (Hay Day, global build)",
}

SC_EXTS = (".sc", ".sctx", ".ktx", ".zktx")

# Geometry calibration measured on Hay Day 1.60.231 (see docs/research/ASSET_ACQUISITION.md): a 1x1 tile is a
# 128 x 64 SC-unit diamond and an exported map object's registration point (0,0) is the TOP (north) corner of
# its footprint (1x1 paths/fields span x -64..64, y 0..64; 2x2/3x3/4x4 buildings end at y = 128/192/~256).
# The app's world tile is 64 x 32 px, so 1 SC unit = 0.5 world px.
SC_UNITS_PER_WORLD_PX = 2.0
# Bumped whenever rendering output changes for the same input (consumers re-render cached derived images).
RENDER_REV = "2026-11-09.2"
# render_layers(): additive excess below this (0..1) is dropped (compression noise, invisible when added).
GLOW_MIN = 3.0 / 255.0
# Largest canvas rendered in one piece (RGBA float32 working layers: 16 bytes per pixel per layer).
MAX_CANVAS_PIXELS = 64_000_000


class ToolError(RuntimeError):
	pass


def log(msg: str) -> None:
	print(msg, flush=True)


def ensure_private(path: Path) -> Path:
	path = path.resolve()
	try:
		path.relative_to(REPO_ROOT)
	except ValueError:
		return path
	raise ToolError(f"refusing to write proprietary files inside the repository: {path}")


def need(module: str, pip_name: str | None = None):
	try:
		return __import__(module)
	except ImportError as ex:
		raise ToolError(f"missing Python module '{module}' (pip install {pip_name or module})") from ex


# =====================================================================================================
# Package handling: APK / XAPK / APKS / APKM / directory
# =====================================================================================================

def collect_apks(inp: Path, workdir: Path) -> list[Path]:
	"""Return paths of all APK files contained in the input (bundles are unpacked into ``workdir``)."""
	if inp.is_dir():
		apks = sorted(p for p in inp.rglob("*.apk"))
		bundles = sorted(p for p in inp.rglob("*") if p.suffix.lower() in (".xapk", ".apks", ".apkm"))
		for b in bundles:
			apks += collect_apks(b, workdir)
		return apks
	with zipfile.ZipFile(inp) as z:
		names = z.namelist()
		if "AndroidManifest.xml" in names:
			return [inp]
		inner = [n for n in names if n.lower().endswith(".apk")]
		if not inner:
			raise ToolError(f"{inp}: neither an APK nor a bundle containing APKs")
		out = []
		dest = workdir / ("bundle_" + hashlib.sha1(str(inp).encode()).hexdigest()[:10])
		dest.mkdir(parents=True, exist_ok=True)
		for n in inner:
			target = dest / Path(n).name
			if not target.exists() or target.stat().st_size != z.getinfo(n).file_size:
				with z.open(n) as src, open(target, "wb") as dst:
					shutil.copyfileobj(src, dst, 1 << 20)
			out.append(target)
		return out


# =====================================================================================================
# APK signature verification (v2 / v3 per https://source.android.com/docs/security/features/apksigning)
# =====================================================================================================

def _lp(b: bytes, p: int) -> tuple[bytes, int]:
	n = struct.unpack_from("<I", b, p)[0]
	return b[p + 4:p + 4 + n], p + 4 + n


def _seq(b: bytes) -> list[bytes]:
	out, p = [], 0
	while p < len(b):
		x, p = _lp(b, p)
		out.append(x)
	return out


_SIG_ALGS = {0x0101: ("sha256", "pss"), 0x0102: ("sha512", "pss"), 0x0103: ("sha256", "pkcs1"),
	0x0104: ("sha512", "pkcs1"), 0x0201: ("sha256", "ecdsa"), 0x0202: ("sha512", "ecdsa"),
	0x0301: ("sha256", "dsa"), 0x0421: ("sha256", "pkcs1"), 0x0423: ("sha256", "ecdsa"), 0x0425: ("sha256", "dsa")}
_VERITY_ALGS = (0x0421, 0x0423, 0x0425)


def _verify_raw(pub, alg: int, data: bytes, sig: bytes) -> None:
	from cryptography.hazmat.primitives import hashes
	from cryptography.hazmat.primitives.asymmetric import ec, padding
	h, kind = _SIG_ALGS[alg]
	H = hashes.SHA256() if h == "sha256" else hashes.SHA512()
	if kind == "pss":
		pub.verify(sig, data, padding.PSS(padding.MGF1(H), H.digest_size), H)
	elif kind == "pkcs1":
		pub.verify(sig, data, padding.PKCS1v15(), H)
	elif kind == "ecdsa":
		pub.verify(sig, data, ec.ECDSA(H))
	else:
		pub.verify(sig, data, H)


def _chunked_digest(f, sections, alg_hash: str) -> bytes:
	H = hashlib.sha256 if alg_hash == "sha256" else hashlib.sha512
	digests = []
	for start, end, override in sections:
		if override is not None:
			digests.append(H(b"\xa5" + struct.pack("<I", len(override)) + override).digest())
			continue
		f.seek(start)
		left = end - start
		while left > 0:
			chunk = f.read(min(left, 1 << 20))
			left -= len(chunk)
			digests.append(H(b"\xa5" + struct.pack("<I", len(chunk)) + chunk).digest())
	return H(b"\x5a" + struct.pack("<I", len(digests)) + b"".join(digests)).digest()


def verify_apk_v2v3(path: Path) -> dict:
	need("cryptography")
	from cryptography import x509
	from cryptography.hazmat.primitives import hashes
	res: dict = {"schemes": {}}
	with open(path, "rb") as f:
		f.seek(0, 2)
		size = f.tell()
		f.seek(max(0, size - 65557 - 22))
		tail = f.read()
		i = tail.rfind(b"PK\x05\x06")
		if i < 0:
			raise ToolError("no ZIP end-of-central-directory record")
		eocd_off = size - len(tail) + i
		eocd = tail[i:]
		cd_off = struct.unpack_from("<I", eocd, 16)[0]
		f.seek(cd_off - 24)
		footer = f.read(24)
		if footer[8:] != b"APK Sig Block 42":
			res["absent"] = "no APK Signing Block (v1-only APK, typical before 2017)"
			return res
		bsize = struct.unpack_from("<Q", footer)[0]
		blk_off = cd_off - bsize - 8
		f.seek(blk_off)
		blk = f.read(bsize + 8)
		pairs, p, blocks = blk[8:-24], 0, {}
		while p < len(pairs):
			ln = struct.unpack_from("<Q", pairs, p)[0]
			pid = struct.unpack_from("<I", pairs, p + 8)[0]
			blocks[pid] = pairs[p + 12:p + 8 + ln]
			p += 8 + ln
		sections = [(0, blk_off, None), (cd_off, eocd_off, None),
			(0, 0, eocd[:16] + struct.pack("<I", blk_off) + eocd[20:])]
		for pid, name in ((0x7109871a, "v2"), (0xf05368c0, "v3")):
			if pid not in blocks:
				continue
			signers = []
			for signer in _seq(_lp(blocks[pid], 0)[0]):
				signed_data, q = _lp(signer, 0)
				if name == "v3":
					q += 8  # minSdk, maxSdk
				sigs_b, q = _lp(signer, q)
				digests_b, r = _lp(signed_data, 0)
				certs_b, r = _lp(signed_data, r)
				cert = x509.load_der_x509_certificate(_seq(certs_b)[0])
				pub = cert.public_key()
				sig_ok = []
				for s in _seq(sigs_b):
					alg = struct.unpack_from("<I", s)[0]
					if alg in _SIG_ALGS:
						_verify_raw(pub, alg, signed_data, _lp(s, 4)[0])  # raises InvalidSignature
						sig_ok.append(hex(alg))
				dig_ok = []
				for d in _seq(digests_b):
					alg = struct.unpack_from("<I", d)[0]
					if alg in _SIG_ALGS and alg not in _VERITY_ALGS:
						if _chunked_digest(f, sections, _SIG_ALGS[alg][0]) != _lp(d, 4)[0]:
							raise ToolError(f"{name}: content digest mismatch -> file was modified")
						dig_ok.append(hex(alg))
				if not sig_ok or not dig_ok:
					raise ToolError(f"{name}: no supported signature/digest algorithm")
				signers.append({"subject": cert.subject.rfc4514_string(),
					"sha256": cert.fingerprint(hashes.SHA256()).hex(), "signature_algs": sig_ok,
					"digest_algs": dig_ok})
			res["schemes"][name] = signers
		res["other_blocks"] = sorted(hex(k) for k in blocks if k not in (0x7109871a, 0xf05368c0))
	return res


def verify_apk_v1(path: Path) -> dict:
	"""JAR signature: PKCS#7 over the .SF file, .SF digest of MANIFEST.MF, MANIFEST digests of all entries."""
	try:
		from pyasn1.codec.der import decoder, encoder
		from pyasn1_modules import rfc2315
	except ImportError:
		return {"skipped": "pyasn1/pyasn1-modules not installed"}
	from cryptography.hazmat.primitives import hashes
	from cryptography.hazmat.primitives.asymmetric import padding
	from cryptography.hazmat.primitives.serialization import pkcs7
	with zipfile.ZipFile(path) as z:
		names = z.namelist()
		sig_files = [n for n in names if re.match(r"META-INF/[^/]+\.(RSA|DSA|EC)$", n, re.I)]
		if not sig_files:
			return {"skipped": "no v1 signature"}
		blob = z.read(sig_files[0])
		sf = z.read(sig_files[0].rsplit(".", 1)[0] + ".SF")
		mf = z.read("META-INF/MANIFEST.MF")
		ci, _ = decoder.decode(blob, asn1Spec=rfc2315.ContentInfo())
		sd, _ = decoder.decode(ci["content"], asn1Spec=rfc2315.SignedData())
		cert = pkcs7.load_der_pkcs7_certificates(blob)[0]
		si = sd["signerInfos"][0]
		oid = str(si["digestAlgorithm"]["algorithm"])
		H = {"2.16.840.1.101.3.4.2.1": hashes.SHA256(), "1.3.14.3.2.26": hashes.SHA1(),
			"2.16.840.1.101.3.4.2.3": hashes.SHA512()}[oid]
		signed = sf
		if si["authenticatedAttributes"].hasValue():
			attrs = si["authenticatedAttributes"]
			signed = b"\x31" + encoder.encode(attrs)[1:]
			md = [a for a in attrs if str(a["type"]) == "1.2.840.113549.1.9.4"][0]
			if bytes(decoder.decode(bytes(md["values"][0]))[0]) != hashlib.new(H.name.replace("-", ""), sf).digest():
				raise ToolError("v1: messageDigest mismatch")
		cert.public_key().verify(bytes(si["encryptedDigest"]), signed, padding.PKCS1v15(), H)
		algmap = {"SHA-256": "sha256", "SHA1": "sha1", "SHA-1": "sha1", "SHA-512": "sha512"}
		m = re.search(r"(SHA-256|SHA1|SHA-1|SHA-512)-Digest-Manifest: (\S+)", sf.decode("utf-8", "replace"))
		if not m or base64.b64decode(m.group(2)) != hashlib.new(algmap[m.group(1)], mf).digest():
			raise ToolError("v1: .SF does not match MANIFEST.MF")
		text = mf.decode("utf-8").replace("\r\n", "\n").replace("\n ", "")
		want = {}
		for block in text.split("\n\n"):
			nm = re.search(r"^Name: (.+)$", block, re.M)
			dg = re.search(r"^(SHA-256|SHA1|SHA-1|SHA-512)-Digest: (\S+)$", block, re.M)
			if nm and dg:
				want[nm.group(1)] = (algmap[dg.group(1)], base64.b64decode(dg.group(2)))
		bad, checked = [], 0
		for n in names:
			if n.startswith("META-INF/") or n.endswith("/"):
				continue
			if n not in want:
				bad.append(f"unsigned entry {n}")
				continue
			h = hashlib.new(want[n][0])
			with z.open(n) as fh:
				for chunk in iter(lambda: fh.read(1 << 20), b""):
					h.update(chunk)
			if h.digest() != want[n][1]:
				bad.append(f"digest mismatch {n}")
			checked += 1
	from cryptography.hazmat.primitives import hashes as _h
	return {"subject": cert.subject.rfc4514_string(), "sha256": cert.fingerprint(_h.SHA256()).hex(),
		"entries_checked": checked, "problems": bad[:20], "problem_count": len(bad)}


def verify_apk(path: Path) -> dict:
	out = {"file": str(path), "size": path.stat().st_size}
	try:
		out["v2v3"] = verify_apk_v2v3(path)
	except Exception as ex:  # noqa: BLE001 - any failure means "not verified"
		out["v2v3"] = {"error": f"{type(ex).__name__}: {ex}"}
	try:
		out["v1"] = verify_apk_v1(path)
	except Exception as ex:  # noqa: BLE001
		out["v1"] = {"error": f"{type(ex).__name__}: {ex}"}
	certs = set()
	for signers in out["v2v3"].get("schemes", {}).values():
		certs.update(s["sha256"] for s in signers)
	if not certs and "sha256" in out["v1"] and not out["v1"].get("problem_count"):
		certs.add(out["v1"]["sha256"])
	v1_ok = "sha256" in out["v1"] and not out["v1"].get("problem_count") and not out["v1"].get("error")
	v2_ok = bool(out["v2v3"].get("schemes")) and "error" not in out["v2v3"]
	out["signer_sha256"] = sorted(certs)
	# v2/v3 (whole-file) wins when present; a v1-only APK needs a clean v1 check. Any v2/v3 error = rejected.
	out["verified"] = "error" not in out["v2v3"] and (v2_ok or (v1_ok and "absent" in out["v2v3"]))
	out["known_signer"] = [KNOWN_SIGNERS[c] for c in certs if c in KNOWN_SIGNERS]
	out["accepted"] = out["verified"] and len(certs) == 1 and bool(out["known_signer"])
	return out


# =====================================================================================================
# SC containers
# =====================================================================================================

def decompress_sc(data: bytes, name: str = "") -> tuple[bytes, dict]:
	"""Return (decompressed body, info). Raises ToolError for unsupported variants."""
	info: dict = {}
	if data[:4] == b"Sig:":
		data = data[68:]
		info["signed"] = True
	if data[:2] != b"SC":
		# headerless legacy LZMA (props byte 0x5D)
		if data[:1] in (b"\x5d", b"\x5e"):
			info["container"] = "headerless-lzma"
			return _lzma_sc(data), info
		raise ToolError(f"{name}: not an SC container")
	ver = struct.unpack_from(">I", data, 2)[0]
	p = 6
	if ver > 0xFFFF:  # little-endian version => SC2 (v5/v6)
		raise ToolError(f"{name}: SC2 container (version {struct.unpack_from('<I', data, 2)[0]}) is not supported")
	if ver == 4:
		ver = struct.unpack_from(">I", data, p)[0]
		p += 4
		info["wrapper"] = 4
	if ver in (5, 6):
		raise ToolError(f"{name}: SC2 container (version {ver}) is not supported")
	hl = struct.unpack_from(">I", data, p)[0]
	p += 4
	md5 = data[p:p + hl]
	p += hl
	body = data[p:]
	info["version"] = ver
	if body[:4] == b"\x28\xb5\x2f\xfd":
		zstd = need("zstandard")
		out = zstd.ZstdDecompressor().decompressobj().decompress(body)
		info["compression"] = "zstd"
	elif body[:4] == b"SCLZ":
		try:
			import lzham  # type: ignore
		except ImportError as ex:
			raise ToolError(f"{name}: LZHAM-compressed SC needs the 'lzham' module (pylzham)") from ex
		dict_log2 = body[4]
		usize = struct.unpack_from("<I", body, 5)[0]
		out = lzham.decompress(body[9:], usize, {"dict_size_log2": dict_log2})
		info["compression"] = "lzham"
	elif body[:1] in (b"\x5d", b"\x5e"):
		out = _lzma_sc(body)
		info["compression"] = "lzma"
	elif ver == 2:
		out = body
		info["compression"] = "none"
	else:
		raise ToolError(f"{name}: unknown compression {body[:4].hex()}")
	if hl == 16:
		info["md5_ok"] = hashlib.md5(out).digest() == md5
	return out, info


def _lzma_sc(body: bytes) -> bytes:
	# Supercell's LZMA header: 5 props bytes + 4-byte size; standard .lzma uses an 8-byte size.
	fixed = body[:9] + b"\x00\x00\x00\x00" + body[9:]
	return lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(fixed)


# =====================================================================================================
# Textures
# =====================================================================================================

_KTX_ASTC = {0x93B0: (4, 4), 0x93B1: (5, 4), 0x93B2: (5, 5), 0x93B3: (6, 5), 0x93B4: (6, 6), 0x93B5: (8, 5),
	0x93B6: (8, 6), 0x93B7: (8, 8), 0x93B8: (10, 5), 0x93B9: (10, 6), 0x93BA: (10, 8), 0x93BB: (10, 10),
	0x93BC: (12, 10), 0x93BD: (12, 12)}
_KTX_ASTC.update({k + 0x20: v for k, v in list(_KTX_ASTC.items())})  # sRGB variants 0x93D0..


def decode_ktx(data: bytes):
	"""KTX 1.1 -> PIL RGBA image (straight channel order, alpha as stored)."""
	from PIL import Image
	if data[:12] != b"\xabKTX 11\xbb\r\n\x1a\n":
		if data[:12] == b"\xabKTX 20\xbb\r\n\x1a\n":
			raise ToolError("KTX2 textures are not supported")
		raise ToolError("not a KTX file")
	little = struct.unpack_from("<I", data, 12)[0] == 0x04030201
	e = "<" if little else ">"
	(_, gltype, _, glformat, glif, _, w, h, _, _, _, _, kvlen) = struct.unpack_from(e + "13I", data, 12)
	p = 64 + kvlen
	size = struct.unpack_from(e + "I", data, p)[0]
	payload = data[p + 4:p + 4 + size]
	t2d = need("texture2ddecoder")
	if glif in _KTX_ASTC:
		bw, bh = _KTX_ASTC[glif]
		raw = t2d.decode_astc(payload, w, h, bw, bh)
	elif glif == 0x8D64:  # ETC1 (UNTESTED)
		raw = t2d.decode_etc1(payload, w, h)
	elif glif in (0x9274, 0x9275):  # ETC2 RGB (UNTESTED)
		raw = t2d.decode_etc2(payload, w, h)
	elif glif in (0x9278, 0x9279):  # ETC2 RGBA (UNTESTED)
		raw = t2d.decode_etc2a8(payload, w, h)
	elif gltype == 0x1401 and glformat == 0x1908:  # plain RGBA8 (UNTESTED)
		return Image.frombytes("RGBA", (w, h), payload)
	else:
		raise ToolError(f"unsupported KTX internal format 0x{glif:04x}")
	return Image.frombytes("RGBA", (w, h), raw, "raw", "BGRA")  # texture2ddecoder returns BGRA


_PIXEL_BYTES = {0: 4, 1: 4, 2: 2, 3: 2, 4: 2, 5: 4, 6: 2, 10: 1}


def decode_raw_pixels(pf: int, w: int, h: int, data: bytes, tiled: bool):
	import numpy as np
	from PIL import Image
	bpp = _PIXEL_BYTES.get(pf)
	if bpp is None:
		raise ToolError(f"unsupported raw pixel format {pf}")
	need_len = w * h * bpp
	buf = data[:need_len]
	if len(buf) < need_len:
		raise ToolError(f"texture data too short ({len(buf)} < {need_len})")
	if tiled:  # 32x32 blocks, row-major block order
		lin = bytearray(need_len)
		p = 0
		for by in range(0, h, 32):
			for bx in range(0, w, 32):
				bw = min(32, w - bx) * bpp
				for y in range(by, min(by + 32, h)):
					i = (y * w + bx) * bpp
					lin[i:i + bw] = buf[p:p + bw]
					p += bw
		buf = bytes(lin)
	if pf in (0, 1, 5):
		return Image.frombytes("RGBA", (w, h), buf)
	a = np.frombuffer(buf, dtype="<u2" if bpp == 2 else np.uint8).reshape(h, w)
	if pf == 2:  # RGBA4444
		rgba = np.stack([(a >> 12) & 15, (a >> 8) & 15, (a >> 4) & 15, a & 15], -1).astype(np.uint8) * 17
	elif pf == 3:  # RGBA5551
		r, g, b = (a >> 11) & 31, (a >> 6) & 31, (a >> 1) & 31
		rgba = np.stack([r * 255 // 31, g * 255 // 31, b * 255 // 31, (a & 1) * 255], -1).astype(np.uint8)
	elif pf == 4:  # RGB565
		r, g, b = (a >> 11) & 31, (a >> 5) & 63, a & 31
		rgba = np.stack([r * 255 // 31, g * 255 // 63, b * 255 // 31, np.full_like(a, 255)], -1).astype(np.uint8)
	elif pf == 6:  # LA88: low byte = alpha? Tools store (L, A) pairs
		la = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 2)
		rgba = np.dstack([la[..., 1], la[..., 1], la[..., 1], la[..., 0]])
	elif pf == 10:  # L8
		rgba = np.dstack([a, a, a, np.full_like(a, 255)])
	else:
		raise ToolError(f"unsupported raw pixel format {pf}")
	return Image.fromarray(np.ascontiguousarray(rgba), "RGBA")


# =====================================================================================================
# SC1 parser
# =====================================================================================================

TEXTURE_TAGS = (1, 16, 19, 24, 27, 28, 29, 34, 45, 47)
SHAPE_TAGS = (2, 18)
CLIP_TAGS = (3, 10, 12, 14, 35, 49)
TEXTFIELD_TAGS = (7, 15, 20, 21, 25, 33, 43, 44, 46)
MODIFIER_TAGS = (38, 39, 40)


class Reader:
	__slots__ = ("b", "p")

	def __init__(self, b: bytes, p: int = 0):
		self.b, self.p = b, p

	def u8(self) -> int:
		v = self.b[self.p]
		self.p += 1
		return v

	def u16(self) -> int:
		v = struct.unpack_from("<H", self.b, self.p)[0]
		self.p += 2
		return v

	def i32(self) -> int:
		v = struct.unpack_from("<i", self.b, self.p)[0]
		self.p += 4
		return v

	def string(self) -> str | None:
		n = self.u8()
		if n == 0xFF:
			return None
		s = self.b[self.p:self.p + n].decode("utf-8", "replace")
		self.p += n
		return s


class Texture:
	def __init__(self, tag: int, pf: int, w: int, h: int):
		self.tag, self.pf, self.w, self.h = tag, pf, w, h
		self.data: bytes | None = None
		self.ktx: bytes | None = None
		self.external: str | None = None
		self.image = None  # PIL image, mode RGBa (premultiplied)


class Command:
	__slots__ = ("tag", "tex", "xy", "uv")

	def __init__(self, tag, tex, xy, uv):
		self.tag, self.tex, self.xy, self.uv = tag, tex, xy, uv


class Shape:
	def __init__(self, sid: int):
		self.id = sid
		self.commands: list[Command] = []


class Clip:
	def __init__(self, cid: int):
		self.id = cid
		self.fps = 0
		self.frame_count = 0
		self.elements: list[tuple[int, int, int]] = []
		self.children: list[int] = []
		self.blends: list[int] = []
		self.names: list[str | None] = []
		self.frames: list[tuple[int, str | None]] = []
		self.bank = 0
		self.scaling_grid = None
		self.tag = 0


class Swf:
	def __init__(self, name: str):
		self.name = name
		self.textures: list[Texture] = []
		self.shapes: dict[int, Shape] = {}
		self.clips: dict[int, Clip] = {}
		self.textfields: set[int] = set()
		self.modifiers: dict[int, int] = {}
		self.banks: list[dict] = []
		self.exports: list[tuple[int, str]] = []
		self.flags: dict = {}
		self.unknown_tags: dict[int, int] = {}
		self.draw_tags: dict[int, int] = {}


def parse_sc(body: bytes, name: str, is_tex: bool, swf: Swf | None = None) -> Swf:
	swf = swf or Swf(name)
	r = Reader(body)
	if not is_tex:
		counts = struct.unpack_from("<6H", body, 0)
		r.p = 12 + 5
		swf.banks = [{"m": [], "c": []}]
		n_exp = r.u16()
		ids = [r.u16() for _ in range(n_exp)]
		swf.exports = [(i, r.string() or "") for i in ids]
		swf.flags["header_counts"] = dict(zip(("shapes", "clips", "textures", "textfields", "matrices",
			"colors"), counts))
	tex_i = 0
	while r.p < len(body):
		tag = r.u8()
		length = r.i32()
		start = r.p
		if tag == 0:
			break
		b = Reader(body, start)
		if tag in TEXTURE_TAGS:
			ext = None
			if tag == 47:
				ext = b.string()
			has_data = is_tex or not swf.flags.get("external_texture")
			klen = b.i32() if (tag == 45 and has_data) else None
			pf, w, h = b.u8(), b.u16(), b.u16()
			if is_tex and tex_i < len(swf.textures):
				t = swf.textures[tex_i]
				t.tag, t.pf, t.w, t.h = tag, pf, w, h
			else:
				t = Texture(tag, pf, w, h)
				swf.textures.append(t)
			t.external = ext
			if has_data:
				if klen is not None:
					t.ktx = body[b.p:b.p + klen]
				elif ext is None:
					t.data = body[b.p:start + length]
			tex_i += 1
		elif tag in SHAPE_TAGS:
			s = Shape(b.u16())
			n_cmd = b.u16()
			if tag == 18:
				b.u16()  # total vertex count
			while True:
				ct = b.u8()
				cl = b.i32()
				cs = b.p
				if ct == 0:
					break
				if ct in (4, 17, 22):
					ti = b.u8()
					n = 4 if ct == 4 else b.u8()
					xy = [(b.i32() / 20.0, b.i32() / 20.0) for _ in range(n)]
					uv = [(b.u16(), b.u16()) for _ in range(n)]
					s.commands.append(Command(ct, ti, xy, uv))
					swf.draw_tags[ct] = swf.draw_tags.get(ct, 0) + 1
				b.p = cs + cl
			if len(s.commands) != n_cmd:
				swf.flags.setdefault("shape_count_mismatch", []).append(s.id)
			swf.shapes[s.id] = s
		elif tag in CLIP_TAGS:
			c = Clip(b.u16())
			c.tag = tag
			c.fps = b.u8()
			c.frame_count = b.u16()
			if tag in (3, 14):
				swf.flags.setdefault("deprecated_clip_tags", []).append(c.id)
				r.p = start + length
				continue
			if tag == 49:
				for _ in range(b.u8()):
					pt = b.u8()
					if pt != 0:
						raise ToolError(f"{name}: unknown movie clip custom property type {pt}")
					b.u8()
			n_el = b.i32()
			c.elements = [struct.unpack_from("<3H", body, b.p + 6 * k) for k in range(n_el)]
			b.p += 6 * n_el
			n_ch = b.u16()
			c.children = [b.u16() for _ in range(n_ch)]
			if tag == 12 or tag >= 35:
				c.blends = [b.u8() for _ in range(n_ch)]
			c.names = [b.string() for _ in range(n_ch)]
			while True:
				ft = b.u8()
				fl = b.i32()
				fs = b.p
				if ft == 0:
					break
				if ft == 11:
					c.frames.append((b.u16(), b.string()))
				elif ft == 41:
					c.bank = b.u8()
				elif ft == 31:
					c.scaling_grid = tuple(b.i32() / 20.0 for _ in range(4))
				b.p = fs + fl
			swf.clips[c.id] = c
		elif tag in TEXTFIELD_TAGS:
			swf.textfields.add(b.u16())
		elif tag == 8 or tag == 36:
			div = 1024.0 if tag == 8 else 65535.0
			a, bb, cc, d = (b.i32() / div for _ in range(4))
			swf.banks[-1]["m"].append((a, bb, cc, d, b.i32() / 20.0, b.i32() / 20.0))
		elif tag == 9:
			ra, ga, ba, al, rm, gm, bm = (b.u8() for _ in range(7))
			swf.banks[-1]["c"].append(((rm, gm, bm, al), (ra, ga, ba)))
		elif tag == 42:
			swf.banks.append({"m": [], "c": []})
		elif tag in MODIFIER_TAGS:
			swf.modifiers[b.u16()] = tag
		elif tag == 26:
			swf.flags["external_texture"] = True
		elif tag == 23:
			swf.flags["lowres"] = True
		elif tag == 30:
			swf.flags["multires"] = True
		elif tag == 32:
			swf.flags["suffixes"] = (b.string(), b.string())
		elif tag == 37:
			pass
		else:
			swf.unknown_tags[tag] = swf.unknown_tags.get(tag, 0) + 1
		r.p = start + length
	return swf


# =====================================================================================================
# SC2 (container version 5) and SCTX: minimal FlatBuffers reader, field order from SupercellFlash's
# sc2_schemas/*.fbs and SupercellTexture's sctx_schemas/*.fbs (MIT, read as format documentation only).
# =====================================================================================================

class FB:
	"""Read-only view of one FlatBuffers table."""
	__slots__ = ("b", "pos", "vt", "vlen")

	def __init__(self, b: bytes, pos: int):
		self.b, self.pos = b, pos
		self.vt = pos - struct.unpack_from("<i", b, pos)[0]
		self.vlen = struct.unpack_from("<H", b, self.vt)[0]

	@classmethod
	def root(cls, b: bytes, off: int = 0) -> "FB":
		return cls(b, off + struct.unpack_from("<I", b, off)[0])

	def _field(self, i: int) -> int | None:
		o = 4 + 2 * i
		if o >= self.vlen:
			return None
		rel = struct.unpack_from("<H", self.b, self.vt + o)[0]
		return self.pos + rel if rel else None

	def scalar(self, i: int, fmt: str, default=0):
		p = self._field(i)
		return default if p is None else struct.unpack_from("<" + fmt, self.b, p)[0]

	def _target(self, i: int) -> int | None:
		p = self._field(i)
		return None if p is None else p + struct.unpack_from("<I", self.b, p)[0]

	def table(self, i: int) -> "FB | None":
		t = self._target(i)
		return None if t is None else FB(self.b, t)

	def string(self, i: int) -> str | None:
		t = self._target(i)
		if t is None:
			return None
		n = struct.unpack_from("<I", self.b, t)[0]
		return self.b[t + 4:t + 4 + n].decode("utf-8", "replace")

	def vector(self, i: int) -> tuple[int, int]:
		"""(start, length) of a vector field; (0, 0) when absent."""
		t = self._target(i)
		if t is None:
			return 0, 0
		return t + 4, struct.unpack_from("<I", self.b, t)[0]

	def bytes_(self, i: int) -> bytes:
		s, n = self.vector(i)
		return self.b[s:s + n]

	def scalars(self, i: int, fmt: str) -> list:
		s, n = self.vector(i)
		return list(struct.unpack_from("<%d%s" % (n, fmt), self.b, s)) if n else []

	def tables(self, i: int) -> list["FB"]:
		s, n = self.vector(i)
		return [FB(self.b, s + 4 * k + struct.unpack_from("<I", self.b, s + 4 * k)[0]) for k in range(n)]

	def strings(self, i: int) -> list[str]:
		s, n = self.vector(i)
		out = []
		for k in range(n):
			t = s + 4 * k + struct.unpack_from("<I", self.b, s + 4 * k)[0]
			ln = struct.unpack_from("<I", self.b, t)[0]
			out.append(self.b[t + 4:t + 4 + ln].decode("utf-8", "replace"))
		return out


def _strip_to_polygon(n: int) -> list[int]:
	"""Vertex order that turns a triangle strip into its outline polygon (0, odd ascending, even descending)."""
	return [0] + list(range(1, n, 2)) + list(range(((n - 1) // 2) * 2, 0, -2))


def is_sc2(data: bytes) -> bool:
	return data[:2] == b"SC" and struct.unpack_from(">I", data, 2)[0] > 0xFFFF


def parse_sc2(data: bytes, name: str) -> Swf:
	"""SC2 container (version 5 tested; 6 = 'compressed movie clips' is refused)."""
	zstd = need("zstandard")
	ver = struct.unpack_from("<I", data, 2)[0]
	if ver != 5:
		raise ToolError(f"{name}: SC2 version {ver} is not supported (only 5)")
	p = 6
	dsize = struct.unpack_from("<I", data, p)[0]
	p += 4
	hdr = FB.root(data[p:p + dsize])
	p += dsize
	swf = Swf(name)
	tprec, sprec = hdr.scalar(0, "I"), hdr.scalar(1, "I")
	mult = {2: 20.0, 3: 1024.0}
	tm, sm = mult.get(tprec, 1.0), mult.get(sprec, 1.0)
	res_off = hdr.scalar(8, "I")
	csize = hdr.scalar(11, "I")
	ext_banks = hdr.scalar(12, "I")
	if ext_banks:
		raise ToolError(f"{name}: SC2 external (delta-compressed) matrix banks are not supported")
	body_src = data[p:p + csize] if csize else data[p:]
	body = zstd.ZstdDecompressor().decompressobj().decompress(body_src) \
		if body_src[:4] == b"\x28\xb5\x2f\xfd" else body_src
	swf.flags["sc2"] = {"version": ver, "translation_precision": tprec, "scale_precision": sprec}
	ds_size = struct.unpack_from("<I", body, 0)[0]
	ds = FB.root(body[4:4 + ds_size])
	strings = ds.strings(0)
	elements = ds.scalars(4, "H")
	pts_s, pts_n = ds.vector(5)
	pts = ds.b[pts_s:pts_s + pts_n]
	for bank in ds.tables(6):
		m_s, m_n = bank.vector(0)
		c_s, c_n = bank.vector(1)
		h_s, h_n = bank.vector(2)
		mats = [struct.unpack_from("<6f", bank.b, m_s + 24 * k) for k in range(m_n)]
		if not mats and h_n:
			mats = []
			for k in range(h_n):
				a, b_, c, d, tx, ty = struct.unpack_from("<6h", bank.b, h_s + 12 * k)
				mats.append((a / sm, b_ / sm, c / sm, d / sm, tx / tm, ty / tm))
		cts = []
		for k in range(c_n):
			rm, gm, bm, al, ra, ga, ba = struct.unpack_from("<7B", bank.b, c_s + 7 * k)
			cts.append(((rm, gm, bm, al), (ra, ga, ba)))
		swf.banks.append({"m": mats, "c": cts})
	if not swf.banks:
		swf.banks = [{"m": [], "c": []}]
	q = res_off
	chunks = []
	for _ in range(6):
		if q + 4 > len(body):
			break
		n = struct.unpack_from("<I", body, q)[0]
		chunks.append(body[q + 4:q + 4 + n])
		q += 4 + n
	while len(chunks) < 6:
		chunks.append(b"")
	ex_b, tf_b, sh_b, mc_b, mod_b, tx_b = chunks
	if ex_b:
		e = FB.root(ex_b)
		ids, refs = e.scalars(0, "H"), e.scalars(1, "I")
		swf.exports = [(i, strings[r] if r < len(strings) else "") for i, r in zip(ids, refs)]
	if tf_b:
		t = FB.root(tf_b)
		s, n = t.vector(0)
		for k in range(n):
			swf.textfields.add(struct.unpack_from("<H", t.b, s + 40 * k)[0])
	if sh_b:
		for sh in FB.root(sh_b).tables(0):
			shape = Shape(sh.scalar(0, "H"))
			cs, cn = sh.vector(1)
			for k in range(cn):
				_, ti, npts, poff = struct.unpack_from("<4I", sh.b, cs + 16 * k)
				verts = [struct.unpack_from("<2f2H", pts, (poff + v) * 12) for v in range(npts)]
				order = _strip_to_polygon(npts)
				xy = [(verts[i][0], verts[i][1]) for i in order]
				uv = [(verts[i][2], verts[i][3]) for i in order]
				shape.commands.append(Command(22, ti, xy, uv))
				swf.draw_tags["sc2"] = swf.draw_tags.get("sc2", 0) + 1
			swf.shapes[shape.id] = shape
	if mc_b:
		for mc in FB.root(mc_b).tables(0):
			c = Clip(mc.scalar(0, "H"))
			c.tag = "sc2"
			c.fps = mc.scalar(2, "B")
			c.frame_count = mc.scalar(3, "H")
			c.children = mc.scalars(5, "H")
			c.names = [strings[r] if r < len(strings) else None for r in mc.scalars(6, "I")]
			c.blends = mc.scalars(7, "B")
			fs, fn = mc.vector(8)
			if fn:
				c.frames = [(struct.unpack_from("<I", mc.b, fs + 8 * k)[0],
					strings[struct.unpack_from("<I", mc.b, fs + 8 * k + 4)[0]] or None) for k in range(fn)]
			else:
				c.frames = [(n, None) for n in mc.scalars(12, "H")]
			off = mc.scalar(9, "I", 0xFFFFFFFF)
			total = sum(n for n, _ in c.frames)
			if off != 0xFFFFFFFF:
				c.elements = [tuple(elements[off + 3 * k:off + 3 * k + 3]) for k in range(total)]
			c.bank = mc.scalar(10, "I")
			swf.clips[c.id] = c
	if mod_b:
		m = FB.root(mod_b)
		s, n = m.vector(0)
		for k in range(n):
			mid, mtype = struct.unpack_from("<HB", m.b, s + 4 * k)
			swf.modifiers[mid] = mtype
	if tx_b:
		for ts in FB.root(tx_b).tables(0):
			hi = ts.table(1)
			if hi is None:
				continue
			t = Texture(47, hi.scalar(1, "B"), hi.scalar(2, "H"), hi.scalar(3, "H"))
			t.external = hi.string(5)
			if not t.external:
				fmt = hi.scalar(0, "B")
				blob = hi.bytes_(4)
				if fmt & 8:
					t.ktx = blob
				else:
					t.data = blob
			swf.textures.append(t)
	return swf


_SCTX_ASTC = {}
for _base in (186, 204):  # sRGB / linear; 4x4 5x4 5x5 6x5 6x6, then (base+6..) 8x5 8x6 8x8 10x5 10x6 10x8 10x10 12x10 12x12
	for _k, _blk in enumerate(((4, 4), (5, 4), (5, 5), (6, 5), (6, 6))):
		_SCTX_ASTC[_base + _k] = _blk
	for _k, _blk in enumerate(((8, 5), (8, 6), (8, 8), (10, 5), (10, 6), (10, 8), (10, 10), (12, 10), (12, 12))):
		_SCTX_ASTC[_base + 6 + _k] = _blk


def decode_sctx(data: bytes):
	"""Supercell streaming texture (.sctx) -> PIL RGBA image (level 0)."""
	from PIL import Image
	p = 0
	hlen = struct.unpack_from("<I", data, p)[0]
	p += 4
	hb = data[p:p + hlen]
	p += hlen
	if hb[4:8] != b"SCTX":
		raise ToolError("not an SCTX header")
	h = FB.root(hb)
	ptype, w, hgt = h.scalar(1, "I"), h.scalar(2, "H"), h.scalar(3, "H")
	levels, flags = h.scalar(4, "B", 1), h.scalar(6, "I")
	mlen = struct.unpack_from("<I", data, p)[0]
	p += 4
	data_off = p + mlen
	offsets = []
	for _ in range(levels):
		ln = struct.unpack_from("<I", data, p)[0]
		mm = FB.root(data[p + 4:p + 4 + ln])
		offsets.append((mm.scalar(0, "H"), mm.scalar(1, "H"), mm.scalar(2, "I")))
		p += 4 + ln
	p = data_off
	if flags & 8:  # use_padding
		p = (p + 15) & ~15
	payload = data[p:]
	if payload[:4] == b"\x28\xb5\x2f\xfd":
		payload = need("zstandard").ZstdDecompressor().decompressobj().decompress(payload)
	lw, lh, loff = offsets[0] if offsets else (w, hgt, 0)
	end = offsets[1][2] if len(offsets) > 1 else len(payload)
	lvl = payload[loff:end]
	t2d = need("texture2ddecoder")
	if ptype in _SCTX_ASTC:
		bw, bh = _SCTX_ASTC[ptype]
		raw = t2d.decode_astc(lvl, lw, lh, bw, bh)
		return Image.frombytes("RGBA", (lw, lh), raw, "raw", "BGRA")
	if ptype == 70:  # RGBA8 (UNTESTED)
		return Image.frombytes("RGBA", (lw, lh), lvl[:lw * lh * 4])
	if ptype in (178, 179):  # ETC2 EAC RGBA8 (UNTESTED)
		return Image.frombytes("RGBA", (lw, lh), t2d.decode_etc2a8(lvl, lw, lh), "raw", "BGRA")
	if ptype == 263:  # ETC1 (UNTESTED)
		return Image.frombytes("RGBA", (lw, lh), t2d.decode_etc1(lvl, lw, lh), "raw", "BGRA")
	raise ToolError(f"unsupported SCTX pixel type {ptype}")


def load_textures(swf: Swf, premultiplied: str = "auto", external=None) -> list[str]:
	"""Decode texture images into premultiplied 'RGBa' PIL images. Returns warnings.

	``external(name) -> bytes | None`` resolves external texture files (.sctx / .ktx / .zktx)."""
	import numpy as np
	from PIL import Image
	warns = []
	for i, t in enumerate(swf.textures):
		try:
			if t.ktx is not None:
				img = decode_ktx(t.ktx)
			elif t.data is not None:
				img = decode_raw_pixels(t.pf, t.w, t.h, t.data, tiled=t.tag in (27, 28, 29))
			elif t.external:
				blob = external(t.external) if external else None
				if blob is None:
					raise ToolError(f"external texture file '{t.external}' not found")
				low = t.external.lower()
				if low.endswith(".sctx"):
					img = decode_sctx(blob)
				elif low.endswith(".zktx"):  # UNTESTED
					img = decode_ktx(need("zstandard").ZstdDecompressor().decompressobj().decompress(blob))
				elif low.endswith(".ktx"):  # UNTESTED
					img = decode_ktx(blob)
				else:
					raise ToolError(f"unknown external texture type '{t.external}'")
				if img.size != (t.w, t.h) and t.w and t.h:
					warns.append(f"texture {i}: size {img.size} differs from declared {(t.w, t.h)}")
			else:
				raise ToolError("texture has no data (missing _tex.sc?)")
		except ToolError as ex:
			warns.append(f"texture {i}: {ex}")
			t.image = None
			continue
		a = np.asarray(img, dtype=np.uint8)
		alpha = a[..., 3:4].astype(np.uint16)
		semi = (alpha[..., 0] > 0) & (alpha[..., 0] < 255)
		is_pm = premultiplied == "yes"
		if premultiplied == "auto":
			over = (a[..., :3].max(-1).astype(np.int16) > a[..., 3].astype(np.int16) + 2) & semi
			# premultiplied data never has colour > alpha; ASTC noise gives ~0.1 % outliers (measured)
			is_pm = semi.sum() == 0 or over.sum() / max(1, semi.sum()) < 0.02
		if not is_pm:
			a = a.copy()
			a[..., :3] = ((a[..., :3].astype(np.uint16) * alpha + 127) // 255).astype(np.uint8)
		t.image = Image.fromarray(np.ascontiguousarray(a), "RGBa")
		t.premultiplied_source = bool(is_pm)
	return warns


# =====================================================================================================
# Renderer
# =====================================================================================================

def mat_mul(p, c):
	"""Return parent∘child for Flash-style matrices (a, b, c, d, tx, ty): x' = a x + c y + tx, y' = b x + d y + ty."""
	a1, b1, c1, d1, x1, y1 = p
	a2, b2, c2, d2, x2, y2 = c
	return (a1 * a2 + c1 * b2, b1 * a2 + d1 * b2, a1 * c2 + c1 * d2, b1 * c2 + d1 * d2,
		a1 * x2 + c1 * y2 + x1, b1 * x2 + d1 * y2 + y1)


def ct_mul(p, c):
	(pm, pa), (cm, ca) = p, c
	mul = tuple(min(255.0, pm[i] * cm[i] / 255.0) for i in range(4))
	add = tuple(min(255.0, pa[i] + ca[i]) for i in range(3))
	return (mul, add)


IDENT = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
CT_IDENT = ((255.0, 255.0, 255.0, 255.0), (0.0, 0.0, 0.0))


# Runtime placeholder slots: Supercell marks nodes that the game fills at runtime (collected-item icons, the order
# board's reward slot, the neighborhood emblem, ...) with solid fills whose uv points all name ONE pure-red texel
# (255, 0, 0). Since degenerate-uv fills are drawn (solid colours are real art), exactly these red single-texel fills
# are dropped from every display list, or static art would show red squares.
PLACEHOLDER_RGB = (255, 0, 0)
PLACEHOLDER_WARN = "runtime placeholder fills (pure-red single texel) dropped"


class Renderer:
	def __init__(self, swf: Swf, max_depth: int = 64, drop_placeholders: bool = True, nested_frame: int | None = None,
			clip_frame=None, hidden_names=None):
		"""``nested_frame`` None: nested clips at frame 0 (default). An int G: every nested clip plays frame
		G mod its frame count (instances placed at frame 0 advance with the root timeline).
		``clip_frame(clip_id, instance_name, clip)``, when given, picks the frame of every NESTED clip (an int, taken
		mod the clip's length; None = the default above): ambient-animation export plays some clips and holds others.
		``hidden_names``: instance names that are not drawn at any depth (e.g. HUD children)."""
		self.swf = swf
		self.max_depth = max_depth
		self.drop_placeholders = drop_placeholders
		self.nested_frame = nested_frame
		self.clip_frame = clip_frame
		self.hidden_names = set(hidden_names or ())
		self._ph_cache: dict = {}

	def is_runtime_placeholder(self, cmd: Command) -> bool:
		"""True for a fill whose uv points all name one texel and that texel is pure red (a runtime slot)."""
		uv = cmd.uv
		if not uv or any(p != uv[0] for p in uv):
			return False
		key = (cmd.tex, cmd.tag, tuple(uv[0]))
		hit = self._ph_cache.get(key)
		if hit is not None:
			return hit
		tex = self.swf.textures[cmd.tex] if cmd.tex < len(self.swf.textures) else None
		res = False
		if tex is not None and tex.image is not None:
			u, v = self._uv_px(cmd, tex)[0]
			px = tex.image.getpixel((min(tex.w - 1, max(0, int(u))), min(tex.h - 1, max(0, int(v)))))
			res = tuple(px[:3]) == PLACEHOLDER_RGB
		self._ph_cache[key] = res
		return res

	# ---- display list -------------------------------------------------------------------------
	def display_list(self, obj_id: int, frame: int = 0) -> tuple[list, list[str]]:
		"""Flattened draw list: ("draw", cmd, matrix, colour transform, blend mode) and mask markers. The blend mode
		is the nearest ancestor's non-normal mode (Flash numbering: 0/1 normal, 3 multiply, 4 screen, 8 add, ...)."""
		ops: list = []
		warns: list[str] = []
		self._emit(obj_id, IDENT, CT_IDENT, frame, ops, warns, 0)
		return ops, warns

	def _emit(self, oid, m, ct, frame, ops, warns, depth, blend: int = 0, name: str | None = None):
		swf = self.swf
		if depth > self.max_depth:
			warns.append("max nesting depth reached")
			return
		if oid in swf.shapes:
			for cmd in swf.shapes[oid].commands:
				if self.drop_placeholders and self.is_runtime_placeholder(cmd):
					if PLACEHOLDER_WARN not in warns:
						warns.append(PLACEHOLDER_WARN)
					continue
				ops.append(("draw", cmd, m, ct, blend))
			return
		if oid in swf.textfields:
			if "text fields are not rendered" not in warns:
				warns.append("text fields are not rendered")
			return
		if oid in swf.modifiers:
			ops.append(({38: "mask", 39: "masked", 40: "unmask"}[swf.modifiers[oid]],))
			return
		clip = swf.clips.get(oid)
		if clip is None:
			warns.append(f"unknown child id {oid}")
			return
		if not clip.frames:
			return
		if depth == 0:
			fi = min(frame, len(clip.frames) - 1)
		else:
			fi = self.nested_frame % len(clip.frames) if self.nested_frame is not None else 0
			if self.clip_frame is not None:
				want = self.clip_frame(oid, name, clip)
				if want is not None:
					fi = int(want) % len(clip.frames)
		start = sum(n for n, _ in clip.frames[:fi])
		count = clip.frames[fi][0]
		bank = swf.banks[clip.bank] if clip.bank < len(swf.banks) else swf.banks[0]
		for ci, mi, ki in clip.elements[start:start + count]:
			if ci >= len(clip.children):
				warns.append(f"clip {oid}: child index out of range")
				continue
			cm = bank["m"][mi] if mi != 0xFFFF and mi < len(bank["m"]) else IDENT
			cc = bank["c"][ki] if ki != 0xFFFF and ki < len(bank["c"]) else CT_IDENT
			b = clip.blends[ci] if ci < len(clip.blends) else 0
			nm = clip.names[ci] if ci < len(clip.names) else None
			if nm and nm in self.hidden_names:
				continue
			if b not in (0, 1) and "non-normal blend modes ignored" not in warns:
				warns.append("non-normal blend modes ignored")
			self._emit(clip.children[ci], mat_mul(m, cm), ct_mul(ct, cc), 0, ops, warns, depth + 1,
				b if b not in (0, 1) else blend, nm)

	# ---- geometry -----------------------------------------------------------------------------
	@staticmethod
	def _uv_px(cmd: Command, tex: Texture):
		if cmd.tag == 22:
			return [(u * tex.w / 65535.0, v * tex.h / 65535.0) for u, v in cmd.uv]
		# tags 4 / 17 (UNTESTED): SupercellFlash treats them like 22; Supercell-Extractor as absolute pixels.
		return [(float(u), float(v)) for u, v in cmd.uv]

	def bounds(self, ops, scale: float):
		xs, ys = [], []
		for op in ops:
			if op[0] != "draw":
				continue
			cmd, m = op[1], op[2]
			for x, y in cmd.xy:
				xs.append((m[0] * x + m[2] * y + m[4]) * scale)
				ys.append((m[1] * x + m[3] * y + m[5]) * scale)
		if not xs:
			return None
		return (math.floor(min(xs)), math.floor(min(ys)), math.ceil(max(xs)), math.ceil(max(ys)))

	def texel_scale(self, ops) -> float:
		"""Median texels per world unit over the draw list (the 'native' resolution)."""
		vals = []
		for op in ops:
			if op[0] != "draw":
				continue
			cmd, m = op[1], op[2]
			tex = self.swf.textures[cmd.tex] if cmd.tex < len(self.swf.textures) else None
			if tex is None or len(cmd.xy) < 3:
				continue
			A = _affine_from(_world(cmd.xy, m)[:3], self._uv_px(cmd, tex)[:3])
			if A is None:
				continue
			det = abs(A[0] * A[4] - A[1] * A[3])
			if det > 1e-9:
				vals.append(math.sqrt(det))
		if not vals:
			return 1.0
		vals.sort()
		return vals[len(vals) // 2]

	def texel_density(self, ops) -> dict | None:
		"""Source texture density of a draw list: texels per SC unit, area-weighted p50 / p90 over the draw commands
		(degenerate-uv fills excluded). 1 world px = 2 SC units, so 2 * p50 is the largest output pixels per world px
		that still adds detail. None when nothing textured is drawn."""
		vals = []
		for op in ops:
			if op[0] != "draw":
				continue
			cmd, m = op[1], op[2]
			tex = self.swf.textures[cmd.tex] if cmd.tex < len(self.swf.textures) else None
			if tex is None or len(cmd.xy) < 3:
				continue
			xy = _world(cmd.xy, m)
			A = _affine_from(xy[:3], self._uv_px(cmd, tex)[:3])
			if A is None:
				continue
			det = abs(A[0] * A[4] - A[1] * A[3])
			if det < 1e-9:
				continue
			area = 0.0
			for i in range(len(xy)):
				x0, y0 = xy[i]
				x1, y1 = xy[(i + 1) % len(xy)]
				area += x0 * y1 - x1 * y0
			vals.append((math.sqrt(det), abs(area) / 2))
		tot = sum(a for _, a in vals)
		if not vals or tot <= 0:
			return None
		vals.sort()
		acc, p50, p90 = 0.0, None, None
		for v, a in vals:
			acc += a
			if p50 is None and acc >= 0.5 * tot:
				p50 = v
			if p90 is None and acc >= 0.9 * tot:
				p90 = v
		return {"p50": round(p50, 4), "p90": round(p90 if p90 is not None else vals[-1][0], 4), "commands": len(vals)}

	# ---- raster ---------------------------------------------------------------------------------
	def canvas(self, ops, scale: float = 1.0, pad: int = 2):
		"""Full canvas (x0, y0, x1, y1) in output pixels (registration point = (0, 0)) or None if empty."""
		bb = self.bounds(ops, scale)
		if bb is None:
			return None
		return bb[0] - pad, bb[1] - pad, bb[2] + pad, bb[3] + pad

	def render(self, ops, scale: float = 1.0, pad: int = 2, window=None, max_pixels: int = MAX_CANVAS_PIXELS):
		"""Rasterise ``ops``. ``window`` = (x0, y0, x1, y1) in output pixels (registration point = (0, 0)) renders
		only that part of the canvas (chunked rendering of huge exports); default = the whole bounding box.
		Returns (PIL RGBA image, origin = registration point in image pixels)."""
		import numpy as np
		from PIL import Image, ImageDraw
		if window is None:
			bb = self.canvas(ops, scale, pad)
			if bb is None:
				return None, None
			x0, y0, x1, y1 = bb
		else:
			x0, y0, x1, y1 = (int(v) for v in window)
		W, H = x1 - x0, y1 - y0
		if W <= 0 or H <= 0 or W * H > max_pixels:
			raise ToolError(f"unreasonable canvas size {W}x{H}")
		layers = [np.zeros((H, W, 4), np.float32)]  # premultiplied, 0..1
		mask_stack: list = []
		# A display list made ONLY of single-texel fills is a marker layer (e.g. the animal slots of a habitat's
		# "middle" piece: one dark square per level), not art: its canvas is kept, nothing is drawn.
		draws = [op for op in ops if op[0] == "draw"]
		marker_only = bool(draws) and all(op[1].uv and all(q == op[1].uv[0] for q in op[1].uv) for op in draws)
		for op in ops:
			kind = op[0]
			if kind == "mask":
				mask_stack.append(np.zeros((H, W, 4), np.float32))
				layers.append(mask_stack[-1])
				continue
			if kind == "masked":
				if mask_stack:
					layers.append(np.zeros((H, W, 4), np.float32))
				continue
			if kind == "unmask":
				if mask_stack and len(layers) >= 3:
					content = layers.pop()
					mask = layers.pop()
					mask_stack.pop()
					a = mask[..., 3:4]
					dst = layers[-1]
					c = content * a
					dst *= 1.0 - c[..., 3:4]
					dst += c
				continue
			if marker_only:
				continue
			blend = op[4] if len(op) > 4 else 0
			# Non-normal blend modes are drawn as normal (historic behaviour, renders checked by eye), EXCEPT solid
			# degenerate-uv fills: those were invisible before the 2026-11-09 fix and are almost always screen/add
			# glows or multiply shading whose black/white fill must not become an opaque block. Screen (4) and add (8)
			# fills become normal fills whose alpha is their brightest channel (black = no-op, as in the game);
			# other modes keep the old behaviour for such fills (not drawn). render_layers() composites them exactly.
			for by0, by1, bx0, bx1, arr in self._op_patches(op, scale, x0, y0, W, H, legacy_solid=True):
				dst = layers[-1][by0:by1, bx0:bx1]
				dst *= 1.0 - arr[..., 3:4]
				dst += arr
		while len(layers) > 1:  # unterminated masks: draw content unmasked
			top = layers.pop()
			layers[-1] *= 1.0 - top[..., 3:4]
			layers[-1] += top
		out = layers[0]
		alpha = out[..., 3:4]
		rgb = np.where(alpha > 1e-6, out[..., :3] / np.maximum(alpha, 1e-6), 0.0)
		img = np.concatenate([np.clip(rgb, 0, 1), np.clip(alpha, 0, 1)], -1)
		img = (img * 255.0 + 0.5).astype(np.uint8)
		return Image.fromarray(img, "RGBA"), (-x0, -y0)


	def _op_patches(self, op, scale: float, x0: int, y0: int, W: int, H: int, legacy_solid: bool):
		"""Rasterised pieces of one draw op inside the (x0, y0, W, H) window: (by0, by1, bx0, bx1, premultiplied RGBA
		float32 array with the colour transform applied). ``legacy_solid``: solid (degenerate-uv) fills under a
		non-normal blend mode follow render()'s historic rule (screen/add: alpha = brightest channel; others skipped)."""
		import numpy as np
		from PIL import Image, ImageDraw
		cmd, m, ct = op[1], op[2], op[3]
		blend = op[4] if len(op) > 4 else 0
		tex = self.swf.textures[cmd.tex] if cmd.tex < len(self.swf.textures) else None
		if tex is None or tex.image is None:
			return
		world = [(px * scale - x0, py * scale - y0) for px, py in _world(cmd.xy, m)]
		if (max(p[0] for p in world) <= 0 or max(p[1] for p in world) <= 0 or min(p[0] for p in world) >= W
				or min(p[1] for p in world) >= H):
			return
		uv = self._uv_px(cmd, tex)
		solid_blend = legacy_solid and blend not in (0, 1) and _uv_degenerate(uv)
		if solid_blend and blend not in (4, 8):
			return
		for poly_xy, poly_uv, inv in _pieces(world, uv):  # inv: xy -> uv
			if inv is None:
				continue
			bx0 = max(0, math.floor(min(p[0] for p in poly_xy)))
			by0 = max(0, math.floor(min(p[1] for p in poly_xy)))
			bx1 = min(W, math.ceil(max(p[0] for p in poly_xy)))
			by1 = min(H, math.ceil(max(p[1] for p in poly_xy)))
			if bx1 <= bx0 or by1 <= by0:
				continue
			w, h = bx1 - bx0, by1 - by0
			# PIL maps output pixel CENTRES (x+0.5) through the coefficients.
			a, b, c, d, e, f = inv
			coeffs = (a, b, a * bx0 + b * by0 + c, d, e, d * bx0 + e * by0 + f)
			patch = tex.image.transform((w, h), Image.Transform.AFFINE, coeffs, resample=Image.Resampling.BILINEAR)
			mask = Image.new("L", (w * 4, h * 4), 0)
			ImageDraw.Draw(mask).polygon([((x - bx0) * 4, (y - by0) * 4) for x, y in poly_xy], fill=255)
			mask = mask.resize((w, h), Image.Resampling.BOX)
			arr = np.asarray(patch, np.float32) / 255.0
			if solid_blend:   # screen/add -> premultiplied colour with alpha = brightest channel
				arr[..., 3] = arr[..., :3].max(axis=-1)
			arr *= (np.asarray(mask, np.float32) / 255.0)[..., None]
			(rm, gm, bm, am), (ra, ga, ba) = ct
			if (rm, gm, bm, am, ra, ga, ba) != (255.0, 255.0, 255.0, 255.0, 0.0, 0.0, 0.0):
				alpha = arr[..., 3:4].copy()
				arr[..., 0] *= rm / 255.0
				arr[..., 1] *= gm / 255.0
				arr[..., 2] *= bm / 255.0
				arr[..., :3] += np.array([ra, ga, ba], np.float32) / 255.0 * alpha
				arr *= am / 255.0
				np.clip(arr, 0.0, 1.0, out=arr)
				arr[..., :3] = np.minimum(arr[..., :3], arr[..., 3:4])
			yield by0, by1, bx0, bx1, arr

	def render_layers(self, ops, scale: float = 1.0, pad: int = 2, window=None, max_pixels: int = MAX_CANVAS_PIXELS):
		"""Blend-mode-exact render, split into what a normal-alpha image can carry and an additive remainder.

		Over an opaque backdrop G every op is affine in G per channel, so the whole display list composites to
		R(G) = C + T*G (C = premultiplied colour, T = transmittance per channel). Tracked per pixel:
		  normal (0/1, and the unknown modes, e.g. 64): C = s + (1-sa)C, T = (1-sa)T
		  add (8):      C = min(1, C + s)                      (Flash numbering; strong, not verified in the game)
		  screen (4):   C = s + (1-s)C, T = (1-s)T   per channel
		  multiply (3): k = s + 1 - sa; C = kC, T = kT per channel (plausible)
		Masks keep their (C, T) layers; the mask's coverage is 1 - mean(T).
		Output: a straight-alpha RGBA image with A = 1 - mean(T) and colour P = min(C, A) (drawn normally), plus the
		excess E = C - P as an RGBA "glow" image (rgb = E / max(E), alpha = max(E)) to be drawn with ADDITIVE blending
		(rgb * alpha is added). Exact for add over any opaque backdrop; screen and multiply over pixels that the art
		does not cover are approximated by the mean transmittance (error (T_c - mean T) * G per channel).
		Without non-normal ops the normal image equals render()'s output and the glow is None.
		Returns (normal RGBA image, glow RGBA image or None, origin) like render()."""
		import numpy as np
		from PIL import Image
		if window is None:
			bb = self.canvas(ops, scale, pad)
			if bb is None:
				return None, None, None
			x0, y0, x1, y1 = bb
		else:
			x0, y0, x1, y1 = (int(v) for v in window)
		W, H = x1 - x0, y1 - y0
		if W <= 0 or H <= 0 or W * H > max_pixels:
			raise ToolError(f"unreasonable canvas size {W}x{H}")

		def new_layer():
			return [np.zeros((H, W, 3), np.float32), np.ones((H, W, 3), np.float32)]

		layers = [new_layer()]
		mask_depth = 0
		draws = [op for op in ops if op[0] == "draw"]
		marker_only = bool(draws) and all(op[1].uv and all(q == op[1].uv[0] for q in op[1].uv) for op in draws)
		for op in ops:
			kind = op[0]
			if kind == "mask":
				layers.append(new_layer())
				mask_depth += 1
				continue
			if kind == "masked":
				if mask_depth:
					layers.append(new_layer())
				continue
			if kind == "unmask":
				if mask_depth and len(layers) >= 3:
					cc, ctr = layers.pop()
					mc, mt = layers.pop()
					mask_depth -= 1
					mcov = 1.0 - mt.mean(axis=-1, keepdims=True)
					dc, dt = layers[-1]
					layers[-1] = [mcov * (cc + ctr * dc) + (1.0 - mcov) * dc, mcov * ctr * dt + (1.0 - mcov) * dt]
				continue
			if marker_only:
				continue
			blend = op[4] if len(op) > 4 else 0
			for by0, by1, bx0, bx1, arr in self._op_patches(op, scale, x0, y0, W, H, legacy_solid=False):
				C = layers[-1][0][by0:by1, bx0:bx1]
				T = layers[-1][1][by0:by1, bx0:bx1]
				s, sa = arr[..., :3], arr[..., 3:4]
				if blend == 8:
					C += s
					np.minimum(C, 1.0, out=C)
				elif blend == 4:
					C *= 1.0 - s
					C += s
					T *= 1.0 - s
				elif blend == 3:
					k = s + 1.0 - sa
					C *= k
					T *= k
				else:
					C *= 1.0 - sa
					C += s
					T *= 1.0 - sa
		while len(layers) > 1:  # unterminated masks: content unmasked
			cc, ctr = layers.pop()
			dc, dt = layers[-1]
			layers[-1] = [cc + ctr * dc, ctr * dt]
		C, T = layers[0]
		A = np.clip(1.0 - T.mean(axis=-1, keepdims=True), 0.0, 1.0)
		C = np.clip(C, 0.0, None)
		P = np.minimum(C, A)
		E = np.clip(C - P, 0.0, 1.0)
		rgb = np.where(A > 1e-6, P / np.maximum(A, 1e-6), 0.0)
		img = (np.concatenate([np.clip(rgb, 0, 1), A], -1) * 255.0 + 0.5).astype(np.uint8)
		normal = Image.fromarray(img, "RGBA")
		glow = None
		# Only real add/screen/multiply ops make a glow: atlas texels whose colour slightly exceeds their alpha (block
		# compression noise) would otherwise leave a faint excess under normal blending; render() clips it the same way.
		E[E < GLOW_MIN] = 0.0
		ga = E.max(axis=-1, keepdims=True)
		if any(op[0] == "draw" and len(op) > 4 and op[4] in (3, 4, 8) for op in ops) and float(ga.max()) > 0.0:
			grgb = np.where(ga > 1e-6, E / np.maximum(ga, 1e-6), 0.0)
			gimg = (np.concatenate([np.clip(grgb, 0, 1), ga], -1) * 255.0 + 0.5).astype(np.uint8)
			glow = Image.fromarray(gimg, "RGBA")
		return normal, glow, (-x0, -y0)


def render_chunked(rend: Renderer, ops, scale: float, out_dir: Path, chunk: int = 2048, pad: int = 2) -> dict | None:
	"""Render a (huge) display list as a grid of ``chunk`` x ``chunk`` PNG tiles named ``r<row>_c<col>.png`` in
	``out_dir``. Fully transparent tiles are not written. Returns the manifest (canvas size, registration point in
	canvas pixels, tile list with pixel offsets) or None when there is nothing to draw. Placing every tile at its
	``offset`` reproduces exactly the single image ``render`` would return."""
	bb = rend.canvas(ops, scale, pad)
	if bb is None:
		return None
	x0, y0, x1, y1 = bb
	W, H = x1 - x0, y1 - y0
	cols, rows = math.ceil(W / chunk), math.ceil(H / chunk)
	out_dir.mkdir(parents=True, exist_ok=True)
	tiles = []
	for r in range(rows):
		for c in range(cols):
			wx0, wy0 = x0 + c * chunk, y0 + r * chunk
			win = (wx0, wy0, min(x1, wx0 + chunk), min(y1, wy0 + chunk))
			img, _ = rend.render(ops, scale, pad, window=win)
			if img is None or img.getbbox() is None:
				continue
			name = f"r{r:02d}_c{c:02d}.png"
			img.save(out_dir / name, optimize=False)
			tiles.append({"file": name, "offset": [c * chunk, r * chunk], "size": list(img.size)})
	return {"size": [W, H], "origin": [-x0, -y0], "chunk": chunk, "grid": [cols, rows], "tiles": tiles}


def fit_scale(rend: Renderer, ops, scale: float, max_pixels: int = MAX_CANVAS_PIXELS, pad: int = 2) -> float:
	"""Largest scale <= ``scale`` (on a 1/64 grid) whose canvas fits in ``max_pixels``."""
	s = scale
	for _ in range(64):
		bb = rend.canvas(ops, s, pad)
		if bb is None or (bb[2] - bb[0]) * (bb[3] - bb[1]) <= max_pixels:
			return s
		W, H = bb[2] - bb[0], bb[3] - bb[1]
		s = math.floor(s * math.sqrt(max_pixels / (W * H)) * 0.98 * 64) / 64
		if s <= 0:
			break
	raise ToolError("cannot fit the canvas into the pixel budget")


def _world(xy, m):
	return [(m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]) for x, y in xy]


def _affine_from(src, dst):
	"""Affine (a,b,c,d,e,f) with dst = (a*x+b*y+c, d*x+e*y+f) from 3 point pairs; None if degenerate."""
	(x0, y0), (x1, y1), (x2, y2) = src
	det = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
	if abs(det) < 1e-9:
		return None
	(u0, v0), (u1, v1), (u2, v2) = dst
	a = ((u1 - u0) * (y2 - y0) - (u2 - u0) * (y1 - y0)) / det
	b = ((u2 - u0) * (x1 - x0) - (u1 - u0) * (x2 - x0)) / det
	d = ((v1 - v0) * (y2 - y0) - (v2 - v0) * (y1 - y0)) / det
	e = ((v2 - v0) * (x1 - x0) - (v1 - v0) * (x2 - x0)) / det
	return (a, b, u0 - a * x0 - b * y0, d, e, v0 - d * x0 - e * y0)


def _invert(A):
	a, b, c, d, e, f = A
	det = a * e - b * d
	if abs(det) < 1e-12:
		return None
	ia, ib, id_, ie = e / det, -b / det, -d / det, a / det
	return (ia, ib, -(ia * c + ib * f), id_, ie, -(id_ * c + ie * f))


def _uv_degenerate(uv) -> bool:
	"""True when some fan triangle of the uv polygon has zero area (one texel or a line)."""
	for k in range(1, len(uv) - 1):
		(u0, v0), (u1, v1), (u2, v2) = uv[0], uv[k], uv[k + 1]
		if abs((u1 - u0) * (v2 - v0) - (u2 - u0) * (v1 - v0)) < 1e-9:
			return True
	return False


def uv_degenerate_commands(rend: "Renderer", ops) -> int:
	"""Number of draw commands in ``ops`` with a degenerate uv triangle (all uv points on one texel or one line in
	some fan triangle). Before the 2026-11-09 fix these were (partly) dropped, so exports that contain any render
	differently now (``extract --only-degenerate`` re-renders exactly these)."""
	n = 0
	for op in ops:
		if op[0] != "draw":
			continue
		cmd = op[1]
		tex = rend.swf.textures[cmd.tex] if cmd.tex < len(rend.swf.textures) else None
		if tex is None or len(cmd.uv) < 3:
			continue
		if _uv_degenerate(rend._uv_px(cmd, tex)):
			n += 1
	return n


def _pieces(xy, uv):
	"""Split a draw command into pieces that each have ONE affine xy->uv map (whole polygon when consistent).

	Returns (piece_xy, piece_uv, xy_to_uv). The map is solved from the xy side, so commands whose uv points are
	degenerate also render: Supercell draws solid-colour fills (e.g. the river water in background.sc
	bg_edge_west) as polygons whose uv points all name ONE texel, and 1-D gradients as uv lines."""
	n = len(xy)
	if n < 3:
		return []
	tri = None
	for k in range(1, n - 1):
		if _affine_from(xy[0:1] + xy[k:k + 2], uv[0:1] + uv[k:k + 2]) is not None:
			tri = (0, k, k + 1)
			break
	if tri is None:
		return []
	A = _affine_from([xy[i] for i in tri], [uv[i] for i in tri])
	ok = True
	for (u, v), (x, y) in zip(uv, xy):
		pu, pv = A[0] * x + A[1] * y + A[2], A[3] * x + A[4] * y + A[5]
		if abs(pu - u) > 0.75 or abs(pv - v) > 0.75:
			ok = False
			break
	if ok:
		return [(xy, uv, A)]
	out = []
	for k in range(1, n - 1):
		pxy, puv = [xy[0], xy[k], xy[k + 1]], [uv[0], uv[k], uv[k + 1]]
		out.append((pxy, puv, _affine_from(pxy, puv)))
	return out


# =====================================================================================================
# Commands
# =====================================================================================================

def asset_files_in_apks(apks: list[Path]) -> dict[str, tuple[Path, str]]:
	files: dict[str, tuple[Path, str]] = {}
	for apk in apks:
		with zipfile.ZipFile(apk) as z:
			for n in z.namelist():
				if not n.startswith("assets/") or n.endswith("/"):
					continue
				rel = n[len("assets/"):]
				low = rel.lower()
				# Play Asset Delivery packs keep files under assets/ too; first wins (base before splits)
				if low.endswith(SC_EXTS) or low.endswith(".csv") or low.endswith("fingerprint.json"):
					files.setdefault(rel, (apk, n))
	return files


def inventory(files: dict) -> dict:
	c = {"_tex.sc": 0, ".sc": 0, ".sctx": 0, ".ktx": 0, ".zktx": 0, ".csv": 0, "fingerprint.json": 0}
	for rel in files:
		low = rel.lower()
		for k in ("_tex.sc", ".sc", ".sctx", ".zktx", ".ktx", ".csv", "fingerprint.json"):
			if low.endswith(k):
				c[k] += 1
				break
	return c


def read_version(files: dict) -> str:
	fp = [k for k in files if k.endswith("fingerprint.json")]
	if not fp:
		return "unknown"
	try:  # a member of an APK, or a plain file when the input is a folder of already-extracted assets
		return str(json.loads(_read_file(files[fp[0]])).get("version") or "unknown")
	except (ValueError, OSError, zipfile.BadZipFile):
		return "unknown"


def cmd_verify(args) -> int:
	with tempfile.TemporaryDirectory(dir=str(ensure_private(args.out))) as tmp:
		apks = collect_apks(Path(args.input), Path(tmp))
		results = [verify_apk(a) for a in apks]
	ok = True
	for r in results:
		state = "ACCEPTED" if r["accepted"] else ("VERIFIED, UNKNOWN SIGNER" if r["verified"] else "NOT VERIFIED")
		log(f"{state:24s} {Path(r['file']).name}  signer={','.join(s[:16] for s in r['signer_sha256']) or '-'}")
		for k in ("v2v3", "v1"):
			if r[k].get("error"):
				log(f"    {k}: {r[k]['error']}")
		ok &= r["accepted"]
	if args.json:
		print(json.dumps(results, indent=1))
	return 0 if ok else 2


def _open_inputs(args, tmp: Path):
	inp = Path(args.input)
	if inp.is_dir() and not any(inp.rglob("*.apk")) and not any(
			p.suffix.lower() in (".xapk", ".apks", ".apkm") for p in inp.rglob("*")):
		# a folder of already extracted files (assets/sc/...): no signature to check
		files = {}
		for p in inp.rglob("*"):
			if p.is_file() and (p.name.lower().endswith(SC_EXTS) or p.name.endswith("fingerprint.json")):
				rel = str(p.relative_to(inp))
				rel = rel.split("assets/", 1)[-1]
				files[rel] = (p, None)
		return files, [], None
	apks = collect_apks(inp, tmp)
	return asset_files_in_apks(apks), apks, None


def _read_file(entry) -> bytes:
	path, member = entry
	if member is None:
		return Path(path).read_bytes()
	with zipfile.ZipFile(path) as z:
		return z.read(member)


def cmd_list(args) -> int:
	with tempfile.TemporaryDirectory(dir=str(ensure_private(args.out))) as tmp:
		files, apks, _ = _open_inputs(args, Path(tmp))
		info = {"apks": [str(a.name) for a in apks], "counts": inventory(files),
			"version": read_version(files) if apks else "unknown"}
		sc = sorted(k for k in files if k.lower().endswith(".sc") and not k.lower().endswith("_tex.sc"))
		info["sc_files"] = sc
		print(json.dumps(info, indent=1))
	return 0


def cmd_extract(args) -> int:
	need("PIL", "pillow")
	need("numpy")
	out_root = ensure_private(args.out)
	out_root.mkdir(parents=True, exist_ok=True)
	report: dict = {"tool": "extract_from_apk.py", "started": dt.datetime.now(dt.timezone.utc).isoformat(),
		"input": str(args.input), "files": {}}
	tmpdir = tempfile.mkdtemp(prefix="apk_", dir=str(out_root))
	try:
		files, apks, _ = _open_inputs(args, Path(tmpdir))
		if apks:
			ver = [verify_apk(a) for a in apks]
			report["signatures"] = ver
			bad = [v for v in ver if not v["accepted"]]
			if bad and not args.allow_unverified:
				for v in bad:
					log(f"REJECTED {Path(v['file']).name}: verified={v['verified']} signer={v['signer_sha256']}")
				log("Refusing to continue (use --allow-unverified only for files you know are genuine).")
				return 2
		version = args.version or (read_version(files) if files else "unknown")
		report["version"] = version
		report["counts"] = inventory(files)
		raw_dir = ensure_private(out_root / "raw" / "apk_extracted" / version)
		spr_root = ensure_private(out_root / "raw" / "apk_sprites" / version)
		atl_root = ensure_private(out_root / "raw" / "apk_atlases" / version)
		for rel, entry in files.items():
			if rel.lower().endswith(SC_EXTS) or rel.endswith("fingerprint.json"):
				dst = raw_dir / "assets" / rel
				if not dst.exists():
					dst.parent.mkdir(parents=True, exist_ok=True)
					dst.write_bytes(_read_file(entry))
		only = set(x.strip() for x in args.only.split(",")) if args.only else None
		export_re = re.compile(args.exports, re.I) if args.exports else None
		sc_names = sorted(k for k in files if k.lower().endswith(".sc") and not k.lower().endswith("_tex.sc"))
		for rel in sc_names:
			base = Path(rel).name[:-3]
			if only and base not in only:
				continue
			if base.endswith("_lowres") and not args.include_lowres and not only:
				continue  # old builds ship a separate half-resolution copy of every file
			rep = report["files"].setdefault(base, {})
			try:
				raw_sc = _read_file(files[rel])
				if is_sc2(raw_sc):
					swf = parse_sc2(raw_sc, base)
					rep["container"] = swf.flags["sc2"]
				else:
					body, info = decompress_sc(raw_sc, rel)
					rep["container"] = info
					swf = parse_sc(body, base, is_tex=False)
				tex_rel = rel[:-3] + "_tex.sc"
				if swf.flags.get("external_texture"):
					if tex_rel not in files:
						raise ToolError(f"missing {tex_rel}")
					tbody, tinfo = decompress_sc(_read_file(files[tex_rel]), tex_rel)
					rep["tex_container"] = tinfo
					parse_sc(tbody, base, is_tex=True, swf=swf)
				rep["counts"] = {"shapes": len(swf.shapes), "clips": len(swf.clips), "textures": len(swf.textures),
					"textfields": len(swf.textfields), "banks": len(swf.banks), "exports": len(swf.exports),
					"modifiers": len(swf.modifiers)}
				rep["draw_command_tags"] = swf.draw_tags
				if swf.unknown_tags:
					rep["unknown_tags"] = swf.unknown_tags
				folder = str(Path(rel).parent)

				def _external(name: str, folder=folder):
					key = name if name in files else (f"{folder}/{name}" if f"{folder}/{name}" in files else None)
					return _read_file(files[key]) if key else None

				rep["texture_warnings"] = load_textures(swf, args.premultiplied, _external)
				rep["textures"] = [{"tag": t.tag, "pf": t.pf, "size": [t.w, t.h],
					"ktx": t.ktx is not None, "decoded": t.image is not None,
					"premultiplied_source": getattr(t, "premultiplied_source", None)} for t in swf.textures]
				if args.atlases:
					atl_root.mkdir(parents=True, exist_ok=True)
					for i, t in enumerate(swf.textures):
						if t.image is not None:
							t.image.convert("RGBA").save(atl_root / f"{base}_{i}.png")
				nested = getattr(args, "nested_frame", None)
				rend = Renderer(swf, nested_frame=nested)
				exports = [(i, n) for i, n in swf.exports if not export_re or export_re.search(n)]
				if args.max:
					exports = exports[:args.max]
				sdir = spr_root / base
				sdir.mkdir(parents=True, exist_ok=True)
				index_path = sdir / "index.json"
				index = json.loads(index_path.read_text()) if index_path.exists() else {}
				done = failed = skipped_same = 0
				for oid, ename in exports:
					entry = {"id": oid, "kind": "clip" if oid in swf.clips else ("shape" if oid in swf.shapes else "other"),
						"render_rev": RENDER_REV}
					if nested is not None:
						entry["nested_frame"] = nested
					try:
						frame, label = args.frame, None
						clip = swf.clips.get(oid)
						if clip is not None and args.frame_label:
							starts = {lab: i for i, (_, lab) in reversed(list(enumerate(clip.frames))) if lab}
							for want in args.frame_label.split(","):
								if want in starts:
									frame, label = starts[want], want
									break
						ops, warns = rend.display_list(oid, frame)
						if getattr(args, "only_degenerate", False) and not uv_degenerate_commands(rend, ops):
							skipped_same += 1
							continue
						scale = args.scale if args.scale else round(max(0.25, rend.texel_scale(ops)) * 4) / 4
						huge = getattr(args, "huge", "error")
						bb = rend.canvas(ops, scale)
						too_big = bb is not None and (bb[2] - bb[0]) * (bb[3] - bb[1]) > args.max_pixels
						if too_big and huge == "chunk":
							fname = re.sub(r"[^A-Za-z0-9_.-]+", "_", ename) or f"id{oid}"
							cdir = f"{fname}__chunks"
							man = render_chunked(rend, ops, scale, sdir / cdir, args.chunk_size)
							# no "file" key on purpose: consumers that expect one PNG per export skip this entry
							entry.update({"chunks": {"dir": cdir, **{k: man[k] for k in ("chunk", "grid", "tiles")}},
								"size": man["size"], "origin": man["origin"], "scale": scale,
								"pixels_per_world_px": scale * SC_UNITS_PER_WORLD_PX,
								"frames": len(clip.frames) if clip is not None else 1, "frame_rendered": frame,
								"frame_label": label, "draw_ops": sum(1 for o in ops if o[0] == "draw")})
							if warns:
								entry["warnings"] = sorted(set(warns))
							index[ename] = entry
							done += 1
							continue
						if too_big and huge == "downscale":
							full = scale
							scale = fit_scale(rend, ops, scale, args.max_pixels)
							entry["downscaled_from"] = full
						img, origin = rend.render(ops, scale, max_pixels=args.max_pixels)
						if img is None:
							entry["skipped"] = "nothing to draw"
						else:
							fname = re.sub(r"[^A-Za-z0-9_.-]+", "_", ename) or f"id{oid}"
							if fname in {v.get("file", "")[:-4] for k, v in index.items() if k != ename}:
								fname += f"__{oid}"
							img.save(sdir / f"{fname}.png", optimize=False)
							entry.update({"file": f"{fname}.png", "size": list(img.size),
								"origin": [round(origin[0], 2), round(origin[1], 2)], "scale": scale,
								"pixels_per_world_px": scale * SC_UNITS_PER_WORLD_PX,
								"frames": len(clip.frames) if clip is not None else 1,
								"frame_rendered": frame, "frame_label": label,
								"frame_labels": sorted({lab for _, lab in clip.frames if lab}) if clip is not None else [],
								"draw_ops": sum(1 for o in ops if o[0] == "draw")})
							done += 1
						if warns:
							entry["warnings"] = sorted(set(warns))
					except Exception as ex:  # noqa: BLE001 - one bad export must not stop the batch
						entry["error"] = f"{type(ex).__name__}: {ex}"
						failed += 1
					index[ename] = entry
				index_path.write_text(json.dumps(index, indent=1, sort_keys=True))
				rep["rendered"] = done
				rep["failed"] = failed
				if getattr(args, "only_degenerate", False):
					rep["unchanged_skipped"] = skipped_same
				log(f"{base}: {len(exports)} exports, rendered {done}, failed {failed}, "
					+ (f"unchanged (no degenerate uv) {skipped_same}, " if getattr(args, "only_degenerate", False) else "") +
					f"textures {sum(1 for t in swf.textures if t.image is not None)}/{len(swf.textures)}")
			except ToolError as ex:
				rep["error"] = str(ex)
				log(f"{base}: SKIPPED - {ex}")
		report["finished"] = dt.datetime.now(dt.timezone.utc).isoformat()
		spr_root.mkdir(parents=True, exist_ok=True)
		rep_path = spr_root / "extract_report.json"
		partial = bool(args.only or args.exports or args.max or getattr(args, "only_degenerate", False))
		if partial and rep_path.exists():
			# a partial re-render must not replace the full run's report (its input/signature provenance is used
			# by build_pack.py): merge the per-file results and record the run
			try:
				prev = json.loads(rep_path.read_text())
			except ValueError:
				prev = None
			if isinstance(prev, dict):
				prev.setdefault("files", {}).update(report["files"])
				prev.setdefault("partial_runs", []).append({"started": report["started"], "finished": report["finished"],
					"input": report["input"], "files": sorted(report["files"]),
					"only_degenerate": bool(getattr(args, "only_degenerate", False)), "exports": args.exports})
				report = prev
		rep_path.write_text(json.dumps(report, indent=1, default=str))
		log(f"report: {rep_path}")
		return 0
	finally:
		shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv=None) -> int:
	ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
		formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = ap.add_subparsers(dest="cmd", required=True)
	for name in ("verify", "list", "extract"):
		p = sub.add_parser(name)
		p.add_argument("input", help="APK, XAPK/APKS/APKM bundle, folder of APKs, or folder of extracted assets")
		p.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"private output root (default {DEFAULT_OUT})")
		if name == "verify":
			p.add_argument("--json", action="store_true")
		if name == "extract":
			p.add_argument("--only", help="comma-separated .sc base names, e.g. buildings_new,decos01_generic")
			p.add_argument("--exports", help="regex filter on export names")
			p.add_argument("--max", type=int, default=0, help="render at most N exports per file")
			p.add_argument("--only-degenerate", action="store_true",
				help="re-render only exports that contain degenerate-uv fills (their output changed with the "
				"2026-11-09 renderer fix); other index entries and PNGs are left untouched")
			p.add_argument("--frame", type=int, default=0, help="frame of the exported clip to render")
			p.add_argument("--nested-frame", type=int, default=None,
				help="play nested clips at frame G mod their length (default: nested clips at frame 0); use with "
				"--exports and a separate --out for representative poses (index entries record nested_frame)")
			p.add_argument("--scale", type=float, default=1.5,
				help="output px per SC unit (default 1.5 = buildings' native texel density = 3 px per world px; "
				"0 = per-export native density)")
			p.add_argument("--frame-label", default="IdleStart,Idle,idle",
				help="comma-separated frame labels to try before --frame (empty string disables)")
			p.add_argument("--huge", choices=("error", "downscale", "chunk"), default="error",
				help="exports whose canvas exceeds --max-pixels: 'error' (default, reported in index.json), "
				"'downscale' (largest scale that fits; index records scale + downscaled_from) or 'chunk' (full "
				"scale as <export>__chunks/r<row>_c<col>.png tiles; index entry has 'chunks' and no 'file')")
			p.add_argument("--max-pixels", type=int, default=MAX_CANVAS_PIXELS,
				help=f"single-canvas pixel budget (default {MAX_CANVAS_PIXELS})")
			p.add_argument("--chunk-size", type=int, default=2048, help="tile size in px for --huge chunk")
			p.add_argument("--atlases", action="store_true", help="also save decoded atlases")
			p.add_argument("--include-lowres", action="store_true", help="also render *_lowres.sc files (old builds)")
			p.add_argument("--premultiplied", choices=("auto", "yes", "no"), default="auto")
			p.add_argument("--version", help="override the version folder name")
			p.add_argument("--allow-unverified", action="store_true",
				help="continue even if a signature does not verify or the signer is unknown")
	args = ap.parse_args(argv)
	try:
		return {"verify": cmd_verify, "list": cmd_list, "extract": cmd_extract}[args.cmd](args)
	except ToolError as ex:
		log(f"error: {ex}")
		return 1


if __name__ == "__main__":
	sys.exit(main())
