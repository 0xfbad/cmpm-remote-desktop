# rd-tlog: durable session transcripts

Every terminal a student opens (ttyd, SSH, xfce4-terminal, alacritty) runs
under `tlog-rec-session` when the plugin setting `tlog_enabled` is on. tlog
records **output only** (no keystrokes, so no captured passwords) as JSON to
`/dev/log`, which the plugin bind-mounts from this collector's socket on the
runner. Transcripts survive session teardown (`auto_remove` destroys the
container and its writable layer; the host file is the only durable copy).

## Install (each runner)

```sh
sudo ./install.sh
systemctl status rd-tlog-collector.socket
test -S /run/rd-tlog/log.sock && echo ok
```

Then set `tlog_enabled` on in the plugin admin config. The plugin verifies
`/dev/log` is a socket after each create and raises a `tlog_socket_missing`
event if the collector is absent on that host.

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
- Transcripts are high-fidelity but **tamperable**: a student with in-container
  root can kill tlog, edit `/etc/passwd`, or shim the binary. The `.meta`
  sidecar's frozen `last_write` is the visible-gap record. The untamperable
  record is the host-side cgroup telemetry (provisioning/compute), not tlog.
- Rate limiting is `action=drop` in the image's tlog conf (delay would read as
  a mysterious terminal hang). Sustained drops truncate noisy tools; the
  collector's byte caps (1 GiB/session, 40 GiB total) bound host usage either
  way. Bounding `/var/lib/rd-tlog` with a dedicated quota'd filesystem is a
  runner-provisioning step (see provisioning/storage's loopback primitive).
- Retention: `rd-tlog-purge.timer` deletes transcript files older than
  `RD_TLOG_RETENTION_DAYS` (default 60, matching the plugin's
  `retention_days`).
- journald settings are irrelevant here - this pipeline bypasses journald
  entirely (facility demux happens by content/credentials, not syslogd).

## Dev mode

`sudo ./install.sh --dev` runs the collector in the foreground on
`/tmp/rd-tlog-dev/log.sock`; point the plugin's `tlog_socket_path` setting at
it for local end-to-end testing.
