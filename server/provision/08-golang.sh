#!/usr/bin/env bash
# 08 — Go toolchain to build cg-agent on the box. go.dev/dl.google.com return 404/403 from this VM's network
# (Google blocks the region), so use Ubuntu's packaged golang-1.22 (jammy-updates). Run as root.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q --no-install-recommends golang-1.22-go >/dev/null
ln -sf /usr/lib/go-1.22/bin/go /usr/local/bin/go; ln -sf /usr/lib/go-1.22/bin/gofmt /usr/local/bin/gofmt
go version; echo "08-golang: OK"
