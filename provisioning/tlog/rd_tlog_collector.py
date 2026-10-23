#!/usr/bin/env python3

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
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,200}$")

RECV_SIZE = 65536
PID_CACHE_TTL_SECONDS = 2.0
FLUSH_META_EVERY = 5.0
USAGE_RESCAN_EVERY = 60.0


class DockerNames:

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
        self.pid_cache: dict[int, tuple[str | None, float]] = {}
        self.session_bytes: dict[str, int] = {}
        self.capped: set[str] = set()
        self.total_bytes = 0
        self.total_capped = False
        self.unattributed = 0
        self.dropped = 0
        self.last_meta_flush: dict[str, float] = {}
        self.last_usage_scan = 0.0
        self._restore_usage() # restarts must retain byte cap accounting

    def _restore_usage(self) -> None:
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


    def resolve(self, pid: int) -> str | None:
        now = time.time()
        cached = self.pid_cache.get(pid)
        if cached and now - cached[1] < PID_CACHE_TTL_SECONDS:
            return cached[0]
        cid = cgroup_container_id(pid)
        name = self.names.lookup(cid) if cid else None
        if name and not NAME_RE.match(name):
            name = f"other/{cid}" if cid else None
        self.pid_cache[pid] = (name, now)
        if len(self.pid_cache) > 4096:
            self.pid_cache = {p: v for p, v in self.pid_cache.items() if now - v[1] < PID_CACHE_TTL_SECONDS}
        return name


    def _path_for(self, name: str, suffix: str) -> str:
        if name.startswith("other/"):
            os.makedirs(os.path.join(self.sessions_dir, "other"), mode=0o750, exist_ok=True)
        return os.path.join(self.sessions_dir, f"{name}{suffix}")

    def _append(self, name: str, suffix: str, data: bytes) -> None:
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

            name = self.resolve(pid)
            if name is None:
                self.unattributed += 1
                self._append("unattributed", ".jsonl", payload + b"\n")
                continue
            if name in self.capped or self.total_capped:
                self._refresh_caps_if_due() # retention can reclaim capacity while this path skips writes
            if name in self.capped or self.total_capped:
                self.dropped += 1
                continue

            rec = extract_tlog_json(payload)
            if rec is not None:
                idx = payload.find(b"{")
                self._append(name, ".tlog.jsonl", payload[idx:] + b"\n")
            else:
                self._append(name, ".syslog.log", payload + b"\n")


def make_socket(path: str) -> socket.socket:
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
    parser = argparse.ArgumentParser(description="collect terminal output from the runner socket", formatter_class=argparse.RawDescriptionHelpFormatter)
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
