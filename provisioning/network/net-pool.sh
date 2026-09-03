#!/usr/bin/env bash
# net-pool.sh -- create (or --verify) the fixed per-host pool of single-tenant
# docker networks rd-net-00..rd-net-{N-1} (bridges rdb00..) with pinned /28
# subnets carved from RD_POOL_BASE. Idempotent: existing networks are skipped,
# networks are never removed here or at runtime.
#
# Per-runner values (see README.md):
#   RD_POOL_BASE  runner1 10.77.0.0/20, runner2 10.77.16.0/20, runner3 10.77.32.0/20
#   RD_POOL_SIZE  prototype slot count; the current plugin has no matching setting
#   RD_BIND_IP    non-dev prototype mode: REQUIRED private management/WireGuard
#                 address used as host_binding_ipv4. Empty requires --dev.
set -euo pipefail

RD_POOL_SIZE="${RD_POOL_SIZE:-24}"
RD_POOL_BASE="${RD_POOL_BASE:-10.77.0.0/20}"
RD_BIND_IP="${RD_BIND_IP:-}"
DEV_MODE=0

die() {
  echo "net-pool.sh: $*" >&2
  exit 1
}

preflight() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v ip >/dev/null 2>&1 || die "iproute2 is required"
  python3 - "$RD_POOL_BASE" "$RD_POOL_SIZE" "$RD_BIND_IP" "$DEV_MODE" <<'PY'
import ipaddress
import sys

pool_text, size_text, bind_text, dev_text = sys.argv[1:]
try:
    pool = ipaddress.IPv4Network(pool_text, strict=True)
    size = int(size_text)
except (ValueError, TypeError) as exc:
    raise SystemExit(f"net-pool.sh: invalid pool configuration: {exc}")
if size < 1 or size > 256:
    raise SystemExit("net-pool.sh: RD_POOL_SIZE must be between 1 and 256")
if pool.prefixlen > 28 or size * 16 > pool.num_addresses:
    raise SystemExit(
        f"net-pool.sh: {pool} cannot contain {size} non-overlapping /28 slots"
    )
if not pool.subnet_of(ipaddress.IPv4Network("10.77.0.0/16")):
    raise SystemExit("net-pool.sh: RD_POOL_BASE must be inside the protected 10.77.0.0/16 pool")
if dev_text != "1":
    if not bind_text:
        raise SystemExit("net-pool.sh: RD_BIND_IP is required in non-dev prototype mode")
    try:
        bind = ipaddress.IPv4Address(bind_text)
    except ValueError as exc:
        raise SystemExit(f"net-pool.sh: invalid RD_BIND_IP: {exc}")
    private_ranges = (
        ipaddress.IPv4Network("10.0.0.0/8"),
        ipaddress.IPv4Network("172.16.0.0/12"),
        ipaddress.IPv4Network("192.168.0.0/16"),
    )
    if not any(bind in network for network in private_ranges):
        raise SystemExit(
            "net-pool.sh: RD_BIND_IP must be an RFC1918 IPv4 address"
        )
PY
  if [ "$DEV_MODE" -ne 1 ]; then
    ip -4 -o address show | awk -v wanted="$RD_BIND_IP" '{ split($4, address, "/"); if (address[1] == wanted) found=1 } END { exit !found }' ||
      die "RD_BIND_IP is not assigned to a local interface: $RD_BIND_IP"
  fi
}

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

int2ip() {
  local n="$1"
  echo "$(((n >> 24) & 255)).$(((n >> 16) & 255)).$(((n >> 8) & 255)).$((n & 255))"
}

# slot i -> RD_POOL_BASE + i*16 addresses, as a /28
slot_subnet() {
  local i="$1"
  local base_int
  base_int="$(ip2int "${RD_POOL_BASE%/*}")"
  echo "$(int2ip $((base_int + i * 16)))/28"
}

create_pool() {
  preflight
  local i ii subnet
  local -a create_args
  for ((i = 0; i < RD_POOL_SIZE; i++)); do
    ii="$(printf '%02d' "$i")"
    subnet="$(slot_subnet "$i")"
    # Idempotent guard: never touch an existing network.
    if ! docker network inspect "rd-net-$ii" >/dev/null 2>&1; then
      create_args=(
        --driver bridge
        --subnet "$subnet"
        --opt "com.docker.network.bridge.name=rdb$ii"
        --opt com.docker.network.bridge.enable_icc=false
      )
      if [[ -n $RD_BIND_IP ]]; then
        create_args+=(--opt "com.docker.network.bridge.host_binding_ipv4=$RD_BIND_IP")
      fi
      docker network create \
        "${create_args[@]}" \
        --label rd.pool=1 \
        --label rd.slot="$i" \
        "rd-net-$ii"
    fi
  done
  echo "pool ready: rd-net-00..rd-net-$(printf '%02d' $((RD_POOL_SIZE - 1))) from $RD_POOL_BASE"
}

verify_pool() {
  preflight
  local fail=0 i ii name expected actual icc brname bind count
  count="$(docker network ls --filter label=rd.pool=1 --format '{{.Name}}' | grep -c '^rd-net-' || true)"
  if [[ $count -ne $RD_POOL_SIZE ]]; then
    echo "FAIL: expected $RD_POOL_SIZE rd-net-* networks (label rd.pool=1), found $count" >&2
    fail=1
  fi
  for ((i = 0; i < RD_POOL_SIZE; i++)); do
    ii="$(printf '%02d' "$i")"
    name="rd-net-$ii"
    expected="$(slot_subnet "$i")"
    if ! actual="$(docker network inspect -f '{{ (index .IPAM.Config 0).Subnet }}' "$name" 2>/dev/null)"; then
      echo "FAIL: $name does not exist" >&2
      fail=1
      continue
    fi
    if [[ $actual != "$expected" ]]; then
      echo "FAIL: $name subnet is $actual, expected $expected" >&2
      fail=1
    fi
    icc="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.enable_icc" }}' "$name")"
    if [[ $icc != "false" ]]; then
      echo "FAIL: $name enable_icc is '$icc', expected 'false'" >&2
      fail=1
    fi
    brname="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.name" }}' "$name")"
    if [[ $brname != "rdb$ii" ]]; then
      echo "FAIL: $name bridge.name is '$brname', expected 'rdb$ii'" >&2
      fail=1
    fi
    bind="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.host_binding_ipv4" }}' "$name")"
    if [[ -n $RD_BIND_IP && $bind != "$RD_BIND_IP" ]]; then
      echo "FAIL: $name host_binding_ipv4 is '$bind', expected '$RD_BIND_IP'" >&2
      fail=1
    fi
    if [[ $DEV_MODE -ne 1 && -z $bind ]]; then
      echo "FAIL: $name has no host_binding_ipv4 in non-dev prototype mode" >&2
      fail=1
    fi
    if ! ip link show "rdb$ii" >/dev/null 2>&1; then
      echo "FAIL: bridge link rdb$ii not present" >&2
      fail=1
    fi
  done
  if [[ $fail -ne 0 ]]; then
    echo "verify FAILED" >&2
    return 1
  fi
  echo "verify OK: $RD_POOL_SIZE networks, subnets, options, bridge links"
}

main() {
  local mode=create
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dev) DEV_MODE=1 ;;
    --preflight) mode=preflight ;;
    --verify) mode=verify ;;
    *) die "usage: $0 [--dev] [--preflight|--verify]" ;;
    esac
    shift
  done
  case "$mode" in
  create) create_pool ;;
  preflight) preflight ;;
  verify) verify_pool ;;
  esac
}

# Allow sourcing for the subnet-math helpers without running main.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
