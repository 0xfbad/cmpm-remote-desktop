#!/usr/bin/env bash
set -euo pipefail

image=${1:-ctfd-remote-desktop:latest}
prefix=rd-hardening-$$
first=$prefix-a
second=$prefix-b
lifetime=$prefix-lifetime
watchdog=$prefix-watchdog
invalid_empty=$prefix-invalid-empty
invalid_long=$prefix-invalid-long
invalid_control=$prefix-invalid-control
missing_chroot=$prefix-missing-chroot

cleanup() {
  docker rm -f "$first" "$second" "$lifetime" "$watchdog" \
    "$invalid_empty" "$invalid_long" "$invalid_control" >/dev/null 2>&1 || true
  docker rm -f "$missing_chroot" >/dev/null 2>&1 || true
}
trap cleanup EXIT

plugin_caps=(
  --cap-drop ALL
  --cap-add CHOWN
  --cap-add SETUID
  --cap-add SETGID
  --cap-add FOWNER
  --cap-add DAC_OVERRIDE
  --cap-add NET_RAW
  --cap-add NET_BIND_SERVICE
  --cap-add AUDIT_WRITE
  --cap-add SYS_CHROOT
)

run_session() {
  local name=$1 username=$2 max_lifetime=$3
  docker run --detach --name "$name" --init \
    "${plugin_caps[@]}" \
    --pids-limit 4096 \
    --shm-size 512m \
    --env "CTFD_USERNAME=$username" \
    --env VNC_PASSWORD=testpass \
    --env RESOLUTION=1024x768 \
    --env "MAX_LIFETIME=$max_lifetime" \
    "$image" >/dev/null
}

wait_ready() {
  local name=$1
  for ((attempt = 0; attempt < 480; attempt++)); do
    if docker exec "$name" test -f /run/remote-desktop/ready 2>/dev/null &&
      docker exec "$name" /usr/local/bin/remote-desktop-healthcheck 2>/dev/null; then
      return
    fi
    if [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) != true ]]; then
      docker logs "$name" >&2 || true
      echo "$name exited before readiness" >&2
      return 1
    fi
    sleep 0.25
  done
  docker logs "$name" >&2 || true
  echo "$name did not become ready" >&2
  return 1
}

wait_stopped() {
  local name=$1 attempts=${2:-100}
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == false ]]; then
      return
    fi
    sleep 0.1
  done
  return 1
}

assert_password_rejected() {
  local name=$1 password=$2 result
  docker run --detach --name "$name" --init \
    "${plugin_caps[@]}" \
    --env CTFD_USERNAME=invalid_password \
    --env "VNC_PASSWORD=$password" \
    "$image" >/dev/null
  wait_stopped "$name" 200 || {
    docker logs "$name" >&2 || true
    echo "invalid VNC password left a running container" >&2
    return 1
  }
  result=$(docker inspect -f '{{.State.ExitCode}}:{{.State.OOMKilled}}' "$name")
  [[ $result =~ ^[1-9][0-9]*:false$ ]] || {
    echo "invalid VNC password exited unexpectedly: $result" >&2
    return 1
  }
}

echo "checking immutable image identity and privilege invariants"
[[ $(docker image inspect --format '{{ index .Config.Labels "edu.ucsc.ctfd-remote-desktop.contract" }}' "$image") == 3 ]]
docker run --rm --entrypoint /bin/bash "$image" -c '
  set -euo pipefail
  test ! -s /etc/machine-id
  ! compgen -G "/etc/ssh/ssh_host_*_key*" >/dev/null
  getcap /usr/bin/dumpcap | grep -Fqx "/usr/bin/dumpcap cap_net_raw=ep"
  test ! -e /usr/local/lib/.session-init
  test "$(find /usr/share/fonts/truetype/jetbrains-mono-nerd -maxdepth 1 -type f -name "*.ttf" | wc -l)" -eq 4
'

# The rest of the contract label names -- ports, health behaviour, stop signal --
# was previously asserted only by reading the Dockerfile.
echo "checking the declared contract surface, not just the label"
# println per port so sort sees one field per line, then join without a
# trailing separator -- ExposedPorts map order is not stable.
[[ $(docker image inspect --format '{{ range $p, $_ := .Config.ExposedPorts }}{{ println $p }}{{ end }}' "$image" |
  grep . | sort | paste -sd,) == "22/tcp,5900/tcp,6080/tcp,7682/tcp" ]]
[[ $(docker image inspect --format '{{ .Config.StopSignal }}' "$image") == SIGTERM ]]
[[ $(docker image inspect --format '{{ .Config.Healthcheck.Retries }}' "$image") == 3 ]]
[[ $(docker image inspect --format '{{ .Config.Healthcheck.StartPeriod }}' "$image") == 3m0s ]]
[[ $(docker image inspect --format '{{ .Config.Healthcheck.Interval }}' "$image") == 30s ]]

# nmap ships from Kali with cap_net_admin in its file-permitted set, which the
# container bounding set masks -- the kernel then refuses to exec it at all.
# Assert both the capability and that it actually runs.
echo "checking nmap is executable under the container capability set"
docker run --rm --entrypoint /bin/bash "$image" -c '
  set -euo pipefail
  getcap /usr/lib/nmap/nmap | grep -Fqx "/usr/lib/nmap/nmap cap_net_bind_service,cap_net_raw=ep"
  nmap --version >/dev/null
'

# An xfce helper value must name a helper file, or exo-open silently pops the
# "Choose Preferred Application" chooser instead of opening the app.
echo "checking xfce helper ids resolve to installed helpers"
docker run --rm --entrypoint /bin/bash "$image" -c '
  set -euo pipefail
  while IFS="=" read -r key value; do
    [[ -n ${key:-} && ${key:0:1} != "#" ]] || continue
    test -f "/usr/share/xfce4/helpers/${value}.desktop" || {
      echo "helpers.rc ${key}=${value} names no installed helper" >&2
      exit 1
    }
  done < /etc/xdg/xfce4/helpers.rc
'

echo "checking strict VNC password validation"
assert_password_rejected "$invalid_empty" ""
assert_password_rejected "$invalid_long" ninechars
assert_password_rejected "$invalid_control" $'abc\nBAD'

echo "checking authenticated SSH startup capability contract"
docker run --detach --name "$missing_chroot" --init \
  --cap-drop ALL \
  --cap-add CHOWN \
  --cap-add SETUID \
  --cap-add SETGID \
  --cap-add FOWNER \
  --cap-add DAC_OVERRIDE \
  --cap-add NET_RAW \
  --cap-add NET_BIND_SERVICE \
  --cap-add AUDIT_WRITE \
  --env CTFD_USERNAME=missing_chroot \
  --env VNC_PASSWORD=testpass \
  "$image" >/dev/null
wait_stopped "$missing_chroot" 300 || {
  docker logs "$missing_chroot" >&2 || true
  echo "session without SYS_CHROOT survived authenticated SSH startup" >&2
  exit 1
}
[[ $(docker inspect -f '{{.State.ExitCode}}:{{.State.OOMKilled}}' "$missing_chroot") =~ ^[1-9][0-9]*:false$ ]]
docker logs "$missing_chroot" 2>&1 | grep -Fq 'sshd failed its authenticated startup probe'

echo "starting two sessions with the plugin capability profile"
run_session "$first" tcpdump 300
run_session "$second" adm 300
wait_ready "$first"
wait_ready "$second"

first_username=$(docker exec "$first" cat /var/lib/remote-desktop/resolved-username)
second_username=$(docker exec "$second" cat /var/lib/remote-desktop/resolved-username)
[[ $first_username == student_tcpdump ]]
[[ $second_username == student_adm ]]

first_machine_id=$(docker exec "$first" cat /etc/machine-id)
second_machine_id=$(docker exec "$second" cat /etc/machine-id)
first_host_key=$(docker exec "$first" sha256sum /etc/ssh/ssh_host_ed25519_key | awk '{print $1}')
second_host_key=$(docker exec "$second" sha256sum /etc/ssh/ssh_host_ed25519_key | awk '{print $1}')
[[ $first_machine_id != "$second_machine_id" ]]
[[ $first_host_key != "$second_host_key" ]]

first_deadline=$(docker exec "$first" cat /var/lib/remote-desktop/max-lifetime-deadline)
docker restart --timeout 5 "$first" >/dev/null
wait_ready "$first"
[[ $(docker exec "$first" cat /etc/machine-id) == "$first_machine_id" ]]
[[ $(docker exec "$first" sha256sum /etc/ssh/ssh_host_ed25519_key | awk '{print $1}') == "$first_host_key" ]]
[[ $(docker exec "$first" cat /var/lib/remote-desktop/max-lifetime-deadline) == "$first_deadline" ]]

echo "checking unprivileged packet capture without NET_ADMIN or SETFCAP"
docker exec --user "$first_username" "$first" \
  timeout 10 dumpcap -q -i any -c 1 -w /tmp/runtime-hardening.pcapng >/dev/null 2>&1 &
capture_exec_pid=$!
sleep 0.5
docker exec "$first" ping -c 1 127.0.0.1 >/dev/null
wait "$capture_exec_pid"
docker exec "$first" test -s /tmp/runtime-hardening.pcapng

echo "checking fail-fast supervision"
docker exec "$second" /bin/bash -c '
  kill -STOP "$(</run/remote-desktop/xvnc.pid)" \
             "$(</run/remote-desktop/sshd.pid)" \
             "$(</run/remote-desktop/xfce.pid)" \
             "$(</run/remote-desktop/lifetime.pid)" \
             "$(</run/remote-desktop/health-watchdog.pid)"
'
if docker exec "$second" /usr/local/bin/remote-desktop-healthcheck; then
  echo "health check accepted stopped essential processes" >&2
  exit 1
fi
docker exec "$second" /bin/bash -c '
  kill -CONT "$(</run/remote-desktop/xvnc.pid)" \
             "$(</run/remote-desktop/sshd.pid)" \
             "$(</run/remote-desktop/xfce.pid)" \
             "$(</run/remote-desktop/lifetime.pid)" \
             "$(</run/remote-desktop/health-watchdog.pid)"
'
docker exec "$second" /usr/local/bin/remote-desktop-healthcheck

echo "checking GUI process health coverage"
docker exec "$second" /bin/bash -c '
  username=$(</var/lib/remote-desktop/resolved-username)
  user_id=$(id -u -- "$username")
  panel_pid=$(pgrep -u "$user_id" -x xfce4-panel | head -n 1)
  test -n "$panel_pid"
  # The production capability profile intentionally omits CAP_KILL. Signal
  # the panel as its owning user so the test genuinely transitions it to T.
  runuser -u "$username" -- kill -STOP "$panel_pid"
  printf "%s\n" "$panel_pid" >/run/remote-desktop/test-panel.pid
'
if docker exec "$second" /usr/local/bin/remote-desktop-healthcheck; then
  echo "health check accepted a stopped XFCE panel" >&2
  exit 1
fi
docker exec "$second" /bin/bash -c '
  username=$(</var/lib/remote-desktop/resolved-username)
  runuser -u "$username" -- kill -CONT "$(</run/remote-desktop/test-panel.pid)"
'
docker exec "$second" /usr/local/bin/remote-desktop-healthcheck

echo "checking automatic remediation of a persistently hung service"
run_session "$watchdog" watchdog 300
wait_ready "$watchdog"
docker exec "$watchdog" /bin/bash -c 'kill -STOP "$(</run/remote-desktop/xvnc.pid)"'
wait_stopped "$watchdog" 700 || {
  docker logs "$watchdog" >&2 || true
  echo "health watchdog left a persistently hung session running" >&2
  exit 1
}
[[ $(docker inspect -f '{{.State.ExitCode}}:{{.State.OOMKilled}}' "$watchdog") == 0:false ]]

docker exec "$second" /bin/bash -c 'kill "$(</run/remote-desktop/websockify.pid)"'
wait_stopped "$second" 50 || {
  docker logs "$second" >&2 || true
  echo "container stayed running after websockify exited" >&2
  exit 1
}

echo "checking bounded graceful stop"
stop_started_ns=$(python3 -c 'import time; print(time.monotonic_ns())')
docker stop --timeout 5 "$first" >/dev/null
stop_finished_ns=$(python3 -c 'import time; print(time.monotonic_ns())')
stop_elapsed_ms=$(((stop_finished_ns - stop_started_ns) / 1000000))
((stop_elapsed_ms < 5000)) || {
  echo "graceful stop took ${stop_elapsed_ms}ms" >&2
  exit 1
}
[[ $(docker inspect -f '{{.State.ExitCode}}:{{.State.OOMKilled}}' "$first") == 0:false ]]

echo "checking cumulative MAX_LIFETIME enforcement across restart"
run_session "$lifetime" lifetime 40
wait_ready "$lifetime"
lifetime_deadline=$(docker exec "$lifetime" cat /var/lib/remote-desktop/max-lifetime-deadline)
sleep 4
docker restart --timeout 5 "$lifetime" >/dev/null
wait_ready "$lifetime"
[[ $(docker exec "$lifetime" cat /var/lib/remote-desktop/max-lifetime-deadline) == "$lifetime_deadline" ]]
(($(date +%s) < lifetime_deadline))
[[ $(docker inspect -f '{{.State.Running}}' "$lifetime") == true ]]

lifetime_wait_seconds=$((lifetime_deadline - $(date +%s) + 6))
lifetime_wait_attempts=$((lifetime_wait_seconds * 10))
wait_stopped "$lifetime" "$lifetime_wait_attempts" || {
  docker logs "$lifetime" >&2 || true
  echo "MAX_LIFETIME did not stop the container" >&2
  exit 1
}
lifetime_stopped_at=$(date +%s)
((lifetime_stopped_at >= lifetime_deadline))
((lifetime_stopped_at <= lifetime_deadline + 5))
[[ $(docker inspect -f '{{.State.ExitCode}}:{{.State.OOMKilled}}' "$lifetime") == 0:false ]]

echo "runtime hardening checks passed"
