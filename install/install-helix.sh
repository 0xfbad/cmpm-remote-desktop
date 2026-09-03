#!/bin/bash
set -euo pipefail

HELIX_VERSION=25.07.1
HELIX_SHA256=3f08e63ecd388fff657ad39722f88bb03dcf326f1f2da2700d99e1dc40ab2e8b
HX_URL="https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/helix-${HELIX_VERSION}-x86_64-linux.tar.xz"

curl --proto '=https' --tlsv1.2 -fsSL "$HX_URL" -o /tmp/helix.tar.xz
echo "$HELIX_SHA256  /tmp/helix.tar.xz" | sha256sum -c -
mkdir -p /opt/helix
tar -xf /tmp/helix.tar.xz -C /opt/helix --strip-components=1
ln -sf /opt/helix/hx /usr/local/bin/hx
rm /tmp/helix.tar.xz
