#!/bin/bash
set -euo pipefail

HX_URL=$(curl -sfL https://api.github.com/repos/helix-editor/helix/releases/latest |
  grep "browser_download_url.*x86_64-linux" |
  head -1 |
  cut -d '"' -f 4)
[ -n "$HX_URL" ] || {
  echo "no helix release url found" >&2
  exit 1
}

curl -fLo /tmp/helix.tar.xz "$HX_URL"
mkdir -p /opt/helix
tar -xf /tmp/helix.tar.xz -C /opt/helix --strip-components=1
ln -sf /opt/helix/hx /usr/local/bin/hx
rm /tmp/helix.tar.xz
