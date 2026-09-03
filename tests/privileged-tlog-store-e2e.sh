#!/usr/bin/env bash
# Destructive regression in an isolated privileged container. The only devices
# formatted are loop devices backed by files created inside that container.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517
name=rd-tlog-store-e2e

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker run --privileged --detach --name "$name" \
  --volume "$repo:/work:ro" --entrypoint sleep "$image" infinity >/dev/null
docker exec "$name" bash -lc \
  'export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null; apt-get install -y --no-install-recommends xfsprogs util-linux fdisk procps psmisc coreutils findutils >/dev/null'

docker exec -i "$name" bash -s <<'INNER'
set -euo pipefail

fail() { echo "privileged-tlog-store-e2e: $*" >&2; exit 1; }
expect_reject() {
  local label=$1
  shift
  if /work/provisioning/tlog/make-store.sh "$@" >/tmp/reject.log 2>&1; then
    cat /tmp/reject.log >&2
    fail "$label was accepted"
  fi
  echo "PASS: $label rejected"
}

truncate -s 48G /tmp/store.img
loop=$(losetup --find --show /tmp/store.img)
parent=
cleanup_inner() {
  umount /mnt/store /mnt/child 2>/dev/null || true
  [ -z "$parent" ] || losetup -d "$parent" 2>/dev/null || true
  losetup -d "$loop" 2>/dev/null || true
}
trap cleanup_inner EXIT

expect_reject 'root mountpoint' "$loop" /
[ -z "$(blkid -o value -s TYPE "$loop" 2>/dev/null || true)" ] || fail 'root rejection formatted device'

mkdir -p /mnt/real
ln -s /mnt/real /mnt/link
expect_reject 'symlink mountpoint' "$loop" /mnt/link
mkdir -p /mnt/nonempty
touch /mnt/nonempty/student-data
expect_reject 'nonempty mountpoint' "$loop" /mnt/nonempty

mkdir -p /mnt/fstab-target
printf '%s %s xfs defaults 0 2\n' "$loop" /mnt/fstab-target >>/etc/fstab
expect_reject 'existing fstab target' "$loop" /mnt/fstab-target
sed -i '\|/mnt/fstab-target|d' /etc/fstab

sleep 60 <"$loop" &
holder_pid=$!
expect_reject 'open device' "$loop" /mnt/store
kill "$holder_pid"
wait "$holder_pid" 2>/dev/null || true

# A whole-disk selection must notice a mounted child partition.
truncate -s 48G /tmp/parent.img
parent=$(losetup --find --show --partscan /tmp/parent.img)
printf ',1G,L\n' | sfdisk "$parent" >/dev/null
losetup -d "$parent"
parent=$(losetup --find --show --partscan /tmp/parent.img)
partx -a "$parent" 2>/dev/null || true
partprobe "$parent" 2>/dev/null || true
udevadm settle 2>/dev/null || true
child="${parent}p1"
[ -b "$child" ] || child="${parent}1"
if [ ! -b "$child" ]; then
  child=$(lsblk -nrpo NAME "$parent" | sed -n '2p')
fi
if [ -n "$child" ] && [ ! -b "$child" ]; then
  child_majmin=$(lsblk -nrpo MAJ:MIN "$parent" | sed -n '2p')
  major=${child_majmin%:*}
  minor=${child_majmin#*:}
  case "$major:$minor" in
  *[!0-9:]*) ;;
  *:*) mknod "$child" b "$major" "$minor" ;;
  esac
fi
[ -b "$child" ] || {
  lsblk -o NAME,MAJ:MIN,TYPE,SIZE "$parent" >&2 || true
  fail "partition device did not appear for $parent"
}
mkfs.xfs -f "$child" >/dev/null
mkdir -p /mnt/child
mount "$child" /mnt/child
expect_reject 'whole disk with mounted child' --force "$parent" /mnt/store
umount /mnt/child

child_uuid=$(blkid -o value -s UUID "$child")
expect_reject 'inactive partitioned whole disk without force' "$parent" /mnt/store
expect_reject 'inactive partitioned whole disk with force' --force "$parent" /mnt/store
[ "$(blkid -o value -s UUID "$child")" = "$child_uuid" ] ||
	fail 'partitioned-disk rejection changed the child filesystem'
losetup -d "$parent"

# Source conflicts expressed through fstab must also block --force.
printf '%s %s xfs defaults 0 2\n' "$loop" /mnt/other >>/etc/fstab
expect_reject 'fstab source reference' --force "$loop" /mnt/store
sed -i '\|/mnt/other|d' /etc/fstab

# If the kernel permits swap in this container, exercise that live-device
# branch too; otherwise the static test still requires the explicit check.
mkswap "$loop" >/dev/null
if swapon "$loop" 2>/dev/null; then
  expect_reject 'active swap' --force "$loop" /mnt/store
  swapoff "$loop"
else
  echo 'SKIP: container kernel denied swapon'
fi

mkdir -p /mnt/store
/work/provisioning/tlog/make-store.sh --force "$loop" /mnt/store >/tmp/success.log
RD_TLOG_STORE=/mnt/store /work/provisioning/tlog/check-store.sh
grep -qE '^UUID=[^ ]+ /mnt/store xfs defaults,nodev,nosuid,noexec 0 2$' /etc/fstab ||
  fail 'verified mount was not atomically recorded in fstab'
echo 'PASS: verified 48 GiB loop-backed XFS store and atomic fstab install'
INNER

echo "privileged-tlog-store-e2e: PASS"
