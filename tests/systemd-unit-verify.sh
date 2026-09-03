#!/usr/bin/env bash
# Parse the installed unit graph with real systemd tooling. Run directly on a
# systemd host or inside the pinned Ubuntu container used by GitLab CI.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unit_dir=$(mktemp -d)
cleanup() { rm -rf -- "$unit_dir"; }
trap cleanup EXIT

mkdir -p "$unit_dir/docker.service.d" "$unit_dir/system.slice.d"
cp "$repo/provisioning/network/systemd/rd-network-policy.service" "$unit_dir/"
cp "$repo/provisioning/network/systemd/rd-net-sysctl.service" "$unit_dir/"
cp "$repo/provisioning/network/systemd/docker.service.d/10-rd-network-policy.conf" "$unit_dir/docker.service.d/"
cp "$repo/provisioning/storage/systemd/docker.service.d/10-rd-storage-interlock.conf" "$unit_dir/docker.service.d/"
cp "$repo/provisioning/storage/systemd/rd-io-tripwire.service" "$unit_dir/"
cp "$repo/provisioning/storage/systemd/rd-io-tripwire.timer" "$unit_dir/"
cp "$repo/provisioning/compute/systemd/rd.slice" "$unit_dir/"
cp "$repo/provisioning/compute/systemd/system.slice.d/50-rd-host-reserve.conf" "$unit_dir/system.slice.d/"
cp "$repo/provisioning/compute/telemetry/rd-telemetry.service" "$unit_dir/"
cp "$repo/provisioning/compute/telemetry/rd-telemetry.timer" "$unit_dir/"
cp "$repo/provisioning/tlog/rd-tlog-collector.service" "$unit_dir/"
cp "$repo/provisioning/tlog/rd-tlog-collector.socket" "$unit_dir/"
cp "$repo/provisioning/tlog/rd-tlog-purge.service" "$unit_dir/"
cp "$repo/provisioning/tlog/rd-tlog-purge.timer" "$unit_dir/"

cat >"$unit_dir/docker.service" <<'EOF'
[Unit]
Description=verification stub for Docker
[Service]
ExecStart=/bin/true
EOF
cat >"$unit_dir/nftables.service" <<'EOF'
[Unit]
Description=verification stub for nftables
[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
EOF

mkdir -p /run/systemd
SYSTEMD_UNIT_PATH="$unit_dir:/usr/lib/systemd/system:/lib/systemd/system" \
  systemd-analyze verify \
  docker.service rd-network-policy.service rd-net-sysctl.service \
  rd.slice system.slice rd-io-tripwire.service rd-io-tripwire.timer \
  rd-telemetry.service rd-telemetry.timer \
  rd-tlog-collector.service rd-tlog-collector.socket \
  rd-tlog-purge.service rd-tlog-purge.timer

grep -Fx 'Requires=rd-network-policy.service' "$unit_dir/docker.service.d/10-rd-network-policy.conf" >/dev/null
grep -Fx 'After=rd-network-policy.service' "$unit_dir/docker.service.d/10-rd-network-policy.conf" >/dev/null
grep -Fx 'After=local-fs.target nftables.service' "$unit_dir/rd-network-policy.service" >/dev/null
grep -Fx 'Before=network-pre.target docker.service' "$unit_dir/rd-network-policy.service" >/dev/null
grep -Fx 'PartOf=nftables.service' "$unit_dir/rd-network-policy.service" >/dev/null
grep -Fx 'MemoryMax=90%' "$unit_dir/rd.slice" >/dev/null
grep -Fx 'MemoryMin=2G' "$unit_dir/system.slice.d/50-rd-host-reserve.conf" >/dev/null
grep -Fx 'ExecStart=/usr/local/lib/rd-io-tripwire.sh' "$unit_dir/rd-io-tripwire.service" >/dev/null
for monitor in rd-io-tripwire.service rd-telemetry.service; do
  grep -Fx 'ExecCondition=/usr/bin/systemctl --quiet is-active docker.service' \
    "$unit_dir/$monitor" >/dev/null
  if grep -Eq '^(Requires|Wants)=docker\.service$' "$unit_dir/$monitor"; then
    echo "$monitor must not start Docker when its timer fires" >&2
    exit 1
  fi
done

echo 'systemd-unit-verify: PASS'
