#!/bin/bash
set -euo pipefail

PWNDBG_VERSION=2026.07.29
PWNDBG_SHA256=27030bb5c86e54a386aed88a309a844483fe0ef63e0be28ab7a024e0e627a79b
PWNDBG_URL="https://github.com/pwndbg/pwndbg/releases/download/${PWNDBG_VERSION}/pwndbg_${PWNDBG_VERSION}_amd64.deb"

curl --proto '=https' --tlsv1.2 -fsSL \
  --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 15 "$PWNDBG_URL" -o /tmp/pwndbg.deb
echo "$PWNDBG_SHA256  /tmp/pwndbg.deb" | sha256sum -c -
apt-get update
apt-get install -y /tmp/pwndbg.deb
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/pwndbg.deb
