# Remote-Desktop Host Network Provisioning

Per-host provisioning for the single-tenant network pool used by the plugin's
`network_isolation` mode. Each host gets a fixed pool of pre-created bridge
networks (`rd-net-00` .. `rd-net-{N-1}`, bridges `rdb00`..) with pinned /28
subnets. Networks are never removed at runtime; the plugin claims/releases
slots in its own DB.

Run `install.sh` as root on each host, with the per-runner variables below
exported (or edited in) first.

## Per-runner variables

| Variable | runner1 | runner2 | runner3 | Notes |
|---|---|---|---|---|
| `RD_POOL_BASE` | `10.77.0.0/20` | `10.77.16.0/20` | `10.77.32.0/20` | Start of this host's /28 pool space. Must be unique per runner. |
| `RD_POOL_SIZE` | `24` | `24` | `24` | Slot count. Must equal the plugin's `network_pool_size` setting. |
| `RD_BIND_IP` | mgmt/WireGuard addr | mgmt/WireGuard addr | mgmt/WireGuard addr | Published-port bind address (`host_binding_ipv4`). Empty on dev = bind all. |

Egress template `define`s (`nftables/rd-egress.nft.template`) — per-site values,
required before prod, not before code lands:

| Define | Value |
|---|---|
| `CTFD_HOST` | CTFd server IP(s) — the ONLY container-to-CTFd path (443/80) |
| `DNS_SERVERS` | Campus/site resolvers containers actually use |
| `NTP_SERVERS` | Site NTP |
| `APT_MIRRORS` | apt mirror IPs (80/443) |
| `BLOCKED_DST` | RFC1918 + runner LAN CIDRs + campus management CIDRs |

## daemon.json notes (comments for `daemon.json.example`)

`daemon.json.example` is kept as pure JSON (JSON has no comments), so its
rationale lives here:

- `default-address-pools: [{"base": "10.100.0.0/16", "size": 24}]` fences every
  **subnet-less** `docker network create` — including challenge-containers'
  per-stack bridges — into `10.100.0.0/16`, keeping them out of the rd pool's
  `10.77.0.0/16` space.
- It does **NOT** constrain explicitly-pinned subnets. The rd pool pins its own
  `10.77.x.0/28` subnets, which is why it can live outside the fence — and why
  the rule below about pinned challenge subnets exists.
- `install.sh` jq-**merges** this key into `/etc/docker/daemon.json`. The
  storage provisioning owns `log-opts` in the same file — never overwrite
  unrelated keys.
- A dockerd restart is required for the pool fence to take effect (it only
  affects future subnet-less creates; the pinned rd networks are unaffected).

## Subnet-pinning rule (enforced by review, not by the daemon)

> challenge-containers stacks may pin subnets from challenge config; challenge
> configs MUST NOT pin subnets inside 10.77.0.0/16 — the daemon address-pool
> fence does not constrain explicitly pinned subnets.

Audit challenge configs for pinned subnets in `10.77.0.0/16` before each event.

## Feature-4 coupling

`max_containers` per host (Feature 4) must be **<= network_pool_size**.
Until Feature 4 lands, `network_pool_exhausted` events mostly signal slot
leaks rather than real capacity pressure — useful, do not silence them.

## Verify-on-runner checklist (no SSH from dev; run per host)

- [ ] Full pool: `RD_POOL_BASE=<per-runner> RD_POOL_SIZE=24 ./net-pool.sh`
      then `./net-pool.sh --verify` passes; rerun `tests/isolation-test.sh`.
- [ ] Egress ACL with real campus defines loaded: DNS/NTP/apt-mirror reachable
      from a session; other runners' LANs + campus mgmt + RFC1918 dropped;
      CTFd autologin (443/80 carve-out) and the sensei pull path work.
- [ ] `RD_BIND_IP=<management addr>` set and `pub_hostname` updated:
      orchestrator readiness poll OK; `nmap -p40000-59999` against the
      runners' public IPs from off-host AND same-host shows closed.
- [ ] `rd-net-sysctl.service` holds across a reboot AND across
      `systemctl restart docker` (the `PartOf=` coupling).
- [ ] `sysctl net.bridge.bridge-nf-call-iptables` checked; `ss -tlnp`
      baseline recorded.
- [ ] Runner nft version accepts `iifname`/`ibrname "rdb*"` prefix wildcards at
      **runtime** (dev only parse-verified on nft 1.1.6).
- [ ] challenge-containers coexistence under load: subnet-less stacks land in
      `10.100.0.0/16`; audit challenge configs for subnets pinned inside
      `10.77.0.0/16` (they bypass the pool fence); concurrent create/teardown
      of both plugins.

## Pre-prod adjacent-work checklist

- [ ] `pub_hostname` per context switched to the management address.
- [ ] Delete the `behind_proxy=false` branches (`src/routes.py:211-219` and
      `449-455`).
- [ ] `_direct_vnc_url` made proxy-only.

## Rollback

`network_isolation=False` reverts instantly to the shared `rd_network_name`
path; pooled sessions drain naturally (slot release is never gated on the
setting). Pool networks are inert while unused — no teardown needed.
