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
# dev box (log caps + tripwire only):
sudo ./install.sh

# runner (adds storage-opts + mount interlock):
sudo ./install.sh --with-storage-opts

# either, without bouncing dockerd (apply config on next restart):
sudo ./install.sh --no-restart-docker
```

install.sh is idempotent and MERGES into any existing /etc/docker/daemon.json
with jq (a timestamped backup is taken first). Unrelated keys such as
`default-address-pools` (owned by the network provisioning) are preserved.

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
