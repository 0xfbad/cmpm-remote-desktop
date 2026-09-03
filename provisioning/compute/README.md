# Compute-host provisioning (ctfd-remote-desktop)

> **PROTOTYPE / MANUAL OPERATOR INTEGRATION.** The current plugin can pass an
> explicitly configured `cgroup_parent`, but it does not automatically select
> `rd.slice`, consume this telemetry schema as a readiness contract, or emit the
> readiness events described by the prototype. Installing these files alone
> does not place a session in the slice.

These files provide host-side resource governance and a standalone telemetry
snapshot for runner hosts. To use only the supported slice portion with the
current plugin, first install and verify it on every target daemon, then set
`cgroup_parent=rd.slice` explicitly. Treat the telemetry consumer and aggregate
readiness policy as future integration work.

## Manual deployment must run `install.sh`

`install.sh` (install mode) copies the units, enables the slice and the
telemetry timer, applies sysctl, pre-pulls the pinned cgroup-placement probe, and
**ends with `verify`** — a hard gate that exits non-zero unless the slice
is loaded with a finite MemoryMax sized to ~90% of RAM, `system.slice`
carries the 2G reserve, `kernel.pid_max` is 131072, containers actually
land under `rd.slice`, and a fresh telemetry snapshot exists.

Why verification is mandatory when `cgroup_parent=rd.slice`: **an
unprovisioned host silently gets an unlimited implicitly-created `rd.slice`.**
docker with the systemd
cgroup driver auto-creates a missing slice when it sees
`--cgroup-parent rd.slice` — no error, no unit file, and no limits
(CPUWeight unset, MemoryMax=infinity; empirically confirmed on the dev
daemon). Sessions run with per-container limits only and the slice-level
backstops (memory ceiling, fork-bomb TasksMax, CPU/IO deprioritization) do
not exist. The operator gate is `install.sh verify`; the current plugin has no
`rd_slice_unconfigured` event or telemetry-readiness backstop.

## Contention policy: platform infra wins by design

challenge-containers stacks (and dockerd, sshd, CTFd itself) stay in
`system.slice`, which this config boosts to CPUWeight=500 / IOWeight=500
(vs rd.slice's 50/50) plus MemoryMin=2G. Under contention, platform
infrastructure — including challenge containers — outcompetes student
desktops **by design**. Student desktops are the expendable workload;
losing a desktop session is recoverable, losing dockerd or the challenge
stack is not.

## Files

| Source | Installed to |
| --- | --- |
| `systemd/rd.slice` | `/etc/systemd/system/rd.slice` |
| `systemd/system.slice.d/50-rd-host-reserve.conf` | `/etc/systemd/system/system.slice.d/` |
| `sysctl.d/90-rd-pidmax.conf` | `/etc/sysctl.d/` |
| `telemetry/rd-telemetry.sh` | `/usr/local/lib/rd-telemetry.sh` |
| `telemetry/rd-telemetry.service` | `/etc/systemd/system/` |
| `telemetry/rd-telemetry.timer` | `/etc/systemd/system/` |

`rd-telemetry.sh` snapshots PSI, memory.events, pids.events, io.stat and
memory usage for every `docker-*.scope` under `rd.slice` into
`/var/lib/rd-telemetry/current.json` (atomic tmp+rename) every 30s. The
timer-triggered service has ordering-only `After=docker.service` plus an
`ExecCondition` that requires Docker to already be active; it has no
`Requires=`/`Wants=` edge and checks before contacting docker.socket. Thus a
telemetry tick skips cleanly instead of starting a daemon that storage
maintenance deliberately stopped.

The historical variable name `READER_IMAGE` identifies the pinned throwaway
image used by `install.sh verify` to prove Docker can place a container under
the slice. It defaults to a verified multi-architecture BusyBox 1.37.0 digest
and is pre-pulled at install. A future telemetry reader could reuse it, but the
current plugin does not launch such a reader or ingest the snapshot.

The standalone prototype snapshot is versioned (`schema_version: 1`) and
fail-closed. Its `ready` value is true only when every named readiness boolean is true: the
complete compute tuple, atomic network policy, full pool and actual private
host bindings, proxy ACL, tlog socket and separate block-backed store, and
Docker overlay2 on XFS with project quotas. `configuration` carries the exact
contract and site network values. No current plugin decision is gated on this
value; integrating it requires an authenticated/fail-closed reader and tests
before it can be treated as a production readiness signal.

Note: "slice unconfigured" is detected from
`systemctl show rd.slice -p MemoryMax`, not from cgroup directory
existence — the `/sys/fs/cgroup/rd.slice` directory is absent whenever the
slice is merely inactive (zero sessions), which must not read as
unconfigured.

## Usage

```sh
sudo ./install.sh            # install + verify (image build path)
sudo ./install.sh verify     # verification only, non-zero exit on failure
```
