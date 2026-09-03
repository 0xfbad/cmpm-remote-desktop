# Remote-Desktop Host Network Provisioning

> **PROTOTYPE — NOT CURRENTLY INTEGRATED WITH THE CTFd PLUGIN.** The current
> plugin has only the shared `rd_network_name` setting. It has no
> `network_isolation` switch, pool-size setting, slot allocator, or pool event
> contract. Installing these files does not move sessions onto `rd-net-*`.

This is a standalone per-host prototype for a future single-tenant network
pool. Each host gets a fixed pool of pre-created bridge networks (`rd-net-00`
.. `rd-net-{N-1}`, bridges `rdb00`..) with pinned /28 subnets. The intended
future plugin integration would claim/release persistent slots without removing
networks at runtime; that allocation code is not present today.

Run `install.sh` as root on each host, with the per-runner variables below
exported (or edited in) first.

For an isolated prototype lab, copy `nftables/rd-egress.nft.template` to
`/etc/rd-egress.nft`, replace every documentation address, and then run
`sudo ./install.sh`. The non-dev installer mode validates and loads that policy;
`sudo ./install.sh --dev` is an even weaker host-gateway development mode.
Neither mode makes this production-ready. In particular, the template has no
site-defined SSH client allowlist and no final default-deny rule for every other
published container port. Do not use it to protect untrusted sessions or the
current shared-network plugin deployment.

The non-dev prototype install validates every input and the complete nft batch
before changing the host. It installs `/etc/rd-network-policy.nft` and enables
`rd-network-policy.service`, which restores both the bridge and IP tables in
one atomic `nft -f` transaction before Docker on every boot. A bad replacement
does not partially flush the active policy.

## Per-runner variables

| Variable | runner1 | runner2 | runner3 | Notes |
|---|---|---|---|---|
| `RD_POOL_BASE` | `10.77.0.0/20` | `10.77.16.0/20` | `10.77.32.0/20` | Start of this host's /28 pool space. Must be unique per runner. |
| `RD_POOL_SIZE` | `24` | `24` | `24` | Prototype slot count. There is no matching setting in the current plugin. |
| `RD_BIND_IP` | mgmt/WireGuard addr | mgmt/WireGuard addr | mgmt/WireGuard addr | Required in non-dev prototype mode: RFC1918 address assigned on this host; every pool network gets this `host_binding_ipv4`. |
| `RD_PROXY_CIDRS` | proxy IP(s) | proxy IP(s) | proxy IP(s) | Required in non-dev prototype mode: comma-separated exact RFC1918 `/32` source hosts allowed into published noVNC/ttyd ports. Include every CTFd/reverse-proxy egress IP. |
| `RD_RUNNER_PEER_CIDRS` | runner IPs | runner IPs | runner IPs | Required in non-dev prototype mode: comma-separated exact RFC1918 `/32` management addresses for this runner and every peer. The current `RD_BIND_IP/32` must be present. |

Egress template `define`s (`nftables/rd-egress.nft.template`) — per-site values
required by the non-dev prototype mode:

| Define | Value |
|---|---|
| `CTFD_HOST` | CTFd server IP(s) — the ONLY container-to-CTFd path (443/80) |
| `DNS_SERVERS` | Campus/site resolvers containers actually use |
| `NTP_SERVERS` | Site NTP |
| `APT_MIRRORS` | apt mirror IPs (80/443) |
| `BLOCKED_DST` | RFC1918 + runner LAN CIDRs + campus management CIDRs |

`PROXY_CIDRS` and `RUNNER_PEER_CIDRS` are deliberately not site-file defines;
the installer injects them from the mandatory environment values above into
the persisted transaction after strict host-address validation. Broad ranges,
including `0.0.0.0/0`, are rejected so an allowlist cannot silently become
world-accessible and a peer block cannot silently disable student internet.

`10.77.0.0/16` is always dropped before the challenge allowlist. This closes
both direct peer-network routing and the Docker published-port hairpin after
DNAT. Put every runner/public-management CIDR in `BLOCKED_DST` to close the
same route across runners. Internet destinations remain available, and
in-scope private challenge targets must be explicitly listed.

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

## Future admission-control coupling

An integrated implementation must enforce each context's `max_containers` as
less than or equal to the pool size and add durable slot allocation before this
can be enabled. The present plugin cannot emit `network_pool_exhausted`, claim
a slot, or safely release one, so do not infer capacity state from the existence
of these networks.

## Prototype runner-lab checklist (no SSH from dev; run per host)

- [ ] Full pool: export `RD_POOL_BASE`, `RD_POOL_SIZE`, and the runner's
      `RD_BIND_IP`; then `./net-pool.sh` and `./net-pool.sh --verify` pass.
      Rerun `tests/isolation-test.sh` with the non-dev prototype nft policy
      loaded.
- [ ] Egress ACL with real campus defines loaded: DNS/NTP/apt-mirror reachable
      from a session; other runners' LANs + campus mgmt + RFC1918 dropped;
      CTFd autologin (443/80 carve-out) and the sensei pull path work.
- [ ] `RD_BIND_IP=<management addr>` set and `pub_hostname` updated:
      standalone policy tests pass. From an untrusted off-host source, assert
      that raw VNC is denied, noVNC/ttyd are denied, and SSH follows the intended
      client allowlist. Do not implement this as a blanket 40000–59999 rule:
      after Docker DNAT, filter on container ports 5900, 6080, 7682, and 22 in
      the forwarding path. The supplied prototype template does not implement
      the SSH allowlist or a complete ingress default deny; those assertions
      require a separate site policy.
- [ ] `rd-net-sysctl.service` holds across a reboot AND across
      `systemctl restart docker` (the `PartOf=` coupling).
- [ ] `rd-network-policy.service` is enabled, active after reboot, and
      `systemctl reload rd-network-policy.service` preserves every `rd-*-v1`
      rule markers. A deliberately invalid candidate fails without changing
      the currently listed ruleset.
- [ ] `systemctl show docker.service -p Requires -p After` lists
      `rd-network-policy.service`; stopping/restarting `nftables.service`
      stops/reloads the policy before Docker may run.
- [ ] `sysctl net.bridge.bridge-nf-call-iptables` checked; `ss -tlnp`
      baseline recorded.
- [ ] Runner nft version accepts `iifname`/`ibrname "rdb*"` prefix wildcards at
      **runtime** (dev only parse-verified on nft 1.1.6).
- [ ] challenge-containers coexistence under load: subnet-less stacks land in
      `10.100.0.0/16`; audit challenge configs for subnets pinned inside
      `10.77.0.0/16` (they bypass the pool fence); concurrent create/teardown
      of both plugins.

## Future integration checklist

- [ ] `pub_hostname` per context points to the private management address
      configured as that runner's `RD_BIND_IP`.
- [ ] Plugin support for durable pool-slot admission/release is implemented and
      tested against worker crashes and reconciliation before any session uses
      an `rd-net-*` network.

## Prototype rollback

There is no `network_isolation` setting to toggle in the current plugin; it
always uses its configured shared `rd_network_name`. The unused pool networks
are inert, but applying or removing host firewall policy is an operator change
that must use the installer's validated transaction and site rollback plan.
