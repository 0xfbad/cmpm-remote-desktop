#!/usr/bin/env bash
# install.sh -- idempotent per-host provisioning for the rd network pool.
#   1. jq-MERGE default-address-pools into /etc/docker/daemon.json
#   2. create the network pool (net-pool.sh)
#   3. install + enable systemd/rd-net-sysctl.service
#   4. load the nftables bridge assertion
#
# NOT done here: loading nftables/rd-egress.nft.template. It needs per-site
# defines (CTFD_HOST/DNS_SERVERS/NTP_SERVERS/APT_MIRRORS/BLOCKED_DST), and
# its rd_input chain drops new container->host connections, which breaks
# dev host-gateway CTFd topologies. Fill the defines and load it manually
# on prod runners only.
#
# Per-runner env: RD_POOL_BASE, RD_POOL_SIZE, RD_BIND_IP (see README.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_JSON="/etc/docker/daemon.json"

die() {
    echo "install.sh: $*" >&2
    exit 1
}

[[ "$(id -u)" -eq 0 ]] || die "must run as root"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || die "docker is required"
command -v nft >/dev/null 2>&1 || die "nft is required"

# --- 1. daemon.json: merge default-address-pools ---------------------------
# MERGE, never overwrite: the storage provisioning owns log-opts in this same
# file, and any other unrelated keys must survive untouched.
echo "==> merging default-address-pools into $DAEMON_JSON"
current="{}"
if [[ -s "$DAEMON_JSON" ]]; then
    current="$(cat "$DAEMON_JSON")"
    jq -e . >/dev/null 2>&1 <<<"$current" || die "$DAEMON_JSON is not valid JSON; fix it before merging"
fi
merged="$(jq -s '.[0] * .[1]' <(printf '%s' "$current") "$SCRIPT_DIR/daemon.json.example")"

if diff -u <(jq -S . <<<"$current") <(jq -S . <<<"$merged"); then
    echo "    daemon.json already up to date"
else
    # diff exits nonzero when there are changes; the hunk above is the
    # operator-visible preview of exactly what will be applied.
    tmp="$(mktemp)"
    jq -S . <<<"$merged" >"$tmp"
    install -m 0644 "$tmp" "$DAEMON_JSON"
    rm -f "$tmp"
    echo "    applied. NOTE: restart dockerd for the address-pool fence to"
    echo "    take effect (it only affects future subnet-less network creates;"
    echo "    the pinned rd-net-* subnets are unaffected)."
fi

# --- 2. network pool -------------------------------------------------------
echo "==> creating network pool (net-pool.sh)"
"$SCRIPT_DIR/net-pool.sh"
"$SCRIPT_DIR/net-pool.sh" --verify

# --- 3. rd-net-sysctl.service ----------------------------------------------
echo "==> installing rd-net-sysctl.service"
install -m 0644 "$SCRIPT_DIR/systemd/rd-net-sysctl.service" /etc/systemd/system/rd-net-sysctl.service
systemctl daemon-reload
systemctl enable --now rd-net-sysctl.service

# --- 4. nftables bridge assertion ------------------------------------------
# Delete-then-load so reruns don't append duplicate rules to the chain.
echo "==> loading nftables bridge assertion (rd_iso)"
if nft list table bridge rd_iso >/dev/null 2>&1; then
    nft delete table bridge rd_iso
fi
nft -f "$SCRIPT_DIR/nftables/rd-bridge-assert.nft"

echo "==> done. Egress ACL NOT loaded (per-site defines required; rd_input"
echo "    breaks dev host-gateway topologies) -- see nftables/rd-egress.nft.template."
