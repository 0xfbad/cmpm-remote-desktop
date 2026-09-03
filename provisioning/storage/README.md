# Storage provisioning (rd-io-tripwire, daemon.json log caps, XFS data-root)

Host-side pieces for the remote-desktop storage budget: json-file log caps,
an IO tripwire that pauses runaway writers, the docker/data-root mount
interlock, and the XFS data-root build script.

> **RUNNER-ONLY:** `install.sh --with-storage-opts` (daemon-wide
> `overlay2.size=20G`) and the `10-rd-storage-interlock.conf` drop-in must
> NEVER be applied to the ext4 dev box. On ext4 the daemon refuses
> overlay2.size and dockerd will not start — on a runner with a missing XFS
> mount, dockerd refusing to start is the interlock *working*.

## Applicability matrix

| Piece                                          | dev box (ext4) | XFS runners |
|------------------------------------------------|:--------------:|:-----------:|
| daemon.json log caps (log-driver + log-opts)   | yes            | yes         |
| rd-io-tripwire service/timer/script/env        | yes (ihard pass self-skips on ext4) | yes |
| `--with-storage-opts` (overlay2.size=20G)      | **never**      | yes         |
| docker.service.d/10-rd-storage-interlock.conf  | **never**      | yes         |
| xfs/make-data-root.sh (real device mode)       | no             | yes         |
| xfs/make-data-root.sh `--loopback` test mode   | yes (scratch dockerd testing) | yes |

## Install

```sh
# dev box (log caps + tripwire only; Docker is not restarted):
sudo ./install.sh

# runner (adds storage-opts + mount interlock; Docker is not restarted):
sudo ./install.sh --with-storage-opts

# Explicitly apply a changed config on an already-drained host:
sudo ./install.sh --with-storage-opts --restart-docker
```

Docker restart is deliberately opt-in. Even with `--restart-docker`, the
installer restarts only an already-running daemon, only when daemon.json or the
mount interlock actually changed, and only after `docker ps` is empty both
before mutation and immediately before restart. It never starts an inactive
daemon. If the changed configuration fails to restart, the installer restores
the exact prior daemon.json and interlock drop-in, reloads systemd, attempts one
recovery restart with the old files, and still exits nonzero so the failed
change cannot be mistaken for success. Without the flag, changed settings take
effect on the next operator-controlled Docker restart.

`install.sh --with-storage-opts` queries the running daemon for its active
Docker data-root and exits without changing configuration unless that exact
directory is a dedicated XFS mount with project quotas (`prjquota`/`pquota`)
and `ftype=1`. The mount must be a whole, block-backed filesystem on a device
separate from `/`, not a bind mount. This intentionally requires Docker to be
running for the preflight; it prevents checking one path while dockerd actually
uses another.

`install.sh` is idempotent and merges into any existing
`/etc/docker/daemon.json` with jq. It creates the candidate as a mode-0600
temporary file in `/etc/docker`, validates it with both jq and
`dockerd --validate`, takes a timestamped backup of the prior file, and then
renames the candidate into place atomically. Invalid existing or generated
configuration is left untouched. Unrelated keys such as
`default-address-pools` (owned by the network provisioning) are preserved.
The generated systemd mount interlock uses the active data-root reported by
Docker rather than assuming `/var/lib/docker`.

## Prepare an XFS data-root

Stop both Docker activation paths before invoking the destructive real-device
mode:

```sh
sudo systemctl stop docker.socket docker.service
sudo ./xfs/make-data-root.sh /dev/disk/by-id/EXACT_DEVICE /var/lib/docker
```

At entry, the helper runtime-masks `rd-io-tripwire.timer` and
`rd-telemetry.timer`, stops any in-flight instances of their services, and
leaves that maintenance hold in place. Their service units also use an
`ExecCondition` instead of `Requires=`/`Wants=`, so a timer firing can never
start a deliberately stopped Docker daemon through dependency or socket
activation. The helper rechecks both systemd activation paths and the dockerd
process immediately before every `mkfs.xfs` and every mount.

The helper refuses to proceed if Docker/dockerd is active, the selected block
device (or a child) is mounted or has active holders, the device is referenced
by fstab or open by a process, the mount target is mounted or referenced by
fstab, or the target is nonempty. These checks are never bypassed. `--force`
has one narrow meaning:
it passes `-f` to `mkfs.xfs` for the resolved, exact block device when that
device already has a filesystem. It is not accepted in `--loopback` mode and
does not overwrite an existing loopback image.

The fstab entry is installed only after the new filesystem has mounted and
XFS project quotas plus `ftype=1` have been verified. The default target is
`/var/lib/docker`; a nonempty directory is rejected so an XFS mount cannot
silently hide existing Docker data.

Keep the monitoring timers masked while configuring and verifying the new
Docker root. Release the hold only after Docker is healthy on the intended
mount:

```sh
sudo systemctl unmask --runtime rd-io-tripwire.timer rd-telemetry.timer
sudo systemctl enable --now rd-io-tripwire.timer rd-telemetry.timer
```

`install.sh` detects this runtime mask and will not remove it or fail by trying
to start the held timer.

For a non-persistent scratch test, use a new image path and an empty target:

```sh
sudo ./xfs/make-data-root.sh --loopback /var/tmp/rd-xfs.img 30G /mnt/rd-docker-test
```

## Non-destructive checks

```sh
./tests/storage-safety-static.sh
./tests/storage-install-regression.sh
```

This checks shell syntax, the reference JSON, validation/install ordering, and
the presence of the destructive-operation guardrails. The behavioral
regression uses a temporary filesystem root and fake Docker/systemd commands to
prove restart opt-in, no-op change sensitivity, drain refusal, and rollback of
both prior config files after a simulated failed restart. The checks also run
shellcheck when it is installed. They do not format, mount, restart, or write to
host configuration.

## Post-install verification

Runner (XFS data-root):

1. `docker info` shows `Backing Filesystem: xfs` and `Supports d_type: true`.
2. Unmount drill: stop dockerd, unmount the data-root, `systemctl start docker`
   — dockerd must stay **down and loud** (RequiresMountsFor dependency
   failure). That is the interlock working; remount and start to recover.

Everywhere:

3. `systemctl status rd-io-tripwire.timer` — active, firing every 5s.
4. `journalctl -t rd-io-tripwire` after a `dd` burst in an `rd-session-*`
   container: strikes accumulate, `docker pause` fires, a forensics JSON
   record lands in /var/log/rd-tripwire/.
5. An idle container (empty io.stat) produces zero strikes and no errors.
6. On ext4 the ihard pass logs nothing and exits 0 (by design).

The tripwire only ever `docker pause`s — never stop/kill/rm. auto_remove
would delete the writable layer, i.e. the evidence.

## Caveat: buffered overlay writes may evade io.stat ([VERIFY ON RUNNER])

Verified on the dev box (kernel 6.18, ext4-on-LUKS): buffered writes through
the overlayfs upper layer are NOT attributed to the container's cgroup io.stat
even with fdatasync - only direct IO (`oflag=direct`) shows up. The tripwire's
wbytes rate is therefore a lower bound, not a complete measure; the kernel
project quota (overlay2.size) is the actual containment, and the tripwire is a
detection layer for the IO patterns that do get attributed. Re-verify
attribution on the XFS runners; if buffered overlay writeback is attributed
there, the tripwire sees everything.
