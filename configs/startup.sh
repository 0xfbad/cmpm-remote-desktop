#!/bin/bash
set -Eeuo pipefail

state_dir=/var/lib/remote-desktop
username_file=$state_dir/resolved-username
lifetime_file=$state_dir/max-lifetime-deadline
runtime_dir=/run/remote-desktop
install -d -o root -g root -m 0755 "$runtime_dir"
exec 9>"$runtime_dir/startup.lock"
chmod 0600 "$runtime_dir/startup.lock"
if flock --exclusive --nonblock --conflict-exit-code 75 9; then
  :
else
  lock_status=$?
  if ((lock_status == 75)); then
    exit 0
  fi
  echo "cannot acquire startup lock" >&2
  exit "$lock_status"
fi

startup_pid=$$
declare -a managed_pids=()
shutting_down=0

record_pid() {
  local service=$1 pid=$2
  managed_pids+=("$pid")
  printf '%s\n' "$pid" >"$runtime_dir/$service.pid"
}

# shellcheck disable=SC2329
shutdown() {
  local exit_code=${1:-0} pid alive
  if ((shutting_down)); then
    return
  fi
  shutting_down=1
  trap - EXIT INT TERM
  rm -f -- "$runtime_dir/ready"

  if ((${#managed_pids[@]})); then
    kill -TERM "${managed_pids[@]}" 2>/dev/null || true
    for ((attempt = 0; attempt < 30; attempt++)); do
      alive=0
      for pid in "${managed_pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
          alive=1
        fi
      done
      ((alive == 0)) && break
      sleep 0.1
    done
    for pid in "${managed_pids[@]}"; do
      kill -KILL "$pid" 2>/dev/null || true # init reaps remaining children if kernel sleep prevents prompt exit
    done
  fi

  rm -f -- "$runtime_dir"/*.pid
  exit "$exit_code"
}

trap 'exit 0' INT TERM
trap 'shutdown "$?"' EXIT

rm -f -- "$runtime_dir/ready" "$runtime_dir"/*.pid

machine_id=
if [[ -f /etc/machine-id && ! -L /etc/machine-id ]]; then
  machine_id=$(</etc/machine-id)
fi
if [[ ! $machine_id =~ ^[0-9a-f]{32}$ ]]; then
  machine_id_tmp=/etc/machine-id.tmp.$$
  rm -f -- /etc/machine-id "$machine_id_tmp"
  (umask 022 && dbus-uuidgen >"$machine_id_tmp") # each writable layer needs its own identity and restarts must retain it
  chmod 0444 "$machine_id_tmp"
  mv -T "$machine_id_tmp" /etc/machine-id
fi
install -d -o root -g root -m 0755 /var/lib/dbus
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

if [[ -L $state_dir ]] || [[ -e $state_dir && ! -d $state_dir ]]; then
  echo "invalid student account state directory" >&2
  exit 1
fi
install -d -o root -g root -m 0700 "$state_dir"

if [[ -L $username_file ]] || [[ -e $username_file && ! -f $username_file ]]; then
  echo "invalid persisted student account file" >&2
  exit 1
fi
if [[ -f $username_file ]]; then
  if [[ $(stat -c '%u:%g:%a' -- "$username_file" 2>/dev/null) != 0:0:600 ]]; then
    echo "persisted student account file has unsafe ownership or mode" >&2
    exit 1
  fi
  USERNAME=$(<"$username_file")
  if [[ ! $USERNAME =~ ^[a-z_][a-z0-9_]{0,31}$ ]]; then
    echo "invalid persisted student account: $USERNAME" >&2
    exit 1
  fi
else
  USERNAME=$(
    printf '%s' "${CTFD_USERNAME:-user}" |
      LC_ALL=C tr '[:upper:]' '[:lower:]' |
      LC_ALL=C tr -c 'a-z0-9_' '_'
  )
  case "$USERNAME" in
  *[a-z0-9]*) ;;
  *) USERNAME=user ;;
  esac
  case "$USERNAME" in
  [0-9]*) USERNAME="student_$USERNAME" ;; # useradd requires a nonnumeric leading character
  esac
  USERNAME=${USERNAME:0:32} # linux account names allow at most 32 characters

  if id -u -- "$USERNAME" >/dev/null 2>&1 || getent group -- "$USERNAME" >/dev/null 2>&1; then # base accounts may have a system uid or locked shell
    username_stem="student_$USERNAME"
    username_stem=${username_stem:0:32}
    USERNAME=$username_stem
    username_suffix=2
    while id -u -- "$USERNAME" >/dev/null 2>&1 || getent group -- "$USERNAME" >/dev/null 2>&1; do
      suffix="_$username_suffix"
      USERNAME="${username_stem:0:$((32 - ${#suffix}))}$suffix"
      username_suffix=$((username_suffix + 1))
    done
  fi

  username_file_tmp=$state_dir/resolved-username.tmp.$$
  (umask 077 && printf '%s\n' "$USERNAME" >"$username_file_tmp")
  chown root:root "$username_file_tmp"
  mv -T "$username_file_tmp" "$username_file" # persist before useradd so interrupted startup reuses the same account
fi

lifetime_remaining=
if [[ -n ${MAX_LIFETIME:-} ]]; then
  if [[ ! $MAX_LIFETIME =~ ^[1-9][0-9]*$ || ${#MAX_LIFETIME} -gt 10 ]]; then
    echo "MAX_LIFETIME must be a positive integer number of seconds" >&2
    exit 1
  fi
  lifetime_seconds=$((10#$MAX_LIFETIME))
  if ((lifetime_seconds > 2147483647)); then
    echo "MAX_LIFETIME is too large" >&2
    exit 1
  fi

  if [[ -L $lifetime_file ]] || [[ -e $lifetime_file && ! -f $lifetime_file ]]; then
    echo "invalid persisted maximum-lifetime file" >&2
    exit 1
  fi
  if [[ -f $lifetime_file ]]; then
    if [[ $(stat -c '%u:%g:%a' -- "$lifetime_file" 2>/dev/null) != 0:0:600 ]]; then
      echo "persisted maximum-lifetime file has unsafe ownership or mode" >&2
      exit 1
    fi
    lifetime_deadline=$(<"$lifetime_file")
    if [[ ! $lifetime_deadline =~ ^[1-9][0-9]*$ || ${#lifetime_deadline} -gt 10 ]]; then
      echo "invalid persisted maximum-lifetime deadline" >&2
      exit 1
    fi
    lifetime_deadline=$((10#$lifetime_deadline))
  else
    lifetime_deadline=$(($(date +%s) + lifetime_seconds)) # restarts must not grant a new lifetime
    lifetime_file_tmp=$state_dir/max-lifetime-deadline.tmp.$$
    (umask 077 && printf '%s\n' "$lifetime_deadline" >"$lifetime_file_tmp")
    chown root:root "$lifetime_file_tmp"
    mv -T "$lifetime_file_tmp" "$lifetime_file"
  fi

  lifetime_remaining=$((lifetime_deadline - $(date +%s)))
  if ((lifetime_remaining <= 0)); then
    echo "maximum session lifetime has elapsed"
    exit 0
  fi

  lifetime_warn() {
    local minutes=$1 uid
    uid=$(id -u -- "$USERNAME" 2>/dev/null) || return 0 # the watchdog can start before useradd
    [[ -n $uid ]] || return 0
    su -l -s /bin/bash "$USERNAME" -c \
      "DISPLAY=:0 notify-send -u critical 'Session ends in ${minutes} minutes'" \
      >/dev/null 2>&1 || true
  }

  lifetime_watchdog() {
    local current_deadline now remaining sleep_for threshold
    local -A warned_for=()
    trap - EXIT INT TERM
    while true; do
      if [[ $(stat -c '%u:%g:%a' -- "$lifetime_file" 2>/dev/null) != 0:0:600 ]]; then
        echo "maximum-lifetime deadline became unsafe" >&2
        kill -TERM "$startup_pid" 2>/dev/null || true
        return
      fi
      current_deadline=$(<"$lifetime_file") # evidence holds replace this deadline while the container is paused
      if [[ ! $current_deadline =~ ^[1-9][0-9]*$ || ${#current_deadline} -gt 10 ]]; then
        echo "maximum-lifetime deadline became invalid" >&2
        kill -TERM "$startup_pid" 2>/dev/null || true
        return
      fi
      current_deadline=$((10#$current_deadline))
      now=$(date +%s)
      remaining=$((current_deadline - now))
      for threshold in 300 60; do
        if ((remaining <= threshold)) && [[ ${warned_for[$threshold]:-} != "$current_deadline" ]]; then
          warned_for[$threshold]=$current_deadline
          lifetime_warn $((threshold / 60))
        fi
      done
      if ((remaining <= 0)); then
        kill -TERM "$startup_pid" 2>/dev/null || true
        return
      fi
      sleep_for=$remaining
      ((sleep_for > 30)) && sleep_for=30 # recalculate after host suspend or clock changes
      sleep "$sleep_for"
    done
  }
  lifetime_watchdog 9>&- &
  record_pid lifetime "$!"
fi

# shellcheck source=configs/setup-recording.sh
. /usr/local/lib/setup-recording.sh

if ! id -u -- "$USERNAME" >/dev/null 2>&1; then
  useradd -m -s "$USER_SHELL" "$USERNAME"
  install -d -o "$USERNAME" -g "$USERNAME" -m 0755 "/home/$USERNAME/Downloads"
  chmod 0755 "/home/$USERNAME"
else
  usermod -s "$USER_SHELL" "$USERNAME"
fi

if [[ ${ENABLE_WORKSPACE_CONTEXT:-0} == 1 ]]; then
  install -d -o "$USERNAME" -g "$USERNAME" -m 0700 /var/lib/rd-workspace # student writable ai context must stay outside root only account state
fi

/usr/local/bin/remote-desktop-command-collector 9>&- &
phase_deadline=$((SECONDS + 3))
while [[ ! -S /run/.session-init.sock ]] && ((SECONDS < phase_deadline)); do
  sleep 0.1
done
[[ -S /run/.session-init.sock ]] || echo "command recording is unavailable" >&2

sudoers_tmp=/etc/sudoers.d/90-remote-desktop-user.tmp.$$
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USERNAME" >"$sudoers_tmp"
chmod 0440 "$sudoers_tmp"
visudo -cf "$sudoers_tmp" >/dev/null
mv -T "$sudoers_tmp" /etc/sudoers.d/90-remote-desktop-user

if [[ -v VNC_PASSWORD ]]; then
  PASS=$VNC_PASSWORD # an explicit empty value must not create an undiscoverable random password
else
  PASS=$(openssl rand -base64 6)
fi
is_visible_ascii_password() {
  local LC_ALL=C
  [[ $1 =~ ^[!-~]{1,8}$ ]]
}
if [[ $PASS == *:* ]] || ! is_visible_ascii_password "$PASS"; then
  echo "VNC_PASSWORD must be 1-8 visible ASCII characters and contain no colon" >&2
  exit 1
fi
printf '%s:%s\n' "$USERNAME" "$PASS" | chpasswd
ttyd_credentials_file=$runtime_dir/ttyd-credentials
(umask 077 && printf '%s:%s\n' "$USERNAME" "$PASS" >"$ttyd_credentials_file")
user_id=$(id -u -- "$USERNAME")
install -d -o "$USERNAME" -g "$USERNAME" -m 0700 "/run/user/$user_id"

ln -sfn /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
export DISPLAY=:0
export LIBGL_ALWAYS_SOFTWARE=1
RESOLUTION=${RESOLUTION:-1920x1080}
if [[ ! $RESOLUTION =~ ^([0-9]{3,4})x([0-9]{3,4})$ ]]; then
  echo "RESOLUTION must be WIDTHxHEIGHT between 320x200 and 7680x4320" >&2
  exit 1
fi
resolution_width=$((10#${BASH_REMATCH[1]}))
resolution_height=$((10#${BASH_REMATCH[2]}))
if ((resolution_width < 320 || resolution_width > 7680 || resolution_height < 200 || resolution_height > 4320)); then
  echo "RESOLUTION must be WIDTHxHEIGHT between 320x200 and 7680x4320" >&2
  exit 1
fi

install -d -o "$USERNAME" -g "$USERNAME" -m 0700 "/home/$USERNAME/.vnc"
printf '%s\n' "$PASS" | tigervncpasswd -f >"/home/$USERNAME/.vnc/passwd"
chmod 0600 "/home/$USERNAME/.vnc/passwd"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.vnc/passwd"

rm -f -- /tmp/.X0-lock /tmp/.X11-unix/X0 # restarts retain old locks without the x process
install -d -m 1777 /tmp/.X11-unix

Xvnc "$DISPLAY" \
  -localhost 0 \
  -SecurityTypes VncAuth \
  -PasswordFile "/home/$USERNAME/.vnc/passwd" \
  -geometry "$RESOLUTION" \
  -depth 24 9>&- &
xvnc_pid=$!
record_pid xvnc "$xvnc_pid"

if [[ ${ENABLE_SSH:-1} != 0 ]]; then
  install -d -m 0755 /run/sshd
  ssh-keygen -A
  sshd_config_tmp=/etc/ssh/sshd_config.d/90-remote-desktop.conf.tmp.$$
  printf 'PermitRootLogin no\nAllowUsers %s\n' "$USERNAME" >"$sshd_config_tmp"
  chmod 0644 "$sshd_config_tmp"
  mv -T "$sshd_config_tmp" /etc/ssh/sshd_config.d/90-remote-desktop.conf
  /usr/sbin/sshd -t
  /usr/sbin/sshd -D -e 9>&- &
  record_pid sshd "$!"
fi

if [[ ${ENABLE_TTYD:-1} != 0 ]]; then
  ttyd -p 7682 -W -O -m 16 -c "$USERNAME:$PASS" -t fontSize=16 \
    -t 'fontFamily=JetBrainsMono Nerd Font Mono, Menlo, Consolas, monospace' \
    su -l "$USERNAME" 9>&- &
  record_pid ttyd "$!"
fi

phase_deadline=$((SECONDS + 30))
while ((SECONDS < phase_deadline)); do
  if [[ -S /tmp/.X11-unix/X0 ]]; then
    break
  fi
  kill -0 "$xvnc_pid" 2>/dev/null || {
    echo "Xvnc exited during startup" >&2
    exit 1
  }
  sleep 0.1
done
[[ -S /tmp/.X11-unix/X0 ]] || {
  echo "Xvnc failed to create display :0" >&2
  exit 1
}

timeout 5 xdpyinfo -display "$DISPLAY" >/dev/null
timeout 5 /bin/bash -c 'xset s off && xset s noblank && { xset -dpms 2>/dev/null || true; }' # tigervnc has no dpms extension

if [[ -n ${CTFD_URL:-} ]]; then
  for policy in /usr/lib/firefox-esr/distribution/policies.json /usr/share/firefox-esr/distribution/policies.json; do
    if [[ -f $policy ]]; then
      jq --arg url "${CTFD_URL%/}/challenges" \
        '.policies.Homepage.URL = $url | (.policies.Bookmarks[] | select(.Title == "Challenges")).URL = $url' \
        "$policy" >"$policy.tmp"
      mv -T "$policy.tmp" "$policy"
    fi
  done
fi

if [[ -n ${CTFD_COOKIE_VALUE:-} && -n ${CTFD_URL:-} ]]; then
  jq -n \
    --arg url "$CTFD_URL" \
    --arg name "${CTFD_COOKIE_NAME:-session}" \
    --arg value "$CTFD_COOKIE_VALUE" \
    '{url: $url, name: $name, value: $value}' \
    >/tmp/ctfd_auth.json
  chown "$USERNAME:$USERNAME" /tmp/ctfd_auth.json
  chmod 0600 /tmp/ctfd_auth.json
fi

su -l -s /bin/bash "$USERNAME" -c "
  export SHELL=$USER_SHELL # the bootstrap shell override must not reach gui terminals
  export DISPLAY=$DISPLAY
  export XDG_RUNTIME_DIR=/run/user/$user_id
  exec dbus-launch --exit-with-session xfce4-session
" 9>&- &
xfce_supervisor_pid=$!
record_pid xfce "$xfce_supervisor_pid"

phase_deadline=$((SECONDS + 30))
while ((SECONDS < phase_deadline)); do
  if pgrep -u "$user_id" -x xfce4-session >/dev/null; then
    break
  fi
  kill -0 "$xfce_supervisor_pid" 2>/dev/null || {
    echo "XFCE session exited during startup" >&2
    exit 1
  }
  sleep 0.1
done
pgrep -u "$user_id" -x xfce4-session >/dev/null || {
  echo "XFCE session failed to start" >&2
  exit 1
}

for gui_process in xfwm4 xfce4-panel; do # the session process can exist before a usable desktop
  phase_deadline=$((SECONDS + 30))
  while ((SECONDS < phase_deadline)); do
    if pgrep -u "$user_id" -x "$gui_process" >/dev/null; then
      break
    fi
    kill -0 "$xfce_supervisor_pid" 2>/dev/null || {
      echo "XFCE session exited while waiting for $gui_process" >&2
      exit 1
    }
    sleep 0.1
  done
  pgrep -u "$user_id" -x "$gui_process" >/dev/null || {
    echo "$gui_process failed to start" >&2
    exit 1
  }
done

if [[ ${ENABLE_SSH:-1} != 0 ]]; then
  if ! REMOTE_DESKTOP_DEEP_SSH_CHECK=1 \
    timeout 10 /usr/local/bin/remote-desktop-healthcheck; then # a banner alone does not prove ssh privilege separation works
    echo "sshd failed its authenticated startup probe" >&2
    exit 1
  fi
fi

touch "$runtime_dir/ready" # publish the marker before http can satisfy the plugin readiness probe
chmod 0644 "$runtime_dir/ready"
websockify --web /usr/share/novnc 6080 localhost:5900 9>&- &
websockify_pid=$!
record_pid websockify "$websockify_pid"

phase_deadline=$((SECONDS + 30))
while ((SECONDS < phase_deadline)); do
  if curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:6080/ >/dev/null; then
    break
  fi
  kill -0 "$websockify_pid" 2>/dev/null || {
    echo "websockify exited during startup" >&2
    exit 1
  }
  sleep 0.1
done
curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:6080/ >/dev/null || {
  echo "websockify failed to serve noVNC" >&2
  exit 1
}

for pid in "${managed_pids[@]}"; do
  kill -0 "$pid" 2>/dev/null || {
    echo "a managed service exited before readiness" >&2
    exit 1
  }
done

health_watchdog() {
  local failures=0
  trap - EXIT INT TERM
  while true; do
    sleep 15
    if timeout 15 /usr/local/bin/remote-desktop-healthcheck >/dev/null 2>&1; then
      failures=0
      continue
    fi
    failures=$((failures + 1))
    echo "runtime health probe failed ($failures/3)" >&2
    if ((failures >= 3)); then
      echo "runtime remained unhealthy; ending the session" >&2
      kill -TERM "$startup_pid" 2>/dev/null || true
      return
    fi
  done
}
health_watchdog 9>&- &
record_pid health-watchdog "$!"

echo "remote desktop ready for $USERNAME at $RESOLUTION"

if wait -n -p exited_pid "${managed_pids[@]}"; then
  child_status=0
else
  child_status=$?
fi
echo "managed process ${exited_pid:-unknown} exited with status $child_status; shutting down" >&2
exit "$child_status"
