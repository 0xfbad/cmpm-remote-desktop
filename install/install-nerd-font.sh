#!/bin/bash
set -euo pipefail

FONT_VERSION=v3.5.1
FONT_SHA256=04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf
FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/JetBrainsMono.tar.xz"

mkdir -p /usr/share/fonts/truetype/jetbrains-mono-nerd
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --retry 5 --retry-delay 2 --retry-all-errors \
  --connect-timeout 15 --max-time 300 \
  "$FONT_URL" -o /tmp/jbmono-nf.tar.xz
echo "$FONT_SHA256  /tmp/jbmono-nf.tar.xz" | sha256sum -c -
tar --extract --xz --file=/tmp/jbmono-nf.tar.xz \
  --directory=/usr/share/fonts/truetype/jetbrains-mono-nerd \
  --no-same-owner \
  JetBrainsMonoNerdFontMono-Regular.ttf \
  JetBrainsMonoNerdFontMono-Bold.ttf \
  JetBrainsMonoNerdFontMono-Italic.ttf \
  JetBrainsMonoNerdFontMono-BoldItalic.ttf
chmod 0644 /usr/share/fonts/truetype/jetbrains-mono-nerd/*.ttf
fc-cache -f
rm /tmp/jbmono-nf.tar.xz
