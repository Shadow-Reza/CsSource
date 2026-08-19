# RevEmu (bir3yk) for the CS:Source v92 dedicated server — research notes

Written 2026-08-19 for MISSION §3 ("RevEmu (bir3yk fork) for non-Steam auth, with a
June 2021 or newer `steamclient.so` renamed to `steamclient_valve.so`") and §4.2
(the "segfault after `Loaded local 'steamclient.so' OK`" trap). Nothing here was run
on the server; everything below is read from primary sources (bir3yk's own forum,
mirrors, engine source, public reverse-engineering repos) and each claim carries its
URL. Where a thing could **not** be verified it is marked **UNVERIFIED**.

Short version for the orchestrator:

* RevEmu is a **closed-source, protector-packed, single-author (bir3yk) binary**. The
  Linux server part is one file, `steamclient.so` (32-bit for our srcds), which you
  drop into `bin/` after renaming Valve's original `bin/steamclient.so` to
  `bin/steamclient_valve.so`, plus a text config `rev.ini` in the server root. There is
  no GitHub repo for it; the canonical download is a pinned thread on `bir3yk.net`
  (mirrored by hl2go.com and se7en.ws) — §1.
* The MISSION's "13 June 2021 `steamclient.so`" is the **RevEmu** build date
  (13-06-2021, re-issued 03-07-2021), *not* the Valve file. The Valve file to rename
  is the one that came with the v92 server install (`bin/steamclient.so`,
  29 505 411 bytes on our box). The v92 segfault was an old (2019) RevEmu
  `steamclient.so` against the 02.07.2021 build — §3, §6.
* The current RevEmu client ticket is **not reproducible** by a test client: since
  2019-08-16 the client obtains it from bir3yk's backend using the HDD serial, the
  client binary is Themida-packed, and the server can verify tickets against the same
  backend (`Check_Ticket`). Only the *legacy* 2013-format ticket is public — §4.
* Steam and non-Steam clients coexist by design: RevEmu wraps the real
  `steamclient_valve.so` and passes genuine Steam tickets through — §5.
* There is a credible **open-source alternative** in the ecosystem the MISSION already
  chose: `srcdslab/sm-ext-connect` (plus the BotoX/CSSZombieEscape fork with
  `sv_nosteam`) lets a SourceMod plugin accept any client and keep its SteamID
  untrusted — exactly the MISSION's identity model — with no third-party backend — §7.

---

## 1. What "bir3yk RevEmu" is and where it lives

**Author / home.** RevEmu for Source-engine games is maintained by the user `bir3yk`
on his own site `bir3yk.net` (forum section "RevEmu", sub-forums "Главные новости и
события" = release news, "RevEmu для Windows", "RevEmu для Linux", "Вопросы и проблемы
с RevEmu"). Forum index with sub-forum ids: <https://bir3yk.net/forum/>
(forum_15 RevEmu, forum_16 news, forum_17 Windows, forum_18 Linux, forum_19 Q&A).
Secondary description (mirror page, English): "The RevEmu emulator allows you to run
games without a Steam client, provides game servers with SteamID verification and
blocks various cheating software" —
<https://se7en.ws/download-revemu-bir3yk-latest-version/?lang=en>.

**There is no source code and no GitHub repository for bir3yk's RevEmu.** GitHub
search for `revemu` (API, 2026-08-19) returns only unrelated projects, reverse
engineering by `kohtep`, and two binary re-uploads:
* `kohtep/revLoader` — "Result of the reverse engineering of the revLoader.exe
  launcher, which used to activate the RevEmu emulator in some No-Steam games"
  (client-side loader only): <https://github.com/kohtep/revLoader>
* `kohtep/MultiEmulator` — GoldSrc ticket generators incl. `RevEmu2013.h`
  (see §4): <https://github.com/kohtep/MultiEmulator>
* `Uphardt/RevEmu-2024-Uphardt-Edition-LINUX` — a re-upload of a Linux server
  `bin/steamclient.so` (1 722 036 bytes — the same byte size as bir3yk's own
  08-10-2023 Linux build, see below; identity **not hash-verified**) with a verbose
  Russian `rev.ini`; README: "Both Steam and Non-Steam players will be able to join":
  <https://github.com/Uphardt/RevEmu-2024-Uphardt-Edition-LINUX>
* `FreakPirate/Server_css_revemu_linux` — 2015 snapshot of the *old* Linux server
  part (`linux/bin/steamclient.so` 1 182 148 B, `steamclient_i486.so`,
  `libSteam2Auth.so`, `rev.ini`, `steam_appid.txt`; note says "steamclient_i486.so -
  use css v34 linux server"): <https://github.com/FreakPirate/Server_css_revemu_linux>
  — historical (v34 era), **not** for v92.

bir3yk himself says the binary is protected and unmodifiable: "Отредактировать вряд ли
получится так как он защищен протектором" ("editing is unlikely to work since it is
protected by a protector") — <https://bir3yk.net/forum/topic_3170/> (post 28799,
2024-12-15); when asked for "rev.ini and the rest", his answer is "download the
archive ... take rev.ini from it and read" / "forum search rules" —
<https://bir3yk.net/forum/topic_3019/> (2023).

### 1a. Canonical downloads (bir3yk.net)

The pinned Linux thread **"Последняя версия эмулятора для Linux" (topic 2642)** is the
canonical server download list. Page as read 2026-08-19
(<https://bir3yk.net/forum/topic_2642/>, post 24311, links decoded from the site's
`engine/go.php?url=base64` redirector):

| RevEmu Linux server build | mega.nz | Google Drive |
|---|---|---|
| **[14-04-2026] Server_x32** | `https://mega.nz/file/pG4hzYST#AOD2mQ7NB6i_-ajhFMPY0QSeQzhUub07n_HBQAvJqn0` | `https://drive.google.com/file/d/1B8s6IltBW37ExvfS4Lu1kn3idtEN-63I/view?usp=sharing` |
| [14-04-2026] Server_x64 | `https://mega.nz/file/kOBgEChS#MHBovhfwW7cPQb9diuOVJjGm96JrKzMQBH3DUnOnVJo` | `https://drive.google.com/file/d/1XmkVG96mxHaPu64_iCcU99DFrLxLuqvz/view?usp=sharing` |
| [24-02-2025] Server_x32 | `https://mega.nz/file/lLgAiLAI#p2C11g1tGI8pGOPHnoFsgZTvVsdiL_4UI14DR8KVp8w` | `https://drive.google.com/file/d/1oUI-vXZ9b68mUhinOM1ZiGTDFVuBvsSJ/view?usp=sharing` |
| [24-02-2025] Server_x64 | `https://mega.nz/file/ZP41GAab#JokB9Kc6x6nWsWInZHCkJUfCAc5SwkozMwwtKGX15pw` | `https://drive.google.com/file/d/1EO03Y80k3-V1PT3UQYisMz6gA6SNCriy/view?usp=sharing` |
| [14-12-2024] Server | `https://mega.nz/file/4OgiwZgL#ozCslGSei-E9f8TihXi-xpEDmjphT06mrXQsRYXHu1U` | `https://drive.google.com/file/d/1JWGZOKVbGqc5Vff7lp9REOEABivF9NNH/view?usp=sharing` |
| [08-10-2023] Server | `https://mega.nz/file/ReRUzApI#hx-M9gM82WAP3jB7cGH1VTKfNKw_TRcdcZHPqAkB1bs` | `https://drive.google.com/file/d/1SQKYL_7gTsKskBviKrUT2uU8rzbzR8eM/view?usp=sharing` |
| [21-02-2022] Server | `https://mega.nz/file/gXAwzJjS#_Nj6P2YrFJ2i5xeClqHLL33uj1ECtQ2E5FqqaVjXyig` | `https://drive.google.com/file/d/1c4Qb8XAyeNYoIlmbnbwoccc9EK-cahHa/view?usp=sharing` |

Notes on this list:
* The thread was reachable anonymously when read; the older pinned thread `topic_180`
  ("revemu linux", 2018-2019 builds of 04/12/21-06-2019) is login-walled (HTTP 302
  in every Wayback capture since mid-2019 —
  <https://web.archive.org/cdx/search/cdx?url=bir3yk.net/forum/topic_180/>); its 2019
  copy: <http://web.archive.org/web/20190719113054/http://bir3yk.net:80/forum/topic_180/>.
  Re-check availability before relying on it.
* The **x32 build is the one for CS:S v92** (srcds is 32-bit). x64 builds exist only
  since 21-02-2025 for 64-bit games/servers (CS:S v93 x64, GMod...):
  <https://bir3yk.net/forum/topic_3180/> (post 28962, "Наконец то я собрал 64-х битную
  версию").
* The 21-02-2025 build was pulled after it **crashed a CS:S v92 server** (post 28980
  by Sammit92: "Обновил версию эмулятора на CS:Source v92 ... Сервер вообще не стартует
  и крашится") and re-built on 24-02-2025 "on Ubuntu 14.04" because builds made on
  Ubuntu 24.04 failed on older libc (post 29027) — same thread. The **14-04-2026**
  build is the current one (release post 30771 in
  <https://bir3yk.net/forum/topic_3264/>).
* The Linux **server archive contains exactly one file: `steamclient.so`**. Users
  complain about it ("в архиве только .so файл" —
  <https://bir3yk.net/forum/topic_2978/>; "скачал последнюю версию revemu, там только
  один файл steamclient.so" — <https://bir3yk.net/forum/topic_3019/>), and the
  hl2go mirror copies confirm it (zip central directory read via HTTP range requests
  on 2026-08-19; nothing was downloaded in full or executed):

  | mirror file (hl2go.com) | contents | size (bytes) | timestamp |
  |---|---|---|---|
  | `21.02.2022_server.linux_.zip` | `steamclient.so` | 1 675 300 | 2022-02-21 |
  | `08.10.2023_server.linux_.zip` | `steamclient.so` | 1 722 036 | 2023-10-08 |
  | `21.02.2025_server.linux_x32.zip` | `steamclient.so` | 1 572 332 | 2025-02-21 |
  | `21.02.2025_server.linux_x64.zip` | `steamclient.so` | 1 514 728 | 2025-02-21 |
  | `03.07.2021_server.win_.zip` | `steamclient.dll` | 1 168 896 | 2021-07-03 |

  Mirror page: <https://hl2go.com/downloads/dedicated-servers/srcds/revemu-latest-version-linux-windows/>
  (files: `?download=20512` = 21.02.2022 linux, `20513` = 08.10.2023 linux,
  `21944` = 21.02.2025 x32, `21943` = 21.02.2025 x64, `2592` = 03.07.2021 win,
  `2408` = full `revemu_18_02_2022.zip` 25 MB, `20511`/`2591` = Windows clients;
  direct files under `https://files1.hl2go.com/2022/03/`).
  **So `rev.ini` is NOT in the server archive** — take it from §2b.
* The last **full** archive with `server/linux/rev.ini` + `server/linux/bin/steamclient.so`
  + Windows + client folders is the **03.07.2021** release (the one that fixed v92):
  Google Drive `https://drive.google.com/file/d/1XT9Ph3aT9VXvGFa5VH8kWuz53tYmZqR3/view`
  as linked from the forum how-to "Установка RevEmu версии от 03.07.21 на linux server"
  <https://bir3yk.net/forum/topic_2857/> (post 26276, 2021-07-29). bir3yk's own
  reply elsewhere says the Google copy trips antivirus ("а вы его скачайте антивирус
  удалит вирус, возьмите оттуда rev.ini" — topic 3019). **Treat with care; never run
  on the workstation.**
* se7en.ws mirror of the **23.08.2025** release (changelog: "Support for new Steam
  interfaces; The service unavailability in some regions has been eliminated"):
  `https://mega.nz/file/vtJ3TJAJ#ZCw7sJqhx9mXvR-f44UhUqvSPhZQ_ccZufu2L7eVhUE`
  (decoded from the page's `/away/` base64 link) —
  <https://se7en.ws/download-revemu-bir3yk-latest-version/?lang=en>.
* Windows client side (what a launcher would bundle) lives in the pinned Windows
  thread <https://bir3yk.net/forum/topic_2641/> (05-06-2026, 23-08-2025, 12-06-2025,
  03-04-2025, x32 and x64; mega + Google links in the post). Client = replacement
  `steamclient.dll` + `revLoader` + `rev.ini` (`[Loader] ProcName=...`) +
  `steam_appid.txt` (se7en/hl2go install text; `revloader_x86_64.zip` attachment in
  <https://bir3yk.net/forum/topic_3186/> post 29268).

---

## 2. Installation on a Linux srcds, and `rev.ini`

### 2a. File placement (all sources agree)

1. In the server's `bin/` directory **rename Valve's `steamclient.so` to
   `steamclient_valve.so`**, then copy RevEmu's `steamclient.so` into `bin/`.
   * se7en.ws: "Linux — in bin folder rename steamclient.so to steamclient_valve.so
     then copy steamclient.so file there from the server's archive RevEmu"
     (<https://se7en.ws/download-revemu-bir3yk-latest-version/?lang=en>)
   * hl2go: "go to the bin directory of the game server and rename the original
     steamclient.so file to steamclient_valve.so, then copy the steamclient.so file
     from the archive of the RevEmu server part to the same place"
     (<https://hl2go.com/downloads/dedicated-servers/srcds/revemu-latest-version-linux-windows/>)
   * bir3yk, 2021-07-03: "при обновлении сервера с -validate должен обновится
     steamclient.so ... и вы его должны переименовать в steamclient_valve.so, а потом
     только закинуть эмуль" = "when updating the server with -validate the
     steamclient.so should be updated ... you must rename it to steamclient_valve.so
     and only then drop in the emulator" (<https://bir3yk.net/forum/topic_2840/>,
     post 26127).
   The name `steamclient_valve.so` is only a convention: `rev.ini` `ClientDLL=` points
   at it, any name works (the 2021 how-to uses `steamclient_original.so` —
   <https://bir3yk.net/forum/topic_2857/>).
2. Put **`rev.ini` in the server root, next to `srcds_run`** ("Кидаем его в корень
   нашего сервера. Туда же где находится srcds_run" — topic 2857; "нужен файл rev.ini
   в папке с сервером, без него не запустится" = "rev.ini is needed in the server
   folder, without it it won't start" — bir3yk, <https://bir3yk.net/forum/topic_3170/>
   post 28786). Without it RevEmu logs `Not using ClientDll` and srcds aborts with
   `corrupted double-linked list` (same thread, post 28785).
3. Mechanism: the engine `dlopen`s `bin/steamclient.so` (console: `[S_API]
   SteamAPI_Init(): Loaded local 'steamclient.so' OK.`); RevEmu's file implements the
   Steam interfaces itself and chain-loads the real library from `ClientDLL` for
   everything it does not emulate (VAC/master-server/real-Steam auth — see the
   `ClientDLL` comment in §2b). The Windows side is identical with `.dll`
   (`ClientDLL=.\bin\steamclient_valve.dll`, <https://bir3yk.net/forum/topic_2775/>).
4. Success indicator: a **`rev-client.log`** appears in the server root on start
   (`Startup` / `Using ClientDll "bin/steamclient_valve.so"`); if it is missing RevEmu
   is not loaded at all (<https://bir3yk.net/forum/topic_3197/>). Per-connect lines
   look like `Ticket: Rev Emu.` / `Ticket: Unknown.` then `UserConnect IP = ... |
   SteamID = STEAM_0:0:... (322)` and `SteamDisconnect ...`
   (<https://bir3yk.net/forum/topic_3250/>). The trailing number (322 for RevEmu
   tickets, 2 for "Unknown" in 2025 logs, 164 in a 2024 L4D log) is not documented
   anywhere I found — **UNVERIFIED** what it encodes.
5. **Re-running `steamcmd ... validate` overwrites `bin/steamclient.so` with Valve's
   copy** and RevEmu silently disappears ("при обновлении все равно все слетит как не
   переименовывай" = "on update everything gets reset no matter how you rename" —
   bir3yk, topic 2857 post 26277). For our shared read-only `/opt/css/base` this
   means: apply RevEmu *after* the final `app_update`, record the sha256 of both
   `bin/steamclient.so` and `bin/steamclient_valve.so` in `docs/evidence/`, and make
   the deploy script re-check them after any future validate.
6. Our layout: `bin/steamclient.so` (RevEmu) and `bin/steamclient_valve.so` (Valve)
   belong in the shared base (identical for all seven instances); `rev.ini` in the
   base root too. `rev-client.log` is written to the server root, i.e. into each
   instance's overlay upper dir — the unit's `ReadWritePaths` must cover the merged
   root or RevEmu cannot create it (or set `Logging = False`). RevEmu also needs
   **outbound** network access to bir3yk's backend for `Check_Ticket` and for the
   server-list/"Friends" service (see §4/§6); keep egress open for the srcds user.

### 2b. `rev.ini` reference

The reference config bir3yk points people to in 2026 is the one quoted in
<https://bir3yk.net/forum/topic_3229/> (post 30509; bir3yk: "например тут" =
"for example here", <https://bir3yk.net/forum/topic_2978/> post 30653). His comment
in 2026: "у вас нормальный rev.ini, для серверов он практически не меняется" = "your
rev.ini is fine, for servers it practically never changes"
(<https://bir3yk.net/forum/topic_3253/> post 30630). The Uphardt repo's `rev.ini`
(<https://raw.githubusercontent.com/Uphardt/RevEmu-2024-Uphardt-Edition-LINUX/HEAD/rev.ini>)
is the same key set with Russian prose. Keys, with the upstream comment text and
bir3yk's explanations:

`[steamclient]`

| key | default | meaning (source) |
|---|---|---|
| `PlayerName` | `SteamPlayer` | name of the emulated Steam account (Uphardt ini §1.1) — irrelevant on a server |
| `Logging` | `True` | write `rev-client.log` in the server root |
| `ClientDLL` | (n/a) | "Change ClientDLL to point to the original steamclient.so. This setting will enable VAC for your server and your server will be listed on Valve master server! Also, Steam clients will have their regular Steam IDs" — **must be set**, e.g. `ClientDLL=./bin/steamclient_valve.so` (topic 3229 ini; topic 2857) |
| `DisableUnlockedItems` | `False` | TF2/CS:GO/Dota item emulation toggle; irrelevant for CS:S |
| `EnableSDK` | `False` | "If you use in Ultimate SSDK change the setting below to True" (topic 3229 ini); bir3yk once suggested `EnableSDK = True` as a long-shot crash workaround (<https://bir3yk.net/forum/topic_3176/> post 28915) |

`[GameServer]`

| key | default | meaning (source) |
|---|---|---|
| `AllowOldRev74` | `True` | "Allow revEmu v9.74 ~ 9.82 clients to join your server" (2009-2012 era clients) |
| `AllowOldRev` | `True` | "Allow revEmu v9.63 ~ 9.73 clients ... revEmu v9.62 and below will be rejected nevertheless" |
| `AllowUnknown` | `True` | "Allow unknown clients to join your server" — tickets RevEmu does not recognise (e.g. Goldberg/other emus, or whatever a raw test client sends); bir3yk confirms Goldberg clients get in with `AllowUnknown=true` on the 2025 build (<https://bir3yk.net/forum/topic_3182/> posts 29009/29029) |
| `AllowCracked` | `True` | "Allow cracked Steam clients to join your server" |
| `AllowLegit` | `True` | "Allow legitimate Steam clients to join your server" |
| `AllowedAnyCountConnectUnknownClientWithOneIP` | `True` | "Allowed any count connect Unknown client with one IP (25 Unknown clients 1 IP default true)"; bir3yk 2025: with it off, at most 25 "unknown" clients (per IP/total — wording ambiguous) are admitted, which is one cause of `STEAM validation rejected` (<https://bir3yk.net/forum/topic_3250/> post 30611, <https://bir3yk.net/forum/topic_3229/> post 30510) |
| `Fake_player` | `False` | "Allow shows bots as normal players in the server (in serverbrowser)" — fake online; keep `False` |
| `RevEmu_2012` | `False` | "Allow revemu clients to join your server (steamid subject to substitution)" — admits the legacy 2012/2013 RevEmu ticket whose SteamID is trivially forgeable (see §4b) |
| `RejectText` | `Downloading client on http://you_site.com` | "Reject text for client cs 1.6 max 128 symbol" — shown to rejected non-Steam clients (seen as the disconnect reason in <https://bir3yk.net/forum/topic_3170/> post 28787) |
| `AddCountPlayerInServerName` | `False` | "Add count player in server name etc. (17/32)" |
| `Check_Ticket` | `True` | "Ticket revemu authentication" — verify RevEmu client tickets (online, against bir3yk's service); introduced with the 16.08.2019 anti-spoof release (<https://se7en.ws/solving-the-problem-of-spoofing-steamid-on-cs-s-cs-go-new-revemu/?lang=en>) |
| `Allow_Fail_Check` | `False` | "Allow connection when it is impossible to check" — admit when the ticket check cannot be performed (backend unreachable) |
| `Check_Ticket_Async` | `True` | asynchronous ticket check so the server does not stall (Uphardt ini §2.14; se7en/hl2go install text); bir3yk blames an un-commented `Check_Ticket_Async=False` for a crashing server and recommends 2 CPU cores (<https://bir3yk.net/forum/topic_3176/> post 28910) |
| `UseConectSM` | `False` | "Fix crash if you use SourceMod extension connect.ext" — set `True` only if the SourceMod *connect* extension (§7) is loaded alongside RevEmu |
| `DetectIP` | `False` | "Detect IP with connect client RevEmu for HL2... While you can not use" (2021 ini quoted in <https://bir3yk.net/forum/topic_2840/> post 26163) — leave alone |
| `UseBir3ykOnline` | `False` | 2026: "added option in rev.ini [GameServer] UseBir3ykOnline = True ... for servers located in countries where access to my site is blocked" (<https://bir3yk.net/forum/topic_3264/> post 30771, item 7) |

`[GameServerNSNet]` (`EnableNSNetSvc = False/UDP/TCP/BOTH`, `NSNetDedicatedPort`,
`AdditionalSlaveServer`) is the item/inventory relay for TF2/CS:GO/Dota — bir3yk:
"[GameServerNSNet] и все что ниже уберите это для игр с предметами" = "remove
[GameServerNSNet] and everything below, that is for games with items"
(<https://bir3yk.net/forum/topic_3180/> post 29572). **Delete the section for CS:S.**

bir3yk's own policy guidance (2021-07-05, topic 2840 posts 26127/26164): to keep
SteamID spoofers out use `Check_Ticket = True` and `AllowCracked=False`; the
"maximum online" setting hosting panels push — `CHECK_TICKET=FALSE` + `ALLOW_FAIL_CHECK=TRUE`
("let all pirates in / if the check fails let them in anyway") — is what he explicitly
says *not* to do for security, but it is exactly what most public servers run
(e.g. the MyArena-derived ini in post 26126). Since MISSION §3 says SteamIDs are
forgeable and identity is the phone account, the permissive profile is acceptable
for us **provided nothing keys on SteamID**.

Suggested starting `rev.ini` for Chogan (derived from the reference ini; keys not
listed keep upstream defaults):

```ini
[steamclient]
PlayerName = SteamPlayer
Logging = True
ClientDLL=./bin/steamclient_valve.so
DisableUnlockedItems = True
EnableSDK = False

[GameServer]
AllowOldRev74 = False
AllowOldRev = False
AllowUnknown = True
AllowCracked = True
AllowLegit = True
AllowedAnyCountConnectUnknownClientWithOneIP = True
Fake_player = False
RevEmu_2012 = False
RejectText = Use the Chogan launcher
AddCountPlayerInServerName = False
Check_Ticket = True
Check_Ticket_Async = True
Allow_Fail_Check = True
UseConectSM = False
```
`Check_Ticket=True` + `Allow_Fail_Check=True` keeps RevEmu's own anti-spoof check
when its backend answers and fails open when it does not (the MISSION's fail-open
philosophy); flip to `Check_Ticket = False` if the backend turns out to be
unreachable from 212.80.8.87 (§6). **This profile is untested on v92 — it is the
obvious first thing to probe once a real client exists.**

---

## 3. The "June 2021 steamclient.so" requirement — what it actually refers to

MISSION §4.2 says: servers segfaulted right after `Loaded local 'steamclient.so' OK`
when v92 shipped; "Cause: a stale steamclient.so. Fix: use the 13 June 2021 or newer
one." The primary source is the bir3yk thread **"Crash серверов CS:S c обновлением от
02.07.2021 –[build 6630498]"** <https://bir3yk.net/forum/topic_2840/>:

* Post 26121 (jeffo2109, 2021-07-03): after updating to the 02.07.2021 build he
  re-applied the RevEmu `steamclient.so` **from [21-06-2019]** and got a reboot loop:
  `Initializing Steam libraries for secure Internet server` /
  `[S_API] SteamAPI_Init(): Loaded local 'steamclient.so' OK.` /
  `Segmentation fault (core dumped)`. "Без файла RevEmu (steamclient.so) сервера
  работают в штатном режиме" = "without the RevEmu file the servers run normally".
* Post 26122 (bir3yk): "попробуйте от [13-06-2021] — убрана еще 1 возможная причина
  падения серверов при kick reject игрока. обновил ссылки на новую версию" = "try the
  [13-06-2021] build — one more possible cause of server crashes on kick/reject
  removed; updated the links to the new version".
* Post 26125 (bir3yk, same day): "попробуйте обновить на последнюю версию, сегодня
  выложил, прошлую я не проверял, а новая работает на css сервере" = "update to the
  latest version, posted today (03.07.2021), I did not test the previous one, the new
  one works on a CSS server".
* Post 26126 (jeffo2109): fixed with `steamclient.so (13.06.2021)` ("почему-то теперь
  появилось 03.07.2021" = "for some reason 03.07.2021 now appeared") +
  `steamclient_valve.so` + a `rev.ini` taken from MyArena servers.
* Post 26127 (bir3yk): the Valve file is simply the one `steamcmd ... -validate`
  drops into `bin/` with the update; rename it, then add the emulator.

So: **"13 June 2021 or newer" is the date of bir3yk's RevEmu `steamclient.so` build
(13-06-2021, superseded by 03-07-2021 and everything in §1a), not of Valve's
library.** The Valve library that must be renamed to `steamclient_valve.so` is the one
shipped *inside the v92 server install itself* — on our box
`/opt/css/base/bin/steamclient.so`, 29 505 411 bytes from build 6953255
(recorded in `docs/evidence/01-buildid.txt`). No RevEmu document tells you to take
steamcmd's own `linux32/steamclient.so` instead; that file is the Steam *client*
runtime steamcmd updates for itself and is a different (newer) build — it is not
what "the original steamclient.so from bin" means and using it is **UNVERIFIED**.
(Daren's 2021 how-to even keeps the Valve file under the name
`steamclient_original.so` to survive a hosting panel that deleted `*_valve.so` —
topic 2857 post 26276.)

Practical consequence for us: with the 14-04-2026 (or 24-02-2025) x32 RevEmu build
plus the v92-shipped Valve `steamclient.so` renamed, the §4.2 crash should not occur;
if srcds still dies after `Loaded local 'steamclient.so' OK`, suspect (a) an old RevEmu
build, (b) a missing/unreadable `rev.ini` (→ `Not using ClientDll` +
`corrupted double-linked list`, <https://bir3yk.net/forum/topic_3170/>), (c) a RevEmu
build compiled against a newer glibc than the box (the pulled 21-02-2025 build,
<https://bir3yk.net/forum/topic_3180/> post 29027) — before touching our own code.

---

## 4. The client-side auth ticket — can a test client forge one?

### 4a. Where the ticket travels (engine facts)

On the wire the STEAM branch of `C2S_CONNECT` carries `short len` + a blob (see
`docs/source-connect-protocol.md` §2). Server side the blob ("cookie") is handed to
`CSteam3Server::NotifyClientConnect`, which requires `ucbCookie > 8`, reads a
**little-endian `uint64` SteamID64 first** ("steamID is prepended to the ticket"),
validates universe/individual-account, then calls
`SteamGameServer()->BeginAuthSession(pvCookie+8, ucbCookie-8, steamID)` and logs
`S3: Client connected with invalid ticket: UserID: %x` etc. on failure —
`engine/sv_steamauth.cpp` in the public mirror
<https://raw.githubusercontent.com/nillerusr/source-engine/master/engine/sv_steamauth.cpp>
(function `NotifyClientConnect`, ~line 704). The SourceMod *connect* extension
parses the same layout (`uint64 ullSteamID = *(uint64 *)pCookie; pvTicket = pCookie +
sizeof(uint64)`) — <https://raw.githubusercontent.com/asherkin/connect/master/extension/extension.cpp>.
Later the async verdict arrives through `CSteam3Server::OnValidateAuthTicketResponse`
(`STEAMAUTH: Client %s received failure code %d` → e.g. code 8 =
`k_EAuthSessionResponseAuthTicketInvalid` → "Invalid STEAM UserID Ticket").

`BeginAuthSession` and the validate callback are implemented **inside
`steamclient.so`** — i.e. inside RevEmu once it is installed. That is the whole
trick: RevEmu decides what a "ticket" is. The messages seen with RevEmu
(`S3: Client connected with invalid ticket` + `RejectConnection ... STEAM validation
rejected`, `STEAMAUTH: Client X received failure code 8` + `Invalid STEAM UserID
Ticket`) are these engine paths reacting to RevEmu's answers
(<https://bir3yk.net/forum/topic_3250/>, <https://bir3yk.net/forum/topic_2614/79>
post 26394).

### 4b. Legacy RevEmu ("RevEmu 2013") ticket — public, forgeable

For the 2012-2013 generation of RevEmu the Source ticket is fully documented by
reverse engineering:
* `kohtep/CSSv90Spoofer` (CS:S v90 No-Steam, 2019) hooks
  `CSteam3Client::InitiateConnection` and writes: `pdata[0] = revHash` (low dword,
  `|1` for odd SteamIDs), `pdata[1] = 0x01100001` (high dword of the SteamID64 —
  universe 1, type individual, instance 1), then `GenerateRevEmu2013(data+8, ...)`;
  comment: "Modern Source Engine builds require that SteamID value was in the
  beginning of ticket" —
  <https://raw.githubusercontent.com/2x9Mon/CSSv90Spoofer/master/src/MemPatch.cpp>.
* `kohtep/MultiEmulator` `RevEmu2013.h` is that generator: a **194-byte** record —
  `int 'S'` | `revHash` | `int 'rev'` | `0` | `revHash<<1` (SteamID low) |
  `0x01100001` (SteamID high) | `time+90123` (byte 27 mangled) | `~time` |
  `revHash*2>>3` | `0` | 32-byte AES-256 block of the 32-char HWID string with key
  `0123456789ABCDEFGHIJKLMNOPQRSTUV` | 32-byte AES block of that key string with key
  `_YOU_SERIOUSLY_NEED_TO_GET_LAID_` | SHA-256 of the HWID string —
  <https://raw.githubusercontent.com/kohtep/MultiEmulator/master/MultiEmulator/Source/Emulators/RevEmu2013.h>.
  `revHash` = `RevSpoofer::Hash(hwid)`: `h = 0x4E67C6A7; for each char c: h ^= (h>>2) +
  (h<<5) + c` — <https://raw.githubusercontent.com/kohtep/MultiEmulator/master/MultiEmulator/Source/Public/RevSpoofer.cpp>.
  The SteamID is `revHash<<1` → account id even → always `STEAM_0:0:revHash`; the
  repo includes a solver that finds an HWID string for any wanted SteamID, which is
  why MISSION §3 says non-Steam SteamIDs are forgeable.
* A server admits this ticket only with `RevEmu_2012 = True` ("steamid subject to
  substitution", §2b). **Whether the 2025/2026 server builds still accept it is
  UNVERIFIED** (nobody in the threads I read used it on v92).

### 4c. Current RevEmu ticket (Aug-2019 onwards) — not reproducible

* The 16.08.2019 release "Implemented new anti-spoofing protection" and introduced
  `Check_Ticket` (<https://se7en.ws/solving-the-problem-of-spoofing-steamid-on-cs-s-cs-go-new-revemu/?lang=en>).
* The 2025 reverse-engineering write-up (unknowncheats, "RevEmu SteamID Changer",
  <https://www.unknowncheats.me/forum/counterstrike-source/714921-revemu-steamid-changer.html>)
  describes the current client: "Whenever revEmu decides to generate auth ticket it
  takes disk serial via wmic. For generating steamid it uses next hashing function
  [the same `1315423911` = `0x4E67C6A7` shift/xor hash over 32 chars, result*2] ...
  **Auth ticket is generated by sending request to revEmu servers with serial** ...
  revEmu is protected with themida". I.e. the SteamID is still `hash(HDD serial)*2`
  but the ticket itself is minted by bir3yk's backend, and the spoofer works by
  changing the serial *then letting the genuine client fetch a new ticket*, not by
  forging bytes.
* bir3yk confirms the design from his side: clients need admin rights and a readable
  HDD serial ("CrystalDiskInfo должен видеть ваш s/n HDD. На виртуалке не должно
  работать" = "on a VM it should not work", <https://bir3yk.net/forum/topic_3186/>
  post 29268); servers verify tickets "on the site" ("сервера могу проверять тикета
  на сайте", <https://bir3yk.net/forum/topic_3264/> post 30771 item 9); 2025 ideas to
  give serial-less players a shared ticket (<https://bir3yk.net/forum/topic_3219/>
  post 30476).
* RevEmu logs each accepted ticket type: `Ticket: Rev Emu.` (current client) vs
  `Ticket: Unknown.` (anything else; admitted only with `AllowUnknown=True`, limited
  by `AllowedAnyCountConnectUnknownClientWithOneIP`).

**Answer:** the current RevEmu ticket format/contents are *not* determinable from
public sources and depend on a live third-party service; a test client cannot produce
one. What a test client **can** do:
1. Send `[SteamID64 LE][any >=1 bytes]` and run the server with `AllowUnknown = True`,
   `AllowedAnyCountConnectUnknownClientWithOneIP = True` (and `Check_Ticket = False`
   or `Allow_Fail_Check = True`) — expected to be logged as `Ticket: Unknown.` and
   admitted under the SteamID the client chose (this is how Goldberg clients get in:
   <https://bir3yk.net/forum/topic_3182/>). **Expected, UNVERIFIED on v92.**
2. Or drive a **real RevEmu client** (a se7en.ws / 7launcher CS:S v92 "client build"
   — bir3yk's list of client builds: <https://bir3yk.net/forum/topic_2635/>) on a
   **physical** Windows machine run as admin — VMs get no SteamID (above).
3. Or set `RevEmu_2012 = True` and send the documented 194-byte RevEmu2013 ticket
   (§4b) — **UNVERIFIED** that current builds still honour it.
4. Or avoid RevEmu for the auth path entirely (§7).

Two client-side behaviours to test early because the launcher uses `connect`: UC
users report "revemu somehow breaks your `connect` and `retry` commands, you gotta
connect through the serverbrowser (favorites tab)" and "i wont be able to connect by
ip ... if i did not connected to server via server browser first" (same UC thread,
replies), while bir3yk's forum reports the opposite problem on v93 ("клиенты не могут
добавить в избранное зайти на сервер только через connect" =
"clients cannot add to favourites, can only join via connect",
<https://bir3yk.net/forum/topic_3183/> post 29039). Plausibly the ticket is fetched
asynchronously at client start and an immediate `connect` races it — **UNVERIFIED**;
the launcher should tolerate a retry and the server should run `Allow_Fail_Check`/
`AllowUnknown` on.

---

## 5. Steam and non-Steam clients at the same time

Yes, by design, and it is the default:
* `rev.ini` has independent switches `AllowLegit` (genuine Steam), `AllowCracked`,
  `AllowUnknown`, `AllowOldRev*`, `RevEmu_2012` (§2b); the `ClientDLL` comment says
  pointing it at the original `steamclient.so` "will enable VAC for your server and
  your server will be listed on Valve master server! Also, Steam clients will have
  their regular Steam IDs" — i.e. genuine Steam tickets are passed through to Valve's
  library/backend and keep real SteamIDs, while RevEmu tickets are resolved by the
  emulator (<https://bir3yk.net/forum/topic_3229/> ini; Uphardt README "На сервер
  смогут заходить как Steam, так и Non-Steam Игроки").
* Field reports: "The server was running smoothly for a few hours steam and no-steam"
  (<https://bir3yk.net/forum/topic_3176/> post 28909); "on my server I see that they
  unite steam and non-steam users" (<https://bir3yk.net/forum/topic_3250/> post
  30601); Steam clients' admin rights vanishing after an emulator update was a bug
  report, not the norm (<https://bir3yk.net/forum/topic_3108/>).
* Caveat: a Steam client launched through a "steam fix" (spacewar appid) gets
  `S3: Client connected with ticket for the wrong game` (<https://bir3yk.net/forum/topic_3182/>
  post 29032) — that is the engine/Valve path, not RevEmu.
* For SourceMod this mixed population is why MISSION §4.3 (`SteamAuthstringValidation
  no`) matters: SM's default "validate steamid auth strings with the Steam backend
  before giving out admin access" (<https://raw.githubusercontent.com/alliedmodders/sourcemod/master/configs/core.cfg>)
  can never succeed for emulated IDs.

---

## 6. Known issues on the 2021 v92 build (and later) — and fixes

| symptom | cause | fix | source |
|---|---|---|---|
| `[S_API] SteamAPI_Init(): Loaded local 'steamclient.so' OK.` → `Segmentation fault` in a restart loop, right after the 02.07.2021 update | RevEmu `steamclient.so` older than 13-06-2021 (the 21-06-2019 build) | install the 13-06-2021 / 03-07-2021 or any later RevEmu build; re-rename the freshly validated Valve `steamclient.so` to `steamclient_valve.so` | <https://bir3yk.net/forum/topic_2840/> |
| RevEmu "installed" but no `rev-client.log`, server runs as plain Steam | `rev.ini` missing / `ClientDLL` path wrong; or `validate` re-installed Valve's `steamclient.so` over RevEmu's | put `rev.ini` in the server root with `ClientDLL=./bin/steamclient_valve.so`; re-apply after every validate | <https://bir3yk.net/forum/topic_3197/>, <https://bir3yk.net/forum/topic_2857/> |
| `Not using ClientDll` in log, `corrupted double-linked list` / `Aborted` | no `rev.ini` | add `rev.ini` | <https://bir3yk.net/forum/topic_3170/> |
| `realloc(): invalid next size` / `Aborted (core dumped)` every few minutes (2025 build) | user un-commented `#Check_Ticket_Async=False`; bir3yk also notes 2 CPU cores "desirable" | keep `Check_Ticket_Async = True` (or commented = default) | <https://bir3yk.net/forum/topic_3176/> |
| `Disconnect: Invalid STEAM UserID Ticket` / `STEAMAUTH: Client X received failure code 8` for pirates, Oct 2021 | RevEmu ticket check failing (backend side) | `Check_Ticket=False` ("только так пускает пиратов") or `Allow_Fail_Check=True` | <https://bir3yk.net/forum/topic_2614/79> posts 26394-26441 |
| `S3: Client connected with invalid ticket: UserID: ...` + `RejectConnection: ... STEAM validation rejected`, log shows `Ticket: Unknown.` | unknown tickets disallowed or more than 25 of them | `AllowUnknown = True`, `AllowedAnyCountConnectUnknownClientWithOneIP=True`; bir3yk also suggests `Check_Ticket = True` + `Check_Ticket_Async = True` | <https://bir3yk.net/forum/topic_3250/> |
| server start fails / crashes on CS:S v92 with the 21-02-2025 build | build linked against Ubuntu 24.04 libc | use 24-02-2025 (built on Ubuntu 14.04) or 14-04-2026 x32 | <https://bir3yk.net/forum/topic_3180/> posts 28980/29027 |
| "ghost players" (player count stays 1 after everyone left), `shutdown server` on changelevel, eventual crash — Debian 13 / Ubuntu 24.04 with the 2025 build | attributed by users to RevEmu on very fast disconnects during connecting; bir3yk could not reproduce | none yet; report | <https://bir3yk.net/forum/topic_3253/> |
| crash when the SourceMod *connect* extension is also loaded | documented in `rev.ini` | `UseConectSM = True` | rev.ini comment, §2b |
| pirates kicked with the `RejectText` string after a panel "steam fix"/SIDSPF plugin | third-party SourceMod extension (`SIDSPF.ext.2.css.so`) interfering | remove it; test connects with `addons/` renamed to isolate MM/SM | <https://bir3yk.net/forum/topic_2840/> posts 26194-26201 |
| server-list visibility / ticket check failing from some countries | bir3yk's site blocked regionally | 23.08.2025 build auto-fails-over to a German mirror; 2026 `[GameServer] UseBir3ykOnline = True` | <https://bir3yk.net/forum/topic_3219/>, <https://bir3yk.net/forum/topic_3264/> |

Operational caveats worth stating loudly in the report:
* RevEmu is a **closed, packed binary from one anonymous author that runs inside
  srcds with network access and phones home** (ticket check, server list). It has been
  "cracked" at least once (se7en 2019 article) and SteamID spoofers for it are public
  (<https://www.unknowncheats.me/forum/counterstrike-source/714921-revemu-steamid-changer.html>).
  This is compatible with MISSION §3 only because identity is the phone account.
* bir3yk's service is Russian-hosted; `Check_Ticket` and the server-list features
  depend on reaching it from `212.80.8.87` — **UNVERIFIED**; probe with `curl -I
  https://bir3yk.net/` from the box and keep `Allow_Fail_Check = True`.
* Updates are irregular and client builds (se7en/7launcher) lag server builds; a
  server-side update can lock old client emulators out (`RejectText` path).

---

## 7. Alternatives if RevEmu is unusable

1. **`srcdslab/sm-ext-connect` (SourceMod extension, GPLv3, maintained — release
   1.4.1 on 2026-08-01)** — <https://github.com/srcdslab/sm-ext-connect>. It detours
   `CBaseServer::ConnectClient`, reads `SteamID64 + ticket` from the cookie, calls
   `BeginAuthSession` itself, then exposes **`OnBeginAuthSessionResult` and
   `OnValidateAuthTicketResponse` forwards whose return value *replaces* the
   result**, a `ValidateAuthTicketResponse(steamID, response, owner)` native to
   synthesise Steam's verdict, and `OnClientPreConnectEx(name, password, ip,
   steamID, rejectReason)` with async accept/reject (`connect.inc` in the repo; logic
   in `src/extension.cpp`, <https://raw.githubusercontent.com/srcdslab/sm-ext-connect/master/src/extension.cpp>).
   Gamedata `connect2.games.txt` covers `engine css` (and dods) on linux/linux64/
   windows using exported symbols (`_ZN11CBaseServer13ConnectClientE...`,
   `_ZN13CSteam3Server28OnValidateAuthTicketResponseE...`) —
   <https://raw.githubusercontent.com/srcdslab/sm-ext-connect/master/package/addons/sourcemod/gamedata/connect2.games.txt>.
   A ~20-line plugin returning `k_EBeginAuthSessionResultOK` / `k_EAuthSessionResponseOK`
   turns it into a no-Steam gate that **admits any client with whatever SteamID it
   claims and no third-party backend**, while genuine Steam clients still validate
   normally — which is precisely the MISSION's threat model (SteamID untrusted,
   phone account is identity, `lt` ticket does the real auth). It comes from the same
   org as SMAC/Lilac. Caveats: 1.4.1 assets are built on **ubuntu-24.04** for
   sm-1.12/sm-master (<https://github.com/srcdslab/sm-ext-connect/releases/tag/1.4.1>)
   — on our 22.04 box check `ldd`/GLIBC symbols or build with AMBuild; older
   `1.4.0.post2` assets are plain `sm-ext-connect-linux.tar.gz`
   (<https://github.com/srcdslab/sm-ext-connect/releases/tag/1.4.0.post2>);
   **loading on v92 (ServerGameClients004 era) is UNVERIFIED** — gamedata is by
   symbol so it should bind, test it. Original upstream (no override forwards):
   <https://github.com/asherkin/connect> ("Only the Source 2009 engine is supported").
2. **BotoX / CSSZombieEscape `sm-ext-connect`** — the fork those forwards descend
   from, with a built-in **`sv_nosteam 1`** cvar ("Disable steam validation and force
   steam authentication") and `sv_forcesteam`: when set, an invalid ticket is not
   rejected and a fake `ValidateAuthTicketResponse` OK is injected after
   `ConnectClient` — <https://git.botox.bz/CSSZombieEscape/sm-ext-connect>
   (`extension.cpp`, <https://git.botox.bz/CSSZombieEscape/sm-ext-connect/raw/branch/master/extension.cpp>).
   Last commit "fix for latest css update, thanks to maxime1907" is dated
   **2021-07-03 — i.e. for v92**. Caveats: self-hosted Gitea, no GitHub mirror
   (`github.com/CSSZombieEscape/sm-ext-connect` = 404), needs building against
   SM 1.11/1.12 yourself; **UNVERIFIED** on our build.
3. **Uphardt "RevEmu 2024 Uphardt Edition (LINUX)"** — GitHub re-upload of a RevEmu
   Linux server `steamclient.so` (same size as bir3yk 08-10-2023) + readable
   `rev.ini`: <https://github.com/Uphardt/RevEmu-2024-Uphardt-Edition-LINUX>. Only
   useful as a fallback copy of RevEmu itself; same closed binary, older than the
   14-04-2026 build, provenance unverifiable.
4. **Old RevEmu (2013-2015, "RevEmu 2013")** — e.g. the 2015 snapshot
   <https://github.com/FreakPirate/Server_css_revemu_linux> (`steamclient.so`,
   `steamclient_i486.so`, `libSteam2Auth.so`, `rev.ini`; CS:S v34). Not for v92
   (its 2019 successor already segfaulted on v92, §3) and fully spoofable (§4b).
5. **LumaEmu** — Windows-only `steamclient.dll` emulator documented for CS:GO/CS:S
   servers ("Currently there are only 2 STEAM emulators which are LumaEmu and RevEmu
   that can turn your Source Dedicated Server into Non-Steam") —
   <https://whatsoftware.com/how-to-make-a-non-steam-css-server-using-revemu-vup-and-esteamation/>.
   No Linux build; irrelevant for our box.
6. **"SteamEmu", "SourceEmu", engine no-steam patches (2008-2012 Setti/NoSteam
   guides)** — GoldSrc-era or dead; `kohtep/MultiEmulator` lists SteamEmu/Setti/
   AVSMP/SC2009 generators for *HL1 with DProto/ReUnion only* —
   <https://github.com/kohtep/MultiEmulator>. Nothing comparable for Source 2013
   dedicated servers was found beyond items 1-5. (Setti's 2012 "How to crack ANY
   server" thread exists at <http://css.setti.info/forum/topic/2277-how-to-crack-any-server-winlinux-updated/>
   but is pre-v92 and was not retrievable in detail.)
7. **Client-side only emulators (Goldberg, SmartSteamEmu) are not server solutions**:
   they present "unknown" tickets that RevEmu admits with `AllowUnknown=True`
   (<https://bir3yk.net/forum/topic_3182/>) and that option 1/2 admits by construction.

Recommendation for the build: keep RevEmu as MISSION §3 specifies for the *player*
population (it is what every no-Steam CS:S client build out there speaks), but gate
**nothing** on its verdicts; and, if RevEmu cannot be obtained/does not load on v92,
switch to option 1 (srcdslab connect + override plugin) — it also gives the `cg-agent`
test client a trivial ticket (`SteamID64 + 1 byte`). Record whichever branch is taken
in `docs/decisions.md` / `docs/probes.md`.

---

## 8. Sources (all read 2026-08-19)

bir3yk.net: forum index <https://bir3yk.net/forum/>; topic 2642 (Linux downloads)
<https://bir3yk.net/forum/topic_2642/>; topic 2641 (Windows client downloads)
<https://bir3yk.net/forum/topic_2641/>; topic 2840 (v92 crash, 2021-07)
<https://bir3yk.net/forum/topic_2840/>; topic 2857 (03.07.21 Linux how-to)
<https://bir3yk.net/forum/topic_2857/>; topic 2614 p.79 (Oct-2021 ticket failures)
<https://bir3yk.net/forum/topic_2614/79>; topic 3019 <https://bir3yk.net/forum/topic_3019/>;
topic 2978 <https://bir3yk.net/forum/topic_2978/>; topic 3229 (reference rev.ini)
<https://bir3yk.net/forum/topic_3229/>; topic 3170 <https://bir3yk.net/forum/topic_3170/>;
topic 3176 <https://bir3yk.net/forum/topic_3176/>; topic 3180 <https://bir3yk.net/forum/topic_3180/>;
topic 3182 <https://bir3yk.net/forum/topic_3182/>; topic 3183 <https://bir3yk.net/forum/topic_3183/>;
topic 3186 <https://bir3yk.net/forum/topic_3186/>; topic 3197 <https://bir3yk.net/forum/topic_3197/>;
topic 3219 <https://bir3yk.net/forum/topic_3219/>; topic 3224 <https://bir3yk.net/forum/topic_3224/>;
topic 3250 <https://bir3yk.net/forum/topic_3250/>; topic 3253 <https://bir3yk.net/forum/topic_3253/>;
topic 3264 <https://bir3yk.net/forum/topic_3264/>; topic 2775 <https://bir3yk.net/forum/topic_2775/>;
topic 2635 <https://bir3yk.net/forum/topic_2635/>; topic 3108 <https://bir3yk.net/forum/topic_3108/>.
Mirrors: <https://hl2go.com/downloads/dedicated-servers/srcds/revemu-latest-version-linux-windows/>,
<https://se7en.ws/download-revemu-bir3yk-latest-version/?lang=en>,
<https://se7en.ws/solving-the-problem-of-spoofing-steamid-on-cs-s-cs-go-new-revemu/?lang=en>,
<https://whatsoftware.com/how-to-make-a-non-steam-css-server-using-revemu-vup-and-esteamation/>.
Code: <https://github.com/kohtep/MultiEmulator>, <https://github.com/2x9Mon/CSSv90Spoofer>,
<https://github.com/kohtep/revLoader>, <https://github.com/Uphardt/RevEmu-2024-Uphardt-Edition-LINUX>,
<https://github.com/FreakPirate/Server_css_revemu_linux>, <https://github.com/asherkin/connect>,
<https://github.com/srcdslab/sm-ext-connect>, <https://git.botox.bz/CSSZombieEscape/sm-ext-connect>,
<https://raw.githubusercontent.com/nillerusr/source-engine/master/engine/sv_steamauth.cpp>,
<https://raw.githubusercontent.com/alliedmodders/sourcemod/master/configs/core.cfg>.
Other: <https://www.unknowncheats.me/forum/counterstrike-source/714921-revemu-steamid-changer.html>,
<http://web.archive.org/web/20190719113054/http://bir3yk.net:80/forum/topic_180/>.
