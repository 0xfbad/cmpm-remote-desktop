#!/usr/bin/env bash
# Builds an XFS docker data-root with project quotas (required for
# overlay2 storage-opt size). Two modes:
#   make-data-root.sh [--force] DEVICE [MOUNTPOINT]
#       Real device: mkfs.xfs -m crc=1 -n ftype=1, fstab entry with prjquota,
#       mount. --force only permits mkfs.xfs -f on that exact block device;
#       it never bypasses in-use device or mountpoint safety checks.
#   make-data-root.sh --loopback FILE SIZE [MOUNTPOINT]
#       Test mode: PREALLOCATED (fallocate, not sparse) image + losetup +
#       mkfs.xfs + mount -o prjquota. No fstab entry (not boot-persistent).
# Default MOUNTPOINT: /var/lib/docker. Root required.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  make-data-root.sh [--force] DEVICE [MOUNTPOINT]
  make-data-root.sh --loopback FILE SIZE [MOUNTPOINT]

  --force      real-device mode only: permit formatting the exact DEVICE when
               it already carries a filesystem; never bypass safety checks
  --loopback   build on a preallocated loop image (testing only)
  MOUNTPOINT   defaults to /var/lib/docker
EOF
}

FORCE=0
LOOPBACK=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
  --force) FORCE=1 ;;
  --loopback) LOOPBACK=1 ;;
  --)
    shift
    args+=("$@")
    break
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "make-data-root.sh: unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  *) args+=("$1") ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "make-data-root.sh: must run as root" >&2
  exit 1
fi

fail() {
  echo "make-data-root.sh: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

DOCKER_MONITOR_TIMERS=(rd-io-tripwire.timer rd-telemetry.timer)
DOCKER_MONITOR_SERVICES=(rd-io-tripwire.service rd-telemetry.service)

quiesce_docker_monitoring() {
  local load_state mask_state service timer

  # These timers historically pulled docker.service in through their monitor
  # services. Runtime-mask both names even on a fresh host, then stop any
  # in-flight monitor, so an old installed unit cannot race the checks below.
  systemctl mask --runtime --now "${DOCKER_MONITOR_TIMERS[@]}" >/dev/null ||
    fail "cannot runtime-mask Docker monitoring timers"
  for timer in "${DOCKER_MONITOR_TIMERS[@]}"; do
    mask_state=$(systemctl is-enabled "$timer" 2>/dev/null || true)
    case "$mask_state" in
    masked | masked-runtime) ;;
    *) fail "Docker monitoring timer is not runtime-masked: $timer" ;;
    esac
  done

  for service in "${DOCKER_MONITOR_SERVICES[@]}"; do
    load_state=$(systemctl show --property=LoadState --value "$service" 2>/dev/null || true)
    if [ "$load_state" != not-found ]; then
      systemctl stop "$service" || fail "cannot stop Docker monitoring service: $service"
    fi
    ! systemctl is-active --quiet "$service" 2>/dev/null ||
      fail "Docker monitoring service is still active: $service"
  done

  echo "make-data-root.sh: Docker monitoring timers are runtime-masked; keep them masked until Docker is configured and verified" >&2
}

docker_must_be_stopped() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet docker 2>/dev/null ||
      systemctl is-active --quiet docker.socket 2>/dev/null; then
      fail "Docker or docker.socket is active; stop both before preparing a data-root"
    fi
  fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -x dockerd >/dev/null 2>&1; then
    fail "a dockerd process is running; stop it before preparing a data-root"
  fi
}

preflight_mountpoint() {
  local requested_mountpoint target_source

  requested_mountpoint=$mountpoint
  [ ! -L "$requested_mountpoint" ] || fail "mountpoint may not be a symlink: $requested_mountpoint"
  mountpoint=$(realpath -m -- "$mountpoint") || fail "cannot resolve mountpoint: $mountpoint"
  [ "$mountpoint" != / ] || fail "refusing to use / as a data-root mountpoint"
  case "$mountpoint" in
  *[[:space:]]*) fail "mountpoint may not contain whitespace: $mountpoint" ;;
  esac
  if [ -e "$mountpoint" ] && [ ! -d "$mountpoint" ]; then
    fail "mountpoint exists and is not a directory: $mountpoint"
  fi
  if findmnt -rn -M "$mountpoint" >/dev/null 2>&1; then
    fail "mountpoint is already mounted: $mountpoint"
  fi

  # Refuse even a matching-looking entry: a subsequent format changes UUID,
  # so reusing it implicitly could leave an ambiguous or stale boot mount.
  target_source=$(findmnt -srne -M "$mountpoint" -o SOURCE 2>/dev/null || true)
  [ -z "$target_source" ] ||
    fail "fstab already has an entry for mountpoint $mountpoint ($target_source)"

  if [ -d "$mountpoint" ] &&
    find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    fail "mountpoint is not empty; refusing to hide existing data: $mountpoint"
  fi
}

verify_xfs_mount() {
  local fs_type mount_opts xfs_metadata

  fs_type=$(findmnt -rn -M "$mountpoint" -o FSTYPE 2>/dev/null) ||
    fail "new filesystem did not mount at $mountpoint"
  [ "$fs_type" = xfs ] || fail "mounted filesystem is not XFS: $fs_type"
  mount_opts=$(findmnt -rn -M "$mountpoint" -o OPTIONS 2>/dev/null) ||
    fail "cannot read mount options for $mountpoint"
  case ",$mount_opts," in
  *,prjquota,* | *,pquota,*) ;;
  *) fail "project quotas are not active at $mountpoint" ;;
  esac
  xfs_metadata=$(xfs_info "$mountpoint" 2>/dev/null) || fail "xfs_info failed for $mountpoint"
  printf '%s\n' "$xfs_metadata" | grep -Eq '(^|[[:space:],])ftype=1([[:space:],]|$)' ||
    fail "XFS ftype=1 verification failed at $mountpoint"
}

print_next_steps() {
  local mountpoint="$1"
  cat <<EOF

XFS data-root ready at $mountpoint (mounted with prjquota).

Next steps:
  1. Point dockerd at it — either in /etc/docker/daemon.json:
         "data-root": "$mountpoint"
     or for a scratch test daemon:
         dockerd --data-root "$mountpoint"
  2. Restart docker, then verify:
         docker info | grep -E 'Backing Filesystem|Supports d_type'
     must show: Backing Filesystem: xfs / Supports d_type: true
  3. Runner only: install the storage opts + interlock:
         ../install.sh --with-storage-opts
  4. Only after Docker is configured, running, and verified, release the
     maintenance hold:
         systemctl unmask --runtime rd-io-tripwire.timer rd-telemetry.timer
         systemctl start rd-io-tripwire.timer rd-telemetry.timer
EOF
}

if [ "$LOOPBACK" -eq 1 ]; then
  if [ "${#args[@]}" -lt 2 ] || [ "${#args[@]}" -gt 3 ]; then
    usage >&2
    exit 2
  fi
  [ "$FORCE" -eq 0 ] || fail "--force is only valid for formatting an exact block DEVICE"
  img="${args[0]}"
  size="${args[1]}"
  mountpoint="${args[2]:-/var/lib/docker}"

  require_command fallocate
  require_command losetup
  require_command mkfs.xfs
  require_command findmnt
  require_command systemctl
  require_command xfs_info
  quiesce_docker_monitoring
  docker_must_be_stopped
  preflight_mountpoint
  [ ! -e "$img" ] && [ ! -L "$img" ] || fail "loopback image already exists: $img"

  loopdev=
  loop_mounted=0
  image_created=0
  # shellcheck disable=SC2329 # invoked indirectly by EXIT trap
  cleanup_loopback() {
    local status=$?
    trap - EXIT
    if [ "$status" -ne 0 ]; then
      [ "$loop_mounted" -eq 0 ] || umount -- "$mountpoint" 2>/dev/null || true
      [ -z "$loopdev" ] || losetup -d -- "$loopdev" 2>/dev/null || true
      [ "$image_created" -eq 0 ] || rm -f -- "$img"
    fi
    exit "$status"
  }
  trap cleanup_loopback EXIT

  # Preallocated, not sparse: a sparse image full of quota'd writes can
  # still ENOSPC the backing filesystem out from under dockerd.
  (umask 077 && fallocate -l "$size" "$img")
  image_created=1

  loopdev=$(losetup --find --show -- "$img")
  docker_must_be_stopped
  mkfs.xfs -m crc=1 -n ftype=1 "$loopdev"
  mkdir -p "$mountpoint"
  docker_must_be_stopped
  mount -o prjquota -- "$loopdev" "$mountpoint"
  loop_mounted=1
  verify_xfs_mount

  echo "loop device: $loopdev (image: $img)"
  echo "teardown: umount $mountpoint && losetup -d $loopdev && rm -f $img"
  print_next_steps "$mountpoint"
  trap - EXIT
  exit 0
fi

# --- real device mode -----------------------------------------------------
if [ "${#args[@]}" -lt 1 ] || [ "${#args[@]}" -gt 2 ]; then
  usage >&2
  exit 2
fi
device="${args[0]}"
mountpoint="${args[1]:-/var/lib/docker}"

require_command blkid
require_command findmnt
require_command fuser
require_command lsblk
require_command mkfs.xfs
require_command swapon
require_command systemctl
require_command xfs_info
device=$(readlink -f -- "$device") || fail "cannot resolve device: ${args[0]}"
[ -b "$device" ] || fail "$device is not a block device"

quiesce_docker_monitoring
docker_must_be_stopped
preflight_mountpoint

# Inspect the selected device and every descendant. Selecting a whole disk
# must not evade checks merely because its partition, swap, fstab reference,
# open handle, or holder has another pathname.
mapfile -t block_paths < <(lsblk -nrpo NAME "$device")
[ "${#block_paths[@]}" -gt 0 ] || fail "cannot inspect block-device tree: $device"
if lsblk -nrpo MOUNTPOINTS "$device" 2>/dev/null | grep -q '[^[:space:]]'; then
  fail "$device or one of its descendants is mounted or otherwise live"
fi

mapfile -t swap_paths < <(swapon --show=NAME --noheadings --raw 2>/dev/null || true)
for block_path in "${block_paths[@]}"; do
  block_path=$(readlink -f -- "$block_path") || fail "cannot resolve descendant of $device"
  if findmnt -rn -S "$block_path" >/dev/null 2>&1; then
    fail "$block_path is an active mount source"
  fi
  if fuser -s "$block_path" 2>/dev/null; then
    fail "$block_path is open by a running process"
  fi
  for swap_path in "${swap_paths[@]}"; do
    swap_path=$(readlink -f -- "$swap_path" 2>/dev/null || true)
    [ -z "$swap_path" ] || [ "$swap_path" != "$block_path" ] ||
      fail "$block_path is active swap"
  done

  # Refuse dm-crypt, LVM, mdraid, and similar consumers. --force is
  # intentionally not consulted by any in-use check.
  block_name=${block_path##*/}
  if compgen -G "/sys/class/block/$block_name/holders/*" >/dev/null; then
    fail "$block_path has active block-device holders (dm-crypt, LVM, mdraid, or similar)"
  fi

  # findmnt resolves UUID=/LABEL= entries. Check every descendant, not only
  # the spelling supplied on the command line.
  fstab_targets=$(findmnt -srne -S "$block_path" -o TARGET 2>/dev/null || true)
  [ -z "$fstab_targets" ] ||
    fail "fstab already references $block_path (target: $fstab_targets)"
done

# `blkid TYPE` on a whole disk does not report its partition table or child
# filesystems. Never let even --force silently widen from "this filesystem"
# to "erase every partition"; operators must select a leaf partition or
# explicitly wipe a reviewed partition table outside this helper first.
partition_table=$(lsblk -dnro PTTYPE "$device" 2>/dev/null || true)
if [ -n "$partition_table" ] || [ "${#block_paths[@]}" -ne 1 ]; then
  fail "$device contains a partition table or child block devices; select a leaf device"
fi

[ ! -L /etc/fstab ] || fail "/etc/fstab may not be a symlink"
[ ! -e /etc/fstab ] || [ -f /etc/fstab ] || fail "/etc/fstab is not a regular file"

existing_fs=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)
if [ -n "$existing_fs" ] && [ "$FORCE" -ne 1 ]; then
  fail "$device already has a filesystem ($existing_fs); use --force to format this exact device"
fi

mkfs_args=(-m crc=1 -n ftype=1)
[ "$FORCE" -eq 1 ] && mkfs_args+=(-f)
docker_must_be_stopped
mkfs.xfs "${mkfs_args[@]}" "$device"

uuid=$(blkid -o value -s UUID "$device")
[ -n "$uuid" ] || fail "new XFS filesystem has no UUID: $device"
fstab_line="UUID=$uuid $mountpoint xfs defaults,prjquota 0 2"
mkdir -p "$mountpoint"

real_mounted=0
fstab_candidate=
cleanup_real() {
  local status=$?
  trap - EXIT
  rm -f -- "${fstab_candidate:-}"
  if [ "$status" -ne 0 ] && [ "$real_mounted" -eq 1 ]; then
    umount -- "$mountpoint" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup_real EXIT

docker_must_be_stopped
mount -o prjquota -- "$device" "$mountpoint"
real_mounted=1
verify_xfs_mount

# Only make the mount boot-persistent after format, mount, quota, and ftype
# verification have all succeeded. Replace fstab atomically on its filesystem.
[ ! -L /etc/fstab ] || fail "/etc/fstab may not be a symlink"
fstab_candidate=$(mktemp /etc/.fstab.rd-storage.XXXXXX)
if [ -e /etc/fstab ]; then
  [ -f /etc/fstab ] || fail "/etc/fstab is not a regular file"
  cp --preserve=all -- /etc/fstab "$fstab_candidate"
else
  chmod 0644 "$fstab_candidate"
fi
printf '%s\n' "$fstab_line" >>"$fstab_candidate"
mv -f -- "$fstab_candidate" /etc/fstab
fstab_candidate=
trap - EXIT
echo "added to /etc/fstab: $fstab_line"

systemctl daemon-reload 2>/dev/null || true

print_next_steps "$mountpoint"
