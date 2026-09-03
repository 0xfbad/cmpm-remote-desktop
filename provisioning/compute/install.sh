#!/usr/bin/env bash
# install.sh - provision a compute host for ctfd-remote-desktop sessions.
#
#   install.sh [install]   install units + telemetry, then run verify
#   install.sh verify      verification only; exits non-zero on any failure
#
# Any operator who configures the plugin with cgroup_parent=rd.slice must run
# this script first (install mode ends with verify). See README.md: an
# unprovisioned host silently gets an unlimited implicitly-created rd.slice.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER_IMAGE="${READER_IMAGE:-busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0}"

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
  # Pre-pull the pinned throwaway image used by the cgroup-placement probe.
  # Telemetry itself is host-side and does not launch this image.
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
  local load_state cpu_weight io_weight mem_high mem_max swap_max tasks_max
  load_state="$(systemctl show rd.slice -p LoadState --value 2>/dev/null)"
  cpu_weight="$(systemctl show rd.slice -p CPUWeight --value 2>/dev/null)"
  io_weight="$(systemctl show rd.slice -p IOWeight --value 2>/dev/null)"
  mem_high="$(systemctl show rd.slice -p MemoryHigh --value 2>/dev/null)"
  mem_max="$(systemctl show rd.slice -p MemoryMax --value 2>/dev/null)"
  swap_max="$(systemctl show rd.slice -p MemorySwapMax --value 2>/dev/null)"
  tasks_max="$(systemctl show rd.slice -p TasksMax --value 2>/dev/null)"
  if [ "$load_state" = "loaded" ] && [ -n "$mem_max" ] && [ "$mem_max" != "infinity" ]; then
    pass "rd.slice loaded with MemoryMax=$mem_max"
  else
    fail "rd.slice LoadState=$load_state MemoryMax=${mem_max:-<empty>} (expected loaded, finite)"
  fi

  if [ "$cpu_weight" = 50 ] && [ "$io_weight" = 50 ] && [ "$tasks_max" = 32768 ]; then
    pass "rd.slice CPUWeight=50 IOWeight=50 TasksMax=32768"
  else
    fail "rd.slice tuple CPUWeight=${cpu_weight:-?} IOWeight=${io_weight:-?} TasksMax=${tasks_max:-?}"
  fi

  if [ -n "$swap_max" ] && [ "$swap_max" != "0" ] && [ "$swap_max" != "infinity" ]; then
    pass "rd.slice has bounded swap cushion MemorySwapMax=$swap_max"
  else
    fail "rd.slice MemorySwapMax=${swap_max:-<empty>} (expected finite and non-zero)"
  fi

  # (2) MemoryHigh/Max/SwapMax match the complete declarative tuple.
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

  if [ -n "$mem_total_kb" ] && [ -n "$mem_high" ] && [ "$mem_high" != "infinity" ]; then
    if awk -v max="$mem_high" -v total_kb="$mem_total_kb" 'BEGIN {
                expected = total_kb * 1024 * 0.70
                delta = max - expected
                if (delta < 0) delta = -delta
                exit !(delta <= expected * 0.05)
            }'; then
      pass "rd.slice MemoryHigh within 5% of 0.70 x MemTotal"
    else
      fail "rd.slice MemoryHigh=$mem_high not within 5% of 0.70 x MemTotal"
    fi
  else
    fail "cannot check MemoryHigh sizing"
  fi

  if [ -n "$mem_total_kb" ] && [ -n "$swap_max" ] && [ "$swap_max" != "infinity" ]; then
    if awk -v max="$swap_max" -v total_kb="$mem_total_kb" 'BEGIN {
                expected = total_kb * 1024 * 0.25
                delta = max - expected
                if (delta < 0) delta = -delta
                exit !(delta <= expected * 0.05)
            }'; then
      pass "rd.slice MemorySwapMax within 5% of 0.25 x MemTotal"
    else
      fail "rd.slice MemorySwapMax=$swap_max not within 5% of 0.25 x MemTotal"
    fi
  else
    fail "cannot check MemorySwapMax sizing"
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
  if ! docker image inspect "$READER_IMAGE" >/dev/null 2>&1; then
    docker pull "$READER_IMAGE" >/dev/null 2>&1
  fi
  if docker run --rm --cgroup-parent rd.slice "$READER_IMAGE" true >/dev/null 2>&1; then
    pass "docker run --cgroup-parent rd.slice works with pinned READER_IMAGE"
  else
    fail "docker run --rm --cgroup-parent rd.slice READER_IMAGE true failed"
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
    if python3 - "$snap" <<'PY'; then
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema_version"] == 1
assert isinstance(data["ready"], bool)
assert data["readiness"]["slice_configured"] is True
assert data["readiness"]["compute_limits_match"] is True
assert data["configuration"]["cgroup_parent"] == "rd.slice"
PY
      pass "telemetry v1 compute attestation is valid"
    else
      fail "telemetry v1 compute attestation is invalid"
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
