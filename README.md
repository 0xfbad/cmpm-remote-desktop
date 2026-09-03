# remote-desktop

Per-student Kali XFCE desktop image for the CTFd remote desktop plugin.
One container per session: Xvnc + noVNC (6080), ttyd (7682), optional SSH
(22), all authenticated with the per-session `VNC_PASSWORD`.

## Build

```sh
docker build --platform linux/amd64 -t ctfd-remote-desktop .
# optional course CA: --secret id=ucsc_ca,src=ca.pem --build-arg UCSC_CA_CERT_SHA256=<der-sha256>
```

## Contract

The image carries `edu.ucsc.ctfd-remote-desktop.contract=3`, naming the
plugin-facing interface: ports 22/5900/6080/7682, the accepted env vars
(`CTFD_USERNAME`, `VNC_PASSWORD`, `RESOLUTION`, toggles, `MAX_LIFETIME`), the
resolved-username handoff, and startup readiness/health behavior. Any breaking
change to that interface bumps the number; the plugin rejects mismatches.

`ENABLE_WORKSPACE_CONTEXT=1` optionally captures recent shell commands to
`/var/lib/rd-workspace/commands.log` for the AI tutor; it is off by default
and not part of the contract.

## Tests

`nix flake check` runs lint, static safety, and unit tests; the image and
host E2E suites live in `tests/` and run from `.gitlab-ci.yml`.
