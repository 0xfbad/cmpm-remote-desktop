import ctypes
import hashlib
import json
import platform
from pathlib import Path
import struct
import sys

profile = Path(sys.argv[1])
output = Path(sys.argv[2])
assert platform.machine() == "x86_64"
assert (
    hashlib.sha256(profile.read_bytes()).hexdigest()
    == "63405c81b33f692155cd10d177e48239d891ed2ffb4f9f065f984dde768e3616"
)
policy = json.loads(profile.read_text())
capabilities = {
    "CAP_AUDIT_WRITE",
    "CAP_CHOWN",
    "CAP_DAC_OVERRIDE",
    "CAP_FOWNER",
    "CAP_KILL",
    "CAP_NET_BIND_SERVICE",
    "CAP_NET_RAW",
    "CAP_SETGID",
    "CAP_SETUID",
    "CAP_SYS_CHROOT",
}
lib = ctypes.CDLL("libseccomp.so.2", use_errno=True)
lib.seccomp_init.argtypes = [ctypes.c_uint32]
lib.seccomp_init.restype = ctypes.c_void_p
lib.seccomp_arch_resolve_name.argtypes = [ctypes.c_char_p]
lib.seccomp_arch_resolve_name.restype = ctypes.c_uint32
lib.seccomp_arch_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
lib.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
lib.seccomp_syscall_resolve_name.restype = ctypes.c_int
lib.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
lib.seccomp_release.argtypes = [ctypes.c_void_p]


class Comparison(ctypes.Structure):
    _fields_ = [
        ("arg", ctypes.c_uint32),
        ("op", ctypes.c_uint32),
        ("a", ctypes.c_uint64),
        ("b", ctypes.c_uint64),
    ]


lib.seccomp_rule_add_array.argtypes = [
    ctypes.c_void_p,
    ctypes.c_uint32,
    ctypes.c_int,
    ctypes.c_uint,
    ctypes.POINTER(Comparison),
]
context = lib.seccomp_init(0x50000 | policy.get("defaultErrnoRet", 1))
assert context
for architecture in ["x86", "x32"]:
    assert (
        lib.seccomp_arch_add(
            context, lib.seccomp_arch_resolve_name(architecture.encode())
        )
        == 0
    )
operators = {
    "SCMP_CMP_NE": 1,
    "SCMP_CMP_LT": 2,
    "SCMP_CMP_LE": 3,
    "SCMP_CMP_EQ": 4,
    "SCMP_CMP_GE": 5,
    "SCMP_CMP_GT": 6,
    "SCMP_CMP_MASKED_EQ": 7,
}
unknown = []
selected = []
for rule in policy["syscalls"]:
    include = rule.get("includes", {})
    exclude = rule.get("excludes", {})
    if include.get("caps") and not any(c in capabilities for c in include["caps"]):
        continue
    if exclude.get("caps") and any(c in capabilities for c in exclude["caps"]):
        continue
    if include.get("arches") and "amd64" not in include["arches"]:
        continue
    if "amd64" in exclude.get("arches", []):
        continue
    action = (
        0x7FFF0000
        if rule["action"] == "SCMP_ACT_ALLOW"
        else (0x50000 | rule.get("errnoRet", 1))
    )
    comparisons = (Comparison * len(rule.get("args", [])))(
        *[
            Comparison(
                arg["index"], operators[arg["op"]], arg["value"], arg.get("valueTwo", 0)
            )
            for arg in rule.get("args", [])
        ]
    )
    for name in rule["names"]:
        number = lib.seccomp_syscall_resolve_name(name.encode())
        if number == -1:
            unknown.append(name)
            continue
        rc = lib.seccomp_rule_add_array(
            context, action, number, len(comparisons), comparisons
        )
        assert rc == 0, (name, number, rc)
        selected.append(name)
assert not unknown, unknown
raw = output.with_suffix(".bpf")
with raw.open("wb") as target:
    assert lib.seccomp_export_bpf(context, target.fileno()) == 0
lib.seccomp_release(context)
data = raw.read_bytes()
assert len(data) % 8 == 0
lines = ["static const struct sock_filter guest_filter[] = {"]
for offset in range(0, len(data), 8):
    code, jt, jf, k = struct.unpack("HBBI", data[offset : offset + 8])
    lines.append("    {" + f"{code}, {jt}, {jf}, {k}" + "},")
lines.append("};")
output.write_text("\n".join(lines) + "\n")
output.with_suffix(".json").write_text(
    json.dumps(
        {
            "policy_sha256": hashlib.sha256(profile.read_bytes()).hexdigest(),
            "bpf_sha256": hashlib.sha256(data).hexdigest(),
            "capabilities": sorted(capabilities),
            "architectures": ["x86_64", "x86", "x32"],
            "instructions": len(data) // 8,
            "unknown_syscalls": unknown,
            "selected_rule_count": len(selected),
        },
        indent=2,
    )
    + "\n"
)
