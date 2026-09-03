#!/bin/bash
set -euo pipefail

runtime_dir=/run/remote-desktop
state_dir=/var/lib/remote-desktop

# OpenSSH invokes SSH_ASKPASS as a separate process. Reusing this executable
# avoids staging the session password in another script; the root-only
# credentials file remains the sole source of truth.
if [[ ${REMOTE_DESKTOP_HEALTH_ASKPASS:-0} == 1 ]]; then
  credentials=$(<"$runtime_dir/ttyd-credentials")
  printf '%s\n' "${credentials#*:}"
  exit 0
fi

deep_ssh_auth_probe() {
  local username control_socket status=0
  username=$(<"$state_dir/resolved-username")
  [[ $username =~ ^[a-z_][a-z0-9_]{0,31}$ ]]
  control_socket="$runtime_dir/ssh-health.$$.sock"
  REMOTE_DESKTOP_HEALTH_ASKPASS=1 \
    SSH_ASKPASS="$0" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    timeout 5 ssh -F /dev/null -fN \
    -o BatchMode=no \
    -o ConnectTimeout=2 \
    -o ConnectionAttempts=1 \
    -o ControlMaster=yes \
    -o "ControlPath=$control_socket" \
    -o GlobalKnownHostsFile=/dev/null \
    -o KbdInteractiveAuthentication=no \
    -o LogLevel=ERROR \
    -o NumberOfPasswordPrompts=1 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$username@127.0.0.1" || status=$?
  timeout 1 ssh -F /dev/null -S "$control_socket" -O exit 127.0.0.1 >/dev/null 2>&1 || true
  rm -f -- "$control_socket"
  return "$status"
}

# Startup calls this mode exactly once before publishing noVNC. Periodic
# health uses a lightweight banner probe below to avoid repeated key exchange
# and authentication load across hundreds of sessions.
if [[ ${REMOTE_DESKTOP_DEEP_SSH_CHECK:-0} == 1 ]]; then
  deep_ssh_auth_probe
  exit 0
fi

check_live_pid() {
  local pid=$1 state
  [[ $pid =~ ^[1-9][0-9]*$ ]]
  # The plugin intentionally drops CAP_KILL. Container root therefore gets
  # EPERM from kill(2) when probing the unprivileged XFCE processes even though
  # they are alive. procfs existence/state is the capability-independent
  # liveness source and also lets us reject stopped or uninterruptible tasks.
  [[ -r /proc/$pid/status ]]
  state=$(awk '$1 == "State:" {print $2}' "/proc/$pid/status") || return 1
  [[ -n $state ]] || return 1
  case "$state" in
  D | T | t | Z | X | x) return 1 ;;
  esac
}

check_pid() {
  local service=$1 pid
  IFS= read -r pid <"$runtime_dir/$service.pid"
  check_live_pid "$pid"
}

test -f "$runtime_dir/ready"
test -S /tmp/.X11-unix/X0
check_pid xvnc
check_pid websockify
check_pid xfce
if [[ -n ${MAX_LIFETIME:-} ]]; then
  check_pid lifetime
fi
if [[ -f $runtime_dir/health-watchdog.pid ]]; then
  check_pid health-watchdog
fi
timeout 2 xdpyinfo -display :0 >/dev/null 2>&1

curl --noproxy '*' --fail --silent --show-error --max-time 2 \
  http://127.0.0.1:6080/ >/dev/null

if [[ ${ENABLE_SSH:-1} != 0 ]]; then
  check_pid sshd
fi

if [[ ${ENABLE_TTYD:-1} != 0 ]]; then
  check_pid ttyd
  ttyd_credentials=$(<"$runtime_dir/ttyd-credentials")
  [[ $ttyd_credentials == *:* ]]
  curl --noproxy '*' --fail --silent --show-error --max-time 2 \
    --user "$ttyd_credentials" \
    http://127.0.0.1:7682/ >/dev/null
fi

username=$(<"$state_dir/resolved-username")
[[ $username =~ ^[a-z_][a-z0-9_]{0,31}$ ]]
user_id=$(id -u -- "$username")

if [[ ${ENABLE_SSH:-1} != 0 ]]; then
  # shellcheck disable=SC2016 # the child Bash deliberately expands its own banner variable
  timeout 3 /bin/bash -c '
    exec 3<>/dev/tcp/127.0.0.1/22
    IFS= read -r -t 2 banner <&3
    [[ $banner == SSH-2.0-* || $banner == SSH-1.99-* ]]
  '
fi

check_user_process() {
  local process=$1 pid
  while IFS= read -r pid; do
    if check_live_pid "$pid"; then
      return 0
    fi
  done < <(pgrep -u "$user_id" -x "$process" || true)
  return 1
}

check_user_process xfce4-session
check_user_process xfwm4
check_user_process xfce4-panel
