#!/usr/bin/env bash
# end-to-end tlog smoke against the real image + the plugin's collector:
#   T1 ttyd-style login shell records; T2 second concurrent terminal records
#   (proves the /run/tlog lock removal); T3 no-TTY su -c passthrough works;
#   T4 skel alacritty points at tlog and $SHELL is zsh inside a recorded shell;
#   T5 kill tlog -> container survives; T6 docker kill -> transcript survives;
#   T7 no socket mount + TLOG_ENABLED=1 -> degrade warning, shells still work.
# run: tests/smoke-tlog.sh [image] [collector.py]
set -u

if [ "${1:-}" = "--collector-unit" ]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  python3 - "$REPO_ROOT/provisioning/tlog/rd_tlog_collector.py" <<'PY'
import importlib.util
import pathlib
import socket
import sys
import tempfile

spec = importlib.util.spec_from_file_location("rd_tlog_collector", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as directory:
    sessions = pathlib.Path(directory, "sessions")
    sessions.mkdir()
    transcript = sessions / "s1.tlog.jsonl"
    transcript.write_bytes(b"12345678")
    reader, writer = socket.socketpair()
    writer.close()
    collector = module.Collector(reader, directory, per_session_max=10, total_max=100)
    collector._append("s1", ".tlog.jsonl", b"more")
    assert transcript.read_bytes() == b"12345678"
    assert collector.session_bytes["s1"] == 8
    assert "s1" in collector.capped
    reader.close()
print("collector restart-cap test passed")
PY
  exit
fi

IMAGE="${1:-ctfd-remote-desktop:latest}"
COLLECTOR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/provisioning/tlog/rd_tlog_collector.py}"
WORK=$(mktemp -d /tmp/rd-tlog-smoke.XXXXXX)
SOCK="$WORK/log.sock"
C=rd-session-tlogsmoke
FAILURES=0

say() { printf '%s\n' "$*"; }
pass() { say "PASS: $*"; }
fail() {
  say "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

cleanup() {
  docker rm -f "$C" "$C-degrade" >/dev/null 2>&1 || true
  [ -n "${COLLECTOR_PID:-}" ] && kill "$COLLECTOR_PID" 2>/dev/null
}
trap cleanup EXIT

python3 "$COLLECTOR" --socket "$SOCK" --state-dir "$WORK" &
COLLECTOR_PID=$!
for _ in $(seq 1 50); do
  [ -S "$SOCK" ] && break
  sleep 0.1
done
[ -S "$SOCK" ] || {
  fail "collector socket never appeared"
  exit 1
}
chmod 666 "$SOCK"

docker run -d --name "$C" -e CTFD_USERNAME=tloguser -e VNC_PASSWORD=smokepw \
  -e TLOG_ENABLED=1 --mount "type=bind,src=$SOCK,dst=/dev/log,readonly" \
  -p 127.0.0.1::6080 "$IMAGE" >/dev/null

# The socket is shared by every session. A rooted student must not be able to
# chmod/unlink the host inode and suppress recording for peers.
if docker exec "$C" chmod 000 /dev/log >/dev/null 2>&1; then
  fail "T0 read-only collector socket accepted chmod"
else
  pass "T0 collector socket is read-only"
fi

for _i in $(seq 1 120); do
  docker exec "$C" pgrep -f xfce4-session >/dev/null 2>&1 && break
  [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] || {
    fail "container died"
    docker logs "$C" | tail
    exit 1
  }
  sleep 1
done

TRANSCRIPT="$WORK/sessions/$C.tlog.jsonl"

# T1: login shell is tlog and output is recorded
shell=$(docker exec "$C" getent passwd tloguser | cut -d: -f7)
if [ "$shell" = "/usr/bin/tlog-rec-session" ]; then pass "T1 passwd shell is tlog"; else fail "T1 passwd shell is $shell"; fi
docker exec -t "$C" su -l tloguser -c 'echo TLOGMARK1' >/dev/null 2>&1
sleep 8 # tlog latency=10 max; drain
if [ -f "$TRANSCRIPT" ] && grep -q TLOGMARK1 "$TRANSCRIPT"; then
  pass "T1 marker recorded in host transcript"
else
  fail "T1 marker not in transcript ($TRANSCRIPT)"
fi

# T2: a SECOND concurrent terminal still records (the /run/tlog lockfile
# would have limited recording to the first terminal)
docker exec -d -t "$C" su -l tloguser -c 'sleep 30' >/dev/null 2>&1
sleep 1
docker exec -t "$C" su -l tloguser -c 'echo TLOGMARK2' >/dev/null 2>&1
sleep 8
if grep -q TLOGMARK2 "$TRANSCRIPT"; then pass "T2 concurrent second terminal recorded"; else fail "T2 second terminal not recorded"; fi

# T3: no-TTY passthrough (scp/sftp shape) exits 0
if docker exec "$C" su -l tloguser -c 'echo notty-ok' >/dev/null 2>&1; then
  pass "T3 no-TTY su -c passes through"
else
  fail "T3 no-TTY su -c failed"
fi

# T4: skel patch + child SHELL
prog=$(docker exec "$C" grep '^program' /home/tloguser/.config/alacritty/alacritty.toml 2>/dev/null)
case "$prog" in *tlog-rec-session*) pass "T4 alacritty skel points at tlog" ;; *) fail "T4 alacritty program: $prog" ;; esac
# tlog prints an informational "Ignoring non-existent lock file" line (the
# absent /run/tlog is intentional), so grep for the value instead of tail -1
shellout=$(docker exec -t "$C" su -l tloguser -c 'echo SHELLIS=$SHELL' 2>/dev/null | tr -d '\r')
case "$shellout" in *SHELLIS=/usr/bin/zsh* | *SHELLIS=/bin/zsh*) pass "T4 recorded shell exports SHELL=zsh" ;; *) fail "T4 SHELL inside recorded shell: $shellout" ;; esac

# T5: killing tlog stops the transcript but not the container
docker exec "$C" pkill -9 tlog-rec-session 2>/dev/null
sleep 2
if [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ]; then pass "T5 container survives tlog kill"; else fail "T5 container died"; fi

# T6: durability across container destruction
size_before=$(stat -c %s "$TRANSCRIPT" 2>/dev/null || echo 0)
docker kill "$C" >/dev/null 2>&1
sleep 2
if [ -f "$TRANSCRIPT" ] && [ "$(stat -c %s "$TRANSCRIPT")" -ge "$size_before" ]; then
  pass "T6 transcript survives container teardown"
else
  fail "T6 transcript lost on teardown"
fi

# T7: degrade path - no socket mount, TLOG_ENABLED=1
docker run -d --name "$C-degrade" -e CTFD_USERNAME=tloguser -e VNC_PASSWORD=smokepw \
  -e TLOG_ENABLED=1 -p 127.0.0.1::6080 "$IMAGE" >/dev/null
for _i in $(seq 1 120); do
  docker exec "$C-degrade" pgrep -f xfce4-session >/dev/null 2>&1 && break
  sleep 1
done
if docker logs "$C-degrade" 2>&1 | grep -q "/dev/log is not a socket"; then
  pass "T7 degrade warning emitted"
else
  fail "T7 no degrade warning in logs"
fi
if docker exec -t "$C-degrade" su -l tloguser -c 'echo still-works' 2>/dev/null | grep -q still-works; then
  pass "T7 shells still work without collector"
else
  fail "T7 shell broken without collector"
fi

cleanup
say "state dir kept at $WORK for inspection"
if [ "$FAILURES" -gt 0 ]; then
  say "$FAILURES failure(s)"
  exit 1
fi
say "all tlog assertions passed"
