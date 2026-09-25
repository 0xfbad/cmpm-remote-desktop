#!/usr/bin/env bash
set -euo pipefail

UBLOCK_VERSION=1.75.0
UBLOCK_FILE_ID=5034826
UBLOCK_SHA256=5b74415860456370644bd80f16125e865b0e6c356bb5dfcfb84069967eaa5287

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

curl --fail --location --silent --show-error \
  --proto '=https' --tlsv1.2 \
  --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 15 \
  "https://addons.mozilla.org/firefox/downloads/file/$UBLOCK_FILE_ID/ublock_origin-$UBLOCK_VERSION.xpi" \
  -o "$tmpdir/ublock-origin.xpi"
printf '%s  %s\n' "$UBLOCK_SHA256" "$tmpdir/ublock-origin.xpi" | sha256sum --check --status
install -Dm644 "$tmpdir/ublock-origin.xpi" /usr/local/share/firefox/extensions/ublock-origin.xpi
