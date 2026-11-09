# Asset acquisition: client files (Route B/C) and Supercell extraction tools

**Done: 2026-11-09** · Companion documents: [ASSET_SOURCES.md](ASSET_SOURCES.md),
[ASSET_FORMATS.md](ASSET_FORMATS.md), [LEGAL_AND_LICENSING.md](LEGAL_AND_LICENSING.md),
[../ASSET_PIPELINE.md](../ASSET_PIPELINE.md)

This document contains **no images**. Everything proprietary that was obtained or produced (APKs, extracted
`.sc`/`.sctx` files, decoded atlases, rendered sprites, logs with download tokens) is stored **only** under the
private root `/root/hayday-sandbox-private-assets` (outside the repository). Nothing was committed.

## 0. Context and rules followed

* The user states that Supercell support authorised them to obtain and use original Hay Day art for
  **personal use** in this app, on condition that it is never redistributed. This research acts on that
  statement. It is the user's statement, not something we verified. The older documents (ASSET_SOURCES.md,
  ASSET_FORMATS.md) were written before it and still say "do not extract".
* Hard limits that were kept:
  * No bot protection, CAPTCHA, Cloudflare challenge or login was bypassed. When a site answered with one,
    the result was recorded and the site was left alone.
  * No Supercell game server or asset CDN was contacted. No game-client protocol was emulated. No personal
    account was used.
  * Polite traffic: at most one download at a time, metadata requests spaced out, HTTP range requests used to
    read signatures before any full download.
  * An APK was accepted only if its signature verifies **and** the signer certificate is Supercell's (see §2).
* **Third-party tools were not executed.** The session's permission policy blocked running the cloned
  extractor code ("Code from External"). That decision was not worked around. All tool assessments in §4 are
  therefore **static source reviews**. The working pipeline in §5 is our own code
  (`tools/private_assets/extract_from_apk.py`). Its only third-party pieces are ordinary PyPI libraries
  (Pillow, numpy, zstandard, cryptography, pyasn1, and `texture2ddecoder` built from its source distribution).

## 1. Summary

| Question | Answer |
|---|---|
| Can a genuine Hay Day client be obtained without login or bot challenge? | **Yes.** Three Supercell-signed builds were obtained and fully verified: **1.73.89** (current; XAPK from Malavida), **1.60.231** and **1.28.146** (APKs from archive.org). |
| What formats do current builds use? | 1.73.89: 113 `.sc` files in **SC2 version 5** (FlatBuffers + Zstandard) and 430 `.sctx` textures (ASTC). 1.60.231: SC1 (v4 wrapper, version 3, Zstandard) and KTX/ASTC embedded in `_tex.sc`. 1.28.146: SC1 version 1, LZMA, raw RGBA8888. |
| Does any existing tool render complete objects from current files? | Probably `danila-schelkov/sc-editor` (Java/OpenGL, has a headless `render` command), going by its source. **Not run** (policy). The older tools named in the task cannot read current files. |
| Do we have complete object renders? | **Yes, with our own pipeline.** For 1.73.89, **13,071 of 13,264 exports** were rendered as complete movie-clip images (buildings, decorations, fences, paths, trees, animals, UI). There are also subsets from 1.60.231 and 1.28.146. All are in `/root/hayday-sandbox-private-assets/raw/apk_sprites/<version>/` (§5.3). |
| Geometry calibration for the app | Registration point (0,0) of a map object = **top (north) corner of its footprint**. 1 tile = **128 × 64 SC units**, so 1 SC unit = 0.5 world px (§5.4). Checked against 32 buildings with confirmed footprints. |
| Recommended route | **Route C, user-side:** the user runs `extract_from_apk.py` on an APK pulled from their own phone, or on the verified 1.73.89 XAPK already in private storage. The next step is a pack builder that maps export names to catalogue ids (§6). |

## 2. How an APK was judged genuine

* **Signature check:** the full APK Signature Scheme v2/v3 check (signed-data signature plus the 1 MiB-chunked
  content digest over the whole file) and the v1 JAR check (PKCS#7 over `.SF`, `.SF` → `MANIFEST.MF`, every
  entry digest). Two independent implementations were used: our own code, and the PyPI package
  `apksigtool 0.1.0` (pure Python, source reviewed), which agreed on 1.60.231. Negative test: copies with one
  flipped byte were **rejected**, both a v2 APK (content digest mismatch) and a v1-only APK (CRC/digest).
* **Whose key it is:** the signer on every accepted file is
  `CN=Wayne Lu ZhongWei, OU=Hayday, O=Supercell, L=Helsinki, ST=Uusimaa, C=FI`, valid from 2013-09-18, with
  certificate SHA-256 `2265e9019d3e0afc1a05531d14f4ff5346a323f7edd1f7221671b764c0cc1bab`.
  The evidence that this is Supercell's key:
  1. The identical certificate is on **independently uploaded** copies from different uploaders and years:
     1.24.92 (2018), 1.28.146 (2016), 1.54.71 XAPK (2022, all 21 splits), 1.60.231 (2024) and the
     1.73.89 XAPK (2026, all 5 splits).
  2. Android only installs updates signed with the same key, so a key that stayed constant from 2016 to 2026
     across Play-distributed builds is the publisher's key.
  3. The v2+ builds carry Google Play **source-stamp** blocks.
  4. Clash of Clans 7.156.4 (also on archive.org) is signed by `CN=Visa Forsten, OU=Supercell, O=Supercell,
     L=Helsinki`, created 2013-09-12. That is the same naming pattern, made six days earlier.
  5. Repackaged copies have **different** certificates (see §3.1).

  An independent public fingerprint would be stronger evidence, but the one place we tried for it
  (Exodus Privacy) was blocked by the network. **Approximation:** evidence 1–5 together are strong. The source
  stamps were not cryptographically checked against Google's stamp key.

## 3. Channels tried (exact results)

### 3.1 archive.org (no login for public items)

| Request | Result |
|---|---|
| `advancedsearch.php?q="com.supercell.hayday"` | 200 JSON, 2 hits: item `com.supercell.hayday` (2016) and a video ad |
| item `com.supercell.hayday` (81 MB APK) | metadata: `access-restricted-item: true`, collection `loggedin`. Ranged GET → **HTTP 401**. Not used (needs a login) |
| search `title:(hay day) AND mediatype:software` / `collection:apkarchive` / `collection:ipaarchive` | 200; 29 / 20 / 42 items. Many are named "mod" |
| Range-probed APK candidates (EOCD, `META-INF/*.RSA`, signing block, `fingerprint.json`; about 9 requests each, without downloading) | see the next table |

| archive.org item | Size (B) | Build (`fingerprint.json`) | Signer | Verdict |
|---|---:|---|---|---|
| `hay-day` (2024, "Hay Day.apk") | 476,733,471 | 1.62.180 | `CN=np, O=np, L=南京, ST=江苏, C=中国` (sha256 `492682f8…`) | **Rejected:** repackaged |
| `hay-day-www.hilelioyunindir.com` | 262,183,372 | 1.60.231 | Supercell (`2265e901…`), v1+v2+v3 + source stamp | **Accepted, downloaded** (sha1 matches archive.org's metadata) |
| `Hay-Day-1.33.130_ApkHouse.com` | 92,925,510 | 1.33.130 | `C=QA` (`cf77e64b…`) | **Rejected:** re-signed |
| `HayDay1.37.1049appsforpc` | 104,360,492 | 1.37.104 | `C=QA` (`cf77e64b…`), described as a "mod" | **Rejected** |
| `HayDay1.28.146Lastapk.com` | 77,912,392 | 1.28.146 | Supercell, v1 only | **Accepted, downloaded** (to test the LZMA path) |
| `HayDaywww.gamerroid.blogspot.com` | 49,484,797 | 1.24.92 | Supercell, v1 only | Consistent; not downloaded |
| `hay-day-v-1.54.71-game-4free.tn` (XAPK) | 175,622,604 | 1.54.71 | Supercell on all probed splits | Consistent; not downloaded |
| `Clash_of_Clans_7_156_4_android_4_0_3` | 49,187,547 | CoC 7.156.3 | `CN=Visa Forsten, OU=Supercell, O=Supercell` | Reference certificate only |

Items named as mods (`mod-cao-lua-1.62.180`, `hay-day-mod-*`, `hayday-cybermodapk`, …) and zip uploads were not
probed. **iOS IPAs** on archive.org (up to "Hay Day v1.69.93 (iOS)", which is *decrypted*) were not used: they
are DRM-stripped redistributions, and the acceptance rule covers APK signatures only.

### 3.2 Stores and mirrors

| Channel | Request | Result | Outcome |
|---|---|---|---|
| **Malavida** | product page; `/en/soft/hay-day/android/download` | 200 / 200, **no challenge**. Lists 1.73.89. Redirects `dw.malavida.com` → `dw35…/check/…` → `dw23…/dwn/<token>/com.supercell.hayday-1.73.89.xapk`: 853,515,121 B, `Accept-Ranges: bytes` | Range-probed (31 requests), then downloaded over one connection. **All 5 splits are Supercell-signed, v2+v3 verified. Accepted.** sha256 `dc4b0de2…0fbd0` |
| **Tencent MyApp 应用宝** (`sj.qq.com/appdetail/com.supercell.hayday`) | page | 200. Official China build 卡通农场: `com.tencent.tmgp.supercell.hayday` **1.75.1** (code 10750001), operator 深圳市腾讯天游科技有限公司, developer "supercell". Direct HTTPS APK on `imtt2.dd.qq.com`, 538,617,797 B, no login or challenge | Range-probed only: signer `CN=(Tencent), O=(Tencent), L=(Shenzhen)` (sha256 `58993421…10d15`), **not Supercell's**. **Not downloaded** (rule). Contains 125 `.sc` and 471 `.sctx`. Decision for the lead (§7) |
| Amazon Appstore | `amazon.com/dp/B018GSK5ZC` (linked from supercell.com) | 200, version 1.73.89, 862.3 MB | Download needs an Amazon account and the Appstore client. Not usable |
| Google Play | details page | 200 | Download needs a Google account. Not used |
| Huawei AppGallery | search API without a token / with an anonymous `getInterfaceCode` token | 403 `rtnCode 1002 "InterfaceCode Verification failed"` / 200 → `searchnothingcard` | Not listed |
| Samsung Galaxy Store | `api/detail/com.supercell.hayday` / web page | 200 `errCode 9901 "content is suspended or terminated"` / 404 | Not available |
| Xiaomi GetApps | `app.mi.com/details?id=com.supercell.hayday` | 200, generic store home page | No listing found |
| F-Droid | `api/v1/packages/com.supercell.hayday` | 404 | Not listed (expected) |
| APKMirror | app page | **403, Cloudflare challenge** ("Just a moment") | Left alone (downloads too, per the lead) |
| APKPure / apkfab / apkgk | app pages | **403, Cloudflare challenge** each | Left alone |
| Uptodown | app page | 200; downloads sit behind Turnstile (lead) | Not retried |
| apkcombo.com, apk.support | any | Proxy CONNECT **502** (network policy) | Blocked |
| Softonic | app page | 412 | Not pursued |
| Aptoide | `ws75.aptoide.com/api/7/app/getMeta` | 404 (the lead had found it not listed) | — |
| Exodus Privacy (to cross-check the certificate) | report and API | connection reset by egress | Blocked |
| haydaygame.com | home | connection reset | Blocked. The Supercell asset CDN (`game-assets.haydaygame.com`) was **deliberately not contacted** |

## 4. Tool evaluation (static source review; nothing executed)

Last-commit dates come from `git log` of fresh clones (`/tmp/hd_tools`, 2026-11-09). Licences come from the
repository files.

| Tool | Language, licence | Last commit | Containers / compression | Textures | Rebuilds shapes / clips? | Dependencies | Hay Day 1.60 / 1.73 (static reasoning) |
|---|---|---|---|---|---|---|---|
| baraklevy20/Supercell-Extractor | Node.js; no LICENSE (package.json "ISC") | 2022-04-01 | SC1 (BE version ≤ 100, v4 wrapper); LZMA, LZHAM, zstd | raw tags only; 0x2d (45 KTX) and 0x2f (47) hit "Unsupported tag" (scFormat.js L205-211) | shapes + `--extract-movie-clips` | sharp 0.29, lzma-native (native builds) | **Fails** on 1.60 (KTX atlases) and 1.73 (SC2). Fixing it means writing KTX/ASTC + SC2 support: no cheaper than our pipeline |
| 123456abcdef/cr-sc-dump | Python; no LICENSE | 2025-02-15 ("wip new sctx") | assumes the v4 header layout; LZMA, LZHAM, zstd; CSV | KTX (ASTC/ETC1 via texture2ddecoder), SCTX (WIP), raw | **atlases only** | Pillow, texture2ddecoder, zstandard, pylzham | 1.60: atlases probably; tag-45 branch passes *the rest of the buffer* to the KTX reader, so a second KTX in the same file (e.g. `decos02_seasonal`) would be lost. 1.73: no SC2 parsing |
| sc-workshop/SupercellFlash (+ SupercellCompression, SupercellTexture) | C++17, MIT | 2026-06-20 | SC1 full; SC2 v5, partial v6 (external delta-compressed matrix banks, compressed clips) | KTX, ZKTX, SCTX | **library only** (load/save); tools = texture-tool, test-tool; no rasteriser | CMake ≥ 3.22, flatc, deps fetched at `GIT_TAG main` (unpinned) | Best **format reference**: our SC2/SCTX reader follows its `.fbs` schemas. Not a renderer |
| nextonesfaster/sc-extract (`sce`) | Rust, MIT | 2021-11-09 | `_tex.sc` incl. v4, CSV | tags 01/18/1e/1a/12/08/0c; **no 0x2d KTX** | cuts single images from `_tex.sc` sprites | cargo, lzham-sys | **Fails** on 1.60/1.73 textures |
| 123456abcdef/sc-assets-download | Python | 2025-07-13 | — | — | — | stdlib | **Excluded:** downloads from Supercell CDN/servers with a forged client hello |
| xcoder-tool/XCoder (+ sc-py, sc-compression) | Python ≥ 3.13, MIT | 2026-08-04 | SC1; LZMA, LZHAM, zstd | KTX through the external **PVRTexToolCLI** (proprietary binary); SCTX re-wrapped as KTX | shapes + movie clips, but by pasting rotated/flipped bounding boxes (no general affine warp; colour transforms and masks not composited) | git deps; self-update via api.github.com | 1.60: needs PVRTexToolCLI; approximate renders. 1.73: no SC2 |
| **danila-schelkov/sc-editor** (+ supercell-swf, supercell-texture) | Java 17, MIT | 2026-08-31 (lib 2026-11-08) | SC1 + SC2 (supercell-swf takes the version ≥ 5 path) | KTX (GL), SCTX | **Real OpenGL renderer**; GUI "Export as image / video / GIF"; headless `render --exports --input --output --format --pixel-scale --start-frame --end-frame` | Maven, JOGL native jars, OpenGL (Xvfb + llvmpipe is probably enough) | Probably the most capable maintained tool. **Best reference** for checking our renders, if running external code is allowed later |
| rawnullbyte/SC-Studio | Python/PyQt6, GPL-3.0 | 2026-10-20 | SC2 v5/v6 only | ASTC/ETC/BC1/PVRTC/raw preview | editor; "Rendered effects" view exports PNG/GIF/WebP (colour transforms, blend, masks) | PyQt6 | 1.73 plausible (GUI); 1.60 no (SC1) |
| obus-globus/sc5-parser | Python; no licence file | 2026-03-16 | SC2 v5 | SCTX | named sprites with polygon UV mapping, frame labels | uv/pip | 1.73 plausible; licence unclear |
| GenericName1911/SC2FLA-FOSS-Edition | Python, GPL-3.0, Windows-only | 2025-12-29 | `.sc` → `.fla`; SC2 via `ScDowngrade.exe`, SCTX via `SctxConverter.exe` | via PVRTexToolCLI | needs Adobe Animate to render | Windows binaries | Not usable here |
| Jason-XII/sc-decoder | Python; no licence | 2026-06-21 (2 commits) | Clash Royale-oriented | — | pygame playback | pygame | Toy |
| moien007/dumpsc | C# | 2019-02-14 | — | — | — | — | README: "not working anymore" |

Compression-only libraries: xcoder-tool/sc-compression (Python, MIT), jeanbmar/sc-compression (Node),
danila-schelkov/sc-file (Java, MIT). Seen in search only, not reviewed: Daniil-SV/SCTX-Converter,
Daniil-SV/ScDowngrade (binary releases).

## 5. Our pipeline: `tools/private_assets/extract_from_apk.py`

User-side and private: it defaults to `/root/hayday-sandbox-private-assets` (or `$HAYDAY_PRIVATE_ASSETS`) and
**refuses** to write inside the repository. It contains no art. Sub-commands:

* `verify`: v2/v3 (+ v1) verification of every APK, including those inside XAPK/APKS/APKM bundles or a folder of
  `adb pull` splits, plus a check that the signer is the known Supercell certificate.
* `list`: counts of `.sc`, `_tex.sc`, `.sctx`, `.ktx`, `.zktx`, `.csv` and the `fingerprint.json` version.
* `extract`: verify → copy `assets/sc/*` → decompress → decode atlases → parse → render each export.

### 5.1 Formats as found in the three builds (measured)

| Build | `.sc` | Textures | Container | Draw commands |
|---|---|---|---|---|
| 1.28.146 (2016) | 39 (+ `_lowres` copies) | 39 `_tex.sc`, raw RGBA8888 (tag 1) | `SC` v1, MD5, **LZMA** | tag 22 |
| 1.60.231 (2024) | 62 | 62 `_tex.sc`: 77× tag 45 KTX 1.1 (ASTC 6×6 `0x93b4` ×65, 4×4 `0x93b0` ×11, 8×8 `0x93b7` ×1), 2× tag 28, 1× tag 1 LA88 | `SC` v4 wrapper, version 3, MD5, **Zstandard** | tag 22 only |
| 1.73.89 (current) | 113 | **430 `.sctx`** (ASTC; textures are external and listed per SC2 texture set) | **SC2 version 5**: FlatBuffers header (export names + hashes), Zstandard body, inline matrix banks (float matrices; precision fields = 1) | SC2 vertex buffer (float x/y + u16 u/v, triangle-strip order) |

CSV files are **uncompressed plain text** in 1.60.231 and 1.73.89 (317 / 415 files). They are a possible future
source of item facts such as sizes and levels. If they are used, they must be labelled as game-data-derived and
kept private until that use is decided.

All atlases measured are **premultiplied alpha**: under 0.2 % of semi-transparent texels have colour > alpha,
which is ASTC noise. The renderer composites in premultiplied space and un-premultiplies once at the end.

### 5.2 What was tested, and how

* Signature verification: all three builds accepted. Corrupted copies rejected (§2).
* Decompression and parse: every `.sc` of 1.60.231 parsed without unknown tags; MD5 matched. Every SC2 file
  of 1.73.89 parsed (numbers in §5.3).
* Rendering: affine-exact. Each draw-command polygon is warped from atlas UV to world XY with one affine
  map; triangles are used only when the polygon is not affine-consistent. Edges are 4× supersampled, matrices
  and colour transforms nested, masks applied (38 = mask layer, 39 = masked content, 40 = end), text fields
  skipped. The frame defaults to the clip's `IdleStart` label (Hay Day buildings label their states
  `TapStart`, `IdleStart`, `ProcessStart`, …), else frame 0.
* Visual check (by eye, private): Bakery (1.28.146, 1.60.231, 1.73.89 `bakery_01` / `bakery_02`), Dairy
  (1.60.231 and the redesigned 1.73.89), cow fence + corner, apple tree, bench, gazebo, Mud Bath and Big
  Greenhouse (mask users). All rendered as complete, correctly assembled objects. Masks look plausible but are
  **not verified against the game**.
* Not tested (no samples): raw pixel formats 2/3/4/10, ETC payloads, `.zktx`, SC2 v6, SC2 external matrix
  banks, half-precision SC2 matrices, LZHAM. These are listed in the script's docstring.

### 5.3 Full-build runs (private output)

| Build | Scope | Result |
|---|---|---|
| **1.73.89** | **every file**: `extract <xapk>` with defaults (scale 1.5, `IdleStart` frame) | 113/113 SC2 files parsed, 0 file-level errors; **430/430 `.sctx` decoded**. **13,264 exports: 13,071 rendered**, 161 skipped (nothing visible in the chosen frame, e.g. effect clips that start empty), **32 failed**. All 32 failures hit the tool's 64-Mpx canvas safety limit (map-edge backgrounds such as `bg_edge_southeast`, 10k–19k px wide at scale 1.5; a lower `--scale` would render them). No other errors. Warnings: 2,900 exports contain text fields (not drawn) and 398 use non-normal blend modes (drawn as normal). 17 min 54 s wall time in one process (~15 min CPU); 13,071 PNGs, 1.58 GB |
| 1.60.231 | all 124 container files decompressed and parsed | 0 MD5 mismatches, 0 unknown tags, 9,450 exports in the 62 `.sc` |
| 1.60.231 | rendered `buildings_new`, `decos01_generic`, `decos04_pathsandfences`, `fruit_trees_berrybushes`, `nature_new` | 1,125 of 1,127 exports rendered (2 empty), 0 failed, 27 s. A first all-files run was **aborted**: it hit a uint8-overflow bug in the premultiplied-alpha detection, which is now fixed. That run was not repeated |
| 1.28.146 | `buildings_new` + `decos`, 4 exports | rendered (LZMA path, raw RGBA8888 atlas) |

Quality check: two random samples of 36 renders each were checked by eye on contact sheets (private): one of
buildings, one of decorations, paths, fences and nature. All were assembled correctly. Exports that are
sub-parts (e.g. `bee_tree_lvl3_middle`, `squirrel_house_lvl2_right`) are partial, as expected. One class
looks wrong *as a player would see it*: water tiles such as `pondtile_corner_right` are a single shape whose
texture is a teal-to-red gradient. **Approximation:** this is input for a game shader, and our renderer shows
the raw texture.

### 5.4 Geometry calibration (for building an asset pack)

Measured on the 1.73.89 renders, at scale 1 (SC units):

* 1×1 path tiles and fields span x ≈ −64…+64 and y ≈ 0…64, so **one tile is a 128 × 64 diamond** and the
  export's origin is its **top corner**.
* For **32 production buildings whose footprints are "confirmed"** in `data/items`, the lowest art pixel lies at
  y ≈ 32·(w+h): 2×2 → 109–140 (expected 128), 3×3 → 176–203 (192), 4×4 dairy → 253 (256), and the art is
  centred on x ≈ 0. This agrees with the hypothesis. Small differences come from the art (shadows, planks).
* The app's tile is 64 × 32 world px, so **1 SC unit = 0.5 world px**. A sprite rendered at scale *s*
  (px per SC unit) has `pixels_per_world_px = 2·s`. The default *s* = 1.5 (the buildings' native texel
  density) gives 3 px per world px.
* Pack anchor (texture px at the footprint's ground centre) = `origin + s·((w−h)·32, (w+h)·16)`, where
  `origin` is stored per export in `index.json`. **Unverified:** which art axis corresponds to the catalogue's
  `w` for non-square footprints.
* Side finding: the field and 1×1 path exports cover exactly one 128×64 diamond. This supports the
  catalogue's `field: [1,1]` (currently "unverified"). Data was not changed.

## 6. Recommended route

1. **Source of client files:** use (a) the user's own phone: `adb shell pm path com.supercell.hayday`, then
   `adb pull` every path (base + splits), or (b) the already verified 1.73.89 XAPK in
   `/root/hayday-sandbox-private-assets/raw/apk/`. Re-run `verify` on any new file; the tool refuses unknown
   signers by default.
2. **Extraction:** `python3 tools/private_assets/extract_from_apk.py extract <apk|xapk|folder>`. Use `--only`
   and `--exports` for quick runs.
3. **Next step (not done here):** a private pack builder that maps export names to catalogue ids
   (`bakery_01` → `bakery`, `cow_fence` / `_corner` / `_mirrored` / `_pole` → connection masks, `_mastered` and
   seasonal names → variants). It would compute anchors with the formula in §5.4 and write
   `user://asset_packs/hayday_original/pack.json`. It needs a curated mapping table, with unmapped names left
   visibly unmapped.
4. **Validation (optional):** if running external code becomes acceptable, render a handful of exports with
   sc-editor's headless `render` command and diff them against our PNGs, especially masks and blend modes.

## 7. Open decisions for the lead

* **Tencent China build (1.75.1).** It is official (Tencent publishes Supercell's games in China), newer than
  1.73.89, and downloadable without login or challenge. But it is signed with a **Tencent** certificate, so it
  fails the "Supercell signer" rule. Not downloaded. Accept only if the rule is widened explicitly.
* **IPA route.** Decrypted iOS builds on archive.org were not used. An Apple-signed `CodeResources` chain could in
  principle authenticate the resource files, but that was not explored.
* **Running reference tools.** sc-editor and SupercellFlash could not be run under this session's policy.
