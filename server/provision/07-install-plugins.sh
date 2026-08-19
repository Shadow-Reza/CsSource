#!/usr/bin/env bash
# 07 — SMAC (srcdslab) + Lilac (srcdslab) + stock map-vote plugins into the shared base. Stops instances first.
set -euo pipefail
BASE=/opt/css/base; GAME=$BASE/cstrike; SM=$GAME/addons/sourcemod; DIST=/opt/css/dist
SMAC_URL="${SMAC_URL:-https://github.com/srcdslab/sm-plugin-SMAC/releases/download/latest/sm-plugin-SMAC-latest.tar.gz}"
LILAC_URL="${LILAC_URL:-https://github.com/srcdslab/sm-plugin-lilac/releases/download/latest/sm-plugin-lilac-latest.tar.gz}"
for u in css@pub1 css@pub2 css@dm css@gg css@awp css@m1 css@m2; do systemctl stop "$u" 2>/dev/null || true; done
for n in pub1 pub2 dm gg awp m1 m2; do systemctl stop "css-overlay@$n" 2>/dev/null || true; done
grep -qs "lowerdir=$BASE" /proc/mounts && { echo "overlays still mounted; abort" >&2; exit 1; }
mkdir -p $DIST; cd $DIST
for u in "$SMAC_URL" "$LILAC_URL"; do f="$(basename "$u")"; curl -fsSL -o "$f" "$u"; done   # rolling 'latest' → always refetch
sha256sum "$(basename "$SMAC_URL")" "$(basename "$LILAC_URL")" | tee -a $DIST/SHA256SUMS.plugins
rm -rf /tmp/smac /tmp/lilac; mkdir -p /tmp/smac /tmp/lilac
tar -xzf "$(basename "$SMAC_URL")" -C /tmp/smac; tar -xzf "$(basename "$LILAC_URL")" -C /tmp/lilac
echo "--- smac tarball ---"; find /tmp/smac -type f | sed 's|/tmp/smac/||' | head -40
echo "--- lilac tarball ---"; find /tmp/lilac -type f | sed 's|/tmp/lilac/||' | head -20
# locate the addons root inside each tarball
SMAC_ROOT=$(dirname "$(find /tmp/smac -type d -name sourcemod | head -1)")
LILAC_ROOT=$(dirname "$(find /tmp/lilac -type d -name sourcemod | head -1)")
# copy everything except plugins (translations, gamedata, configs, scripting)
for R in "$SMAC_ROOT" "$LILAC_ROOT"; do
  (cd "$R" && find sourcemod -type f ! -path 'sourcemod/plugins/*' -exec install -D -m 0664 {} "$GAME/addons/{}" \;)
done
# plugins: SMAC modules we load (log-only phase; smac_cvars deliberately excluded; hl2dm/l4d2 fixes irrelevant)
install -d -m 2775 $SM/plugins/disabled/smac-not-loaded
for m in smac smac_wallhack smac_aimbot smac_autotrigger smac_eyetest smac_speedhack smac_spinhack smac_client smac_commands smac_rcon smac_css_antiflash smac_css_antismoke smac_css_fixes; do
  f=$(find "$SMAC_ROOT" -name "$m.smx" | head -1); [ -n "$f" ] && install -m 0664 "$f" "$SM/plugins/$m.smx" || echo "WARN: $m.smx not in tarball"
done
for m in smac_cvars smac_hl2dm_fixes smac_l4d2_fixes; do f=$(find "$SMAC_ROOT" -name "$m.smx" | head -1); [ -n "$f" ] && install -m 0664 "$f" "$SM/plugins/disabled/smac-not-loaded/$m.smx"; done
f=$(find "$LILAC_ROOT" -name "lilac.smx" | head -1); install -m 0664 "$f" "$SM/plugins/lilac.smx"
# stock map-vote plugins into the per-mode optional pools
for mode in public dm gg awp; do for p in mapchooser nominations rockthevote; do install -m 0664 "$SM/plugins/disabled/$p.smx" "$SM/plugins/optional/$mode/$p.smx"; done; done
echo "smac: $(basename "$SMAC_URL") $(sha256sum "$(basename "$SMAC_URL")" | cut -c1-16) $(date -u +%F)" >> $BASE/VERSIONS.txt
echo "lilac: $(basename "$LILAC_URL") $(sha256sum "$(basename "$LILAC_URL")" | cut -c1-16) $(date -u +%F)" >> $BASE/VERSIONS.txt
/opt/css/bin/css-base-fixperms
ls $SM/plugins/ | tr '\n' ' '; echo
echo "07-install-plugins: OK"
