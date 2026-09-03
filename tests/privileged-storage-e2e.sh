#!/usr/bin/env bash
# Destructive storage guard regression in an isolated privileged container.
# Only loop devices backed by files created inside the container are formatted.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517
name=rd-storage-e2e

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run --privileged --detach --name "$name" \
  --volume "$repo:/work:ro" --entrypoint sleep "$image" infinity >/dev/null
docker exec "$name" bash -lc \
  'export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null; apt-get install -y --no-install-recommends xfsprogs util-linux fdisk procps psmisc coreutils findutils >/dev/null'

docker exec -i "$name" bash -s <<'INNER'
set -euo pipefail

fail() { echo "privileged-storage-e2e: $*" >&2; exit 1; }
expect_reject() {
	local label=$1
	shift
	if /work/provisioning/storage/xfs/make-data-root.sh "$@" >/tmp/reject.log 2>&1; then
		cat /tmp/reject.log >&2
		fail "$label was accepted"
	fi
	echo "PASS: $label rejected"
}
make_partitioned_loop() {
	local image=$1 loop child child_majmin major minor
	truncate -s 8G "$image"
	loop=$(losetup --find --show "$image")
	printf ',1G,L\n' | sfdisk "$loop" >/dev/null
	losetup -d "$loop"
	loop=$(losetup --find --show --partscan "$image")
	partx -a "$loop" 2>/dev/null || true
	partprobe "$loop" 2>/dev/null || true
	child=$(lsblk -nrpo NAME "$loop" | sed -n '2p')
	[ -n "$child" ] || fail "partition device did not appear for $loop"
	if [ ! -b "$child" ]; then
		child_majmin=$(lsblk -nrpo MAJ:MIN "$loop" | sed -n '2p')
		major=${child_majmin%:*}
		minor=${child_majmin#*:}
		mknod "$child" b "$major" "$minor"
	fi
	printf '%s %s\n' "$loop" "$child"
}

read -r parent child < <(make_partitioned_loop /tmp/parent.img)
success_loop=
cleanup_inner() {
	umount /mnt/child /mnt/docker 2>/dev/null || true
	[ -z "$success_loop" ] || losetup -d "$success_loop" 2>/dev/null || true
	losetup -d "$parent" 2>/dev/null || true
}
trap cleanup_inner EXIT

sleep 60 <"$child" &
holder_pid=$!
expect_reject 'whole disk with open child partition' --force "$parent" /mnt/docker
kill "$holder_pid"
wait "$holder_pid" 2>/dev/null || true

mkfs.xfs -f "$child" >/dev/null
uuid=$(blkid -o value -s UUID "$child")
printf 'UUID=%s /mnt/fstab-child xfs defaults 0 2\n' "$uuid" >>/etc/fstab
expect_reject 'whole disk with UUID-referenced child partition' --force "$parent" /mnt/docker
sed -i '\|/mnt/fstab-child|d' /etc/fstab

mkdir -p /mnt/child
mount "$child" /mnt/child
expect_reject 'whole disk with mounted child partition' --force "$parent" /mnt/docker
umount /mnt/child

child_uuid=$(blkid -o value -s UUID "$child")
expect_reject 'inactive partitioned whole disk without force' "$parent" /mnt/docker
expect_reject 'inactive partitioned whole disk with force' --force "$parent" /mnt/docker
[ "$(blkid -o value -s UUID "$child")" = "$child_uuid" ] ||
	fail 'partitioned-disk rejection changed the child filesystem'

# fstab type checks happen before mkfs, not after destructive mutation.
mv /etc/fstab /etc/fstab.real
ln -s /etc/fstab.real /etc/fstab
expect_reject 'symlink /etc/fstab' --force "$parent" /mnt/docker
rm /etc/fstab
mv /etc/fstab.real /etc/fstab

truncate -s 8G /tmp/success.img
success_loop=$(losetup --find --show /tmp/success.img)
mkdir -p /mnt/docker
/work/provisioning/storage/xfs/make-data-root.sh "$success_loop" /mnt/docker >/tmp/success.log
findmnt -rn -M /mnt/docker -o FSTYPE,OPTIONS | grep -Eq '^xfs .*\b(prjquota|pquota)\b' ||
	fail 'success mount lacks XFS project quotas'
grep -qE '^UUID=[^ ]+ /mnt/docker xfs defaults,prjquota 0 2$' /etc/fstab ||
	fail 'verified mount was not atomically recorded in fstab'
echo 'PASS: verified XFS project-quota store and atomic fstab install'
INNER

echo "privileged-storage-e2e: PASS"
