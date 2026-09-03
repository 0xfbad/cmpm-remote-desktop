#!/usr/bin/env bash
# Fail closed unless the transcript store is a separate, finite block-backed
# XFS filesystem with defensive mount options.
set -euo pipefail

store="${RD_TLOG_STORE:-/var/lib/rd-tlog}"
minimum_store_bytes="${RD_TLOG_MINIMUM_STORE_BYTES:-47244640256}"

fail() {
  echo "rd-tlog store check: $*" >&2
  exit 1
}

command -v findmnt >/dev/null 2>&1 || fail "findmnt is required"
command -v df >/dev/null 2>&1 || fail "df is required"
mountpoint -q "$store" || fail "$store is not a dedicated mountpoint"

fstype="$(findmnt -n -o FSTYPE --target "$store")"
[ "$fstype" = xfs ] || fail "$store uses $fstype, expected xfs"

source="$(findmnt -n -o SOURCE --target "$store")"
source="${source%%\[*}"
source="$(readlink -f "$source" 2>/dev/null || true)"
[ -n "$source" ] && [ -b "$source" ] || fail "$store source is not a block device"

store_device="$(findmnt -n -o MAJ:MIN --target "$store")"
root_device="$(findmnt -n -o MAJ:MIN --target /)"
[ -n "$store_device" ] && [ "$store_device" != "$root_device" ] ||
  fail "$store must not share the root filesystem block device"

options="$(findmnt -n -o OPTIONS --target "$store")"
for option in nodev nosuid noexec; do
  case ",$options," in
  *",$option,"*) ;;
  *) fail "$store is missing mount option $option" ;;
  esac
done

store_bytes="$(df -P -B1 "$store" | awk 'NR == 2 { print $2 }')"
case "$store_bytes" in
'' | *[!0-9]*) fail "could not determine filesystem size" ;;
esac
[ "$store_bytes" -ge "$minimum_store_bytes" ] ||
  fail "$store is ${store_bytes} bytes; at least ${minimum_store_bytes} bytes is required"
