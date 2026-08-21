#!/usr/bin/env bash
# net-pool.sh -- create (or --verify) the fixed per-host pool of single-tenant
# docker networks rd-net-00..rd-net-{N-1} (bridges rdb00..) with pinned /28
# subnets carved from RD_POOL_BASE. Idempotent: existing networks are skipped,
# networks are never removed here or at runtime.
#
# Per-runner values (see README.md):
#   RD_POOL_BASE  runner1 10.77.0.0/20, runner2 10.77.16.0/20, runner3 10.77.32.0/20
#   RD_POOL_SIZE  must equal the plugin's network_pool_size setting
#   RD_BIND_IP    prod: management/WireGuard address (host_binding_ipv4);
#                 empty (dev) = bind published ports on all interfaces
set -euo pipefail

RD_POOL_SIZE="${RD_POOL_SIZE:-24}"
RD_POOL_BASE="${RD_POOL_BASE:-10.77.0.0/20}"
RD_BIND_IP="${RD_BIND_IP:-}"

ip2int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int2ip() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# slot i -> RD_POOL_BASE + i*16 addresses, as a /28
slot_subnet() {
    local i="$1"
    local base_int
    base_int="$(ip2int "${RD_POOL_BASE%/*}")"
    echo "$(int2ip $(( base_int + i * 16 )))/28"
}

create_pool() {
    local i ii subnet
    for (( i = 0; i < RD_POOL_SIZE; i++ )); do
        ii="$(printf '%02d' "$i")"
        subnet="$(slot_subnet "$i")"
        # Idempotent guard: never touch an existing network.
        docker network inspect "rd-net-$ii" >/dev/null 2>&1 || \
            docker network create \
                --driver bridge \
                --subnet "$subnet" \
                --opt com.docker.network.bridge.name="rdb$ii" \
                --opt com.docker.network.bridge.enable_icc=false \
                ${RD_BIND_IP:+--opt com.docker.network.bridge.host_binding_ipv4=$RD_BIND_IP} \
                --label rd.pool=1 \
                --label rd.slot="$i" \
                "rd-net-$ii"
    done
    echo "pool ready: rd-net-00..rd-net-$(printf '%02d' $(( RD_POOL_SIZE - 1 ))) from $RD_POOL_BASE"
}

verify_pool() {
    local fail=0 i ii name expected actual icc brname count
    count="$(docker network ls --filter label=rd.pool=1 --format '{{.Name}}' | grep -c '^rd-net-' || true)"
    if [[ "$count" -ne "$RD_POOL_SIZE" ]]; then
        echo "FAIL: expected $RD_POOL_SIZE rd-net-* networks (label rd.pool=1), found $count" >&2
        fail=1
    fi
    for (( i = 0; i < RD_POOL_SIZE; i++ )); do
        ii="$(printf '%02d' "$i")"
        name="rd-net-$ii"
        expected="$(slot_subnet "$i")"
        if ! actual="$(docker network inspect -f '{{ (index .IPAM.Config 0).Subnet }}' "$name" 2>/dev/null)"; then
            echo "FAIL: $name does not exist" >&2
            fail=1
            continue
        fi
        if [[ "$actual" != "$expected" ]]; then
            echo "FAIL: $name subnet is $actual, expected $expected" >&2
            fail=1
        fi
        icc="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.enable_icc" }}' "$name")"
        if [[ "$icc" != "false" ]]; then
            echo "FAIL: $name enable_icc is '$icc', expected 'false'" >&2
            fail=1
        fi
        brname="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.name" }}' "$name")"
        if [[ "$brname" != "rdb$ii" ]]; then
            echo "FAIL: $name bridge.name is '$brname', expected 'rdb$ii'" >&2
            fail=1
        fi
        if ! ip link show "rdb$ii" >/dev/null 2>&1; then
            echo "FAIL: bridge link rdb$ii not present" >&2
            fail=1
        fi
    done
    if [[ "$fail" -ne 0 ]]; then
        echo "verify FAILED" >&2
        return 1
    fi
    echo "verify OK: $RD_POOL_SIZE networks, subnets, options, bridge links"
}

main() {
    case "${1:-}" in
        --verify) verify_pool ;;
        "")       create_pool ;;
        *)
            echo "usage: $0 [--verify]" >&2
            exit 2
            ;;
    esac
}

# Allow sourcing for the subnet-math helpers without running main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
