#!/usr/bin/env bash
# rd-io-tripwire: pause rd-session-* containers writing above RATE_TRIP_BYTES
# for CONSEC consecutive samples. Pause ONLY — never stop/kill/rm: auto_remove
# would delete the writable layer, i.e. the evidence.
set -u
# Non-zero exit must never trigger systemd backoff.
trap 'exit 0' EXIT

RATE_TRIP_BYTES="${RATE_TRIP_BYTES:-209715200}"
CONSEC="${CONSEC:-3}"
STATE_DIR="${STATE_DIR:-/run/rd-io-tripwire}"
LOG_DIR="${LOG_DIR:-/var/log/rd-tripwire}"
NAME_PREFIX="${NAME_PREFIX:-rd-session-}"
PAUSE_ENABLE="${PAUSE_ENABLE:-1}"
IHARD_ENABLE="${IHARD_ENABLE:-1}"
IHARD="${IHARD:-2000000}"
DATA_ROOT="${DATA_ROOT:-/var/lib/docker}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# rd.slice first (feature 3's slice), then system.slice, then any slice.
find_iostat() {
  local id="$1" p
  for p in "/sys/fs/cgroup/rd.slice/docker-$id.scope/io.stat" \
    "/sys/fs/cgroup/system.slice/docker-$id.scope/io.stat"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  for p in /sys/fs/cgroup/*/docker-"$id".scope/io.stat; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# One-time XFS inode hard limit on the container's overlay upperdir project.
# Silent no-op on non-XFS data-roots (ext4 dev box).
ihard_pass() {
  local id="$1" upperdir projid
  [ "$IHARD_ENABLE" = "1" ] || return 0
  [ -f "$STATE_DIR/$id.ihard" ] && return 0
  [ "$(stat -f -c %T "$DATA_ROOT" 2>/dev/null)" = "xfs" ] || return 0
  upperdir=$(docker inspect -f '{{.GraphDriver.Data.UpperDir}}' "$id" 2>/dev/null) || return 0
  [ -n "$upperdir" ] && [ -d "$upperdir" ] || return 0
  projid=$(lsattr -pd "$upperdir" 2>/dev/null | awk '{print $1; exit}')
  case "$projid" in '' | *[!0-9]*) return 0 ;; esac
  if xfs_quota -x -c "limit -p ihard=$IHARD $projid" "$DATA_ROOT" 2>/dev/null; then
    : >"$STATE_DIR/$id.ihard"
    logger -t rd-io-tripwire "ihard=$IHARD set for projid=$projid container=$id"
  fi
}

now=$(date +%s)
seen=" "

while read -r id name; do
  [ -n "$id" ] || continue
  seen="$seen$id "

  # docker ps lists paused containers too; skip ones already paused.
  if [ "$(docker inspect -f '{{.State.Paused}}' "$id" 2>/dev/null)" = "true" ]; then
    continue
  fi

  ihard_pass "$id"

  iostat_path=$(find_iostat "$id") || continue

  # io.stat is EMPTY until the container performs IO: sum must default to 0
  # on an empty or missing file — no strike, no error.
  wbytes=$(awk '{for (i = 1; i <= NF; i++)
                       if ($i ~ /^wbytes=/) { split($i, a, "="); s += a[2] }}
                  END { printf "%d", s + 0 }' "$iostat_path" 2>/dev/null)
  case "$wbytes" in '' | *[!0-9]*) wbytes=0 ;; esac

  state_file="$STATE_DIR/$id"
  prev_wbytes="" prev_ts="" strikes=0
  if [ -f "$state_file" ]; then
    read -r prev_wbytes prev_ts strikes <"$state_file" || true
  fi
  case "$strikes" in '' | *[!0-9]*) strikes=0 ;; esac
  case "$prev_wbytes" in *[!0-9]*) prev_wbytes="" ;; esac
  case "$prev_ts" in *[!0-9]*) prev_ts="" ;; esac

  if [ -n "$prev_wbytes" ] && [ -n "$prev_ts" ] && [ "$now" -gt "$prev_ts" ]; then
    rate=$(((wbytes - prev_wbytes) / (now - prev_ts)))
    [ "$rate" -lt 0 ] && rate=0
    if [ "$rate" -gt "$RATE_TRIP_BYTES" ]; then
      strikes=$((strikes + 1))
    else
      strikes=0
    fi
    if [ "$strikes" -ge "$CONSEC" ]; then
      if [ "$PAUSE_ENABLE" = "1" ]; then
        if docker pause "$id" >/dev/null 2>&1; then
          ts=$(date +%s)
          printf '{"container_id":"%s","name":"%s","rate_bps":%d,"total_wbytes":%d,"ts":%d,"action":"pause"}\n' \
            "$id" "$name" "$rate" "$wbytes" "$ts" >"$LOG_DIR/$name.$ts.json"
          logger -t rd-io-tripwire "paused $name ($id): rate=${rate}B/s total_wbytes=$wbytes"
        fi
      else
        logger -t rd-io-tripwire "detect-only: would pause $name ($id): rate=${rate}B/s strikes=$strikes"
      fi
    fi
  fi

  printf '%s %s %s\n' "$wbytes" "$now" "$strikes" >"$state_file"
done < <(docker ps --no-trunc --filter "name=$NAME_PREFIX" --format '{{.ID}} {{.Names}}')

# Prune state (and ihard markers) for vanished containers.
for f in "$STATE_DIR"/*; do
  [ -e "$f" ] || continue
  base=${f##*/}
  cid=${base%.ihard}
  case "$seen" in
  *" $cid "*) ;;
  *) rm -f "$f" ;;
  esac
done

exit 0
