#!/bin/bash
set -euo pipefail

ZELLIJ_VERSION=v0.45.0
ZELLIJ_SHA256=ab8b2494d80c20c07da4361041a25b96b93c73df992d2d54143e70fb9b1a1063
ZELLIJ_URL="https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz"

curl --proto '=https' --tlsv1.2 -fsSL "$ZELLIJ_URL" -o /tmp/zellij.tar.gz
echo "$ZELLIJ_SHA256  /tmp/zellij.tar.gz" | sha256sum -c -
tar xf /tmp/zellij.tar.gz -C /usr/local/bin zellij
chmod +x /usr/local/bin/zellij
rm /tmp/zellij.tar.gz
