# srcclient — protocol-level Source engine test client (CS:S v92, protocol 24)

`srcclient.py` is a Python 3 (stdlib only) fake game client that performs the
real Source-engine connect handshake and then keeps a real netchannel alive.
It exists for **MISSION §5 probe 1** and for automated "does this instance accept
a player" checks: it lets us put a `setinfo lt=...` userinfo key on the wire
exactly like a launcher-driven game client would, without a game client.

Files

| file | purpose |
|---|---|
| `srcclient.py` | the client (run it on the server box, or from anywhere that can reach the game port) |
| `fakeserver.py` | an offline stand-in for the server side, built from the same framing code; lets you exercise the client without srcds (consistency check, **not** an independent oracle) |

## What it does

1. `A2S_GETCHALLENGE` (`'q'`) with a random client challenge → parses `S2C_CHALLENGE`
   (`'A'`): magic, server challenge, client-challenge echo, auth protocol, (for
   `PROTOCOL_STEAM`) steam2 key size, game-server SteamID64, VAC-secure byte.
2. `C2S_CONNECT` (`'k'`): protocol **24**, auth protocol (echo of what the server
   advertised, or `--authproto 2|3`), challenge, client challenge, name, password,
   product version (`steam.inf` PatchVersion, default learned from `A2S_INFO`,
   fallback `6630498`), then either a 32-hex cdkey (auth 2) or `short len + ticket
   bytes` (auth 3).
3. Parses `S2C_CONNECTION` (`'B'`, also the `"B00000000000000"` resend form) or
   `S2C_CONNREJECT` (`'9'`) and prints the reason (known `#GameUI_ServerReject*`
   tokens are explained).
4. Netchannel loop for `--hold` seconds. Every packet carries the real header
   (out-seq, in-seq ack, flags, **CRC16 fold of CRC32** over the rest of the packet,
   reliable-state byte, optional choked byte, `PACKET_FLAG_CHALLENGE` + challenge).
   The first packet carries, **reliably** (sub-channel + fragment encoding, single
   block `VarInt32` length, multi-fragment when > 1024 bytes):
   `net_SetConVar` (userinfo: name, rate, cl_updaterate, cl_cmdrate, cl_interp,
   cl_interp_ratio, cl_lagcompensation, cl_predict, ... plus every `--setinfo k=v`)
   followed by `net_SignonState(CONNECTED, -1)` — the same order the real client
   uses (`engine/client.cpp` `CClientState::SetSignonState`, CONNECTED case).
   Then it: acks the server's reliable sub-channels (flips the reliable-state bit
   after a block is fully received, reassembles fragments, decompresses
   Snappy/LZSS blocks and whole packets, reassembles split packets), parses
   `svc_Print`, `svc_ServerInfo` (spawn count, map, hostname, tick interval),
   `net_Tick`, string-table messages, `net_SetConVar`, `net_SignonState`,
   `net_Disconnect`, answers `svc_GetCvarValue` and `net_File` requests, resends
   un-acked reliable data, and sends NOP keep-alives every 0.5 s.
   With `--progress 3` it also answers `net_SignonState(NEW)` with
   `CLC_ClientInfo` + `net_SignonState(NEW)`; `--progress 4/5/6` ack PRESPAWN /
   SPAWN / FULL best-effort (see limits).
5. At the end it sends `net_Disconnect("srcclient done")` so the slot is freed.

Also:

* `--a2s` — `A2S_INFO` with the 2020 challenge handshake (`'A'` reply → resend with
  the 4-byte challenge appended), prints all fields.
* `--rcon-password PW --rcon-cmd "status"` — minimal Source RCON over TCP (auth +
  one command, multi-packet response collected).
* `--selftest` — offline checks (bit packing vs. engine layout, CRC fold, Snappy,
  LZSS, a UDP loopback of two netchannels with a dropped packet/resend, checksum
  rejection).

## Final line (machine readable)

```
SRCCLIENT_RESULT connected=1 rejected_reason=none held_seconds=15.0 last_signon_state=3 serverinfo_seen=1 spawncount=12 userinfo_acked=1 dropped=0 disconnect_reason=none authproto=3 challenge=0x1c2b3a49 challenge_format=binary map=de_dust2 hostname=Chogan_|_Public_#1_|_Classic packets_in=17 packets_out=33 ...
```

| key | meaning |
|---|---|
| `connected` | 1 = `S2C_CONNECTION` received (server allocated a slot and created the netchannel) |
| `rejected_reason` | reason string from `S2C_CONNREJECT`, `no_challenge_reply`, `no_connection_reply`, or `none` |
| `held_seconds` | how long the netchannel phase lasted |
| `last_signon_state` | highest `net_SignonState` value the server sent us (2 CONNECTED, 3 NEW, 4 PRESPAWN, 5 SPAWN, 6 FULL) |
| `serverinfo_seen` | 1 = `svc_ServerInfo` parsed (only sent after the server processed our `net_SignonState(CONNECTED)`) |
| `userinfo_acked` | 1 = the server acknowledged the reliable block that carried `net_SetConVar` + `net_SignonState(CONNECTED)` — i.e. `CBaseClient::ProcessSetConVar` ran |
| `dropped` / `disconnect_reason` | server sent `net_Disconnect` before the hold ended |
| `authproto`, `challenge`, `challenge_format` | what was used |
| `map`, `hostname`, `spawncount` | from `svc_ServerInfo` |
| `reliable_*`, `server_drops_seen`, `bytes_*`, `packets_*` | channel stats |

Exit code: 0 when `connected=1`, 1 otherwise, 2 for A2S/RCON failures.

## How to run on the box

Python 3.10 is installed on the VM (docs/server-facts.md). No packages needed.

```bash
# copy the directory (scripts/rput from the workstation) to e.g. /opt/css/tools/srcclient
cd /opt/css/tools/srcclient
python3 srcclient.py --selftest                                # offline sanity check

# 1) is the instance up?  (A2S_INFO with challenge)
python3 srcclient.py --host 127.0.0.1 --port 27017 --a2s

# 2) probe 1: connect with setinfo lt=hello and stay 20 s
python3 srcclient.py --host 127.0.0.1 --port 27017 --name probe1 --setinfo lt=hello --hold 20 -v

# 3) RCON status while it is held (other terminal)
python3 srcclient.py --host 127.0.0.1 --port 27017 --rcon-password '...' --rcon-cmd status

# 4) against the public IP (from the box or elsewhere): same, --host 212.80.8.87
```

`-v` prints one line per packet and per parsed message; `-vv` adds hex dumps.
Loopback is exempt from every IP restriction and from `sv_password`
(`CheckIPRestrictions` / `CheckPassword`, `baseserver.cpp` ~1528/1560). With `sv_lan 1`
a run from outside the server's /16 (or a non-RFC1918 address) is rejected with
`#GameUI_ServerRejectLANRestrict`; with `sv_lan 0` it needs the password and — for
`--authproto 3` — a ticket RevEmu accepts (see note 7 below).
While it is held, on the server console / rcon: `status` should list the client
(name from the connect packet, `STEAM_ID_LAN` with `sv_lan 1`, `STEAM_ID_PENDING`
with `sv_lan 0` and no valid Steam auth), `net_showmsg 1` / `net_showfragments 1` /
`net_showudp 1` show what the engine makes of our packets, and a SourceMod plugin
reading `GetClientInfo(client, "lt")` in `OnClientConnected` /
`OnClientSettingsChanged` shows whether the key arrived.

Useful switches:

| switch | why |
|---|---|
| `--authproto auto|2|3` | default: echo the server's advertised protocol. `2` = HASHEDCDKEY (`--cdkey`, 32 hex), `3` = STEAM (`--ticket dummy|none|<hex>`, `--steamid64`, `--ticket-pad`) |
| `--ticket-as-string` | send the STEAM ticket as a NUL-terminated string (nillerusr-mirror server style) instead of `short len + bytes` (retail style) |
| `--challenge-format auto|binary|text` | `'q'` body: binary `long client challenge + "0000000000"` (engine source) or the text `connect0x%08X` form; `auto` tries binary twice, then text twice |
| `--product-version` | defaults to the `A2S_INFO` version string (`6630498` on our v92 build); the server rejects a mismatch with `#GameUI_ServerRejectOldVersion/NewVersion` |
| `--progress N` | highest signon state to acknowledge (default 2: stay at CONNECTED/NEW, never ack NEW) |
| `--sendtable-crc 0x...` | CRC to put in `CLC_ClientInfo` when acking NEW (unknown → 0) |
| `--no-challenge-flag` | omit the per-packet challenge (fallback if the engine build predates `PACKET_FLAG_CHALLENGE`) |
| `--no-disconnect` | leave without `net_Disconnect` so the server-side timeout path can be observed |
| `--bind-port` | fixed local UDP port (firewall tests) |

## What it proves — and what it does not

Proves (when `connected=1 userinfo_acked=1 serverinfo_seen=1`):

* the instance answers the connectionless handshake and accepts a protocol-24 client
  with the given auth protocol / version / password;
* the server's netchannel accepted our header (challenge, CRC, sequence), processed
  our reliable block (`ProcessSetConVar` stored the userinfo, `ProcessSignonState(CONNECTED)`
  ran `CheckConnect` → game DLL `ClientConnect` → SourceMod `OnClientConnect(ed)`),
  and sent `svc_ServerInfo` + `net_SignonState(NEW)` back;
* the client can stay parked in NEW for `--hold` seconds without being dropped
  (`SIGNON_TIME_OUT` is 300 s, `net.h:26`).

Does not prove: that a real game client can play (no SendTables, no entity
decoding, no clc_Move), nor anything about the auth backend.

## Protocol notes, findings and uncertainties

Everything was derived from the public engine mirror
`https://github.com/nillerusr/source-engine` (a cleaned 2017-era Source 2013 MP
engine, `PROTOCOL_VERSION` bumped to 25 only as a number), cross-checked with
`docs/source-connect-protocol.md`. The retail CS:S v92 `srcds_linux` could not be
disassembled from here; items marked *unverified* need the first real run.

1. **Where `ClientConnect` fires (differs from `docs/source-connect-protocol.md` §3).**
   The doc says the game DLL's `ClientConnect` (SourceMod `OnClientConnect` /
   `OnClientConnected`) runs inside `CBaseServer::ConnectClient` → `client->Connect()`.
   In the engine source it actually runs in `CGameClient::CheckConnect()`
   (`engine/sv_client.cpp` ~872, `g_pServerPluginHandler->ClientConnect(...)`), which is
   called from `CGameClient::SetSignonState(SIGNONSTATE_CONNECTED)` (~718), i.e. when the
   server processes the client's **`net_SignonState(CONNECTED)`** message — the message
   the real client sends right **after** the `net_SetConVar` userinfo block in the same
   reliable payload (`engine/client.cpp` CONNECTED case + the trailing
   `SendNetMsg(NET_SignonState(state,count))`). `CNetChan::ProcessMessages` handles them in
   order, so `m_ConVars` already holds `lt` when `ClientConnect` runs. Consequence for
   probe 1: `GetClientInfo(client, "lt")` **should** be readable in `OnClientConnected`
   (and of course in `OnClientSettingsChanged`, fired from `CBaseServer::UpdateUserSettings`
   in the same server frame, after `NET_ProcessSocket`). `CBaseClient::Connect()` only sets
   the name and fires the `player_connect` game event. *Unverified on the retail binary* —
   this is exactly what probe 1 measures; srcclient sends the two messages in the
   engine's order so the probe is faithful.
2. **`'q'` body.** The mirror's client writes `long clientChallenge + "0000000000"`
   (`baseclientstate.cpp` ~860) and the server reads `ReadLong()` (`baseserver.cpp` ~690).
   MISSION/task text mention a `connect0x%08X` string (CS:GO-era form). Default is
   `auto`: binary first, text as fallback; the result line reports `challenge_format`.
3. **Netchannel header.** `seq, ack, flags, CRC16, relstate, [choked], [challenge],
   [subchannel data], messages` (`net_chan.cpp` SendDatagram ~1575 / ProcessPacketHeader
   ~2232). Checksum = CRC32 (IEEE, zlib table) over everything after the checksum field,
   folded `low16 ^ high16` (~1517). Padding: a NOP if 1–2 bits remain in the last byte,
   then ones to the byte boundary with the pad count in flags bits 5–7
   (`ENCODE_PAD_BITS`, `protocol.h:81`) — bit 5 overlaps `PACKET_FLAG_CHALLENGE`, which
   is always set anyway. Receivers ignore pad bits (they stop when < 6 bits remain).
4. **Challenge flag.** The mirror always sends `PACKET_FLAG_CHALLENGE` and drops packets
   without it once it has seen one. Assumed present in the 2021 retail build
   (*unverified*) — `--no-challenge-flag` exists as the fallback.
5. **Reliable sub-channel encoding** (`SendSubChannelData` ~1169 / `ReadSubChannelData`
   ~1312): 3-bit sub-channel index; per stream (normal, file) one bit "data follows";
   single block = `0`, compressed bit, **`VarInt32` byte count** (protocol > 23; protocol
   ≤ 23 used `NET_MAX_PAYLOAD_BITS` — `proto_version.h` "NET_MAX_PAYLOAD_BITS went away"
   at 23→24), data; multi-fragment = `1`, 18-bit start fragment, 3-bit count, and on the
   first fragment: file bit (+32-bit id + name), compressed bit (+26-bit size), 26-bit
   total bytes. Fragment size 256, at most 4 per packet (1260/256). Acks: the receiver
   flips its `m_nInReliableState` bit for that sub-channel once the packet's fragments
   were read (a block spanning several packets is acked piecewise); the sender compares
   that byte with its `m_nOutReliableState` and frees/resends per sub-channel.
6. **Compression.** Reliable blocks ≥ 1024 bytes are Snappy-compressed by the sender
   (`CompressFragments` ~131, id `SNAP`); whole packets ≥ 1024 bytes may be sent as
   `0xFFFFFFFD + SNAP...` (`net_ws.cpp` ~2441). LZSS (`LZSS` id) is also decoded. Both
   decoders are pure Python; *the Snappy path has only been tested on synthetic data*.
7. **Auth.** `GetChallengeType` returns `PROTOCOL_STEAM` on a dedicated server, so
   RevEmu servers advertise 3. Retail `CheckChallengeType` (the `#if 0` parts of the
   mirror, *unverified*): STEAM → ticket length must be 1..2047 and `NotifyClientConnect`
   (first 8 bytes = SteamID64, must be an individual account in the GS universe, then
   `BeginAuthSession`) may fail — **with `sv_lan 1` that failure is ignored**
   (`&& !BLanOnly()`), the client gets `STEAM_ID_LAN`; with `sv_lan 0` it is
   `#GameUI_ServerRejectSteam` unless RevEmu's `BeginAuthSession` accepts the dummy
   ticket. HASHEDCDKEY → cdkey must be exactly 32 chars, then
   `NotifyLocalClientConnect` (`CreateUnauthenticatedUserConnection`). Whether a retail
   server that advertised 3 accepts 2 is *unverified*; both are implemented.
8. **Version check.** `Q_strncmp(serverPatchVersion, clientVersion, strlen(server))`
   (`baseserver.cpp` ~720): the client string must start with the server's
   `PatchVersion` (`6630498` here, `docs/evidence/01-buildid.txt`).
9. **Beyond NEW.** Acking NEW makes the server run `SendSignonData`; unless the
   `CLC_ClientInfo` SendTable CRC equals the server's or `sv_sendtables 1` is set, it
   disconnects with "Server uses different class tables" (`sv_client.cpp` ~941). That is
   why the default `--progress 2` parks the client at NEW (which is enough for
   probe 1). With `sv_sendtables 1` the client has been seen (against `fakeserver.py`
   only) to walk NEW → PRESPAWN → SPAWN → FULL with `--progress 6`; on a real server the
   PRESPAWN/SPAWN data (`svc_ClassInfo`, sounds, baselines, `svc_PacketEntities`) is
   skipped by length fields, *not* decoded.
10. `svc_ServerInfo` / `CLC_ClientInfo` carry a trailing `m_bIsReplay` bit in
    `REPLAY_ENABLED` builds (CS:S ships `replay_srv.so`); the parser auto-detects it from
    the `net_Tick` that always follows `svc_ServerInfo` and mirrors the result in
    `CLC_ClientInfo`.
11. **Userinfo limits** (confirmed in the doc): key and value ≤ 259 bytes each, keys
    `[A-Za-z0-9_]`, ≤ 255 keys per message; new keys after the first batch are ignored
    (`m_bInitialConVarsSet`). The client warns if a `--setinfo` violates these.

## Limits

* Not a game client: no entity/datatable decoding, no `clc_Move`, no voice, no file
  transfer; messages it does not know stop parsing of that packet (channel stays up).
* No Steam/RevEmu ticket generation — only dummy/hex tickets.
* Timing is Python `select` with 0.5 s keep-alives; fine for signon (300 s timeout) and
  for FULL (`sv_timeout` 65 s) but do not expect it to keep up with 100-tick snapshot
  rates for long.
* `fakeserver.py` shares its framing code with the client, so it only proves
  self-consistency, never wire compatibility with srcds.
