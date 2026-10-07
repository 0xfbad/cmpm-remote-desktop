[ -n "${BASH_VERSION:-}" ] || return 0
[[ $- == *i* ]] || return 0
[[ -S /run/.session-init.sock ]] || return 0
declare -F __si_prompt >/dev/null && return 0

__si_history_id=$(HISTTIMEFORMAT='' history 1 2>/dev/null | awk '{print $1; exit}')
__si_tty=""

__si_prompt() {
  local ec=$? entry id cmd
  entry=$(HISTTIMEFORMAT='' history 1 2>/dev/null)
  if [[ ! $entry =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ ]]; then
    return "$ec"
  fi
  id=${BASH_REMATCH[1]}
  cmd=${BASH_REMATCH[2]}
  if [[ $id == "$__si_history_id" ]]; then
    return "$ec"
  fi
  __si_history_id=$id
  [[ -z $__si_tty ]] && __si_tty=$(tty 2>/dev/null || echo "?")
  (
    jq -nc \
      --argjson ts "$EPOCHREALTIME" \
      --arg cmd "$cmd" \
      --argjson ec "$ec" \
      --arg cwd "$PWD" \
      --arg tty "$__si_tty" \
      '{ts:$ts,cmd:$cmd,exit:$ec,duration_ms:null,cwd:$cwd,tty:$tty}' |
      socat -u - UNIX-SENDTO:/run/.session-init.sock
  ) 2>/dev/null &
  disown "$!" 2>/dev/null || true
  return "$ec"
}

if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
  PROMPT_COMMAND=(__si_prompt "${PROMPT_COMMAND[@]}")
else
  # shellcheck disable=SC2178,SC2128
  PROMPT_COMMAND="__si_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
