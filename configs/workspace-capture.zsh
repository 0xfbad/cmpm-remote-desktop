# Best-effort capture of recent shell commands for the AI tutor. The directory
# is created by startup.sh only when ENABLE_WORKSPACE_CONTEXT=1; guarding on it
# rather than on the variable is deliberate, because env does not survive the
# `su -l` that ttyd uses to start shells. Rows are well under 4 KiB so `>>` is
# atomic across concurrent terminals; the every-100 rewrite can lose a few lines
# under a race, which is acceptable for best-effort context. ~/.zsh_history is
# deliberately not used: it is flushed only at shell exit and has no exit codes.
if [[ -d /var/lib/rd-workspace && -w /var/lib/rd-workspace ]]; then
  zmodload zsh/datetime
  autoload -Uz add-zsh-hook
  _rd_wc_log=/var/lib/rd-workspace/commands.log
  _rd_wc_cmd="" _rd_wc_start=0 _rd_wc_n=0

  _rd_wc_preexec() { _rd_wc_cmd=$1; _rd_wc_start=$EPOCHREALTIME }

  _rd_wc_precmd() {
    local code=$?
    [[ -z $_rd_wc_cmd ]] && return
    local dur=$(( (EPOCHREALTIME - _rd_wc_start) * 1000 ))
    local cmd=${_rd_wc_cmd//[$'\t\n\r']/ }
    printf '%d\t%d\t%d\t%s\t%s\n' \
      $EPOCHSECONDS $code ${dur%.*} "${PWD/#$HOME/~}" "${cmd[1,200]}" \
      >>$_rd_wc_log 2>/dev/null
    _rd_wc_cmd=""
    if (( ++_rd_wc_n % 100 == 0 )); then
      tail -n 200 $_rd_wc_log >$_rd_wc_log.tmp 2>/dev/null && mv -f $_rd_wc_log.tmp $_rd_wc_log
    fi
  }

  add-zsh-hook preexec _rd_wc_preexec
  add-zsh-hook precmd _rd_wc_precmd
  # must observe the real $? - run before fzf/zoxide precmd hooks registered earlier in .zshrc
  precmd_functions=(_rd_wc_precmd ${precmd_functions:#_rd_wc_precmd})
fi
