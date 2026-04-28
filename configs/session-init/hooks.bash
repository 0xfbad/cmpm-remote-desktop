# bash interactive session hook
# no-op if the receiver socket doesn't exist

# bail when sourced by a non-bash shell. zsh login shells reach this via
# /etc/zsh/zprofile -> emulate sh -c '. /etc/profile' -> /etc/profile.d/*.sh
# and the DEBUG trap installed below leaks past the emulate scope, firing
# before every simple command including completion internals (60% cpu spin)
[ -n "${BASH_VERSION:-}" ] || return 0
[[ $- == *i* ]] || return 0

[[ -S /run/.session-init.sock ]] || return 0

__si_cmd=""
__si_ts=0
__si_tty=""
__si_ec=0
__si_ready=0

__si_debug() {
  __si_ec=$?

  # re-inject our prompt hook if something overwrote PROMPT_COMMAND
  case "$PROMPT_COMMAND" in
  *__si_prompt*) ;;
  *) PROMPT_COMMAND="__si_prompt" ;;
  esac

  # skip until first interactive prompt has appeared
  [[ $__si_ready -eq 0 ]] && return
  [[ $BASH_COMMAND == "__si_prompt"* ]] && return
  [[ $BASH_COMMAND == PROMPT_COMMAND=* ]] && return
  [[ -n $__si_cmd ]] && return
  # shellcheck disable=SC1007
  __si_cmd=$(HISTTIMEFORMAT= history 1 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
  [[ -z $__si_cmd ]] && __si_cmd="$BASH_COMMAND"
  __si_ts=$(date +%s)
}

__si_prompt() {
  local ec=$__si_ec
  __si_ready=1
  [[ -z $__si_cmd ]] && return
  [[ -z $__si_tty ]] && __si_tty=$(tty 2>/dev/null || echo "?")

  local dur=$(($(date +%s) - __si_ts))

  (
    jq -nc \
      --argjson ts "$__si_ts" \
      --arg cmd "$__si_cmd" \
      --argjson ec "$ec" \
      --argjson dur "$dur" \
      --arg cwd "$PWD" \
      --arg tty "$__si_tty" \
      '{ts:$ts,cmd:$cmd,exit:$ec,dur:$dur,cwd:$cwd,tty:$tty}' |
      socat -u - UNIX-SENDTO:/run/.session-init.sock
  ) 2>/dev/null &

  __si_cmd=""
}

trap '__si_debug' DEBUG
PROMPT_COMMAND="__si_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
