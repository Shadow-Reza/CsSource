# Match / PUG system and gamemode plugins for CS:Source v92 — research (Task D)

Date: 2026-08-19. Scope: MISSION §6.6 (match servers) and §6.5 (DM / GunGame / AimAwp
gamemode plugins). Constraints that shape every verdict below: CS:S **v92** (build
6953255), **SourceMod pinned to 1.12.0-git7179** (D-005: newer 1.12 builds cannot load on
v92), Metamod:Source 1.12 git1225, Linux, no community engine patches.

Method note: `forums.alliedmods.net` answered every request from this machine (curl,
WebFetch, r.jina.ai, a headless and a real Chrome tab) with a Cloudflare challenge
(HTTP 403 "Just a moment..."); I did not attempt to bypass it. The threads below were
read from **Wayback Machine captures** (which worked intermittently) and from GitHub
mirrors of the source. Everything marked *unverified* is stated as such rather than
guessed.

---

## 0. TL;DR verdict

| Need | Use | Why |
|---|---|---|
| Match / mix system (§6.6) | **ZxYdzero/CS-S-Mixmod**, branch `new_syntax` (v5.3, GPL-3.0, SM 1.12 API, CS:S-only) — a maintained 2024-2026 descendant of the AlliedModders "Mix Mod" thread 162329 | Only CS:S match plugin with commits in 2025-2026; ready-up, knife round, half swap, MR12/MR15 + OT, SourceTV autorecord, stats, natives + forwards. Gaps: no pause command in v5.3 (the v4.3-based `main` branch has `sm_pause`), no log streaming — add a ~30-line bridge plugin that turns its forwards into `LogToGame()` lines for `logaddress_add`. |
| Fallback match system | NOMFPS/Warmod-css-v91 (WarMod 3.0.11 CS:S port, SM 1.10, old syntax) | Second choice only; unmaintained since 2020-12. WarMod [BFG] is CS:GO-only. CSSMatch is a 2013 C++ Valve Server Plugin (not Metamod), would need a port — rejected. |
| Deathmatch server | **CSS:DM (alliedmodders/cssdm) 2.1.6-git270**, prebuilt Linux tarball 2024-11-13; CS:S gamedata was re-patched Dec 2021 (post-v92) | It is the reference CS:S DM (extension + .smx). Fallback (pure SourcePawn): jmichelmundel/sourcemod-css-dm-jmdm (2025-11, SM 1.12 toolchain) or the LAN of DOOM modular set. |
| GunGame server | **GunGame:SM 1.2.16.0** (altexdim/sourcemod-plugin-gungame) + **one** respawn plugin (lanofdoom/counterstrikesource-respawn) — *not* CSS:DM | GunGame:SM uses netprops only (no gamedata) and does not respawn by itself; respawn authority stays a single plugin. Minimal alternative: lanofdoom/counterstrikesource-gungame (2023, new syntax). |
| Weapon restriction (AimAwp + Match) | **Weapon Restrict 4.2.0** (Drifter321/csgo-css-weapon-restrict), CS:S supported via `GetEngineVersion()==Engine_CSS`, prebuilt `.smx`, last commit 2022-04 | Per-map configs, warmup mode, natives. |
| Simple respawn | lanofdoom/counterstrikesource-respawn 1.0.0 (`CS_RespawnPlayer`, 2 cvars) | Tiny, GPL-3.0, CS:S-specific. |

**Respawn authority rule (MISSION §6.5):** exactly one plugin may respawn players per
instance. DM server: CSS:DM only (it respawns). GunGame server: GunGame:SM (does not
respawn) + lanofdoom respawn (respawns); cssdm must NOT be loaded there. AimAwp/Match:
no respawn plugin at all.

---

## 1. "Mix Mod" — AlliedModders thread 162329

- Thread title: **"[CS:S] Mix Mod (plugin) (v4.3, Updated: 29-07-2012)"**, author **iDragon**,
  first post 07-17-2011, first post last edited 12-22-2012. Read from the Wayback capture
  https://web.archive.org/web/20240609234650/https://forums.alliedmods.net/showthread.php?t=162329
  (archive view: https://web.archive.org/web/20240609025432/https://forums.alliedmods.net/archive/index.php/t-162329.html).
  Full first-post text saved to `docs/evidence/taskD-mixmod-am-thread-162329-firstpost.txt`.
- What it is: a single SourcePawn plugin (`mixmod.smx`) for **CS:S only** that runs a 5v5
  mix/PCW: `sm_start`/`sm_pcw`/`sm_stop`, `sm_live`/`sm_notlive`, MR15 with auto team swap
  after round 15 and MR3 overtime on 15-15, optional knife round (`sm_ko3`, winner vote for
  side), ready system (`sm_ready`/`sm_notready`, auto-start at 10 ready, optional random
  teams), `sm_pause` (round replayed), `sm_rr`, `sm_swapteams`/`sm_st`, password commands
  (`sm_pw`/`sm_rpw`/`sm_npw`), `sm_kickct`/`sm_kickt`, `sm_maps`, `sm_spec`, SourceTV
  `sm_record`/auto-record, MVP display, TK-damage display, mute/gag, menu `sm_mix`.
  Configs `mr15.cfg`/`prac.cfg`/`mr3.cfg` attached to the post.
- Last update: **v4.3, 29-07-2012**; last thread post 11-14-2021 (user complaint); a
  12-07-2018 post reports the stock `mixmod.smx` failing at load (`CreateMapList` /
  `ReadFileLine` invalid handle — missing map list file), so the upstream attachment is
  fragile as-is.
- Download: only as AlliedModders attachments (`attachment.php?attachmentid=107035` =
  `mixmod.sp` 151.2 KB; `107034` = older `mixmod_35.sp`) — not reachable through
  Cloudflare from here.
- **GitHub mirror / living fork: https://github.com/ZxYdzero/CS-S-Mixmod** (created
  2024-01-23, pushed 2026-05-13, GPL-3.0, 4 stars). Its header reads "Mixmod Created by
  iDragon" and reproduces the v4.3 changelog verbatim, so it is the same code line.
  - branch `main` (last commit 2024-11-10): old-syntax v4.3 + 2024 fixes by "Sparkle"
    (MR12, auto-kick unready at 10, substitutes, HUD); **still has `sm_pause`**, `sm_start`,
    `sm_pcw`, `sm_nl`, `sm_setmixscore` (56 commands).
  - branch `new_syntax` (default; v5.3; commits 2025-07 … 2026-05-13): refactored into
    modules (`mixmod/{core,teams,scoring,maps,commands,events,ready,ui,stats,api}.sp`),
    `#pragma newdecls required`, only `<sourcemod> <sdktools> <cstrike>`, netprops via
    `FindSendPropInfo` (no gamedata signatures), natives `MixMod_*` + forwards
    `MixMod_OnMixStart/OnMixEnd/OnHalfTime/OnRoundStart/OnRoundEnd/OnPlayerReady`,
    translations zh/en/ru, prebuilt `addons/sourcemod/plugins/mixmod.smx` (54 KB).
    README (Chinese) states it compiles with **0 errors / 0 warnings on SourceMod
    1.12.0.7230 and 1.13.0.7346** (source: README.md in the repo). Commands: `!ready/!r`,
    `!notready/!nr`, `!score`, `!mvp`, `!stats`, `!help`; admin `!mix`, `!mr12/!live`,
    `!prac/!warmup`, `!map`, `!rr`, `!swap`, `!record/!stop`, `!kickct/!kickt`, `!random`,
    `!ko3`, `!forceready`, `!mapvote`, `!password/!rpw/!removepassword`, `!spec`,
    `!mmute/!mgag`. Format: MR12 + one MR3 overtime (cvar `sm_mixmod_mr3_enable`),
    SourceTV autorecord, stats with ADR/clutch logic.
  - **Not present in v5.3:** `sm_pause`, `sm_pcw`, `sm_notlive` (they exist in `main`).
    Some `PrintToServer`/`LogMessage` strings are hard-coded Chinese (cosmetic; chat text
    is translated; the `MODNAME` define is "MYGO" — change it).
  - README recommends two companion AM plugins ("Team Limits" p=2699194, "Restart Empty"
    p=2646280); the code has **no** include/native dependency on them (verified by grep),
    they are optional glue. A GitHub copy of Restart Empty exists at
    https://github.com/HugoJF/restart-empty (points at AM p=2646309).
  - SM 1.12 note: compiled upstream on build 7230 (> our pinned 7179). Recompile from
    source with the 7179 `spcomp` before deploying; the source uses no natives newer than
    1.12.0.

## 2. CSSMatch

- Surviving source: Google Code export mirrors, e.g.
  https://github.com/Nicolous/cssmatch-plugin (Nicolas "Nicolous" Maingot = the author),
  https://github.com/google-code-export/cssmatch-plugin, plus forks (xpz, basert, knobik,
  miguelmig, griha41, gamenew09). Last upstream commit **2013-11-18** ("Abandon de
  threading::Event …", by nicolas.maingot@gmail.com). Version **2.2.5**
  (`misc/common.h`: `CSSMATCH_PLUGIN_PRINT_BASE "2.2.5"`). License GPL-3.0 with a Source
  SDK linking exception (Makefile header). English wiki export:
  https://github.com/mathiaseklund/cssmatch-plugin-en (only redirect stubs to cssmatch.com).
- cssmatch.com is now a parked domain (redirects to `/lander`); cssmatch.sourceforge.net and
  sourceforge.net/projects/cssmatch return 403/Cloudflare from here (unverified whether
  the SF project still has files).
- **It is NOT a Metamod:Source plugin.** It is a **Valve Server Plugin** (VSP):
  `plugin/ServerPlugin.cpp` implements `IServerPluginCallbacks`
  (`#include "engine/iserverplugin.h"`, `EXPOSE_SINGLE_INTERFACE_GLOBALVAR`), loaded via
  `addons/cssmatch.vdf` (`"file" "addons/cssmatch"`). Built with a hand-written Makefile
  against `../hl2sdk-ob` (`-m32 -march=pentium`), with TinyXML++ (`ticpp/`) and its own
  `convars/convar.h`. Interfaces requested: `INTERFACEVERSION_VENGINESERVER`,
  `INTERFACEVERSION_SERVERGAMEDLL`, PlayerInfoManager002, GAMEEVENTSMANAGER002,
  ISERVERPLUGINHELPERS001, IEngineSoundServer, VSERVERTOOLS, VFileSystem — whatever the
  2013 OB headers defined (commented-out code in `ServerPlugin.cpp` shows it was tuned to
  `VEngineServer021` / `ServerGameDLL008`).
- Would it build/run against CS:S v92? The v92-era SDK is the pre-2025 `css` branch of
  alliedmodders/hl2sdk (commit 514eb48f9b, 2015-09-19: `VEngineServer023`,
  `ServerGameDLL010`, `ServerGameClients004` — matches D-005's observation that v92 exports
  ServerGameDLL010/ServerGameClients004; the current tip of that branch was bumped on
  2025-02-19 to ServerGameDLL012/ServerGameClients005 for v93 and must NOT be used). A
  rebuild would mean: new build system against hl2sdk-css@514eb48f9b, fixing whatever
  changed in `IServerGameDLL`/`IVEngineServer` since OB, and validating a 12-year-old
  code base with no tests. **Unverified** whether the last 2013 binary loads on v92 (the
  engine still exports older `VEngineServer0xx` names, but the game DLL interface is the
  risk). Features for the record: MR12/MR15 configs, knife round, warmup, two halves,
  timeouts, SourceTV records, XML match reports, admin list, 8 languages.
- Verdict: **reject** — wrong plugin type for our stack, dead upstream, porting cost
  exceeds writing the missing pieces in SourcePawn.

## 3. WarMod family

- **WarMod [BFG]** by Versatile_BFG — AM thread t=225474 (title in the Wayback capture
  of 2022-09-04: "[CS:GO] WarMod [BFG] <20.06.24.1348, 24-Jun-2020>"; later titles show
  22.09.26.1915). First post: "This is an updated version of the Game Tech WarMod by
  Twelve-60 … It has been coded up from his old CS:S source code on github … Warmod will
  require Sourcemod v1.10+ to compile". GitHub: https://github.com/Versatile-BFG/Warmod_BFG
  (GPL-3.0; commits 2022-08-29 … **2022-11-06**, `WM_VERSION "22.11.06.1146"`; also
  `warmod_livewire.sp`; prebuilt `plugins/warmod.smx`). Features: ready system, auto
  live-on-3, knife round, half switch, overtime, play-out, veto (bo2/bo3/bo5), GOTV
  autorecord, JSON event log (`LogEvent(... "live_on_3" ...)`), MySQL results, round
  restore/backup, admin menu; includes `updater`, `tEasyFTP`, `bzip2`, `zip` (optional).
  **CS:S support: none.** The code is CS:GO-only: `FindConVar("mp_overtime_enable")`,
  `mp_warmup_end`, `mp_halftime_pausetimer`, `mp_backup_round_file_pattern`, workshop IDs,
  CS:GO weapon list (`m4a1_silencer`, `taser` …). `HookConVarChange(mp_halftime_duration,…)`
  on a null handle would error on CS:S. Compiles on SM 1.10/1.11 per commit messages
  ("Updated to SM 1.11", "Recompiled … to SM1.10"); SM 1.12 compile *unverified* but
  likely. Verdict: **not usable for CS:S**.
- **Original GameTech WarMod (CS:S)** by Twelve-60 — AM thread t=60952 ("GameTech WarMod",
  "designed solely for competitive CS:GO & CS:S matches"; Wayback capture 2023-05-22;
  first post last edited 10-13-2012). GitHub: https://github.com/GameTech/WarMod
  (last commit **2012-09-10**, v**3.1.10** in `include/warmod.inc`, no license file).
  Features: ready-up, auto LO3, knife-on-3 (`/knife`,`/ko3`), auto swap at half,
  overtime (maxrounds / sudden death), play-out, SourceTV autorecord, MySQL upload,
  enhanced UDP logs, forwards (`OnLO3`, `OnHalfTime`, …), damage report, "LiveWire" TCP
  event stream. **No pause command.** Hard requirements of that era: `socket` and
  `steamtools` extensions (SteamTools is dead), old syntax (`new String:`), SM 1.4-era.
- **NOMFPS/Warmod-css-v91** — https://github.com/NOMFPS/Warmod-css-v91 ("Warmod for css
  v91+", created 2020-11-30, last commit **2020-12-01**, 5 stars, no license): a port of
  WarMod **3.0.11** "for Sourcemod v-1.10.0" that *removes* the socket/steamtools/autoupdate
  dependencies and LiveWire, adds an in-game scoreboard update; ships `warmod.smx`,
  `warmod.sp` (5174 lines, old syntax), translations and the full `cfg/warmod/*` rulesets
  (mr9/mr12/mr15, ko3/lo3 configs). 43 registered commands incl. `readyup`, `knife`,
  `lo3`, `swap`, `notlive`, `forcestart`, `forceend`; cvars `wm_auto_swap`, `wm_overtime`,
  `wm_auto_record`, `wm_upload_results`, `wm_play_out`, … . No pause. Author's own note:
  "i made this little port in one day". SM 1.12 compile: *unverified*; old syntax is
  still accepted by the 1.12 compiler with warnings, but nobody has built this against
  1.12. Verdict: **viable fallback**, not first choice.

## 4. Other candidates searched

- GitHub repo searches (API): `pug+sourcemod` → 11 results, all CS:GO/TF2/Neotokyo;
  `pugsetup` ports → CS:GO only (splewis/csgo-pug-setup and forks); `mix+sourcemod` → TF2
  mixes, no CS:S; `cssmix|mixmod|csspug|matchmod|pugsetup` → the only CS:S hit is
  **ZxYdzero/CS-S-Mixmod** (above). `sourcemod match cstrike` → one CS:S item,
  https://github.com/Ayrton09/umbrella_soccer (CS:S *soccer* match control, not CS).
  "sm_pug", "PugSetup for CSS", "MatchMod", "CSS PUG": nothing found for CS:S.
- **srcdslab org**: all **293** repositories enumerated on 2026-08-19
  (`docs/evidence/taskD-srcdslab-repos-2026-08-19.txt`); grep for
  match/pug/mix/war/scrim/competitive/ready/knife/deathmatch/gungame/respawn/restrict
  returns only KnifeMode, KnockbackRestrict(+discord, kbans-web), TeamManager ("Warmup
  round and manage player teams"), WeaponCleaner, BotManager, ShowDamage, HideKnife,
  CancelKnife, QuickSwitch, ServerCommandFilter, AlwaysWeaponSkins, FixBumpWeapon,
  NextmapVoteDisabler. **MISSION §6.6 is confirmed: srcdslab has no match repo.**
  Repos of theirs that are relevant anyway: `sm-ext-cssfixes` ("Patch CS:S bugs"),
  `sm-ext-a2sqcache`, `sm-plugin-WeaponCleaner` (DM weapon cleanup),
  `sm-plugin-TeamManager`.
- Conclusion for §6.6: the spec's claim "no maintained match system for CS:S" is
  **wrong in one respect** — CS-S-Mixmod is maintained (2026-05-13) — and right about
  everything else (get5/MatchZy/pugsetup/WarMod[BFG] are CS:GO/CS2, CSSMatch is dead).

## 5. Gamemode plugins

### 5.1 Deathmatch — CSS:DM (BAILOPAN)
- Repo: https://github.com/alliedmodders/cssdm ("Counter-Strike:Source Deathmatch";
  GitHub shows license "Other"/NOASSERTION; credits.txt: (C) 2004-2007 David "BAILOPAN"
  Anderson and AlliedModders LLC). It is a **C++ SourceMod extension**
  (`cssdm.ext.2.css.so`, AMBuild against `hl2sdk-css`, MM:S 1.10, SM 1.10) plus SourcePawn
  plugins (`scripting/`) and gamedata (`gamedata/cssdm.games.txt`, sections `csgo` and
  `cstrike`).
- Version `CSSDM_FULL_VERSION "2.1.5"+build` in `cssdm_version.h`; the site calls the
  release 2.1.4 and snapshots are named 2.1.6-gitNNN. Last commits: **2024-11-13** (merge
  of PR #17 "Update CS:S FFA TakeDmgPatch1 offset + patch", authored 2021-12-29 — i.e.
  *after* the July-2021 v92 update, so the CS:S FFA byte-patch offsets were fixed for the
  v92 binary), 2019-12-29 (SM 1.10 build), earlier CS:GO gamedata churn. The `cstrike`
  gamedata block uses Linux symbol names (`@_Z11UTIL_RemoveP11CBaseEntity`,
  `@_ZN9CCSPlayer12RoundRespawnEv`, `@_ZN9CCSPlayer12OnTakeDamageERK15CTakeDamageInfo`)
  plus vtable offsets (RemoveAllItems 343, GiveAmmo 253, Weapon_GetSlot 269 on Linux)
  that belong to the pre-v93 layout — correct for v92, **not** for v93 (same trap as
  MISSION §4.1, moot for us).
- Prebuilt: http://www.bailopan.net/cssdm/ (download page links the snapshot dir)
  → https://www.bailopan.net/cssdm/snapshots/2.1/ → newest
  `cssdm-2.1.6-git270-linux.tar.gz` (2024-11-13 13:19, 368 KB); previous
  `cssdm-2.1.6-git268-linux.tar.gz` (2019-12-29). Site news: "CS:S DM now requires
  Metamod:Source 1.8.7 and SourceMod 1.3.8" (2011 text; the git270 build was made with SM
  1.10 headers).
- Compatibility with SM 1.12.0-git7179: the extension was compiled against the SM 1.10
  SDK. SourceMod keeps binary compatibility for extensions across 1.x minor versions (1.10
  extensions normally load on 1.11/1.12), but **this specific load is unverified** — test
  `sm exts list` on the DM instance first; if it refuses, rebuild from source against
  SM 1.12 + hl2sdk-css@514eb48f9b (AMBuild-1 style `AMBuildScript`).
- Features: respawn (`cssdm_enable`, spawn protection), weapon equip menus
  (`cssdm.equip.txt`), spawn points per map (`cfg/cssdm/spawns/`), FFA mode (byte patches),
  bot balance, strip/remove drops, translations incl. RU/UA. **It is the respawn authority
  on the DM server.**
- Fallbacks (pure SourcePawn, no extension):
  - https://github.com/jmichelmundel/sourcemod-css-dm-jmdm — "CSS FFA DeathMatch
    (sm_jmdm)", single 1913-line `sm_jmdm.sp`, new syntax, uses `CS_RespawnPlayer`,
    `mp_ignore_round_win_conditions`, spawn presets per map, spawn protection, weapon
    cleaner, single-team FFA or CT-vs-T modes; bundles the SM **1.12** compiler
    (`compilador/include/version_auto.inc`: `SOURCEMOD_V_MINOR 12`, cset ff8e0fa8);
    one commit, **2025-11-26**; no license file (README in Portuguese).
  - LAN of DOOM modular set (all GPL-3.0, new syntax, compiled in CI with SM 1.10.0-git6502,
    last commits 2023-12-11): `counterstrikesource-respawn`, `-spawn-protection`,
    `-free-for-all` (FFA damage+scoring), `-ffa-spawns`, `-remove-objectives`,
    `-disable-buyzones`, `-disable-round-timer`, `-max-cash`, `-disable-radar`,
    `-paintball`, `-map-settings` — https://github.com/lanofdoom .

### 5.2 GunGame — GunGame:SM
- Repo: https://github.com/altexdim/sourcemod-plugin-gungame ("GunGame plugin for
  sourcemod", README points to AM thread t=93977). Version **1.2.16.0**
  (`include/gungame_const.inc`), authors "teame06-hat, Liam, Otstrel.ru Team". Last code
  commits 2015-12-22 ("Added revolver" — CS:GO), 2016-11-25 (translation), 2017-01-26
  ("fix urls"). No LICENSE file in the tree (*license unverified*; the AM thread is the
  only place it would be stated).
- CS:S support: yes — `cfg/gungame/css/` config set (`gungame.config.txt`,
  `gungame.equip.txt`, `weaponinfo.txt`, warmup/mapvote cfgs) separate from `csgo/`;
  gameplay hooks are netprop-based (`FindSendPropInfo("CBasePlayer","m_iAmmo")`,
  `m_hMyWeapons`, `m_iAccount`, `m_ArmorValue`, `m_bHasHelmet` …) — **no gamedata
  signatures**, so v92 vtable shifts are irrelevant.
- Prebuilt `.smx` in `addons/sourcemod/plugins/` (gungame.smx + gungame_afk/_bot/_config/
  _display_winner/_logging/_mapvoting/_stats/_tk/_warmup_configs/_winner_effects). Old
  syntax (`public Plugin:myinfo`, `decl String:`), bundled `colors.inc`/`langutils.inc`.
  SM 1.12 compile: the 1.12 compiler still accepts transitional syntax (deprecation
  warnings); **not compiled by me — verify on the build box**. The shipped .smx files
  were built years ago with an older spcomp; they should still load on SM 1.12 (SM keeps
  .smx backward compatibility) — also *verify*.
- **Respawn:** GunGame:SM itself never respawns (no `CS_RespawnPlayer` in its sources;
  `doc/README.txt` tells users to add "sm_ggdm" DeathMatch:SM, AM t=103242, or CSS:DM
  with config key `"FFA"`). Therefore on the GG server load **one** respawn plugin
  (lanofdoom respawn below) and **not** cssdm; set GunGame `RemoveObjectives 3`,
  `WarmupEnabled`, `WorldspawnSuicide` etc. in `cfg/gungame/css/gungame.config.txt`.
- Minimal alternative: https://github.com/lanofdoom/counterstrikesource-gungame
  (GPL-3.0, 658-line new-syntax plugin, 25-weapon ladder hard-coded, CI-built with SM
  1.10.0-git6502, last commit 2023-12-11, no respawn either).

### 5.3 Weapon restriction — Weapon Restrict by Dr!fter
- Repo: https://github.com/Drifter321/csgo-css-weapon-restrict (old URL
  Drifter321/Weapon-Restrict redirects there). AM thread: "[CSS/CS:GO] Weapon Restrict"
  https://forums.alliedmods.net/showthread.php?t=105219 (not fetched; title from search
  engine results). Version **4.2.0** (`#define PLUGIN_VERSION "4.2.0"`), last commits
  **2022-04-27** ("Update for SM1.11 and add new items by parsing items_game.txt",
  translations). No LICENSE file (*license unverified*).
- CS:S support: explicit — `AskPluginLoad2` fails unless `GetEngineVersion()` is
  `Engine_CSGO` or `Engine_CSS`; the items_game.txt parsing is CS:GO-only
  (`include/cstrike_weapons.inc` line ~220), CS:S uses the built-in weapon table.
  Needs `sdkhooks`, `cstrike`, optional `adminmenu`. Features: `sm_restrict`/`sm_unrestrict`,
  per-team limits, weapon groups, per-map configs (`CONFIGLOADER`), warmup mode, per-player
  restrictions, natives/forwards for other plugins (`include/restrict.inc`).
- Prebuilt `compiled/weapon_restrict.smx` (built for SM 1.11). SM 1.12: new syntax,
  nothing version-specific — expected to compile unchanged (*not compiled by me*).
- For AimAwp: restrict everything but `awp`/pistols/knife via a per-map config; for the
  Match servers: use it only for knife-round enforcement if Mixmod's own stripping is not
  enough (Mixmod already strips to knife in `!ko3`).

### 5.4 Simple respawn
- https://github.com/lanofdoom/counterstrikesource-respawn — "Player Respawn" 1.0.0,
  GPL-3.0, last commit 2023-12-11, cvars `sm_lanofdoom_respawn_enabled`,
  `sm_lanofdoom_respawn_time` (default 2.0 s); uses `CS_RespawnPlayer()` (the `cstrike`
  extension native — its `RoundRespawn` gamedata in our pinned SM 7179 is the pre-v93 set,
  correct for v92). Handles round-end/first-spawn edge cases. CI-built with SM
  1.10.0-git6502; trivially recompiles on 1.12 (new syntax, two includes).

## 6. Classic AWP / aim maps for CS:S

Verified through the GameBanana API on 2026-08-19 — URLs only, nothing downloaded.

| Map | URL | File (size) |
|---|---|---|
| awp_india | https://gamebanana.com/mods/118646 | awp_india_1108333021.zip (1.15 MB) |
| awp_india_v2 | https://gamebanana.com/mods/118656 | awp_india_v2.zip (1.38 MB) |
| awp_map | https://gamebanana.com/mods/118855 | "awp_map cs source.zip" (411 KB) |
| awp_lego / awp_lego_final | https://gamebanana.com/mods/118722 , https://gamebanana.com/mods/118793 | (not inspected) |
| aim_map | https://gamebanana.com/mods/107959 | aim_map_4.rar (415 KB) |
| aim_ag_texture2 | https://gamebanana.com/mods/105436 | aim_ag_texture2.zip (894 KB) |
| aim_headshot | https://gamebanana.com/mods/107570 (also 107571) | (not inspected) |
| aim_ak-colt_* | https://gamebanana.com/mods/105853 (battle), /105872 (indoors), /105898 (war) | (not inspected) |
| fy_pool_day (2022 remake, large) | https://gamebanana.com/mods/362403 | fy_pool_day_b618c.rar (70.3 MB) |
| fy_pool_day_reloaded | https://gamebanana.com/mods/113912 | fy_pool_day_reloaded.zip (2.9 MB) |
| fy_iceworld | https://gamebanana.com/mods/112832 | fy_iceworld_1100241015.zip (1.68 MB) |
| CS:S "AWP" map category | https://gamebanana.com/mods/cats/8246 | — |

Licensing: GameBanana uploads are user-submitted with no uniform license; fine for a
closed private network, but do not redistribute outside FastDL. Prefer the small classic
versions (the 70 MB fy_pool_day would hurt FastDL at `limit_rate 1500k`).

## 7. Recommended build for the two Match servers (§6.6)

1. Deploy **CS-S-Mixmod `new_syntax`** recompiled with SM 1.12.0-git7179's `spcomp`
   (`-i addons/sourcemod/scripting/include`). Rename `MODNAME`; keep SM's server language
   English (`ServerLang` in `core.cfg`) so the `en` phrases are used for non-localised
   clients. Ship `cfg/mr12.cfg`, `cfg/prac.cfg`, `cfg/mr3.cfg` from the repo, adapted to our
   100-tick rate settings.
2. Add the missing **pause**: port `sm_pause` from the `main` branch (saves weapons,
   money, armour and replays the round), or implement the CS:S-native way
   (`sv_pausable 1` + server `pause`, with a timer-based auto-unpause and per-team budget).
   Decide at implementation time; the `main`-branch logic is ~150 lines.
3. Add a **log bridge** plugin (new file, ~30 lines): hook `MixMod_OnMixStart`,
   `MixMod_OnRoundEnd`, `MixMod_OnHalfTime`, `MixMod_OnMixEnd` and emit
   `LogToGame("chogan_match: event=... map=... t=... ct=...")`. Those lines leave the box
   through the normal `logaddress_add <collector>` UDP log stream (MISSION §6.6 "stream
   results out via logaddress_add"), no HTTP from inside the plugin.
4. Weapon Restrict only if needed for knife-round enforcement (Mixmod already strips);
   Stripper:Source is **not** needed (Mixmod has `sm_mixmod_remove_props`).
5. If Mixmod turns out unusable on the box, fall back to NOMFPS/Warmod-css-v91 and, as a
   last resort, write the minimal plugin the MISSION describes (ready-up, knife, swap,
   score, pause) — the CS-S-Mixmod modules are a good reference for the CS:S-specific
   parts (money/armour netprops, `mp_restartgame` handling, team swap without slaying).

## 8. Open items / what I could not verify
- AlliedModders attachments (original `mixmod.sp` 107035, `warmod.inc` etc.) were not
  fetched (Cloudflare). The GitHub copies above are the working sources.
- None of the plugins was compiled or loaded by me (no downloads/execution on this
  Windows machine by rule). Every "compiles on SM 1.12" statement above is either from
  the upstream README (CS-S-Mixmod: 1.12.0.7230) or an expectation to be verified on the
  Linux build box.
- CSS:DM git270 extension loading on SM 1.12 (built against SM 1.10) — test first.
- Licenses missing upstream: GunGame:SM, Weapon Restrict, NOMFPS port, jmdm, GameTech
  WarMod (BFG, CS-S-Mixmod, CSSMatch and LAN of DOOM are GPL-3.0).
