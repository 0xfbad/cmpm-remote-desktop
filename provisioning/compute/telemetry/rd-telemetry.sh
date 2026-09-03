#!/usr/bin/env bash
# rd-telemetry.sh - snapshot per-session cgroup telemetry for rd.slice.
# Installed to /usr/local/lib/rd-telemetry.sh, driven by rd-telemetry.timer.
# Composes JSON without a jq dependency and atomically publishes a strict v1
# runner-readiness contract plus per-container telemetry.
# The trap guarantees exit 0 so a partial read can never put the oneshot
# service into systemd failure backoff.
set -u
trap 'exit 0' EXIT

# Overridable for unprivileged testing.
TELEMETRY_DIR="${RD_TELEMETRY_DIR:-/var/lib/rd-telemetry}"
SLICE_CGROUP="${RD_SLICE_CGROUP:-/sys/fs/cgroup/rd.slice}"
NETWORK_CONFIG="${RD_NETWORK_CONFIG:-/etc/rd-network.conf}"

# Installed by network provisioning, root-owned and shell-escaped with %q.
RD_NETWORK_POLICY_VERSION=""
RD_POOL_BASE=""
RD_POOL_SIZE=""
RD_BIND_IP=""
RD_PROXY_CIDRS=""
RD_RUNNER_PEER_CIDRS=""
if [ -r "$NETWORK_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$NETWORK_CONFIG"
fi

is_private_ipv4() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  for octet in "$a" "$b" "$c" "$d"; do
    case "$octet" in '' | *[!0-9]*) return 1 ;; esac
    [ "$octet" -le 255 ] || return 1
  done
  [ "$a" -eq 10 ] ||
    { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } ||
    { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; }
}

within_percent() {
  awk -v actual="$1" -v total_kb="$2" -v percent="$3" 'BEGIN {
    expected = total_kb * 1024 * percent / 100
    delta = actual - expected
    if (delta < 0) delta = -delta
    exit !(expected > 0 && delta <= expected * 0.05)
  }'
}

# slice_unconfigured is decided from systemd properties, NOT from cgroup
# directory existence: /sys/fs/cgroup/rd.slice is absent whenever the slice
# is merely inactive (zero sessions), and that must NOT read as
# "unconfigured". An unprovisioned host shows MemoryMax=infinity on the
# implicitly-created slice; a missing unit shows empty output.
slice_props="$(systemctl show rd.slice -p LoadState -p CPUWeight -p IOWeight -p MemoryHigh -p MemoryMax -p MemorySwapMax -p TasksMax --value 2>/dev/null)" || slice_props=""
readarray -t slice_values <<<"$slice_props"
load_state="${slice_values[0]:-}"
cpu_weight="${slice_values[1]:-}"
io_weight="${slice_values[2]:-}"
memory_high="${slice_values[3]:-}"
memory_max="${slice_values[4]:-}"
memory_swap_max="${slice_values[5]:-}"
tasks_max="${slice_values[6]:-}"
system_memory_min="$(systemctl show system.slice -p MemoryMin --value 2>/dev/null)" || system_memory_min=""
kernel_pid_max="$(sysctl -n kernel.pid_max 2>/dev/null)" || kernel_pid_max=""
mem_total_kb="$(awk '$1 == "MemTotal:" { print $2 }' /proc/meminfo)"

slice_configured=false
if [ "$load_state" = loaded ] && [ -n "$memory_max" ] && [ "$memory_max" != infinity ]; then
  slice_configured=true
fi
slice_unconfigured=true
[ "$slice_configured" = true ] && slice_unconfigured=false

compute_limits_match=false
if [ "$slice_configured" = true ] &&
  [ "$cpu_weight" = 50 ] && [ "$io_weight" = 50 ] && [ "$tasks_max" = 32768 ] &&
  [ "$system_memory_min" = 2147483648 ] && [ "$kernel_pid_max" = 131072 ] &&
  within_percent "$memory_high" "$mem_total_kb" 70 &&
  within_percent "$memory_max" "$mem_total_kb" 90 &&
  within_percent "$memory_swap_max" "$mem_total_kb" 25; then
  compute_limits_match=true
fi

# The non-dev network prototype installer owns this table and its invariant
# peer drop. Report the result in the trusted host snapshot so a future
# consumer can detect reboot/manual policy loss; it does not prove that a
# complete production firewall exists.
nft_rules="$(nft list ruleset 2>/dev/null)" || nft_rules=""
has_marker() { grep -q "comment \"$1\"" <<<"$nft_rules"; }
network_policy_loaded=false
network_policy_service_active=false
systemctl is-active --quiet rd-network-policy.service 2>/dev/null && network_policy_service_active=true
docker_requires_policy=false
docker_after_policy=false
docker_requires="$(systemctl show docker.service -p Requires --value 2>/dev/null)" || docker_requires=""
docker_after="$(systemctl show docker.service -p After --value 2>/dev/null)" || docker_after=""
case " $docker_requires " in *" rd-network-policy.service "*) docker_requires_policy=true ;; esac
case " $docker_after " in *" rd-network-policy.service "*) docker_after_policy=true ;; esac
if [ "$RD_NETWORK_POLICY_VERSION" = 1 ] && [ "$network_policy_service_active" = true ] &&
  [ "$docker_requires_policy" = true ] && [ "$docker_after_policy" = true ] &&
  has_marker rd-peer-session-drop-v1 &&
  has_marker rd-runner-peer-drop-v1 && has_marker rd-host-input-drop-v1 &&
  has_marker rd-bridge-drop-v1; then
  network_policy_loaded=true
fi
network_proxy_acl=false
if [ -n "$RD_PROXY_CIDRS" ] && has_marker rd-proxy-web-allow-v1 &&
  has_marker rd-proxy-web-return-v1 && has_marker rd-proxy-web-drop-v1 &&
  has_marker rd-raw-vnc-drop-v1; then
  network_proxy_acl=true
fi

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}
int2ip() {
  local n="$1"
  echo "$(((n >> 24) & 255)).$(((n >> 16) & 255)).$(((n >> 8) & 255)).$((n & 255))"
}

network_pool_ready=false
network_private_binding=false
pool_base_protected=false
if python3 - "$RD_POOL_BASE" >/dev/null 2>&1 <<'PY'; then
import ipaddress
import sys

try:
    pool = ipaddress.IPv4Network(sys.argv[1], strict=True)
except ValueError:
    raise SystemExit(1)
raise SystemExit(not pool.subnet_of(ipaddress.IPv4Network("10.77.0.0/16")))
PY
  pool_base_protected=true
fi
if [ "$pool_base_protected" = true ] && [[ $RD_POOL_SIZE =~ ^[0-9]+$ ]] &&
  [ "$RD_POOL_SIZE" -gt 0 ] && [ -n "$RD_POOL_BASE" ]; then
  pool_ok=true
  binding_ok=true
  is_private_ipv4 "$RD_BIND_IP" || binding_ok=false
  base_int="$(ip2int "${RD_POOL_BASE%/*}")"
  count="$(docker network ls --filter label=rd.pool=1 --format '{{.Name}}' 2>/dev/null | grep -c '^rd-net-' || true)"
  [ "$count" -eq "$RD_POOL_SIZE" ] || pool_ok=false
  for ((i = 0; i < RD_POOL_SIZE; i++)); do
    ii="$(printf '%02d' "$i")"
    name="rd-net-$ii"
    expected="$(int2ip $((base_int + i * 16)))/28"
    actual="$(docker network inspect -f '{{ (index .IPAM.Config 0).Subnet }}' "$name" 2>/dev/null)" || actual=""
    icc="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.enable_icc" }}' "$name" 2>/dev/null)" || icc=""
    bridge="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.name" }}' "$name" 2>/dev/null)" || bridge=""
    binding="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.host_binding_ipv4" }}' "$name" 2>/dev/null)" || binding=""
    [ "$actual" = "$expected" ] && [ "$icc" = false ] && [ "$bridge" = "rdb$ii" ] || pool_ok=false
    [ -n "$RD_BIND_IP" ] && [ "$binding" = "$RD_BIND_IP" ] || binding_ok=false
  done
  [ "$pool_ok" = true ] && network_pool_ready=true
  [ "$binding_ok" = true ] && network_private_binding=true
fi

tlog_socket_active=false
if [ -S /run/rd-tlog/log.sock ] && systemctl is-active --quiet rd-tlog-collector.socket 2>/dev/null; then
  tlog_socket_active=true
fi
tlog_store_mounted=false
mountpoint -q /var/lib/rd-tlog 2>/dev/null && tlog_store_mounted=true
tlog_store_block_backed=false
if [ -x /usr/local/lib/rd-tlog/check-store.sh ] && /usr/local/lib/rd-tlog/check-store.sh >/dev/null 2>&1; then
  tlog_store_block_backed=true
fi

storage_driver="$(docker info --format '{{.Driver}}' 2>/dev/null)" || storage_driver=""
storage_backing="$(docker info --format '{{range .DriverStatus}}{{if eq (index . 0) "Backing Filesystem"}}{{index . 1}}{{end}}{{end}}' 2>/dev/null)" || storage_backing=""
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" || docker_root=""
storage_project_quota=false
storage_dedicated_mount=false
storage_block_backed=false
storage_separate_device=false
storage_ftype_one=false
if [ -n "$docker_root" ] && docker_root="$(realpath -e -- "$docker_root" 2>/dev/null)"; then
  docker_mount="$(findmnt -rn -M "$docker_root" -o TARGET 2>/dev/null)" || docker_mount=""
  if [ "$docker_mount" = "$docker_root" ]; then
    storage_dedicated_mount=true
  fi
  docker_fstype="$(findmnt -rn -M "$docker_root" -o FSTYPE 2>/dev/null)" || docker_fstype=""
  docker_options="$(findmnt -rn -M "$docker_root" -o OPTIONS 2>/dev/null)" || docker_options=""
  case ",$docker_options," in *",prjquota,"* | *",pquota,"*) storage_project_quota=true ;; esac
  docker_source="$(findmnt -rn -M "$docker_root" -o SOURCE 2>/dev/null)" || docker_source=""
  docker_source="${docker_source%%\[*}"
  docker_source="$(readlink -f -- "$docker_source" 2>/dev/null)" || docker_source=""
  [ -b "$docker_source" ] && storage_block_backed=true
  docker_device="$(findmnt -rn -M "$docker_root" -o MAJ:MIN 2>/dev/null)" || docker_device=""
  root_device="$(findmnt -rn -M / -o MAJ:MIN 2>/dev/null)" || root_device=""
  [ -n "$docker_device" ] && [ "$docker_device" != "$root_device" ] && storage_separate_device=true
  if command -v xfs_info >/dev/null 2>&1 &&
    xfs_info "$docker_root" 2>/dev/null | grep -Eq '(^|[[:space:],])ftype=1([[:space:],]|$)'; then
    storage_ftype_one=true
  fi
else
  docker_fstype=""
fi
storage_ready=false
if [ "$storage_driver" = overlay2 ] && [ "$storage_backing" = xfs ] &&
  [ "$docker_fstype" = xfs ] && [ "$storage_project_quota" = true ] &&
  [ "$storage_dedicated_mount" = true ] && [ "$storage_block_backed" = true ] &&
  [ "$storage_separate_device" = true ] && [ "$storage_ftype_one" = true ]; then
  storage_ready=true
fi

# Emit {"avg10":..,"avg60":..,"avg300":..,"total":..} from the "some" line
# of a PSI file; zeros if the file or line is missing.
pressure_json() {
  awk '
        $1 == "some" {
            for (i = 2; i <= NF; i++) {
                if (split($i, kv, "=") == 2) v[kv[1]] = kv[2]
            }
            found = 1
        }
        END {
            printf "{\"avg10\": %s, \"avg60\": %s, \"avg300\": %s, \"total\": %s}",
                v["avg10"] + 0, v["avg60"] + 0, v["avg300"] + 0, v["total"] + 0
        }' "$1" 2>/dev/null ||
    printf '{"avg10": 0, "avg60": 0, "avg300": 0, "total": 0}'
}

# Emit the six counters of memory.events; zeros for missing keys/file.
memory_events_json() {
  awk '
        { v[$1] = $2 }
        END {
            printf "{\"low\": %d, \"high\": %d, \"max\": %d, \"oom\": %d, \"oom_kill\": %d, \"oom_group_kill\": %d}",
                v["low"], v["high"], v["max"], v["oom"], v["oom_kill"], v["oom_group_kill"]
        }' "$1" 2>/dev/null ||
    printf '{"low": 0, "high": 0, "max": 0, "oom": 0, "oom_kill": 0, "oom_group_kill": 0}'
}

# Emit {"max": N} from pids.events; zero if missing.
pids_events_json() {
  awk '
        $1 == "max" { m = $2 }
        END { printf "{\"max\": %d}", m }
        ' "$1" 2>/dev/null ||
    printf '{"max": 0}'
}

containers=""
sep=""
for scope_dir in "$SLICE_CGROUP"/docker-*.scope; do
  # Glob may match nothing (slice inactive/absent); the literal pattern is
  # not a directory, so this also serves as the no-match guard.
  [ -d "$scope_dir" ] || continue

  scope_name="${scope_dir##*/}"
  cid="${scope_name#docker-}"
  cid="${cid%.scope}"
  # Only full 64-hex container ids.
  case "$cid" in
  *[!0-9a-f]*) continue ;;
  esac
  [ "${#cid}" -eq 64 ] || continue

  cpu_p="$(pressure_json "$scope_dir/cpu.pressure")"
  io_p="$(pressure_json "$scope_dir/io.pressure")"
  mem_p="$(pressure_json "$scope_dir/memory.pressure")"
  mem_ev="$(memory_events_json "$scope_dir/memory.events")"
  pids_ev="$(pids_events_json "$scope_dir/pids.events")"

  # Raw first line of io.stat (may be empty when no io yet / file absent).
  # Content is "MAJ:MIN key=val ..." - no characters needing JSON escaping.
  io_stat="$(sed -n '1p' "$scope_dir/io.stat" 2>/dev/null)" || io_stat=""

  mem_cur="$(cat "$scope_dir/memory.current" 2>/dev/null)" || mem_cur=""
  case "$mem_cur" in
  '' | *[!0-9]*) mem_cur=0 ;;
  esac
  # memory.max is raw text on purpose: it can be the string "max".
  mem_max="$(cat "$scope_dir/memory.max" 2>/dev/null)" || mem_max=""

  # Host-observed process-name count. /proc/PID/exe is subject to ptrace access
  # checks across UIDs; /proc/PID/comm remains readable to this root service
  # without granting CAP_SYS_PTRACE. Linux truncates comm to TASK_COMM_LEN-1,
  # hence the expected tlog-rec-sessio spelling. Container root can still kill
  # or replace tlog, so a transition to zero is a gap signal, not proof.
  tlog_processes=0
  while read -r pid; do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || comm=""
    case "$comm" in
    tlog-rec-session | tlog-rec-sessio) tlog_processes=$((tlog_processes + 1)) ;;
    esac
  done <"$scope_dir/cgroup.procs"

  obj="{\"id\": \"$cid\""
  obj="$obj, \"cpu_pressure\": $cpu_p"
  obj="$obj, \"io_pressure\": $io_p"
  obj="$obj, \"memory_pressure\": $mem_p"
  obj="$obj, \"memory_events\": $mem_ev"
  obj="$obj, \"pids_events\": $pids_ev"
  obj="$obj, \"io_stat\": \"$io_stat\""
  obj="$obj, \"memory_current\": $mem_cur"
  obj="$obj, \"memory_max\": \"$mem_max\""
  obj="$obj, \"tlog_processes\": $tlog_processes}"

  containers="$containers$sep$obj"
  sep=", "
done

mkdir -p "$TELEMETRY_DIR" 2>/dev/null || exit 0
out="$TELEMETRY_DIR/current.json"

ready=true
for check in "$slice_configured" "$compute_limits_match" "$network_policy_loaded" \
  "$network_pool_ready" "$network_private_binding" "$network_proxy_acl" \
  "$tlog_socket_active" "$tlog_store_mounted" "$tlog_store_block_backed" "$storage_ready"; do
  [ "$check" = true ] || ready=false
done

cidrs_json() {
  local raw="$1" item output="" separator=""
  IFS=, read -ra items <<<"$raw"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -n "$item" ] || continue
    output="$output$separator\"$item\""
    separator=", "
  done
  printf '[%s]' "$output"
}
proxy_cidrs_json="$(cidrs_json "$RD_PROXY_CIDRS")"
runner_peer_cidrs_json="$(cidrs_json "$RD_RUNNER_PEER_CIDRS")"

# tmp-then-rename: atomic on the same filesystem, readers never see a
# partial file. Single fixed-size file, so the spool is bounded.
printf '%s\n' "{
  \"schema_version\": 1,
  \"ts\": $(date +%s),
  \"ready\": $ready,
  \"readiness\": {
    \"slice_configured\": $slice_configured,
    \"compute_limits_match\": $compute_limits_match,
    \"network_policy_loaded\": $network_policy_loaded,
    \"network_pool_ready\": $network_pool_ready,
    \"network_private_binding\": $network_private_binding,
    \"network_proxy_acl\": $network_proxy_acl,
    \"tlog_socket_active\": $tlog_socket_active,
    \"tlog_store_mounted\": $tlog_store_mounted,
    \"tlog_store_block_backed\": $tlog_store_block_backed,
    \"storage_ready\": $storage_ready
  },
  \"configuration\": {
    \"cgroup_parent\": \"rd.slice\",
    \"compute\": {
      \"cpu_weight\": 50,
      \"io_weight\": 50,
      \"memory_high_percent\": 70,
      \"memory_max_percent\": 90,
      \"memory_swap_max_percent\": 25,
      \"tasks_max\": 32768,
      \"system_memory_min\": 2147483648,
      \"kernel_pid_max\": 131072
    },
    \"network\": {
      \"policy_version\": ${RD_NETWORK_POLICY_VERSION:-0},
      \"pool_base\": \"$RD_POOL_BASE\",
      \"pool_size\": ${RD_POOL_SIZE:-0},
      \"bind_ip\": \"$RD_BIND_IP\",
      \"proxy_cidrs\": $proxy_cidrs_json,
      \"runner_peer_cidrs\": $runner_peer_cidrs_json,
      \"service_active\": $network_policy_service_active,
      \"docker_requires_policy\": $docker_requires_policy,
      \"docker_after_policy\": $docker_after_policy
    },
    \"tlog\": {
      \"socket_path\": \"/run/rd-tlog/log.sock\",
      \"store_mount\": \"/var/lib/rd-tlog\"
    },
    \"storage\": {
      \"driver\": \"$storage_driver\",
      \"backing_filesystem\": \"$storage_backing\",
      \"project_quota\": $storage_project_quota,
      \"dedicated_mount\": $storage_dedicated_mount,
      \"block_backed\": $storage_block_backed,
      \"separate_device\": $storage_separate_device,
      \"ftype_one\": $storage_ftype_one
    }
  },
  \"observed_compute\": {
    \"cpu_weight\": \"$cpu_weight\",
    \"io_weight\": \"$io_weight\",
    \"memory_high\": \"$memory_high\",
    \"memory_max\": \"$memory_max\",
    \"memory_swap_max\": \"$memory_swap_max\",
    \"tasks_max\": \"$tasks_max\",
    \"system_memory_min\": \"$system_memory_min\",
    \"kernel_pid_max\": \"$kernel_pid_max\"
  },
  \"slice_unconfigured\": $slice_unconfigured,
  \"network_policy_loaded\": $network_policy_loaded,
  \"containers\": [$containers]
}" >"$out.tmp" &&
  mv -f "$out.tmp" "$out"
