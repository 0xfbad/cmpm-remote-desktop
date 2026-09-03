#!/usr/bin/env bash
# install.sh -- idempotent per-host provisioning for the rd network pool.
# All non-dev prototype inputs and the complete nft transaction are validated
# before the first host mutation. The installed policy is then restored before
# Docker on every boot by rd-network-policy.service. This prototype does not
# implement the repository's complete production ingress matrix.
#
# Per-runner env: RD_POOL_BASE, RD_POOL_SIZE, RD_BIND_IP (see README.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_JSON="/etc/docker/daemon.json"
DEV_MODE=0
EGRESS_POLICY="${RD_EGRESS_POLICY:-/etc/rd-egress.nft}"

while [ "$#" -gt 0 ]; do
  case "$1" in
  --dev) DEV_MODE=1 ;;
  --egress-policy)
    shift
    [ "$#" -gt 0 ] || {
      echo "--egress-policy requires a path" >&2
      exit 2
    }
    EGRESS_POLICY="$1"
    ;;
  -h | --help)
    echo "usage: $0 [--dev] [--egress-policy FILE]"
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    exit 2
    ;;
  esac
  shift
done

die() {
  echo "install.sh: $*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || die "must run as root"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || die "docker is required"
command -v nft >/dev/null 2>&1 || die "nft is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
command -v dockerd >/dev/null 2>&1 || die "dockerd is required to validate daemon.json"

# --- preflight: no host mutation above this line ---------------------------
pool_args=()
[ "$DEV_MODE" -eq 1 ] && pool_args+=(--dev)
"$SCRIPT_DIR/net-pool.sh" "${pool_args[@]}" --preflight

current="{}"
if [[ -s $DAEMON_JSON ]]; then
  current="$(cat "$DAEMON_JSON")"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$current" ||
    die "$DAEMON_JSON must contain one valid JSON object; fix it before merging"
fi
merged="$(jq -s '.[0] * .[1]' <(printf '%s' "$current") "$SCRIPT_DIR/daemon.json.example")"

policy_candidate="$(mktemp)"
daemon_candidate="$(mktemp)"
daemon_target_candidate=""
policy_target_candidate=""
network_config_candidate=""
cleanup() {
  rm -f "$policy_candidate" "$daemon_candidate"
  [ -z "$daemon_target_candidate" ] || rm -f "$daemon_target_candidate"
  [ -z "$policy_target_candidate" ] || rm -f "$policy_target_candidate"
  [ -z "$network_config_candidate" ] || rm -f "$network_config_candidate"
}
trap cleanup EXIT
jq -S . <<<"$merged" >"$daemon_candidate"
dockerd --validate --config-file "$daemon_candidate" >/dev/null ||
  die "dockerd rejected the merged daemon.json; host was not modified"

if [ "$DEV_MODE" -eq 1 ]; then
  {
    printf 'destroy table bridge rd_iso\n'
    printf 'destroy table ip rd_egress\n'
    cat "$SCRIPT_DIR/nftables/rd-bridge-assert.nft"
  } >"$policy_candidate"
else
  [ -f "$EGRESS_POLICY" ] || die "non-dev prototype egress policy missing: $EGRESS_POLICY (copy and fill nftables/rd-egress.nft.template)"
  # Comments intentionally explain which values to replace; only executable
  # define/rule lines count for placeholder rejection.
  if sed 's/[[:space:]]*#.*$//' "$EGRESS_POLICY" | grep -Eq '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|REPLACE'; then
    die "$EGRESS_POLICY still contains documentation placeholders"
  fi
  [ -n "${RD_PROXY_CIDRS:-}" ] || die "RD_PROXY_CIDRS is required in non-dev prototype mode"
  [ -n "${RD_RUNNER_PEER_CIDRS:-}" ] || die "RD_RUNNER_PEER_CIDRS is required in non-dev prototype mode"
  mapfile -t normalized_cidrs < <(
    python3 - "$RD_PROXY_CIDRS" "$RD_RUNNER_PEER_CIDRS" <<'PY'
import ipaddress
import sys

for label, raw in zip(("RD_PROXY_CIDRS", "RD_RUNNER_PEER_CIDRS"), sys.argv[1:]):
    values = [item.strip() for item in raw.split(",") if item.strip()]
    if not values:
        raise SystemExit(f"install.sh: {label} must contain at least one IPv4 CIDR")
    networks = []
    for value in values:
        try:
            network = ipaddress.IPv4Network(value, strict=True)
        except ValueError as exc:
            raise SystemExit(f"install.sh: invalid {label} entry {value!r}: {exc}")
        private_ranges = (
            ipaddress.IPv4Network("10.0.0.0/8"),
            ipaddress.IPv4Network("172.16.0.0/12"),
            ipaddress.IPv4Network("192.168.0.0/16"),
        )
        if network.prefixlen != 32 or not any(network.subnet_of(r) for r in private_ranges):
            raise SystemExit(
                f"install.sh: {label} entries must be exact RFC1918 IPv4 /32 hosts"
            )
        networks.append(str(network))
    print(", ".join(networks))
PY
  )
  [ "${#normalized_cidrs[@]}" -eq 2 ] || die "CIDR normalization failed"
  proxy_cidrs="${normalized_cidrs[0]}"
  runner_peer_cidrs="${normalized_cidrs[1]}"
  case ", ${runner_peer_cidrs}," in
  *", ${RD_BIND_IP}/32,"*) ;;
  *) die "RD_RUNNER_PEER_CIDRS must include this runner's RD_BIND_IP (${RD_BIND_IP}/32)" ;;
  esac
  {
    # `destroy` is idempotent when a table is absent. Both destroys and both
    # declarations are one nft input and therefore one atomic transaction.
    printf 'destroy table bridge rd_iso\n'
    printf 'destroy table ip rd_egress\n'
    printf 'define PROXY_CIDRS = { %s }\n' "$proxy_cidrs"
    printf 'define RUNNER_PEER_CIDRS = { %s }\n' "$runner_peer_cidrs"
    cat "$SCRIPT_DIR/nftables/rd-bridge-assert.nft"
    cat "$EGRESS_POLICY"
  } >"$policy_candidate"
fi
nft -c -f "$policy_candidate" || die "candidate nftables policy failed syntax/kernel validation; host was not modified"

# --- 1. daemon.json: merge default-address-pools ---------------------------
# MERGE, never overwrite: the storage provisioning owns log-opts in this same
# file, and any other unrelated keys must survive untouched.
echo "==> merging default-address-pools into $DAEMON_JSON"
if diff -u <(jq -S . <<<"$current") <(jq -S . <<<"$merged"); then
  echo "    daemon.json already up to date"
else
  # diff exits nonzero when there are changes; the hunk above is the
  # operator-visible preview of exactly what will be applied.
  daemon_dir="${DAEMON_JSON%/*}"
  mkdir -p "$daemon_dir"
  daemon_target_candidate="$(mktemp "$daemon_dir/.daemon.json.XXXXXX")"
  install -m 0644 "$daemon_candidate" "$daemon_target_candidate"
  chown root:root "$daemon_target_candidate"
  if [[ -f $DAEMON_JSON ]]; then
    cp -a -- "$DAEMON_JSON" "$DAEMON_JSON.bak.$(date +%s%N)"
  fi
  mv -f -- "$daemon_target_candidate" "$DAEMON_JSON"
  daemon_target_candidate=""
  echo "    applied. NOTE: restart dockerd for the address-pool fence to"
  echo "    take effect (it only affects future subnet-less network creates;"
  echo "    the pinned rd-net-* subnets are unaffected)."
fi

# --- 2. network pool -------------------------------------------------------
echo "==> creating network pool (net-pool.sh)"
"$SCRIPT_DIR/net-pool.sh" "${pool_args[@]}"
"$SCRIPT_DIR/net-pool.sh" "${pool_args[@]}" --verify

# --- 3. rd-net-sysctl.service ----------------------------------------------
echo "==> installing rd-net-sysctl.service"
install -D -m 0644 "$SCRIPT_DIR/systemd/rd-net-sysctl.service" /etc/systemd/system/rd-net-sysctl.service
systemctl daemon-reload
systemctl enable --now rd-net-sysctl.service

# --- 4. atomic, reboot-persistent nftables policy --------------------------
if [ "$DEV_MODE" -eq 1 ]; then
  echo "==> DEV MODE: loading non-persistent bridge assertion only"
  nft -f "$policy_candidate"
  echo "    Do not use --dev on a runner that hosts untrusted student sessions."
else
  echo "==> installing atomic reboot-persistent nftables policy"
  policy_target_candidate="$(mktemp /etc/.rd-network-policy.nft.XXXXXX)"
  install -m 0600 "$policy_candidate" "$policy_target_candidate"
  chown root:root "$policy_target_candidate"
  mv -f -- "$policy_target_candidate" /etc/rd-network-policy.nft
  policy_target_candidate=""
  install -D -m 0755 "$SCRIPT_DIR/bin/rd-network-policy-load.sh" /usr/local/lib/rd-network-policy-load.sh
  install -D -m 0644 "$SCRIPT_DIR/systemd/rd-network-policy.service" /etc/systemd/system/rd-network-policy.service
  install -D -m 0644 "$SCRIPT_DIR/systemd/docker.service.d/10-rd-network-policy.conf" \
    /etc/systemd/system/docker.service.d/10-rd-network-policy.conf
  network_config_candidate="$(mktemp /etc/.rd-network.conf.XXXXXX)"
  {
    printf 'RD_NETWORK_POLICY_VERSION=1\n'
    printf 'RD_POOL_BASE=%q\n' "${RD_POOL_BASE:-10.77.0.0/20}"
    printf 'RD_POOL_SIZE=%q\n' "${RD_POOL_SIZE:-24}"
    printf 'RD_BIND_IP=%q\n' "${RD_BIND_IP:-}"
    printf 'RD_PROXY_CIDRS=%q\n' "$proxy_cidrs"
    printf 'RD_RUNNER_PEER_CIDRS=%q\n' "$runner_peer_cidrs"
  } >"$network_config_candidate"
  chmod 0600 "$network_config_candidate"
  chown root:root "$network_config_candidate"
  mv -f -- "$network_config_candidate" /etc/rd-network.conf
  network_config_candidate=""
  systemctl daemon-reload
  systemctl enable rd-network-policy.service
  if systemctl is-active --quiet rd-network-policy.service; then
    systemctl reload rd-network-policy.service
  else
    systemctl start rd-network-policy.service
  fi
fi

echo "==> done"
