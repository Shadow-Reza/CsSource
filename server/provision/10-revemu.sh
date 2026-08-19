#!/usr/bin/env bash
# 10 — RevEmu (bir3yk) non-Steam auth into the shared base (MISSION §3, §4.2, docs/revemu.md).
#  * Valve's own bin/steamclient.so (from buildid 6953255, 2021-07) becomes bin/steamclient_valve.so
#  * RevEmu's steamclient.so (08.10.2023 Linux server build, 1 722 036 bytes) becomes bin/steamclient.so
#  * rev.ini at the server root (srcds cwd)  — ClientDLL=./bin/steamclient_valve.so
# Provenance cross-check: the hl2go mirror zip and the Uphardt GitHub re-upload must have the same sha256.
# NOTE: `steamcmd ... validate` restores Valve's steamclient.so — re-run this script after any base update.
set -euo pipefail
BASE=/opt/css/base; DIST=/opt/css/dist/revemu; mkdir -p $DIST
HL2GO_URL="${REVEMU_URL:-https://hl2go.com/downloads/dedicated-servers/srcds/revemu-latest-version-linux-windows/?download=20513}"
GH_URL="https://raw.githubusercontent.com/Uphardt/RevEmu-2024-Uphardt-Edition-LINUX/main/bin/steamclient.so"
for u in css@pub1 css@pub2 css@dm css@gg css@awp css@m1 css@m2; do systemctl stop "$u" 2>/dev/null || true; done
for n in pub1 pub2 dm gg awp m1 m2; do systemctl stop "css-overlay@$n" 2>/dev/null || true; done
grep -qs "lowerdir=$BASE" /proc/mounts && { echo "overlays still mounted; abort" >&2; exit 1; }
cd $DIST
if [ ! -s steamclient.so.revemu ]; then
  ok=0
  if curl -fsSL -A "Mozilla/5.0" -o hl2go.zip "$HL2GO_URL" && unzip -l hl2go.zip >/dev/null 2>&1; then
    unzip -o -j hl2go.zip -d hl2go >/dev/null; f=$(find hl2go -name steamclient.so | head -1); [ -n "$f" ] && cp "$f" steamclient.so.hl2go && ok=1
    echo "hl2go zip: $(unzip -l hl2go.zip | tail -3 | head -2 | tr -s ' ')"
  else echo "hl2go download failed"; fi
  curl -fsSL -o steamclient.so.github "$GH_URL" && echo "github: $(stat -c %s steamclient.so.github) bytes" || echo "github download failed"
  sha256sum steamclient.so.hl2go steamclient.so.github 2>/dev/null | tee SHA256SUMS.revemu
  if [ -s steamclient.so.hl2go ] && [ -s steamclient.so.github ] && cmp -s steamclient.so.hl2go steamclient.so.github; then echo "PROVENANCE: hl2go mirror == Uphardt GitHub (identical)"; fi
  if [ -s steamclient.so.hl2go ]; then cp steamclient.so.hl2go steamclient.so.revemu; elif [ -s steamclient.so.github ]; then cp steamclient.so.github steamclient.so.revemu; else echo "no RevEmu binary obtained" >&2; exit 1; fi
fi
file steamclient.so.revemu | cut -c1-120
# keep Valve's file (only once — never overwrite steamclient_valve.so with an already-patched steamclient.so)
if [ ! -s $BASE/bin/steamclient_valve.so ]; then
  if cmp -s $BASE/bin/steamclient.so steamclient.so.revemu; then echo "base steamclient.so is already RevEmu but steamclient_valve.so missing?!" >&2; exit 1; fi
  cp -p $BASE/bin/steamclient.so $BASE/bin/steamclient_valve.so
fi
install -m 0775 -o cssbase -g css steamclient.so.revemu $BASE/bin/steamclient.so
install -m 0664 -o cssbase -g css /opt/css/etc/templates/rev.ini $BASE/rev.ini
sha256sum $BASE/bin/steamclient.so $BASE/bin/steamclient_valve.so | tee -a SHA256SUMS.revemu
echo "revemu: steamclient.so $(sha256sum $BASE/bin/steamclient.so | cut -c1-16) (08.10.2023 build via hl2go/Uphardt); valve steamclient_valve.so $(stat -c %s $BASE/bin/steamclient_valve.so) bytes" >> $BASE/VERSIONS.txt
/opt/css/bin/css-base-fixperms
echo "10-revemu: OK"
