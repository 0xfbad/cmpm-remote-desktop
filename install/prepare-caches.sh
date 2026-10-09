#!/bin/bash
set -Eeuo pipefail

# students need package metadata offline
timeout --kill-after=5s 300s apt-get update --error-on=any \
  -o Acquire::Retries=3 \
  -o Acquire::Languages=none \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30
apt-get clean
compgen -G '/var/lib/apt/lists/*_Packages*' >/dev/null

install -d /etc/skel/.cache /etc/skel/.config/tealdeer
timeout --kill-after=5s 180s env \
  HOME=/etc/skel XDG_CACHE_HOME=/etc/skel/.cache XDG_CONFIG_HOME=/etc/skel/.config \
  tldr --update
env HOME=/etc/skel XDG_CACHE_HOME=/etc/skel/.cache XDG_CONFIG_HOME=/etc/skel/.config \
  tldr --no-auto-update tar >/dev/null
env HOME=/etc/skel XDG_CACHE_HOME=/etc/skel/.cache XDG_CONFIG_HOME=/etc/skel/.config \
  tldr --no-auto-update apt >/dev/null
apt-cache show bash >/dev/null

mandb >/dev/null
man -w man groff_man gcc g++ gdb >/dev/null
for manual in coreutils bash zsh gcc gdb binutils make tar; do
  [[ $(info --where "$manual") == /usr/share/info/* ]]
done
test -s /usr/share/doc/wireshark/wsug_html_chunked/index.html

install -d /usr/local/share/remote-desktop
date -u +%Y-%m-%dT%H:%M:%SZ >/usr/local/share/remote-desktop/cache-built-at
dpkg-query -W -f='${binary:Package}\t${Version}\n' \
  >/usr/local/share/remote-desktop/packages.tsv
