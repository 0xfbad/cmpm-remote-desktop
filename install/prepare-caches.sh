#!/bin/bash
set -Eeuo pipefail

# keep package lists so students can install tools without a startup download
timeout --kill-after=5s 300s apt-get update --error-on=any \
  -o Acquire::Retries=3 \
  -o Acquire::Languages=none \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30
apt-get clean
compgen -G '/var/lib/apt/lists/*_Packages*' >/dev/null

install -d /etc/skel/.cache /etc/skel/.config/tealdeer
# these paths must not override the student home at runtime
timeout --kill-after=5s 180s env \
  HOME=/etc/skel XDG_CACHE_HOME=/etc/skel/.cache XDG_CONFIG_HOME=/etc/skel/.config \
  tldr --update
env HOME=/etc/skel XDG_CACHE_HOME=/etc/skel/.cache XDG_CONFIG_HOME=/etc/skel/.config \
  tldr --no-auto-update tar >/dev/null
env HOME=/etc/skel XDG_CACHE_HOME=/etc/skel/.cache XDG_CONFIG_HOME=/etc/skel/.config \
  tldr --no-auto-update apt >/dev/null
apt-cache show bash >/dev/null

install -d /usr/local/share/remote-desktop
date -u +%Y-%m-%dT%H:%M:%SZ >/usr/local/share/remote-desktop/cache-built-at
dpkg-query -W -f='${binary:Package}\t${Version}\n' \
  >/usr/local/share/remote-desktop/packages.tsv
