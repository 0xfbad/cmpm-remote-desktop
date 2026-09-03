#!/usr/bin/env python3
"""Exercise the desktop exclusively through its Docker-published endpoints."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
from cryptography.hazmat.primitives.ciphers import Cipher, modes


BasicAuth = tuple[str, str]


def _basic_authorization(credentials: BasicAuth) -> str:
    username, password = credentials
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def _initialization_message(credentials: BasicAuth) -> bytes:
    username, password = credentials
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return json.dumps(
        {"AuthToken": token, "columns": 80, "rows": 24},
        separators=(",", ":"),
    ).encode("utf-8")


class WebSocket:
    def __init__(
        self,
        host: str,
        port: int,
        origin: str | None = None,
        *,
        path: str = "/ws",
        subprotocol: str | None = "tty",
        basic_auth: BasicAuth | None = None,
    ) -> None:
        if not path.startswith("/") or any(character in path for character in "\r\n"):
            raise ValueError(f"invalid WebSocket path: {path!r}")
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.settimeout(5)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request_headers = [
            f"GET {path} HTTP/1.1",
            f"Host: {host}:{port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        if subprotocol is not None:
            request_headers.append(f"Sec-WebSocket-Protocol: {subprotocol}")
        if basic_auth is not None:
            request_headers.append(f"Authorization: {_basic_authorization(basic_auth)}")
        request_headers.append(f"Origin: {origin or f'http://{host}:{port}'}")
        request = "\r\n".join([*request_headers, "", ""])
        self.sock.sendall(request.encode("ascii"))
        response = self._read_until(b"\r\n\r\n")
        status, *headers = response.decode("iso-8859-1").split("\r\n")
        if " 101 " not in status:
            self.sock.close()
            raise RuntimeError(f"WebSocket upgrade failed: {status}")
        parsed = {
            name.lower(): value.strip()
            for line in headers
            if line and ":" in line
            for name, value in [line.split(":", 1)]
        }
        accept = parsed.get("sec-websocket-accept", "")
        expected = base64.b64encode(
            hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
            ).digest()
        ).decode("ascii")
        if accept != expected:
            self.sock.close()
            raise RuntimeError("WebSocket server returned an invalid accept key")
        if subprotocol is not None:
            selected_subprotocol = parsed.get("sec-websocket-protocol")
            if selected_subprotocol != subprotocol:
                self.sock.close()
                raise RuntimeError(
                    "WebSocket server selected an invalid subprotocol: "
                    f"{selected_subprotocol!r}"
                )

    def _read_exact(self, size: int) -> bytes:
        chunks: list[bytes] = []
        remaining = size
        while remaining:
            chunk = self.sock.recv(remaining)
            if not chunk:
                raise EOFError("WebSocket peer closed the TCP connection")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _read_until(self, delimiter: bytes) -> bytes:
        data = bytearray()
        while delimiter not in data:
            data.extend(self._read_exact(1))
            if len(data) > 65536:
                raise RuntimeError("oversized HTTP upgrade response")
        return bytes(data)

    def send(self, payload: bytes, opcode: int = 0x2, fin: bool = True) -> None:
        mask = os.urandom(4)
        length = len(payload)
        header = bytearray([(0x80 if fin else 0) | opcode])
        if length < 126:
            header.append(0x80 | length)
        elif length <= 0xFFFF:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def receive(self) -> tuple[int, bytes]:
        first, second = self._read_exact(2)
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._read_exact(8))[0]
        if second & 0x80:
            raise RuntimeError("server-to-client WebSocket frame was masked")
        return opcode, self._read_exact(length)

    def close(self) -> None:
        self.sock.close()


def docker(*args: str, capture: bool = False) -> str:
    result = subprocess.run(
        ["docker", *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else ""


def wait_for_port(
    container: str,
    container_port: int,
    basic_auth: BasicAuth | None = None,
) -> int:
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            mapping = docker("port", container, f"{container_port}/tcp", capture=True)
            port = int(mapping.rsplit(":", 1)[1])
            with socket.create_connection(("127.0.0.1", port), timeout=1) as probe:
                probe.settimeout(1)
                if container_port == 7682:
                    authorization = (
                        f"Authorization: {_basic_authorization(basic_auth)}\r\n"
                        if basic_auth is not None
                        else ""
                    )
                    probe.sendall(
                        (
                            "GET / HTTP/1.1\r\n"
                            "Host: 127.0.0.1\r\n"
                            f"{authorization}"
                            "Connection: close\r\n\r\n"
                        ).encode("ascii")
                    )
                    status = probe.recv(64).split(b"\r\n", 1)[0]
                    ready = status.startswith((b"HTTP/1.1 200 ", b"HTTP/1.0 200 "))
                elif container_port == 22:
                    ready = probe.recv(16).startswith(b"SSH-")
                elif container_port == 6080:
                    probe.sendall(
                        b"GET /vnc.html HTTP/1.1\r\n"
                        b"Host: 127.0.0.1\r\n"
                        b"Connection: close\r\n\r\n"
                    )
                    status = probe.recv(64).split(b"\r\n", 1)[0]
                    ready = status.startswith((b"HTTP/1.1 200 ", b"HTTP/1.0 200 "))
                else:
                    ready = True
                if ready:
                    return port
            time.sleep(0.25)
        except (OSError, ValueError, subprocess.CalledProcessError):
            time.sleep(0.25)
    raise RuntimeError(
        f"container port {container_port} did not become reachable on its published port"
    )


def run_command_on_socket(
    ws: WebSocket, marker: str, expected_user: str | None = None
) -> None:
    if expected_user is None:
        command = f"printf '{marker}\\n'"
        expected = marker
    else:
        command = f"printf '{marker}:'; id -un"
        expected = f"{marker}:{expected_user}"
    ws.send(f"0{command}\n".encode("ascii"))
    deadline = time.monotonic() + 15
    output = bytearray()
    while time.monotonic() < deadline:
        opcode, payload = ws.receive()
        if opcode == 0x8:
            raise RuntimeError("ttyd closed a normal terminal connection")
        if opcode == 0x9:
            ws.send(payload, opcode=0xA)
            continue
        if opcode == 0x2 and payload[:1] == b"0":
            output.extend(payload[1:])
            if expected.encode("ascii") in output:
                return
    raise RuntimeError(f"normal ttyd command produced no marker; output={output!r}")


def open_terminal(port: int, basic_auth: BasicAuth) -> WebSocket:
    ws = WebSocket("127.0.0.1", port, basic_auth=basic_auth)
    ws.send(_initialization_message(basic_auth))
    return ws


def run_command(
    port: int,
    marker: str,
    basic_auth: BasicAuth,
    expected_user: str | None = None,
) -> None:
    ws = open_terminal(port, basic_auth)
    try:
        run_command_on_socket(ws, marker, expected_user)
    finally:
        ws.close()


def expect_rejected(
    port: int,
    label: str,
    messages: list[tuple[bytes, int, bool]],
    expected_code: int,
    basic_auth: BasicAuth,
) -> None:
    ws = WebSocket("127.0.0.1", port, basic_auth=basic_auth)
    try:
        for payload, opcode, fin in messages:
            try:
                ws.send(payload, opcode=opcode, fin=fin)
            except OSError:
                # The peer may finish closing while a large frame is still in
                # sendall(). The subsequent normal-client probe distinguishes
                # this expected client reset from a server failure.
                return

        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                opcode, payload = ws.receive()
            except EOFError:
                return
            if opcode == 0x8:
                if len(payload) >= 2:
                    code = struct.unpack("!H", payload[:2])[0]
                    if code != expected_code:
                        raise RuntimeError(
                            f"{label} got close code {code}, expected {expected_code}"
                        )
                return
            if opcode == 0x9:
                ws.send(payload, opcode=0xA)
                continue

        raise RuntimeError(f"{label} was not rejected")
    finally:
        ws.close()


def expect_rejected_after_initialization(
    port: int,
    label: str,
    messages: list[tuple[bytes, int, bool]],
    expected_code: int,
    basic_auth: BasicAuth,
) -> None:
    expect_rejected(
        port,
        label,
        [(_initialization_message(basic_auth), 0x2, True), *messages],
        expected_code,
        basic_auth,
    )


def expect_cross_origin_rejected(port: int, basic_auth: BasicAuth) -> None:
    try:
        ws = WebSocket(
            "127.0.0.1",
            port,
            origin="https://attacker.invalid",
            basic_auth=basic_auth,
        )
    except (EOFError, OSError):
        return
    except RuntimeError as error:
        if "WebSocket upgrade failed" not in str(error):
            raise
        return
    ws.close()
    raise RuntimeError("cross-origin WebSocket upgrade was accepted")


def exercise_client_limit(port: int, expected_user: str, basic_auth: BasicAuth) -> None:
    clients: list[WebSocket] = []
    try:
        for index in range(16):
            ws = open_terminal(port, basic_auth)
            clients.append(ws)
            run_command_on_socket(ws, f"TTYD_CLIENT_{index + 1}_OK", expected_user)

        try:
            overflow = WebSocket("127.0.0.1", port, basic_auth=basic_auth)
        except (EOFError, OSError, RuntimeError):
            overflow = None
        if overflow is not None:
            overflow.close()
            raise RuntimeError("ttyd accepted a 17th simultaneous client")

        for index, ws in enumerate(clients, start=1):
            run_command_on_socket(ws, f"TTYD_CLIENT_{index}_STILL_OK", expected_user)
    finally:
        for ws in clients:
            ws.close()

    # LWS close callbacks are asynchronous; allow their client-count updates
    # to settle, then prove capacity is released for a new student terminal.
    deadline = time.monotonic() + 10
    while True:
        try:
            run_command(
                port,
                "TTYD_CLIENT_CAPACITY_RELEASED_OK",
                basic_auth,
                expected_user,
            )
            break
        except (EOFError, OSError, RuntimeError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)
    print("PASS: 16 clients worked; the 17th was refused without disruption")


def exercise_attacks(port: int, expected_user: str, basic_auth: BasicAuth) -> None:
    attacks = [
        (
            "empty binary message",
            lambda: expect_rejected(
                port,
                "empty binary message",
                [(b"", 0x2, True)],
                1002,
                basic_auth,
            ),
        ),
        (
            "empty text message",
            lambda: expect_rejected(
                port,
                "empty text message",
                [(b"", 0x1, True)],
                1002,
                basic_auth,
            ),
        ),
        (
            "input before initialization",
            lambda: expect_rejected(
                port,
                "input before initialization",
                [(b"0id\n", 0x2, True)],
                1002,
                basic_auth,
            ),
        ),
        (
            "malformed initialization JSON",
            lambda: expect_rejected(
                port,
                "malformed initialization JSON",
                [(b'{"columns":80,"rows":', 0x2, True)],
                1007,
                basic_auth,
            ),
        ),
        (
            "invalid terminal dimensions",
            lambda: expect_rejected(
                port,
                "invalid terminal dimensions",
                [(b'{"columns":-1,"rows":"24"}', 0x2, True)],
                1007,
                basic_auth,
            ),
        ),
        (
            "missing initialization auth token",
            lambda: expect_rejected(
                port,
                "missing initialization auth token",
                [
                    (b'{"columns":80,"rows":24}', 0x2, True),
                    (b"0id\n", 0x2, True),
                ],
                1008,
                basic_auth,
            ),
        ),
        (
            "incorrect initialization auth token",
            lambda: expect_rejected(
                port,
                "incorrect initialization auth token",
                [
                    (
                        b'{"AuthToken":"invalid","columns":80,"rows":24}',
                        0x2,
                        True,
                    ),
                    (b"0id\n", 0x2, True),
                ],
                1008,
                basic_auth,
            ),
        ),
        (
            "malformed resize JSON",
            lambda: expect_rejected_after_initialization(
                port,
                "malformed resize JSON",
                [(b"1not-json", 0x2, True)],
                1007,
                basic_auth,
            ),
        ),
        (
            "unknown command",
            lambda: expect_rejected_after_initialization(
                port,
                "unknown command",
                [(b"9", 0x2, True)],
                1002,
                basic_auth,
            ),
        ),
        (
            "oversized fragmented input",
            lambda: expect_rejected_after_initialization(
                port,
                "oversized fragmented input",
                [
                    (b"0" + b"A" * (6 * 1024 * 1024), 0x2, False),
                    (b"B" * (5 * 1024 * 1024), 0x0, True),
                ],
                1009,
                basic_auth,
            ),
        ),
    ]

    run_command(port, "TTYD_BEFORE_ATTACKS_OK", basic_auth, expected_user)
    expect_cross_origin_rejected(port, basic_auth)
    run_command(port, "TTYD_AFTER_ORIGIN_ATTACK_OK", basic_auth, expected_user)
    print("PASS: cross-origin WebSocket upgrade was rejected")
    exercise_client_limit(port, expected_user, basic_auth)
    for index, (label, attack) in enumerate(attacks, start=1):
        attack()
        run_command(
            port,
            f"TTYD_AFTER_ATTACK_{index}_OK",
            basic_auth,
            expected_user,
        )
        print(f"PASS: {label} closed only its client")


def ssh_command(
    port: int,
    username: str,
    password: str,
    command: str,
    *,
    allocate_tty: bool = False,
) -> str:
    with tempfile.TemporaryDirectory(prefix="rd-ssh-e2e-") as directory:
        askpass = Path(directory) / "askpass"
        askpass.write_text("#!/bin/sh\nprintf '%s\\n' \"$E2E_SSH_PASSWORD\"\n")
        askpass.chmod(0o700)
        environment = os.environ.copy()
        environment.update(
            {
                "DISPLAY": ":0",
                "E2E_SSH_PASSWORD": password,
                "SSH_ASKPASS": str(askpass),
                "SSH_ASKPASS_REQUIRE": "force",
            }
        )
        arguments = [
            "ssh",
            *(["-tt"] if allocate_tty else []),
            "-p",
            str(port),
            "-o",
            "BatchMode=no",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "LogLevel=ERROR",
            "-o",
            "PreferredAuthentications=password",
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            f"{username}@127.0.0.1",
            command,
        ]
        result = subprocess.run(
            arguments,
            check=True,
            capture_output=True,
            env=environment,
            start_new_session=True,
            text=True,
            timeout=20,
        )
        return result.stdout


def run_ssh_command(port: int, username: str, password: str, marker: str) -> None:
    output = ssh_command(
        port,
        username,
        password,
        f"printf '{marker}:'; id -un; sudo -n id -u",
    )
    expected = f"{marker}:{username}"
    if expected not in output:
        raise RuntimeError(f"SSH command did not run as {username}: {output!r}")
    if output.splitlines()[-1:] != ["0"]:
        raise RuntimeError(f"passwordless sudo was unavailable: {output!r}")


def exercise_ssh_persistence(
    port: int, username: str, password: str
) -> tuple[str, str]:
    marker = f"PERSISTED_{uuid.uuid4().hex}"
    path = ".endpoint-persistence-e2e"
    ssh_command(port, username, password, f"printf '{marker}\\n' > ~/{path}")
    output = ssh_command(port, username, password, f"cat ~/{path}")
    if marker not in output:
        raise RuntimeError(f"file did not persist between SSH logins: {output!r}")
    print("PASS: file persisted between published SSH login sessions")
    return path, marker


def verify_ssh_persistence(
    port: int, username: str, password: str, path: str, marker: str
) -> None:
    output = ssh_command(
        port,
        username,
        password,
        f"cat ~/{path}; printf 'RESTART_SUDO:'; sudo -n id -u",
    )
    if marker not in output or "RESTART_SUDO:0" not in output:
        raise RuntimeError(
            f"restart lost the student file, identity, or sudo: {output!r}"
        )
    print("PASS: published SSH retained the same home and sudo after restart")


def _reverse_byte_bits(value: int) -> int:
    value = ((value & 0xF0) >> 4) | ((value & 0x0F) << 4)
    value = ((value & 0xCC) >> 2) | ((value & 0x33) << 2)
    return ((value & 0xAA) >> 1) | ((value & 0x55) << 1)


def _vnc_challenge_response(challenge: bytes, password: str) -> bytes:
    password_bytes = password.encode("latin-1")[:8].ljust(8, b"\0")
    key = bytes(_reverse_byte_bits(value) for value in password_bytes)
    # VNC authentication uses DES. DES-EDE with the same key in all three
    # positions is exactly DES, while avoiding reliance on a legacy openssl
    # command/provider being installed on the test host.
    encryptor = Cipher(TripleDES(key * 3), modes.ECB()).encryptor()
    response = encryptor.update(challenge) + encryptor.finalize()
    if len(response) != 16:
        raise RuntimeError("cipher returned an invalid VNC challenge response")
    return response


class _RawRFBTransport:
    def __init__(self, port: int) -> None:
        self.client = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.client.settimeout(15)

    def read_exact(self, size: int) -> bytes:
        data = bytearray()
        while len(data) < size:
            chunk = self.client.recv(size - len(data))
            if not chunk:
                raise EOFError("VNC server closed the raw TCP connection")
            data.extend(chunk)
        return bytes(data)

    def sendall(self, payload: bytes) -> None:
        self.client.sendall(payload)

    def close(self) -> None:
        self.client.close()


class _WebSocketRFBTransport:
    def __init__(self, port: int) -> None:
        self.websocket = WebSocket(
            "127.0.0.1",
            port,
            path="/websockify",
            subprotocol="binary",
        )
        self.websocket.sock.settimeout(15)
        self.buffer = bytearray()

    def read_exact(self, size: int) -> bytes:
        while len(self.buffer) < size:
            opcode, payload = self.websocket.receive()
            if opcode in (0x0, 0x2):
                self.buffer.extend(payload)
            elif opcode == 0x8:
                raise EOFError("noVNC WebSocket closed the RFB connection")
            elif opcode == 0x9:
                self.websocket.send(payload, opcode=0xA)
            elif opcode != 0xA:
                raise RuntimeError(
                    f"unexpected WebSocket opcode {opcode} in RFB stream"
                )
        result = bytes(self.buffer[:size])
        del self.buffer[:size]
        return result

    def sendall(self, payload: bytes) -> None:
        self.websocket.send(payload, opcode=0x2)

    def close(self) -> None:
        self.websocket.close()


def _exercise_vnc_desktop(
    client: _RawRFBTransport | _WebSocketRFBTransport,
    password: str,
    transport_name: str,
) -> None:
    read_exact = client.read_exact
    try:
        version = read_exact(12)
        if not version.startswith(b"RFB 003."):
            raise RuntimeError(f"invalid VNC protocol greeting: {version!r}")
        client.sendall(b"RFB 003.008\n")
        count = read_exact(1)[0]
        if count == 0:
            reason_size = struct.unpack("!I", read_exact(4))[0]
            raise RuntimeError(f"VNC rejected negotiation: {read_exact(reason_size)!r}")
        security_types = read_exact(count)
        if 2 not in security_types:
            raise RuntimeError(
                f"VNC password authentication unavailable: {security_types!r}"
            )
        client.sendall(b"\x02")
        challenge = read_exact(16)
        client.sendall(_vnc_challenge_response(challenge, password))
        result = struct.unpack("!I", read_exact(4))[0]
        if result != 0:
            reason_size = struct.unpack("!I", read_exact(4))[0]
            raise RuntimeError(
                f"VNC authentication failed: {read_exact(reason_size)!r}"
            )

        client.sendall(b"\x01")
        width, height = struct.unpack("!HH", read_exact(4))
        pixel_format = read_exact(16)
        name_size = struct.unpack("!I", read_exact(4))[0]
        desktop_name = read_exact(name_size)
        bytes_per_pixel = pixel_format[0] // 8
        if not width or not height or bytes_per_pixel not in (1, 2, 4):
            raise RuntimeError(
                f"invalid VNC desktop metadata: {width}x{height}, {pixel_format!r}"
            )

        # Request only the standard raw encoding, then sample a bounded region
        # and prove XFCE produced real, non-uniform framebuffer content.
        client.sendall(struct.pack("!BBHi", 2, 0, 1, 0))
        request_width = min(width, 640)
        request_height = min(height, 360)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            client.sendall(
                struct.pack("!BBHHHH", 3, 0, 0, 0, request_width, request_height)
            )
            while True:
                message_type = read_exact(1)[0]
                if message_type == 0:
                    rectangle_count = struct.unpack("!H", read_exact(3)[1:])[0]
                    break
                if message_type == 2:  # bell
                    continue
                if message_type == 3:  # server cut text
                    read_exact(struct.unpack("!I", read_exact(7)[3:])[0])
                    continue
                raise RuntimeError(f"unexpected VNC server message {message_type}")

            pixels = bytearray()
            for _ in range(rectangle_count):
                _x, _y, rect_width, rect_height, encoding = struct.unpack(
                    "!HHHHi", read_exact(12)
                )
                if encoding != 0:
                    raise RuntimeError(f"unexpected VNC rectangle encoding {encoding}")
                pixels.extend(read_exact(rect_width * rect_height * bytes_per_pixel))
            pixel_count = len(pixels) // bytes_per_pixel
            stride = max(1, pixel_count // 4096)
            samples = {
                bytes(pixels[index * bytes_per_pixel : (index + 1) * bytes_per_pixel])
                for index in range(0, pixel_count, stride)
            }
            if len(samples) > 1:
                print(
                    f"PASS: {transport_name} RFB authenticated and rendered "
                    f"{width}x{height} desktop {desktop_name!r}"
                )
                return
            time.sleep(0.25)
        raise RuntimeError("VNC framebuffer remained uniformly blank")
    finally:
        client.close()


def exercise_vnc_desktop(port: int, password: str) -> None:
    _exercise_vnc_desktop(_RawRFBTransport(port), password, "raw VNC")


def exercise_novnc_rfb(port: int, password: str) -> None:
    _exercise_vnc_desktop(
        _WebSocketRFBTransport(port),
        password,
        "noVNC /websockify WebSocket",
    )


def exercise_novnc_http(port: int) -> None:
    deadline = time.monotonic() + 10
    while True:
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/vnc.html", timeout=3
            ) as response:
                body = response.read(2 * 1024 * 1024)
                if response.status != 200 or b"noVNC" not in body:
                    raise RuntimeError(
                        f"noVNC entry point was invalid: status={response.status}, bytes={len(body)}"
                    )
            print("PASS: noVNC served its browser client through the published port")
            return
        except (OSError, urllib.error.URLError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


def assert_gui_contract(container: str, expected_username: str) -> None:
    username = docker(
        "exec",
        container,
        "cat",
        "/var/lib/remote-desktop/resolved-username",
        capture=True,
    )
    if username != expected_username:
        raise RuntimeError(
            f"resolved GUI username was {username!r}, expected {expected_username!r}"
        )
    user_id = docker("exec", container, "id", "-u", "--", username, capture=True)
    if not user_id.isdigit():
        raise RuntimeError(f"invalid resolved GUI uid: {user_id!r}")

    # Assert both the configured opt-outs and their effective process state. The
    # print applet can appear as either its launcher or its Python script.
    process_script = r"""
set -euo pipefail
uid=$1
username=$2
home=$(getent passwd -- "$username" | cut -d: -f6)

for process in xfwm4 xfce4-panel; do
  healthy=0
  while IFS= read -r pid; do
    state=$(awk '$1 == "State:" {print $2}' "/proc/$pid/status" 2>/dev/null) || continue
    case "$state" in Z|X|x|"") continue ;; esac
    healthy=1
    break
  done < <(pgrep -u "$uid" -x "$process" || true)
  if ((healthy == 0)); then
    echo "$process is not alive for $username" >&2
    exit 1
  fi
done

for desktop in \
  blueman.desktop \
  nm-applet.desktop \
  print-applet.desktop \
  xfce4-power-manager.desktop \
  xfce4-screensaver.desktop \
  xiccd.desktop; do
  grep -Fqx 'Hidden=true' "$home/.config/autostart/$desktop"
done

patterns=(
  '(^|/)blueman-applet([[:space:]]|$)'
  '(^|/)nm-applet([[:space:]]|$)'
  '(^|/)(system-config-printer-applet|system-config-printer/applet[.]py)([[:space:]]|$)'
  '(^|/)xfce4-power-manager([[:space:]]|$)'
  '(^|/)xfce4-screensaver([[:space:]]|$)'
  '(^|/)xiccd([[:space:]]|$)'
)
for pattern in "${patterns[@]}"; do
  if pgrep -u "$uid" -f "$pattern" >/dev/null; then
    echo "disabled GUI applet is running: $pattern" >&2
    exit 1
  fi
done
"""
    docker(
        "exec",
        container,
        "/bin/bash",
        "-c",
        process_script,
        "gui-contract",
        user_id,
        username,
    )

    # The production profile omits SYS_PTRACE, so even container root cannot
    # scrape another user's /proc/<pid>/environ on a ptrace_scope=1 host.
    # Discover the session bus by its user-owned Unix socket instead.
    dbus_sockets = docker(
        "exec",
        container,
        "/bin/bash",
        "-c",
        'for path in "/run/user/$1/bus" /tmp/dbus-*; do '
        '[[ -S "$path" && $(stat -c %u -- "$path") == "$1" ]] && printf "%s\\n" "$path"; '
        "done",
        "gui-contract",
        user_id,
        capture=True,
    ).splitlines()
    if not dbus_sockets:
        raise RuntimeError("XFCE session exposed no owned D-Bus socket")
    dbus_address = f"unix:path={dbus_sockets[0]}"
    compositing = docker(
        "exec",
        "--user",
        username,
        "--env",
        "DISPLAY=:0",
        "--env",
        f"XDG_RUNTIME_DIR=/run/user/{user_id}",
        "--env",
        f"DBUS_SESSION_BUS_ADDRESS={dbus_address}",
        container,
        "timeout",
        "5",
        "xfconf-query",
        "--channel",
        "xfwm4",
        "--property",
        "/general/use_compositing",
        capture=True,
    )
    if compositing.lower() != "false":
        raise RuntimeError(f"XFCE compositing was not disabled: {compositing!r}")
    print(
        "PASS: GUI identity, window manager, panel, compositing, and disabled "
        "applets matched the desktop contract"
    )


def run_username_case(image: str, supplied: str, expected: str) -> None:
    container = f"rd-username-e2e-{uuid.uuid4().hex[:12]}"
    try:
        docker(
            "run",
            "--detach",
            "--rm",
            "--name",
            container,
            "--publish",
            "127.0.0.1::7682",
            "--env",
            "ENABLE_SSH=0",
            "--env",
            "TLOG_ENABLED=0",
            "--env",
            f"CTFD_USERNAME={supplied}",
            "--env",
            "VNC_PASSWORD=userpw1",
            image,
        )
        credentials = (expected, "userpw1")
        port = wait_for_port(container, 7682, credentials)
        run_command(port, "TTYD_USERNAME_OK", credentials, expected)
        print(f"PASS: CTFD username {supplied!r} mapped to {expected!r}")
    finally:
        subprocess.run(
            ["docker", "stop", "--timeout", "5", container],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def exercise_published_endpoint_recording(image: str) -> None:
    """Prove a real published SSH PTY reaches the host-side transcript."""
    collector_script = (
        Path(__file__).resolve().parents[1]
        / "provisioning"
        / "tlog"
        / "rd_tlog_collector.py"
    )
    container = f"rd-tlog-endpoint-e2e-{uuid.uuid4().hex[:12]}"
    marker = f"TLOG_PUBLISHED_ENDPOINT_{uuid.uuid4().hex}"

    with tempfile.TemporaryDirectory(prefix="rd-tlog-endpoint-e2e-") as directory:
        state_dir = Path(directory) / "state"
        socket_path = Path(directory) / "log.sock"
        collector_log_path = Path(directory) / "collector.log"
        state_dir.mkdir()

        with collector_log_path.open("w+") as collector_log:
            collector = subprocess.Popen(
                [
                    sys.executable,
                    str(collector_script),
                    "--socket",
                    str(socket_path),
                    "--state-dir",
                    str(state_dir),
                ],
                stdout=collector_log,
                stderr=subprocess.STDOUT,
                text=True,
            )
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        if stat.S_ISSOCK(socket_path.stat().st_mode):
                            break
                    except FileNotFoundError:
                        pass
                    if collector.poll() is not None:
                        collector_log.seek(0)
                        raise RuntimeError(
                            "tlog collector exited before creating its socket: "
                            f"{collector_log.read()}"
                        )
                    time.sleep(0.1)
                else:
                    raise RuntimeError("tlog collector socket was not created")

                docker(
                    "run",
                    "--detach",
                    "--rm",
                    "--name",
                    container,
                    "--publish",
                    "127.0.0.1::22",
                    "--env",
                    "ENABLE_TTYD=0",
                    "--env",
                    "TLOG_ENABLED=1",
                    "--env",
                    "CTFD_USERNAME=tlog_endpoint",
                    "--env",
                    "VNC_PASSWORD=tlogpw1",
                    "--mount",
                    f"type=bind,src={socket_path},dst=/dev/log,readonly",
                    image,
                )
                port = wait_for_port(container, 22)
                output = ssh_command(
                    port,
                    "tlog_endpoint",
                    "tlogpw1",
                    f"printf '{marker}\\n'; sleep 1",
                    allocate_tty=True,
                )
                if marker not in output:
                    raise RuntimeError(
                        f"recorded SSH command did not produce its marker: {output!r}"
                    )

                transcript = state_dir / "sessions" / f"{container}.tlog.jsonl"
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    try:
                        if marker.encode("ascii") in transcript.read_bytes():
                            break
                    except FileNotFoundError:
                        pass
                    time.sleep(0.25)
                else:
                    collector_log.flush()
                    collector_log.seek(0)
                    raise RuntimeError(
                        f"published SSH marker was not recorded in {transcript}; "
                        f"collector output={collector_log.read()!r}"
                    )
            finally:
                subprocess.run(
                    ["docker", "stop", "--timeout", "5", container],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                collector.terminate()
                try:
                    collector.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    collector.kill()
                    collector.wait(timeout=5)

    print("PASS: published SSH PTY activity reached the host tlog transcript")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default="ctfd-remote-desktop:ttyd-test")
    args = parser.parse_args()
    container = f"rd-ttyd-e2e-{uuid.uuid4().hex[:12]}"
    try:
        docker(
            "run",
            "--detach",
            "--name",
            container,
            "--init",
            "--cap-drop",
            "ALL",
            "--cap-add",
            "CHOWN",
            "--cap-add",
            "SETUID",
            "--cap-add",
            "SETGID",
            "--cap-add",
            "FOWNER",
            "--cap-add",
            "DAC_OVERRIDE",
            "--cap-add",
            "NET_RAW",
            "--cap-add",
            "NET_BIND_SERVICE",
            "--cap-add",
            "AUDIT_WRITE",
            "--cap-add",
            "SYS_CHROOT",
            "--pids-limit",
            "4096",
            "--shm-size",
            "512m",
            "--publish",
            "127.0.0.1::7682",
            "--publish",
            "127.0.0.1::22",
            "--publish",
            "127.0.0.1::5900",
            "--publish",
            "127.0.0.1::6080",
            "--env",
            "TLOG_ENABLED=0",
            "--env",
            "CTFD_USERNAME=root",
            "--env",
            "VNC_PASSWORD=ttydpw1",
            args.image,
        )
        ttyd_credentials = ("student_root", "ttydpw1")
        port = wait_for_port(container, 7682, ttyd_credentials)
        ssh_port = wait_for_port(container, 22)
        vnc_port = wait_for_port(container, 5900)
        novnc_port = wait_for_port(container, 6080)
        exercise_attacks(port, "student_root", ttyd_credentials)
        run_ssh_command(
            ssh_port,
            "student_root",
            "ttydpw1",
            "SSH_USERNAME_OK",
        )
        print("PASS: external SSH command ran as 'student_root'")
        persistence_path, persistence_marker = exercise_ssh_persistence(
            ssh_port, "student_root", "ttydpw1"
        )
        exercise_novnc_http(novnc_port)
        exercise_vnc_desktop(vnc_port, "ttydpw1")
        exercise_novnc_rfb(novnc_port, "ttydpw1")
        assert_gui_contract(container, "student_root")

        docker("restart", "--timeout", "10", container)
        port, ssh_port, vnc_port, novnc_port = (
            wait_for_port(container, 7682, ttyd_credentials),
            wait_for_port(container, 22),
            wait_for_port(container, 5900),
            wait_for_port(container, 6080),
        )
        run_command(
            port,
            "TTYD_AFTER_RESTART_OK",
            ttyd_credentials,
            "student_root",
        )
        verify_ssh_persistence(
            ssh_port,
            "student_root",
            "ttydpw1",
            persistence_path,
            persistence_marker,
        )
        exercise_novnc_http(novnc_port)
        exercise_vnc_desktop(vnc_port, "ttydpw1")
        exercise_novnc_rfb(novnc_port, "ttydpw1")
        assert_gui_contract(container, "student_root")
        print("PASS: all published container endpoints recovered after restart")
        running = docker(
            "inspect", "--format", "{{.State.Running}}", container, capture=True
        )
        if running != "true":
            raise RuntimeError("ttyd attack terminated the desktop container")
        print(f"PASS: ttyd remained usable after all adversarial inputs on port {port}")
    finally:
        failed = sys.exc_info()[0] is not None
        if failed:
            print(f"container logs for failed E2E run ({container}):", file=sys.stderr)
            subprocess.run(
                ["docker", "logs", container],
                check=False,
            )
        subprocess.run(
            ["docker", "stop", "--timeout", "5", container],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["docker", "rm", "--force", container],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    run_username_case(args.image, "123", "student_123")
    run_username_case(args.image, "!!!", "user")
    run_username_case(args.image, "line\nbreak", "line_break")
    run_username_case(
        args.image,
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        "abcdefghijklmnopqrstuvwxyz012345",
    )
    exercise_published_endpoint_recording(args.image)
    return 0


if __name__ == "__main__":
    sys.exit(main())
