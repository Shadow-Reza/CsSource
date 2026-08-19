#!/usr/bin/env bash
# 04 — Metamod:Source 1.12 + SourceMod 1.12 + RIPExt into the shared base (MISSION §3 stack).
# Base must not change while overlays are mounted: stops all css@ instances first. Run as root.
set -euo pipefail
MM_URL="https://mms.alliedmods.net/mmsdrop/1.12/${MM_FILE:-mmsource-1.12.0-git1225-linux.tar.gz}"
# SM is PINNED to git7179 (2025-02-17): it is the last 1.12 build whose sourcemod.2.css.so targets the v92 interfaces
# (ServerGameClients004 / ServerGameDLL010). git7182+ (2025-02-20, the v93 update) needs ServerGameClients005 /
# ServerGameDLL012 and fails to load on v92 with "Could not find interface: ServerGameClients005". See docs/decisions.md D-005.
SM_URL="https://sm.alliedmods.net/smdrop/1.12/${SM_FILE:-sourcemod-1.12.0-git7179-linux.tar.gz}"
RIPEXT_URL="${RIPEXT_URL:-https://github.com/ErikMinekus/sm-ripext/releases/download/1.3.2/sm-ripext-1.3.2-linux.zip}"
BASE=/opt/css/base; GAME=$BASE/cstrike; DIST=/opt/css/dist
mkdir -p $DIST
for u in css@pub1 css@pub2 css@dm css@gg css@awp css@m1 css@m2; do systemctl stop "$u" 2>/dev/null || true; done
for n in pub1 pub2 dm gg awp m1 m2; do systemctl stop "css-overlay@$n" 2>/dev/null || true; done
if grep -qs "lowerdir=$BASE" /proc/mounts; then echo "overlays still mounted; abort" >&2; exit 1; fi
cd $DIST
for u in "$MM_URL" "$SM_URL" "$RIPEXT_URL"; do f="$(basename "$u")"; [ -s "$f" ] || curl -fsSL -o "$f" "$u"; done
sha256sum "$(basename "$MM_URL")" "$(basename "$SM_URL")" "$(basename "$RIPEXT_URL")" | tee $DIST/SHA256SUMS.mm-sm
# fresh SM tree (a different build may have been there); keep nothing from the old one
rm -rf "$GAME/addons/sourcemod"
tar -xzf "$(basename "$MM_URL")" -C "$GAME"
tar -xzf "$(basename "$SM_URL")" -C "$GAME"
# Chogan core.cfg (DisableAutoUpdate=yes, SteamAuthstringValidation=no) + per-mode optional plugin pool
install -m 0664 /opt/css/etc/templates/sm/core.cfg "$GAME/addons/sourcemod/configs/core.cfg"
install -d -m 2775 "$GAME/addons/sourcemod/plugins/optional"/{public,dm,gg,awp,match}
# RIPExt zip contains addons/sourcemod/{extensions,scripting/include}
rm -rf /tmp/ripext && mkdir -p /tmp/ripext && unzip -q -o "$(basename "$RIPEXT_URL")" -d /tmp/ripext
cp -a /tmp/ripext/addons/. "$GAME/addons/"
ls -la "$GAME/addons/sourcemod/extensions/" | grep -i ripext || echo "WARN: ripext ext not found after copy"
# record versions
echo "metamod: $(basename "$MM_URL")" > $BASE/VERSIONS.txt
echo "sourcemod: $(basename "$SM_URL")" >> $BASE/VERSIONS.txt
echo "ripext: $(basename "$RIPEXT_URL")" >> $BASE/VERSIONS.txt
echo "css buildid: $(grep -oP '"buildid"\s+"\K[0-9]+' $BASE/steamapps/appmanifest_232330.acf)" >> $BASE/VERSIONS.txt
cat $BASE/VERSIONS.txt
/opt/css/bin/css-base-fixperms
echo "04-install-mm-sm: OK"
