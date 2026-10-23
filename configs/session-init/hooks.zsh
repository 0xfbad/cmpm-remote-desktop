[[ -S /run/.session-init.sock ]] || return 0
zmodload zsh/datetime 2>/dev/null || return 0
autoload -Uz add-zsh-hook

typeset -g __si_cmd="" __si_ts=0 __si_tty=""

__si_preexec() {
    __si_cmd=$1
    __si_ts=$EPOCHREALTIME
}

__si_precmd() {
    local ec=$?
    local LC_ALL=C
    [[ -z $__si_cmd ]] && return "$ec"
    if (( ${#__si_cmd} > 60 * 1024 )); then
        __si_cmd=""
        return "$ec"
    fi
    local dur=$(( (EPOCHREALTIME - __si_ts) * 1000 ))
    [[ -z $__si_tty ]] && __si_tty=$(tty 2>/dev/null || echo "?")

    {
        /usr/local/bin/remote-desktop-command-sender /run/.session-init.sock \
            "$__si_ts" "$__si_cmd" "$ec" "${dur%.*}" "$PWD" "$__si_tty"
    } 2>/dev/null &!

    __si_cmd=""
    return "$ec"
}

add-zsh-hook preexec __si_preexec
add-zsh-hook precmd __si_precmd
precmd_functions=(__si_precmd ${precmd_functions:#__si_precmd}) # must observe the original status before fzf and zoxide
