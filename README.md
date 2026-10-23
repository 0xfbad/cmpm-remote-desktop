# remote desktop image

Kali Linux with XFCE, TigerVNC/noVNC, ttyd, and course tools.

```sh
docker build --platform linux/amd64 -t ctfd-remote-desktop .
nix flake check
```

`workspace-runtime` supplies private disk quotas, seccomp, and AppArmor when available.
Metrics use Bash/Zsh hooks, jq/logger, and a JSONL journal; CTFd imports it every 30 seconds.
Tlog is installed but inactive; `provisioning/tlog` needs plugin integration to record transcripts.
Optional tutor context uses `ENABLE_WORKSPACE_CONTEXT=1` and `/var/lib/rd-workspace/commands.log`.
Put PNG, JPEG, or SVG files in `assets/wallpapers`; each new desktop selects one.

Before using `cgroup_parent=rd.slice`, run `sudo provisioning/compute/install.sh` and `sudo provisioning/compute/install.sh verify`.
Parent swap limits must permit the intended session swap.
For log caps and the IO tripwire, run `sudo provisioning/storage/install.sh`; drain the runner before `--restart-docker`.
`provisioning/network` is an unused prototype, not complete session isolation; managed desktops use the shared Docker bridge.
For a course CA, add `--secret id=ucsc_ca,src=ca.pem --build-arg UCSC_CA_CERT_SHA256=<verified-der-sha256>`.
