# gamedata-v92 — SourceMod gamedata pinned for Counter-Strike: Source v92 (build 6953255)

These five files are the CS:S gamedata **exactly as shipped in SourceMod 1.12.0-git7179**
(the build pinned in `docs/decisions.md` D-005), taken from upstream commit
`fc4d88f7dbd002324a0676c8a489a3b2c627af7a` on `1.12-dev` — the last commit before the
v93 gamedata update (`e6e470058d`, the 1.12 cherry-pick of master `5d468dd2`). Full
evidence, diffs and the loader-path analysis are in `docs/gamedata-trap.md`.
Checksums and upstream blob ids: `SHA256SUMS`.

| File | Status upstream after 2025-02-20 | Relevance on v92 (Linux) |
|---|---|---|
| `core.games/engine.css.txt` | deleted | values identical to `core.games/engine.ep2valve.txt` (which build 7179 also loads for CS:S) — harmless either way |
| `sdkhooks.games/game.cstrike.txt` | deleted; replaced by a `"cstrike"` block in `sdkhooks.games/engine.ep2v.txt` with **v93 vtable indices** (+2..+6) | all SDKHooks hooks (OnTakeDamage, SetTransmit, Spawn, Weapon_*, ...) |
| `sdktools.games/engine.css.txt` | file still exists but is **no longer referenced** by `sdktools.games/master.games.txt` (orphaned) | `sv`, FireOutput, LookupAttachment, SetUserCvar/SetClientName/InfoChanged |
| `sdktools.games/game.cstrike.txt` | rewritten with **v93 vtable indices** (GiveNamedItem 402→409, Teleport 109→111, ...) | GivePlayerItem, TeleportEntity, IgniteEntity, RemovePlayerItem, EquipPlayerWeapon, ... |
| `sm-cstrike.games/game.css.txt` | rewritten 3 times (e6e47005, 17a2f4bdbf, 4250635d40); on Linux only `ClanTagOffset` 29→23 actually changes | cstrike extension: CS_GetClientClanTag |

## How to use

* **With the pinned build 7179 (what the provisioning scripts install): nothing to install.**
  The tarball `sourcemod-1.12.0-git7179-linux.tar.gz` already contains these exact files.
  Verify after install:

  ```sh
  cd /opt/css/base/cstrike/addons/sourcemod/gamedata
  sha256sum core.games/engine.css.txt sdkhooks.games/game.cstrike.txt sdktools.games/engine.css.txt \
            sdktools.games/game.cstrike.txt sm-cstrike.games/game.css.txt
  # expected values (LF form; core.games/engine.css.txt may instead hash to f3fa427e... if the tarball kept CRLF): see SHA256SUMS
  ```

  Keep `"DisableAutoUpdate" "yes"` in `configs/core.cfg` so `updater.ext.so` is never loaded
  (it would otherwise POST every gamedata file's md5 to update.sourcemod.net and overwrite
  the ones that differ with the current 1.12 = v93 content).

* **If a future operator ever runs a SourceMod that still loads on v92 but ships v93 gamedata**
  (today no such build exists: every 1.12 build >= 7182 requires ServerGameClients005 and fails
  to load on v92 at all — D-005), the override location for these *master-based* gamedata sets is
  `addons/sourcemod/gamedata/<set>/custom/<anything>.txt`, **not** `gamedata/custom/<set>.txt`:

  ```
  addons/sourcemod/gamedata/sdkhooks.games/custom/v92-game.cstrike.txt   <- copy of sdkhooks.games/game.cstrike.txt
  addons/sourcemod/gamedata/sdktools.games/custom/v92-game.cstrike.txt   <- copy of sdktools.games/game.cstrike.txt
  addons/sourcemod/gamedata/sdktools.games/custom/v92-engine.css.txt     <- copy of sdktools.games/engine.css.txt
  addons/sourcemod/gamedata/sm-cstrike.games/custom/v92-game.css.txt     <- copy of sm-cstrike.games/game.css.txt
  addons/sourcemod/gamedata/core.games/custom/v92-engine.css.txt         <- copy of core.games/engine.css.txt (optional, values already equal)
  ```

  Files in `<set>/custom/` are parsed after every file selected by `<set>/master.games.txt`, so
  their values win (`CGameConfig::Reparse`, quoted in `docs/gamedata-trap.md`). Only `*.txt` names
  are read. Since the `#default` sections in these files apply to every game, do this only on a
  CS:S-only install.
