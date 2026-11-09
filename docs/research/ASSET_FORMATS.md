# Supercell Asset Formats (as documented by community tools)

**Verified: 2026-11-09** · Companion documents: [ASSET_SOURCES.md](ASSET_SOURCES.md), [LEGAL_AND_LICENSING.md](LEGAL_AND_LICENSING.md)

> **Purpose:** background knowledge only. Hay Day Sandbox will **not** parse these formats.
> Extracting game files breaches Supercell's ToS (see LEGAL_AND_LICENSING.md section 3).
> Everything below comes from reading open-source code. We opened no game files.

Labels: **Confirmed** = the cited code does exactly this. Supercell has never published a specification,
so "Confirmed" means confirmed *as implemented by the tool*, not as Supercell's ground truth.
**Community-reported** = stated in comments or READMEs, or the tools disagree.
**Approximation** = our inference. **Unverified** = not checked.

Code references (all at the default branch on 2026-11-09):
- **SE** = baraklevy20/Supercell-Extractor `src/sc/scBuffer.js`, `scFormat.js`, `sections/*.js`. https://github.com/baraklevy20/Supercell-Extractor
- **CR** = 123456abcdef/cr-sc-dump `dumpsc.py`. https://github.com/123456abcdef/cr-sc-dump/blob/master/dumpsc.py
- **SF** = sc-workshop/SupercellFlash `supercell-flash/source/flash/...`, `sc2_schemas/*.fbs`. https://github.com/sc-workshop/SupercellFlash
- **SCC** = sc-workshop/SupercellCompression `supercell-compression/source/compression/backend/sc/`. https://github.com/sc-workshop/SupercellCompression

## 1. File families

| Extension | Content | Source |
|---|---|---|
| `foo.sc` | Display-object definitions (shapes, movie clips, text fields, matrices, export names). May also contain textures | SE scFormat.js L49-224 |
| `foo_tex.sc`, `foo_lowres_tex.sc`, `foo<suffix>_tex.sc` | Texture atlases only, loaded when `foo.sc` contains tag 26 "use external texture" | SE scFormat.js L29-47; SF SupercellSWF.cpp L69-87 |
| `*_dl.sc` | Older layout with the full header (CR's `--old` flag) | CR README, L330-336 |
| `.ktx`, `.zktx`, `.sctx` | External GPU-compressed textures (Khronos KTX, compressed KTX, Supercell "SCTX") | SF SWFTexture.cpp L420-446; CR L157-262 |
| `.csv` | Game data tables, LZMA-compressed, optionally prefixed by a signature | CR L99-102, L405-416, L444-447 |

## 2. Container header and compression signatures

**SC1 header (Confirmed: SE scBuffer.js L8-31, CR L313-323, SCC sc_decompressor.cpp L31-72):**

```
"SC"            2 bytes  magic (0x53 0x43)
version         u32 BE   1..4
[if version==4] u32 BE   real version, followed by a trailing metadata block (see below)
hash_len        u32 BE   usually 16
hash            hash_len MD5 of the *decompressed* payload (SE L65-72 and CR L325 check it)
payload         compressed body (LZMA / LZHAM / Zstandard)
```

- **Version 4 trailer (Community-reported):** SE stops decompressing at the string `START`, with the
  comment "rest of the file seems to contain export names" (L15-19). SCC reads the last 4 bytes as a
  length and parses a FlexBuffers map of export name to hash (L52-66).
- **Version to compression mapping (Community-reported, tools disagree):**
  - SCC: v1 = LZMA or LZHAM, v2 = uncompressed (its own comment says "are you sure?"), v3 = Zstandard (L74-101).
  - SE: any version of 2 or higher = Zstandard (L28-31).
  - CR: ignores the version number and detects compression from magic bytes (L57-96).
- **Signatures (Confirmed in code):**

| Compression | Signature at the start of the payload | Reference |
|---|---|---|
| Zstandard | `28 B5 2F FD` (zstd frame magic, RFC 8878) | CR L72 (`zstandard.FRAME_HEADER`) |
| LZHAM | `SCLZ`, then `dict_size_log2` (u8) and unpacked size (u32 LE) | CR L58-70; SE L50-59; SCC `SC_LZHAM_MAGIC` |
| LZMA | 5-byte props (first byte usually `0x5D`, SE also accepts `0x5E`), then **4-byte** unpacked size (LE). Standard `.lzma` uses 8 bytes, so tools insert 4 zero bytes | CR L76-95; SE L34-48 |
| Headerless legacy | Raw LZMA with no `SC` magic | SCC L35-45; SE L23-26 |
| Signed CSV | `Sig:` (`53 69 67 3A`), then 64 more bytes (68 skipped in total), then LZMA | CR L410-411, L446-447; SCC `SC_SHA64_MAGIC` |

**SC2 (versions 5 and 6, Confirmed in SF SupercellSWF.cpp L25-40, L90-158, L665-680):** after `"SC"`,
the version is stored **little-endian** (SF swaps byte order when the big-endian value is above 4). v6
adds a u16 that is always 0. Next comes a u32 descriptor size and a **FlatBuffers `Header`** table
(`sc2_schemas/Header.fbs`) holding `shape_count`, `movie_clips_count`, `texture_count`,
`text_fields_count`, `resources_offset`, `metadata` (export name plus hash), `compressed_size` and
`external_matrix_bank_size`. The body after it is Zstandard-compressed. *Approximation:* SE's
`version <= 100` check (scBuffer.js L12) rejects these files, so SE cannot read SC2.
**Unverified:** which of SC1 or SC2 current Hay Day builds use.

## 3. SC1 decompressed body

- **Header (Confirmed: SE scFormat.js L59-80, SF SupercellSWF.cpp L161-196):** six u16 counts (shapes,
  movie clips, textures, text fields, matrices, colour transforms), 5 unused bytes, export count (u16),
  export IDs (u16[]), then export names (u8 length-prefixed UTF-8 strings). `_tex.sc` files have no such
  header: they go straight to tags (CR treats files as texture-only unless `--old` is passed, L330-336).
- **Tag stream:** `tag u8, length u32 LE, body`, repeated until tag 0 (SE L92-214, SF L241-242).
- **Tag IDs (Confirmed, SF `flash_tags.h` L5-66):**

| Tags | Meaning |
|---|---|
| 1, 16, 19, 24, 27, 28, 29, 34 | Texture variants (TEXTURE ... TEXTURE_8) |
| 45 / 47 | TEXTURE_9 (embedded KTX) / TEXTURE_10 (external texture file path) |
| 2, 18 | Shape / Shape_2 |
| 4, 17, 22 (inside shapes) | ShapeDrawBitmapCommand v1/v2/v3 (6 = deprecated colour fill) |
| 3, 10, 12, 14, 35, 49 | MovieClip variants (3 and 14 deprecated, 49 = custom property index) |
| 5, 11 (inside movie clips) | MovieClip frame |
| 7, 15, 20, 21, 25, 33, 43, 44, 46 | TextField variants |
| 8, 36 / 9 / 42, 41 | 2x3 matrix (v1, v2) / colour transform / matrix bank and bank index |
| 23 / 26 / 30 / 32 | Use low-res texture / use external `_tex.sc` / multi-res / texture file suffixes |
| 31 | Scaling grid (9-slice) |
| 37-40 | MovieClip modifiers (mask layers) |

## 4. Textures (atlases)

- **Layout (Confirmed: SF SWFTexture.cpp L163-226, SE texture.js L132-174, CR L369-399):** optional
  prefix (tag 47: path string, tag 45: i32 KTX length), then `pixel_format u8, width u16, height u16`,
  then the pixels when the data lives in this file.
- **Pixel formats (Confirmed, SF SWFTexture.h L24-31 and CR L105-154):** 0/1 = RGBA8888,
  2 = RGBA4444, 3 = RGBA5551, 4 = RGB565, 6 = LA88 (luminance and alpha), 10 = L8. SE also maps indices
  5 and 7-9 (texture.js L3-42).
- **Tiled storage (Confirmed):** tags 27, 28 and 29 store pixels in **32x32 blocks** in row-major block
  order (SF: `m_linear=false` for TEXTURE_5/6/7, L216-218; SE L144-166; CR L379-390). The other tags are
  stored linearly.
- **Filtering (Confirmed, SF L208-214):** tags 16, 19 and 29 use mipmaps; tag 34 uses nearest.
- **GPU-compressed (Confirmed, CR L204-262, SF L423-433):** KTX 1.1 and 2.0 containing ASTC 4x4, 6x6 or
  8x8, or ETC1. `.sctx` holds ASTC with an optionally compressed payload (CR L157-201). `.zktx` is a
  compressed KTX (SF L423-425).
- **SC2 textures (Confirmed, `Textures.fbs`):** `TextureSet { lowres, highres }`. Each `TextureData`
  has `pixel_type`, `width`, `height`, `data`, or an `external_texture` path (zktx/ktx/sctx).

## 5. Shapes: how one sprite is assembled from atlas regions

- **Shape (Confirmed, SF Shape.cpp L6-48; SE shape.js L76-131):** `id u16`, `command_count u16`, plus
  `vertex_total u16` for tag 18 only. Then nested command tags until 0.
- **Draw command (Confirmed, SF ShapeDrawBitmapCommand.cpp L6-21):** `texture_index u8`,
  `vertex_count` (fixed at 4 for tag 4, otherwise u8), then `vertex_count` x **XY** as i32 *twips*
  (divided by 20 to get pixels, SE scBuffer.js L84-86), then `vertex_count` x **UV** as u16 pairs.
- **UV units (Community-reported, the tools disagree):** SE scales UV by `/0xFFFF * atlas size` only for
  tag 22 and treats tags 4 and 17 as absolute atlas pixels (shape.js L119-131). SF divides by 65535 for
  every tag.
- **Composition (Confirmed in SE and SF code):** a shape is a *set* of textured polygons. Each command
  cuts a polygon (a triangle fan, SF Shape.cpp L33) out of one atlas (`texture_index`) at the UV
  coordinates and places it at the XY coordinates in the shape's local space. The atlas region may be
  stored rotated by multiples of 90 degrees or mirrored relative to its placement. SE works this out from
  the winding order of the XY and UV polygons (shape.js L17-55). The finished sprite is the union of all
  polygons, whose bounding box gives the sprite's size and origin (SE `getRegion` and `getShapeRegion`).
  An object in the game is therefore not a single rectangle cut from the atlas.
- **SC2 shapes (Confirmed, `Shapes.fbs`, `DataStorage.fbs`):** commands are
  `{texture_index, points_count, points_offset}`, and the vertices live in a shared
  `DataStorage.shapes_bitmap_poins` buffer.

## 6. Movie clips, matrices and exports

- **MovieClip (Confirmed, SE movieClip.js L19-80):** `id u16`, `frame_rate u8`, `frame_count u16`,
  `element_count u32`, then elements of `{child_index, matrix_index, color_transform_index}` (0xFFFF
  means identity). Then `child_count u16`, the child IDs, blend modes (one byte per child, tags 12 and 35
  only) and child names. Frame tags (11) follow.
- **Matrix (Confirmed, SE transformMatrix.js):** `a, b, c, d` as i32/1024, and `tx, ty` as i32 twips/20.
- **Exports (Confirmed SE L69-80; Approximation for game behaviour):** export names map a string to a
  display-object ID. *Approximation:* the game creates buildings and decorations by export name, usually
  as a MovieClip (animation and states) made of shapes. That is why SE renders movie clips to get a whole
  building. **Unverified:** the export names used for Hay Day.

## 7. CSV data tables

- **Container (Confirmed, CR L99-102, L405-416, L444-447):** a first byte of `0x5D` means LZMA. A `Sig:`
  prefix means 68 bytes are skipped first. The decompressed output is plain CSV text.
- **Layout (Community-reported, not documented by the four projects):** row 1 holds column names and
  row 2 holds column types (e.g. `String`, `int`, `Boolean`). Later rows are entries, and a blank name
  cell continues the previous entry (for example per-level rows).
- **Hay Day folders (Confirmed / Approximation):** SE's `.gitignore` excludes `/csv_client/` and
  `/csv_logic/`. *Approximation:* these mirror the game's data folders.
- **Building and decoration columns such as width/height: Unverified.** None of the evaluated projects
  documents Hay Day CSV columns, and we opened no game CSV. Public, citable footprint data exists on the
  Hay Day Wiki instead (e.g. Bakery infobox `size = 3×3`, see ASSET_SOURCES.md section 4).

## 8. Implications for Hay Day Sandbox

1. Do not implement any of the above in the app or its tools. Item footprints come from curated data,
   not from decoded CSV files.
2. User-imported art will be **plain PNG** (e.g. fan kit renders or the user's own drawings). The importer
   needs per-item `scale`, `anchor/offset` and optional `flip` settings, because source images are not
   aligned to the tile grid (see the fan kit sizes in ASSET_SOURCES.md).
3. Extend the git-ignore and CI guards to cover every game-file family listed in section 1 (`*.sc`,
   `*_tex.sc`, `*.sctx`, `*.ktx`, `*.zktx`, `*.apk`, `*.xapk`, `*.obb`, and game `csv_client/` and
   `csv_logic/` dumps), so no extracted file can be committed by accident.
