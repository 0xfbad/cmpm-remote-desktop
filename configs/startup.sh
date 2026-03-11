#!/bin/bash

# machine-id required for dbus
if [ ! -f /etc/machine-id ]; then
    dbus-uuidgen > /etc/machine-id
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
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

    su - "$USERNAME" -c "mkdir -p ~/Downloads"

    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
    chmod 755 "/home/$USERNAME"

    su - "$USERNAME" -c "tldr --update" || true
fi

DUMPCAP=$(command -v dumpcap 2>/dev/null)
if [ -n "$DUMPCAP" ]; then
    setcap cap_net_raw,cap_net_admin=ep "$DUMPCAP"
fi

ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
export DISPLAY=:0
export LIBGL_ALWAYS_SOFTWARE=1
RESOLUTION="${RESOLUTION:-1920x1080}"

VNC_PASS="${VNC_PASSWORD:-$(openssl rand -base64 6)}"

mkdir -p "/home/$USERNAME/.vnc"
echo "$VNC_PASS" | vncpasswd -f > "/home/$USERNAME/.vnc/passwd"
chmod 600 "/home/$USERNAME/.vnc/passwd"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.vnc"

Xvnc $DISPLAY \
    -localhost 0 \
    -SecurityTypes VncAuth \
    -PasswordFile "/home/$USERNAME/.vnc/passwd" \
    -geometry "$RESOLUTION" \
    -depth 24 &

websockify --web /usr/share/novnc 6080 localhost:5900 &

until [ -e /tmp/.X11-unix/X0 ]; do sleep 0.1; done
until curl -fs localhost:6080 >/dev/null; do sleep 0.1; done

su - "$USERNAME" -c "
    export DISPLAY=$DISPLAY
    exec dbus-launch --exit-with-session xfce4-session
"
