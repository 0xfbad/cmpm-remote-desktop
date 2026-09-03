#!/usr/bin/env bash
# Non-destructive regression checks for the storage provisioning guardrails.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL=$HERE/install.sh
MAKE_ROOT=$HERE/xfs/make-data-root.sh
INSTALL_REGRESSION=$HERE/tests/storage-install-regression.sh
TRIPWIRE_SERVICE=$HERE/systemd/rd-io-tripwire.service
TELEMETRY_SERVICE=$HERE/../compute/telemetry/rd-telemetry.service

fail() {
  echo "storage-safety-static: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1 pattern=$2
  grep -Eq -- "$pattern" "$file" || fail "$file is missing safety check: $pattern"
}

line_of() {
  local file=$1 pattern=$2
  grep -nEm1 -- "$pattern" "$file" | cut -d: -f1
}

bash -n "$INSTALL" "$MAKE_ROOT" "$INSTALL_REGRESSION" "$HERE/bin/rd-io-tripwire.sh"
jq -e 'type == "object"' "$HERE/daemon.json" >/dev/null
if "$INSTALL" unexpected-argument >/dev/null 2>&1; then
  fail "install.sh accepted an unexpected positional argument"
fi
if "$MAKE_ROOT" --unknown-option >/dev/null 2>&1; then
  fail "make-data-root.sh accepted an unknown option"
fi

assert_contains "$INSTALL" 'docker info --format'
assert_contains "$INSTALL" 'findmnt .* -M .*DATA_ROOT'
assert_contains "$INSTALL" 'FSROOT'
assert_contains "$INSTALL" 'block device separate from /'
assert_contains "$INSTALL" 'ftype=1'
assert_contains "$INSTALL" 'prjquota.*pquota|pquota.*prjquota'
assert_contains "$INSTALL" 'mktemp .*daemon\.json'
assert_contains "$INSTALL" 'dockerd --validate --config-file'
assert_contains "$INSTALL" '^RESTART_DOCKER=0$'
assert_contains "$INSTALL" '--restart-docker'
assert_contains "$INSTALL" 'docker ps --quiet --no-trunc'
assert_contains "$INSTALL" 'docker_config_changed'
assert_contains "$INSTALL" 'restore_docker_configuration'
assert_contains "$INSTALL" 'atomic_restore .*daemon_previous.*DAEMON_JSON'
assert_contains "$INSTALL" 'atomic_restore .*dropin_previous.*DROPIN'
assert_contains "$INSTALL" 'systemctl restart docker\.service'

preflight_line=$(line_of "$INSTALL" '^[[:space:]]+preflight_storage_opts$')
daemon_dir_line=$(line_of "$INSTALL" '^DAEMON_DIR=')
validate_line=$(line_of "$INSTALL" '^dockerd --validate --config-file')
# shellcheck disable=SC2016 # literal regex intentionally matches shell source
install_line=$(line_of "$INSTALL" '^[[:space:]]+mv -f -- "\$candidate" "\$DAEMON_JSON"')
[ "$preflight_line" -lt "$daemon_dir_line" ] || fail "storage preflight no longer precedes config work"
[ "$validate_line" -lt "$install_line" ] || fail "daemon.json is installed before dockerd validation"

for service in "$TRIPWIRE_SERVICE" "$TELEMETRY_SERVICE"; do
  assert_contains "$service" '^After=docker\.service$'
  assert_contains "$service" '^ExecCondition=/usr/bin/systemctl --quiet is-active docker\.service$'
  if grep -Eq '^(Requires|Wants)=docker\.service$' "$service"; then
    fail "$service can pull Docker up from a monitoring timer"
  fi
done

assert_contains "$MAKE_ROOT" 'systemctl is-active --quiet docker'
assert_contains "$MAKE_ROOT" 'pgrep -x dockerd'
assert_contains "$MAKE_ROOT" 'lsblk .*MOUNTPOINTS'
assert_contains "$MAKE_ROOT" 'swapon --show=NAME'
assert_contains "$MAKE_ROOT" 'fuser -s .*block_path'
assert_contains "$MAKE_ROOT" '/holders/\*'
assert_contains "$MAKE_ROOT" 'findmnt .* -S .*block_path'
assert_contains "$MAKE_ROOT" 'lsblk -dnro PTTYPE'
assert_contains "$MAKE_ROOT" 'partition table or child block devices'
assert_contains "$MAKE_ROOT" 'findmnt .* -M .*mountpoint'
assert_contains "$MAKE_ROOT" 'fstab already (has|references)'
assert_contains "$MAKE_ROOT" 'mountpoint is not empty'
assert_contains "$MAKE_ROOT" '/etc/fstab may not be a symlink'
assert_contains "$MAKE_ROOT" '/etc/fstab is not a regular file'
assert_contains "$MAKE_ROOT" '--force is only valid for formatting an exact block DEVICE'
assert_contains "$MAKE_ROOT" 'systemctl mask --runtime --now.*DOCKER_MONITOR_TIMERS'
assert_contains "$MAKE_ROOT" 'rd-io-tripwire\.timer rd-telemetry\.timer'
assert_contains "$MAKE_ROOT" 'systemctl stop .*service'

# Every format and mount command must be immediately preceded by a fresh
# Docker-down check, after the long-running block-device checks have completed.
while IFS=: read -r operation_line _; do
  previous_line=$(sed -n "$((operation_line - 1))p" "$MAKE_ROOT")
  [[ $previous_line =~ ^[[:space:]]*docker_must_be_stopped[[:space:]]*$ ]] ||
    fail "destructive operation at $MAKE_ROOT:$operation_line lacks an immediate Docker recheck"
done < <(grep -nE '^[[:space:]]+(mkfs\.xfs|mount -o prjquota)' "$MAKE_ROOT")

force_line=$(line_of "$MAKE_ROOT" 'mkfs_args\+=\(-f\)')
# shellcheck disable=SC2016 # literal regex intentionally matches shell source
mkfs_line=$(line_of "$MAKE_ROOT" '^mkfs\.xfs "\$\{mkfs_args\[@\]\}" "\$device"')
[ "$force_line" -lt "$mkfs_line" ] || fail "--force is not scoped to the exact-device mkfs call"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$INSTALL" "$MAKE_ROOT" "$INSTALL_REGRESSION" "$HERE/bin/rd-io-tripwire.sh"
fi

echo "storage-safety-static: PASS"
