#!/usr/bin/env bash
# end-to-end workspace-context capture smoke against the real image:
#   T1 without ENABLE_WORKSPACE_CONTEXT the directory and hooks are absent and
#   shells work; T2 with it on, a ttyd-style login shell writes one TSV row per
#   command with the right exit codes and home-relative cwd; T3 the log is
#   capped at 200 lines after 500 prompt cycles; T4 capture and tlog coexist.
# hooks only fire in an interactive shell, so every driver pipes a script into
# `su -l "$USERNAME" -c 'zsh -i'`, the same shell ttyd gets.
# run: tests/smoke-workspace-context.sh [image]
set -u

IMAGE="${1:-ctfd-remote-desktop:latest}"
USER=wcuser
C=rd-session-wcsmoke
LOG=/var/lib/rd-workspace/commands.log
FAILURES=0

say() { printf '%s\n' "$*"; }
pass() { say "PASS: $*"; }
fail() {
  say "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

cleanup() {
  docker rm -f "$C-off" "$C-on" "$C-tlog" >/dev/null 2>&1 || true
  [ -n "${COLLECTOR_PID:-}" ] && kill "$COLLECTOR_PID" 2>/dev/null
  [ -n "${WORK:-}" ] && rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

wait_ready() {
  for _i in $(seq 1 120); do
    docker exec "$1" pgrep -f xfce4-session >/dev/null 2>&1 && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] || {
      fail "container $1 died"
      docker logs "$1" 2>&1 | tail
      return 1
    }
    sleep 1
  done
  fail "container $1 never became ready"
  return 1
}

# feed stdin to an interactive login zsh in $1
zsh_drive() { docker exec -i "$1" su -l "$USER" -c 'zsh -i' 2>/dev/null | tr -d '\r'; }

# T1: opt-out default
docker run -d --name "$C-off" -e CTFD_USERNAME="$USER" -e VNC_PASSWORD=smokepw \
  -p 127.0.0.1::6080 "$IMAGE" >/dev/null
wait_ready "$C-off" || exit 1

if docker exec "$C-off" test -d /var/lib/rd-workspace; then
  fail "T1 /var/lib/rd-workspace exists without ENABLE_WORKSPACE_CONTEXT"
else
  pass "T1 workspace directory absent by default"
fi
# shellcheck disable=SC2016 # the zsh under test expands its own function table lookup
out=$(printf 'print -r -- HOOKS=${+functions[_rd_wc_precmd]}\necho SHELL-OK\nexit\n' | zsh_drive "$C-off")
case "$out" in *HOOKS=0*) pass "T1 capture hooks not loaded" ;; *) fail "T1 hook state: $out" ;; esac
case "$out" in *SHELL-OK*) pass "T1 shell works normally" ;; *) fail "T1 shell broken" ;; esac

# T2: opt-in capture through a ttyd-style login shell
docker run -d --name "$C-on" -e CTFD_USERNAME="$USER" -e VNC_PASSWORD=smokepw \
  -e ENABLE_WORKSPACE_CONTEXT=1 -p 127.0.0.1::6080 "$IMAGE" >/dev/null
wait_ready "$C-on" || exit 1

perms=$(docker exec "$C-on" stat -c '%U:%G:%a' /var/lib/rd-workspace 2>/dev/null)
if [ "$perms" = "$USER:$USER:700" ]; then pass "T2 workspace dir is $perms"; else fail "T2 workspace dir perms: $perms"; fi

printf 'pwd\nfalse\ncd /tmp && true\nexit\n' | zsh_drive "$C-on" >/dev/null
rows=$(docker exec "$C-on" cat "$LOG" 2>/dev/null)
count=$(printf '%s\n' "$rows" | grep -c . || true)
codes=$(printf '%s\n' "$rows" | cut -f2 | tr '\n' ' ')
cwds=$(printf '%s\n' "$rows" | cut -f4 | tr '\n' ' ')
cmds=$(printf '%s\n' "$rows" | cut -f5 | tr '\n' '|')
if [ "$count" = "3" ]; then pass "T2 three rows recorded"; else fail "T2 recorded $count rows: $rows"; fi
if [ "$codes" = "0 1 0 " ]; then pass "T2 exit codes are 0 1 0"; else fail "T2 exit codes: $codes"; fi
if [ "$cwds" = "~ ~ /tmp " ]; then pass "T2 cwd is home-relative then absolute after cd"; else fail "T2 cwds: $cwds"; fi
if [ "$cmds" = "pwd|false|cd /tmp && true|" ]; then pass "T2 commands captured verbatim"; else fail "T2 commands: $cmds"; fi
fields=$(docker exec "$C-on" awk -F'\t' '{print NF}' "$LOG" 2>/dev/null | sort -u | tr -d '\n')
if [ "$fields" = "5" ]; then pass "T2 every row has 5 TSV fields"; else fail "T2 field counts: $fields"; fi

# T3: 500 prompt cycles leave at most 200 lines
{
  for _i in $(seq 1 500); do echo true; done
  echo exit
} | zsh_drive "$C-on" >/dev/null
lines=$(docker exec "$C-on" wc -l "$LOG" 2>/dev/null | awk '{print $1}')
if [ -n "$lines" ] && [ "$lines" -le 200 ]; then pass "T3 log capped at $lines lines"; else fail "T3 log has $lines lines"; fi

# T4: coexistence with tlog
WORK=$(mktemp -d /tmp/rd-wc-smoke.XXXXXX)
SOCK="$WORK/log.sock"
COLLECTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/provisioning/tlog/rd_tlog_collector.py"
python3 "$COLLECTOR" --socket "$SOCK" --state-dir "$WORK" &
COLLECTOR_PID=$!
for _ in $(seq 1 50); do
  [ -S "$SOCK" ] && break
  sleep 0.1
done
if [ -S "$SOCK" ]; then
  chmod 666 "$SOCK"
  docker run -d --name "$C-tlog" -e CTFD_USERNAME="$USER" -e VNC_PASSWORD=smokepw \
    -e ENABLE_WORKSPACE_CONTEXT=1 -e TLOG_ENABLED=1 \
    --mount "type=bind,src=$SOCK,dst=/dev/log,readonly" \
    -p 127.0.0.1::6080 "$IMAGE" >/dev/null
  if wait_ready "$C-tlog"; then
    printf 'echo WCTLOGMARK\nexit\n' | zsh_drive "$C-tlog" >/dev/null
    sleep 8 # tlog latency=10 max; drain
    if grep -q WCTLOGMARK "$WORK/sessions/$C-tlog.tlog.jsonl" 2>/dev/null; then
      pass "T4 tlog transcript still produced"
    else
      fail "T4 tlog transcript missing"
    fi
    if docker exec "$C-tlog" grep -q WCTLOGMARK "$LOG" 2>/dev/null; then
      pass "T4 commands.log written alongside tlog"
    else
      fail "T4 commands.log not written under tlog"
    fi
  fi
else
  fail "T4 collector socket never appeared"
fi

cleanup
if [ "$FAILURES" -gt 0 ]; then
  say "$FAILURES failure(s)"
  exit 1
fi
say "all workspace context assertions passed"
