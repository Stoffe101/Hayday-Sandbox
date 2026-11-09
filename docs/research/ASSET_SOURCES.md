# Asset Sources Evaluation

**Verified: 2026-11-09** · Companion documents: [LEGAL_AND_LICENSING.md](LEGAL_AND_LICENSING.md), [ASSET_FORMATS.md](ASSET_FORMATS.md)

Labels: **Confirmed** (read directly in source code, files or JSON on the verification date),
**Community-reported** (stated by third-party projects or wikis), **Approximation** (our inference),
**Unverified** (not checked or not checkable). This is not legal advice.

**How we verified.** We read Supercell's pages with curl. We enumerated the fan kit through the JSON
endpoints its own web app calls, reading metadata only. We downloaded no images. We read the GitHub
projects as source files from `raw.githubusercontent.com`. **The GitHub REST API (`api.github.com/repos/...`)
was blocked for these repositories in this research session.** As a result, last-commit dates and GitHub's
licence detection are **Unverified**. Where we give dates, they are estimates from evidence inside the code.
We ran none of the tools, and we downloaded no game files, APKs or sprites.

## 1. Status table

| Source | What it offers | Verified how | License | Usable for Hay Day Sandbox? | Confidence |
|---|---|---|---|---|---|
| Supercell Fan Kit, Hay Day ([fankit.supercell.com/hayday](https://fankit.supercell.com/hayday)) | 2,866 official PNG/JPG assets, including building, decoration, fence and path renders | Frontify JSON endpoints, metadata only | No per-asset licence. Governed by the FCP (non-commercial, unmodified, disclaimer, revocable) | **Art: user-side only.** Users may download it themselves and import it locally. Do not commit or redistribute it. **Names: yes**, as identifiers | High (contents), Medium (permission for our use) |
| [baraklevy20/Supercell-Extractor](https://github.com/baraklevy20/Supercell-Extractor) | Node.js `.sc` decoder that outputs textures, cut shapes and movie clips | README, package.json, src/*.js | No LICENSE file. package.json says `"license": "ISC"` (the npm default) | **No.** Using it breaches the ToS, and it is old and does not support current formats (SC2 / KTX / SCTX) | High (code), Low (date) |
| [123456abcdef/cr-sc-dump](https://github.com/123456abcdef/cr-sc-dump) | Python dumper that outputs whole texture atlases as PNG and decompresses CSVs | README, dumpsc.py, requirements.txt | No LICENSE file found | **No.** Using it breaches the ToS. Its README points to a third-party APK mirror | High (code), Low (date) |
| [sc-workshop/SupercellFlash](https://github.com/sc-workshop/SupercellFlash) | C++ library that reads, modifies and saves `.sc` (SC1, SC2 v5, partial v6) | README, LICENSE, CMake, source/*.cpp/.h, sc2_schemas/*.fbs | MIT, "Copyright (c) 2025 SC Workshop" | **No** (same ToS issue). Useful only as format documentation | High |
| [123456abcdef/sc-assets-download](https://github.com/123456abcdef/sc-assets-download) | Downloads game asset files directly from Supercell's CDN or game servers | README, sc_assets_download.py, Dockerfile | No LICENSE file found | **No.** It talks to Supercell servers while posing as a game client, which likely breaches the ToS. Its Hay Day configuration is out of date | High (code) |
| Hay Day Wiki (Fandom), text and infoboxes ([hayday.fandom.com](https://hayday.fandom.com)) | Item names, levels, prices, and `size` (footprint) in building infoboxes | MediaWiki API: siteinfo plus page wikitext | Text CC BY-SA | **Yes, for metadata**, recorded by hand with attribution. Decoration sizes are not always listed | Medium |
| Hay Day Wiki images | Screenshots and sprites | The pages reference `File:*.png` | Supercell's copyright, not covered by CC BY-SA | **No** | Medium |
| The user's own screenshots | Real in-game look | n/a | Supercell's copyright in the depicted art | User-side import only. Never commit | Medium |
| Original placeholder art | Shapes and icons made for this project | n/a | Project's own licence | **Yes. The only art that may be committed** | High |

## 2. Supercell Fan Kit (Hay Day)

- **Confirmed:** https://fankit.supercell.com/ is a Frontify brand portal. The Hay Day entry links to
  https://fankit.supercell.com/hayday, which redirects to `/d/QSVyhmM7gdGe/game-assets`. The page is a
  JavaScript app. Its data comes from same-origin endpoints such as
  `/api/assets/search/361?limit=25&page=1&order=NEWEST&asset-type91=Buildings`, `/api/facette/list/361`
  and `/api/project?document_id=361` (project name "Hay Day Fan Kit"). These are internal endpoints, not
  a documented API, so they may change.
- **Confirmed:** the "Asset Type" facet counts as of 2026-11-09 (facets overlap, so they do not sum to the
  2,866 total):

| Facet | Count | Formats | Example titles |
|---|---|---|---|
| Decorations | 915 | PNG | `HayDay_Acacia_Tree`, `HayDay_Castle_Tower`, `HayDay_10th_Birthday_Ferris_Wheel` |
| Crops & Goods | 556 | PNG | product icons |
| Characters | 325 | PNG (+10 JPG) | animals and humans |
| Buildings | 182 | PNG | `HayDay_Bakery`, `HayDay_Bakery_Mastered`, `HayDay_Barn_Lvl_0..4`, `HayDay_House_Lvl1..9`, `HayDay_Feedmill`, `HayDay_Roadside_Shop` |
| Flowers Plants and Trees | 156 | PNG | overlaps with Decorations |
| Paths | 139 | PNG | tile variants (`_Corner`, `_End`, `_Mirrored`, `_Pole`, `_Cross_Int`), e.g. `HayDay_Cobbelstone_Path_Corner` |
| Fences | 102 | PNG | `HayDay_Picket_Fence`, `_Corner`, `_Pole` variants |
| Farm Pass / Sanctuary / Animal Accessories / Valley | 96 / 95 / 78 / 67 | PNG | seasonal items |
| "Hay Day" | 39 | PNG + JPG | `HayDay_Logo`, `HayDay_AppStore`, event key art, crate icons |

- **Confirmed:** image sizes are not normalised. The most common Buildings sizes are 1024x768 and
  878x757. Common Decorations sizes range from about 172x108 to 308x147. There is no tile footprint,
  anchor or pixel-per-tile metadata. To place these images on a grid, each item needs its own scale and
  offset settings.
- **Confirmed:** `licenses: []` on every asset. Use is governed by the FCP (see LEGAL_AND_LICENSING.md).
- **Unverified:** the camera angle and whether the art matches the in-game isometric projection, because
  we did not download any images.

## 3. Extractor projects

### baraklevy20/Supercell-Extractor
- **Language/deps (Confirmed, package.json):** JavaScript (Node). `fzstd 0.0.3`, `js-md5`,
  `lzma-native ^8.0.6`, `mathjs ^10.0.0`, `p-limit`, `sharp ^0.29.3`, `smart-buffer`, `winston`,
  `yargs`, plus a bundled LZHAM module (`src/lzham`).
- **License:** no `LICENSE`, `LICENSE.md` or `LICENSE.txt` at the repository root (all returned 404).
  package.json has `"license": "ISC"`. *Approximation:* that is npm's default, not a deliberate grant.
  Treat the project as all rights reserved.
- **Formats (Confirmed, README and `src/sc/scBuffer.js` L8-63):** `.sc` with `_tex.sc` or
  `_lowres_tex.sc` external textures. Compression: LZMA, LZHAM (`SCLZ`), Zstandard, and the "version 4"
  header. Outputs: textures, shapes cut from atlases, gradients, and optionally movie clips
  (`--extract-movie-clips`). CSV and SC3D: "Maybe in the future".
- **Current Hay Day files: probably not supported (Approximation from code).** It treats a file as SC
  only when `version <= 100` (scBuffer.js L12), but SC2 files store version 5 or 6 little-endian, so that
  check fails. Texture tags 45 (KTX) and 47 (external file) fall into "Unsupported tag" (scFormat.js
  L205-211). The README claims Hay Day support, but for older files.
- **Downloads from Supercell:** no. It reads local files.
- **Maintenance:** *Approximation:* the dependency versions are from about late 2021 (sharp 0.29, eslint
  8.3, mathjs 10). The README still tells users to clone the old repository name `Supercell-Viewer`.
  The project looks inactive. Last commit date: **Unverified**.
- **README terms (Confirmed):** "purely for fun. You may not use it to develop a clone to these games or
  hack the games in any way. Please follow the Supercell fan content policy".

### 123456abcdef/cr-sc-dump
- **Language/deps (Confirmed):** Python 3. `Pillow`, `pylzham`, `texture2ddecoder`, `zstandard`
  (requirements.txt). The README mentions an optional Docker build.
- **License:** no LICENSE file found. Treat as all rights reserved.
- **Formats (Confirmed, `dumpsc.py`):** `.sc`, `_dl.sc` (`--old`), `_tex.sc`, `.csv` (LZMA, or with a
  `Sig:` prefix), `.ktx` (KTX 1.1/2.0 with ASTC 4x4/6x6/8x8 or ETC1), `.sctx` (ASTC), and LZMA, LZHAM
  and Zstandard compression (L57-96, L157-302, L405-416). It dumps **whole atlas textures** only and does
  not cut atlases into individual sprites (L313-402).
- **Current Hay Day:** the README says it "Works the same for any other Supercell game". **Unverified.**
  *Approximation:* KTX and SCTX handling suggests it was updated more recently (around 2024) than
  Supercell-Extractor.
- **Downloads:** none in the code. The README tells users to "Download [Clash Royale APK](https://apkpure.com/...)"
  (a third-party mirror) or to pull files from a rooted device.
- **Maintenance / last commit:** Unverified.

### sc-workshop/SupercellFlash
- **Language/deps (Confirmed):** C++17, CMake 3.22 or later, FlatBuffers (`flatc` on PATH). Fetches
  `Workshop-Core`, `SupercellCompression` and `SupercellTexture` at `GIT_TAG main`, meaning unpinned
  (`cmake/dependencies.cmake`).
- **License (Confirmed):** MIT, "Copyright (c) 2025 SC Workshop". The SupercellCompression README carries
  an FCP-style disclaimer.
- **Formats (Confirmed):** "Full support for SC1. Support for SC2 V5, partial V6 support". Reads and
  writes `.sc`, with external `_tex.sc` and low-res or multi-res variants, and `.ktx`, `.zktx` and `.sctx`
  textures (`SupercellSWF.cpp` L25-87, `SWFTexture.cpp` L420-446). Compression is handled by
  SupercellCompression (LZMA, LZHAM, Zstandard, ASTC).
- **Downloads:** none. It is a library, plus optional tools (`SC_FLASH_BUILD_TOOLS`).
- **Maintenance:** *Approximation:* the most current of the four (copyright 2025, SC2 schemas). The
  README TODO says "Linux and Mac OS support", so it is Windows-first. Last commit: Unverified.

### 123456abcdef/sc-assets-download
- **Language/deps (Confirmed):** Python 3 standard library only. Docker image `python:3-alpine`.
- **License:** no LICENSE file found.
- **What it does (Confirmed, `sc_assets_download.py`):** for `bb`, `bs` and `cr` it opens a TCP socket to
  the game server on port 9339 and sends a forged `ClientHello` (message 10100) to obtain the fingerprint
  (L70-115). For `hd` it fetches
  `http://game-assets.haydaygame.com/<contentHash>/fingerprint.json` and then every listed file (L175-217).
- **Hay Day config is out of date (Confirmed):** `majorVersion 1`, `build 49`,
  `contentHash 32b1a85e...` (L57-66). The README says Hay Day handshake support is "tbd". Whether the CDN
  still serves that hash: **Unverified** (not run).
- **ToS (Approximation):** reaching Supercell servers "by any means other than the user interface
  provided by Supercell" and obtaining information "using any method not expressly permitted" are both
  forbidden. **Do not use.**
- **Maintenance:** the README says the hashes must be updated by hand after every game update. Last
  commit: Unverified.

## 4. Metadata sources

- **Confirmed:** the wiki's Bakery page infobox contains `level = 4`, `price = 20`, `time = 10 s`,
  `slots = 2`, `size = 3×3`
  (https://hayday.fandom.com/api.php?action=parse&page=Bakery&prop=wikitext&format=json).
- **Confirmed:** decoration list pages (e.g. `Decorations/Nature`) give names, levels and prices, but no
  sizes in their tables. Footprints would have to be collected page by page or observed in the game.
- **Recommendation:** keep a hand-curated data file in which every record has a `source` field (wiki
  page URL or "in-game observation"). Credit the Hay Day Wiki under CC BY-SA if values are copied from it.
