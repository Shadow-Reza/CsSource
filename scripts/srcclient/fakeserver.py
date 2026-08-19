#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fakeserver.py -- tiny offline stand-in for the Source server side of the handshake,
used only to exercise srcclient.py end to end without a real srcds:

  terminal 1:  python3 fakeserver.py --port 27999
  terminal 2:  python3 srcclient.py --host 127.0.0.1 --port 27999 --setinfo lt=hello --hold 5 -v

It implements, with the SAME framing code as srcclient.py (so it is a consistency
check, not an independent oracle):
  * S2C_CHALLENGE reply (PROTOCOL_STEAM form), S2C_CONNECTION / S2C_CONNREJECT
  * netchannel header parsing + ack of the client's reliable sub-channel
  * a serverinfo block (svc_Print, svc_ServerInfo, net_Tick, one svc_CreateStringTable,
    net_SetConVar, net_SignonState(NEW)) sent reliably (multi-fragment) once the client
    sent net_SignonState(CONNECTED); PRESPAWN/SPAWN acks if the client progresses.
Everything it prints about the userinfo it received is what a real server would see
in CBaseClient::ProcessSetConVar.
"""
import argparse
import select
import socket
import struct
import sys
import time

sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import srcclient as sc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=27999)
    ap.add_argument('--reject', default=None, help='reject every connect with this reason')
    ap.add_argument('--authproto', type=int, default=3)
    ap.add_argument('--verbose', '-v', action='count', default=0)
    args = ap.parse_args()
    sc.VERBOSE = args.verbose
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(('127.0.0.1', args.port))
    print('fakeserver listening on 127.0.0.1:%d' % args.port)
    clients = {}   # addr -> dict(chan, state, spawncount)
    spawncount = 7
    challenge_for = lambda addr: (hash(addr[0]) ^ 0x5a5a5a5a) & 0x7FFFFFFF
    while True:
        rl, _, _ = select.select([s], [], [], 1.0)
        if not rl:
            # periodic transmit like the engine's 1 s signon keepalive
            for addr, c in list(clients.items()):
                c['chan'].transmit()
            continue
        data, addr = s.recvfrom(65536)
        hdr = struct.unpack_from('<i', data)[0]
        if hdr == -1:
            cmd = data[4:5]
            r = sc.BitReader(data)
            r.read_ulong()
            r.read_byte()
            if cmd == sc.A2S_GETCHALLENGE:
                cc = r.read_ulong()
                w = sc.BitWriter()
                w.write_long(sc.CONNECTIONLESS_HEADER)
                w.write_byte(ord(sc.S2C_CHALLENGE))
                w.write_long(sc.S2C_MAGICVERSION)
                w.write_long(challenge_for(addr))
                w.write_long(cc)
                w.write_long(args.authproto)
                if args.authproto == sc.PROTOCOL_STEAM:
                    w.write_short(0)
                    w.write_bytes(struct.pack('<Q', 90071996842377216))
                    w.write_byte(0)
                w.write_string('000000')
                s.sendto(w.data(), addr)
                print('%s: getchallenge (client challenge 0x%08x) -> challenge 0x%08x' % (addr, cc, challenge_for(addr)))
            elif cmd == sc.C2S_CONNECT:
                proto = r.read_long()
                auth = r.read_long()
                ch = r.read_ulong()
                cc = r.read_ulong()
                name = r.read_string()
                pw = r.read_string()
                ver = r.read_string()
                if auth == sc.PROTOCOL_HASHEDCDKEY:
                    key = r.read_string()
                    keyinfo = 'cdkey=%r' % key
                else:
                    ln = r.read_short()
                    ticket = r.read_bytes(ln) if 0 <= ln <= r.bytes_left() else b''
                    keyinfo = 'ticket=%d bytes steamid64=%s' % (ln, struct.unpack('<Q', ticket[:8])[0] if len(ticket) >= 8 else None)
                print('%s: connect protocol=%d auth=%d challenge=0x%08x name=%r password=%r version=%r %s' % (
                    addr, proto, auth, ch, name, pw, ver, keyinfo))
                w = sc.BitWriter()
                w.write_long(sc.CONNECTIONLESS_HEADER)
                if args.reject or proto != sc.PROTOCOL_VERSION or ch != challenge_for(addr):
                    reason = args.reject or ('#GameUI_ServerRejectBadChallenge' if ch != challenge_for(addr) else '#GameUI_ServerRejectOldVersion')
                    w.write_byte(ord(sc.S2C_CONNREJECT))
                    w.write_long(cc)
                    w.write_string(reason)
                    s.sendto(w.data(), addr)
                    print('%s: rejected: %s' % (addr, reason))
                    continue
                w.write_byte(ord(sc.S2C_CONNECTION))
                w.write_long(cc)
                w.write_string('0000000000')
                s.sendto(w.data(), addr)
                clients[addr] = {'chan': sc.NetChannel(s, addr, challenge_for(addr), None, side='clc'), 'state': 2, 'name': name}
                print('%s: accepted, netchannel created' % (addr,))
            continue
        c = clients.get(addr)
        if not c:
            continue
        chan = c['chan']
        msgs = chan.process_packet(data)
        for m in msgs:
            n = m['name']
            if n == 'net_SetConVar':
                print('%s: USERINFO (%d convars): %s' % (addr, len(m['convars']), ', '.join('%s=%r' % kv for kv in m['convars'])))
            elif n == 'net_SignonState':
                print('%s: net_SignonState(%s, %d)' % (addr, sc.SIGNON_NAMES.get(m['state']), m['spawncount']))
                if m['state'] == 2 and c['state'] == 2:
                    # CheckConnect -> ClientConnect would fire here; send serverinfo block
                    def wr(w):
                        w.write_ubits(sc.svc_Print, 6)
                        w.write_string('\nCounter-Strike: Source\nMap: de_dust2\nPlayers: 1 / 32\nBuild: 6630498\nServer Number: %d\n\n' % spawncount)
                        w.write_ubits(sc.svc_ServerInfo, 6)
                        w.write_short(24)
                        w.write_long(spawncount)
                        w.write_one_bit(0)
                        w.write_one_bit(1)
                        w.write_long(0xFFFFFFFF)
                        w.write_word(200)
                        w.write_bytes(b'\x11' * 16)
                        w.write_byte(1)
                        w.write_byte(32)
                        w.write_float(1.0 / 66.0)
                        w.write_char(ord('l'))
                        w.write_string('cstrike')
                        w.write_string('de_dust2')
                        w.write_string('sky_dust')
                        w.write_string('fakeserver')
                        w.write_one_bit(0)           # replay bit
                        w.write_ubits(sc.net_Tick, 6)
                        w.write_long(1234)
                        w.write_ubits(100, 16)
                        w.write_ubits(10, 16)
                        # one string table with 700 bytes of payload (multi-fragment block)
                        w.write_ubits(sc.svc_CreateStringTable, 6)
                        w.write_string('downloadables')
                        w.write_word(8192)
                        w.write_ubits(3, 14)
                        payload = b'\xAA' * 700
                        w.write_varint32(len(payload) * 8)
                        w.write_one_bit(0)
                        w.write_one_bit(0)
                        w.write_bits(payload, len(payload) * 8)
                        w.write_ubits(sc.net_SetConVar, 6)
                        w.write_byte(2)
                        w.write_string('sv_cheats')
                        w.write_string('0')
                        w.write_string('mp_friendlyfire')
                        w.write_string('0')
                        w.write_ubits(sc.net_SignonState, 6)
                        w.write_byte(3)
                        w.write_long(spawncount)
                    chan.queue_reliable(wr)
                    c['state'] = 3
                    chan.transmit()
                elif m['state'] == 3 and c['state'] == 3:
                    def wr(w):
                        w.write_ubits(sc.svc_ClassInfo, 6)
                        w.write_short(3)
                        w.write_one_bit(1)
                        w.write_ubits(sc.net_SignonState, 6)
                        w.write_byte(4)
                        w.write_long(spawncount)
                    chan.queue_reliable(wr)
                    c['state'] = 4
                    chan.transmit()
                elif m['state'] == 4 and c['state'] == 4:
                    def wr(w):
                        w.write_ubits(sc.net_Tick, 6)
                        w.write_long(1300)
                        w.write_ubits(100, 16)
                        w.write_ubits(10, 16)
                        w.write_ubits(sc.net_SignonState, 6)
                        w.write_byte(5)
                        w.write_long(spawncount)
                    chan.queue_reliable(wr)
                    c['state'] = 5
                    chan.transmit()
                elif m['state'] == 5 and c['state'] == 5:
                    c['state'] = 6
                    print('%s: ActivatePlayer (FULL) -- ClientPutInServer would fire' % (addr,))
                    w = sc.BitWriter()
                    w.write_ubits(sc.svc_PacketEntities, 6)
                    w.write_ubits(5, sc.MAX_EDICT_BITS)
                    w.write_one_bit(0)
                    w.write_ubits(0, 1)
                    w.write_ubits(0, sc.MAX_EDICT_BITS)
                    w.write_ubits(16, sc.DELTASIZE_BITS)
                    w.write_one_bit(0)
                    w.write_ubits(0xABCD, 16)
                    chan.transmit(w)
                elif m['state'] == 6:
                    print('%s: client reports FULL' % (addr,))
            elif n == 'clc_ClientInfo':
                print('%s: clc_ClientInfo server_count=%d sendtable_crc=0x%08x friends=%r' % (
                    addr, m['server_count'], m['sendtable_crc'], m['friends_name']))
            elif n == 'net_Disconnect':
                print('%s: disconnected: %r' % (addr, m['reason']))
                del clients[addr]
                break
            else:
                print('%s: %s %s' % (addr, n, {k: v for k, v in m.items() if k not in ('id', 'name')}))
        if addr in clients and (chan.reply_wanted or chan.has_pending_reliable()):
            chan.reply_wanted = False
            chan.transmit()


if __name__ == '__main__':
    main()
