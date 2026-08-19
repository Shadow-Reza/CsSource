#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
srcclient.py -- protocol-level Source-engine test client (CS:S v92 / protocol 24).

Python 3 standard library only.  Meant to run ON the game server box against
127.0.0.1 (sv_lan 1 friendly) and later against the public IP.

What it does
  1. A2S_GETCHALLENGE 'q'  -> S2C_CHALLENGE 'A'   (challenge, auth protocol, GS steamid, secure)
  2. C2S_CONNECT 'k'       -> S2C_CONNECTION 'B' or S2C_CONNREJECT '9'
  3. netchannel: every packet has the real header (seq / ack / flags / CRC16 fold of
     CRC32 / reliable-state byte / choked / challenge); first packet carries the
     userinfo as a RELIABLE net_SetConVar (subchannel + fragment encoding) followed by
     net_SignonState(CONNECTED); then NOP keep-alives every 0.5 s for --hold seconds,
     acking the server's reliable sub-channels, parsing svc_ServerInfo /
     net_SignonState / svc_Print / net_Disconnect and (optionally) progressing
     CONNECTED -> NEW -> ... (see --progress).
  4. --a2s : A2S_INFO with the 2020 challenge handshake.
  5. --rcon-password/--rcon-cmd : minimal Source RCON (TCP).

Final line (machine readable):
  SRCCLIENT_RESULT connected=0|1 rejected_reason=... held_seconds=N last_signon_state=N serverinfo_seen=0|1 ...

Engine references (all line numbers from nillerusr/source-engine master, read 2026-08-19):
  https://raw.githubusercontent.com/nillerusr/source-engine/master/engine/net_chan.cpp
      SendDatagram (~1575), ProcessPacketHeader (~2232), ProcessPacket (~2421),
      SendSubChannelData (~1169), ReadSubChannelData (~1312), UpdateSubChannels (~1451),
      BufferToShortChecksum (~1517), Shutdown (~358)
  https://raw.githubusercontent.com/nillerusr/source-engine/master/common/netmessages.cpp
      NET_SetConVar (~1136), NET_SignonState (~789), CLC_ClientInfo (~104),
      SVC_ServerInfo (~707), SVC_CreateStringTable (~1267), ...
  https://raw.githubusercontent.com/nillerusr/source-engine/master/engine/baseserver.cpp
      ProcessConnectionlessPacket (~660), ReplyChallenge (~980), ConnectClient (~435)
  https://raw.githubusercontent.com/nillerusr/source-engine/master/engine/baseclientstate.cpp
      SendConnectPacket (~495), ProcessConnectionlessPacket (~905), challenge request (~860)
  https://raw.githubusercontent.com/nillerusr/source-engine/master/engine/client.cpp
      CClientState::SetSignonState (~256: userinfo sent at CONNECTED), SendClientInfo (~177)
  https://raw.githubusercontent.com/nillerusr/source-engine/master/engine/sv_client.cpp
      CGameClient::SetSignonState (~718) -> CheckConnect (~872) -> ClientConnect
  https://raw.githubusercontent.com/nillerusr/source-engine/master/tier1/bitbuf.cpp
  https://raw.githubusercontent.com/nillerusr/source-engine/master/tier1/checksum_crc.cpp
  https://raw.githubusercontent.com/nillerusr/source-engine/master/tier1/lzss.cpp
  https://raw.githubusercontent.com/nillerusr/source-engine/master/engine/net_ws.cpp
      NET_GetLong (split packets ~1230), compressed packets (~1494)
See docs/source-connect-protocol.md in this repo for the packet layouts.
"""

import argparse
import binascii
import hashlib
import random
import select
import socket
import struct
import sys
import time
import zlib

# ---------------------------------------------------------------------------
# Constants (common/protocol.h, common/proto_oob.h, engine/net.h, engine/net_chan.h)
# ---------------------------------------------------------------------------
PROTOCOL_VERSION = 24                # retail CS:S v92 (mirror says 25, see docs)
CONNECTIONLESS_HEADER = 0xFFFFFFFF
NET_HEADER_FLAG_SPLITPACKET = -2
NET_HEADER_FLAG_COMPRESSEDPACKET = -3

A2S_GETCHALLENGE = b'q'
S2C_CHALLENGE = b'A'
C2S_CONNECT = b'k'
S2C_CONNECTION = b'B'
S2C_CONNREJECT = b'9'
A2S_INFO = b'T'
S2A_INFO_SRC = b'I'
S2C_MAGICVERSION = 0x5A4F4933

PROTOCOL_HASHEDCDKEY = 2
PROTOCOL_STEAM = 3
STEAM_KEYSIZE = 2048

PACKET_FLAG_RELIABLE = 1 << 0
PACKET_FLAG_COMPRESSED = 1 << 1
PACKET_FLAG_ENCRYPTED = 1 << 2
PACKET_FLAG_SPLIT = 1 << 3
PACKET_FLAG_CHOKED = 1 << 4
PACKET_FLAG_CHALLENGE = 1 << 5

NETMSG_TYPE_BITS = 6
NETMSG_LENGTH_BITS = 11
MAX_SUBCHANNELS = 8
MAX_STREAMS = 2
FRAGMENT_BITS = 8
FRAGMENT_SIZE = 1 << FRAGMENT_BITS          # 256
MAX_FILE_SIZE_BITS = 26
MAX_ROUTABLE_PAYLOAD = 1260
MIN_ROUTABLE_PAYLOAD = 16
NET_MAX_PAYLOAD = 288000
MAX_EDICT_BITS = 11
MAX_SERVER_CLASS_BITS = 9
MAX_EVENT_BITS = 9
MAX_DECAL_INDEX_BITS = 9
SP_MODEL_INDEX_BITS = 13
MAX_SOUND_INDEX_BITS = 14
DELTASIZE_BITS = 20
MAX_TABLES = 32
MAX_CUSTOM_FILES = 4
EVENT_INDEX_BITS = 8
COORD_INTEGER_BITS = 14
COORD_FRACTIONAL_BITS = 5

# net messages (shared)
net_NOP = 0
net_Disconnect = 1
net_File = 2
net_Tick = 3
net_StringCmd = 4
net_SetConVar = 5
net_SignonState = 6
# server -> client
svc_Print = 7
svc_ServerInfo = 8
svc_SendTable = 9
svc_ClassInfo = 10
svc_SetPause = 11
svc_CreateStringTable = 12
svc_UpdateStringTable = 13
svc_VoiceInit = 14
svc_VoiceData = 15
svc_Sounds = 17
svc_SetView = 18
svc_FixAngle = 19
svc_CrosshairAngle = 20
svc_BSPDecal = 21
svc_UserMessage = 23
svc_EntityMessage = 24
svc_GameEvent = 25
svc_PacketEntities = 26
svc_TempEntities = 27
svc_Prefetch = 28
svc_Menu = 29
svc_GameEventList = 30
svc_GetCvarValue = 31
svc_CmdKeyValues = 32
svc_SetPauseTimed = 33
# client -> server
clc_ClientInfo = 8
clc_Move = 9
clc_VoiceData = 10
clc_BaselineAck = 11
clc_ListenEvents = 12
clc_RespondCvarValue = 13
clc_FileCRCCheck = 14
clc_SaveReplay = 15
clc_CmdKeyValues = 16
clc_FileMD5Check = 17

SVC_NAMES = {
    0: 'net_NOP', 1: 'net_Disconnect', 2: 'net_File', 3: 'net_Tick', 4: 'net_StringCmd',
    5: 'net_SetConVar', 6: 'net_SignonState', 7: 'svc_Print', 8: 'svc_ServerInfo',
    9: 'svc_SendTable', 10: 'svc_ClassInfo', 11: 'svc_SetPause', 12: 'svc_CreateStringTable',
    13: 'svc_UpdateStringTable', 14: 'svc_VoiceInit', 15: 'svc_VoiceData', 17: 'svc_Sounds',
    18: 'svc_SetView', 19: 'svc_FixAngle', 20: 'svc_CrosshairAngle', 21: 'svc_BSPDecal',
    23: 'svc_UserMessage', 24: 'svc_EntityMessage', 25: 'svc_GameEvent',
    26: 'svc_PacketEntities', 27: 'svc_TempEntities', 28: 'svc_Prefetch', 29: 'svc_Menu',
    30: 'svc_GameEventList', 31: 'svc_GetCvarValue', 32: 'svc_CmdKeyValues',
    33: 'svc_SetPauseTimed',
}

SIGNONSTATE_NONE = 0
SIGNONSTATE_CHALLENGE = 1
SIGNONSTATE_CONNECTED = 2
SIGNONSTATE_NEW = 3
SIGNONSTATE_PRESPAWN = 4
SIGNONSTATE_SPAWN = 5
SIGNONSTATE_FULL = 6
SIGNONSTATE_CHANGELEVEL = 7
SIGNON_NAMES = {0: 'NONE', 1: 'CHALLENGE', 2: 'CONNECTED', 3: 'NEW', 4: 'PRESPAWN',
                5: 'SPAWN', 6: 'FULL', 7: 'CHANGELEVEL'}

SUBCHANNEL_FREE = 0
SUBCHANNEL_TOSEND = 1
SUBCHANNEL_WAITING = 2
SUBCHANNEL_DIRTY = 3

# Known rejection tokens (localization keys the engine sends as reject reason)
REJECT_TOKENS = {
    '#GameUI_ServerRejectBadChallenge': 'bad challenge number',
    '#GameUI_ServerRejectOldVersion': 'client protocol/version too old',
    '#GameUI_ServerRejectNewVersion': 'client protocol/version too new',
    '#GameUI_ServerRejectLANRestrict': 'LAN restriction (sv_lan 1, not same class B / private IP)',
    '#GameUI_ServerRejectBadPassword': 'bad password',
    '#GameUI_ServerRejectServerFull': 'server full',
    '#GameUI_ServerRejectInvalidConnection': 'invalid auth protocol',
    '#GameUI_ServerRejectInvalidCertLen': 'cdkey hash must be 32 chars (HASHEDCDKEY)',
    '#GameUI_ServerRejectInvalidSteamCertLen': 'steam ticket length invalid (0 or >= 2048)',
    '#GameUI_ServerRejectSteam': 'steam auth (NotifyClientConnect) failed and sv_lan is 0',
    '#GameUI_ServerRejectBanned': 'banned',
    '#GameUI_ServerRejectFailedChannel': 'could not create netchannel',
    '#GameUI_ServerRejectBadSteamKey': 'bad steam key length',
    '#GameUI_ServerRejectGS': 'NotifyLocalClientConnect failed',
    '#GameUI_ServerRejectMustUseMatchmaking': 'GC lobby required',
}

DEFAULT_PRODUCT_VERSION = '6630498'   # steam.inf PatchVersion of CS:S v92 (docs/evidence/01-buildid.txt)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
T0 = time.time()
VERBOSE = 0


def log(msg, level=0):
    if level <= VERBOSE:
        sys.stdout.write('[%8.3f] %s\n' % (time.time() - T0, msg))
        sys.stdout.flush()


def hexdump(b, maxlen=96):
    h = binascii.hexlify(bytes(b[:maxlen])).decode()
    s = ' '.join(h[i:i + 2] for i in range(0, len(h), 2))
    if len(b) > maxlen:
        s += ' ... (%d bytes)' % len(b)
    return s


# ---------------------------------------------------------------------------
# bf_write / bf_read  (tier1/bitbuf.cpp semantics: LSB-first bit stream packed
# into little-endian 32-bit words == bit i lives in byte i>>3, bit i&7)
# ---------------------------------------------------------------------------
class BitWriter(object):
    def __init__(self):
        self.buf = bytearray()
        self.pos = 0          # bit cursor

    # --- primitives ---
    def write_ubits(self, value, nbits):
        if nbits <= 0:
            return
        value &= (1 << nbits) - 1
        end = self.pos + nbits
        need = (end + 7) >> 3
        if len(self.buf) < need:
            self.buf.extend(b'\x00' * (need - len(self.buf)))
        bs = self.pos >> 3
        be = need
        chunk = int.from_bytes(self.buf[bs:be], 'little')
        chunk |= value << (self.pos & 7)
        self.buf[bs:be] = chunk.to_bytes(be - bs, 'little')
        self.pos = end

    def write_sbits(self, value, nbits):
        self.write_ubits(value & ((1 << nbits) - 1), nbits)

    def write_one_bit(self, v):
        self.write_ubits(1 if v else 0, 1)

    def write_byte(self, v):
        self.write_ubits(v & 0xFF, 8)

    def write_char(self, v):
        self.write_ubits(v & 0xFF, 8)

    def write_short(self, v):
        self.write_ubits(v & 0xFFFF, 16)

    def write_word(self, v):
        self.write_ubits(v & 0xFFFF, 16)

    def write_long(self, v):
        self.write_ubits(v & 0xFFFFFFFF, 32)

    def write_float(self, f):
        self.write_ubits(struct.unpack('<I', struct.pack('<f', f))[0], 32)

    def write_bytes(self, data):
        for b in bytes(data):
            self.write_ubits(b, 8)

    def write_bits(self, data, nbits):
        """bf_write::WriteBits: copy nbits from a byte buffer (whole bytes then the
        low bits of the last partial byte)."""
        data = bytes(data)
        nbytes = nbits >> 3
        for i in range(nbytes):
            self.write_ubits(data[i], 8)
        rem = nbits & 7
        if rem:
            self.write_ubits(data[nbytes] & ((1 << rem) - 1), rem)

    def write_string(self, s):
        if isinstance(s, str):
            s = s.encode('utf-8', 'replace')
        for b in s:
            self.write_ubits(b, 8)
        self.write_ubits(0, 8)

    def write_varint32(self, v):
        v &= 0xFFFFFFFF
        while v > 0x7F:
            self.write_ubits((v & 0x7F) | 0x80, 8)
            v >>= 7
        self.write_ubits(v & 0x7F, 8)

    # --- helpers ---
    def num_bits(self):
        return self.pos

    def num_bytes(self):
        return (self.pos + 7) >> 3

    def data(self):
        return bytes(self.buf[:self.num_bytes()])

    def patch_byte(self, byte_index, value):
        self.buf[byte_index] = value & 0xFF

    def patch_short(self, byte_index, value):
        self.buf[byte_index] = value & 0xFF
        self.buf[byte_index + 1] = (value >> 8) & 0xFF


class BitReadError(Exception):
    pass


class BitReader(object):
    def __init__(self, data, nbits=None):
        self.data = bytes(data)
        self.nbits = len(self.data) * 8 if nbits is None else nbits
        self.pos = 0
        self.overflowed = False

    def bits_left(self):
        return self.nbits - self.pos

    def bytes_left(self):
        return self.bits_left() >> 3

    def read_ubits(self, nbits):
        if nbits == 0:
            return 0
        end = self.pos + nbits
        if end > self.nbits:
            self.overflowed = True
            self.pos = self.nbits
            raise BitReadError('read past end (%d bits wanted, %d left)' % (nbits, self.nbits - self.pos))
        bs = self.pos >> 3
        be = (end + 7) >> 3
        chunk = int.from_bytes(self.data[bs:be], 'little')
        v = (chunk >> (self.pos & 7)) & ((1 << nbits) - 1)
        self.pos = end
        return v

    def peek_ubits(self, nbits):
        save = self.pos
        try:
            return self.read_ubits(nbits)
        finally:
            self.pos = save
            self.overflowed = False

    def read_sbits(self, nbits):
        v = self.read_ubits(nbits)
        if v & (1 << (nbits - 1)):
            v -= 1 << nbits
        return v

    def read_one_bit(self):
        return self.read_ubits(1)

    def read_byte(self):
        return self.read_ubits(8)

    def read_char(self):
        v = self.read_ubits(8)
        return v - 256 if v > 127 else v

    def read_short(self):
        return self.read_sbits(16)

    def read_word(self):
        return self.read_ubits(16)

    def read_long(self):
        return self.read_sbits(32)

    def read_ulong(self):
        return self.read_ubits(32)

    def read_float(self):
        return struct.unpack('<f', struct.pack('<I', self.read_ubits(32)))[0]

    def read_bytes(self, n):
        return bytes(self.read_ubits(8) for _ in range(n))

    def read_string(self, maxlen=4096):
        out = bytearray()
        while True:
            c = self.read_ubits(8)
            if c == 0:
                break
            if len(out) < maxlen:
                out.append(c)
        return out.decode('utf-8', 'replace')

    def read_varint32(self):
        result = 0
        shift = 0
        for _ in range(5):
            b = self.read_ubits(8)
            result |= (b & 0x7F) << shift
            if not (b & 0x80):
                break
            shift += 7
        return result & 0xFFFFFFFF

    def seek_relative(self, nbits):
        end = self.pos + nbits
        if end > self.nbits or end < 0:
            self.overflowed = True
            raise BitReadError('seek past end')
        self.pos = end

    def read_bit_coord(self):
        intval = self.read_one_bit()
        fractval = self.read_one_bit()
        value = 0.0
        if intval or fractval:
            sign = self.read_one_bit()
            if intval:
                intval = self.read_ubits(COORD_INTEGER_BITS) + 1
            if fractval:
                fractval = self.read_ubits(COORD_FRACTIONAL_BITS)
            value = intval + fractval * (1.0 / (1 << COORD_FRACTIONAL_BITS))
            if sign:
                value = -value
        return value

    def read_bit_vec3_coord(self):
        xf = self.read_one_bit()
        yf = self.read_one_bit()
        zf = self.read_one_bit()
        x = self.read_bit_coord() if xf else 0.0
        y = self.read_bit_coord() if yf else 0.0
        z = self.read_bit_coord() if zf else 0.0
        return (x, y, z)

    def read_bit_angle(self, nbits):
        return self.read_ubits(nbits) * (360.0 / (1 << nbits))


def q_log2(v):
    """mathlib Q_log2: floor(log2(v)), 0 for v<=1."""
    a = 0
    v = int(v)
    while v > 1:
        v >>= 1
        a += 1
    return a


# ---------------------------------------------------------------------------
# Checksums / compression
# ---------------------------------------------------------------------------
def crc16_fold(data):
    """net_chan.cpp BufferToShortChecksum: CRC32 (zlib/IEEE, same table as
    tier1/checksum_crc.cpp) folded to 16 bits: low16 ^ high16."""
    crc = zlib.crc32(bytes(data)) & 0xFFFFFFFF
    return ((crc & 0xFFFF) ^ ((crc >> 16) & 0xFFFF)) & 0xFFFF


def snappy_raw_decompress(src, expected=None):
    """Raw Snappy stream decoder (no framing).  engine/common.cpp prefixes it
    with the 4-byte id 'SNAP'."""
    src = bytes(src)
    n = len(src)
    i = 0
    # varint32 uncompressed length
    ulen = 0
    shift = 0
    while True:
        if i >= n:
            raise ValueError('snappy: truncated length')
        b = src[i]
        i += 1
        ulen |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            break
    out = bytearray()
    while i < n:
        tag = src[i]
        i += 1
        t = tag & 3
        if t == 0:
            ln = (tag >> 2) + 1
            if ln > 60:
                nb = ln - 60
                ln = int.from_bytes(src[i:i + nb], 'little') + 1
                i += nb
            out += src[i:i + ln]
            i += ln
        else:
            if t == 1:
                ln = ((tag >> 2) & 7) + 4
                off = ((tag >> 5) << 8) | src[i]
                i += 1
            elif t == 2:
                ln = (tag >> 2) + 1
                off = int.from_bytes(src[i:i + 2], 'little')
                i += 2
            else:
                ln = (tag >> 2) + 1
                off = int.from_bytes(src[i:i + 4], 'little')
                i += 4
            if off == 0 or off > len(out):
                raise ValueError('snappy: bad offset')
            start = len(out) - off
            if ln <= off:
                out += out[start:start + ln]
            else:
                for k in range(ln):
                    out.append(out[start + k])
    if len(out) != ulen:
        raise ValueError('snappy: length mismatch %d != %d' % (len(out), ulen))
    if expected is not None and len(out) != expected:
        raise ValueError('snappy: expected %d got %d' % (expected, len(out)))
    return bytes(out)


def lzss_decompress(src):
    """tier1/lzss.cpp CLZSS::SafeUncompress.  src starts with 'LZSS' + uint32 actualSize."""
    src = bytes(src)
    if len(src) < 8 or src[:4] != b'LZSS':
        raise ValueError('lzss: bad header')
    actual = struct.unpack_from('<I', src, 4)[0]
    i = 8
    out = bytearray()
    cmd = 0
    getcmd = 0
    n = len(src)
    while True:
        if not getcmd:
            if i >= n:
                raise ValueError('lzss: truncated')
            cmd = src[i]
            i += 1
        getcmd = (getcmd + 1) & 7
        if cmd & 1:
            if i + 1 >= n:
                raise ValueError('lzss: truncated pair')
            position = src[i] << 4
            position |= src[i + 1] >> 4
            count = (src[i + 1] & 0x0F) + 1
            i += 2
            if count == 1:
                break
            start = len(out) - position - 1
            if start < 0:
                raise ValueError('lzss: bad back reference')
            for k in range(count):
                out.append(out[start + k])
        else:
            if i >= n:
                raise ValueError('lzss: truncated literal')
            out.append(src[i])
            i += 1
        cmd >>= 1
    if len(out) != actual:
        raise ValueError('lzss: size mismatch %d != %d' % (len(out), actual))
    return bytes(out)


def decompress_block(src, expected=None):
    """COM_BufferToBufferDecompress: dispatch on the 4-byte id."""
    src = bytes(src)
    if src[:4] == b'SNAP':
        return snappy_raw_decompress(src[4:], expected)
    if src[:4] == b'LZSS':
        return lzss_decompress(src)
    raise ValueError('unknown compression id %r' % src[:4])


# ---------------------------------------------------------------------------
# Connectionless (OOB) packets
# ---------------------------------------------------------------------------
def build_getchallenge(client_challenge, fmt='binary'):
    """baseclientstate.cpp ~860: header, 'q', long(client challenge), "0000000000"\\0.
    fmt='text' sends the older/CS:GO-style "connect0x%08X" string instead (fallback)."""
    w = BitWriter()
    w.write_long(CONNECTIONLESS_HEADER)
    w.write_byte(ord(A2S_GETCHALLENGE))
    if fmt == 'text':
        w.write_string('connect0x%08X' % (client_challenge & 0xFFFFFFFF))
    else:
        w.write_long(client_challenge)
        w.write_string('0000000000')
    return w.data()


def parse_challenge_reply(data):
    """S2C_CHALLENGE 'A' (baseserver.cpp ReplyChallenge ~980)."""
    r = BitReader(data)
    res = {'raw': data}
    hdr = r.read_ulong()
    if hdr != CONNECTIONLESS_HEADER:
        raise ValueError('not connectionless')
    c = r.read_byte()
    if c != ord(S2C_CHALLENGE):
        raise ValueError('not S2C_CHALLENGE')
    res['magic'] = r.read_ulong()
    res['challenge'] = r.read_ulong()
    res['client_challenge'] = r.read_ulong()
    res['authprotocol'] = r.read_long()
    res['steam2_keysize'] = None
    res['gs_steamid'] = None
    res['vac_secure'] = None
    try:
        if res['authprotocol'] == PROTOCOL_STEAM:
            res['steam2_keysize'] = r.read_short()
            if r.bytes_left() >= 8:
                res['gs_steamid'] = int.from_bytes(r.read_bytes(8), 'little')
            if r.bytes_left() >= 1:
                res['vac_secure'] = r.read_byte()
        res['padding'] = r.read_string()
    except BitReadError:
        res['padding'] = None
    res['trailing_bytes'] = r.bytes_left()
    return res


def build_connect(authproto, challenge, client_challenge, name, password, version,
                  cdkey='', ticket=b'', ticket_as_string=False):
    """C2S_CONNECT 'k' (baseclientstate.cpp SendConnectPacket ~495)."""
    w = BitWriter()
    w.write_long(CONNECTIONLESS_HEADER)
    w.write_byte(ord(C2S_CONNECT))
    w.write_long(PROTOCOL_VERSION)
    w.write_long(authproto)
    w.write_long(challenge)
    w.write_long(client_challenge)
    w.write_string(name)
    w.write_string(password)
    w.write_string(version)
    if authproto == PROTOCOL_HASHEDCDKEY:
        w.write_string(cdkey)
    elif authproto == PROTOCOL_STEAM:
        if ticket_as_string:
            # nillerusr-mirror style: server does ReadString(cdkey) for every auth protocol
            w.write_string(ticket)
        else:
            # retail style (PrepareSteamConnectResponse): short len + bytes
            w.write_short(len(ticket))
            w.write_bytes(ticket)
    else:
        w.write_string(cdkey)
    return w.data()


def build_a2s_info(challenge=None):
    pkt = b'\xff\xff\xff\xffTSource Engine Query\x00'
    if challenge is not None:
        pkt += challenge
    return pkt


def parse_a2s_info(d):
    """S2A_INFO_SRC 'I' (Steam A2S_INFO reply). Returns dict."""
    p = 5
    res = {'protocol': d[p]}
    p += 1

    def cstr():
        nonlocal p
        e = d.index(b'\x00', p)
        s = d[p:e].decode('utf-8', 'replace')
        p = e + 1
        return s
    res['name'] = cstr()
    res['map'] = cstr()
    res['folder'] = cstr()
    res['game'] = cstr()
    res['appid'] = struct.unpack_from('<H', d, p)[0]
    p += 2
    players, maxp, bots, stype, env, vis, vac = struct.unpack_from('<BBBccBB', d, p)
    p += 7
    res.update(players=players, max_players=maxp, bots=bots, server_type=stype.decode(),
               environment=env.decode(), password=vis, vac=vac)
    res['version'] = cstr()
    if p < len(d):
        edf = d[p]
        p += 1
        res['edf'] = edf
        if edf & 0x80:
            res['port'] = struct.unpack_from('<H', d, p)[0]
            p += 2
        if edf & 0x10:
            res['steamid'] = struct.unpack_from('<Q', d, p)[0]
            p += 8
        if edf & 0x40:
            res['sourcetv_port'] = struct.unpack_from('<H', d, p)[0]
            p += 2
            res['sourcetv_name'] = cstr()
        if edf & 0x20:
            res['keywords'] = cstr()
        if edf & 0x01:
            res['gameid'] = struct.unpack_from('<Q', d, p)[0]
            p += 8
    return res


def a2s_info(host, port, timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        t0 = time.time()
        s.sendto(build_a2s_info(), (host, port))
        d, _ = s.recvfrom(4096)
        if d[4:5] == S2C_CHALLENGE:   # 2020 challenge handshake
            s.sendto(build_a2s_info(d[5:9]), (host, port))
            d, _ = s.recvfrom(4096)
        rtt = (time.time() - t0) * 1000.0
        if d[4:5] != S2A_INFO_SRC:
            raise ValueError('unexpected A2S reply %r' % d[:8])
        res = parse_a2s_info(d)
        res['rtt_ms'] = rtt
        return res
    finally:
        s.close()


# ---------------------------------------------------------------------------
# RCON (Source RCON protocol, TCP)
# ---------------------------------------------------------------------------
SERVERDATA_AUTH = 3
SERVERDATA_AUTH_RESPONSE = 2
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_RESPONSE_VALUE = 0


def rcon_packet(pid, ptype, body):
    b = body.encode('utf-8', 'replace') if isinstance(body, str) else body
    payload = struct.pack('<ii', pid, ptype) + b + b'\x00\x00'
    return struct.pack('<i', len(payload)) + payload


def rcon_read_packets(sock, timeout):
    """Read complete RCON packets until the socket is idle for `timeout`."""
    sock.settimeout(timeout)
    buf = b''
    pkts = []
    while True:
        try:
            d = sock.recv(65536)
        except socket.timeout:
            break
        if not d:
            break
        buf += d
        while len(buf) >= 4:
            ln = struct.unpack_from('<i', buf)[0]
            if ln < 10 or len(buf) < 4 + ln:
                break
            pid, ptype = struct.unpack_from('<ii', buf, 4)
            body = buf[12:4 + ln - 2]
            pkts.append((pid, ptype, body.decode('utf-8', 'replace')))
            buf = buf[4 + ln:]
        sock.settimeout(0.4)
    return pkts


def rcon(host, port, password, cmd, timeout=5.0):
    s = socket.create_connection((host, port), timeout=timeout)
    try:
        s.sendall(rcon_packet(1, SERVERDATA_AUTH, password))
        pkts = rcon_read_packets(s, timeout)
        auth_ok = any(pt == SERVERDATA_AUTH_RESPONSE and pid == 1 for pid, pt, _ in pkts)
        auth_fail = any(pt == SERVERDATA_AUTH_RESPONSE and pid == -1 for pid, pt, _ in pkts)
        if auth_fail or not auth_ok:
            return False, 'RCON auth failed (packets=%r)' % (pkts,)
        s.sendall(rcon_packet(2, SERVERDATA_EXECCOMMAND, cmd))
        pkts = rcon_read_packets(s, timeout)
        out = ''.join(body for pid, pt, body in pkts if pt == SERVERDATA_RESPONSE_VALUE)
        return True, out
    finally:
        s.close()


# ---------------------------------------------------------------------------
# Net message writers (client -> server)
# ---------------------------------------------------------------------------
def msg_setconvar(w, pairs):
    """NET_SetConVar::WriteToBuffer (netmessages.cpp ~1136): 6-bit id, byte count, key/value strings."""
    w.write_ubits(net_SetConVar, NETMSG_TYPE_BITS)
    w.write_byte(len(pairs))
    for k, v in pairs:
        w.write_string(k)
        w.write_string(v)


def msg_signonstate(w, state, spawncount):
    w.write_ubits(net_SignonState, NETMSG_TYPE_BITS)
    w.write_byte(state)
    w.write_long(spawncount)


def msg_stringcmd(w, cmd):
    w.write_ubits(net_StringCmd, NETMSG_TYPE_BITS)
    w.write_string(cmd)


def msg_disconnect(w, reason):
    w.write_ubits(net_Disconnect, NETMSG_TYPE_BITS)
    w.write_string(reason)


def msg_file_deny(w, transfer_id, filename):
    w.write_ubits(net_File, NETMSG_TYPE_BITS)
    w.write_ubits(transfer_id, 32)
    w.write_string(filename)
    w.write_one_bit(0)


def msg_clientinfo(w, server_count, sendtable_crc, friends_id=0, friends_name='', replay_bit=True):
    """CLC_ClientInfo::WriteToBuffer (netmessages.cpp ~104)."""
    w.write_ubits(clc_ClientInfo, NETMSG_TYPE_BITS)
    w.write_long(server_count)
    w.write_long(sendtable_crc)
    w.write_one_bit(0)                 # m_bIsHLTV
    w.write_long(friends_id)
    w.write_string(friends_name)
    for _ in range(MAX_CUSTOM_FILES):
        w.write_one_bit(0)             # no custom file CRCs
    if replay_bit:
        w.write_one_bit(0)             # m_bIsReplay (REPLAY_ENABLED builds)


def msg_respond_cvar(w, cookie, status, name, value):
    w.write_ubits(clc_RespondCvarValue, NETMSG_TYPE_BITS)
    w.write_sbits(cookie, 32)
    w.write_sbits(status, 4)
    w.write_string(name)
    w.write_string(value)


# ---------------------------------------------------------------------------
# Net message parser (server -> client).  Returns list of dicts; stops at the
# first message it cannot parse (and says so) so that the channel stays alive.
# ---------------------------------------------------------------------------
CLC_NAMES = {8: 'clc_ClientInfo', 9: 'clc_Move', 10: 'clc_VoiceData', 11: 'clc_BaselineAck',
             12: 'clc_ListenEvents', 13: 'clc_RespondCvarValue', 14: 'clc_FileCRCCheck',
             15: 'clc_SaveReplay', 16: 'clc_CmdKeyValues', 17: 'clc_FileMD5Check'}


class MsgParser(object):
    def __init__(self, side='svc'):
        self.side = side         # 'svc' = parse server->client stream, 'clc' = client->server (fakeserver)
        self.replay_bit = None   # None = autodetect on svc_ServerInfo

    def _parse_clc(self, r, cmd, m):
        if cmd == clc_ClientInfo:
            m['server_count'] = r.read_long()
            m['sendtable_crc'] = r.read_ulong()
            m['is_hltv'] = r.read_one_bit()
            m['friends_id'] = r.read_ulong()
            m['friends_name'] = r.read_string()
            m['custom_files'] = [r.read_ubits(32) if r.read_one_bit() else 0 for _ in range(MAX_CUSTOM_FILES)]
            if self.replay_bit is None or self.replay_bit:
                m['is_replay'] = r.read_one_bit()
        elif cmd == clc_RespondCvarValue:
            m['cookie'] = r.read_sbits(32)
            m['status'] = r.read_sbits(4)
            m['cvar'] = r.read_string()
            m['value'] = r.read_string()
        elif cmd == clc_BaselineAck:
            m['tick'] = r.read_long()
            m['baseline'] = r.read_ubits(1)
        elif cmd == clc_ListenEvents:
            m['mask'] = [r.read_ulong() for _ in range((1 << MAX_EVENT_BITS) // 32)]
        else:
            return 'unknown/unsupported clc message id %d' % cmd
        return None

    def parse(self, r):
        msgs = []
        try:
            while r.bits_left() >= NETMSG_TYPE_BITS:
                cmd = r.read_ubits(NETMSG_TYPE_BITS)
                if self.side == 'clc' and cmd > net_SignonState:
                    m = {'id': cmd, 'name': CLC_NAMES.get(cmd, 'unknown(%d)' % cmd)}
                    err = self._parse_clc(r, cmd, m)
                    if err:
                        return msgs, err
                    msgs.append(m)
                    continue
                m = {'id': cmd, 'name': SVC_NAMES.get(cmd, 'unknown(%d)' % cmd)}
                if cmd == net_NOP:
                    continue
                elif cmd == net_Disconnect:
                    m['reason'] = r.read_string()
                    msgs.append(m)
                    return msgs, None
                elif cmd == net_File:
                    m['transfer_id'] = r.read_ubits(32)
                    m['filename'] = r.read_string()
                    m['request'] = r.read_one_bit()
                elif cmd == net_Tick:
                    m['tick'] = r.read_long()
                    m['host_frametime'] = r.read_ubits(16) / 100000.0
                    m['host_frametime_std'] = r.read_ubits(16) / 100000.0
                elif cmd == net_StringCmd:
                    m['command'] = r.read_string()
                elif cmd == net_SetConVar:
                    n = r.read_byte()
                    cv = []
                    for _ in range(n):
                        k = r.read_string()
                        v = r.read_string()
                        cv.append((k, v))
                    m['convars'] = cv
                elif cmd == net_SignonState:
                    m['state'] = r.read_byte()
                    m['spawncount'] = r.read_long()
                elif cmd == svc_Print:
                    m['text'] = r.read_string()
                elif cmd == svc_ServerInfo:
                    m['protocol'] = r.read_short()
                    m['server_count'] = r.read_long()
                    m['is_hltv'] = r.read_one_bit()
                    m['is_dedicated'] = r.read_one_bit()
                    m['client_crc_legacy'] = r.read_ulong()
                    m['max_classes'] = r.read_word()
                    m['map_md5'] = binascii.hexlify(r.read_bytes(16)).decode()
                    m['player_slot'] = r.read_byte()
                    m['max_clients'] = r.read_byte()
                    m['tick_interval'] = r.read_float()
                    m['os'] = chr(r.read_ubits(8))
                    m['game_dir'] = r.read_string()
                    m['map_name'] = r.read_string()
                    m['sky_name'] = r.read_string()
                    m['host_name'] = r.read_string()
                    # REPLAY_ENABLED builds append one bit (m_bIsReplay). SendServerInfo
                    # always writes a NET_Tick right after svc_ServerInfo, so we can
                    # auto-detect: look for the 6-bit id '3' with and without the bit.
                    if self.replay_bit is None:
                        without = r.peek_ubits(NETMSG_TYPE_BITS) if r.bits_left() >= 6 else -1
                        save = r.pos
                        withb = -1
                        if r.bits_left() >= 7:
                            r.read_one_bit()
                            withb = r.peek_ubits(NETMSG_TYPE_BITS)
                        r.pos = save
                        if withb == net_Tick and without != net_Tick:
                            self.replay_bit = True
                        elif without == net_Tick and withb != net_Tick:
                            self.replay_bit = False
                        else:
                            self.replay_bit = True   # assume REPLAY_ENABLED (replay_srv.so ships with CS:S)
                        m['replay_bit_autodetect'] = self.replay_bit
                    if self.replay_bit:
                        m['is_replay'] = r.read_one_bit()
                elif cmd == svc_SendTable:
                    m['needs_decoder'] = r.read_one_bit()
                    ln = r.read_short()
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_ClassInfo:
                    n = r.read_short()
                    m['num_classes'] = n
                    bits = q_log2(n) + 1
                    m['create_on_client'] = r.read_one_bit()
                    if not m['create_on_client']:
                        classes = []
                        for _ in range(n):
                            cid = r.read_ubits(bits)
                            cn = r.read_string()
                            dt = r.read_string()
                            classes.append((cid, cn, dt))
                        m['classes'] = len(classes)
                elif cmd == svc_SetPause:
                    m['paused'] = r.read_one_bit()
                elif cmd == svc_SetPauseTimed:
                    m['paused'] = r.read_one_bit()
                    m['expire'] = r.read_float()
                elif cmd == svc_CreateStringTable:
                    if r.peek_ubits(8) == ord(':'):
                        r.read_byte()
                        m['is_filenames'] = True
                    m['table'] = r.read_string()
                    maxent = r.read_word()
                    m['max_entries'] = maxent
                    m['num_entries'] = r.read_ubits(q_log2(maxent) + 1)
                    ln = r.read_varint32()          # protocol > 23
                    m['bits'] = ln
                    m['user_data_fixed'] = r.read_one_bit()
                    if m['user_data_fixed']:
                        r.read_ubits(12)
                        r.read_ubits(4)
                    m['compressed'] = r.read_one_bit()   # protocol > 14
                    r.seek_relative(ln)
                elif cmd == svc_UpdateStringTable:
                    m['table_id'] = r.read_ubits(q_log2(MAX_TABLES))
                    if r.read_one_bit():
                        m['changed'] = r.read_word()
                    else:
                        m['changed'] = 1
                    ln = r.read_ubits(20)
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_VoiceInit:
                    m['codec'] = r.read_string()
                    q = r.read_byte()
                    if q == 255:
                        m['sample_rate'] = r.read_short()
                    else:
                        m['quality'] = q
                elif cmd == svc_VoiceData:
                    m['from_client'] = r.read_byte()
                    m['proximity'] = r.read_byte()
                    ln = r.read_word()
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_Sounds:
                    rel = r.read_one_bit()
                    if rel:
                        m['num'] = 1
                        ln = r.read_ubits(8)
                    else:
                        m['num'] = r.read_ubits(8)
                        ln = r.read_ubits(16)
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_SetView:
                    m['entity'] = r.read_ubits(MAX_EDICT_BITS)
                elif cmd == svc_FixAngle:
                    m['relative'] = r.read_one_bit()
                    m['angle'] = (r.read_bit_angle(16), r.read_bit_angle(16), r.read_bit_angle(16))
                elif cmd == svc_CrosshairAngle:
                    m['angle'] = (r.read_bit_angle(16), r.read_bit_angle(16), r.read_bit_angle(16))
                elif cmd == svc_BSPDecal:
                    m['pos'] = r.read_bit_vec3_coord()
                    m['decal'] = r.read_ubits(MAX_DECAL_INDEX_BITS)
                    if r.read_one_bit():
                        m['entity'] = r.read_ubits(MAX_EDICT_BITS)
                        m['model'] = r.read_ubits(SP_MODEL_INDEX_BITS)
                    m['low_priority'] = r.read_one_bit()
                elif cmd == svc_UserMessage:
                    m['type'] = r.read_byte()
                    ln = r.read_ubits(NETMSG_LENGTH_BITS)
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_EntityMessage:
                    m['entity'] = r.read_ubits(MAX_EDICT_BITS)
                    m['class'] = r.read_ubits(MAX_SERVER_CLASS_BITS)
                    ln = r.read_ubits(NETMSG_LENGTH_BITS)
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_GameEvent:
                    ln = r.read_ubits(NETMSG_LENGTH_BITS)
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_PacketEntities:
                    m['max_entries'] = r.read_ubits(MAX_EDICT_BITS)
                    m['is_delta'] = r.read_one_bit()
                    if m['is_delta']:
                        m['delta_from'] = r.read_long()
                    m['baseline'] = r.read_ubits(1)
                    m['updated'] = r.read_ubits(MAX_EDICT_BITS)
                    ln = r.read_ubits(DELTASIZE_BITS)
                    m['bits'] = ln
                    m['update_baseline'] = r.read_one_bit()
                    r.seek_relative(ln)
                elif cmd == svc_TempEntities:
                    m['num'] = r.read_ubits(EVENT_INDEX_BITS)
                    ln = r.read_varint32()          # protocol > 23
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_Prefetch:
                    m['sound'] = r.read_ubits(MAX_SOUND_INDEX_BITS)   # protocol > 22
                elif cmd == svc_Menu:
                    m['type'] = r.read_short()
                    ln = r.read_word()
                    m['bytes'] = ln
                    r.read_bytes(ln)
                elif cmd == svc_GameEventList:
                    m['num_events'] = r.read_ubits(MAX_EVENT_BITS)
                    ln = r.read_ubits(20)
                    m['bits'] = ln
                    r.seek_relative(ln)
                elif cmd == svc_GetCvarValue:
                    m['cookie'] = r.read_sbits(32)
                    m['cvar'] = r.read_string()
                elif cmd == svc_CmdKeyValues:
                    n = r.read_long()
                    m['bytes'] = n
                    if n <= 0 or n > r.bytes_left():
                        return msgs, 'svc_CmdKeyValues bad length %d' % n
                    r.seek_relative(n * 8)
                else:
                    return msgs, 'unknown/unsupported net message id %d' % cmd
                msgs.append(m)
        except BitReadError as e:
            return msgs, 'bit read error: %s' % e
        return msgs, None


# ---------------------------------------------------------------------------
# NetChannel (port of the bits of CNetChan the client needs)
# ---------------------------------------------------------------------------
class SubChannel(object):
    __slots__ = ('index', 'state', 'send_seq', 'start', 'num')

    def __init__(self, index):
        self.index = index
        self.free()

    def free(self):
        self.state = SUBCHANNEL_FREE
        self.send_seq = -1
        self.start = [-1] * MAX_STREAMS
        self.num = [0] * MAX_STREAMS


class DataFragments(object):
    def __init__(self, data):
        self.buffer = bytes(data)
        self.bytes = len(self.buffer)
        self.num_fragments = (self.bytes + FRAGMENT_SIZE - 1) // FRAGMENT_SIZE
        self.acked = 0
        self.pending = 0


class ReceiveList(object):
    def __init__(self):
        self.reset()

    def reset(self):
        self.buffer = None
        self.bytes = 0
        self.num_fragments = 0
        self.acked = 0
        self.compressed = False
        self.uncompressed_size = 0
        self.filename = ''
        self.transfer_id = 0


class NetChannel(object):
    def __init__(self, sock, addr, challenge, handler, side='svc', send_challenge=True):
        self.sock = sock
        self.addr = addr
        self.challenge = challenge & 0xFFFFFFFF
        self.send_challenge = send_challenge   # PACKET_FLAG_CHALLENGE + challenge long in every packet
        self.handler = handler
        self.out_seq = 1
        self.in_seq = 0
        self.out_seq_ack = 0
        self.out_rel = 0
        self.in_rel = 0
        self.choked = 0
        self.subchannels = [SubChannel(i) for i in range(MAX_SUBCHANNELS)]
        self.waiting = [[] for _ in range(MAX_STREAMS)]
        self.recv = [ReceiveList() for _ in range(MAX_STREAMS)]
        self.reliable = BitWriter()
        self.unreliable = BitWriter()
        self.max_reliable_payload = MAX_ROUTABLE_PAYLOAD   # net_maxfragments
        self.packets_out = 0
        self.packets_in = 0
        self.bytes_in = 0
        self.bytes_out = 0
        self.last_received = time.time()
        self.drops_seen = 0
        self.reliable_sent_blocks = 0
        self.reliable_acked_blocks = 0
        self.reliable_resends = 0
        self.split = {}   # seq -> (count, size, parts dict)
        self.stream_contains_challenge = False
        self.reply_wanted = False      # set when a packet with reliable data was accepted (ack it promptly)
        self.parser = MsgParser(side)

    # ---- outgoing reliable data -------------------------------------------
    def queue_reliable(self, writer_fn):
        writer_fn(self.reliable)

    def _create_fragments_from_buffer(self, w):
        """CreateFragmentsFromBuffer (~1007) without the merge optimisation."""
        bw = BitWriter()
        bw.write_bits(w.data(), w.num_bits())
        rem = bw.num_bits() % 8
        if 0 < rem <= (8 - NETMSG_TYPE_BITS):
            bw.write_ubits(net_NOP, NETMSG_TYPE_BITS)
        data = bw.data()
        self.waiting[0].append(DataFragments(data))
        self.reliable_sent_blocks += 1
        log('netchan: queued reliable block %d bytes (%d fragments)' % (len(data), self.waiting[0][-1].num_fragments), 1)

    def _free_subchannel(self):
        for s in self.subchannels:
            if s.state == SUBCHANNEL_FREE:
                return s
        return None

    def _update_subchannels(self):
        """UpdateSubChannels (~1451)."""
        free = self._free_subchannel()
        if free is None:
            return
        send_max = self.max_reliable_payload // FRAGMENT_SIZE
        send_data = False
        for i in range(MAX_STREAMS):
            if not self.waiting[i]:
                continue
            data = self.waiting[i][0]
            sent = data.acked + data.pending
            if sent == data.num_fragments:
                continue
            num = min(send_max, data.num_fragments - sent)
            free.start[i] = sent
            free.num[i] = num
            data.pending += num
            send_data = True
            send_max -= num
            if send_max <= 0:
                break
        if send_data:
            self.out_rel ^= (1 << free.index)
            free.state = SUBCHANNEL_TOSEND
            free.send_seq = 0

    def _send_subchannel_data(self, w):
        """SendSubChannelData (~1169). Returns True if reliable data was written."""
        self._update_subchannels()
        sub = None
        for s in self.subchannels:
            if s.state == SUBCHANNEL_TOSEND:
                sub = s
                break
        if sub is None:
            return False
        w.write_ubits(sub.index, 3)
        for i in range(MAX_STREAMS):
            if sub.num[i] == 0:
                w.write_one_bit(0)
                continue
            data = self.waiting[i][0]
            w.write_one_bit(1)
            offset = sub.start[i] * FRAGMENT_SIZE
            length = sub.num[i] * FRAGMENT_SIZE
            if sub.start[i] + sub.num[i] == data.num_fragments:
                rest = FRAGMENT_SIZE - (data.bytes % FRAGMENT_SIZE)
                if rest < FRAGMENT_SIZE:
                    length -= rest
            single = (sub.num[i] == data.num_fragments)
            if single:
                w.write_one_bit(0)              # single block
                w.write_one_bit(0)              # not compressed
                w.write_varint32(data.bytes)    # protocol > 23: VarInt32 (was NET_MAX_PAYLOAD_BITS)
            else:
                w.write_one_bit(1)              # fragments follow
                w.write_ubits(sub.start[i], MAX_FILE_SIZE_BITS - FRAGMENT_BITS)
                w.write_ubits(sub.num[i], 3)
                if offset == 0:
                    w.write_one_bit(0)          # not a file
                    w.write_one_bit(0)          # not compressed
                    w.write_ubits(data.bytes, MAX_FILE_SIZE_BITS)
            w.write_bytes(data.buffer[offset:offset + length])
            log('netchan: sending subchan %d: start %d num %d (%d bytes, seq %d)' % (
                sub.index, sub.start[i], sub.num[i], length, self.out_seq), 1)
            sub.send_seq = self.out_seq
            sub.state = SUBCHANNEL_WAITING
        return True

    def _check_waiting_list(self, i):
        if not self.waiting[i] or self.out_seq_ack <= 0:
            return
        data = self.waiting[i][0]
        if data.acked == data.num_fragments:
            self.waiting[i].pop(0)
            self.reliable_acked_blocks += 1
            log('netchan: reliable block fully acknowledged (%d bytes)' % data.bytes, 1)

    def has_pending_reliable(self):
        return bool(self.waiting[0]) or self.reliable.num_bits() > 0

    # ---- build & send ------------------------------------------------------
    def transmit(self, datagram=None):
        """SendDatagram (~1575). datagram: optional BitWriter with unreliable messages."""
        if self.reliable.num_bits() > 0:
            self._create_fragments_from_buffer(self.reliable)
            self.reliable = BitWriter()
        w = BitWriter()
        flags = 0
        w.write_long(self.out_seq)
        w.write_long(self.in_seq)
        flags_pos = w.num_bytes()
        w.write_byte(0)                 # flags, patched later
        w.write_short(0)                # checksum, patched later
        checksum_start = w.num_bytes()  # 11
        w.write_byte(self.in_rel)
        if self.choked > 0:
            flags |= PACKET_FLAG_CHOKED
            w.write_byte(self.choked & 0xFF)
        if self.send_challenge:
            flags |= PACKET_FLAG_CHALLENGE
            w.write_long(self.challenge)
        if self._send_subchannel_data(w):
            flags |= PACKET_FLAG_RELIABLE
        if datagram is not None and datagram.num_bits() > 0:
            w.write_bits(datagram.data(), datagram.num_bits())
        if self.unreliable.num_bits() > 0:
            w.write_bits(self.unreliable.data(), self.unreliable.num_bits())
            self.unreliable = BitWriter()
        while w.num_bytes() < MIN_ROUTABLE_PAYLOAD:
            w.write_ubits(net_NOP, NETMSG_TYPE_BITS)
        rem = w.num_bits() % 8
        if 0 < rem <= (8 - NETMSG_TYPE_BITS):
            w.write_ubits(net_NOP, NETMSG_TYPE_BITS)
        rem = w.num_bits() % 8
        if rem > 0:
            pad = 8 - rem
            flags |= (pad << 5) & 0xFF          # ENCODE_PAD_BITS
            w.write_ubits((1 << pad) - 1, pad)  # pad with ones
        w.patch_byte(flags_pos, flags)
        body = w.data()
        cs = crc16_fold(body[checksum_start:])
        w.patch_short(flags_pos + 1, cs)
        pkt = w.data()
        self.sock.sendto(pkt, self.addr)
        self.packets_out += 1
        self.bytes_out += len(pkt)
        log('UDP -> seq=%d ack=%d flags=0x%02x rel=%d relstate=0x%02x len=%d%s' % (
            self.out_seq, self.in_seq, flags, 1 if flags & PACKET_FLAG_RELIABLE else 0,
            self.in_rel, len(pkt), (' ' + hexdump(pkt)) if VERBOSE >= 2 else ''), 1)
        self.choked = 0
        self.out_seq += 1
        return self.out_seq - 1

    # ---- receive -----------------------------------------------------------
    def _reassemble_split(self, data):
        """NET_GetLong (net_ws.cpp ~1230). Returns full packet or None."""
        if len(data) < 12:
            return None
        seq, pid, split_size = struct.unpack_from('<ihh', data, 4)
        number = (pid >> 8) & 0xFF
        count = pid & 0xFF
        if split_size <= 0 or count == 0:
            return None
        entry = self.split.get(seq)
        if entry is None:
            entry = {'count': count, 'size': split_size, 'parts': {}}
            self.split[seq] = entry
        entry['parts'][number] = data[12:]
        log('netchan: split packet %d/%d seq %d (%d bytes)' % (number + 1, count, seq, len(data) - 12), 1)
        if len(entry['parts']) < count:
            return None
        full = b''.join(entry['parts'][i] for i in range(count))
        del self.split[seq]
        return full

    def process_packet(self, data):
        """NET_ReceiveDatagram + CNetChan::ProcessPacket. Returns list of parsed msgs."""
        self.packets_in += 1
        self.bytes_in += len(data)
        if len(data) < 4:
            return []
        hdr = struct.unpack_from('<i', data)[0]
        if hdr == NET_HEADER_FLAG_SPLITPACKET:
            data = self._reassemble_split(data)
            if data is None:
                return []
            hdr = struct.unpack_from('<i', data)[0]
        if hdr == NET_HEADER_FLAG_COMPRESSEDPACKET:
            try:
                data = decompress_block(data[4:])
            except Exception as e:
                log('netchan: packet decompression failed: %s' % e)
                return []
            hdr = struct.unpack_from('<i', data)[0]
        if hdr == -1:
            return [{'id': -1, 'name': 'connectionless', 'raw': data}]
        r = BitReader(data)
        sequence = r.read_long()
        sequence_ack = r.read_long()
        flags = r.read_byte()
        checksum = r.read_ubits(16)
        off = r.pos >> 3
        calc = crc16_fold(data[off:])
        if calc != checksum:
            log('netchan: corrupted packet seq %d (checksum 0x%04x != 0x%04x)' % (sequence, checksum, calc))
            return []
        rel_state = r.read_byte()
        nchoked = 0
        if flags & PACKET_FLAG_CHOKED:
            nchoked = r.read_byte()
        if flags & PACKET_FLAG_CHALLENGE:
            ch = r.read_ulong()
            if ch != self.challenge:
                log('netchan: packet challenge 0x%08x != ours 0x%08x, dropped' % (ch, self.challenge))
                return []
            self.stream_contains_challenge = True
        elif self.stream_contains_challenge:
            log('netchan: packet without challenge after challenged stream, dropped')
            return []
        if sequence <= self.in_seq:
            log('netchan: stale/duplicate packet %d at %d' % (sequence, self.in_seq), 1)
            return []
        drop = sequence - (self.in_seq + nchoked + 1)
        if drop > 0:
            self.drops_seen += drop
            log('netchan: %d packet(s) dropped before seq %d' % (drop, sequence), 1)
        # acknowledge our subchannels
        for sub in self.subchannels:
            bit = 1 << sub.index
            if (self.out_rel & bit) == (rel_state & bit):
                if sub.state == SUBCHANNEL_DIRTY:
                    sub.free()
                elif sub.send_seq > sequence_ack:
                    if sub.state != SUBCHANNEL_FREE:
                        log('netchan: reliable state invalid (subchan %d, sendseq %d > ack %d)' % (
                            sub.index, sub.send_seq, sequence_ack), 1)
                elif sub.state == SUBCHANNEL_WAITING:
                    for j in range(MAX_STREAMS):
                        if sub.num[j] == 0:
                            continue
                        if self.waiting[j]:
                            d = self.waiting[j][0]
                            d.acked += sub.num[j]
                            d.pending -= sub.num[j]
                    log('netchan: subchan %d acknowledged by server (ack %d)' % (sub.index, sequence_ack), 1)
                    sub.free()
            else:
                if sub.send_seq <= sequence_ack and sub.send_seq >= 0:
                    if sub.state == SUBCHANNEL_WAITING:
                        log('netchan: resending subchan %d (server did not get seq %d)' % (sub.index, sub.send_seq), 1)
                        sub.state = SUBCHANNEL_TOSEND
                        self.reliable_resends += 1
                    elif sub.state == SUBCHANNEL_DIRTY:
                        self.out_rel ^= bit
                        sub.free()
        self.in_seq = sequence
        self.out_seq_ack = sequence_ack
        for i in range(MAX_STREAMS):
            self._check_waiting_list(i)
        self.last_received = time.time()
        if flags & PACKET_FLAG_RELIABLE:
            self.reply_wanted = True
        log('UDP <- seq=%d ack=%d flags=0x%02x rel=%d relstate=0x%02x len=%d' % (
            sequence, sequence_ack, flags, 1 if flags & PACKET_FLAG_RELIABLE else 0, rel_state, len(data)), 1)

        msgs = []
        if flags & PACKET_FLAG_RELIABLE:
            try:
                bit = 1 << r.read_ubits(3)
                ok = True
                for i in range(MAX_STREAMS):
                    if r.read_one_bit():
                        if not self._read_subchannel_data(r, i):
                            ok = False
                            break
                if not ok:
                    return msgs
            except BitReadError as e:
                log('netchan: error reading subchannel data: %s' % e)
                return msgs
            self.in_rel ^= bit
            for i in range(MAX_STREAMS):
                more = self._check_receiving_list(i)
                if more is None:
                    return msgs
                msgs.extend(more)
        if r.bits_left() > 0:
            parsed, err = self.parser.parse(r)
            msgs.extend(parsed)
            if err:
                log('netchan: unreliable parse stopped: %s (after %d msgs)' % (err, len(parsed)), 1)
        return msgs

    def _read_subchannel_data(self, r, stream):
        """ReadSubChannelData (~1312)."""
        d = self.recv[stream]
        start = 0
        num = 0
        offset = 0
        length = 0
        single = (r.read_one_bit() == 0)
        if not single:
            start = r.read_ubits(MAX_FILE_SIZE_BITS - FRAGMENT_BITS)
            num = r.read_ubits(3)
            offset = start * FRAGMENT_SIZE
            length = num * FRAGMENT_SIZE
        if offset == 0:
            d.filename = ''
            d.compressed = False
            d.transfer_id = 0
            if single:
                if r.read_one_bit():
                    d.compressed = True
                    d.uncompressed_size = r.read_ubits(MAX_FILE_SIZE_BITS)
                d.bytes = r.read_varint32()
            else:
                if r.read_one_bit():      # file?
                    d.transfer_id = r.read_ubits(32)
                    d.filename = r.read_string()
                if r.read_one_bit():
                    d.compressed = True
                    d.uncompressed_size = r.read_ubits(MAX_FILE_SIZE_BITS)
                d.bytes = r.read_ubits(MAX_FILE_SIZE_BITS)
            if d.buffer is not None:
                log('netchan: fragment transmission aborted at %d/%d' % (d.acked, d.num_fragments), 1)
            d.num_fragments = (d.bytes + FRAGMENT_SIZE - 1) // FRAGMENT_SIZE
            d.acked = 0
            if single:
                num = d.num_fragments
                length = num * FRAGMENT_SIZE
            if d.bytes > (1 << MAX_FILE_SIZE_BITS) - 1:
                log('netchan: net message exceeds max size')
                return False
            d.buffer = bytearray(d.bytes + 4)
        else:
            if d.buffer is None:
                log('netchan: fragment out of order (header missing), waiting for retry', 1)
                return False
        if start + num == d.num_fragments:
            rest = FRAGMENT_SIZE - (d.bytes % FRAGMENT_SIZE)
            if rest < FRAGMENT_SIZE:
                length -= rest
        elif start + num > d.num_fragments:
            log('netchan: fragment chunk out of bounds %d+%d>%d' % (start, num, d.num_fragments))
            return False
        if length == 0 or offset + length > d.bytes:
            log('netchan: malformed fragment ofs %d len %d size %d' % (offset, length, d.bytes))
            d.buffer = None
            return False
        d.buffer[offset:offset + length] = r.read_bytes(length)
        d.acked += num
        log('netchan: received fragments: start %d num %d (%d/%d, %d bytes total%s)' % (
            start, num, d.acked, d.num_fragments, d.bytes, ', compressed' if d.compressed else ''), 1)
        return True

    def _check_receiving_list(self, stream):
        """CheckReceivingList (~2181). Returns list of parsed msgs, or None on fatal error."""
        d = self.recv[stream]
        if d.buffer is None:
            return []
        if d.acked < d.num_fragments:
            return []
        if d.acked > d.num_fragments:
            log('netchan: receiving failed: too many fragments %d/%d' % (d.acked, d.num_fragments))
            return None
        buf = bytes(d.buffer[:d.bytes])
        log('netchan: receiving complete: %d fragments, %d bytes%s' % (
            d.num_fragments, d.bytes, ' (compressed)' if d.compressed else ''), 1)
        if d.compressed:
            try:
                buf = decompress_block(buf, d.uncompressed_size)
                log('netchan: decompressed reliable block to %d bytes' % len(buf), 1)
            except Exception as e:
                log('netchan: reliable block decompression failed: %s' % e)
                d.reset()
                return []
        msgs = []
        if not d.filename:
            parsed, err = self.parser.parse(BitReader(buf))
            msgs.extend(parsed)
            if err:
                log('netchan: reliable parse stopped: %s (after %d msgs)' % (err, len(parsed)), 1)
        else:
            log('netchan: received file %s (%d bytes), ignored' % (d.filename, len(buf)))
        d.reset()
        return msgs


# ---------------------------------------------------------------------------
# The test client
# ---------------------------------------------------------------------------
class Result(object):
    def __init__(self):
        self.connected = 0
        self.rejected_reason = 'none'
        self.held_seconds = 0.0
        self.last_signon_state = 0
        self.serverinfo_seen = 0
        self.spawncount = None
        self.disconnect_reason = 'none'
        self.authproto = None
        self.challenge = None
        self.map = None
        self.hostname = None
        self.dropped = 0
        self.packets_in = 0
        self.packets_out = 0
        self.userinfo_acked = 0
        self.challenge_format = 'binary'
        self.extra = {}

    def line(self):
        def clean(s):
            s = str(s)
            s = s.replace(' ', '_').replace('\n', '_').replace('\r', '_')
            return s if s else 'none'
        fields = [
            ('connected', self.connected),
            ('rejected_reason', clean(self.rejected_reason)),
            ('held_seconds', '%.1f' % self.held_seconds),
            ('last_signon_state', self.last_signon_state),
            ('serverinfo_seen', self.serverinfo_seen),
            ('spawncount', self.spawncount if self.spawncount is not None else 'none'),
            ('userinfo_acked', self.userinfo_acked),
            ('dropped', self.dropped),
            ('disconnect_reason', clean(self.disconnect_reason)),
            ('authproto', self.authproto if self.authproto is not None else 'none'),
            ('challenge', ('0x%08x' % self.challenge) if self.challenge is not None else 'none'),
            ('challenge_format', self.challenge_format),
            ('map', clean(self.map) if self.map else 'none'),
            ('hostname', clean(self.hostname) if self.hostname else 'none'),
            ('packets_in', self.packets_in),
            ('packets_out', self.packets_out),
        ]
        for k, v in sorted(self.extra.items()):
            fields.append((k, clean(v)))
        return 'SRCCLIENT_RESULT ' + ' '.join('%s=%s' % (k, v) for k, v in fields)


class SrcClient(object):
    def __init__(self, args):
        self.args = args
        self.res = Result()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if args.bind_port:
            self.sock.bind(('0.0.0.0', args.bind_port))
        try:
            host_ip = socket.gethostbyname(args.host)
        except socket.error:
            host_ip = args.host
        self.addr = (host_ip, args.port)
        self.client_challenge = (random.randint(0, 0x0FFF) << 16) | random.randint(0, 0xFFFF)
        self.chan = None
        self.signon = SIGNONSTATE_NONE
        self.spawncount = -1
        self.running = True
        self.reconnects = 0
        self.userinfo = self.build_userinfo()

    # ---- userinfo -----------------------------------------------------------
    def build_userinfo(self):
        a = self.args
        pairs = [
            ('name', a.name),
            ('rate', str(a.rate)),
            ('cl_updaterate', str(a.updaterate)),
            ('cl_cmdrate', str(a.cmdrate)),
            ('cl_interp', a.interp),
            ('cl_interp_ratio', str(a.interp_ratio)),
            ('cl_lagcompensation', '1'),
            ('cl_predict', '1'),
            ('cl_predictweapons', '1'),
            ('cl_autowepswitch', '1'),
            ('cl_autohelp', '1'),
            ('cl_language', 'english'),
            ('tv_nochat', '0'),
        ]
        d = dict(pairs)
        order = [k for k, _ in pairs]
        for kv in a.setinfo or []:
            if '=' not in kv:
                log('WARNING: --setinfo expects key=value, got %r (ignored)' % kv)
                continue
            k, v = kv.split('=', 1)
            k = k.strip()
            if not k or not all(c.isalnum() or c == '_' for c in k):
                log('WARNING: setinfo key %r has characters outside [A-Za-z0-9_]; the server will reject it' % k)
            if len(k) > 259 or len(v.encode('utf-8')) > 259:
                log('WARNING: setinfo key/value %r longer than 259 bytes; the server truncates (MAX_OSPATH=260)' % k)
            if k not in d:
                order.append(k)
            d[k] = v
        return [(k, d[k]) for k in order]

    # ---- OOB helpers -------------------------------------------------------
    def send_raw(self, data, what):
        self.sock.sendto(data, self.addr)
        log('OOB -> %s (%d bytes)%s' % (what, len(data), (' ' + hexdump(data)) if VERBOSE >= 2 else ''), 1)

    def recv_oob(self, timeout):
        """Receive one connectionless packet (returns (cmd_byte, BitReader-after-cmd, raw) or None)."""
        end = time.time() + timeout
        while True:
            remaining = end - time.time()
            if remaining <= 0:
                return None
            rl, _, _ = select.select([self.sock], [], [], remaining)
            if not rl:
                return None
            try:
                data, frm = self.sock.recvfrom(65536)
            except (socket.error, OSError) as e:
                log('recv error: %s' % e)
                return None
            if len(data) < 5 or struct.unpack_from('<i', data)[0] != -1:
                log('OOB <- ignoring non-connectionless packet (%d bytes) during handshake' % len(data), 1)
                continue
            log('OOB <- %r (%d bytes)%s' % (data[4:5], len(data), (' ' + hexdump(data)) if VERBOSE >= 2 else ''), 1)
            return data[4:5], data

    # ---- handshake ---------------------------------------------------------
    def get_challenge(self):
        a = self.args
        formats = ['binary', 'text'] if a.challenge_format == 'auto' else [a.challenge_format]
        for attempt in range(a.retries):
            fmt = formats[min(attempt // 2, len(formats) - 1)] if len(formats) > 1 else formats[0]
            self.send_raw(build_getchallenge(self.client_challenge, fmt),
                          "A2S_GETCHALLENGE 'q' (client challenge 0x%08x, %s form)" % (self.client_challenge, fmt))
            deadline = time.time() + a.timeout
            while time.time() < deadline:
                got = self.recv_oob(deadline - time.time())
                if not got:
                    break
                cmd, data = got
                if cmd == S2C_CHALLENGE:
                    try:
                        info = parse_challenge_reply(data)
                    except Exception as e:
                        log("S2C_CHALLENGE parse error: %s (%s)" % (e, hexdump(data)))
                        continue
                    self.res.challenge_format = fmt
                    log("S2C_CHALLENGE 'A': magic=0x%08x (%s) challenge=0x%08x client_challenge_echo=0x%08x (%s) "
                        "authprotocol=%d (%s) steam2_keysize=%s gs_steamid=%s vac_secure=%s padding=%r trailing=%d" % (
                            info['magic'], 'OK' if info['magic'] == S2C_MAGICVERSION else 'MISMATCH',
                            info['challenge'], info['client_challenge'],
                            'matches' if info['client_challenge'] == (self.client_challenge & 0xFFFFFFFF) else 'MISMATCH',
                            info['authprotocol'],
                            {2: 'PROTOCOL_HASHEDCDKEY', 3: 'PROTOCOL_STEAM'}.get(info['authprotocol'], '?'),
                            info['steam2_keysize'], info['gs_steamid'], info['vac_secure'], info['padding'],
                            info['trailing_bytes']))
                    if info['magic'] != S2C_MAGICVERSION:
                        log('WARNING: S2C_MAGICVERSION mismatch; continuing anyway')
                    if info['client_challenge'] != (self.client_challenge & 0xFFFFFFFF):
                        if fmt == 'text':
                            log('NOTE: text-form challenge: server echoed the first 4 bytes of the string; accepting')
                        else:
                            log('WARNING: client challenge echo mismatch; ignoring this reply')
                            continue
                    return info
                elif cmd == S2C_CONNREJECT:
                    r = BitReader(data)
                    r.read_ulong()
                    r.read_byte()
                    r.read_ulong()
                    reason = r.read_string()
                    log("S2C_CONNREJECT '9' during challenge: %s" % reason)
                    self.res.rejected_reason = reason
                    return None
                else:
                    log('ignoring OOB %r while waiting for challenge' % cmd, 1)
            log('no S2C_CHALLENGE reply (attempt %d/%d)' % (attempt + 1, a.retries))
        return None

    def connect(self, chal):
        a = self.args
        authproto = chal['authprotocol'] if a.authproto == 'auto' else int(a.authproto)
        self.res.authproto = authproto
        self.res.challenge = chal['challenge']
        cdkey = a.cdkey
        if authproto == PROTOCOL_HASHEDCDKEY and len(cdkey) != 32:
            log('NOTE: HASHEDCDKEY expects a 32-char MD5 hex (retail rejects other lengths); '
                'using md5(%r)' % cdkey)
            cdkey = hashlib.md5(cdkey.encode()).hexdigest()
        ticket = b''
        if authproto == PROTOCOL_STEAM:
            if a.ticket == 'none':
                ticket = b''
            elif a.ticket == 'dummy':
                ticket = struct.pack('<Q', a.steamid64) + bytes(a.ticket_pad)
            else:
                ticket = binascii.unhexlify(a.ticket)
        pkt = build_connect(authproto, chal['challenge'], self.client_challenge, a.name, a.password,
                            a.product_version, cdkey=cdkey, ticket=ticket,
                            ticket_as_string=a.ticket_as_string)
        desc = ("C2S_CONNECT 'k': protocol=%d authproto=%d challenge=0x%08x client_challenge=0x%08x name=%r "
                "password=%r version=%r " % (PROTOCOL_VERSION, authproto, chal['challenge'],
                                              self.client_challenge, a.name, a.password, a.product_version))
        if authproto == PROTOCOL_HASHEDCDKEY:
            desc += 'cdkey=%r' % cdkey
        else:
            desc += 'ticket=%d bytes (%s)%s' % (len(ticket), a.ticket, ' as-string' if a.ticket_as_string else '')
        self.send_raw(pkt, desc)
        deadline = time.time() + a.timeout
        while time.time() < deadline:
            got = self.recv_oob(deadline - time.time())
            if not got:
                break
            cmd, data = got
            if cmd == S2C_CONNECTION:
                r = BitReader(data)
                r.read_ulong()
                r.read_byte()
                echo = r.read_ulong() if r.bytes_left() >= 4 else None
                rest = data[9:]
                ok = (echo == (self.client_challenge & 0xFFFFFFFF)) or rest.startswith(b'0000')
                log("S2C_CONNECTION 'B': client_challenge_echo=%s (%s) trailer=%r" % (
                    ('0x%08x' % echo) if echo is not None else None,
                    'matches' if echo == (self.client_challenge & 0xFFFFFFFF) else 'no match / resend form', rest))
                if ok:
                    return True
            elif cmd == S2C_CONNREJECT:
                r = BitReader(data)
                r.read_ulong()
                r.read_byte()
                echo = r.read_ulong()
                reason = r.read_string()
                human = REJECT_TOKENS.get(reason.strip(), '')
                log("S2C_CONNREJECT '9': echo=0x%08x reason=%r %s" % (echo, reason, ('(%s)' % human) if human else ''))
                self.res.rejected_reason = reason
                return False
            elif cmd == S2C_CHALLENGE:
                log('extra S2C_CHALLENGE while waiting for connection reply (ignored)', 1)
            else:
                log('ignoring OOB %r while waiting for connection' % cmd, 1)
        return None   # timeout

    # ---- netchannel phase ----------------------------------------------------
    def send_initial_reliable(self, transmit=True):
        a = self.args
        chan = self.chan
        pairs = self.userinfo

        def wr(w):
            msg_setconvar(w, pairs)
            msg_signonstate(w, SIGNONSTATE_CONNECTED, -1)
        chan.queue_reliable(wr)
        log('queued reliable: net_SetConVar(%d convars: %s) + net_SignonState(CONNECTED, -1)' % (
            len(pairs), ', '.join('%s=%s' % (k, (v if len(v) < 24 else v[:21] + '...')) for k, v in pairs)))
        if transmit:
            chan.transmit()

    def handle_messages(self, msgs):
        a = self.args
        chan = self.chan
        for m in msgs:
            mid = m['id']
            if mid == -1:
                raw = m['raw']
                log('OOB packet during netchannel phase: %r' % raw[4:24])
                continue
            name = m['name']
            if mid == net_Disconnect:
                log('<< net_Disconnect from server: %r' % m['reason'])
                self.res.disconnect_reason = m['reason']
                self.res.dropped = 1
                self.running = False
            elif mid == net_SignonState:
                st = m['state']
                log('<< net_SignonState: state=%d (%s) spawncount=%d' % (st, SIGNON_NAMES.get(st, '?'), m['spawncount']))
                if st != SIGNONSTATE_CHANGELEVEL:
                    self.signon = max(self.signon, st)
                    self.res.last_signon_state = max(self.res.last_signon_state, st)
                    self.spawncount = m['spawncount']
                    self.res.spawncount = m['spawncount']
                if st == SIGNONSTATE_NEW and a.progress >= SIGNONSTATE_NEW:
                    sc = m['spawncount']
                    crc = a.sendtable_crc
                    rb = chan.parser.replay_bit if chan.parser.replay_bit is not None else True

                    def wr(w, sc=sc, crc=crc, rb=rb):
                        msg_clientinfo(w, sc, crc, replay_bit=rb)
                        msg_signonstate(w, SIGNONSTATE_NEW, sc)
                    chan.queue_reliable(wr)
                    log('>> queued CLC_ClientInfo(server_count=%d sendtable_crc=0x%08x replay_bit=%s) + '
                        'net_SignonState(NEW, %d)  [NOTE: a wrong SendTable CRC makes the server send '
                        '"Server uses different class tables" unless sv_sendtables 1]' % (sc, crc & 0xFFFFFFFF, rb, sc))
                elif st in (SIGNONSTATE_PRESPAWN, SIGNONSTATE_SPAWN) and a.progress >= st:
                    sc = m['spawncount']

                    def wr(w, st=st, sc=sc):
                        msg_signonstate(w, st, sc)
                    chan.queue_reliable(wr)
                    log('>> queued net_SignonState(%s, %d)' % (SIGNON_NAMES[st], sc))
                elif st == SIGNONSTATE_CONNECTED:
                    # CBaseClient::Reconnect(): server cleared its netchannel and wants the
                    # CONNECTED handshake again (spawncount/state mismatch on our side)
                    self.reconnects += 1
                    if self.reconnects <= 3:
                        log('server requested a reconnect (net_SignonState CONNECTED); re-sending userinfo + CONNECTED ack')
                        self.send_initial_reliable(transmit=False)
                    else:
                        log('server keeps requesting reconnects; giving up re-sending')
                elif st == SIGNONSTATE_CHANGELEVEL:
                    log('server is changing level; staying put')
            elif mid == svc_ServerInfo:
                self.res.serverinfo_seen = 1
                self.res.map = m['map_name']
                self.res.hostname = m['host_name']
                self.res.spawncount = m['server_count']
                self.spawncount = m['server_count']
                log('<< svc_ServerInfo: protocol=%d server_count(spawncount)=%d dedicated=%d hltv=%d max_classes=%d '
                    'player_slot=%d max_clients=%d tick_interval=%.6f (%.1f tick) os=%s gamedir=%r map=%r sky=%r '
                    'hostname=%r map_md5=%s replay_bit=%s' % (
                        m['protocol'], m['server_count'], m['is_dedicated'], m['is_hltv'], m['max_classes'],
                        m['player_slot'], m['max_clients'], m['tick_interval'],
                        (1.0 / m['tick_interval']) if m['tick_interval'] else 0.0, m['os'], m['game_dir'],
                        m['map_name'], m['sky_name'], m['host_name'], m['map_md5'], m.get('replay_bit_autodetect')))
            elif mid == svc_Print:
                txt = m['text'].strip()
                log('<< svc_Print: %s' % ' | '.join(l for l in txt.splitlines() if l.strip()))
            elif mid == net_StringCmd:
                log('<< net_StringCmd: %r' % m['command'])
            elif mid == net_SetConVar:
                cv = m['convars']
                log('<< net_SetConVar: %d replicated convars (%s%s)' % (
                    len(cv), ', '.join('%s=%s' % kv for kv in cv[:6]), ', ...' if len(cv) > 6 else ''))
            elif mid == svc_GetCvarValue:
                val = dict(self.userinfo).get(m['cvar'])
                status = 0 if val is not None else 1
                log('<< svc_GetCvarValue: cookie=%d cvar=%r -> replying %s' % (
                    m['cookie'], m['cvar'], ('value %r' % val) if val is not None else 'CvarNotFound'))
                cookie, cvar = m['cookie'], m['cvar']

                def wr(w, cookie=cookie, status=status, cvar=cvar, val=val):
                    msg_respond_cvar(w, cookie, status, cvar, val or '')
                chan.queue_reliable(wr)
            elif mid == net_File:
                if m['request']:
                    log('<< net_File request id=%d %r -> denying' % (m['transfer_id'], m['filename']))
                    tid, fn = m['transfer_id'], m['filename']

                    def wr(w, tid=tid, fn=fn):
                        msg_file_deny(w, tid, fn)
                    chan.queue_reliable(wr)
                else:
                    log('<< net_File deny id=%d %r' % (m['transfer_id'], m['filename']), 1)
            elif mid == svc_PacketEntities:
                if self.signon == SIGNONSTATE_SPAWN and a.progress >= SIGNONSTATE_FULL and not self.res.extra.get('full_sent'):
                    sc = self.spawncount

                    def wr(w, sc=sc):
                        msg_signonstate(w, SIGNONSTATE_FULL, sc)
                    chan.queue_reliable(wr)
                    self.res.extra['full_sent'] = 1
                    log('>> first svc_PacketEntities at SPAWN: queued net_SignonState(FULL, %d)' % sc)
                log('<< %s: %s' % (name, ' '.join('%s=%r' % kv for kv in m.items() if kv[0] not in ('id', 'name'))), 2)
            else:
                detail = ' '.join('%s=%r' % kv for kv in m.items() if kv[0] not in ('id', 'name'))
                log('<< %s %s' % (name, detail[:200]), 1)

    def run_netchannel(self):
        a = self.args
        self.chan = NetChannel(self.sock, self.addr, self.res.challenge, self,
                               send_challenge=not a.no_challenge_flag)
        chan = self.chan
        self.signon = SIGNONSTATE_CONNECTED
        self.res.last_signon_state = SIGNONSTATE_CONNECTED
        t_start = time.time()
        self.send_initial_reliable()
        next_keepalive = time.time() + a.keepalive
        hold_end = t_start + a.hold
        userinfo_ack_logged = False
        while self.running and time.time() < hold_end:
            timeout = max(0.0, min(next_keepalive, hold_end) - time.time())
            rl, _, _ = select.select([self.sock], [], [], min(timeout, 0.25))
            if rl:
                try:
                    data, frm = self.sock.recvfrom(65536)
                except (socket.error, OSError) as e:
                    log('recv error: %s' % e)
                    break
                if frm[0] != self.addr[0]:
                    log('packet from unexpected address %s ignored' % (frm,), 1)
                    continue
                msgs = chan.process_packet(data)
                if msgs:
                    self.handle_messages(msgs)
                # reply immediately when we have something to send (acks of the server's
                # reliable sub-channels, queued reliable data); the real client transmits
                # every frame during signon, this is the cheap approximation
                if chan.has_pending_reliable() or chan.reply_wanted:
                    chan.reply_wanted = False
                    chan.transmit()
                    next_keepalive = time.time() + a.keepalive
            if not userinfo_ack_logged and chan.reliable_acked_blocks >= 1:
                userinfo_ack_logged = True
                self.res.userinfo_acked = 1
                log('server ACKNOWLEDGED the reliable block carrying net_SetConVar(userinfo) + net_SignonState(CONNECTED)')
            if time.time() >= next_keepalive:
                chan.transmit()
                next_keepalive = time.time() + a.keepalive
            if time.time() - chan.last_received > a.server_silence and chan.packets_in > 0:
                log('WARNING: nothing received from server for %.0fs' % (time.time() - chan.last_received))
                chan.last_received = time.time()   # warn once per interval
        self.res.held_seconds = time.time() - t_start
        if self.running and not a.no_disconnect:
            w = BitWriter()
            msg_disconnect(w, a.disconnect_reason)
            chan.transmit(w)
            log('>> net_Disconnect(%r) sent' % a.disconnect_reason)
        self.res.packets_in = chan.packets_in
        self.res.packets_out = chan.packets_out
        self.res.extra['reliable_blocks_sent'] = chan.reliable_sent_blocks
        self.res.extra['reliable_blocks_acked'] = chan.reliable_acked_blocks
        self.res.extra['reliable_resends'] = chan.reliable_resends
        self.res.extra['server_drops_seen'] = chan.drops_seen
        self.res.extra['bytes_in'] = chan.bytes_in
        self.res.extra['bytes_out'] = chan.bytes_out

    def run(self):
        a = self.args
        log('srcclient: target %s:%d name=%r hold=%.1fs authproto=%s product_version=%r progress=%d' % (
            a.host, a.port, a.name, a.hold, a.authproto, a.product_version, a.progress))
        chal = self.get_challenge()
        if not chal:
            if self.res.rejected_reason == 'none':
                self.res.rejected_reason = 'no_challenge_reply'
            return self.res
        ok = None
        for attempt in range(a.retries):
            ok = self.connect(chal)
            if ok is not None:
                break
            log('no reply to C2S_CONNECT (attempt %d/%d); re-requesting challenge' % (attempt + 1, a.retries))
            chal2 = self.get_challenge()
            if chal2:
                chal = chal2
        if ok is None:
            self.res.rejected_reason = 'no_connection_reply'
            return self.res
        if not ok:
            return self.res
        self.res.connected = 1
        log('CONNECTED: server accepted; entering netchannel phase (challenge 0x%08x)' % self.res.challenge)
        self.run_netchannel()
        return self.res


# ---------------------------------------------------------------------------
# Self test (no server needed): bit buffers, CRC, compression, netchannel loopback
# ---------------------------------------------------------------------------
def selftest():
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)
        print('  [%s] %s' % ('ok' if cond else 'FAIL', what))

    # bit buffer round trip at odd alignments
    w = BitWriter()
    w.write_ubits(5, 6)
    w.write_byte(0xAB)
    w.write_string('hello')
    w.write_one_bit(1)
    w.write_long(0xDEADBEEF)
    w.write_varint32(300)
    w.write_short(-2 & 0xFFFF)
    w.write_float(1.5)
    w.write_sbits(-7, 4)
    r = BitReader(w.data(), w.num_bits())
    check(r.read_ubits(6) == 5 and r.read_byte() == 0xAB and r.read_string() == 'hello' and r.read_one_bit() == 1
          and r.read_ulong() == 0xDEADBEEF and r.read_varint32() == 300 and r.read_short() == -2
          and r.read_float() == 1.5 and r.read_sbits(4) == -7, 'BitWriter/BitReader round trip')
    # LSB-first packing check: WriteUBitLong(5,6) then WriteByte(0xAB) -> bytes: 0b11000101 (0xC5), 0b00101010 (0x2A)
    w2 = BitWriter()
    w2.write_ubits(5, 6)
    w2.write_byte(0xAB)
    check(w2.data() == bytes([0xC5, 0x2A]), 'LSB-first packing matches engine layout (0xC5 0x2A)')
    # CRC fold
    crc = zlib.crc32(b'123456789') & 0xFFFFFFFF
    check(crc == 0xCBF43926 and crc16_fold(b'123456789') == ((0x3926 ^ 0xCBF4) & 0xFFFF), 'CRC32 IEEE + 16-bit fold')
    # snappy: literal + copy
    raw = bytes([11, (3 << 2) | 0]) + b'abcd' + bytes([((3 << 2) | 1) | (0 << 5), 4]) + bytes([(2 << 2) | 0]) + b'xyz'
    # ulen=11, literal 4 'abcd', copy1 len=(3)+4=7 off=4 -> 'abcdabc', literal 3 'xyz' -> total 4+7+3 = 14 != 11 -> fix ulen
    raw = bytes([14]) + raw[1:]
    check(snappy_raw_decompress(raw) == b'abcdabcdabcxyz', 'snappy raw decode (literal/copy overlap)')
    # lzss: header + literals only then stop pair
    body = bytearray()
    body += b'LZSS' + struct.pack('<I', 3)
    body += bytes([0x08])         # cmd byte: bits 0..2 literal, bit 3 = pair (stop)
    body += b'abc'
    body += bytes([0x00, 0x00])   # position 0, count 1 -> stop
    check(lzss_decompress(bytes(body)) == b'abc', 'lzss decode')
    # netchannel loopback: two channels over UDP talking to each other
    s1 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s1.bind(('127.0.0.1', 0))
    s2.bind(('127.0.0.1', 0))
    a1 = s1.getsockname()
    a2 = s2.getsockname()
    c1 = NetChannel(s1, a2, 0x12345678, None)
    c2 = NetChannel(s2, a1, 0x12345678, None)
    big = ('x' * 700).encode()
    pairs = [('name', 'selftest'), ('lt', 'hello'), ('big', big.decode())] * 3   # > 1024 bytes -> multi-fragment

    def wr(w):
        msg_setconvar(w, pairs)
        msg_signonstate(w, 2, -1)
    c1.queue_reliable(wr)
    c1.transmit()
    got = []
    lost_first = True
    for i in range(12):
        rl, _, _ = select.select([s2], [], [], 0.5)
        if rl:
            d, _ = s2.recvfrom(65536)
            if lost_first:
                lost_first = False      # drop the first packet to exercise the resend path
            else:
                got.extend(c2.process_packet(d))
        c2.transmit()
        rl, _, _ = select.select([s1], [], [], 0.5)
        if rl:
            d, _ = s1.recvfrom(65536)
            c1.process_packet(d)
        c1.transmit()
        if c1.reliable_acked_blocks >= 1 and got:
            break
    names = [m['name'] for m in got]
    check('net_SetConVar' in names and 'net_SignonState' in names, 'loopback reliable transfer parsed (%s)' % names)
    check(c1.reliable_acked_blocks == 1, 'loopback reliable block acknowledged after resend (resends=%d)' % c1.reliable_resends)
    cv = [m for m in got if m['name'] == 'net_SetConVar']
    check(bool(cv) and cv[0]['convars'] == pairs, 'userinfo content intact over fragments')
    # header decode of our own packet via the peer's checksum path already covered; corrupt a packet
    # drain anything still queued from the loop above
    while select.select([s2], [], [], 0.1)[0]:
        s2.recvfrom(65536)
    c3 = NetChannel(s1, a2, 0x12345678, None)
    c3.out_seq = 50
    pkt_w = BitWriter()
    msg_stringcmd(pkt_w, 'say hi')
    c3.transmit(pkt_w)
    d, _ = s2.recvfrom(65536)
    bad = bytearray(d)
    bad[-1] ^= 0xFF
    before = c2.in_seq
    c2.process_packet(bytes(bad))
    check(c2.in_seq == before, 'corrupted packet rejected by checksum')
    m = c2.process_packet(d)
    check(any(x['name'] == 'net_StringCmd' and x['command'] == 'say hi' for x in m), 'unreliable net_StringCmd parsed')
    s1.close()
    s2.close()
    print('SELFTEST %s (%d failures)' % ('PASSED' if not fails else 'FAILED', len(fails)))
    return 0 if not fails else 1


# ---------------------------------------------------------------------------
def main():
    global VERBOSE
    ap = argparse.ArgumentParser(description='Protocol-level Source engine (CS:S v92) test client')
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=27015)
    ap.add_argument('--name', default='srcclient')
    ap.add_argument('--password', default='')
    ap.add_argument('--setinfo', action='append', metavar='KEY=VALUE', help='extra userinfo convar (repeatable), e.g. lt=hello')
    ap.add_argument('--hold', type=float, default=15.0, help='seconds to keep the netchannel alive after connect')
    ap.add_argument('--verbose', '-v', action='count', default=0, help='-v packet summary, -vv hex dumps')
    ap.add_argument('--a2s', action='store_true', help='only do A2S_INFO (2020 challenge handshake) and print it')
    ap.add_argument('--rcon-password', default=None)
    ap.add_argument('--rcon-cmd', default='status')
    ap.add_argument('--authproto', default='auto', help="auto (echo server's S2C_CHALLENGE value), 2 (HASHEDCDKEY) or 3 (STEAM)")
    ap.add_argument('--cdkey', default=hashlib.md5(b'srcclient').hexdigest(), help='32-hex cdkey hash for authproto 2')
    ap.add_argument('--ticket', default='dummy', help="steam ticket for authproto 3: 'dummy' (steamid64+pad), 'none' (empty), or hex bytes")
    ap.add_argument('--ticket-pad', type=int, default=16, help='zero bytes appended after steamid64 in the dummy ticket')
    ap.add_argument('--ticket-as-string', action='store_true', help='send the STEAM ticket as a NUL-terminated string instead of short-len+bytes')
    ap.add_argument('--steamid64', type=int, default=0x0110000100000000 | 12345678, help='fake SteamID64 prepended to the dummy ticket')
    ap.add_argument('--product-version', default='auto', help="steam.inf PatchVersion string to send ('auto' = A2S_INFO version, fallback %s)" % DEFAULT_PRODUCT_VERSION)
    ap.add_argument('--challenge-format', choices=['auto', 'binary', 'text'], default='auto',
                    help="A2S_GETCHALLENGE body: binary long+pad (engine), text 'connect0x%%08X', or auto (binary first, then text)")
    ap.add_argument('--progress', type=int, default=SIGNONSTATE_CONNECTED,
                    help='highest signon state to acknowledge: 2=CONNECTED only (default), 3=ack NEW (+CLC_ClientInfo), 4,5,6 best effort')
    ap.add_argument('--sendtable-crc', type=lambda s: int(s, 0), default=0, help='SendTable CRC to put in CLC_ClientInfo (unknown -> 0)')
    ap.add_argument('--rate', type=int, default=80000)
    ap.add_argument('--updaterate', type=int, default=66)
    ap.add_argument('--cmdrate', type=int, default=66)
    ap.add_argument('--interp', default='0.03')
    ap.add_argument('--interp-ratio', type=int, default=2)
    ap.add_argument('--keepalive', type=float, default=0.5, help='seconds between keep-alive packets')
    ap.add_argument('--timeout', type=float, default=2.0, help='seconds to wait for each handshake reply')
    ap.add_argument('--retries', type=int, default=4)
    ap.add_argument('--server-silence', type=float, default=10.0, help='warn if the server is silent this long')
    ap.add_argument('--bind-port', type=int, default=0, help='local UDP port (0 = ephemeral)')
    ap.add_argument('--no-disconnect', action='store_true', help='do not send net_Disconnect at the end (let the server time out)')
    ap.add_argument('--no-challenge-flag', action='store_true',
                    help='omit PACKET_FLAG_CHALLENGE + challenge long from netchannel headers (fallback for engines without it)')
    ap.add_argument('--disconnect-reason', default='srcclient done')
    ap.add_argument('--selftest', action='store_true', help='run offline self tests and exit')
    args = ap.parse_args()
    VERBOSE = args.verbose

    if args.selftest:
        sys.exit(selftest())

    if args.a2s:
        try:
            info = a2s_info(args.host, args.port)
        except Exception as e:
            print('A2S_INFO failed: %s' % e)
            print('SRCCLIENT_A2S ok=0 error=%s' % str(e).replace(' ', '_'))
            sys.exit(2)
        print('A2S_INFO ok rtt=%.0fms name=%r map=%s folder=%s game=%r appid=%d players=%d/%d bots=%d type=%s env=%s '
              'password=%d vac=%d version=%s port=%s steamid=%s keywords=%r' % (
                  info['rtt_ms'], info['name'], info['map'], info['folder'], info['game'], info['appid'],
                  info['players'], info['max_players'], info['bots'], info['server_type'], info['environment'],
                  info['password'], info['vac'], info['version'], info.get('port'), info.get('steamid'),
                  info.get('keywords')))
        print('SRCCLIENT_A2S ok=1 version=%s map=%s players=%d/%d bots=%d vac=%d' % (
            info['version'], info['map'], info['players'], info['max_players'], info['bots'], info['vac']))
        sys.exit(0)

    if args.rcon_password is not None:
        try:
            ok, out = rcon(args.host, args.port, args.rcon_password, args.rcon_cmd)
        except Exception as e:
            print('RCON failed: %s' % e)
            print('SRCCLIENT_RCON ok=0')
            sys.exit(2)
        print(out.rstrip())
        print('SRCCLIENT_RCON ok=%d auth=%d cmd=%s' % (1 if ok else 0, 1 if ok else 0, args.rcon_cmd.replace(' ', '_')))
        sys.exit(0 if ok else 2)

    if args.product_version == 'auto':
        try:
            info = a2s_info(args.host, args.port, timeout=2.0)
            args.product_version = info['version']
            log('product version from A2S_INFO: %r (map=%s players=%d/%d)' % (
                info['version'], info['map'], info['players'], info['max_players']))
        except Exception as e:
            args.product_version = DEFAULT_PRODUCT_VERSION
            log('A2S_INFO unavailable (%s); using default product version %r' % (e, DEFAULT_PRODUCT_VERSION))

    client = SrcClient(args)
    try:
        res = client.run()
    except KeyboardInterrupt:
        res = client.res
        res.disconnect_reason = 'interrupted'
    print(res.line())
    sys.stdout.flush()
    sys.exit(0 if res.connected else 1)


if __name__ == '__main__':
    main()
