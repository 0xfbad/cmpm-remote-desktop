#!/bin/sh
export SHELL="$1"
tmux -L browser -f /usr/local/lib/browser-terminal.conf new-session -d -s browser "$1" -l 2>/dev/null ||
  tmux -L browser has-session -t browser || exit $?

size=$(stty size) || exit $?
tmux -L browser resize-window -t browser -x "${size#* }" -y "${size%% *}" || exit $?

captured=$(tmux -L browser if-shell -F '#{history_size}' 'capture-pane -epJ -S - -E -1 -t browser' \; \
  capture-pane -epJ -S 0 -t browser && printf x) || exit $?
captured=${captured%x}
printf '%s' "${captured%?}" # tmux redraws the last row on attach, omit the snapshot final newline
exec tmux -L browser attach-session -t browser \; set-window-option -t browser window-size latest
