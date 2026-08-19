# Source engine connect handshake — protocol facts (CS:S v92, protocol 24)

Purpose: give a protocol-level test client and **MISSION §5 probe 1** exact,
code-cited facts about the Source connect handshake, the userinfo (`setinfo`)
channel, and where the token can and cannot be read on the server.

## 0. Sources, method, and version caveats

All quotes below are from the public engine mirror **`nillerusr/source-engine`**
(branch `master`), read on **2026-08-19** via `raw.githubusercontent.com`. That is
the only public source that contains the engine `.cpp` we need — the official
`ValveSoftware/source-sdk-2013` ships game code and public headers only, **not**
`baseserver.cpp` / `baseclientstate.cpp` / `net_chan.cpp`, so it cannot answer
these questions.

Raw file base:
`https://raw.githubusercontent.com/nillerusr/source-engine/master/<path>`

Line numbers are from that master snapshot; they may drift as the mirror changes,
so each citation also quotes the code.

**Version caveats — read these before trusting field values:**

1. **Protocol number.** The mirror is at `PROTOCOL_VERSION 25`
   (`common/proto_version.h:15`). **Retail CS:S v92 is protocol 24.** The *wire
   layout* is identical; only the integer the client writes in the `C2S_CONNECT`
   `protocol` field differs. A test client talking to the v92 server **must send
   24**, and the server's `CheckProtocol` rejects anything `!= 24`
   (`baseserver.cpp:1400`, quoted in §3).
2. **This mirror is a cleaned/modernised fork.** In a few spots it has
   `#if 0`-ed or commented out code paths that are live in the retail srcds binary
   (most importantly the `PROTOCOL_STEAM` steam-ticket read in the connect packet
   — see §2). Where the fork clearly diverges from what retail v92 does on the
   wire, it is flagged inline. I could **not** disassemble the retail binary from
   here, so anything that depends on retail-only behaviour is called out as
   *unverified against the shipping binary* and pushed to probe 1.

Constants used throughout (`common/proto_oob.h`, `common/protocol.h`):

| name | byte / value | meaning |
|---|---|---|
| `CONNECTIONLESS_HEADER` | `0xFFFFFFFF` (long) | prefix of every OOB packet |
| `A2S_GETCHALLENGE` | `'q'` (0x71) | client asks for a challenge |
| `S2C_CHALLENGE` | `'A'` (0x41) | server's challenge reply |
| `C2S_CONNECT` | `'k'` (0x6B) | client connect request |
| `S2C_CONNECTION` | `'B'` (0x42) | server accepts, "use netchannels now" |
| `S2C_CONNREJECT` | `'9'` (0x39) | connect rejected + reason string |
| `S2C_MAGICVERSION` | `0x5A4F4933` | version-mismatch magic in `S2C_CHALLENGE` |
| `PROTOCOL_STEAM` | `0x03` | Steam-cert auth |
| `PROTOCOL_HASHEDCDKEY` | `0x02` | hashed-CD-key auth (non-Steam / dedicated-outside-Steam) |
| `STEAM_KEYSIZE` | `2048` | max steam auth key buffer |
| `net_SetConVar` | `5` | netmsg id — userinfo/convar update |
| `net_SignonState` | `6` | netmsg id — signon state change |
| `NETMSG_TYPE_BITS` | `6` | bits used to encode a netmsg id (`engine/net.h:73`) |
| `SIGNONSTATE_CONNECTED` | `2` | netchans ready |
| `SIGNONSTATE_NEW` | `3` | got serverinfo + string tables |

---

## 1. The connectionless challenge exchange

### 1a. What the client sends — `A2S_GETCHALLENGE` (`'q'`)

`CBaseClientState` fires the challenge request from its resend/retry path
(`engine/baseclientstate.cpp:860-869`):

```cpp
    // Request another challenge value.
    {
        ALIGN4 char     msg_buffer[MAX_ROUTABLE_PAYLOAD] ALIGN4_POST;
        bf_write    msg( msg_buffer, sizeof(msg_buffer) );

        msg.WriteLong( CONNECTIONLESS_HEADER );
        msg.WriteByte( A2S_GETCHALLENGE );
        msg.WriteLong( m_retryChallenge );
        msg.WriteString( "0000000000" ); // pad out
        NET_SendPacket( NULL, m_Socket, adr, msg.GetData(), msg.GetNumBytesWritten() );
    }
```

Wire layout of the `'q'` packet, in order:

| # | field | type / size | value |
|---|---|---|---|
| 1 | connectionless header | long, 4 | `0xFFFFFFFF` |
| 2 | message id | byte, 1 | `'q'` (0x71) |
| 3 | **client challenge** | long, 4 | `m_retryChallenge` |
| 4 | padding | string | `"0000000000"` + NUL (11 bytes) |

`m_retryChallenge` is the client-chosen nonce, generated once per connect
(`baseclientstate.cpp:651`): `m_retryChallenge = (RandomInt(0,0x0FFF) << 16) | RandomInt(0,0xFFFF);`
It is echoed back by the server (see §1b) so the client can prove the reply
matches its request.

> **Divergence from retail / MISSION wording.** MISSION §E-1 describes a
> `'connect0x%08X'` trailer. This mirror does **not** use that ASCII form — it
> writes a raw `long` (`m_retryChallenge`) followed by a literal `"0000000000"`
> pad string. The older/retail GoldSrc-style `getchallenge` used a
> `"connect 0x%08x"` text body; the modern Source binary uses the binary form
> shown here. A test client should send the binary form; if the v92 server does
> not answer, fall back to trying the text form and record which one v92 accepts.

### 1b. What the server returns — `S2C_CHALLENGE` (`'A'`)

`CBaseServer::ReplyChallenge` (`engine/baseserver.cpp:980-1016`):

```cpp
void CBaseServer::ReplyChallenge(netadr_t &adr, int clientChallenge )
{
    ALIGN4 char buffer[STEAM_KEYSIZE+32] ALIGN4_POST;
    bf_write msg(buffer,sizeof(buffer));

    int challengeNr = GetChallengeNr( adr );
    int authprotocol = GetChallengeType( adr );

    msg.WriteLong( CONNECTIONLESS_HEADER );
    msg.WriteByte( S2C_CHALLENGE );
    msg.WriteLong( S2C_MAGICVERSION ); // This makes it so we can detect that this server is correct
    msg.WriteLong( challengeNr );      // Server to client challenge
    msg.WriteLong( clientChallenge );  // Client to server challenge to ensure our reply is what they asked
    msg.WriteLong( authprotocol );

#if !defined( NO_STEAM )
    if ( authprotocol == PROTOCOL_STEAM )
    {
        msg.WriteShort( 0 ); //  steam2 encryption key not there anymore
        CSteamID steamID = Steam3Server().GetGSSteamID();
        uint64 unSteamID = steamID.ConvertToUint64();
        msg.WriteBytes( &unSteamID, sizeof(unSteamID) );
        msg.WriteByte( Steam3Server().BSecure() );
    }
#else
    msg.WriteShort( 1 );
    msg.WriteByte( 0 );
    uint64 unSteamID = 0;
    msg.WriteBytes( &unSteamID, sizeof(unSteamID) );
    msg.WriteByte( 0 );
#endif
    msg.WriteString( "000000" );  // padding bytes

    NET_SendPacket( NULL, m_Socket, adr, msg.GetData(), msg.GetNumBytesWritten() );
}
```

Wire layout of the `'A'` reply, in order:

| # | field | type / size | notes |
|---|---|---|---|
| 1 | connectionless header | long, 4 | `0xFFFFFFFF` |
| 2 | message id | byte, 1 | `'A'` (0x41) |
| 3 | magic version | long, 4 | `S2C_MAGICVERSION` = `0x5A4F4933` (`"ZOI3"`); lets client detect a wrong/old server |
| 4 | **server challenge** (`challengeNr`) | long, 4 | server→client nonce; the value the client must put in the `C2S_CONNECT` `challenge` field, and later in every netchannel packet |
| 5 | **client challenge echo** | long, 4 | the `clientChallenge` the client sent in the `'q'` packet, echoed back |
| 6 | **auth protocol** | long, 4 | `PROTOCOL_STEAM` (3) or `PROTOCOL_HASHEDCDKEY` (2), chosen by `GetChallengeType` |
| 7a | steam2 key size | short, 2 | **only if authprotocol == STEAM** — always `0` (steam2 key removed) |
| 7b | **gameserver SteamID** | uint64, 8 | **only if STEAM** — `Steam3Server().GetGSSteamID()` |
| 7c | **VAC secure byte** | byte, 1 | **only if STEAM** — `BSecure()` (1 = VAC secure) |
| 8 | padding | string | `"000000"` + NUL |

`GetChallengeType` (`baseserver.cpp:1046`) returns `PROTOCOL_HASHEDCDKEY` when
`AllowDebugDedicatedServerOutsideSteam()` is true or Steam is not available,
otherwise `PROTOCOL_STEAM`. On the RevEmu non-Steam v92 build the effective auth
protocol is whatever RevEmu's fake steamclient advertises — a test client must
read field 6 from the reply and echo it, not assume a value.

`challengeNr` is not random: `GetChallengeNr` (`baseserver.cpp:1067`) is a CRC32 of
`(client IP << 32) + m_CurrentRandomNonce`, so it is stable per source IP until the
server rotates its nonce. `CheckChallengeNr` (`baseserver.cpp:307`) validates it and
also accepts the previous nonce during a rotation window.

The client consumes this reply in `ProcessConnectionlessPacket`
(`baseclientstate.cpp:919-971`): it verifies the echoed client challenge, reads
`authprotocol`, and for STEAM reads the steam2-key short, the gameserver SteamID,
and the secure byte, then calls `SendConnectPacket(...)`.

---

## 2. `C2S_CONNECT` (`'k'`) packet layout — and where userinfo lives

### 2a. What the client writes

`CBaseClientState::SendConnectPacket` (`engine/baseclientstate.cpp:495-560`):

```cpp
    msg.WriteLong( CONNECTIONLESS_HEADER );
    msg.WriteByte( C2S_CONNECT );
    msg.WriteLong( PROTOCOL_VERSION );
    msg.WriteLong( authProtocol );
    msg.WriteLong( challengeNr );
    msg.WriteLong( m_retryChallenge );
    msg.WriteString( GetClientName() ); // Name
    msg.WriteString( password.GetString() );      // password
    msg.WriteString( GetSteamInfIDVersionInfo().szVersionString ); // product version
//  msg.WriteByte( ( g_pServerPluginHandler->GetNumLoadedPlugins() > 0 ) ? 1 : 0 );

    switch ( authProtocol )
    {
        case PROTOCOL_HASHEDCDKEY:  CDKey = GetCDKeyHash();
                                    msg.WriteString( CDKey );  // cdkey
                                    break;
        case PROTOCOL_STEAM:        if ( !PrepareSteamConnectResponse( unGSSteamID, bGSSecure, adr, msg ) )
                                        return;
                                    break;
        default:                    Host_Error( ... ); return;
    }
    ...
    NET_SendPacket( NULL, m_Socket, adr, msg.GetData(), msg.GetNumBytesWritten() );
```

Wire layout of the `'k'` packet, in order:

| # | field | type / size | notes |
|---|---|---|---|
| 1 | connectionless header | long, 4 | `0xFFFFFFFF` |
| 2 | message id | byte, 1 | `'k'` (0x6B) |
| 3 | **protocol version** | long, 4 | `PROTOCOL_VERSION` — **send 24 for v92** |
| 4 | **auth protocol** | long, 4 | echo of field 6 from `S2C_CHALLENGE` |
| 5 | **server challenge** | long, 4 | `challengeNr` from `S2C_CHALLENGE` |
| 6 | **client challenge** | long, 4 | `m_retryChallenge` (same nonce as the `'q'` packet) |
| 7 | **name** | string | `GetClientName()` — the `name` userinfo cvar |
| 8 | **password** | string | `password` cvar value |
| 9 | **product version** | string | from `steam.inf` (`szVersionString`) |
| 10a | **cdkey / GUID** | string | if `authProtocol == HASHEDCDKEY`: `GetCDKeyHash()` (32-hex MD5) |
| 10b | **steam ticket** | short len + bytes | if `authProtocol == STEAM`: see note below |

`PrepareSteamConnectResponse` (`baseclientstate.cpp:566-611`) is where the steam
ticket would be appended as `WriteShort(len)` then `WriteBytes(ticket, len)` — but
**in this mirror the body is wrapped in `#if 0`**, so the fork does not actually
append a steam ticket. On the retail binary this block is live and does write
`short length + length bytes`. Treat the STEAM-branch length+bytes as *retail
behaviour, unverified here*.

### 2b. Are the userinfo convars written INTO the connect packet? **No.**

This is the load-bearing answer for MISSION probe 1.

`SendConnectPacket` above writes name, password, product version, and the auth
blob — **and nothing else.** There is no `NET_SetConVar` / `Host_BuildConVarUpdateMessage`
call anywhere in the connect packet path. The server agrees: its `C2S_CONNECT`
parser reads exactly those fields and then immediately calls `ConnectClient`,
never touching the rest of the buffer (`baseserver.cpp:691-763`):

```cpp
    case C2S_CONNECT :
    {
        char cdkey[STEAM_KEYSIZE];
        char name[256];
        char password[256];
        char productVersion[32];

        int protocol       = msg.ReadLong();
        int authProtocol   = msg.ReadLong();
        int challengeNr    = msg.ReadLong();
        int clientChallenge= msg.ReadLong();
        ... CheckChallengeNr / rate limit ...
        msg.ReadString( name, sizeof(name) );
        msg.ReadString( password, sizeof(password) );
        msg.ReadString( productVersion, sizeof(productVersion) );
        ... version check ...
        {
            msg.ReadString( cdkey, sizeof(cdkey) );
            ConnectClient( packet->from, protocol, challengeNr, clientChallenge,
                           authProtocol, name, password, cdkey, strlen(cdkey) );
        }
    }
```

Instead, **the userinfo convars are sent as the first reliable netchannel
message, right after the netchannel comes up.** When the client's state machine
reaches `SIGNONSTATE_CONNECTED` it builds and sends them
(`engine/client.cpp:256-274`, `CClientState::SetSignonState`):

```cpp
        case SIGNONSTATE_CONNECTED :
        {
            ...
            m_NetChannel->SetTimeout( SIGNON_TIME_OUT );
            m_NetChannel->SetMaxBufferSize( true, NET_MAX_PAYLOAD );

            // set user settings (rate etc)
            NET_SetConVar convars;
            Host_BuildConVarUpdateMessage( &convars, FCVAR_USERINFO, false );
            m_NetChannel->SendNetMsg( convars );
        }
        break;
```

`Host_BuildConVarUpdateMessage(..., FCVAR_USERINFO, ...)` collects **every**
cvar flagged `FCVAR_USERINFO` (which includes every key created by `setinfo`) into
a single `net_SetConVar` message. So the MISSION's phrase "written INTO the connect
packet" is **incorrect for this engine**: the userinfo rides the netchannel as the
first `net_SetConVar`, *after* the connect handshake finishes, not inside the `'k'`
packet.

### 2c. `net_SetConVar` wire format — bit-packed, not byte-aligned

`NET_SetConVar::WriteToBuffer` (`common/netmessages.cpp:1136-1153`):

```cpp
bool NET_SetConVar::WriteToBuffer( bf_write &buffer )
{
    buffer.WriteUBitLong( GetType(), NETMSG_TYPE_BITS );  // 6 bits, value = 5 (net_SetConVar)
    int numvars = m_ConVars.Count();
    buffer.WriteByte( numvars );                          // count, 8 bits
    for (int i=0; i< numvars; i++ )
    {
        cvar_t * var = &m_ConVars[i];
        buffer.WriteString( var->name  );
        buffer.WriteString( var->value );
    }
    return !buffer.IsOverflowed();
}
```

Wire layout, in order:

| # | field | encoding |
|---|---|---|
| 1 | message type | `WriteUBitLong(5, 6)` — **6 bits**, value `net_SetConVar` = 5 |
| 2 | count `numvars` | `WriteByte` — **8 bits**, so **max 255 convars per message** |
| 3.. | for each: key then value | `WriteString(name)` then `WriteString(value)`, each a NUL-terminated byte string |

**Byte alignment: no.** The message id is a 6-bit field, so from that point the
message is bit-packed inside the netchannel stream; `WriteByte`/`WriteString`
operate at the current bit cursor (Source's `bf_write` writes bytes/strings at
arbitrary bit offsets). A test client that hand-rolls this must use a Source-style
bit writer, not naive byte alignment. The netchannel frames it (§4); this message
is one entry in the reliable subchannel payload.

The server reads it symmetrically in `NET_SetConVar::ReadFromBuffer`
(`netmessages.cpp:1155-1173`): `ReadByte` count, then `ReadString(name)` /
`ReadString(value)` per entry into fixed `cvar_t` buffers (§6 for the size).

---

## 3. Server `CBaseServer::ConnectClient` — exact order, and when the token is visible

`ConnectClient` (`engine/baseserver.cpp:435-595`). The order of operations that
decides whether `GetClientInfo(client,"lt")` can be read inside a given SourceMod
forward:

1. `if ( !IsActive() ) return NULL;` and null-guards on name/password/cdkey.
2. **`CheckProtocol`** (`baseserver.cpp:451`, body at 1400) — rejects if
   `nProtocol != PROTOCOL_VERSION` (24 on v92). Quote:
   ```cpp
   bool CBaseServer::CheckProtocol( netadr_t &adr, int nProtocol, int clientChallenge )
   {
       if ( nProtocol != PROTOCOL_VERSION )
       {
           if ( nProtocol > PROTOCOL_VERSION )
               RejectConnection( adr, clientChallenge, "#GameUI_ServerRejectOldVersion" );
           else
               RejectConnection( adr, clientChallenge, "#GameUI_ServerRejectNewVersion" );
           return false;
       }
       return true;
   }
   ```
3. **`CheckChallengeNr`** (`:457`) — rejects `#GameUI_ServerRejectBadChallenge` if
   the challenge is not the one this IP was issued.
4. If not HLTV/Replay: **`CheckIPRestrictions`** (`:469`, §5) then
   **`CheckPassword`** (`:476`).
5. **`GetFreeClient`** (`:488`) — allocates the slot; `#GameUI_ServerRejectServerFull`
   if none.
6. **`CheckChallengeType`** (`:497`) — Steam auth start / non-Steam GUID setup.
7. Ban check (`Filter_IsUserBanned`) and `FinishCertificateCheck`.
8. **`NET_CreateNetChannel`** (`:534`) then `netchan->SetChallengeNr( challenge )`.
9. **`client->Connect( name, nNextUserID, netchan, false, clientChallenge )`**
   (`baseserver.cpp:550`). **This is where the game DLL's
   `IServerGameClients::ClientConnect` runs, i.e. where SourceMod fires
   `OnClientConnect` and `OnClientConnected`.**
10. Server sends **`S2C_CONNECTION`** back (`:567-577`, §4).

Crucially, **there is no convar read anywhere in `ConnectClient`.** No
`ProcessSetConVar`, no userinfo parsing. `CBaseClient::Connect`
(`engine/baseclient.cpp:562-593`) allocates a *fresh empty* userinfo store and
sets `m_bInitialConVarsSet = false`:

```cpp
void CBaseClient::Connect( const char * szName, int nUserID, INetChannel *pNetChannel, bool bFakePlayer, int clientChallenge )
{
    ...
    Clear();
    m_ConVars = new KeyValues("userinfo");   // EMPTY
    m_bInitialConVarsSet = false;
    m_UserID = nUserID;
    SetName( szName );                        // only "name" is populated, from the connect packet
    ...
    m_nSignonState = SIGNONSTATE_CONNECTED;
}
```

So at the instant `OnClientConnect` / `OnClientConnected` fire, the only userinfo
key that exists is **`name`** (set from connect-packet field 7). Any `setinfo`
key such as `lt` is **not present yet.**

The userinfo arrives later, over the netchannel, and is applied by
`CBaseClient::ProcessSetConVar` (`engine/baseclient.cpp:806-860`):

```cpp
bool CBaseClient::ProcessSetConVar( NET_SetConVar *msg )
{
    for ( int i=0; i<msg->m_ConVars.Count(); i++ )
    {
        const char *name  = msg->m_ConVars[i].name;
        const char *value = msg->m_ConVars[i].value;
        // reject keys with non [A-Za-z0-9_] characters (see §6)
        ...
        if ( V_stricmp( name, "name" ) == 0 ) { ClientRequestNameChange( value ); continue; }

        // The initial set of convars must contain all client convars that are flagged userinfo...
        if ( m_bInitialConVarsSet && !m_ConVars->FindKey( name ) )
        {
            Warning( "Client \"%s\" userinfo ignored: \"%s\" = \"%s\"\n", GetClientName(), name, value );
            continue;
        }
        m_ConVars->SetString( name, value );
    }
    m_bConVarsChanged = true;
    m_bInitialConVarsSet = true;   // first batch latches this
    return true;
}
```

`GetClientInfo` on the SourceMod side ultimately reads this store via
`CBaseClient::GetUserSetting` (`baseclient.cpp:165`), which returns
`m_ConVars->GetString(key,"")` — empty until the first `net_SetConVar` batch is
processed.

**Timeline (multiplayer, real UDP client):**

```
client -> 'q' getchallenge
server -> 'A' challenge
client -> 'k' connect            (name/pw/version only; NO userinfo)
server:  ConnectClient
            -> client->Connect()  ==> ClientConnect fires
                                       OnClientConnect / OnClientConnected  <-- GetClientInfo("lt") == ""  (only "name" set)
         send 'B' S2C_CONNECTION
client:  FullConnect, netchan up, enter SIGNONSTATE_CONNECTED
         -> send net_SetConVar (ALL FCVAR_USERINFO, incl. lt)   <-- token on the wire here
         -> send net_SignonState(CONNECTED)
server:  ProcessSetConVar   ==> m_ConVars now holds lt, m_bInitialConVarsSet = true
                                       GetClientInfo("lt")  now returns the token
         ProcessSignonState(CONNECTED) -> m_bSendServerInfo = true
server:  SendServerInfo -> ... -> net_SignonState(NEW)          (later SM forwards: PostAdminCheck / PutInServer run after this)
```

**Consequence for probe 1.** In this engine, `GetClientInfo(client,"lt")` inside
`OnClientConnected` returns empty, because the `setinfo` value has not been
received yet. It becomes readable only **after** the first `net_SetConVar` batch,
i.e. in a later forward (`OnClientPostAdminCheck`, `OnClientPutInServer`) or on a
short timer. This is exactly the risk MISSION §5 probe 1 exists to test.

> **Caveat, stated plainly.** I could not confirm the *retail v92 binary* behaves
> identically at the `ConnectClient` boundary — a retail build could conceivably
> read a trailing convar block from the connect packet before `client->Connect`.
> But three independent signals in this same source tree point to "userinfo comes
> over the channel, after connect": (a) the client only sends it at
> `SIGNONSTATE_CONNECTED` via `Host_BuildConVarUpdateMessage` — the very function
> MISSION named; (b) `m_bInitialConVarsSet` starts false in `Connect` and is
> latched by the *first channel* `ProcessSetConVar`; (c) the "initial set of
> convars" exploit-fix comment is the well-known retail comment. **Recommendation:
> do not build auth on reading `lt` in `OnClientConnected`.** Prefer probe 1's
> path that reads it slightly later (post-admin-check / a short grace timer), or
> MISSION's fallback (a `RegConsoleCmd` the launcher fires right after connect).
> Verify empirically and record the branch in `docs/probes.md`.

---

## 4. `S2C_CONNECTION` (`'B'`), the netchannel packet header, timeouts, and the minimum a fake client must send

### 4a. `S2C_CONNECTION` (`'B'`) — server accepts

Emitted inside `ConnectClient` (`engine/baseserver.cpp:567-577`):

```cpp
    msg.WriteLong( CONNECTIONLESS_HEADER );
    msg.WriteByte( S2C_CONNECTION );
    msg.WriteLong( clientChallenge );
    msg.WriteString( "0000000000" ); // pad out
    NET_SendPacket ( NULL, m_Socket, adr, msg.GetData(), msg.GetNumBytesWritten() );
```

Layout: header (long) · `'B'` (byte) · client-challenge echo (long) · `"0000000000"`
pad string. No other params. On receiving it (and only while in
`SIGNONSTATE_CHALLENGE`), the client runs `FullConnect`
(`baseclientstate.cpp:682-720`): create netchannel, `StartStreaming(m_nChallengeNr)`,
`SetSignonState(SIGNONSTATE_CONNECTED)`.

### 4b. Netchannel packet header (every in-band packet after connect)

Written by `CNetChan::SendDatagram` (`engine/net_chan.cpp:1575-1660`), read by
`CNetChan::ProcessPacketHeader` (`net_chan.cpp:2232-2263`). Header fields in order:

| # | field | size | notes |
|---|---|---|---|
| 1 | out sequence nr | long, 4 | `m_nOutSequenceNr`; starts at 1 |
| 2 | in sequence ack | long, 4 | `m_nInSequenceNr` (last seq seen from peer) |
| 3 | flags | byte, 1 | `PACKET_FLAG_*` bitmask (written back-patched) |
| 4 | checksum | short, 2 | **present iff `ShouldChecksumPackets()`** = `NET_IsMultiplayer()` (true on our servers). 16-bit fold of CRC32 over the rest of the packet |
| 5 | reliable state | byte, 1 | `m_nInReliableState` — the 8 subchannel reliable bits |
| 6 | choked count | byte, 1 | **present iff `PACKET_FLAG_CHOKED`** in flags |
| 7 | challenge | long, 4 | **present iff `PACKET_FLAG_CHALLENGE`** — and the sender *always* sets that flag (`flags |= PACKET_FLAG_CHALLENGE;` at `net_chan.cpp:1653`). Must equal the challenge set by `SetChallengeNr` (the `challengeNr` from `S2C_CHALLENGE`) |
| 8 | subchannel/reliable data | var | present iff `PACKET_FLAG_RELIABLE` |
| 9 | unreliable messages | var | the datagram payload (net messages) |

Flag bits (`common/protocol.h:73-79`): `RELIABLE 1<<0`, `COMPRESSED 1<<1`,
`ENCRYPTED 1<<2`, `SPLIT 1<<3`, `CHOKED 1<<4`, `CHALLENGE 1<<5`.

`ProcessPacketHeader` **drops the packet (returns -1)** if: the 16-bit checksum
mismatches; the challenge is present but `!= m_ChallengeNr`; a challenge was
expected (seen before) but absent; or the sequence is stale/duplicate
(`sequence <= m_nInSequenceNr`). So a test client MUST: put the correct challenge
in every packet, compute the CRC-16 checksum correctly, and monotonically
increase its out-sequence. `MAX_SUBCHANNELS = 8` (`net_chan.h:32`).

### 4c. Does the server wait, and how long?

Yes. After `S2C_CONNECTION` the client already owns a netchannel and a slot, with
the netchannel timeout set to **`SIGNON_TIME_OUT = 300.0f` seconds**
(`engine/net.h:26`; set at `net_chan.cpp:438` and again in
`CGameClient::SetSignonState(SIGNONSTATE_CONNECTED)` at `sv_client.cpp:723`,
comment: "allow 5 minutes to load map"). `CBaseServer::CheckTimeouts`
(`baseserver.cpp:1243-1272`) drops a client only when `netchan->IsTimedOut()`, and
**skips fake clients** (`if ( cl->IsFakeClient() || !cl->IsConnected() ) continue;`).

Two important notes for a protocol-level test client:
- A real UDP test client is **not** an engine "fake client"
  (`CreateFakeClient`/bots are), so it **is** subject to the 300 s timeout and to
  the reliable-overflow disconnect. It has ~5 minutes of grace but must keep the
  netchannel alive with valid packets.
- `CheckTimeouts` is compiled out entirely in `_DEBUG` builds (`#if !defined(_DEBUG)`).
  Retail srcds is release, so the 300 s timeout applies.

### 4d. Minimum to progress `CONNECTED -> NEW` and beyond

`net_SignonState` wire format (`common/netmessages.cpp:789-796`):
`WriteUBitLong(type=6, 6 bits)` · `WriteByte(m_nSignonState)` · `WriteLong(m_nSpawnCount)`.

To advance from `SIGNONSTATE_CONNECTED` to `SIGNONSTATE_NEW`, the client must, over
the established netchannel:

1. Send the initial **`net_SetConVar`** userinfo batch (see §2c). Not strictly
   required to *advance*, but required for the server to know rate/name/`lt`; the
   real client always sends it first at CONNECTED.
2. Send **`net_SignonState(SIGNONSTATE_CONNECTED, spawncount)`**. The server's
   `CBaseClient::ProcessSignonState` (`baseclient.cpp:866-888`) requires the state
   to *match* the server's current `m_nSignonState` or it forces a `Reconnect()`;
   for states `> CONNECTED` the `spawncount` must equal `m_Server->GetSpawnCount()`.
   On the matching CONNECTED ack, `CBaseClient::SetSignonState` sets
   `m_bSendServerInfo = true` (`baseclient.cpp:283-287`).
3. On its next frame the server runs `SendPendingServerInfo`
   (`baseserver.cpp:1308-1319`) -> `SendServerInfo` -> writes `svc_ServerInfo`,
   string-table baselines, an `FCVAR_REPLICATED` `net_SetConVar`, and finally
   `net_SignonState(SIGNONSTATE_NEW)` (`baseclient.cpp:673-752`), moving the client
   to NEW.
4. At NEW the client sends **`CLC_ClientInfo`** (SendTable CRC, server count,
   custom-file CRCs — `client.cpp:177-214`) and acks
   `net_SignonState(SIGNONSTATE_NEW)`. The server's `ProcessClientInfo`
   (`baseclient.cpp:891+`) rejects it unless the client is exactly in NEW.

Beyond NEW the sequence continues PRESPAWN -> SPAWN -> FULL, each gated by a
matching `net_SignonState` ack; for the auth use-case the token is already
readable by the CONNECTED->NEW point (after step 2's `net_SetConVar` is processed),
so a fake client that only needs to deliver `lt` does not have to reach FULL.

---

## 5. `sv_lan` / `CheckIPRestrictions` — is loopback exempt? are outsiders rejected?

`CBaseServer::CheckIPRestrictions` (`engine/baseserver.cpp:1528-1553`):

```cpp
bool CBaseServer::CheckIPRestrictions( const netadr_t &adr, int nAuthProtocol )
{
    // Determine if client is outside appropriate address range
    if ( adr.IsLoopback() )
        return true;

    if ( IsX360() )
        return true;

    // allow other users if they're on the same ip range
    if ( Steam3Server().BLanOnly() )
    {
        // allow connection, if client is in the same subnet
        if ( adr.CompareClassBAdr( net_local_adr ) )
            return true;

        // allow connection, if client has a private IP
        if ( adr.IsReservedAdr() )
            return true;

        // reject connection
        return false;
    }
    return true;
}
```

Answers:

- **Loopback is exempt** — unconditional `return true` for `adr.IsLoopback()`,
  before the LAN check. A loopback fake client is never LAN-restricted.
- **With `sv_lan 1`** (`Steam3Server().BLanOnly()` true), a non-local address is
  accepted **only** if it is in the **same class B (/16) subnet** as the server
  (`CompareClassBAdr( net_local_adr )`) **or** is an RFC1918 private/reserved
  address (`IsReservedAdr()`); otherwise it is **rejected**. In `ConnectClient` the
  rejection surfaces as `RejectConnection(..., "#GameUI_ServerRejectLANRestrict")`
  (`baseserver.cpp:469-472`).

**Correction to MISSION §E-5 wording.** The restriction is **class B (/16)**, not
"class C". The literal string `"LAN servers are restricted to local clients
(class C)"` is the older GoldSrc message; the Source engine uses the localization
token `#GameUI_ServerRejectLANRestrict` and compares on **class B** plus a private-
IP allowance. Practical upshot for MISSION: with all seven servers on the public
`212.80.8.87`, **keep `sv_lan 0`** (default). If `sv_lan 1` were ever set, only
clients in `212.80.x.x` or on private IPs could connect. Loopback (the A2S/RCON
watchdog, a local fake-client probe) is always allowed regardless of `sv_lan`.

Related: `CheckPassword` (`baseserver.cpp:1560+`) also short-circuits to allow
`adr.IsLocalhost() || adr.IsLoopback()` past any `sv_password`.

---

## 6. `setinfo` key/value limits — confirming the 260-byte claim and the key charset

### 6a. Value/key size — MAX_OSPATH = 260, per field, independently. **Confirmed.**

The `net_SetConVar` payload uses `cvar_t` with two fixed buffers
(`common/netmessages.h:114-121`):

```cpp
    typedef struct cvar_s
    {
        char    name[MAX_OSPATH];
        char    value[MAX_OSPATH];
    } cvar_t;
```

and `MAX_OSPATH` is **260** (`common/qlimits.h:21`):

```c
#define MAX_QPATH   96    // max length of a game pathname
#define MAX_OSPATH  260   // max length of a filesystem pathname
```

On read, `NET_SetConVar::ReadFromBuffer` (`netmessages.cpp:1155-1173`) does
`ReadString(var.name, sizeof(var.name))` and `ReadString(var.value, sizeof(var.value))`
— i.e. each is truncated to **260 bytes including the NUL (259 usable characters)**,
independently. This **confirms MISSION §3's "each userinfo key and value is capped
at 260 bytes independently"** — it is `MAX_OSPATH`, not a coincidence.

The **255-keys** figure is also confirmed: the count is a single `WriteByte(numvars)`
/ `ReadByte()` (`netmessages.cpp:1141`, `1159`), so at most **255 convars per
`net_SetConVar` message**.

> **Caution on "a JWT fits" (MISSION §3).** The value cap is 259 usable bytes. A
> real JWT (`header.payload.signature`, base64url) frequently exceeds that —
> even a minimal HS256 JWT with a couple of claims is often 150-250 bytes, and
> anything with more claims or an RS256 signature blows past 259 and would be
> **silently truncated** by `ReadString`, corrupting the token. Keep the `lt`
> ticket **short and opaque** (e.g. a random 32-48 byte handle the `cg-agent`
> resolves), not a full JWT, or verify the exact JWT length stays < 259 bytes.
> This is a real risk to the auth design and belongs in `OPEN-QUESTIONS.md`.

### 6b. Key charset must be `[A-Za-z0-9_]`. **Confirmed, on both sides.**

Client side, in the `setinfo` command handler (`engine/cl_main.cpp:2865-2877`):

```cpp
    // Discard any convar change request if contains funky characters
    bool bFunky = false;
    for (const char *s = name ; *s != '\0' ; ++s )
    {
        if ( !V_isalnum(*s) && *s != '_' )
        {
            bFunky = true;
            break;
        }
    }
    if ( bFunky )
    {
        Msg( "Ignoring convar change request for variable '%s', which contains invalid character(s)\n", name );
        return;
    }
```

Server side, the identical filter in `CBaseClient::ProcessSetConVar`
(`engine/baseclient.cpp:815-833`) rejects any incoming key with a non-`[A-Za-z0-9_]`
character ("invalid characters in the variable name"). So a `setinfo` **key** must
match `[A-Za-z0-9_]+` — `lt` is fine. (The **value** is not charset-restricted, only
length-restricted to 259 usable bytes.)

### 6c. Bonus confirmations of MISSION §3 behavioural claims

- **"setinfo before connect; keys created after connect are silently ignored."**
  Confirmed by the `m_bInitialConVarsSet` guard in `ProcessSetConVar` (§3): once
  the initial batch is processed, a `net_SetConVar` naming a key that was **not**
  in that batch is dropped with `Warning("... userinfo ignored ...")`. Since the
  initial batch is `Host_BuildConVarUpdateMessage(FCVAR_USERINFO)` built at
  `SIGNONSTATE_CONNECTED`, any key the launcher creates *before* `connect` is
  included and accepted; a brand-new key created *after* connect is ignored.
  Existing keys can still be *updated* after connect.
- **Name is special.** `SetUserCVar`/`ProcessSetConVar` route `"name"` through
  `ClientRequestNameChange` rather than the generic store (`baseclient.cpp:186-199`,
  `829-833`), and `cl_main.cpp:2860` blocks manual `setinfo name`. Don't use `name`
  as an auth channel.

---

## 7. Compact answer set (2, 3, 5, 6) for the orchestrator

- **A2** — `C2S_CONNECT 'k'`: header · `'k'` · protocol(long, **send 24**) ·
  authProtocol(long) · challengeNr(long) · clientChallenge(long) · name(string) ·
  password(string) · productVersion(string) · then HASHEDCDKEY -> cdkey(string) OR
  STEAM -> short len + ticket bytes (STEAM branch `#if 0`-ed in this mirror).
  **Userinfo convars are NOT in the connect packet.** They go over the netchannel
  as the first `net_SetConVar`, built by `Host_BuildConVarUpdateMessage(FCVAR_USERINFO)`
  at `SIGNONSTATE_CONNECTED`. `net_SetConVar` wire = `WriteUBitLong(id=5,6b)` +
  `WriteByte(count<=255)` + per-var `WriteString(key)`+`WriteString(val)`;
  **bit-packed, not byte-aligned.**
- **A3** — `ConnectClient` order: CheckProtocol -> CheckChallengeNr ->
  CheckIPRestrictions -> CheckPassword -> GetFreeClient -> CheckChallengeType ->
  NET_CreateNetChannel -> **`client->Connect()` (ClientConnect / SM
  OnClientConnect+OnClientConnected fire here)** -> send `S2C_CONNECTION`. **No
  convar read in `ConnectClient`.** `Connect` allocates an empty userinfo store
  (`m_bInitialConVarsSet=false`); only `name` is set from the packet. Userinfo is
  applied later by `CBaseClient::ProcessSetConVar` off the netchannel. **Therefore
  `GetClientInfo(client,"lt")` is empty in `OnClientConnected`** and only becomes
  readable after the first `net_SetConVar` (i.e. `OnClientPostAdminCheck` /
  `OnClientPutInServer` / a short timer). Recommend probe 1 not rely on
  `OnClientConnected`; retail-binary parity at this boundary is *unverified* — test it.
- **A5** — `CheckIPRestrictions`: **loopback exempt (unconditional)**. With
  `sv_lan 1`, non-local accepted only if **same class B (/16)** as the server or a
  **private/reserved IP**; else rejected -> `#GameUI_ServerRejectLANRestrict`.
  MISSION's "(class C)" is wrong: it's **class B**. Keep `sv_lan 0` for the public
  `212.80.8.87` servers.
- **A6** — key and value each `char[MAX_OSPATH]`, `MAX_OSPATH = 260`
  (`qlimits.h:21`), truncated on read -> **260 bytes each, independently
  (259 usable)** — MISSION §3 **confirmed**. Count byte -> **<=255 convars per
  message** confirmed. Keys must be **`[A-Za-z0-9_]`** (filtered on both client and
  server) — confirmed. **Caution:** a real JWT often exceeds 259 bytes and would be
  silently truncated; keep the `lt` ticket a short opaque handle.

### Cross-checks / corrections logged against MISSION

1. Userinfo is **not** carried "INTO the connect packet"; it is the first
   netchannel `net_SetConVar`. (§2b)
2. `GetClientInfo("lt")` is **not** reliably available in `OnClientConnected` on
   this engine. (§3) — directly feeds probe 1's fallback choice.
3. LAN restriction is **class B**, not class C. (§5)
4. `getchallenge` uses a binary `client-challenge long` + pad, not a
   `"connect0x%08X"` ASCII trailer, in this mirror. (§1a)
5. This mirror is `PROTOCOL_VERSION 25`; v92 retail is **24** — send 24. (§0)
6. "A JWT fits" is fragile against the 259-byte value cap. (§6a)
