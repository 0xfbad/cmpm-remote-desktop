# shellcheck shell=bash
# sourced by startup.sh (and the smoke-test entrypoint) to pick the user's
# login shell. TLOG_ENABLED=1 routes every terminal (ttyd su -l, sshd,
# xfce4-terminal, alacritty) through tlog-rec-session, which records output
# (never input/keystrokes) to /dev/log - the bind-mounted host collector socket.

if [ "${TLOG_ENABLED:-}" = "1" ]; then
  if command -v tlog-rec-session >/dev/null 2>&1; then
    USER_SHELL=/usr/bin/tlog-rec-session
    # lockfile gotcha: every process in a container shares one audit session
    # id, so a pre-existing /run/tlog limits recording to the FIRST terminal.
    # absent the dir, tlog records every terminal. do not "fix" by creating it
    rm -rf /run/tlog
    # blocks non-sudo chsh only; sudo users bypass everything (documented
    # non-goal - tlog is coverage/fidelity, not tamper-proofing)
    printf '/usr/bin/tlog-rec-session\n' >/etc/shells
    # alacritty hardcodes its shell in the skel config and would bypass the
    # passwd shell entirely - repoint it BEFORE useradd -m copies skel
    if [ -f /etc/skel/.config/alacritty/alacritty.toml ]; then
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
