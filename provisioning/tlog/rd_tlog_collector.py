#!/usr/bin/env python3
"""rd-tlog-collector: per-runner sink for tlog session transcripts.

Sessions bind-mount this daemon's AF_UNIX datagram socket as /dev/log; tlog
(writer=syslog) sends JSON records through glibc syslog(3). Attribution is by
SCM_CREDENTIALS: the kernel-translated sender pid is resolved through
/proc/<pid>/cgroup to a docker container id, then to the container name over
the docker API. Forging another session's pid needs CAP_SYS_ADMIN, which the
session containers do not have (cap_drop=ALL + a small allowlist) - a student
can only pollute their OWN transcript, which is equivalent to producing output.

Files land in <state-dir>/sessions/<container-name>.tlog.jsonl (tlog-play
compatible) with non-tlog syslog lines in <name>.syslog.log and a .meta
sidecar carrying the last-write epoch (the visible-gap record when a student
kills the recorder).

Stdlib only. Run under systemd socket activation (rd-tlog-collector.socket):
systemd holds the socket fd across collector restarts, so the bind-mounted
inode stays live for running sessions. Never restart the .socket unit while
sessions run - a re-bind replaces the inode and running containers keep the
dead one until session end.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import socket
import struct
import sys
import time

_CRED_SIZE = struct.calcsize("3i")

CGROUP_RE = re.compile(r"docker-([0-9a-f]{64})\.scope")
# path-traversal guard for names that come back from the docker API
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,200}$")

RECV_SIZE = 65536
PID_CACHE_TTL = 2.0  # seconds; pid-reuse inside this window is not attacker-steerable
FLUSH_META_EVERY = 5.0
USAGE_RESCAN_EVERY = 60.0


class DockerNames:
    """container id -> name over the docker unix socket, cached."""

    def __init__(self, docker_sock: str = "/var/run/docker.sock") -> None:
        self.docker_sock = docker_sock
        self.cache: dict[str, str] = {}

    def lookup(self, container_id: str) -> str | None:
        name = self.cache.get(container_id)
        if name:
            return name
        try:
            conn = _UnixHTTPConnection(self.docker_sock)
            conn.request("GET", f"/containers/{container_id}/json")
            resp = conn.getresponse()
            if resp.status != 200:
                return None
            data = json.loads(resp.read())
            name = str(data.get("Name", "")).lstrip("/")
            conn.close()
        except Exception:
            return None
        if not name:
            return None
        self.cache[container_id] = name
        return name


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str) -> None:
        super().__init__("localhost")
        self._path = path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2.0)
        sock.connect(self._path)
        self.sock = sock


def cgroup_container_id(pid: int) -> str | None:
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            content = f.read()
    except OSError:
        return None
    m = CGROUP_RE.search(content)
    return m.group(1) if m else None


def extract_tlog_json(payload: bytes) -> dict | None:
    """first '{' after the syslog header; must carry tlog's ver+rec keys."""
    idx = payload.find(b"{")
    if idx == -1:
        return None
    try:
        data = json.loads(payload[idx:])
    except (ValueError, UnicodeDecodeError):
        return None
    if isinstance(data, dict) and "ver" in data and "rec" in data:
        return data
    return None


class Collector:
    def __init__(
        self,
        sock: socket.socket,
        state_dir: str,
        per_session_max: int,
        total_max: int,
        docker_sock: str = "/var/run/docker.sock",
    ) -> None:
        self.sock = sock
        self.state_dir = state_dir
        self.sessions_dir = os.path.join(state_dir, "sessions")
        os.makedirs(self.sessions_dir, mode=0o750, exist_ok=True)
        self.per_session_max = per_session_max
        self.total_max = total_max
        self.names = DockerNames(docker_sock)
        # pid -> (session_name | None, resolved_at)
        self.pid_cache: dict[int, tuple[str | None, float]] = {}
        self.session_bytes: dict[str, int] = {}
        self.capped: set[str] = set()
        self.total_bytes = 0
        self.total_capped = False
        self.unattributed = 0
        self.dropped = 0
        self.last_meta_flush: dict[str, float] = {}
        self.last_usage_scan = 0.0
        self._restore_usage()

    def _restore_usage(self) -> None:
        """Rebuild cap accounting from durable files after every restart.

        The collector is intentionally restartable under systemd socket
        activation.  Starting counters at zero made every restart reset both
        byte caps, so the limits were not limits at all.  Symlinks and special
        files are ignored; the service's protected state directory should
        contain only collector-owned regular files.
        """
        self.session_bytes = {}
        self.total_bytes = 0
        suffixes = (".tlog.jsonl", ".syslog.log", ".jsonl")
        for root, _dirs, files in os.walk(self.sessions_dir, followlinks=False):
            for filename in files:
                path = os.path.join(root, filename)
                try:
                    st = os.lstat(path)
                except OSError:
                    continue
                if not os.path.isfile(path) or os.path.islink(path):
                    continue
                self.total_bytes += st.st_size
                relative = os.path.relpath(path, self.sessions_dir)
                for suffix in suffixes:
                    if relative.endswith(suffix):
                        name = relative[: -len(suffix)]
                        self.session_bytes[name] = self.session_bytes.get(name, 0) + st.st_size
                        break
        self.capped = {name for name, used in self.session_bytes.items() if used >= self.per_session_max}
        self.total_capped = self.total_bytes >= self.total_max
        self.last_usage_scan = time.time()

    # -- attribution ---------------------------------------------------------

    def resolve(self, pid: int) -> str | None:
        now = time.time()
        cached = self.pid_cache.get(pid)
        if cached and now - cached[1] < PID_CACHE_TTL:
            return cached[0]
        cid = cgroup_container_id(pid)
        name = self.names.lookup(cid) if cid else None
        if name and not NAME_RE.match(name):
            # keep the record but quarantine the path
            name = f"other/{cid}" if cid else None
        self.pid_cache[pid] = (name, now)
        if len(self.pid_cache) > 4096:
            self.pid_cache = {p: v for p, v in self.pid_cache.items() if now - v[1] < PID_CACHE_TTL}
        return name

    # -- writing -------------------------------------------------------------

    def _path_for(self, name: str, suffix: str) -> str:
        if name.startswith("other/"):
            os.makedirs(os.path.join(self.sessions_dir, "other"), mode=0o750, exist_ok=True)
        return os.path.join(self.sessions_dir, f"{name}{suffix}")

    def _append(self, name: str, suffix: str, data: bytes) -> None:
        # The retention timer deletes old files independently. Rescan even
        # while capped so reclaimed space becomes usable without restarting
        # the collector (and without letting a restart reset accounting).
        if time.time() - self.last_usage_scan >= USAGE_RESCAN_EVERY:
            self._restore_usage()
        if self.total_capped:
            return
        used = self.session_bytes.get(name, 0)
        if name in self.capped:
            self.dropped += 1
            return
        if self.total_bytes + len(data) > self.total_max:
            self.total_capped = True
            self.dropped += 1
            print("TOTAL byte cap reached - transcript writes stopped, still draining", file=sys.stderr, flush=True)
            return
        if used + len(data) > self.per_session_max:
            self.capped.add(name)
            self.dropped += 1
            print(f"per-session cap reached for {name}", file=sys.stderr, flush=True)
            return
        self._raw_write(name, suffix, data)
        self.session_bytes[name] = used + len(data)
        self.total_bytes += len(data)

    def _refresh_caps_if_due(self) -> None:
        """Refresh durable accounting even when the fast-drop path is active."""
        if time.time() - self.last_usage_scan >= USAGE_RESCAN_EVERY:
            self._restore_usage()

    def _raw_write(self, name: str, suffix: str, data: bytes) -> None:
        path = self._path_for(name, suffix)
        with open(path, "ab") as f:
            f.write(data)
        os.chmod(path, 0o640)
        now = time.time()
        if now - self.last_meta_flush.get(name, 0) > FLUSH_META_EVERY:
            meta = self._path_for(name, ".meta")
            with open(meta, "w") as f:
                json.dump({"last_write": now, "bytes": self.session_bytes.get(name, 0) + len(data)}, f)
            self.last_meta_flush[name] = now

    # -- main loop -----------------------------------------------------------

    def run(self) -> None:
        while True:
            try:
                payload, ancdata, _flags, _addr = self.sock.recvmsg(RECV_SIZE, socket.CMSG_SPACE(_CRED_SIZE))
            except InterruptedError:
                continue
            pid = None
            for level, ctype, cdata in ancdata:
                if level == socket.SOL_SOCKET and ctype == socket.SCM_CREDENTIALS:
                    pid, _uid, _gid = struct.unpack("3i", cdata[:_CRED_SIZE])
                    break
            if pid is None:
                self.unattributed += 1
                continue

            # drop-fast ordering: creds -> cache -> cap check, before any JSON
            # parse or disk IO. the loop must always drain, floods included
            name = self.resolve(pid)
            if name is None:
                self.unattributed += 1
                self._append("unattributed", ".jsonl", payload + b"\n")
                continue
            # The retention timer may have deleted capped files. Refresh
            # before the fast drop so capacity can recover without a service
            # restart; _append's rescan alone is unreachable from this path.
            if name in self.capped or self.total_capped:
                self._refresh_caps_if_due()
            if name in self.capped or self.total_capped:
                self.dropped += 1
                continue

            rec = extract_tlog_json(payload)
            if rec is not None:
                idx = payload.find(b"{")
                self._append(name, ".tlog.jsonl", payload[idx:] + b"\n")
            else:
                # non-tlog syslog traffic (sudo, sshd) is a free extra record
                self._append(name, ".syslog.log", payload + b"\n")


def make_socket(path: str) -> socket.socket:
    # systemd socket activation: LISTEN_FDS means fd 3 is our bound socket
    if os.environ.get("LISTEN_FDS"):
        sock = socket.socket(fileno=3)
    else:
        try:
            os.unlink(path)
        except OSError:
            pass
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.bind(path)
        os.chmod(path, 0o666)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    except OSError:
        pass
    return sock


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", default="/run/rd-tlog/log.sock")
    parser.add_argument("--state-dir", default=os.environ.get("STATE_DIRECTORY", "/var/lib/rd-tlog"))
    parser.add_argument("--docker-sock", default="/var/run/docker.sock")
    parser.add_argument(
        "--per-session-max", type=int, default=int(os.environ.get("RD_TLOG_PER_SESSION_MAX", 1024**3))
    )
    parser.add_argument("--total-max", type=int, default=int(os.environ.get("RD_TLOG_TOTAL_MAX", 40 * 1024**3)))
    args = parser.parse_args()

    sock = make_socket(args.socket)
    collector = Collector(sock, args.state_dir, args.per_session_max, args.total_max, args.docker_sock)
    collector.run()


if __name__ == "__main__":
    main()
