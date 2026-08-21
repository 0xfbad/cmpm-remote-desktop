#!/usr/bin/env bash
# install.sh - provision a compute host for ctfd-remote-desktop sessions.
#
#   install.sh [install]   install units + telemetry, then run verify
#   install.sh verify      verification only; exits non-zero on any failure
#
# The prod runner image build MUST run this script (install mode ends with
# verify). See README.md: an unprovisioned host silently gets an unlimited
# implicitly-created rd.slice.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER_IMAGE="${READER_IMAGE:-busybox:latest}"

if [ "$(id -u)" -ne 0 ]; then
    echo "FAIL: must run as root" >&2
    exit 1
fi

do_install() {
    set -e
    install -D -m 0644 "$SCRIPT_DIR/systemd/rd.slice" /etc/systemd/system/rd.slice
    install -D -m 0644 "$SCRIPT_DIR/systemd/system.slice.d/50-rd-host-reserve.conf" \
        /etc/systemd/system/system.slice.d/50-rd-host-reserve.conf
    install -D -m 0644 "$SCRIPT_DIR/telemetry/rd-telemetry.service" \
        /etc/systemd/system/rd-telemetry.service
    install -D -m 0644 "$SCRIPT_DIR/telemetry/rd-telemetry.timer" \
        /etc/systemd/system/rd-telemetry.timer
    install -D -m 0644 "$SCRIPT_DIR/sysctl.d/90-rd-pidmax.conf" \
        /etc/sysctl.d/90-rd-pidmax.conf
    install -D -m 0755 "$SCRIPT_DIR/telemetry/rd-telemetry.sh" \
        /usr/local/lib/rd-telemetry.sh
    mkdir -p /var/lib/rd-telemetry

    systemctl daemon-reload
    systemctl enable --now rd.slice rd-telemetry.timer
    sysctl --system
    # Pre-pull the tier-2 reader image so host-telemetry reads never depend
    # on hub reachability at class time.
    docker pull "$READER_IMAGE"
    set +e
}

FAILURES=0

pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1" >&2
    FAILURES=$((FAILURES + 1))
}

do_verify() {
    # (1) rd.slice loaded with a real MemoryMax.
    local load_state mem_max
    load_state="$(systemctl show rd.slice -p LoadState --value 2>/dev/null)"
    mem_max="$(systemctl show rd.slice -p MemoryMax --value 2>/dev/null)"
    if [ "$load_state" = "loaded" ] && [ -n "$mem_max" ] && [ "$mem_max" != "infinity" ]; then
        pass "rd.slice loaded with MemoryMax=$mem_max"
    else
        fail "rd.slice LoadState=$load_state MemoryMax=${mem_max:-<empty>} (expected loaded, finite)"
    fi

    # (2) MemoryMax within 5% of 0.90 x MemTotal.
    local mem_total_kb
    mem_total_kb="$(awk '$1 == "MemTotal:" { print $2 }' /proc/meminfo)"
    if [ -n "$mem_total_kb" ] && [ -n "$mem_max" ] && [ "$mem_max" != "infinity" ]; then
        if awk -v max="$mem_max" -v total_kb="$mem_total_kb" 'BEGIN {
                expected = total_kb * 1024 * 0.90
                delta = max - expected
                if (delta < 0) delta = -delta
                exit !(delta <= expected * 0.05)
            }'; then
            pass "rd.slice MemoryMax within 5% of 0.90 x MemTotal"
        else
            fail "rd.slice MemoryMax=$mem_max not within 5% of 0.90 x MemTotal (${mem_total_kb} kB)"
        fi
    else
        fail "cannot check MemoryMax sizing (MemTotal=${mem_total_kb:-?} MemoryMax=${mem_max:-?})"
    fi

    # (3) system.slice MemoryMin == 2G (compare bytes).
    local mem_min
    mem_min="$(systemctl show system.slice -p MemoryMin --value 2>/dev/null)"
    if [ "$mem_min" = "2147483648" ]; then
        pass "system.slice MemoryMin=2G"
    else
        fail "system.slice MemoryMin=${mem_min:-<empty>} (expected 2147483648)"
    fi

    # (4) kernel.pid_max.
    local pid_max
    pid_max="$(sysctl -n kernel.pid_max 2>/dev/null)"
    if [ "$pid_max" = "131072" ]; then
        pass "kernel.pid_max=131072"
    else
        fail "kernel.pid_max=${pid_max:-<empty>} (expected 131072)"
    fi

    # (5) container placement under rd.slice works.
    if ! docker image inspect alpine >/dev/null 2>&1; then
        docker pull alpine >/dev/null 2>&1
    fi
    if docker run --rm --cgroup-parent rd.slice alpine true >/dev/null 2>&1; then
        pass "docker run --cgroup-parent rd.slice works"
    else
        fail "docker run --rm --cgroup-parent rd.slice alpine true failed"
    fi

    # (6) telemetry snapshot fresh. Run the script once directly instead of
    # waiting for a timer tick.
    if [ -x /usr/local/lib/rd-telemetry.sh ]; then
        /usr/local/lib/rd-telemetry.sh
    fi
    local snap=/var/lib/rd-telemetry/current.json
    if [ -f "$snap" ]; then
        local age
        age=$(($(date +%s) - $(stat -c %Y "$snap")))
        if [ "$age" -lt 90 ]; then
            pass "telemetry snapshot present and fresh (${age}s old)"
        else
            fail "telemetry snapshot stale (${age}s old, expected <90s)"
        fi
    else
        fail "telemetry snapshot $snap missing"
    fi

    if [ "$FAILURES" -gt 0 ]; then
        echo "FAIL: $FAILURES verification check(s) failed" >&2
        exit 1
    fi
    echo "PASS: all verification checks passed"
}

MODE="${1:-install}"
case "$MODE" in
    install)
        do_install
        do_verify
        ;;
    verify)
        do_verify
        ;;
    *)
        echo "usage: $0 [install|verify]" >&2
        exit 2
        ;;
esac
