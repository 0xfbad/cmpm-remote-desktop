#!/bin/bash
set -uo pipefail

trap 'kill $(jobs -p) 2>/dev/null; exit 0' INT TERM

# self-delete so users (even with sudo) can't read the entrypoint after boot
rm -- "$0"

# machine-id required for dbus
if [ ! -f /etc/machine-id ]; then
  dbus-uuidgen >/etc/machine-id
fi
mkdir -p /var/lib/dbus
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# sanitize ctfd username
USERNAME=$(echo "${CTFD_USERNAME:-user}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | cut -c1-32)
USERNAME="${USERNAME:-user}"

if ! id -u "$USERNAME" >/dev/null 2>&1; then
  useradd -m -s /bin/zsh -G ssl-cert "$USERNAME"
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers

  su - "$USERNAME" -c "mkdir -p ~/Downloads"

  chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
  chmod 755 "/home/$USERNAME"

  su - "$USERNAME" -c "tldr --update" || true
fi

# shared password for the linux user, ssh, and kasmvnc web auth
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

# kasmvnc password (writes ~/.kasmpasswd in basic-auth format)
su - "$USERNAME" -c "printf '%s\n%s\n' '$PASS' '$PASS' | kasmvncpasswd -u '$USERNAME' -w" >/dev/null

# write xstartup directly so kasmvncserver doesn't prompt for a DE on first run
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.vnc"
cat >"/home/$USERNAME/.vnc/xstartup" <<'XSTARTUP'
#!/bin/sh
set -x
exec dbus-launch --exit-with-session xfce4-session
XSTARTUP
chmod 755 "/home/$USERNAME/.vnc/xstartup"
touch "/home/$USERNAME/.vnc/.de-was-selected"
# preempt kasmvncserver's auto-generated user config (which would shadow /etc/kasmvnc)
cp /etc/kasmvnc/kasmvnc.yaml "/home/$USERNAME/.vnc/kasmvnc.yaml"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.vnc"

# sshd for direct terminal access
mkdir -p /run/sshd
ssh-keygen -A
grep -q '^AllowUsers' /etc/ssh/sshd_config ||
  printf '\nPermitRootLogin no\nAllowUsers %s\n' "$USERNAME" >>/etc/ssh/sshd_config
/usr/sbin/sshd

# pass session cookie + url to firefox.cfg via /tmp/ctfd_auth.json, and
# rewrite the static homepage in policies.json to match
if [ -n "${CTFD_URL:-}" ]; then
  for f in /usr/lib/firefox-esr/distribution/policies.json /usr/share/firefox-esr/distribution/policies.json; do
    if [ -f "$f" ]; then
      jq --arg url "${CTFD_URL%/}/challenges" '.policies.Homepage.URL = $url | (.policies.Bookmarks[] | select(.Title == "Challenges")).URL = $url' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    fi
  done
fi

if [ -n "${CTFD_COOKIE_VALUE:-}" ] && [ -n "${CTFD_URL:-}" ]; then
  jq -n \
    --arg url "$CTFD_URL" \
    --arg name "${CTFD_COOKIE_NAME:-session}" \
    --arg value "$CTFD_COOKIE_VALUE" \
    '{url: $url, name: $name, value: $value}' \
    >/tmp/ctfd_auth.json
  chown "$USERNAME:$USERNAME" /tmp/ctfd_auth.json
  chmod 600 /tmp/ctfd_auth.json
fi

RESOLUTION="${RESOLUTION:-1920x1080}"
WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"

# launch kasmvncserver on :1; it forks and writes ~/.vnc/<host>:1.log
su - "$USERNAME" -c "kasmvncserver :1 \
    -interface 0.0.0.0 \
    -websocketPort 6901 \
    -depth 24 \
    -geometry ${WIDTH}x${HEIGHT} \
    -httpd /usr/share/kasmvnc/www" >/dev/null

# pipe the kasmvnc log to stdout so docker logs is useful
sleep 1
LOG=$(find "/home/$USERNAME/.vnc" -maxdepth 1 -name '*:1.log' -print -quit 2>/dev/null)
if [ -n "$LOG" ]; then
  tail -F "$LOG" &
fi

wait
