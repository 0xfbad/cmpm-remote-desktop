"""Security and durability tests for the host-side tlog collector."""

import importlib.util
import json
import socket
import sys
import threading
import time
from pathlib import Path

import pytest


COLLECTOR_PATH = Path(__file__).resolve().parents[1] / "provisioning" / "tlog" / "rd_tlog_collector.py"
HEX_ID = "a1" * 32


@pytest.fixture(scope="module")
def mod():
    spec = importlib.util.spec_from_file_location("rd_tlog_collector", COLLECTOR_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["rd_tlog_collector"] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _collector(mod, tmp_path, per_session=1024, total=4096):
    reader, writer = socket.socketpair()
    writer.close()
    return mod.Collector(reader, str(tmp_path), per_session, total), reader


def test_cgroup_attribution_is_full_docker_scope(mod):
    match = mod.CGROUP_RE.search(f"0::/rd.slice/docker-{HEX_ID}.scope")
    assert match and match.group(1) == HEX_ID
    assert mod.CGROUP_RE.search(f"0::/rd.slice/docker-{HEX_ID[:32]}.scope") is None


def test_payload_demux_requires_tlog_keys(mod):
    payload = b'<86>host tlog: {"ver":"2.3","rec":1,"out_txt":"x"}'
    assert mod.extract_tlog_json(payload)["out_txt"] == "x"
    assert mod.extract_tlog_json(b'<86>app: {"msg":"x"}') is None


def test_name_validation_rejects_traversal(mod):
    assert mod.NAME_RE.match("rd-session-12-345")
    assert mod.NAME_RE.match("../etc") is None


def test_per_session_cap_refuses_before_crossing(mod, tmp_path):
    collector, sock = _collector(mod, tmp_path, per_session=10)
    try:
        collector._append("s1", ".tlog.jsonl", b"12345\n")
        collector._append("s1", ".tlog.jsonl", b"67890\n")
        assert (tmp_path / "sessions" / "s1.tlog.jsonl").read_bytes() == b"12345\n"
        assert collector.session_bytes["s1"] == 6
        assert "s1" in collector.capped
    finally:
        sock.close()


def test_total_cap_refuses_before_crossing(mod, tmp_path):
    collector, sock = _collector(mod, tmp_path, total=5)
    try:
        collector._append("s1", ".tlog.jsonl", b"123456\n")
        assert collector.total_capped is True
        assert not (tmp_path / "sessions" / "s1.tlog.jsonl").exists()
    finally:
        sock.close()


def test_restart_restores_per_session_and_total_usage(mod, tmp_path):
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    (sessions / "s1.tlog.jsonl").write_bytes(b"12345678")

    collector, sock = _collector(mod, tmp_path, per_session=10, total=100)
    try:
        assert collector.session_bytes["s1"] == 8
        assert collector.total_bytes == 8
        collector._append("s1", ".tlog.jsonl", b"more")
        assert (sessions / "s1.tlog.jsonl").read_bytes() == b"12345678"
        assert "s1" in collector.capped
    finally:
        sock.close()


def test_restart_counts_syslog_and_ignores_symlinks(mod, tmp_path):
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    (sessions / "s1.syslog.log").write_bytes(b"1234")
    (sessions / "escape.tlog.jsonl").symlink_to("/etc/passwd")
    collector, sock = _collector(mod, tmp_path)
    try:
        assert collector.session_bytes == {"s1": 4}
        assert collector.total_bytes == 4
    finally:
        sock.close()


def test_restart_restores_total_cap(mod, tmp_path):
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    (sessions / "s1.tlog.jsonl").write_bytes(b"12345678")
    collector, sock = _collector(mod, tmp_path, per_session=100, total=10)
    try:
        collector._append("s2", ".tlog.jsonl", b"more")
        assert collector.total_capped is True
        assert not (sessions / "s2.tlog.jsonl").exists()
    finally:
        sock.close()


def test_retention_deletion_releases_total_cap_without_restart(mod, tmp_path, monkeypatch):
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    old = sessions / "old.tlog.jsonl"
    old.write_bytes(b"1234567890")
    collector, sock = _collector(mod, tmp_path, per_session=100, total=10)
    try:
        assert collector.total_capped is True
        old.unlink()
        monkeypatch.setattr(mod, "USAGE_RESCAN_EVERY", 0)
        collector._append("new", ".tlog.jsonl", b"ok")
        assert (sessions / "new.tlog.jsonl").read_bytes() == b"ok"
        assert collector.total_capped is False
    finally:
        sock.close()


def test_datagram_end_to_end(mod, tmp_path, monkeypatch):
    monkeypatch.delenv("LISTEN_FDS", raising=False)
    sock_path = str(tmp_path / "log.sock")
    state_dir = tmp_path / "state"
    recv_sock = mod.make_socket(sock_path)
    collector = mod.Collector(recv_sock, str(state_dir), 1024**2, 1024**3)
    monkeypatch.setattr(mod.Collector, "resolve", lambda self, pid: "rd-session-test")

    def run():
        try:
            collector.run()
        except OSError:
            pass

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        client.sendto(b'<86>tlog: {"ver":"2.3","rec":1,"out_txt":"MARK"}', sock_path)
        transcript = state_dir / "sessions" / "rd-session-test.tlog.jsonl"
        deadline = time.time() + 5
        while time.time() < deadline and not transcript.exists():
            time.sleep(0.02)
        assert json.loads(transcript.read_text().splitlines()[0])["out_txt"] == "MARK"
    finally:
        client.close()
        recv_sock.close()
        thread.join(timeout=2)


def test_datagram_recovers_after_retention_deletes_capped_file(mod, tmp_path, monkeypatch):
    monkeypatch.delenv("LISTEN_FDS", raising=False)
    monkeypatch.setattr(mod, "USAGE_RESCAN_EVERY", 0)
    sock_path = str(tmp_path / "log.sock")
    state_dir = tmp_path / "state"
    sessions = state_dir / "sessions"
    sessions.mkdir(parents=True)
    old = sessions / "old.tlog.jsonl"
    old.write_bytes(b"1234567890")

    recv_sock = mod.make_socket(sock_path)
    collector = mod.Collector(recv_sock, str(state_dir), 100, 10)
    monkeypatch.setattr(mod.Collector, "resolve", lambda self, pid: "new")

    def run():
        try:
            collector.run()
        except OSError:
            pass

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    old.unlink()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        client.sendto(b'x', sock_path)
        transcript = sessions / "new.syslog.log"
        deadline = time.time() + 5
        while time.time() < deadline and not transcript.exists():
            time.sleep(0.02)
        assert transcript.read_bytes() == b"x\n"
        assert collector.total_capped is False
    finally:
        client.close()
        recv_sock.close()
        thread.join(timeout=2)
