#!/usr/bin/env bash
# Prove the hardened root telemetry process can observe a student-UID tlog
# process through /proc/PID/comm without CAP_SYS_PTRACE.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

docker run --rm -i \
  --volume "$repo/provisioning/compute/telemetry/rd-telemetry.sh:/rd-telemetry.sh:ro" \
  "$image" bash -s <<'INNER'
set -euo pipefail
cp /bin/sleep /tmp/tlog-rec-session
chmod 0755 /tmp/tlog-rec-session
setpriv --reuid=65534 --regid=65534 --clear-groups /tmp/tlog-rec-session 30 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

scope=/tmp/cgroup/docker-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.scope
mkdir -p "$scope" /tmp/telemetry
printf '%s\n' "$pid" >"$scope/cgroup.procs"
RD_SLICE_CGROUP=/tmp/cgroup \
	RD_TELEMETRY_DIR=/tmp/telemetry \
	RD_NETWORK_CONFIG=/nonexistent \
	bash /rd-telemetry.sh

grep -q '"tlog_processes": 1' /tmp/telemetry/current.json
echo 'privileged-telemetry-e2e: PASS (different-UID tlog comm observed)'
INNER
