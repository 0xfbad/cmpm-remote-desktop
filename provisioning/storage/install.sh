#!/usr/bin/env bash
# Installs rd storage provisioning: daemon.json log caps (merged, never
# clobbered), rd-io-tripwire units/env/script, and — RUNNER-ONLY, behind
# --with-storage-opts — daemon-wide overlay2.size plus the data-root mount
# interlock. Idempotent; must run as root.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WITH_STORAGE_OPTS=0
RESTART_DOCKER=0

usage() {
  cat <<'EOF'
Usage: install.sh [--with-storage-opts] [--restart-docker]
  --with-storage-opts   RUNNER-ONLY: add "storage-opts": ["overlay2.size=20G"]
                        to daemon.json and install the RequiresMountsFor
                        interlock drop-in. Never on the ext4 dev box.
  --restart-docker      Opt in to restarting an already-running Docker daemon,
                        only when its config changed and docker ps is empty.
                        Failed restarts restore the prior config and drop-in.
                        The default leaves Docker untouched.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
  --with-storage-opts) WITH_STORAGE_OPTS=1 ;;
  --restart-docker) RESTART_DOCKER=1 ;;
  --)
    shift
    [ "$#" -eq 0 ] || {
      echo "install.sh: unexpected positional arguments" >&2
      exit 2
    }
    break
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done

INSTALL_ROOT=
if [ "${RD_STORAGE_TEST_MODE:-0}" = 1 ]; then
  [ -n "${RD_STORAGE_TEST_ROOT:-}" ] || {
    echo "install.sh: RD_STORAGE_TEST_ROOT is required in test mode" >&2
    exit 1
  }
  [ -d "$RD_STORAGE_TEST_ROOT" ] && [ ! -L "$RD_STORAGE_TEST_ROOT" ] || {
    echo "install.sh: test root must be a pre-existing real directory" >&2
    exit 1
  }
  INSTALL_ROOT=$(realpath -e -- "$RD_STORAGE_TEST_ROOT")
  [ "$INSTALL_ROOT" != / ] || {
    echo "install.sh: refusing / as a test root" >&2
    exit 1
  }
elif [ -n "${RD_STORAGE_TEST_ROOT:-}" ]; then
  echo "install.sh: RD_STORAGE_TEST_ROOT is only accepted with RD_STORAGE_TEST_MODE=1" >&2
  exit 1
fi

if [ -z "$INSTALL_ROOT" ] && [ "$(id -u)" -ne 0 ]; then
  echo "install.sh: must run as root" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || {
  echo "install.sh: jq is required" >&2
  exit 1
}
command -v dockerd >/dev/null 2>&1 || {
  echo "install.sh: dockerd is required to validate daemon.json" >&2
  exit 1
}
command -v install >/dev/null 2>&1 || {
  echo "install.sh: install is required" >&2
  exit 1
}
command -v systemctl >/dev/null 2>&1 || {
  echo "install.sh: systemctl is required" >&2
  exit 1
}
if [ "$RESTART_DOCKER" -eq 1 ]; then
  command -v docker >/dev/null 2>&1 || {
    echo "install.sh: docker is required with --restart-docker" >&2
    exit 1
  }
fi

for source_file in \
  "$HERE/bin/rd-io-tripwire.sh" \
  "$HERE/default/rd-io-tripwire" \
  "$HERE/systemd/rd-io-tripwire.service" \
  "$HERE/systemd/rd-io-tripwire.timer"; do
  [ -r "$source_file" ] || {
    echo "install.sh: required source file is missing or unreadable: $source_file" >&2
    exit 1
  }
done

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

DATA_ROOT=
preflight_storage_opts() {
  local mount_target fs_type fs_root mount_opts xfs_metadata mount_source data_device root_device

  command -v docker >/dev/null 2>&1 || fail "docker is required to discover the active data-root"
  command -v findmnt >/dev/null 2>&1 || fail "findmnt is required for storage preflight"
  command -v xfs_info >/dev/null 2>&1 || fail "xfs_info is required for storage preflight"

  # Ask the running daemon instead of guessing from daemon.json: command-line
  # flags and service overrides may select a different data-root.
  DATA_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null) ||
    fail "cannot query the running Docker daemon for its active data-root"
  [ -n "$DATA_ROOT" ] || fail "Docker reported an empty data-root"
  [ -d "$DATA_ROOT" ] || fail "active Docker data-root is not a directory: $DATA_ROOT"
  DATA_ROOT=$(realpath -e -- "$DATA_ROOT") || fail "cannot resolve active Docker data-root"
  case "$DATA_ROOT" in
  *[[:space:]]*) fail "Docker data-root may not contain whitespace: $DATA_ROOT" ;;
  esac

  # -M requires DATA_ROOT itself to be a mountpoint. A filesystem merely
  # containing /var/lib/docker is not dedicated and could hide Docker data if
  # the intended mount disappears.
  mount_target=$(findmnt -rn -M "$DATA_ROOT" -o TARGET 2>/dev/null) ||
    fail "active Docker data-root is not a dedicated mountpoint: $DATA_ROOT"
  mount_target=$(realpath -e -- "$mount_target") || fail "cannot resolve data-root mountpoint"
  [ "$mount_target" = "$DATA_ROOT" ] ||
    fail "active Docker data-root is not its own mountpoint: $DATA_ROOT"
  fs_root=$(findmnt -rn -M "$DATA_ROOT" -o FSROOT 2>/dev/null) ||
    fail "cannot determine filesystem root for $DATA_ROOT"
  [ "$fs_root" = / ] ||
    fail "active Docker data-root must be a whole filesystem mount, not a bind mount"

  mount_source=$(findmnt -rn -M "$DATA_ROOT" -o SOURCE 2>/dev/null) ||
    fail "cannot determine mount source for $DATA_ROOT"
  mount_source=${mount_source%%\[*}
  mount_source=$(readlink -f -- "$mount_source" 2>/dev/null) ||
    fail "cannot resolve mount source for $DATA_ROOT"
  [ -b "$mount_source" ] || fail "active Docker data-root is not block-backed: $DATA_ROOT"
  data_device=$(findmnt -rn -M "$DATA_ROOT" -o MAJ:MIN 2>/dev/null) ||
    fail "cannot determine data-root device"
  root_device=$(findmnt -rn -M / -o MAJ:MIN 2>/dev/null) || fail "cannot determine root device"
  [ "$data_device" != "$root_device" ] ||
    fail "active Docker data-root must use a block device separate from /"

  fs_type=$(findmnt -rn -M "$DATA_ROOT" -o FSTYPE 2>/dev/null) ||
    fail "cannot determine filesystem type for $DATA_ROOT"
  [ "$fs_type" = xfs ] || fail "active Docker data-root must be XFS (found $fs_type)"

  mount_opts=$(findmnt -rn -M "$DATA_ROOT" -o OPTIONS 2>/dev/null) ||
    fail "cannot determine mount options for $DATA_ROOT"
  case ",$mount_opts," in
  *,prjquota,* | *,pquota,*) ;;
  *) fail "active Docker data-root must be mounted with prjquota: $DATA_ROOT" ;;
  esac

  xfs_metadata=$(xfs_info "$DATA_ROOT" 2>/dev/null) || fail "xfs_info failed for $DATA_ROOT"
  printf '%s\n' "$xfs_metadata" | grep -Eq '(^|[[:space:],])ftype=1([[:space:],]|$)' ||
    fail "active Docker data-root XFS filesystem must have ftype=1: $DATA_ROOT"
}

if [ "$WITH_STORAGE_OPTS" -eq 1 ] && [ -n "$INSTALL_ROOT" ]; then
  DATA_ROOT=${RD_STORAGE_TEST_DATA_ROOT:?RD_STORAGE_TEST_DATA_ROOT is required with --with-storage-opts in test mode}
elif [ "$WITH_STORAGE_OPTS" -eq 1 ]; then
  # This must precede every daemon.json backup/write and every systemd drop-in
  # change. A failed runner preflight is therefore completely non-mutating.
  preflight_storage_opts
fi

# --- Docker config transaction -------------------------------------------
DAEMON_JSON=$INSTALL_ROOT/etc/docker/daemon.json
DAEMON_DIR=${DAEMON_JSON%/*}
DROPIN_DIR=$INSTALL_ROOT/etc/systemd/system/docker.service.d
DROPIN=$DROPIN_DIR/10-rd-storage-interlock.conf
mkdir -p "$DAEMON_DIR"
umask 077
candidate=$(mktemp "$DAEMON_DIR/.daemon.json.XXXXXX")
next_candidate=
dropin_candidate=
daemon_previous=
dropin_previous=
restore_candidate=
cleanup() {
  [ -z "${candidate:-}" ] || rm -f -- "$candidate"
  [ -z "${next_candidate:-}" ] || rm -f -- "$next_candidate"
  [ -z "${dropin_candidate:-}" ] || rm -f -- "$dropin_candidate"
  [ -z "${daemon_previous:-}" ] || rm -f -- "$daemon_previous"
  [ -z "${dropin_previous:-}" ] || rm -f -- "$dropin_previous"
  [ -z "${restore_candidate:-}" ] || rm -f -- "$restore_candidate"
}
trap cleanup EXIT

if [ -e "$DAEMON_JSON" ] || [ -L "$DAEMON_JSON" ]; then
  [ -f "$DAEMON_JSON" ] && [ ! -L "$DAEMON_JSON" ] ||
    fail "$DAEMON_JSON must be a regular file, not a symlink"
fi

# Log caps always. Unrelated keys (e.g. default-address-pools, owned by the
# network provisioning) pass through untouched.
if [ -f "$DAEMON_JSON" ]; then
  jq -e 'type == "object"' "$DAEMON_JSON" >/dev/null ||
    fail "$DAEMON_JSON must contain one valid JSON object"
  jq '."log-driver" = "json-file"
    | ."log-opts" = ((."log-opts" // {}) + {"max-size": "50m", "max-file": "3"})' \
    "$DAEMON_JSON" >"$candidate"
else
  jq -n '{"log-driver": "json-file", "log-opts": {"max-size": "50m", "max-file": "3"}}' \
    >"$candidate"
fi

if [ "$WITH_STORAGE_OPTS" -eq 1 ]; then
  next_candidate=$(mktemp "$DAEMON_DIR/.daemon.json.XXXXXX")
  jq '."storage-opts" =
        (((."storage-opts" // []) - ["overlay2.size=20G"]) + ["overlay2.size=20G"])' \
    "$candidate" >"$next_candidate"
  mv -f -- "$next_candidate" "$candidate"
  next_candidate=
fi

# Validate the completed candidate twice: jq gives a clear structural check;
# dockerd catches valid JSON containing unknown, conflicting, or ill-typed
# daemon settings. Nothing under /etc has been replaced at this point.
jq -e 'type == "object"' "$candidate" >/dev/null || fail "generated daemon.json is invalid"
dockerd --validate --config-file "$candidate" >/dev/null ||
  fail "dockerd rejected generated daemon.json; existing configuration was not changed"

daemon_changed=1
if [ -f "$DAEMON_JSON" ] && jq -e --slurp '.[0] == .[1]' "$DAEMON_JSON" "$candidate" >/dev/null; then
  daemon_changed=0
fi

# Build and compare the runner-only drop-in before mutating either Docker
# configuration file. Whitespace changes count here because it is a tiny,
# fully owned file; daemon.json comparison above is semantic JSON equality.
dropin_changed=0
if [ "$WITH_STORAGE_OPTS" -eq 1 ]; then
  install -d "$DROPIN_DIR"
  if [ -e "$DROPIN" ] || [ -L "$DROPIN" ]; then
    [ -f "$DROPIN" ] && [ ! -L "$DROPIN" ] ||
      fail "$DROPIN must be a regular file, not a symlink"
  fi
  dropin_candidate=$(mktemp "$DROPIN_DIR/.10-rd-storage-interlock.XXXXXX")
  {
    printf '%s\n' '# Installed by rd storage provisioning after XFS preflight.' '[Unit]'
    printf 'RequiresMountsFor=%s\n' "$DATA_ROOT"
  } >"$dropin_candidate"
  chmod 0644 "$dropin_candidate"
  if [ ! -f "$DROPIN" ] || ! cmp -s -- "$DROPIN" "$dropin_candidate"; then
    dropin_changed=1
  fi
fi

docker_config_changed=0
if [ "$daemon_changed" -eq 1 ] || [ "$dropin_changed" -eq 1 ]; then
  docker_config_changed=1
fi

docker_is_drained() {
  local active_containers
  active_containers=$(docker ps --quiet --no-trunc) || {
    echo "install.sh: cannot query running containers for the Docker restart gate" >&2
    return 1
  }
  if [ -n "$active_containers" ]; then
    echo "install.sh: refusing to restart Docker while any container is running; drain the host first" >&2
    return 1
  fi
}

docker_was_active=0
if [ "$RESTART_DOCKER" -eq 1 ] && [ "$docker_config_changed" -eq 1 ] &&
  systemctl is-active --quiet docker.service; then
  docker_was_active=1
  docker_is_drained || fail "Docker restart preflight failed before configuration was changed"
fi

# Capture exact prior state for restart rollback, then install only files whose
# effective contents changed.
daemon_existed=0
if [ "$daemon_changed" -eq 1 ]; then
  if [ -f "$DAEMON_JSON" ]; then
    daemon_existed=1
    daemon_previous=$(mktemp "$DAEMON_DIR/.daemon.json.previous.XXXXXX")
    cp --preserve=all -- "$DAEMON_JSON" "$daemon_previous"
    cp -a -- "$DAEMON_JSON" "$DAEMON_JSON.bak.$(date +%s%N)"
  fi
  chmod 0644 "$candidate"
  chown root:root "$candidate"
  mv -f -- "$candidate" "$DAEMON_JSON"
  candidate=
else
  rm -f -- "$candidate"
  candidate=
fi

dropin_existed=0
if [ "$WITH_STORAGE_OPTS" -eq 1 ]; then
  if [ "$dropin_changed" -eq 1 ]; then
    if [ -f "$DROPIN" ]; then
      dropin_existed=1
      dropin_previous=$(mktemp "$DROPIN_DIR/.10-rd-storage-interlock.previous.XXXXXX")
      cp --preserve=all -- "$DROPIN" "$dropin_previous"
    fi
    mv -f -- "$dropin_candidate" "$DROPIN"
    dropin_candidate=
  else
    rm -f -- "$dropin_candidate"
    dropin_candidate=
  fi
fi

atomic_restore() {
  local previous=$1 target=$2 target_dir
  target_dir=${target%/*}
  restore_candidate=$(mktemp "$target_dir/.${target##*/}.rollback.XXXXXX") || return 1
  cp --preserve=all -- "$previous" "$restore_candidate" || return 1
  mv -f -- "$restore_candidate" "$target" || return 1
  restore_candidate=
}

restore_docker_configuration() {
  if [ "$daemon_changed" -eq 1 ]; then
    if [ "$daemon_existed" -eq 1 ]; then
      atomic_restore "$daemon_previous" "$DAEMON_JSON" || return 1
    else
      rm -f -- "$DAEMON_JSON" || return 1
    fi
  fi
  if [ "$dropin_changed" -eq 1 ]; then
    if [ "$dropin_existed" -eq 1 ]; then
      atomic_restore "$dropin_previous" "$DROPIN" || return 1
    else
      rm -f -- "$DROPIN" || return 1
    fi
  fi
  systemctl daemon-reload
}

# --- tripwire script + units + env ----------------------------------------
install -d "$INSTALL_ROOT/usr/local/lib" "$INSTALL_ROOT/etc/systemd/system"
install -m 0755 "$HERE/bin/rd-io-tripwire.sh" "$INSTALL_ROOT/usr/local/lib/rd-io-tripwire.sh"
install -m 0644 "$HERE/systemd/rd-io-tripwire.service" "$INSTALL_ROOT/etc/systemd/system/rd-io-tripwire.service"
install -m 0644 "$HERE/systemd/rd-io-tripwire.timer" "$INSTALL_ROOT/etc/systemd/system/rd-io-tripwire.timer"
# Preserve local tuning on re-runs.
if [ ! -f "$INSTALL_ROOT/etc/default/rd-io-tripwire" ]; then
  install -D -m 0644 "$HERE/default/rd-io-tripwire" "$INSTALL_ROOT/etc/default/rd-io-tripwire"
fi
mkdir -p "$INSTALL_ROOT/var/log/rd-tripwire"

systemctl daemon-reload
tripwire_timer_state=$(systemctl is-enabled rd-io-tripwire.timer 2>/dev/null || true)
case "$tripwire_timer_state" in
masked | masked-runtime)
  echo "install.sh: rd-io-tripwire.timer remains masked for storage maintenance; unmask and enable it only after Docker is verified"
  ;;
*) systemctl enable --now rd-io-tripwire.timer ;;
esac

if [ "$docker_config_changed" -eq 0 ]; then
  echo "install.sh: Docker configuration is unchanged; no restart needed"
elif [ "$RESTART_DOCKER" -eq 0 ]; then
  echo "install.sh: Docker configuration changed; Docker was not restarted (use --restart-docker on a drained host)"
elif [ "$docker_was_active" -eq 0 ]; then
  echo "install.sh: Docker configuration changed, but Docker is inactive; leaving it stopped"
else
  # Close the small mutation window: a new workload may have appeared after
  # the preflight. In that case restore the old files instead of disrupting it.
  if ! docker_is_drained; then
    restore_docker_configuration ||
      fail "Docker became busy and automatic configuration rollback failed"
    fail "Docker became busy after preflight; prior configuration was restored"
  fi

  if ! systemctl restart docker.service; then
    echo "install.sh: Docker restart failed; restoring prior daemon configuration" >&2
    restore_docker_configuration ||
      fail "Docker restart failed and automatic configuration rollback also failed"
    if systemctl restart docker.service; then
      fail "Docker rejected the new configuration; prior files were restored and Docker recovered"
    fi
    fail "Docker restart failed; prior files were restored but Docker recovery also failed"
  fi
fi

echo "install.sh: done (storage-opts: $([ "$WITH_STORAGE_OPTS" -eq 1 ] && echo on || echo off))"
