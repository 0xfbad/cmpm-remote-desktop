# rd-tlog: durable session transcripts

> **PROTOTYPE — NOT CURRENTLY INTEGRATED WITH THE CTFd PLUGIN.** The image has
> an opt-in `TLOG_ENABLED=1` path and this collector works standalone, but the
> current plugin has no `tlog_socket_path` or telemetry switch, does not mount
> the collector socket at `/dev/log`, and does not emit tlog gap/missing-socket
> events. Installing the collector alone records no plugin sessions.

In an explicitly integrated runtime, standard terminals (ttyd, SSH,
xfce4-terminal, and alacritty) run under `tlog-rec-session`. tlog records
**output only** (no keystrokes, so no captured passwords) as JSON to `/dev/log`,
which must be a bind-mounted collector socket. Transcripts then survive session
teardown (`auto_remove` destroys the container and its writable layer; the host
file is the only durable copy). Production use requires adding and testing that
mount/environment wiring in the plugin first.

## Install (each runner)

```sh
# One-time: use a dedicated >=44 GiB block device or LVM volume. This is the
# kernel-enforced capacity backstop; choose its size from your retention and
# class concurrency requirements.
sudo ./make-store.sh /dev/mapper/rd-tlog
sudo ./install.sh
systemctl status rd-tlog-collector.socket
test -S /run/rd-tlog/log.sock && echo ok
```

After installation, a future/current-site integration must bind-mount
`/run/rd-tlog/log.sock` onto the session's `/dev/log`, set `TLOG_ENABLED=1`,
verify the destination is a socket after container creation, and fail creation
if it is missing. None of those lifecycle steps is performed by the current
plugin; do not enable this for production by editing only the image environment.

## Replay

```sh
tlog-play -r file -i /var/lib/rd-tlog/sessions/<container-name>.tlog.jsonl
```

The `desktop_session_history.container_name` column links each session row to
its transcript filename.

## Operational rules

- **Never `systemctl restart rd-tlog-collector.socket` while sessions run.**
  Re-binding replaces the socket inode; running containers keep the dead one
  and silently lose transcripts until session end. Restarting the `.service`
  is safe (systemd holds the fd).
- Transcripts are best-effort and **tamperable**: a student with in-container
  root can kill tlog, edit `/etc/passwd`, or shim the binary. The `.meta`
  sidecar records the last received write, but an idle terminal and a disabled
  recorder are indistinguishable. Upstream tlog explicitly recommends a
  separate trusted access/jump host when privileged-user recording is a
  security requirement. Host-side cgroup telemetry remains outside student
  control, but it records resources, not terminal contents.
  The prototype host telemetry derives a `tlog_recorder_gap` when the observed
  tlog process count falls from nonzero to zero. The current plugin does not
  consume it. This catches `pkill`, but is a warning rather than proof of
  tampering because closing the last terminal has the same observable result.
- Rate limiting is `action=drop` in the image's tlog conf (delay would read as
  a mysterious terminal hang). Sustained drops truncate noisy tools; the
  collector's durable byte caps (1 GiB/session, 40 GiB total, reconstructed
  after restart) bound normal writes. Production install additionally requires
  `/var/lib/rd-tlog` to be a dedicated finite filesystem, so a software failure
  cannot fill the runner root filesystem.
- Production refuses bind mounts, directories on `/`, non-XFS stores, and
  stores missing `nodev,nosuid,noexec`. The socket, collector, and purge units
  all carry `RequiresMountsFor=/var/lib/rd-tlog`; the collector additionally
  runs the block-store check before every activation, so a missing mount after
  reboot cannot silently redirect transcripts onto the runner root disk.
- Retention: `rd-tlog-purge.timer` deletes transcript files older than
  `RD_TLOG_RETENTION_DAYS` (default 60). Align it manually with the site's
  plugin history-retention policy; the two settings are not wired together.
- journald settings are irrelevant here - this pipeline bypasses journald
  entirely (facility demux happens by content/credentials, not syslogd).

## Dev mode

`sudo ./install.sh --dev` runs the collector in the foreground on
`/tmp/rd-tlog-dev/log.sock`. For local end-to-end testing, launch a container
directly with that socket bind-mounted to `/dev/log` and `TLOG_ENABLED=1`; there
is no current plugin setting that points sessions at it.
