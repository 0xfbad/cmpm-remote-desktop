#!/usr/bin/env bash
# rd-telemetry.sh - snapshot per-session cgroup telemetry for rd.slice.
# Installed to /usr/local/lib/rd-telemetry.sh, driven by rd-telemetry.timer.
# Composes JSON by hand (awk/sed only, no jq dependency for writing).
# The trap guarantees exit 0 so a partial read can never put the oneshot
# service into systemd failure backoff.
set -u
trap 'exit 0' EXIT

# Overridable for unprivileged testing.
TELEMETRY_DIR="${RD_TELEMETRY_DIR:-/var/lib/rd-telemetry}"
SLICE_CGROUP="${RD_SLICE_CGROUP:-/sys/fs/cgroup/rd.slice}"

# slice_unconfigured is decided from systemd properties, NOT from cgroup
# directory existence: /sys/fs/cgroup/rd.slice is absent whenever the slice
# is merely inactive (zero sessions), and that must NOT read as
# "unconfigured". An unprovisioned host shows MemoryMax=infinity on the
# implicitly-created slice; a missing unit shows empty output.
mem_max_prop="$(systemctl show rd.slice -p MemoryMax --value 2>/dev/null)" || mem_max_prop=""
if [ -z "$mem_max_prop" ] || [ "$mem_max_prop" = "infinity" ]; then
    slice_unconfigured=true
else
    slice_unconfigured=false
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

    obj="{\"id\": \"$cid\""
    obj="$obj, \"cpu_pressure\": $cpu_p"
    obj="$obj, \"io_pressure\": $io_p"
    obj="$obj, \"memory_pressure\": $mem_p"
    obj="$obj, \"memory_events\": $mem_ev"
    obj="$obj, \"pids_events\": $pids_ev"
    obj="$obj, \"io_stat\": \"$io_stat\""
    obj="$obj, \"memory_current\": $mem_cur"
    obj="$obj, \"memory_max\": \"$mem_max\"}"

    containers="$containers$sep$obj"
    sep=", "
done

mkdir -p "$TELEMETRY_DIR" 2>/dev/null || exit 0
out="$TELEMETRY_DIR/current.json"
# tmp-then-rename: atomic on the same filesystem, readers never see a
# partial file. Single fixed-size file, so the spool is bounded.
printf '{"ts": %s, "slice_unconfigured": %s, "containers": [%s]}\n' \
    "$(date +%s)" "$slice_unconfigured" "$containers" > "$out.tmp" &&
    mv -f "$out.tmp" "$out"
