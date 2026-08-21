# Compute-host provisioning (ctfd-remote-desktop)

Host-side resource governance and telemetry for the runner hosts that
execute remote-desktop session containers. The plugin places every session
container under `rd.slice` via `cgroup_parent`; these files make that slice
actually mean something.

## The prod runner image build MUST run `install.sh`

`install.sh` (install mode) copies the units, enables the slice and the
telemetry timer, applies sysctl, pre-pulls the tier-2 reader image, and
**ends with `verify`** — a hard gate that exits non-zero unless the slice
is loaded with a finite MemoryMax sized to ~90% of RAM, `system.slice`
carries the 2G reserve, `kernel.pid_max` is 131072, containers actually
land under `rd.slice`, and a fresh telemetry snapshot exists.

Why this is a MUST and not a nicety: **an unprovisioned host silently gets
an unlimited implicitly-created `rd.slice`.** docker with the systemd
cgroup driver auto-creates a missing slice when it sees
`--cgroup-parent rd.slice` — no error, no unit file, and no limits
(CPUWeight unset, MemoryMax=infinity; empirically confirmed on the dev
daemon). Sessions run with per-container limits only and the slice-level
backstops (memory ceiling, fork-bomb TasksMax, CPU/IO deprioritization) do
not exist. The build-time gate is `install.sh verify`; the runtime backstop
is the plugin's `rd_slice_unconfigured` event, which only fires where the
telemetry timer is installed.

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
plugin's tier-2 host telemetry reads that file through a throwaway reader
container (`READER_IMAGE`, default `busybox:latest`, pre-pulled at install
so class-time reads never depend on hub reachability).

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
