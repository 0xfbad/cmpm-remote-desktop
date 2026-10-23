# remote desktop

kali xfce image for the ctfd remote desktop plugin

```sh
docker build --platform linux/amd64 -t ctfd-remote-desktop .
nix flake check
```

for the course ca, add `--secret id=ucsc_ca,src=ca.pem --build-arg UCSC_CA_CERT_SHA256=<der-sha256>` using an independently verified certificate fingerprint

put png jpeg or svg images in `assets/wallpapers` and rebuild, each new desktop selects one image and keeps it across reconnections

## runner provisioning

before setting `cgroup_parent=rd.slice`, run `sudo provisioning/compute/install.sh` and `sudo provisioning/compute/install.sh verify`, an unprovisioned slice has no memory limit and parent swap limits must permit session swap

for docker log caps and the io tripwire, run `sudo provisioning/storage/install.sh`, add `--restart-docker` only after draining every container on the runner

student writable storage uses a preallocated ext4 image through `workspace-runtime`, the optional `--with-storage-opts` installer mode instead configures classic `overlay2` on a separate block backed xfs mount with `prjquota` and `ftype=1`, that mode prevents docker from starting on ext4

if preparing that optional xfs data root, back up the selected device and run `sudo systemctl stop docker.socket docker.service` then `sudo provisioning/storage/xfs/make-data-root.sh /dev/disk/by-id/EXACT_DEVICE /var/lib/docker`, this formats the exact device and does not migrate existing docker data

the helper leaves monitoring timers masked, after docker is configured and verified on the intended mount run `sudo systemctl unmask --runtime rd-io-tripwire.timer rd-telemetry.timer` then `sudo systemctl enable --now rd-io-tripwire.timer rd-telemetry.timer`, use `--loopback FILE SIZE MOUNTPOINT` only for scratch tests

telemetry is written to `/var/lib/rd-telemetry/current.json`, its `ready` field combines compute storage network and transcript checks, the plugin does not use it for admission

## command capture and optional transcripts

bash and zsh hooks send completed command events through `jq` and `logger` to `/run/.session-init.sock`, the image collector writes `/var/log/.session-init/data.jsonl` for ctfd usage metrics, sends stop after one second if the collector stalls

`ENABLE_WORKSPACE_CONTEXT=1` also keeps a short zsh command history in `/var/lib/rd-workspace/commands.log` for workspace context

`rd-tlog` is a separate optional terminal output collector with no terminal notice, transcripts lack completed command counts and exit status, current managed desktops use the command journal above without `TLOG_ENABLED=1` and no host transcript socket mount, ctfd sessions need plugin code changes to add that variable and mount before terminal transcripts can record

if enabling terminal transcripts separately, back up an unused block device of at least 44 gib and run `sudo provisioning/tlog/make-store.sh /dev/disk/by-id/EXACT_DEVICE` then `sudo provisioning/tlog/install.sh`, the first command formats the exact device as xfs at `/var/lib/rd-tlog`

the transcript store must be separate from `/` with `nodev,nosuid,noexec`, mount `/run/rd-tlog/log.sock` into each guest at `/dev/log` and set `TLOG_ENABLED=1`, reject a missing socket before starting the guest

while recorded sessions run, restart only `rd-tlog-collector.service`, restarting `rd-tlog-collector.socket` leaves their mounted sockets unusable

terminal transcripts capture output and can be disabled by student root, defaults are 1 gib per session and 40 gib total with 60 day retention through `RD_TLOG_RETENTION_DAYS`, replay with `tlog-play -r file -i /var/lib/rd-tlog/sessions/<container-name>.tlog.jsonl`

for a local foreground transcript collector, run `sudo provisioning/tlog/install.sh --dev`, its socket is `/tmp/rd-tlog-dev/log.sock` and restarting it invalidates existing guest mounts

## optional network prototype

current managed desktops use the shared docker bridge, the plugin has no pool allocator, `provisioning/network` remains available as a pool prototype with no ssh client allowlist or complete ingress default deny, do not use it to protect untrusted sessions

for an isolated prototype lab, set a unique `RD_POOL_BASE` within `10.77.0.0/16` and `RD_POOL_SIZE`, set `RD_BIND_IP` to the runner private address and set `RD_PROXY_CIDRS` and `RD_RUNNER_PEER_CIDRS` to comma separated private `/32` hosts including the runner itself in the latter

copy `provisioning/network/nftables/rd-egress.nft.template` to `/etc/rd-egress.nft` and replace its site addresses, set `CTFD_HOST` `DNS_SERVERS` `NTP_SERVERS` `APT_MIRRORS` `CHALLENGE_TARGETS` and `BLOCKED_DST`, keep existing docker and firewall configuration for rollback

run `sudo -E provisioning/network/install.sh --egress-policy /etc/rd-egress.nft` then `sudo -E provisioning/network/net-pool.sh --verify`, address pool changes require a drained docker restart and challenge networks must stay outside `10.77.0.0/16`, use `--dev` only for isolated tests
