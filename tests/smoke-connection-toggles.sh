#!/usr/bin/env bash
# verifies the ENABLE_SSH / ENABLE_TTYD contract against the real image:
# with a toggle off, the service process does not exist in the container AND
# the port is not published. run: tests/smoke-connection-toggles.sh [image]
set -u

IMAGE="${1:-ctfd-remote-desktop:latest}"
FAILURES=0

say() { printf '%s\n' "$*"; }
pass() { say "PASS: $*"; }
fail() { say "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  docker rm -f rd-smoke-toggles >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_ready() {
  # deterministic barrier: xfce4-session starts only after both gated service
  # blocks and the in-script readiness loop have completed
  local c=$1 i
  for i in $(seq 1 120); do
    if docker exec "$c" pgrep -f xfce4-session >/dev/null 2>&1; then
      return 0
    fi
    # container died?
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || return 1
    sleep 1
  done
  return 1
}

# exit-code discipline for pgrep: 1 = absent, 0 = present, else = test error
proc_state() {
  docker exec "$1" pgrep -x "$2" >/dev/null 2>&1
  local rc=$?
  case $rc in
    0) echo present ;;
    1) echo absent ;;
    *) echo "error($rc)" ;;
  esac
}

port_published() {
  # per-port form: docker prints separate lines for 0.0.0.0 and [::]
  docker port "$1" "$2/tcp" >/dev/null 2>&1
}

run_case() {
  local label=$1 env_args=$2 port_args=$3 want_sshd=$4 want_ttyd=$5
  cleanup
  # shellcheck disable=SC2086
  docker run -d --name rd-smoke-toggles $env_args $port_args \
    -e CTFD_USERNAME=smokeuser -e VNC_PASSWORD=smokepass "$IMAGE" >/dev/null
  if ! wait_ready rd-smoke-toggles; then
    fail "$label: container never reached xfce4-session"
    docker logs rd-smoke-toggles 2>&1 | tail -5
    return
  fi

  local sshd ttyd
  sshd=$(proc_state rd-smoke-toggles sshd)
  ttyd=$(proc_state rd-smoke-toggles ttyd)
  [ "$sshd" = "$want_sshd" ] && pass "$label: sshd $sshd" || fail "$label: sshd $sshd (want $want_sshd)"
  [ "$ttyd" = "$want_ttyd" ] && pass "$label: ttyd $ttyd" || fail "$label: ttyd $ttyd (want $want_ttyd)"

  for p in 22 7682; do
    local want=absent
    { [ "$p" = 22 ] && [ "$want_sshd" = present ]; } && want=present
    { [ "$p" = 7682 ] && [ "$want_ttyd" = present ]; } && want=present
    if port_published rd-smoke-toggles "$p"; then
      [ "$want" = present ] && pass "$label: port $p published" || fail "$label: port $p published (want unpublished)"
    else
      [ "$want" = absent ] && pass "$label: port $p not published" || fail "$label: port $p not published (want published)"
    fi
  done

  # noVNC must serve regardless of toggles (readiness path intact)
  local novnc_port
  novnc_port=$(docker port rd-smoke-toggles 6080/tcp | head -1 | awk -F: '{print $NF}')
  if curl -fs "http://127.0.0.1:${novnc_port}/" >/dev/null; then
    pass "$label: noVNC serves on published 6080"
  else
    fail "$label: noVNC not reachable on published 6080"
  fi
}

run_case "A both-on (no env)" "" "-p 127.0.0.1::22 -p 127.0.0.1::5900 -p 127.0.0.1::6080 -p 127.0.0.1::7682" present present
run_case "B ssh-off" "-e ENABLE_SSH=0" "-p 127.0.0.1::5900 -p 127.0.0.1::6080 -p 127.0.0.1::7682" absent present
run_case "C ttyd-off" "-e ENABLE_TTYD=0" "-p 127.0.0.1::5900 -p 127.0.0.1::6080 -p 127.0.0.1::22" present absent
run_case "D both-off (plugin port list)" "-e ENABLE_SSH=0 -e ENABLE_TTYD=0" "-p 127.0.0.1::5900 -p 127.0.0.1::6080" absent absent

cleanup
if [ "$FAILURES" -gt 0 ]; then
  say "$FAILURES failure(s)"
  exit 1
fi
say "all toggle assertions passed"
