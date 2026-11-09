# Legal and Licensing Research

**Verified: 2026-11-09** · Scope: Hay Day Sandbox (offline, personal, non-commercial Godot 4 farm layout planner)

> **Not legal advice.** This is a reading of the published texts by a non-lawyer. Where
> applying a clause to this project needs a judgment call, the finding is labelled
> *Approximation* or *Unverified*. If the project is ever published widely,
> monetised, or receives a takedown request, get a qualified lawyer's opinion.

Labels: **Confirmed** = read directly in the primary source on the verification date.
**Community-reported** = stated by third-party projects or wikis, not by Supercell.
**Approximation** = our interpretation or inference. **Unverified** = not checked or not checkable.

## 1. Primary sources read

| Document | URL | Version seen |
|---|---|---|
| Supercell Fan Content Policy (FCP) | https://supercell.com/en/fan-content-policy/ | "Last updated: September 27, 2023" (previous version 2020-03-30: https://supercell.com/en/fan-content-policy/en/2020-03-30/) |
| Supercell Terms of Service (ToS) | https://supercell.com/en/terms-of-service/ | "Effective Date: November 6, 2024" |
| Supercell Fan Kit, Hay Day portal | https://fankit.supercell.com/hayday (redirects to https://fankit.supercell.com/d/QSVyhmM7gdGe/game-assets) | Assets dated up to 2026-11-06 |
| Hay Day Wiki (Fandom), site licence | https://hayday.fandom.com/api.php?action=query&meta=siteinfo&siprop=rightsinfo | `CC-BY-SA`, links to https://www.fandom.com/licensing |

## 2. Fan Content Policy: what it allows and forbids

All quotes below are **Confirmed** from https://supercell.com/en/fan-content-policy/.

- **Scope covers both fan-kit and in-game material.** The FCP "governs your use of Supercell Oy's
  ("Supercell") copyrights and trademarks from our games, including any related fan kits (such as those
  available at fankit.supercell.com) provided by us ("Supercell Assets")". It does **not** make a separate,
  looser category for fan-kit files; fan-kit art and in-game art are both "Supercell Assets".
- **Purpose limit:** use "must be limited to displaying, identifying and discussing only Supercell's
  products". "You cannot create new products or content based on Supercell Assets, such as games based on
  the Supercell game characters. Not even if they were free."
- **Apps and tools are possible:** "Permitted Fan Content normally includes for example non-commercial
  fan-generated online guides and guide apps, fan meetups, fan pages and gameplay videos".
- **Non-commercial:** "You are not permitted to charge a fee of any kind (including in-app
  functionalities)" unless Supercell approves. The allowed ways to earn money are ads, donations not tied
  to features, and coaching. FAQ: "Can I sell my base layouts? Yes. Selling base layouts is considered
  coaching."
- **Brand and modification:** you "cannot create the impression that Supercell is a sponsor or creator of
  or otherwise endorses your Fan Content" and "You can't modify Supercell Assets without our express
  permission."
- **Physical goods and adaptations:** no merchandise and no novels or plays. (The heading is "Keep it
  online"; offline *digital* use is not addressed.)
- **"No bad stuff":** no use with content that "promotes or contains cheats, hacks, exploits, automation
  software, bots, mods or any unauthorized third-party software designed to modify or interfere with any
  Supercell game", or that "contains information which is not yet public" (FAQ: leaks violate the
  policy). FAQ: "Can I create Fan Content using 3rd party applications such as private servers? No."
- **Required disclaimer** (or a "substantially similar" one, in a legible font):
  > "This material is unofficial and is not endorsed by Supercell. For more information see Supercell's
  > Fan Content Policy: www.supercell.com/fan-content-policy."
- **Names:** "You can't register domain names, social media accounts or related addresses for your Fan
  Content which include Supercell's trademarks (such as SUPERCELL or our game names) without a separate
  written agreement with us."
- **Revocable, part of the ToS:** Supercell "may revoke the limited use license in this Policy at any time
  and for any reason". "This Policy is part of the Supercell Terms of Service". "We will not give warnings
  for violations of this Policy."

## 3. Terms of Service: extracting from and downloading out of the game

All quotes are **Confirmed** from https://supercell.com/en/terms-of-service/.

- **Licence to use the game:** "a non-exclusive, non-transferable, non-sublicensable, revocable and
  limited right to access and use the Service for your own non-commercial entertainment purposes. You
  agree not to use the Service for any other purpose."
- **Reverse engineering and data extraction:** players agree not to "Reverse engineer, decompile,
  disassemble, decipher or otherwise attempt to derive the source code for any underlying software or
  other intellectual property used to provide the Service or any Supercell game, or to obtain any
  information from the Service or any Supercell game using any method not expressly permitted by
  Supercell."
- **Server access:** players must not "Attempt to gain unauthorized access to the Service ... or to the
  computers, servers, or networks connected to the Service by any means other than the user interface
  provided by Supercell".
- **Modifying files:** players must not "Modify or cause to be modified any files that are a part of the
  Service or any Supercell game without Supercell's express written consent."
- **Ownership (section 2.1):** Supercell owns "computer code, themes, objects, characters, character
  names, ... artwork, animations, sounds" and more, and "reserves all rights".

**Approximation:** unpacking an APK and decoding `.sc`, `_tex.sc` or `.csv` files is a "method not
expressly permitted" to "obtain information" from the game, so it breaches the ToS for anyone who has
accepted them. Pretending to be a game client to reach the asset CDN or game server (what
`sc-assets-download` does) also falls under the server-access clause. The FCP never says datamined art is
permitted. On top of that, extracted packs routinely contain unreleased content, and publishing that is a
"leak" under the FCP.

## 4. Fan Kit: what it contains and under what terms

- **Confirmed:** the Hay Day portal is a Frontify media library (portal 68, document 361, project 169,
  named "Hay Day Fan Kit"). Its public JSON endpoints (`/api/facette/list/361`,
  `/api/assets/search/361`, `/api/project?document_id=361`) list **2,866 assets**. The category facets
  include **Buildings (182), Decorations (915), Fences (102), Paths (139), Flowers Plants and Trees
  (156)**, Crops & Goods (556), Characters (325), Animal Accessories (78), Farm Pass (96), Valley (67),
  Sanctuary (95) and "Hay Day" (39: logo, store art, event key art, crate icons). ASSET_SOURCES.md has the
  full table.
- **Confirmed:** every asset has `"licenses": []` and an empty `meta_copyright_notice`. The project has
  `"copyright_download_consensus": false`. The fan kit home page and the Hay Day navigation link only to
  the FCP; the home page footer also links the general Privacy Policy and ToS. **We found no separate fan
  kit licence text.** The FCP is the licence.
- **Unverified:** whether every file can be downloaded without filling in the project's
  "Intended use" request form (`download_request_form` exists in the project JSON, while each asset reports
  `download_status: "Available"`). We downloaded no images, so we have not judged their visual angle or
  quality.

## 5. Item metadata (facts) versus artwork

| Data | Assessment | Label |
|---|---|---|
| Item names, footprint sizes (e.g. 3x3), unlock levels, prices | Individual facts are generally not protected by copyright. Item names can be trademarks or Supercell text, but naming an item only to identify it is normal fan-guide practice under the FCP ("identifying and discussing"). | Approximation |
| Bulk copy of the game's own CSV tables | Getting the tables breaches the ToS (see section 3). Supercell is a Finnish company, and the EU sui generis database right (Directive 96/9/EC) can protect *substantial extraction* from a database even when each entry is a fact. | Approximation |
| Hay Day Wiki text and tables | Text is CC BY-SA (siteinfo above). Copying wiki tables means giving attribution and licensing that data file under CC BY-SA. Recording individual facts by hand, with a citation, carries the least risk. | Confirmed (licence) / Approximation (application) |
| Hay Day Wiki images | Screenshots and sprites of Supercell art. The site's CC BY-SA does not override Supercell's copyright in them. | Community-reported / Approximation |
| Fan kit PNGs | Allowed **only** within the FCP: non-commercial, with the disclaimer, unmodified, not implying endorsement, and revocable. | Confirmed (terms) |
| Datamined sprites (`.sc` extraction) | Getting them breaches the ToS. Not covered by any licence. | Approximation |

## 6. Risks specific to this project

1. **"New product" versus "guide app" (Unverified):** a layout planner that lets you place items on a farm
   grid fits the FCP's "guide apps" example, but if it shipped Supercell art it could be read as a "new
   product ... based on Supercell Assets". No published Supercell text settles this either way.
2. **"Can't modify":** fitting fan kit renders to a grid (cropping, re-anchoring, tinting, scaling,
   slicing fence pieces) may count as modification. Displaying an image scaled down unchanged is probably
   lower risk. *Approximation.*
3. **Repository and app name (Approximation / Unverified):** the name "Hayday-Sandbox" contains the game
   name. The FCP bars "domain names, social media accounts or related addresses" that contain game names.
   Whether a GitHub repository name counts as a "related address" is unclear. If the project is
   published, consider a neutral public name (for example "Farm Layout Sandbox") and use "Hay Day" only in
   descriptive text.
4. **Redistribution:** committing fan kit or extracted art to a public git repository republishes it in
   bulk. That goes beyond "displaying, identifying and discussing", and the art would stay in git history
   even if Supercell revoked permission. *Approximation.*

## 7. Recommended asset policy

1. **Ship only original art.** The repository contains only placeholder or original art made for this
   project (shapes, colour blocks, simple icons) under the project's own licence. No Supercell logos, app
   icons or fonts.
2. **Users bring their own images locally.** The app imports PNGs the user picked into the per-user data
   directory (Godot `user://`). Developers use the git-ignored `assets/original/` folder. Imported images
   are never committed, packaged or exported in shared layout files. Shared layouts reference item IDs
   only.
3. **Recommend the official source.** Documentation may tell users that the Supercell Fan Kit is the
   Supercell-provided source and that its use is governed by the FCP. The app must not scrape it, bulk
   download from it or mirror it.
4. **No extraction features.** No code that reads `.sc`, `_tex.sc`, `.sctx`, `.ktx` or game `.csv` files.
   No APK handling, no calls to Supercell servers or CDNs, no account data. Do not link to or bundle the
   extractor projects in ASSET_SOURCES.md as a recommended workflow.
5. **Metadata comes from hand-curated facts.** Each item record (name, footprint, level) cites its source:
   own observation in the game, or a wiki page with CC BY-SA attribution. No bulk import of client CSVs.
6. **Disclaimer.** Put the FCP disclaimer (section 2) in the README and the in-app About screen. State
   that the project is not affiliated with Supercell.
7. **Stay non-commercial, and no leaks.** No paid features, no unreleased items, no datamined
   "upcoming" content.
8. **Re-check this research** whenever the FCP or ToS "last updated" dates change.
