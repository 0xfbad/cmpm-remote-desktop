#!/bin/bash
set -uo pipefail

trap 'kill $(jobs -p) 2>/dev/null; exit 0' INT TERM

# self-delete so users (even with sudo) can't read the entrypoint after boot.
# bash holds the script via fd, so execution continues normally; restart
# policies will fail since the file is gone, which is fine for ephemeral
# per-session containers
rm -- "$0"

# machine-id required for dbus
if [ ! -f /etc/machine-id ]; then
  dbus-uuidgen >/etc/machine-id
fi
mkdir -p /var/lib/dbus
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# sanitize ctfd username for use as linux account name
# lowercase, replace non-alphanumeric with underscore, truncate to 32 chars
USERNAME=$(echo "${CTFD_USERNAME:-user}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | cut -c1-32)
# fallback if empty after sanitization
USERNAME="${USERNAME:-user}"

if ! id -u "$USERNAME" >/dev/null 2>&1; then
  useradd -m -s /bin/zsh "$USERNAME"
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers

  su - "$USERNAME" -c "mkdir -p ~/Downloads"

  chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
  chmod 755 "/home/$USERNAME"

  su - "$USERNAME" -c "tldr --update" || true
fi

# shared password for the linux user, ssh, and vnc. compute once so a missing
# VNC_PASSWORD env doesn't yield two different randoms for ssh and vnc
PASS="${VNC_PASSWORD:-$(openssl rand -base64 6)}"
echo "$USERNAME:$PASS" | chpasswd

DUMPCAP=$(command -v dumpcap 2>/dev/null)
if [ -n "$DUMPCAP" ]; then
  setcap cap_net_raw,cap_net_admin=ep "$DUMPCAP"
fi

if [ "${SHELL_LOGGING:-}" = "1" ]; then
  /usr/local/lib/.session-init/collector &
fi

ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
export DISPLAY=:0
export LIBGL_ALWAYS_SOFTWARE=1
RESOLUTION="${RESOLUTION:-1920x1080}"

mkdir -p "/home/$USERNAME/.vnc"
echo "$PASS" | tigervncpasswd -f >"/home/$USERNAME/.vnc/passwd"
chmod 600 "/home/$USERNAME/.vnc/passwd"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.vnc"

Xvnc $DISPLAY \
  -localhost 0 \
  -SecurityTypes VncAuth \
  -PasswordFile "/home/$USERNAME/.vnc/passwd" \
  -geometry "$RESOLUTION" \
  -depth 24 &

websockify --web /usr/share/novnc 6080 localhost:5900 &

# sshd for direct terminal access
mkdir -p /run/sshd
ssh-keygen -A
# guarded so the file doesn't grow on container restart
grep -q '^AllowUsers' /etc/ssh/sshd_config ||
  printf '\nPermitRootLogin no\nAllowUsers %s\n' "$USERNAME" >>/etc/ssh/sshd_config
/usr/sbin/sshd

# web terminal for browser-based shell access
ttyd -p 7682 -W -t fontSize=16 -t fontFamily=JetBrainsMonoNerdFont su -l "$USERNAME" &

# wait up to 30s for Xvnc and websockify; bail if either never comes up
for _ in $(seq 1 300); do
  [ -e /tmp/.X11-unix/X0 ] && break
  sleep 0.1
done
[ -e /tmp/.X11-unix/X0 ] || {
  echo "Xvnc failed to start" >&2
  exit 1
}
for _ in $(seq 1 300); do
  curl -fs localhost:6080 >/dev/null && break
  sleep 0.1
done
curl -fs localhost:6080 >/dev/null || {
  echo "websockify failed to start" >&2
  exit 1
}

# no screen blanking or dpms in a vnc container
xset s off
xset s noblank
xset -dpms

su - "$USERNAME" -c "
    export DISPLAY=$DISPLAY
    exec dbus-launch --exit-with-session xfce4-session
"
