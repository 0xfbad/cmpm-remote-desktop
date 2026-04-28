#!/bin/bash
set -euo pipefail

# match pwndbg_*_amd64.deb, not pwndbg-lldb
PWNDBG_URL=$(curl -sfL https://api.github.com/repos/pwndbg/pwndbg/releases/latest |
  grep '"browser_download_url"' |
  grep 'pwndbg_.*amd64.*\.deb' |
  head -1 |
  cut -d '"' -f 4)
[ -n "$PWNDBG_URL" ] || {
  echo "no pwndbg release url found" >&2
  exit 1
}

curl -fLo /tmp/pwndbg.deb "$PWNDBG_URL"
apt-get install -y /tmp/pwndbg.deb
rm /tmp/pwndbg.deb
