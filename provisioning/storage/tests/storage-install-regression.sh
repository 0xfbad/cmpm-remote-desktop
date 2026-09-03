#!/usr/bin/env bash
# Behavioral regression coverage for the non-destructive install transaction.
# All filesystem writes are redirected under a fresh test root and Docker/
# systemd commands are fakes; no host daemon or unit is touched.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL=$HERE/install.sh
TEST_DIR=$(mktemp -d)
FAKE_BIN=$TEST_DIR/bin
TEST_ROOT=$TEST_DIR/root
CALL_LOG=$TEST_DIR/calls.log
mkdir -p "$FAKE_BIN" "$TEST_ROOT"
: >"$CALL_LOG"

cleanup() {
  local status=$?
  trap - EXIT
  local expected_prefix=${TMPDIR:-/tmp}/tmp.
  case "$TEST_DIR" in
  "$expected_prefix"*) rm -rf -- "$TEST_DIR" ;;
  *) echo "storage-install-regression: refusing unexpected cleanup path: $TEST_DIR" >&2 ;;
  esac
  exit "$status"
}
trap cleanup EXIT

fail() {
  echo "storage-install-regression: $*" >&2
  exit 1
}

cat >"$FAKE_BIN/dockerd" <<'EOF'
#!/usr/bin/env bash
printf 'dockerd %s\n' "$*" >>"$RD_TEST_CALL_LOG"
[[ $1 == --validate && $2 == --config-file && -f $3 ]]
EOF

cat >"$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$RD_TEST_CALL_LOG"
case "${1:-}" in
ps)
  [[ ! -s ${RD_TEST_RUNNING_CONTAINERS:-/dev/null} ]] || cat "$RD_TEST_RUNNING_CONTAINERS"
  ;;
*) exit 2 ;;
esac
EOF

cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$RD_TEST_CALL_LOG"
case "${1:-}" in
is-active)
  [[ ${*: -1} == docker.service && ${RD_TEST_DOCKER_ACTIVE:-0} == 1 ]]
  ;;
is-enabled)
  printf '%s\n' disabled
  exit 1
  ;;
restart)
  [[ ${2:-} == docker.service ]] || exit 2
  if [[ -e ${RD_TEST_FAIL_RESTART_ONCE:-} ]]; then
    mv -- "$RD_TEST_FAIL_RESTART_ONCE" "$RD_TEST_FAIL_RESTART_ONCE.used"
    exit 1
  fi
  ;;
daemon-reload | enable) ;;
*) exit 2 ;;
esac
EOF

cat >"$FAKE_BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
for helper in dockerd docker systemctl chown; do
  # Nix build sandboxes intentionally have no /usr/bin/env; point generated
  # fakes at the exact Bash that is running this regression.
  sed -i "1c #!$BASH" "$FAKE_BIN/$helper"
  chmod 0755 "$FAKE_BIN/$helper"
done

export PATH=$FAKE_BIN:$PATH
export RD_TEST_CALL_LOG=$CALL_LOG
export RD_TEST_DOCKER_ACTIVE=1
export RD_STORAGE_TEST_MODE=1
export RD_STORAGE_TEST_ROOT=$TEST_ROOT

run_install() {
  bash "$INSTALL" "$@"
}

# Default behavior applies a real configuration change but never restarts.
run_install >/dev/null
grep -Fqx 'systemctl restart docker.service' "$CALL_LOG" &&
  fail "default install restarted Docker"
[[ -s $TEST_ROOT/etc/docker/daemon.json ]] || fail "daemon.json was not installed"

# A restart request is change-sensitive: semantically identical JSON must not
# cause either a drain query or a daemon restart.
: >"$CALL_LOG"
run_install --restart-docker >/dev/null
grep -Fq 'docker ps ' "$CALL_LOG" && fail "unchanged config ran the drain probe"
grep -Fqx 'systemctl restart docker.service' "$CALL_LOG" &&
  fail "unchanged config restarted Docker"

# Exercise rollback for both owned Docker files. The first restart fails; the
# recovery restart succeeds, but install still reports failure after restoring
# byte-for-byte prior daemon.json and drop-in contents.
daemon_json=$TEST_ROOT/etc/docker/daemon.json
dropin=$TEST_ROOT/etc/systemd/system/docker.service.d/10-rd-storage-interlock.conf
jq '."log-opts"."max-size" = "25m"' "$daemon_json" >"$TEST_DIR/daemon-old.json"
mv -f -- "$TEST_DIR/daemon-old.json" "$daemon_json"
mkdir -p "${dropin%/*}"
printf '%s\n' '# pre-existing operator drop-in' '[Unit]' 'RequiresMountsFor=/old/docker-root' >"$dropin"
cp -- "$daemon_json" "$TEST_DIR/daemon.expected"
cp -- "$dropin" "$TEST_DIR/dropin.expected"
: >"$CALL_LOG"
fail_once=$TEST_DIR/fail-restart-once
: >"$fail_once"
export RD_TEST_FAIL_RESTART_ONCE=$fail_once
export RD_STORAGE_TEST_DATA_ROOT=/srv/rd-docker
if run_install --with-storage-opts --restart-docker >/dev/null 2>&1; then
  fail "install succeeded after a simulated failed configuration restart"
fi
cmp -s -- "$TEST_DIR/daemon.expected" "$daemon_json" ||
  fail "failed restart did not restore daemon.json"
cmp -s -- "$TEST_DIR/dropin.expected" "$dropin" ||
  fail "failed restart did not restore the interlock drop-in"
[[ $(grep -Fxc 'systemctl restart docker.service' "$CALL_LOG") -eq 2 ]] ||
  fail "failed restart did not make exactly one recovery attempt"
unset RD_TEST_FAIL_RESTART_ONCE

# A non-empty host is rejected before either Docker config file changes.
jq '."log-opts"."max-size" = "10m"' "$daemon_json" >"$TEST_DIR/daemon-busy.json"
mv -f -- "$TEST_DIR/daemon-busy.json" "$daemon_json"
cp -- "$daemon_json" "$TEST_DIR/daemon.busy.expected"
running=$TEST_DIR/running-containers
printf '%s\n' deadbeef >"$running"
export RD_TEST_RUNNING_CONTAINERS=$running
: >"$CALL_LOG"
if run_install --restart-docker >/dev/null 2>&1; then
  fail "install restarted Docker with a running container"
fi
cmp -s -- "$TEST_DIR/daemon.busy.expected" "$daemon_json" ||
  fail "drain-gate failure changed daemon.json"
grep -Fqx 'systemctl restart docker.service' "$CALL_LOG" &&
  fail "drain-gate failure reached systemctl restart"

echo "storage-install-regression: PASS"
