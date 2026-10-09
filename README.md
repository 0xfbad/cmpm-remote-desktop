# remote-desktop

Per-student Kali XFCE desktop image for the CTFd remote desktop plugin.
One container per session: Xvnc + noVNC (6080), ttyd (7682), optional SSH
(22), all authenticated with the per-session `VNC_PASSWORD`.

## Build

```sh
docker build --platform linux/amd64 -t ctfd-remote-desktop .
# if adding a course ca, set --secret id=ucsc_ca,src=ca.pem and --build-arg UCSC_CA_CERT_SHA256=<der-sha256>
```

## Contract

The image carries `edu.ucsc.ctfd-remote-desktop.contract=3`, naming the
plugin-facing interface: ports 22/5900/6080/7682, the resolved-username
handoff, startup readiness/health behavior, and these env vars:

| var | purpose |
| --- | --- |
| `CTFD_USERNAME` | requested account name; the resolved name is handed back |
| `VNC_PASSWORD` | session password for VNC, noVNC, ttyd, and SSH |
| `RESOLUTION` | Xvnc geometry |
| `MAX_LIFETIME` | hard session cap, enforced across restarts |
| `CTFD_URL` | rewrites the Firefox homepage policy to the challenges page |
| `CTFD_COOKIE_NAME` / `CTFD_COOKIE_VALUE` | autologin cookie injected into Firefox |
| `ENABLE_SSH` / `ENABLE_TTYD` | connection toggles, default on |
| `TLOG_ENABLED` | session recording |

Any breaking change to that interface bumps the number; the plugin rejects
mismatches.

`ENABLE_WORKSPACE_CONTEXT=1` optionally captures recent shell commands to
`/var/lib/rd-workspace/commands.log` for the AI tutor; it is off by default
and not part of the contract.

Manual pages, GNU Info references, shell builtin help, the Wireshark user
guide, and cached `tldr` examples are available offline. Kali documentation
packages can differ from the installed tool version; use the tool's
built-in help for its current options. Zsh `run-help cd` opens its builtin
reference.
Some GUI documentation links, including Cutter and ImHex, still open online sites.

## Tests

`nix flake check` runs lint, static safety, and unit tests; the image and
host E2E suites live in `tests/` and run from `.gitlab-ci.yml`.
