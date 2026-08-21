#!/usr/bin/env bash
# Installs rd storage provisioning: daemon.json log caps (merged, never
# clobbered), rd-io-tripwire units/env/script, and — RUNNER-ONLY, behind
# --with-storage-opts — daemon-wide overlay2.size plus the data-root mount
# interlock. Idempotent; must run as root.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WITH_STORAGE_OPTS=0
RESTART_DOCKER=1

usage() {
    cat <<'EOF'
Usage: install.sh [--with-storage-opts] [--no-restart-docker]
  --with-storage-opts   RUNNER-ONLY: add "storage-opts": ["overlay2.size=20G"]
                        to daemon.json and install the RequiresMountsFor
                        interlock drop-in. Never on the ext4 dev box.
  --no-restart-docker   Do not restart dockerd (config applies next restart).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --with-storage-opts) WITH_STORAGE_OPTS=1 ;;
        --no-restart-docker) RESTART_DOCKER=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must run as root" >&2
    exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

# --- daemon.json: merge with jq, never clobber unrelated keys -------------
DAEMON_JSON=/etc/docker/daemon.json
mkdir -p /etc/docker
if [ -f "$DAEMON_JSON" ]; then
    cp -a "$DAEMON_JSON" "$DAEMON_JSON.bak.$(date +%s)"
    current=$(cat "$DAEMON_JSON")
else
    current='{}'
fi

# Log caps always. Unrelated keys (e.g. default-address-pools, owned by the
# network provisioning) pass through untouched.
merged=$(jq '."log-driver" = "json-file"
    | ."log-opts" = ((."log-opts" // {}) + {"max-size": "50m", "max-file": "3"})' \
    <<<"$current")

if [ "$WITH_STORAGE_OPTS" -eq 1 ]; then
    merged=$(jq '."storage-opts" =
        (((."storage-opts" // []) - ["overlay2.size=20G"]) + ["overlay2.size=20G"])' \
        <<<"$merged")
fi

printf '%s\n' "$merged" > "$DAEMON_JSON"

# --- interlock drop-in (RUNNER-ONLY, tied to --with-storage-opts) ---------
if [ "$WITH_STORAGE_OPTS" -eq 1 ]; then
    install -d /etc/systemd/system/docker.service.d
    install -m 0644 "$HERE/systemd/docker.service.d/10-rd-storage-interlock.conf" \
        /etc/systemd/system/docker.service.d/10-rd-storage-interlock.conf
fi

# --- tripwire script + units + env ----------------------------------------
install -d /usr/local/lib
install -m 0755 "$HERE/bin/rd-io-tripwire.sh" /usr/local/lib/rd-io-tripwire.sh
install -m 0644 "$HERE/systemd/rd-io-tripwire.service" /etc/systemd/system/rd-io-tripwire.service
install -m 0644 "$HERE/systemd/rd-io-tripwire.timer" /etc/systemd/system/rd-io-tripwire.timer
# Preserve local tuning on re-runs.
if [ ! -f /etc/default/rd-io-tripwire ]; then
    install -m 0644 "$HERE/default/rd-io-tripwire" /etc/default/rd-io-tripwire
fi
mkdir -p /var/log/rd-tripwire

systemctl daemon-reload
systemctl enable --now rd-io-tripwire.timer

if [ "$RESTART_DOCKER" -eq 1 ]; then
    systemctl restart docker
else
    echo "install.sh: docker not restarted; daemon.json changes apply on next restart"
fi

echo "install.sh: done (storage-opts: $([ "$WITH_STORAGE_OPTS" -eq 1 ] && echo on || echo off))"
