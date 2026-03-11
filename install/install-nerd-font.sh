#!/bin/bash
set -e

FONT_URL=$(curl -sfL https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest \
    | grep '"browser_download_url"' \
    | grep 'JetBrainsMono\.tar\.xz' \
    | head -1 \
    | cut -d '"' -f 4)

mkdir -p /usr/share/fonts/truetype/jetbrains-mono-nerd
curl -fLo /tmp/jbmono-nf.tar.xz "$FONT_URL"
tar xf /tmp/jbmono-nf.tar.xz -C /usr/share/fonts/truetype/jetbrains-mono-nerd
fc-cache -f
rm /tmp/jbmono-nf.tar.xz
