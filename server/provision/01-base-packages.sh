#!/usr/bin/env bash
# 01 — base OS packages for a 32-bit srcds host (MISSION §6.1). Idempotent. Run as root.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386
apt-get update -q
# i386 runtime for srcds_linux (32-bit). lib32gcc1 does not exist on jammy/noble; libncurses5 is stale.
apt-get install -y -q --no-install-recommends \
  lib32gcc-s1 lib32stdc++6 libc6:i386 libncurses6:i386 libtinfo6:i386 libcurl4:i386 libstdc++6:i386 zlib1g:i386 \
  ca-certificates curl wget tar bzip2 unzip zip jq git tmux htop iotop lsof strace file rsync \
  nftables python3 python3-venv python3-pip binutils
# steamcmd from Valve's tarball (no debconf licence prompt, no multiverse dependency)
id -u cssbase >/dev/null 2>&1 || useradd --system --home-dir /opt/css/steamcmd --shell /usr/sbin/nologin --comment "CSS shared base owner" cssbase
mkdir -p /opt/css/steamcmd /opt/css/base /opt/css/instances /opt/css/bin /opt/css/etc /var/log/css
chown -R cssbase:cssbase /opt/css/steamcmd /opt/css/base
if [ ! -x /opt/css/steamcmd/steamcmd.sh ]; then
  curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o /tmp/steamcmd_linux.tar.gz
  tar -xzf /tmp/steamcmd_linux.tar.gz -C /opt/css/steamcmd
  chown -R cssbase:cssbase /opt/css/steamcmd
fi
echo "01-base-packages: OK"
