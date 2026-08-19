# Upstream versions & download URLs (pinned 2026-08-19)

Verified on 2026-08-19 (UTC) from primary sources: the sourcemm.net / sourcemod.net
download pages, the `mmsdrop` / `smdrop` directory listings, and the GitHub REST API
(`api.github.com`). Every URL below answered HTTP 200 to a HEAD/GET at verification
time. SHA-256 values come from the GitHub release-asset `digest` field (GitHub
publishes these for assets uploaded since ~2025); where no digest is published this
is stated explicitly. Nothing was downloaded to or executed on the Windows research
machine — sizes are from `Content-Length` / API metadata.

Two things worth knowing before you copy URLs:

* **AlliedModders now mirrors MM:S and SM builds as GitHub Releases.** Since build
  1221 (MM:S) the sourcemm.net / sourcemod.net download buttons point at
  `github.com/alliedmodders/<repo>/releases/download/<ver>.<build>/<file>` instead of
  `mmsdrop`/`smdrop`. Both hosts still serve the same file (same size); the
  `mmsdrop`/`smdrop` copies have no published checksum, the GitHub copies do.
* **srcdslab (SMAC, Lilac) publish a rolling `latest` release** that is deleted and
  re-created on every push to `master`. The asset name never changes; the content and
  sha256 do. Pin by commit sha, not by the `latest` tag.

## Summary table

| # | Component | Version / tag | Build date (UTC) | Linux download URL | Size | SHA-256 |
|---|---|---|---|---|---|---|
| 1 | Metamod:Source 1.12 (stable branch) | `1.12.0-git1225` (tag `1.12.0.1225`, commit `afc8233eedcd0c832b411c1da852328328db5c50`) | 2026-07-22 23:41 | https://github.com/alliedmodders/metamod-source/releases/download/1.12.0.1225/mmsource-1.12.0-git1225-linux.tar.gz — mirror: https://mms.alliedmods.net/mmsdrop/1.12/mmsource-1.12.0-git1225-linux.tar.gz | 5,046,043 B | `9291c702be728ae3010f33c3c671b4d9cdc2cf743d4427d79c92f303ef48be74` (GitHub asset digest) |
| 1b | Metamod:Source 1.11 (fallback) | `1.11.0-git1156` (commit `b795893c26b328a6071747affcd67497882e2b39` "Trigger build for hl2sdk-hl2dm update", 1.11-dev) | 2024-11-17 17:53 | https://mms.alliedmods.net/mmsdrop/1.11/mmsource-1.11.0-git1156-linux.tar.gz | 1,855,203 B | not published (no GitHub release for 1.11 builds) |
| 2 | SourceMod 1.12 (stable branch) | `1.12.0-git7249` (tag `1.12.0.7249`, commit `7c24bd811a65592ec059dafc107ef0b1d49a7031` "Fix (and update) GeoIP db inclusion") | 2026-08-17 01:20 | https://github.com/alliedmodders/sourcemod/releases/download/1.12.0.7249/sourcemod-1.12.0-git7249-linux.tar.gz — mirror: https://sm.alliedmods.net/smdrop/1.12/sourcemod-1.12.0-git7249-linux.tar.gz | 77,362,482 B | `6c0b1a16e6032f36ec769c09cc02d974eb035a5bdee2c51ff0296becf1bcff2c` (GitHub asset digest) |
| 3 | RIPExt (REST in Pawn) | `1.3.2` (target `main`, built against SM `1.12-dev`) | 2025-07-20 07:57 | https://github.com/ErikMinekus/sm-ripext/releases/download/1.3.2/sm-ripext-1.3.2-linux.zip | 4,740,141 B | `c3afa6173b2d5210110e139b00cfb03f04c5615f44840d83be46aa60fc497624` (GitHub asset digest) |
| 4 | SMAC (srcdslab fork) | plugin version string `0.8.8.1`; GitHub release `latest` = commit `a865c520ae3ddc9574925f7e7aabf622652570b2` (master head at pin time). Only fixed tag: `v8.7.3` (2022-11-27, commit `cea9ee3d…`) | 2026-08-18 12:48 | https://github.com/srcdslab/sm-plugin-SMAC/releases/download/latest/sm-plugin-SMAC-latest.tar.gz | 158,058 B | `0633f8917cf2380ca50efc19e57764a0400ae3d4aa20c9e1e3c86c46ed324a3a` — **valid only for the 2026-08-18 12:48 snapshot**; changes on every master push |
| 5 | Lilac (srcdslab fork) | plugin version string `1.7.11`; GitHub release `latest` = commit `d3ed6017eda3cc7991dda8a4f68b55cb88250fe0` (master head at pin time). No fixed tags at all. | 2026-08-18 12:48 | https://github.com/srcdslab/sm-plugin-lilac/releases/download/latest/sm-plugin-lilac-latest.tar.gz | 73,057 B | `9abce1501dae735c8634ecd8253353ad27c9af5c10c6d0f60d1adc90324cb51e` — **valid only for the 2026-08-18 12:48 snapshot** |
| 7 | SteamCMD (Linux) | rolling; file dated 2018-01-05 (self-updates on first run) | 2018-01-05 01:13 | https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz — Valve wiki now documents https://client-update.steamstatic.com/installer/steamcmd_linux.tar.gz (identical file, same ETag `"5a4ed14c-250e91"`) | 2,428,561 B | not published by Valve |

Item 6 (compile toolchain) is a yes/no answer, see §6 below.

---

## 1. Metamod:Source

Sources: https://www.sourcemm.net/downloads.php?branch=stable ,
https://mms.alliedmods.net/mmsdrop/1.12/ , https://mms.alliedmods.net/mmsdrop/1.11/ ,
https://api.github.com/repos/alliedmodders/metamod-source/releases/tags/1.12.0.1225

* sourcemm.net: `?branch=stable` = **1.12**, "Latest downloads for version 1.12 -
  build 1225"; `?branch=master` = 2.0 (build 1410, Source 2 era, do not use).
  Note the stable page carries the boilerplate sentence "These are unstable,
  development MM:S builds" — that is a site template quirk; the "Stable Builds" tab
  links to `?branch=stable`, which is 1.12.
* `mmsdrop/1.12/` newest Linux tarball: `mmsource-1.12.0-git1225-linux.tar.gz`
  (2026-07-22 16:47, 4.8M). Previous: git1224 (2026-04-29), git1223 (2026-04-27),
  git1221 (2026-04-12), git1219 (2025-04-18). `mmsdrop/1.12/mmsource-latest-linux`
  contains the string `mmsource-1.12.0-git1225-linux.tar.gz`.
* Build 1225 = commit `afc8233eedcd0c832b411c1da852328328db5c50` "Update
  hl2sdk-manifests" (2026-07-22T23:35:26Z). GitHub release `1.12.0.1225`
  published 2026-07-22T23:41:27Z by github-actions. Windows zip sha256
  `568ad163a8bd48d9451193fb87aae4c790870bc1102f427e693635f5bea2c1a4` (not needed).
* CS:S support in the 1.12 branch is explicit: build 1215 "Port S1 tf2/css/dods/hl2dm
  build fixes from master" (2025-02-22).
* **1.11 fallback**: newest downloadable Linux build in `mmsdrop/1.11/` is
  `mmsource-1.11.0-git1156-linux.tar.gz` (Last-Modified 2024-11-17 17:53:46 GMT,
  1,855,203 B). `mmsdrop/1.11/mmsource-latest-linux` also says git1156. The
  sourcemm.net `?branch=1.11-dev` page lists commits up to build 1163 (Feb 2025:
  "Fix Linux build", "Fix more defines for Linux") but those builds have **no
  download files** — the newest artifact really is 1156. No sha256 is published for
  1.11 (no GitHub release object exists for `1.11.0.1156` — API returns 404).

## 2. SourceMod

Sources: https://www.sourcemod.net/downloads.php?branch=stable ,
https://sm.alliedmods.net/smdrop/1.12/ ,
https://api.github.com/repos/alliedmodders/sourcemod/releases/tags/1.12.0.7249

* sourcemod.net: `?branch=stable` = **1.12**, "These are stable SourceMod builds",
  "Latest downloads for version 1.12 - build 7249". `?branch=dev` = 1.13 build 7434
  (do not use). 1.11 latest is git6970 (`smdrop/1.11/sourcemod-latest-linux`).
* `smdrop/1.12/` newest Linux tarball: `sourcemod-1.12.0-git7249-linux.tar.gz`
  (Last-Modified Mon, 17 Aug 2026 01:29:26 GMT, 77,362,482 B). Previous: git7246,
  git7245, git7239. `smdrop/1.12/sourcemod-latest-linux` says git7249.
* Build 7249 = commit `7c24bd811a65592ec059dafc107ef0b1d49a7031` "Fix (and update)
  GeoIP db inclusion" (2026-08-17T00:58:52Z; the sourcemod.net row date is
  "Sun, 16 Aug 2026 23:20:55 +0000"). GitHub release `1.12.0.7249` published
  2026-08-17T01:20:55Z. Windows zip sha256
  `76e3552c954025fcc87c196e42b6f677aea4c85a74f65fc69a08a636b6214a0d` (not needed).
* **Gamedata trap cross-check (MISSION §4.1)** — verified against the API:
  * The commit named in MISSION, `5d468dd2c0d91f28f6540f2b0614bdd21e577735`
    "Update TF2 & CSS gamedata (#2269)" (2025-02-20T01:02:24Z), is on **master
    (1.13)**. Its parent is `2382453d50b15aedda4bafc82328d9196ca899b5`.
  * The **same change on the 1.12-dev branch** is commit
    `e6e470058d900c771c0e57f33d4ec1917c5ab7ed` (2025-02-20T03:03:23Z), parent
    `fc4d88f7dbd002324a0676c8a489a3b2c627af7a`. `compare/5d468dd2...1.12-dev` reports
    "diverged", so `5d468dd2^` is not literally an ancestor of the 1.12 tarball —
    but the two files at both parents are byte-identical (sha256 prefixes
    `f3fa427e79d9ff92` for `core.games/engine.css.txt`, `696fd2f68536057d` for
    `sdkhooks.games/game.cstrike.txt`), so either parent works. Pin URLs:
    * https://raw.githubusercontent.com/alliedmodders/sourcemod/fc4d88f7dbd002324a0676c8a489a3b2c627af7a/gamedata/core.games/engine.css.txt
    * https://raw.githubusercontent.com/alliedmodders/sourcemod/fc4d88f7dbd002324a0676c8a489a3b2c627af7a/gamedata/sdkhooks.games/game.cstrike.txt
  * Confirmed on 1.12-dev today: `gamedata/core.games/engine.css.txt` → 404,
    `gamedata/sdkhooks.games/game.cstrike.txt` → 404,
    `gamedata/sdktools.games/engine.css.txt` → 200 (still ships, as MISSION says).
  * **Not covered by MISSION §4.1 (flagging, not verified on a live server):** the
    same commit also *modified* `gamedata/sdktools.games/game.cstrike.txt`,
    `gamedata/sm-cstrike.games/game.css.txt` (cstrike extension: `GiveNamedItem`,
    team-score offsets etc.) and `gamedata/sdkhooks.games/engine.ep2v.txt`, and
    1.12-dev received two follow-ups: `17a2f4bdbf` "Fix cstrike ext gamedata for css
    (#2280)" (2025-02-22) and `4250635d40` "Fix cstrike ext gamedata for css 64bit
    #2287 (#2289)" (2025-03-02). If `cstrike.ext` natives (e.g. `CS_*`) misbehave on
    v92, the pre-`e6e470058d` versions of those files are candidates for the same
    `gamedata/custom/` treatment. Whoever runs probe §5 should record which files
    actually needed pinning.

## 3. RIPExt (ErikMinekus/sm-ripext)

Sources: https://api.github.com/repos/ErikMinekus/sm-ripext/releases ,
https://raw.githubusercontent.com/ErikMinekus/sm-ripext/1.3.2/.github/workflows/ci.yml ,
https://raw.githubusercontent.com/ErikMinekus/sm-ripext/1.3.2/AMBuilder ,
https://raw.githubusercontent.com/ErikMinekus/sm-ripext/1.3.2/curl/lib/curl_config-linux.h ,
https://raw.githubusercontent.com/ErikMinekus/sm-ripext/1.3.2/PackageScript ,
forum thread (archived) https://web.archive.org/web/2024/https://forums.alliedmods.net/showthread.php?t=298024

* Latest release: **1.3.2**, published 2025-07-20T07:57:14Z (previous 1.3.1 was
  2021-08-22). Repo last push 2025-07-20. Release notes: request body size cURL
  option, JSON integers as floats, handle access-rights fix, error code when a handle
  cannot be created.
* Linux asset: `sm-ripext-1.3.2-linux.zip` (4,740,141 B), sha256
  `c3afa6173b2d5210110e139b00cfb03f04c5615f44840d83be46aa60fc497624`.
  A Windows zip exists; there is no longer a mac build.
* Built against **SourceMod `1.12-dev`** (ci.yml at tag 1.3.2:
  `sourcemod-version: [1.12-dev]`, `target-archs: x86,x86_64`, runner
  ubuntu-22.04). `smsdk_config.h`: `SMEXT_CONF_VERSION "1.3.2"`. The forum post says
  "Requires SourceMod 1.10 or later".
* Zip contents (from `PackageScript`): `addons/sourcemod/extensions/rip.ext.so`
  (x86), `addons/sourcemod/extensions/x64/rip.ext.so`,
  `addons/sourcemod/scripting/include/ripext.inc`,
  `addons/sourcemod/scripting/include/ripext/{http,json}.inc`,
  `addons/sourcemod/configs/ripext/ca-bundle.crt`.
* **Does it need libcurl/OpenSSL on the host? No.** There is no README in the repo
  (the repo has no README file; docs live in the forum thread), so this is verified
  from the build files instead: `AMBuilder` builds and statically links vendored
  `curl` (7.75.0, `CURL_STATICLIB`, `HTTP_ONLY`), `mbedtls` (2.25.0), `nghttp2`,
  `libuv`, `zlib`, `jansson`; `curl_config-linux.h` has `#define USE_MBEDTLS 1`,
  `#define USE_NGHTTP2 1`, `/* #undef USE_OPENSSL */`; link flags include
  `-static-libstdc++`/`-static-libgcc`, `-lrt`. TLS is mbedTLS, not OpenSSL, and the
  CA bundle is the shipped `configs/ripext/ca-bundle.crt`
  (`CURLOPT_CAINFO` is set to it in `httprequestcontext.cpp`). Host needs only the
  i386 runtime that srcds needs anyway.
* Operational note from the forum post: "requests are not processed during
  hibernation" — set `sv_hibernate_when_empty 0` if the auth plugin must service
  callbacks on an empty server.

## 4. SMAC (srcdslab/sm-plugin-SMAC)

Sources: https://api.github.com/repos/srcdslab/sm-plugin-SMAC/releases ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-SMAC/master/.github/workflows/ci.yml ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-SMAC/master/README.md ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-SMAC/master/addons/sourcemod/scripting/smac_wallhack.sp ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-SMAC/master/addons/sourcemod/scripting/smac.sp ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-SMAC/master/addons/sourcemod/scripting/include/smac.inc

### Releases / tags
* `latest` — rolling. Re-tagged 2026-08-18T12:48:03Z → commit
  `a865c520ae3ddc9574925f7e7aabf622652570b2` ("ci: add Dependabot config", the master
  head). Asset `sm-plugin-SMAC-latest.tar.gz` 158,058 B, sha256
  `0633f8917cf2380ca50efc19e57764a0400ae3d4aa20c9e1e3c86c46ed324a3a` at that snapshot.
* `v8.7.3` — 2022-11-27, commit `cea9ee3d7a26d12e8b64572f7b709deee123c5c9`, asset
  `sm-plugin-SMAC-v8.7.3.tar.gz` 147,232 B, no digest published. **Predates** the
  2025-02-19 `smac_cvars` fog_enable fix, the SM 1.13-warning fixes and the SM 1.12
  compiler bump — use `latest`, pinned by commit, not v8.7.3.
* Substantive commits since v8.7.3 (rest is CI/dependabot): `3ac4e2543d` 2025-02-19
  "fix(cvars): remove fog_enable check after 18.02.2025 update"; `ea15f3ec0c`
  2025-03-14 "fix(warnings): SM 1.13"; `1a3a89b55e` 2026-01-24 Traditional Chinese;
  `1891d55c95` 2026-01-29 rebuild with latest MultiColors; `27eb0885b3` 2026-03-28
  "chore(ci): bump SM to 1.12". Plugin version string in `smac.inc`:
  `SMAC_VERSION "0.8.8.1"`. README changelog top entry: 0.8.8.0 (19-02-2025), which
  says the update is mandatory after the 18.02.2025 CS:S/TF2 update "otherwise it may
  falsely ban players" (that concerns `smac_cvars`, not wallhack).

### What the release tarball contains (from `ci.yml`, not by opening the tarball)
* `addons/sourcemod/plugins/*.smx` — **compiled** with `spcomp` from
  `rumblefrog/setup-sp@v1.3.1` `version: "1.12.x"` (that action downloads the
  upstream SourceMod 1.12 package and uses its `spcomp`), with the MultiColors include
  cloned from https://github.com/srcdslab/sm-plugin-MultiColors .
* `addons/sourcemod/translations/**` (`smac.phrases.txt` + 20 languages).
* **No** gamedata (SMAC uses SDKTools/SDKHooks and `FindSendPropInfo`; no gamedata
  files exist in the repo) and **no** `configs/` — the core plugin calls
  `AutoExecConfig(true, "smac")`, so `cfg/sourcemod/smac.cfg` is generated on first
  load with every module's cvars.
* Sources are not in the tarball; get them from the repo tree
  `addons/sourcemod/scripting/`.

### Modules compiled by CI (16)
`smac` (core, required by all others), `smac_aimbot`, `smac_autotrigger`,
`smac_client`, `smac_commands`, `smac_css_antiflash`, `smac_css_antismoke`,
`smac_css_fixes`, `smac_cvars`, `smac_eyetest`, `smac_hl2dm_fixes`,
`smac_l4d2_fixes`, `smac_rcon`, `smac_speedhack`, `smac_spinhack`, `smac_wallhack`.
Not compiled (in `scripting/_unsupported/`): `smac_eac_banlist`, `smac_esea_banlist`,
`smac_immunity`. Includes: `smac.inc`, `smac_cvars.inc`, `smac_stocks.inc`,
`smac_wallhack.inc`, `smrcon.inc`.

Engine detection (`smac.sp` `AskPluginLoad2`): `GetEngineVersion() == Engine_CSS →
Game_CSS` — i.e. by SourceMod's engine enum, not by game folder. That is the
"srcdslab does engine detection correctly" property MISSION relies on.

### `smac_wallhack` cvars (exact, from `smac_wallhack.sp` `OnPluginStart`)
| cvar | default | bounds | description (verbatim) |
|---|---|---|---|
| `smac_wallhack` | `1` | 0..1 | "Enable Anti-Wallhack. This will increase your server's CPU usage." (created via `SMAC_CreateConVar`, so it lands in `cfg/sourcemod/smac.cfg`) |
| `smac_wallhack_maxtraces` | `1280` | min 1 | "Max amount of traces that can be executed in one tick." |

Behaviour worth knowing for the load test:
* On load, **only if the server has not set them itself** (`IsConVarDefault`), the
  module sets `sv_minupdaterate` and `sv_maxupdaterate` to the tickrate, and
  `sv_client_min_interp_ratio 0` / `sv_client_max_interp_ratio 1`. Our server.cfg
  sets all four (MISSION §6.2), so this does not fire; if it did, it would conflict
  with the MISSION rate policy.
* `AskPluginLoad2` refuses to load on CS:GO only; on CS:S it registers library
  `smac_wallhack` and natives `SMAC_WH_SetClientIgnore` / `SMAC_WH_GetClientIgnore`.
  Calls `RequireFeature(FeatureType_Capability, FEATURECAP_PLAYERRUNCMD_11PARAMS,
  ...)` — satisfied by any current SM 1.12 build.
* CS:S **FarESP** (radar poisoning) is enabled automatically when `g_Game == Game_CSS`
  (`FarESP_Enable()` on `Wallhack_Enable` and `OnMapStart`): hooks
  `CCSPlayerResource::m_bPlayerSpotted` via `SDKHook_ThinkPost` on the player
  resource entity, hooks the `UpdateRadar` usermessage and re-sends filtered radar
  data every `TIME_TO_TICK(2.0)` ticks, respects `mp_forcecamera`. There is no
  separate cvar for FarESP; it is part of `smac_wallhack 1`. If
  `GetPlayerResourceEntity()` returns -1 the FarESP part silently stays off — probe
  §5.3 should log-check that `FindSendPropInfo("CCSPlayerResource","m_bPlayerSpotted")`
  succeeds on v92.
* The wallhack module never bans or kicks (grep: 0 `SMAC_Ban`/`KickClient` calls) —
  it only culls `SetTransmit` and sounds. Cost is CPU per tick, bounded by
  `smac_wallhack_maxtraces`.

### Other cvars relevant to "log-only, autoban off" (MISSION §6.4)
Core (`smac.sp`): `smac_version`, `smac_welcomemsg 0`, `smac_ban_duration 0`
(minutes, 0 = permanent), `smac_log_verbose 0`, `smac_irc_mode 1`; admin cmd
`smac_status`. There is **no global "disable bans" switch** in SMAC; banning is per
module:
* `smac_aimbot_ban 0` "Number of aimbot detections before a player is banned. Minimum
  allowed is 4. (0 = Never ban)" — default already log-only.
* `smac_autotrigger_ban 0` — default log-only.
* `smac_eyetest_ban 0`, `smac_eyetest_compat 1` — default log-only.
* `smac_speedhack`, `smac_spinhack`: log-only by construction (only `SMAC_LogAction`).
* `smac_cvars`: has **no cvar of its own and no log-only mode**. It ships a
  hard-coded list of ~62 client-cvar rules (`AddCvar(...)` in `OnPluginStart`:
  53× `Action_Ban`, 11× `Action_Kick`, e.g. `sv_cheats`/`host_timescale`
  Comp_Replicated → Ban, `r_drawothermodels == 1.0` else Ban, `sourcemod_version`
  present → Kick), plus it kicks clients that fail to answer cvar queries
  (`SMAC_FailedToReply`). Rules can only be edited at runtime with
  `smac_addcvar <cvar> <comptype> <action> <value> <value2>` /
  `smac_removecvar <cvar>` (ADMFLAG_ROOT). For a log-only phase, do **not** load
  `smac_cvars.smx` (or move it to `plugins/disabled/`); re-enable after reviewing
  the list against RevEmu clients.
* `smac_client`: `smac_antispam_connect 2`, `smac_validate_auth 0` — **keep
  `smac_validate_auth 0`** on non-Steam (it kicks clients that do not Steam-auth
  within 10 s).
* `smac_commands`: `smac_antispam_cmds 20`, `smac_anticmdspam_kick 1`.
* `smac_css_fixes`: `smac_css_defusefix 1`, `smac_css_respawnfix 1`.
* Bans go through SourceBans++ if present (`SBPP_BanPlayer`), else `BanClient(...,
  BANFLAG_AUTO, ...)` — i.e. SteamID-based, which MISSION §3 says not to trust for
  identity; another reason to keep the ban cvars at 0.

## 5. Lilac (srcdslab/sm-plugin-lilac)

Sources: https://api.github.com/repos/srcdslab/sm-plugin-lilac/releases ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-lilac/master/.github/workflows/ci.yml ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-lilac/master/README.md ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-lilac/master/addons/sourcemod/scripting/lilac/lilac_config.sp ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-lilac/master/addons/sourcemod/scripting/lilac/lilac_stock.sp ,
https://raw.githubusercontent.com/srcdslab/sm-plugin-lilac/master/addons/sourcemod/scripting/lilac/lilac_globals.sp

* Only release: rolling `latest`, re-tagged 2026-08-18T12:46:33Z → commit
  `d3ed6017eda3cc7991dda8a4f68b55cb88250fe0` (master head). Asset
  `sm-plugin-lilac-latest.tar.gz` 73,057 B, sha256
  `9abce1501dae735c8634ecd8253353ad27c9af5c10c6d0f60d1adc90324cb51e` at that
  snapshot. There are **no version tags** in the repo. Plugin version string:
  `PLUGIN_VERSION "1.7.11"` (`lilac_globals.sp`); the repo `Changelog` file tops out at
  1.7.10 and `updatefile.txt` at 1.7.4 (both stale relative to the code).
* Notable recent commits: `4d6a8ba83d` 2026-04-19 "fix(convars): support float and
  expand rules list"; `348eba01ee` 2026-03-28 "chore(ci): bump SM to 1.12";
  `105188314f` 2025-06-15 "feat: rebuild cvars logic"; `8697bcb930` 2025-02-15 "Use
  SM structure, add CI"; 1.7.7 dropped CS:GO.
* Tarball contents (from `ci.yml`): `addons/sourcemod/plugins/lilac.smx` (single
  plugin, compiled by `spcomp -i include -o ../plugins/lilac.smx lilac.sp` with
  setup-sp `1.12.x`) + `addons/sourcemod/translations/**` (`lilac.phrases.txt` + 20
  languages). No configs, no gamedata. Includes vendored in the repo:
  `convar_class.inc` (kidfearless Convar class) and `lilac.inc` (forwards/natives).
  Config is auto-generated as `cfg/sourcemod/lilac_config.cfg`
  (`Convar.CreateConfig("lilac_config", "sourcemod")`; a legacy `cfg/lilac_config.cfg`
  is honoured if it already exists).
* Game detection is by **game folder** (`GetGameFolderName == "cstrike" → GAME_CSS`),
  not engine version.
* README (verbatim gist): "Non-Steam versions (IE: Cracks) ARE NOT SUPPORTED … For
  Non-Steam/Cracked version of CS:S (like v34 or v91), Angle-Cheat detections won't
  work. You can fix this by updating these ConVars: `lilac_angles 0` and
  `lilac_angles_patch 0`. These HAVE to be disabled." v92 is not mentioned (matches
  MISSION §6.4: untested).

### Lilac cvars for log-only / autoban off (exact, from `lilac_config.sp`)
All are `FCVAR_PROTECTED`. `lilac_ban_client()` in `lilac_stock.sp` returns
immediately when `lilac_ban` is 0 ("Banning has been disabled, don't forward the ban
and don't ban") and also when the per-detection cvar is in its log-only value.

| cvar | default | log-only / off value | description (abridged, verbatim where quoted) |
|---|---|---|---|
| `lilac_enable` | 1 | — | Enable Little Anti-Cheat |
| `lilac_ban` | 1 | **`0`** | "Enable banning of cheaters, set to 0 if you want to test Lilac before fully trusting it with bans." — the master switch |
| `lilac_ban_length` | 0 | — | minutes, 0 = forever |
| `lilac_log` | 1 | keep 1 | "Enable cheat logging." |
| `lilac_log_extra` | 1 | `2` for max detail | 0 off / 1 extra info on ban / 2 extra info on everything |
| `lilac_log_misc` | 0 | `1` recommended | log kicks for interp exploits, high ping, convar-response failure |
| `lilac_log_date` | `{year}/{month}/{day} {hour}:{minute}:{second}` | — | |
| `lilac_cheat_warning` | 1 | — | alert admins in chat |
| `lilac_angles` | 1 | **`-1` log-only, `0` off** (README says `0` on non-Steam CS:S) | angle cheats |
| `lilac_angles_patch` | 1 | **`0`** on non-Steam CS:S per README | patches angle cheats |
| `lilac_chatclear` | 1 | `-1` | -1 log only / 0 / 1 |
| `lilac_convar` | 1 | `-1` | invalid client convars; -1 log only |
| `lilac_nolerp` | 1 | `-1` | -1 log only |
| `lilac_bhop` | 5 | **negative = log-only** (e.g. `-5`), 0 off | 3 custom, 4 low, 5 medium, 6 high |
| `lilac_aimbot` | 5 | **`1` = log only**, 0 off | "5 or more = ban on n'th detection" |
| `lilac_aimbot_autoshoot` | 1 | — | |
| `lilac_aimlock` | 10 | **`1` = log only**, 0 off | |
| `lilac_aimlock_light` | 1 | keep 1 | "DO NOT DISABLE THIS UNLESS YOUR SERVER CAN HANDLE IT!" |
| `lilac_noisemaker` | 1 | `-1` | TF2 only |
| `lilac_backtrack_patch` | 0 | keep 0 | "0 = Disabled (Recommended setting for SMAC compatibility)" |
| `lilac_backtrack_tolerance` | 0 | — | |
| `lilac_max_ping` | 0 | keep 0 | 3-minute ban above limit |
| `lilac_max_ping_spec` | 0 | — | |
| `lilac_max_lerp` | 105 | `0` to disable kick | kicks interp exploit; **kick, not ban — unaffected by `lilac_ban`** |
| `lilac_macro` | 0 | `-1` log-only | |
| `lilac_macro_warning` | 1 | — | |
| `lilac_macro_method` | 0 | — | 0 kick / 1 ban |
| `lilac_macro_mode` | 0 | — | |
| `lilac_filter_name` | 2 | `-1` log-only, `1` kick only | 2 = ban newline names |
| `lilac_filter_chat` | 1 | — | block invalid chat chars |
| `lilac_loss_fix` | 1 | — | ignore detections under packet loss |
| `lilac_auto_update` | 0 | keep 0 | |
| `lilac_database` | "" | optional | SM database config name for detection logging (MySQL/SQLite) — could point at MariaDB |
| `lilac_sourcebans` / `lilac_materialadmin` / `lilac_sourceirc` | 1 | — | ban backends / IRC relay if present |

Log-only bundle for MISSION §6.4: `lilac_ban 0`, `lilac_log 1`, `lilac_log_extra 2`,
`lilac_log_misc 1`, `lilac_angles 0`, `lilac_angles_patch 0` (README requirement on
non-Steam CS:S), `lilac_bhop -5`, `lilac_aimbot 1`, `lilac_aimlock 1`,
`lilac_convar -1`, `lilac_nolerp -1`, `lilac_chatclear -1`, `lilac_filter_name -1`,
`lilac_max_ping 0`. Note that kick paths (`lilac_max_lerp`, `lilac_convar` query
non-response, macro kick) are not gated by `lilac_ban`; set `lilac_max_lerp 0` and
`lilac_macro 0` if kicks are unwanted during data collection.

Server commands: `lilac_ban_status`, `lilac_set_ban_length`, `lilac_get_bans_length`,
`lilac_bhop_set`, `lilac_date_list`.

## 6. Compile toolchain — do we need spcomp?

* **Both srcdslab releases ship compiled `.smx`** (see §4/§5: CI runs `spcomp` and
  packages `addons/sourcemod/plugins/*.smx` + translations). No compilation is needed
  to deploy them.
* If we do want to rebuild (e.g. to change SMAC's admin-immunity flag or bake a
  patch), the SourceMod 1.12 Linux tarball ships the compiler:
  `addons/sourcemod/scripting/spcomp` (32-bit ELF) **and**
  `addons/sourcemod/scripting/spcomp64` (64-bit ELF) plus `compile.sh` — from
  `tools/buildbot/PackageHelpers` `CopySpcomp()` (x86_64 binary is renamed
  `spcomp64`) and `PackageScript` (`helpers.CopySpcomp('addons/sourcemod/scripting')`;
  https://raw.githubusercontent.com/alliedmodders/sourcemod/1.12-dev/tools/buildbot/PackageScript ).
  Use `spcomp64` on Ubuntu 24.04 to avoid the i386 dependency; both compile identical
  bytecode. This is the same compiler the srcdslab CI uses (setup-sp fetches the
  upstream 1.12 package from smdrop / GitHub releases:
  https://raw.githubusercontent.com/rumblefrog/setup-sp/master/src/utils/constants.ts ).
* Extra includes needed to compile: SMAC needs `multicolors.inc` from
  https://github.com/srcdslab/sm-plugin-MultiColors (not in the SMAC repo; the SMAC
  repo includes `smac*.inc` and `smrcon.inc`). Lilac vendors everything it needs
  (`convar_class.inc`, `lilac.inc`); SourceBans++/MaterialAdmin/Updater includes are
  optional (`#undef REQUIRE_PLUGIN` blocks).

## 7. SteamCMD

* https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz — HTTP 200,
  `Content-Length: 2428561`, `Last-Modified: Fri, 05 Jan 2018 01:13:48 GMT`,
  `ETag: "5a4ed14c-250e91"`. Confirmed.
* https://client-update.steamstatic.com/installer/steamcmd_linux.tar.gz — the URL the
  Valve Developer Wiki (https://developer.valvesoftware.com/wiki/SteamCMD , read via
  r.jina.ai because the wiki returns 403/307 to plain fetches) currently documents;
  identical file (same length and ETag). Prefer this one; keep the akamaihd URL as
  fallback.
* https://media.steampowered.com/installer/steamcmd_linux.tar.gz also answers 200
  but is an older 2013 build (3,170,982 B); avoid.
* No checksum is published by Valve; the bootstrap self-updates on first run, so a
  pinned hash of the tarball is of limited value anyway. Ubuntu prerequisite per the
  wiki: `lib32gcc-s1` (matches MISSION §6.1).

## Pinning recommendation for the build scripts

```
MMS_URL=https://github.com/alliedmodders/metamod-source/releases/download/1.12.0.1225/mmsource-1.12.0-git1225-linux.tar.gz
MMS_SHA256=9291c702be728ae3010f33c3c671b4d9cdc2cf743d4427d79c92f303ef48be74
SM_URL=https://github.com/alliedmodders/sourcemod/releases/download/1.12.0.7249/sourcemod-1.12.0-git7249-linux.tar.gz
SM_SHA256=6c0b1a16e6032f36ec769c09cc02d974eb035a5bdee2c51ff0296becf1bcff2c
RIPEXT_URL=https://github.com/ErikMinekus/sm-ripext/releases/download/1.3.2/sm-ripext-1.3.2-linux.zip
RIPEXT_SHA256=c3afa6173b2d5210110e139b00cfb03f04c5615f44840d83be46aa60fc497624
SMAC_URL=https://github.com/srcdslab/sm-plugin-SMAC/releases/download/latest/sm-plugin-SMAC-latest.tar.gz   # rolling; snapshot commit a865c520, sha256 0633f891... on 2026-08-18
LILAC_URL=https://github.com/srcdslab/sm-plugin-lilac/releases/download/latest/sm-plugin-lilac-latest.tar.gz # rolling; snapshot commit d3ed6017, sha256 9abce150... on 2026-08-18
STEAMCMD_URL=https://client-update.steamstatic.com/installer/steamcmd_linux.tar.gz   # or steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
SM_GAMEDATA_PIN_COMMIT=fc4d88f7dbd002324a0676c8a489a3b2c627af7a   # parent of e6e470058d on 1.12-dev (== files at 5d468dd2^ on master)
```

For SMAC/Lilac, if a reproducible artifact is required, fetch the source tree at the
pinned commit (`https://github.com/srcdslab/sm-plugin-SMAC/archive/a865c520ae3ddc9574925f7e7aabf622652570b2.tar.gz`,
`https://github.com/srcdslab/sm-plugin-lilac/archive/d3ed6017eda3cc7991dda8a4f68b55cb88250fe0.tar.gz`)
and compile with the SM tarball's `spcomp64` — that is what their CI does.

## Not verified / limitations
* Tarball/zip contents for SMAC, Lilac and RIPExt were derived from their CI/package
  scripts, not by opening the archives (no downloads on the research machine).
* `mmsdrop`/`smdrop` copies are assumed identical to the GitHub release assets
  (same byte size); only the GitHub digests are authoritative.
* Whether SMAC FarESP's `m_bPlayerSpotted` prop and Lilac's detections behave on v92
  is exactly probe §5.3 / §6.4 — nothing here claims that.
