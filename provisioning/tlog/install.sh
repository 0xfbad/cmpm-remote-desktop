#!/usr/bin/env bash
# installs the rd-tlog collector on a runner. root required.
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "must run as root" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_MODE=0
[ "${1:-}" = "--dev" ] && DEV_MODE=1

if [ "$DEV_MODE" = "1" ]; then
  # foreground collector on a user-writable path for local testing
  STATE_DIR="${RD_TLOG_DEV_DIR:-/tmp/rd-tlog-dev}"
  mkdir -p "$STATE_DIR"
  echo "dev mode: collector foreground, socket $STATE_DIR/log.sock, state $STATE_DIR"
  echo "note: dev self-bind mode re-binds on every start - running containers hold"
  echo "the dead inode after a restart (systemd socket activation fixes this in prod)"
  exec python3 "$HERE/rd_tlog_collector.py" --socket "$STATE_DIR/log.sock" --state-dir "$STATE_DIR"
fi

# Userspace counters protect normal operation; a separate finite filesystem
# is the kernel-enforced backstop if the collector or purge job malfunctions.
# Refuse production installation without it instead of silently consuming the
# runner root filesystem.
mkdir -p /var/lib/rd-tlog
"$HERE/check-store.sh" || {
  echo "Provision a separate finite block device with: $HERE/make-store.sh DEVICE" >&2
  echo "Use --dev only for an explicitly non-production foreground collector." >&2
  exit 1
}

# docker creates a DIRECTORY at the socket path if any tlog-enabled session ran
# before this install; ListenDatagram would then fail to bind
if [ -d /run/rd-tlog/log.sock ]; then
  rmdir /run/rd-tlog/log.sock || {
    echo "ERROR: /run/rd-tlog/log.sock is a non-empty directory; inspect it manually" >&2
    exit 1
  }
fi

install -D -m 0755 "$HERE/rd_tlog_collector.py" /usr/local/lib/rd-tlog/rd_tlog_collector.py
install -D -m 0755 "$HERE/check-store.sh" /usr/local/lib/rd-tlog/check-store.sh
install -D -m 0644 "$HERE/rd-tlog-collector.socket" /etc/systemd/system/rd-tlog-collector.socket
install -D -m 0644 "$HERE/rd-tlog-collector.service" /etc/systemd/system/rd-tlog-collector.service
install -D -m 0644 "$HERE/rd-tlog-purge.service" /etc/systemd/system/rd-tlog-purge.service
install -D -m 0644 "$HERE/rd-tlog-purge.timer" /etc/systemd/system/rd-tlog-purge.timer

systemctl daemon-reload
systemctl enable --now rd-tlog-collector.socket rd-tlog-purge.timer

systemctl is-active --quiet rd-tlog-collector.socket
test -S /run/rd-tlog/log.sock
findmnt --mountpoint /var/lib/rd-tlog
echo "installed: socket active and transcript store is a dedicated finite filesystem"
