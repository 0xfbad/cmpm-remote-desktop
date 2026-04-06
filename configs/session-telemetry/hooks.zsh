# shell session telemetry
# sends command data to collector via unix datagram socket
# no-op if the collector socket doesn't exist

[[ -S /run/.session-init.sock ]] || return 0

zmodload zsh/datetime 2>/dev/null || return 0

typeset -g __si_cmd=""
typeset -g __si_ts=0
typeset -g __si_tty=""

__si_preexec() {
    __si_cmd="$1"
    __si_ts=$EPOCHSECONDS
}

__si_precmd() {
    local ec=$?
    [[ -z "$__si_cmd" ]] && return

    local dur=$(( EPOCHSECONDS - __si_ts ))
    [[ -z "$__si_tty" ]] && __si_tty=$(tty 2>/dev/null || echo "?")

    {
        jq -nc \
            --argjson ts "$__si_ts" \
            --arg cmd "$__si_cmd" \
            --argjson ec "$ec" \
            --argjson dur "$dur" \
            --arg cwd "$PWD" \
            --arg tty "$__si_tty" \
            '{ts:$ts,cmd:$cmd,exit:$ec,dur:$dur,cwd:$cwd,tty:$tty}' \
        | socat -u - UNIX-SENDTO:/run/.session-init.sock
    } 2>/dev/null &!

    __si_cmd=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __si_preexec
add-zsh-hook precmd __si_precmd
