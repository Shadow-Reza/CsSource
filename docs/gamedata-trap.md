# The SourceMod gamedata trap (MISSION §4.1) — evidence, pinned files, and where overrides really go

Status: researched 2026-08-19 against the GitHub REST API / raw.githubusercontent.com
(`alliedmodders/sourcemod`). Nothing here was executed on the game server; the live
confirmation that build 7179 loads on v92 is in `docs/evidence/02-sm-interface-mismatch.txt`.
Pinned files live in `plugins/gamedata-v92/` (checksums in `plugins/gamedata-v92/SHA256SUMS`).

## TL;DR

1. MISSION §4.1 is **directionally right but operationally moot** for the build we actually run.
   SourceMod is pinned to `1.12.0-git7179` (commit `8f921d97`, 2025-02-17, D-005). The `gamedata/`
   tree of that commit is **byte-identical** (same git tree id `d11e72968e4d11d646ecbd980ad08b500e309486`)
   to the parent of the v93 commit on both branches. The tarball already ships the v92 gamedata;
   there is nothing to pin *into* it. The five files are still mirrored in `plugins/gamedata-v92/`
   so the repo is self-sufficient if AlliedModders ever prunes old builds.
2. The trap still has teeth in exactly one way: the **gamedata auto-updater**. If
   `"DisableAutoUpdate"` is not `"yes"`, build 7179 loads `updater.ext.so`, which POSTs every
   `gamedata/**` file name + md5 to `http://update.sourcemod.net/update/` and overwrites whatever
   the server sends back. Today the 1.12 gamedata on that server is the v93 set (vtable indices
   shifted +2..+7; `master.games.txt` no longer lists the CS:S files). `"DisableAutoUpdate" "yes"`
   is therefore mandatory (already in `server/opt/css/etc/templates/sm/core.cfg`). `-noupdate` on
   the srcds command line has **no effect on SourceMod** (see §7).
3. MISSION §4.1's override path `addons/sourcemod/gamedata/custom/` is **wrong for these files**.
   `core.games`, `sdkhooks.games`, `sdktools.games` and `sm-cstrike.games` are *master-based*
   gamedata sets; for those the loader reads `addons/sourcemod/gamedata/<set>/custom/*.txt`.
   `gamedata/custom/<name>.txt` is only consulted for single-file gamedata (`gamedata/<name>.txt`,
   e.g. `sm-tf2.games.txt`, `funcommands.games.txt`). Code quoted in §6.
4. MISSION §4.1 says only two files were deleted and `sdktools.games/engine.css.txt` "still ships".
   True but misleading: the same commit also (a) rewrote `sdktools.games/game.cstrike.txt` with v93
   indices, (b) removed `engine.css.txt` from `sdktools.games/master.games.txt` (so the surviving file
   is **orphaned / never loaded** by newer SM), and (c) modified `sm-cstrike.games/game.css.txt`
   (followed by two more rewrites). On Linux the only *value* change in (c) is `ClanTagOffset` 29→23.
5. Even if someone pinned every file perfectly, **no SourceMod 1.12 build newer than 7179 loads on
   v92** (`Could not find interface: ServerGameClients005`, D-005). Gamedata is the second wall, not
   the first.

## 1. The commits (GitHub REST API, 2026-08-19)

`GET https://api.github.com/repos/alliedmodders/sourcemod/commits/<sha>`

| Branch | SHA | Committer date (UTC) | Subject | Parent |
|---|---|---|---|---|
| master | `5d468dd2c0d91f28f6540f2b0614bdd21e577735` | 2025-02-20T01:02:24Z | `Update TF2 & CSS gamedata (#2269)` — body: "Gamedata update + Merge css back into orangebox / update tf2 gamedata / fix incorrect gamedata key", co-author Kenzzer | `2382453d50b15aedda4bafc82328d9196ca899b5` |
| master | `2382453d50b15aedda4bafc82328d9196ca899b5` | 2025-02-20T00:51:38Z | `Manifest updates and compilation fixes for css, tf2, dods, hl2dm (#2268)` (no gamedata files touched) | `3b9c74ce96…` |
| 1.12-dev | `e6e470058d900c771c0e57f33d4ec1917c5ab7ed` | 2025-02-20T03:03:23Z | same subject, "(cherry picked from commit 5d468dd2…)" | `fc4d88f7dbd002324a0676c8a489a3b2c627af7a` |
| 1.12-dev | `fc4d88f7dbd002324a0676c8a489a3b2c627af7a` | 2025-02-20T03:03:08Z | `Manifest updates and compilation fixes for css, tf2, dods, hl2dm (#2268)` "(cherry picked from 2382453d…)" — touches 27 source files (hl2sdk-manifests bump, `sm_platform.h`, dhooks/sdktools/bintools), **zero `gamedata/` files** (`compare/8f921d97...fc4d88f7`: ahead_by 1, gamedata files changed: none) | `8f921d971da1cacd00c0f709bea1c31f746b6aea` |
| 1.12-dev | `8f921d971da1cacd00c0f709bea1c31f746b6aea` | 2025-02-17T20:36:55Z | `Make finding the sv_lan ConVar a static operation (#2258)` — **this is build 1.12.0-git7179** (`sm version` on the live server prints "Built from: …/commit/8f921d97", evidence file 02) | `b4cb8789fa…` |

Files changed by `5d468dd2` / `e6e47005` (identical list on both branches, `files[]` from the API):

| Status | File | +/- |
|---|---|---|
| removed | `gamedata/core.games/engine.css.txt` | 0/53 |
| modified | `gamedata/core.games/master.games.txt` | 0/5 (drops the `engine.css.txt` → `"engine" "css"` entry) |
| modified | `gamedata/sdkhooks.games/engine.ep2v.txt` | 183/1 (adds a `"cstrike"` block with v93 indices) |
| removed | `gamedata/sdkhooks.games/game.cstrike.txt` | 0/153 |
| modified | `gamedata/sdkhooks.games/master.games.txt` | 0/5 (drops `game.cstrike.txt` → `"game" "cstrike"`) |
| modified | `gamedata/sdktools.games/engine.ep2valve.txt` | 0/13 (removes the `#supported dod/tf/hl2mp` guards so CS:S now gets FireOutput/SetUserInfo from here) |
| modified | `gamedata/sdktools.games/game.cstrike.txt` | 69/53 (v93 vtable indices; adds windows64/linux64; drops mac) |
| modified | `gamedata/sdktools.games/master.games.txt` | 0/5 (drops `engine.css.txt` → `"engine" "css"`; **`game.cstrike.txt` entry stays**) |
| modified | `gamedata/sm-cstrike.games/game.css.txt` | 0/15 (drops `mac` lines only) |
| modified | `gamedata/sm-tf2.games.txt` | 16/16 |

Follow-ups on `1.12-dev` that touch CS:S gamedata (from `commits?sha=1.12-dev&path=…`):

| SHA | Date | Subject | What it changed for CS:S |
|---|---|---|---|
| `4d585a0d5d7e2ca29e8b5e90f63449185323b5c2` | 2025-02-20T15:05:50Z | `Fix invalid sdkhook offsets for CSS` (cherry-pick of `1e85181f`) | in the `"cstrike"` block of `sdkhooks.games/engine.ep2v.txt`: `ShouldCollide` linux 16→18, `Spawn` windows 29→24 / linux 30→25 (6 lines) |
| `17a2f4bdbf6dc96ade99b0feda28fd7e63eac145` | 2025-02-22T13:16:10Z | `Fix cstrike ext gamedata for css (#2280)` (cherry-pick of `b71d3c01`) | `sm-cstrike.games/game.css.txt` 46/26: new Windows signatures for every function (RoundRespawn, SwitchTeam, HandleCommand_Buy_Internal, GetWeaponPrice, CSWeaponDrop, TerminateRound, GetTranslatedWeaponAlias, GetWeaponInfo, SetClanTag, AliasToWeaponID, WeaponIDToAlias, CheckWinLimit; SetModelFromClass set to "" = inlined), Windows `CTTeamScoreOffset` 18→274, `TTeamScoreOffset` 56→395 (now offsets into CCSGameRules::Think), **Linux `ClanTagOffset` 29→23**, adds windows64/linux64 `WeaponName` = 10 |
| `8185354573deb6cee23f9f52f5d2a51ea9140b38` | 2025-02-26T23:01:40Z | `Fix sdktools css gamedata (#2286)` (cherry-pick of `d5e05fae`) | `sdktools.games/game.cstrike.txt` 2/2: duplicated `"windows" "274"` under `Weapon_GetSlot` becomes `"windows64"`, adds trailing newline |
| `4250635d40113fadfebe0c43f374576db3ad8fdb` | 2025-03-02T16:13:37Z | `Fix cstrike ext gamedata for css 64bit #2287 (#2289)` (cherry-pick of `7fc48b8e`) | `sm-cstrike.games/game.css.txt` 44/9: adds windows64/linux64 everywhere (`WeaponPrice` 64-bit 2356/2352, `ClanTagOffset` 64-bit 29/8, team-score 64-bit offsets), swaps the Windows `AliasToWeaponID`/`WeaponIDToAlias` signatures back, restores a Windows `SetModelFromClass` signature, moves the `"Keys"`/`MVPs` block from a `"cstrike"` section into `"#default"`. No 32-bit Linux value changes. |
| `17ebba55d3…` | 2025-06-21 | `Fix/add LookupAttachment gamedata for cstrike/dod/hl2mp (fixes #2337)` | adds a `LookupAttachment` signature block to `sdktools.games/game.cstrike.txt` (Linux symbol `@_ZN14CBaseAnimating16LookupAttachmentEPKc` — same symbol v92's `engine.css.txt` had) |

`1.12-dev` head at research time: `7c24bd811a65592ec059dafc107ef0b1d49a7031` (2026-08-17, build 7249).
After `4250635d40`, `sm-cstrike.games/game.css.txt` is unchanged to head (blob `12b3bed8…`);
`sdktools.games/game.cstrike.txt` only gained the LookupAttachment block.

## 2. Is build 7179 exactly the parent version? Yes.

* `fc4d88f7`'s parent is `8f921d97` (API `parents[]`), and `fc4d88f7` touches no `gamedata/` path, so
  `gamedata/` at `fc4d88f7` ≡ `gamedata/` at `8f921d97` = build 7179.
* Direct proof: `GET /git/trees/<sha>:gamedata` returns **the same tree id
  `d11e72968e4d11d646ecbd980ad08b500e309486`** for `8f921d97`, `fc4d88f7` and master `2382453d`
  (= `5d468dd2^`). Same tree id ⇒ every file under `gamedata/` is byte-identical across the three.
  So "take the files from `5d468dd2^`" (MISSION) and "take the files from the 1.12 parent" and
  "use what the 7179 tarball already contains" are the same bytes.
* Per-file blob ids (identical at all three commits): `core.games/engine.css.txt` `2c92e9a4…` (1014 B),
  `sdkhooks.games/game.cstrike.txt` `59b46942…` (2008 B), `sdktools.games/engine.css.txt` `e2c4c5c1…`
  (3532 B), `sdktools.games/game.cstrike.txt` `923d16d7…` (2125 B), `sm-cstrike.games/game.css.txt`
  `773ec1f3…` (5015 B).
* Build-number mapping (from `docs/evidence/02-sm-interface-mismatch.txt`, bisect over `smdrop/1.12`):
  7179 = last build with `ServerGameClients004` (tarball Last-Modified 2025-02-17 20:50:56 GMT,
  68,894,101 B — still served, HTTP 200 on 2026-08-19); 7182 (2025-02-20) = first with
  `ServerGameClients005` and without the two deleted files. `fc4d88f7` (the SDK/manifest switch) is
  what moved the css build to the new interfaces; `e6e47005` is the gamedata change. Both landed in
  the same ~15 seconds, so **there is no 1.12 build that has the new binaries with the old gamedata
  or vice versa.**

## 3. The pinned files (`plugins/gamedata-v92/`)

Fetched from `https://raw.githubusercontent.com/alliedmodders/sourcemod/fc4d88f7dbd002324a0676c8a489a3b2c627af7a/gamedata/<path>`:

| Path | Bytes | sha256 (as stored, LF) | Upstream blob | Note |
|---|---|---|---|---|
| `core.games/engine.css.txt` | 961 | `92047c95d3c5a2a9870fbc5b1eedd57434626c6c847c3703e5116a021844f0b6` | `2c92e9a4d5ee…` | **upstream blob is CRLF** (1014 B, sha256 `f3fa427e79d9ff92ce21618c621df106136894a8dc386c1632b6f07b3981236e`); stored LF because `.gitattributes` forces `*.txt eol=lf` (git would normalise it on commit anyway). Content otherwise identical; SM's SMC parser treats `\r` as whitespace. |
| `sdkhooks.games/game.cstrike.txt` | 2008 | `696fd2f68536057dedb79c9aa14e600fac67fe0b7bd7c5c078347e4964a5d664` | `59b46942c18b…` | byte-exact |
| `sdktools.games/engine.css.txt` | 3532 | `a3900440d80166309998feb461fbc9de831695b3f7b246885c53befd45cc5500` | `e2c4c5c163c0…` | byte-exact; unchanged upstream to this day but orphaned (see §4) |
| `sdktools.games/game.cstrike.txt` | 2125 | `28be93b84100d4453afa1df4f8f05f021bf51f6c3f7f0a97e8df1b794ecb6125` | `923d16d74cdb…` | byte-exact |
| `sm-cstrike.games/game.css.txt` | 5015 | `c2fc125180cc1714c9ff6e9d9df5d631930fdf232f02c005054029106beb9e2b` | `773ec1f37efc…` | byte-exact |

(`docs/upstream-versions.md` quotes the CRLF sha256 prefix `f3fa427e79d9ff92` for the first file —
both numbers are correct, they are the CRLF and LF forms of the same text.)

## 4. What changed, file by file (v92 = parent `fc4d88f7` vs v93 = `e6e47005` vs 1.12-dev head `7c24bd81`)

### 4.1 `sdktools.games/game.cstrike.txt` — CBaseEntity/CBasePlayer vtable indices (Linux / Windows)

| Key | v92 lin | v93 lin (e6e47005 … head) | v92 win | v93 win |
|---|---|---|---|---|
| SetOwnerEntity | 18 | **19** | 17 | 18 |
| GiveNamedItem | 402 | **409** | 401 | 408 |
| RemovePlayerItem | 271 | **277** | 270 | 276 |
| Weapon_GetSlot | 269 | **275** | 268 | 274 |
| Ignite | 210 | **216** | 209 | 215 |
| Extinguish | 214 | **220** | 213 | 219 |
| Teleport | 109 | **111** | 108 | 110 |
| CommitSuicide | 440 | **447** | 440 | 447 |
| GetVelocity | 141 | **144** | 140 | 143 |
| EyeAngles | 132 | **135** | 131 | 134 |
| AcceptInput | 37 | **39** | 36 | 38 |
| SetEntityModel | 25 | **27** | 24 | 26 |
| WeaponEquip | 262 | **268** | 261 | 267 |
| Activate | 34 | **36** | 33 | 35 |
| PlayerRunCmd | 420 | **427** | 419 | 426 |
| GiveAmmo | 253 | **259** | 252 | 258 |
| GetAttachment | 206 | **212** | 205 | 211 |

Plus: `mac` lines dropped, `windows64`/`linux64` added (same numbers as 32-bit), head adds a
`Signatures/LookupAttachment` block (Linux symbol identical to v92's `engine.css.txt`). Every one of
these indices is what `GivePlayerItem`, `TeleportEntity`, `IgniteEntity`, `RemovePlayerItem`,
`EquipPlayerWeapon`, `AcceptEntityInput`, `SetEntityModel`, `GetEntityAttachment`… call through; a
+2/+6/+7 index on a v92 vtable calls a random neighbouring virtual → crash or silent corruption.
**This file is still listed in `sdktools.games/master.games.txt` at head**, so a newer SM would
load the v93 numbers for CS:S.

### 4.2 `sdkhooks.games/game.cstrike.txt` (deleted) → `"cstrike"` block in `sdkhooks.games/engine.ep2v.txt`

| Key | v92 lin | e6e47005 lin | 4d585a0d5d lin | head lin | v92 win | head win |
|---|---|---|---|---|---|---|
| Blocked | 103 | 105 | 105 | 105 | 102 | 104 |
| EndTouch | 101 | 103 | 103 | 103 | 100 | 102 |
| FireBullets | 113 | 115 | 115 | 115 | 112 | 114 |
| GetMaxHealth | 118 | 120 | 120 | 120 | 117 | 119 |
| GroundEntChanged | 179 | 182 | 182 | 182 | 177 | 180 |
| OnTakeDamage | 63 | 65 | 65 | 65 | 62 | 64 |
| OnTakeDamage_Alive | 273 | 279 | 279 | 279 | 272 | 278 |
| PreThink | 333 | 339 | 339 | 339 | 332 | 338 |
| PostThink | 334 | 340 | 340 | 340 | 333 | 339 |
| Reload | 271 | 277 | 277 | 277 | 270 | 276 |
| SetTransmit | 21 | 23 | 23 | 23 | 20 | 22 |
| ShouldCollide | 17 | 16 | 18 | 18 | 16 | 17 |
| Spawn | 23 | 30 | 25 | 25 | 22 | 24 |
| StartTouch | 99 | 101 | 101 | 101 | 98 | 100 |
| Think | 48 | 50 | 50 | 50 | 47 | 49 |
| Touch | 100 | 102 | 102 | 102 | 99 | 101 |
| TraceAttack | 61 | 63 | 63 | 63 | 60 | 62 |
| Use | 98 | 100 | 100 | 100 | 97 | 99 |
| VPhysicsUpdate | 158 | 161 | 161 | 161 | 157 | 160 |
| Weapon_CanSwitchTo | 267 | 273 | 273 | 273 | 266 | 272 |
| Weapon_CanUse | 261 | 267 | 267 | 267 | 260 | 266 |
| Weapon_Drop | 264 | 270 | 270 | 270 | 263 | 269 |
| Weapon_Equip | 262 | 268 | 268 | 268 | 261 | 267 |
| Weapon_Switch | 265 | 271 | 271 | 271 | 264 | 270 |
| EntityListeners | (absent) | 131108 | 131108 | 131108 | (absent) | 131108 |

At build 7179 the `"cstrike"` block does not exist in `engine.ep2v.txt` (that file only had
`tf`/`hl2mp`/`dods` blocks), so CS:S SDKHooks offsets came exclusively from `game.cstrike.txt`
(selected by `"game" "cstrike"` in `master.games.txt`). `SetTransmit` is what SMAC's wallhack
module hooks (MISSION §6.4) — 21 on v92, 23 on v93.

### 4.3 `sm-cstrike.games/game.css.txt` (cstrike extension)

* `e6e47005`: only removes `mac` lines. No Linux/Windows value changes.
* `17a2f4bdbf`: Windows signatures/offsets rewritten for v93 (irrelevant on Linux, where every
  signature is a symbol lookup `@_ZN…` and symbols did not change); **Linux `ClanTagOffset` 29 → 23**.
  This is an *instruction-stream* offset into `CCSPlayer::SetClanTag` from which the extension reads
  the member offset of the clan-tag string
  (`extensions/cstrike/natives.cpp` @8f921d97: `tagOffset = *(int *)((intptr_t)addr + tagOffsetOffset);`
  used by `CS_GetClientClanTag`). With 23 on a v92 binary it reads an arbitrary int out of the
  code bytes → garbage string offset. `CS_SetClientClanTag` calls the function itself (symbol) and is
  unaffected on Linux. Linux `CTTeamScoreOffset` 27 / `TTeamScoreOffset` 38 / `WeaponPrice` 2308 /
  `WeaponName` 6 / `MVPs` 69 are unchanged v92→v93.
* `4250635d40`: 64-bit columns only; restructures the `Keys`/`MVPs` block. No 32-bit Linux changes.

### 4.4 `core.games/engine.css.txt` (deleted) — harmless

Content: `gEntList` (windows offset 11 / linux symbol `@gEntList`), `EntInfo` 4, Windows
`LevelShutdown` signature, `"Keys" { "UseInvalidUniverseInSteam2IDs" "1" }`.
`core.games/engine.ep2valve.txt` (engine `orangebox_valve`, unchanged since before the v93 commit,
blob sha256 `c256342ca3aaf040…` at parent, e6e47005 and head) carries the **same Linux values and
the same `UseInvalidUniverseInSteam2IDs 1` key**. Because `CGameConfig` sets the *base engine*
`orangebox_valve` for `css` (see §6) at build 7179 too, CS:S already loaded both files; deleting the
css one changes nothing on Linux (SteamIDs keep rendering as `STEAM_0:…`).

### 4.5 `sdktools.games/engine.css.txt` — still a file, no longer loaded

Content: `GetTEName/GetTENext/TE_GetServerClass`, `sv` (linux `@sv`), `FireOutput` (linux symbol),
`LookupAttachment` (linux symbol), `SetUserCvar 58 / SetClientName 57 / InfoChanged 140`.
`e6e47005` removed its `master.games.txt` entry and removed the `#supported dod/tf/hl2mp` guards
from `engine.ep2valve.txt`, whose Linux values are identical (`sv @sv`, FireOutput symbol,
SetUserCvar 58, SetClientName 57, InfoChanged 140). Net effect on Linux: none. MISSION's "pin only
the two that were deleted" is therefore harmless advice but for the wrong reason — the file that
matters and was *not* deleted is `sdktools.games/game.cstrike.txt` (§4.1).

## 5. Which v92 files actually matter (Linux, 32-bit)

| File | Needed for v92 if running v93 gamedata? | Why |
|---|---|---|
| `sdktools.games/game.cstrike.txt` | **YES (crash-grade)** | 17 vtable indices shifted |
| `sdkhooks.games/game.cstrike.txt` | **YES (crash-grade)** | 24 vtable indices shifted (now in `engine.ep2v.txt` `"cstrike"`) |
| `sm-cstrike.games/game.css.txt` | yes (one native) | `ClanTagOffset` 29 vs 23 |
| `core.games/engine.css.txt` | no | duplicates `engine.ep2valve.txt` |
| `sdktools.games/engine.css.txt` | no | duplicates `engine.ep2valve.txt` |

## 6. Where overrides go — the loader code (`core/logic/GameConfigs.cpp` @ `8f921d97`, identical at head except two macro names)

`https://raw.githubusercontent.com/alliedmodders/sourcemod/8f921d971da1cacd00c0f709bea1c31f746b6aea/core/logic/GameConfigs.cpp`

Constructor — engine name and *base* engine (lines 170-190):

```cpp
CGameConfig::CGameConfig(const char *file, const char *engine)
{
	strncopy(m_File, file, sizeof(m_File));
	...
	if (!engine)
		m_pEngine = bridge->GetSourceEngineName();
	else
		m_pEngine = engine;

	if (strcmp(m_pEngine, "css") == 0 || strcmp(m_pEngine, "dods") == 0 || strcmp(m_pEngine, "hl2dm") == 0 || strcmp(m_pEngine, "tf2") == 0)
		this->SetBaseEngine("orangebox_valve");
	else if (strcmp(m_pEngine, "nucleardawn") == 0)
		this->SetBaseEngine("left4dead2");
	else
		this->SetBaseEngine(NULL);
}
```

`CGameConfig::Reparse` (lines 821-938), abridged only by removing blank lines and one log block:

```cpp
bool CGameConfig::Reparse(char *error, size_t maxlength)
{
	/* Reset cached data */
	m_Offsets.clear();
	m_Props.clear();
	m_Keys.clear();
	m_Addresses.clear();

	char path[PLATFORM_MAX_PATH];

	/* See if we can use the extended gamedata format. */
	g_pSM->BuildPath(Path_SM, path, sizeof(path), "gamedata/%s/master.games.txt", m_File);
	if (!libsys->PathExists(path))
	{
		/* Nope, use the old mechanism. */
		ke::SafeSprintf(path, sizeof(path), "%s.txt", m_File);
		if (!EnterFile(path, error, maxlength))
		{
			return false;
		}

		/* Allow customization. */
		g_pSM->BuildPath(Path_SM, path, sizeof(path), "gamedata/custom/%s.txt", m_File);
		if (libsys->PathExists(path))
		{
			ke::SafeSprintf(path, sizeof(path), "custom/%s.txt", m_File);
			bool success = EnterFile(path, error, maxlength);
			if (success)
			{
				rootmenu->ConsolePrint("[SM] Parsed custom gamedata override file: %s", path);
			}
			return success;
		}
		return true;
	}

	/* Otherwise, it's time to parse the master. */
	SMCError err;
	SMCStates state = {0, 0};
	List<String> fileList;
	master_reader.fileList = &fileList;
	const char *pEngine[2] = { m_pBaseEngine, m_pEngine  };

	for (unsigned char iter = 0; iter < SM_ARRAYSIZE(pEngine); ++iter)
	{
		if (pEngine[iter] == NULL)
		{
			continue;
		}

		this->SetParseEngine(pEngine[iter]);
		err = textparsers->ParseSMCFile(path, &master_reader, &state, error, maxlength);
		if (err != SMCError_Okay)
		{
			... logger->LogError("[SM] Error parsing master gameconf file \"%s\":", path); ...
			return false;
		}
	}

	/* Go through each file we found and parse it. */
	List<String>::iterator iter;
	for (iter = fileList.begin(); iter != fileList.end(); iter++)
	{
		ke::SafeSprintf(path, sizeof(path), "%s/%s", m_File, (*iter).c_str());
		if (!EnterFile(path, error, maxlength))
		{
			return false;
		}
	}

	/* Parse the contents of the 'custom' directory */
	g_pSM->BuildPath(Path_SM, path, sizeof(path), "gamedata/%s/custom", m_File);
	IDirectory *customDir = libsys->OpenDirectory(path);

	if (!customDir)
	{
		return true;
	}

	while (customDir->MoreFiles())
	{
		if (!customDir->IsEntryFile())
		{
			customDir->NextEntry();
			continue;
		}

		const char *curFile = customDir->GetEntryName();

		/* Only allow .txt files */
		int len = strlen(curFile);
		if (len > 4 && strcmp(&curFile[len-4], ".txt") != 0)
		{
			customDir->NextEntry();
			continue;
		}

		ke::SafeSprintf(path, sizeof(path), "%s/custom/%s", m_File, curFile);
		if (!EnterFile(path, error, maxlength))
		{
			libsys->CloseDirectory(customDir);
			return false;
		}

		rootmenu->ConsolePrint("[SM] Parsed custom gamedata override file: %s", path);

		customDir->NextEntry();
	}

	libsys->CloseDirectory(customDir);
	return true;
}
```

`MasterReader::ReadSMC_LeavingSection` (lines 766-800) selects a file when
`(!had_engine && !had_game) || (!had_engine && matched_game) || (!had_game && matched_engine) || (matched_engine && matched_game)`,
and the master is parsed **twice**, once with the base engine (`orangebox_valve`) and once with the
real engine (`css`); files are appended in master-file order (`fileList->find(cur_file) == end()`
dedups). So at build 7179 a CS:S server loads, in this order:

* `core.games`: `engine.ep2valve.txt` (orangebox_valve), then `engine.css.txt` (css)
* `sdkhooks.games`: `engine.ep2v.txt` (orangebox_valve; no `cstrike` block in 7179 → contributes nothing), then `game.cstrike.txt` (game cstrike)
* `sdktools.games`: `engine.ep2valve.txt`, `engine.css.txt`, `game.cstrike.txt`
* `sm-cstrike.games`: `game.css.txt` (`"game" "cstrike"`)

and finally every `*.txt` in `gamedata/<set>/custom/`. Later `m_Offsets.replace(...)` /
`m_Keys.replace(...)` calls win, so **custom files override everything selected by the master**.

**Consequences for an operator:**

* For `core.games`, `sdkhooks.games`, `sdktools.games`, `sm-cstrike.games` (all master-based — each
  has a `master.games.txt`), overrides go in
  `addons/sourcemod/gamedata/<set>/custom/<any-name>.txt`, e.g.
  `addons/sourcemod/gamedata/sdktools.games/custom/v92-game.cstrike.txt`.
  A file dropped at `addons/sourcemod/gamedata/custom/sdktools.games.txt` (MISSION's wording) is
  **never opened** for these sets — the `gamedata/custom/%s.txt` branch is only reached when
  `gamedata/<set>/master.games.txt` does not exist.
* The `#default` sections inside the pinned files apply unconditionally (no `#supported` filter),
  so a custom copy is correct only on a CS:S-only install — which this is.
* The AlliedModders wiki text MISSION paraphrased ("use the custom folder under the gamedata
  directory … never overwritten", https://wiki.alliedmods.net/Gamedata_Updating_(SourceMod)) is
  literally true only for single-file gamedata; the code above is the authority.
* None of this is needed for build 7179 (the tarball already *is* the v92 set), and no newer 1.12
  build can be loaded on v92 at all (`ServerGameClients005`, D-005). Someone who compiles their own
  SourceMod against the pre-v93 hl2sdk-css but with current gamedata would be the only consumer of
  the override recipe; `plugins/gamedata-v92/README.md` spells out the paths for that case.

## 7. The auto-updater and `core.cfg` (exact spelling from `configs/core.cfg` @ `8f921d97`)

`https://raw.githubusercontent.com/alliedmodders/sourcemod/8f921d971da1cacd00c0f709bea1c31f746b6aea/configs/core.cfg`
(file is CRLF upstream, 5116 B):

```
	/**
	 * Enables or Disables SourceMod's automatic gamedata updating.
	 *
	 * The default value is "no". A value of "yes" will block the Auto Updater.
	 */
	"DisableAutoUpdate"			"no"

	/**
	 * If set to yes, a successful gamedata update will attempt to restart SourceMod.
	 ...
	 */
	"ForceRestartAfterUpdate"	"no"

	/**
	 * URL to use for retrieving update information.
	 * SSL is not yet supported.
	 */
	"AutoUpdateURL"				"http://update.sourcemod.net/update/"
	...
	/**
	 * If set to yes, SourceMod will validate steamid auth strings with the Steam backend before giving out admin access.
	 * This can prevent malicious users from impersonating admins with stolen Steam apptickets.
	 * If Steam is down, admins will not be authenticated until Steam comes back up.
	 * This option increases the security of your server, but is still experimental.
	 */
	"SteamAuthstringValidation"	"yes"
```

Keys, exact case: **`DisableAutoUpdate`** (default `"no"`; we set `"yes"`) and
**`SteamAuthstringValidation`** (default `"yes"`; we set `"no"`, MISSION §4.3). Both are already in
`server/opt/css/etc/templates/sm/core.cfg`, which `server/provision/04-install-mm-sm.sh` installs
over the tarball's `configs/core.cfg`.

How the key is consumed (`core/sourcemod.cpp` @ `8f921d97`, lines 351-356):

```cpp
	/* If we want to autoload, do that now */
	const char *disabled = GetCoreConfigValue("DisableAutoUpdate");
	if (disabled == NULL || strcasecmp(disabled, "yes") != 0)
	{
		extsys->LoadAutoExtension("updater.ext." PLATFORM_LIB_EXT);
	}
```

i.e. anything other than `yes` (case-insensitive) loads the updater. What the updater does
(`extensions/updater/Updater.cpp` + `extension.cpp` @ `8f921d97`): walks **all** of `gamedata/`
recursively (`add_folders(form, "gamedata", …)` — including `<set>/custom/` subdirectories), POSTs
`version=1.12.0.7179` plus `file_N_name` / `file_N_md5` for every file to `AutoUpdateURL`, and then
`fopen(path, "wb")` + `fwrite`s every file the server returns under `gamedata/<name>` (it creates
folders, it never deletes). Custom files with names the update server does not know are left alone,
which is why the wiki says "never overwritten"; the stock files *will* be replaced. Whether
update.sourcemod.net keys its answer on the posted version string or just serves branch-latest was
**not tested** (I did not want to POST to it) — treat it as "would serve v93".

`-noupdate`: not a SourceMod option. `grep -i noupdate` over `core/sourcemod.cpp`,
`core/logic/common_logic.cpp`, `core/logic/CoreConfig.cpp`, `core/logic/ExtensionSys.cpp`,
`core/logic/GameConfigs.cpp`, `extensions/updater/extension.cpp`, `extensions/updater/Updater.cpp`
at `8f921d97` finds nothing. `srcds_run` documents `-autoupdate` (steamcmd game update), not
`-noupdate`; srcds ignores unknown `-flags`, so keeping it in `css-launch` is harmless, but it is
**not** what stops the gamedata updater — `DisableAutoUpdate` is. (MISSION §4.1 "and pass -noupdate"
is unverified / likely a no-op; left in place, documented here.)

## 8. Corrections to MISSION §4.1, in one place

| MISSION says | Finding |
|---|---|
| "commit 5d468dd2 (2025-02-20) … deleted core.games/engine.css.txt and sdkhooks.games/game.cstrike.txt" | Correct (master); 1.12 equivalent is `e6e47005`, parent `fc4d88f7` = build-7179 tree + 1 non-gamedata commit. |
| "shifted every vtable index (Linux GiveNamedItem 402→409, Teleport 109→111, …)" | Correct; full tables in §4.1/§4.2. |
| "Take those files from the commit's parent and place them in addons/sourcemod/gamedata/custom/" | **Wrong directory** for master-based sets; must be `gamedata/<set>/custom/*.txt` (§6). And unnecessary for build 7179. |
| "Set DisableAutoUpdate yes **and** pass -noupdate" | `DisableAutoUpdate` is the real control; `-noupdate` is not read by SourceMod (§7). |
| "sdktools.games/engine.css.txt was not deleted and still ships — pin only the two that were" | The file ships but is orphaned from `master.games.txt`; the file that *does* need v92 values and was **not** deleted is `sdktools.games/game.cstrike.txt` (17 shifted indices) — plus `ClanTagOffset` in `sm-cstrike.games/game.css.txt`. `core.games/engine.css.txt` is the one that does not matter on Linux. |
| (implicit) stock SM 1.12 + pinned gamedata = working v92 server | No: stock 1.12 ≥ 7182 cannot load (`ServerGameClients005`). The only workable path is the pinned 7179 tarball, whose gamedata is already the v92 set (D-005). |

## 9. Sources

* https://api.github.com/repos/alliedmodders/sourcemod/commits/5d468dd2c0d91f28f6540f2b0614bdd21e577735
* https://api.github.com/repos/alliedmodders/sourcemod/commits/e6e470058d900c771c0e57f33d4ec1917c5ab7ed
* https://api.github.com/repos/alliedmodders/sourcemod/commits/fc4d88f7dbd002324a0676c8a489a3b2c627af7a
* https://api.github.com/repos/alliedmodders/sourcemod/commits/8f921d971da1cacd00c0f709bea1c31f746b6aea
* https://api.github.com/repos/alliedmodders/sourcemod/commits/17a2f4bdbf6dc96ade99b0feda28fd7e63eac145
* https://api.github.com/repos/alliedmodders/sourcemod/commits/4250635d40113fadfebe0c43f374576db3ad8fdb
* https://api.github.com/repos/alliedmodders/sourcemod/commits/4d585a0d5d7e2ca29e8b5e90f63449185323b5c2
* https://api.github.com/repos/alliedmodders/sourcemod/commits/8185354573deb6cee23f9f52f5d2a51ea9140b38
* https://api.github.com/repos/alliedmodders/sourcemod/commits?sha=1.12-dev&since=2025-02-15T00:00:00Z&until=2025-03-05T00:00:00Z
* https://api.github.com/repos/alliedmodders/sourcemod/compare/8f921d97...fc4d88f7
* https://api.github.com/repos/alliedmodders/sourcemod/git/trees/8f921d971da1cacd00c0f709bea1c31f746b6aea:gamedata?recursive=1 (and the same for `fc4d88f7…`, `2382453d…`, `e6e47005…`, `7c24bd81…`)
* https://raw.githubusercontent.com/alliedmodders/sourcemod/fc4d88f7dbd002324a0676c8a489a3b2c627af7a/gamedata/{core.games/engine.css.txt,sdkhooks.games/game.cstrike.txt,sdktools.games/engine.css.txt,sdktools.games/game.cstrike.txt,sm-cstrike.games/game.css.txt,*/master.games.txt,sdkhooks.games/engine.ep2v.txt,sdktools.games/engine.ep2valve.txt,core.games/engine.ep2valve.txt} and the same paths at `e6e47005…`, `17a2f4bd…`, `81853545…`, `4250635d…`, `4d585a0d…`, `7c24bd81…`
* https://raw.githubusercontent.com/alliedmodders/sourcemod/8f921d971da1cacd00c0f709bea1c31f746b6aea/core/logic/GameConfigs.cpp
* https://raw.githubusercontent.com/alliedmodders/sourcemod/8f921d971da1cacd00c0f709bea1c31f746b6aea/core/sourcemod.cpp
* https://raw.githubusercontent.com/alliedmodders/sourcemod/8f921d971da1cacd00c0f709bea1c31f746b6aea/configs/core.cfg
* https://raw.githubusercontent.com/alliedmodders/sourcemod/8f921d971da1cacd00c0f709bea1c31f746b6aea/extensions/updater/extension.cpp and `…/extensions/updater/Updater.cpp`
* https://raw.githubusercontent.com/alliedmodders/sourcemod/8f921d971da1cacd00c0f709bea1c31f746b6aea/extensions/cstrike/natives.cpp
* https://sm.alliedmods.net/smdrop/1.12/sourcemod-1.12.0-git7179-linux.tar.gz (HEAD: 200, 68,894,101 B, Last-Modified Mon, 17 Feb 2025 20:50:56 GMT)
* https://wiki.alliedmods.net/Gamedata_Updating_(SourceMod)
* `docs/evidence/02-sm-interface-mismatch.txt` (live `sm version` → commit 8f921d97; interface bisect)
