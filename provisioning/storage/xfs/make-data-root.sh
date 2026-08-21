#!/usr/bin/env bash
# Builds an XFS docker data-root with project quotas (required for
# overlay2 storage-opt size). Two modes:
#   make-data-root.sh [--force] DEVICE [MOUNTPOINT]
#       Real device: mkfs.xfs -m crc=1 -n ftype=1, fstab entry with prjquota,
#       mount. Refuses a device that already has a filesystem unless --force.
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

  --force      overwrite a device/image that already carries a filesystem
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
        -h|--help) usage; exit 0 ;;
        *) args+=("$1") ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ]; then
    echo "make-data-root.sh: must run as root" >&2
    exit 1
fi

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
EOF
}

if [ "$LOOPBACK" -eq 1 ]; then
    if [ "${#args[@]}" -lt 2 ]; then usage >&2; exit 2; fi
    img="${args[0]}"
    size="${args[1]}"
    mountpoint="${args[2]:-/var/lib/docker}"

    if [ -e "$img" ] && [ "$FORCE" -ne 1 ]; then
        echo "make-data-root.sh: $img exists; use --force to overwrite" >&2
        exit 1
    fi
    rm -f "$img"
    # Preallocated, not sparse: a sparse image full of quota'd writes can
    # still ENOSPC the backing filesystem out from under dockerd.
    fallocate -l "$size" "$img"

    loopdev=$(losetup --find --show "$img")
    mkfs.xfs -f -m crc=1 -n ftype=1 "$loopdev"
    mkdir -p "$mountpoint"
    mount -o prjquota "$loopdev" "$mountpoint"

    echo "loop device: $loopdev (image: $img)"
    echo "teardown: umount $mountpoint && losetup -d $loopdev && rm -f $img"
    print_next_steps "$mountpoint"
    exit 0
fi

# --- real device mode -----------------------------------------------------
if [ "${#args[@]}" -lt 1 ]; then usage >&2; exit 2; fi
device="${args[0]}"
mountpoint="${args[1]:-/var/lib/docker}"

if [ ! -b "$device" ]; then
    echo "make-data-root.sh: $device is not a block device" >&2
    exit 1
fi

existing_fs=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)
if [ -n "$existing_fs" ] && [ "$FORCE" -ne 1 ]; then
    echo "make-data-root.sh: $device already has a filesystem ($existing_fs); use --force to overwrite" >&2
    exit 1
fi

mkfs_args=(-m crc=1 -n ftype=1)
[ "$FORCE" -eq 1 ] && mkfs_args+=(-f)
mkfs.xfs "${mkfs_args[@]}" "$device"

uuid=$(blkid -o value -s UUID "$device")
fstab_line="UUID=$uuid $mountpoint xfs defaults,prjquota 0 2"
if ! grep -qF "UUID=$uuid " /etc/fstab 2>/dev/null; then
    printf '%s\n' "$fstab_line" >> /etc/fstab
    echo "added to /etc/fstab: $fstab_line"
else
    echo "fstab entry for UUID=$uuid already present; not modified"
fi

mkdir -p "$mountpoint"
systemctl daemon-reload 2>/dev/null || true
mount "$mountpoint" 2>/dev/null || mount -o prjquota "$device" "$mountpoint"

print_next_steps "$mountpoint"
