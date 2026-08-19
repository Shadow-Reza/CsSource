#!/usr/bin/env bash
# 03 — users, groups, directory layout, permissions for the shared-base + overlay design (MISSION §6.1, D-004).
# Idempotent. Run as root.
set -euo pipefail
INSTANCES="pub1 pub2 dm gg awp m1 m2"
getent group css >/dev/null || groupadd --system css
usermod -a -G css cssbase
for n in $INSTANCES; do
  u="css-$n"; I="/opt/css/instances/$n"
  id -u "$u" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$I/home" --shell /usr/sbin/nologin -g css --comment "CSS instance $n" "$u"
  mkdir -p "$I/upper" "$I/work" "$I/root" "$I/home"
  chown root:root "$I" "$I/work" "$I/root"; chmod 755 "$I" "$I/root"; chmod 700 "$I/work"
  mountpoint -q "$I/root" || { chown cssbase:css "$I/upper"; chmod 2775 "$I/upper"; }
  chown "$u:css" "$I/home"; chmod 750 "$I/home"
done
mkdir -p /opt/css/etc/instances /opt/css/etc/secrets /var/log/css /run/css
chmod 750 /opt/css/etc/secrets
# base is owned by cssbase, group css; group-writable so that instance users can write in the overlay's merged view
# (writes land in the per-instance upper dir; the on-disk base is additionally ReadOnlyPaths= inside every unit).
/opt/css/bin/css-base-fixperms
echo "03-layout: OK"
