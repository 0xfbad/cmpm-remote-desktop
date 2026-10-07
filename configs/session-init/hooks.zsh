[[ -S /run/.session-init.sock || ( -d /var/lib/rd-workspace && -w /var/lib/rd-workspace ) ]] || return 0
zmodload zsh/datetime 2>/dev/null || return 0
autoload -Uz add-zsh-hook

typeset -g __si_cmd="" __si_ts=0 __si_tty="" __si_n=0

__si_preexec() {
    __si_cmd=$1
    __si_ts=$EPOCHREALTIME
}

__si_precmd() {
    local ec=$?
    [[ -z $__si_cmd ]] && return
    local dur=$(( (EPOCHREALTIME - __si_ts) * 1000 ))
    [[ -z $__si_tty ]] && __si_tty=$(tty 2>/dev/null || echo "?")

    if [[ -S /run/.session-init.sock ]]; then
        {
            jq -nc \
                --argjson ts "$__si_ts" \
                --arg cmd "$__si_cmd" \
                --argjson ec "$ec" \
                --argjson dur "${dur%.*}" \
                --arg cwd "$PWD" \
                --arg tty "$__si_tty" \
                '{ts:$ts,cmd:$cmd,exit:$ec,duration_ms:$dur,cwd:$cwd,tty:$tty}' \
            | socat -u - UNIX-SENDTO:/run/.session-init.sock
        } 2>/dev/null &!
    fi

    if [[ -d /var/lib/rd-workspace && -w /var/lib/rd-workspace ]]; then
        local cmd=${__si_cmd//[$'\t\n\r']/ }
        printf '%d\t%d\t%d\t%s\t%s\n' \
            $EPOCHSECONDS $ec ${dur%.*} "${PWD/#$HOME/~}" "${cmd[1,200]}" \
            >>/var/lib/rd-workspace/commands.log 2>/dev/null
        if (( ++__si_n % 100 == 0 )); then
            tail -n 200 /var/lib/rd-workspace/commands.log >/var/lib/rd-workspace/commands.log.tmp 2>/dev/null \
                && mv -f /var/lib/rd-workspace/commands.log.tmp /var/lib/rd-workspace/commands.log
        fi
    fi
    __si_cmd=""
}

add-zsh-hook preexec __si_preexec
add-zsh-hook precmd __si_precmd
precmd_functions=(__si_precmd ${precmd_functions:#__si_precmd}) # must observe the original status before fzf and zoxide
