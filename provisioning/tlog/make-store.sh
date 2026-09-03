#!/usr/bin/env bash
# Create a dedicated, finite transcript filesystem. Existing filesystems are
# refused unless --force is supplied for the exact block device. --force never
# bypasses an in-use device, unsafe mountpoint, swap, holder, or fstab check.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: make-store.sh [--force] DEVICE [MOUNTPOINT]

  --force      permit formatting the exact DEVICE when it already carries a
               filesystem; never bypass safety checks
  MOUNTPOINT   defaults to /var/lib/rd-tlog
EOF
}

force=0
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
  --force) force=1 ;;
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
    echo "make-store.sh: unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  *) args+=("$1") ;;
  esac
  shift
done

if [ "${#args[@]}" -lt 1 ] || [ "${#args[@]}" -gt 2 ]; then
  usage >&2
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "make-store.sh: must run as root" >&2
  exit 1
fi

fail() {
  echo "make-store.sh: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

preflight_mountpoint() {
  local requested_mountpoint target_source

  requested_mountpoint=$mountpoint
  [ ! -L "$requested_mountpoint" ] || fail "mountpoint may not be a symlink: $requested_mountpoint"
  mountpoint=$(realpath -m -- "$requested_mountpoint") ||
    fail "cannot resolve mountpoint: $requested_mountpoint"
  [ "$mountpoint" != / ] || fail "refusing to use / as the transcript mountpoint"
  case "$mountpoint" in
  *[[:space:]]*) fail "mountpoint may not contain whitespace: $mountpoint" ;;
  esac
  if [ -e "$mountpoint" ] && [ ! -d "$mountpoint" ]; then
    fail "mountpoint exists and is not a directory: $mountpoint"
  fi
  if findmnt -rn -M "$mountpoint" >/dev/null 2>&1; then
    fail "mountpoint is already mounted: $mountpoint"
  fi

  # Never silently replace an existing boot-time mount owner, including one
  # expressed as UUID=, LABEL=, a symlink, or another device spelling.
  target_source=$(findmnt -srne -M "$mountpoint" -o SOURCE 2>/dev/null || true)
  [ -z "$target_source" ] ||
    fail "fstab already has an entry for mountpoint $mountpoint ($target_source)"

  if [ -d "$mountpoint" ] &&
    find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    fail "mountpoint is not empty; refusing to hide existing transcript data: $mountpoint"
  fi
}

device=${args[0]}
mountpoint=${args[1]:-/var/lib/rd-tlog}
minimum_store_bytes=47244640256

for command_name in blkid blockdev findmnt fuser lsblk mkfs.xfs mountpoint realpath swapon; do
  require_command "$command_name"
done

device=$(readlink -f -- "$device") || fail "cannot resolve device: ${args[0]}"
[ -b "$device" ] || fail "$device is not a block device"
preflight_mountpoint

# Treat the selected device as a tree. Selecting a whole disk must not evade
# checks merely because its mounted partition, swap, or consumer has another
# pathname.
mapfile -t block_paths < <(lsblk -nrpo NAME "$device")
[ "${#block_paths[@]}" -gt 0 ] || fail "cannot inspect block-device tree: $device"

if lsblk -nrpo MOUNTPOINTS "$device" 2>/dev/null | grep -q '[^[:space:]]'; then
  fail "$device or one of its descendants is mounted, swap, or otherwise live"
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

  block_name=${block_path##*/}
  if compgen -G "/sys/class/block/$block_name/holders/*" >/dev/null; then
    fail "$block_path has active block-device holders (dm-crypt, LVM, mdraid, or similar)"
  fi

  # findmnt resolves UUID=/LABEL= fstab entries, so check every descendant
  # rather than only the spelling supplied on the command line.
  fstab_targets=$(findmnt -srne -S "$block_path" -o TARGET 2>/dev/null || true)
  [ -z "$fstab_targets" ] ||
    fail "fstab already references $block_path (target: $fstab_targets)"
done

# A parent disk's blkid TYPE omits its partition table and child filesystems.
# Never let --force erase all children: select a leaf partition, or explicitly
# wipe a reviewed partition table outside this helper before retrying.
partition_table=$(lsblk -dnro PTTYPE "$device" 2>/dev/null || true)
if [ -n "$partition_table" ] || [ "${#block_paths[@]}" -ne 1 ]; then
  fail "$device contains a partition table or child block devices; select a leaf device"
fi

[ ! -L /etc/fstab ] || fail "/etc/fstab may not be a symlink"
[ ! -e /etc/fstab ] || [ -f /etc/fstab ] || fail "/etc/fstab is not a regular file"

device_bytes=$(blockdev --getsize64 "$device")
case "$device_bytes" in
'' | *[!0-9]*) fail "cannot determine size of $device" ;;
esac
[ "$device_bytes" -ge "$minimum_store_bytes" ] ||
  fail "$device is ${device_bytes} bytes; at least 44 GiB is required"

existing_fs=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)
if [ -n "$existing_fs" ] && [ "$force" -ne 1 ]; then
  fail "$device already has a filesystem ($existing_fs); use --force to format this exact device"
fi

mkfs_args=(-m crc=1 -n ftype=1)
[ "$force" -eq 1 ] && mkfs_args+=(-f)
mkfs.xfs "${mkfs_args[@]}" "$device"

uuid=$(blkid -o value -s UUID "$device")
[ -n "$uuid" ] || fail "new XFS filesystem has no UUID: $device"
fstab_line="UUID=$uuid $mountpoint xfs defaults,nodev,nosuid,noexec 0 2"
mkdir -p -- "$mountpoint"

store_mounted=0
fstab_candidate=
cleanup() {
  local status=$?
  trap - EXIT
  [ -z "$fstab_candidate" ] || rm -f -- "$fstab_candidate"
  if [ "$status" -ne 0 ] && [ "$store_mounted" -eq 1 ]; then
    umount -- "$mountpoint" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT

# Verify the live mount before changing boot state. A failure leaves fstab
# untouched and the cleanup trap unmounts the newly formatted store.
mount -o nodev,nosuid,noexec -- "$device" "$mountpoint"
store_mounted=1
RD_TLOG_STORE="$mountpoint" "$(dirname "$0")/check-store.sh"
chmod 0750 "$mountpoint"

# Replace fstab atomically on the /etc filesystem. Refuse a symlink because
# rename would replace the link rather than the intended file.
[ ! -L /etc/fstab ] || fail "/etc/fstab may not be a symlink"
fstab_candidate=$(mktemp /etc/.fstab.rd-tlog.XXXXXX)
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

systemctl daemon-reload 2>/dev/null || true

echo "bounded transcript store mounted at $mountpoint"
echo "added to /etc/fstab: $fstab_line"
df -h "$mountpoint"
echo "now run: $(dirname "$0")/install.sh"
