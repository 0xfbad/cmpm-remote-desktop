#!/usr/bin/env bash
# Validate, then atomically replace both rd nftables tables in one nft batch.
set -euo pipefail

POLICY_FILE="${RD_NETWORK_POLICY_FILE:-/etc/rd-network-policy.nft}"

[ -r "$POLICY_FILE" ] || {
  echo "rd network policy is missing: $POLICY_FILE" >&2
  exit 1
}
command -v nft >/dev/null 2>&1 || {
  echo "nft is required" >&2
  exit 1
}

# `nft -f` applies every command in one netlink transaction. A failed check or
# apply therefore leaves the currently-loaded ruleset intact.
nft -c -f "$POLICY_FILE"
nft -f "$POLICY_FILE"

# These comments are stable contract markers emitted by nft list output.
rules="$(nft list ruleset)"
for marker in rd-peer-session-drop-v1 rd-runner-peer-drop-v1 rd-proxy-web-allow-v1 rd-proxy-web-return-v1 rd-proxy-web-drop-v1 rd-raw-vnc-drop-v1 rd-host-input-drop-v1 rd-bridge-drop-v1; do
  grep -q "comment \"$marker\"" <<<"$rules" || {
    echo "loaded ruleset is missing $marker" >&2
    exit 1
  }
done
