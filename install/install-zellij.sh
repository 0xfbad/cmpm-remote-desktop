#!/bin/bash
set -e

ZELLIJ_URL=$(curl -sfL https://api.github.com/repos/zellij-org/zellij/releases/latest |
  grep '"browser_download_url"' |
  grep 'x86_64-unknown-linux-musl\.tar\.gz' |
  head -1 |
  cut -d '"' -f 4)

curl -fLo /tmp/zellij.tar.gz "$ZELLIJ_URL"
tar xf /tmp/zellij.tar.gz -C /usr/local/bin zellij
chmod +x /usr/local/bin/zellij
rm /tmp/zellij.tar.gz
