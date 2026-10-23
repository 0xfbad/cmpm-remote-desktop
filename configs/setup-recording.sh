# shellcheck shell=bash

if [ "${TLOG_ENABLED:-}" = "1" ]; then
  if command -v tlog-rec-session >/dev/null 2>&1; then
    USER_SHELL=/usr/bin/tlog-rec-session
    rm -rf /run/tlog # a shared audit session lock would record only the first terminal
    printf '/usr/bin/tlog-rec-session\n' >/etc/shells
    if [ -f /etc/skel/.config/alacritty/alacritty.toml ]; then # alacritty overrides the account login shell
      sed -i \
        -e 's|^program = .*|program = "/usr/bin/tlog-rec-session"|' \
        -e 's|^args = .*|args = []|' \
        /etc/skel/.config/alacritty/alacritty.toml
    fi
    [ -S /dev/log ] || echo "WARN: TLOG_ENABLED=1 but /dev/log is not a socket - transcripts will be dropped" >&2
  else
    USER_SHELL=/bin/zsh
    echo "WARN: TLOG_ENABLED=1 but tlog-rec-session is not installed - sessions will NOT be recorded" >&2
  fi
else
  USER_SHELL=/bin/zsh
fi
export USER_SHELL
