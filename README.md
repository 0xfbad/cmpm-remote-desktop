# CMPM 17 Remote Desktop

Browser-accessible Kali Linux desktop for the CMPM 17 security course, students connect via noVNC and get a full XFCE environment with pre-installed security tools and it's built to be spawned per-student by the CTFd challenge plugin

## Quick start

```bash
docker buildx build --pull --platform linux/amd64 --load -t ctfd-remote-desktop .
docker run --rm --init --shm-size=512m \
  -p 127.0.0.1:6080:6080 -p 127.0.0.1:7682:7682 -p 127.0.0.1:2222:22 \
  -e CTFD_USERNAME=testuser -e VNC_PASSWORD=testpass ctfd-remote-desktop
```

The image is large, so keep BuildKit's cache between normal builds. If disk
pressure requires an explicit cleanup, inspect it with `docker buildx du` and
prune old records on demand; pruning to 5 GB after every build forces the next
build to recreate layers larger than the retained cache.

CI may share a registry-backed BuildKit cache only from a protected runner
with authenticated access to a cache repository that untrusted branches
cannot write. Keep the mutable cache reference separate from immutable release
references; it accelerates a build but is never a promotion source:

```bash
cache_ref="${CI_REGISTRY_IMAGE:?protected registry login required}/cache:linux-amd64"
docker buildx build \
  --cache-from "type=registry,ref=$cache_ref" \
  --cache-to "type=registry,ref=$cache_ref,mode=max,image-manifest=true,oci-mediatypes=true" \
  ...
```

Omit both flags for forks, merge-request runners, or any job without protected
registry credentials. Delete/reseed the cache after a suspected credential or
runner compromise; release acceptance always pulls the candidate by digest.

Runtime hosts require Docker Engine 25 or newer; the health check uses
`--start-interval` so fast successful boots do not wait for the normal interval.

- Desktop: `http://localhost:6080/vnc.html?autoconnect=true#password=testpass`
- Terminal: `http://localhost:7682`
- SSH: `ssh testuser@localhost -p 2222` (password: testpass)

The terminal's HTTP Basic credentials are also `testuser` / `testpass`.

The default build never learns trust from the live course endpoint. If the
course site uses a private CA, obtain that CA independently from the campus
PKI administrator and pin its DER SHA-256 fingerprint:

```bash
openssl x509 -in /secure/cmpm-course-ca.pem -outform DER | sha256sum
DOCKER_BUILDKIT=1 docker build --pull --platform linux/amd64 \
  --secret id=ucsc_ca,src=/secure/cmpm-course-ca.pem \
  --build-arg UCSC_CA_CERT_SHA256=<64-hex-fingerprint> \
  -t ctfd-remote-desktop .
```

Supplying only the secret or only the fingerprint fails the build. Supplying
neither leaves the normal public trust store in place and removes the private
certificate-install entry from Firefox's baked policy. In that mode, a course
homepage served only by private PKI correctly shows a trust error instead of
silently trusting a certificate observed over an unauthenticated connection.
The current course endpoint requires its private CA, so that no-secret mode is
for local development only. Production CI and the release recipe below fail
closed unless an operator provides the CA as a protected file secret and its
independently verified fingerprint.

## How it works

Single-stage container on a digest-pinned `kalilinux/kali-rolling` base with
four access methods: Xvnc provides a headless X server proxied through noVNC,
ttyd serves a browser terminal, and sshd provides direct SSH access. The XFCE
session runs under an unprivileged account with passwordless sudo. The account
name comes from `CTFD_USERNAME`, is converted to a valid Linux name, and is
persisted at `/var/lib/remote-desktop/resolved-username` for the CTFd plugin.

The startup script creates the account, configures the shared VNC/SSH
credential, starts every enabled service, and supervises them as one session.
If Xvnc, websockify, sshd, ttyd, or XFCE exits, the container shuts down instead
of remaining deceptively alive. SSH host keys and the D-Bus machine ID are
generated per container and survive a Docker restart, while separate sessions
never share them. The image health check follows the SSH/ttyd toggles and tests
the display, noVNC, desktop session, and enabled endpoints. `dumpcap` receives
only `CAP_NET_RAW` at build time, so packet capture works with the plugin's
least-privilege capability profile and startup never needs `SETFCAP`. ttyd also
requires the per-session username and password with HTTP Basic authentication;
this is defense in depth behind, not a replacement for, the authenticated CTFd
reverse-proxy route.

That supervision is deliberately fail-fast. Three consecutive runtime health
failures end the session, and the CTFd plugin creates session containers with
Docker `auto_remove`. Once the container exits, its writable layer is deleted
and cannot be recovered through Docker. Students must save durable work to an
approved external service; operators should treat the container filesystem as
disposable and choose a different lifecycle design if post-failure forensics
or writable-layer recovery is a requirement.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CTFD_USERNAME` | `user` | CTFd display name, sanitized to lowercase alphanumeric with underscores and used as the linux account name |
| `VNC_PASSWORD` | random 8 chars | Shared password for VNC auth, SSH login, and the Linux user account; must be 1-8 visible ASCII characters (`!` through `~`) with no colon (TigerVNC's protocol limit is 8 bytes). An explicitly empty value is rejected |
| `RESOLUTION` | `1920x1080` | VNC display resolution |
| `ENABLE_SSH` | unset (on) | Set to `0` to not start sshd at all; absent or any other value keeps it on |
| `ENABLE_TTYD` | unset (on) | Set to `0` to not start the ttyd web terminal; absent or any other value keeps it on |
| `MAX_LIFETIME` | unset | Optional positive lifetime in seconds. The absolute deadline persists across Docker restarts so a restart cannot reset the ceiling |
| `TLOG_ENABLED` | unset | Set to `1` to make `tlog-rec-session` the user's login shell, recording terminal output (never keystrokes) to `/dev/log`. Bind-mount the host collector socket to `/dev/log` or transcripts are dropped |
| `ENABLE_WORKSPACE_CONTEXT` | unset (off) | Set to `1` to create `/var/lib/rd-workspace` and enable zsh command capture to `commands.log` (TSV: epoch, exit code, duration ms, cwd, command; last 200 lines). Optional, not part of image contract 3 |
| `CTFD_URL` | unset | Public CTFd URL, used as the autologin cookie's domain and the Firefox homepage |
| `CTFD_COOKIE_NAME` | unset | CTFd session cookie name, usually `session` |
| `CTFD_COOKIE_VALUE` | unset | Signed session cookie value, injected into Firefox at startup |

## Ports

| Port | Service |
|---|---|
| 22 | SSH (OpenSSH) |
| 5900 | Raw VNC (TigerVNC) |
| 6080 | noVNC web client |
| 7682 | ttyd web terminal |

## File structure

```
Dockerfile
configs/
  startup.sh              entrypoint, user setup, vnc + sshd + ttyd + xfce launch
  zshrc                   appended to kali's default zshrc
  alacritty.toml          terminal colors, nerd font, shell config
  mimeapps.list           default application associations
  firefox/
    policies.json          enterprise policies (bookmarks, devtools, homepage)
    autoconfig.js          enables firefox.cfg
    firefox.cfg            lockPref overrides for stuff the policy engine misses
    distribution.ini       replaces kali's default bookmark toolbar
  xfce4/
    helpers.rc             default terminal set to alacritty
    xfconf/xfce-perchannel-xml/
      xfce4-panel.xml      panel layout and launchers
      xfce4-desktop.xml    wallpaper path
      xfce4-terminal.xml   fallback terminal config with nerd font
      xfwm4.xml            window manager defaults
      xsettings.xml        theme and icon settings
install/
  install-pwndbg.sh       pinned, checksummed release .deb
  install-bata24-gef.sh   pinned GEF source + pinned Python wheel
  install-rappel.sh       exact source commit + HEAD verification
  install-helix.sh        pinned, checksummed release archive
  install-zellij.sh       pinned, checksummed release archive
  install-nerd-font.sh    pinned, checksummed Nerd Font archive
  install-ttyd.sh         pinned source + locally verified protocol patch
  install-zsteg.sh        pinned, checksummed gem and runtime dependencies
assets/
  SlugSec-Community-Banner.png
```

## Dockerfile layers

Ordered by change frequency so rebuilds stay fast

1. **Desktop + VNC stack** -- kali-desktop-xfce, tigervnc, novnc, websockify, zsh, locales
2. **Security tools** -- ~80 apt packages covering reversing, exploitation, networking, debugging, Python libs, build tools, editors, terminal utilities
3. **Kali metapackages** -- kali-tools-web, kali-tools-forensics, kali-tools-crypto-stego, plus alacritty
4. **Manual installs** -- pwndbg, bata24-gef, rappel, helix, zellij, JetBrainsMono Nerd Font, ttyd, each as a separate `RUN` for caching
5. **Configs** -- optional fingerprint-pinned CA, Firefox policies, XFCE defaults, wallpaper, shell/terminal config, noVNC patch, entrypoint

The Kali base manifest and every manually downloaded artifact are pinned; all
manual downloads use HTTPS and are checksum-verified before installation.
Rappel additionally verifies the checked-out commit. Kali's rolling apt
repositories are still resolved at build time, so two uncached builds can have
different Debian package versions even with the same base digest. Preserve and
promote the tested image digest rather than rebuilding independently for each
runner. The current manual binaries are `linux/amd64`, so the production image
is intentionally built and tested only for `linux/amd64` even though the base
manifest contains other architectures.

## What's installed

Full package list is in the Dockerfile, highlights below

**Reversing** -- ghidra, radare2, rizin-cutter, imhex, binwalk, pwndbg, bata24-gef

**Exploitation** -- afl++, exploitdb, nasm, ropper, rappel, checksec, python3-pwntools

**Network** -- nmap, wireshark, termshark, tcpdump, socat, burpsuite, netcat

**Forensics/Stego** -- steghide, exiftool, foremost, autopsy, sqlmap, nikto, dirb

**Python** -- pwntools, scapy, flask, requests, pycryptodome (importable as both `Cryptodome` and `Crypto`)

**Editors** -- vim, neovim, helix, emacs-nox, nano, gedit, mousepad

**Terminal** -- alacritty with JetBrainsMono Nerd Font, zsh with Kali's defaults plus eza/zoxide/fzf, zellij, tmux

**Browsers** -- firefox-esr with course bookmarks and an optional independently supplied, fingerprint-pinned course CA; chromium

## Shell config

The zshrc is Kali's stock `newuser.zshrc.recommended` with our stuff appended at the end, so you get the full Kali experience (two-line prompt, syntax highlighting, completion) plus some extras

- `ls`/`ll`/`la`/`l` aliased to eza with nerd font icons
- `cd` replaced by zoxide so it does fuzzy directory matching
- fzf keybindings, ctrl+r for history search
- Navigation aliases like `..`, `...`, `....` and directory stack shortcuts `1` through `9`
- `cp` and `mv` aliased with `-i` so you don't accidentally clobber files

## Firefox

Enterprise policies set the homepage to the challenge server, add toolbar bookmarks for Challenges, SlugSec, and CyberChef, and clean up the new tab page. A course CA is imported only when the build receives both the `ucsc_ca` BuildKit secret and its independently verified `UCSC_CA_CERT_SHA256`; it is never scraped from the live TLS endpoint. Kali's default OffSec bookmarks get replaced by a stripped `distribution.ini`. There's also an autoconfig layer (`firefox.cfg`) that uses `lockPref` to force settings that the policy engine doesn't reliably apply, things like the sandbox warning, devtools tab visibility, and Firefox View

### Autologin

With `CTFD_URL` and `CTFD_COOKIE_VALUE` set (the CTFd plugin sets them per-user), startup.sh stages the cookie at `/tmp/ctfd_auth.json` and rewrites the homepage in policies.json to point at the same URL. Firefox's autoconfig reads the file on launch, calls `Services.cookies.add`, and deletes the staging file. Errors go to `/tmp/ctfd_inject.log`

## Build verification

Run the repository's fail-closed static and unit gate, then build once and
exercise the externally published endpoints that students actually use:

```bash
nix --extra-experimental-features 'nix-command flakes' flake check --print-build-logs
docker buildx build --check .
docker buildx build --pull --platform linux/amd64 --load -t ctfd-remote-desktop:candidate .
python3 tests/e2e-ttyd-websocket.py --image ctfd-remote-desktop:candidate
bash tests/smoke-connection-toggles.sh ctfd-remote-desktop:candidate
bash tests/smoke-tlog.sh ctfd-remote-desktop:candidate
bash tests/smoke-runtime-hardening.sh ctfd-remote-desktop:candidate
sudo bash tests/privileged-telemetry-e2e.sh
sudo bash tests/privileged-storage-e2e.sh
sudo bash tests/privileged-tlog-store-e2e.sh
sudo bash tests/privileged-network-e2e.sh
```

The ttyd E2E opens real WebSocket and SSH connections through Docker-published
ports; it does not use `docker exec` for the student flow. The GitLab
`image-and-network-e2e` job runs a local daemon in the privileged job namespace
so localhost ports and collector bind mounts are real. It is a required manual
production gate because ordinary shared runners cannot safely run these tests.

For a registry release, build and push one commit-addressed candidate with
BuildKit's SBOM and maximal provenance. Configure the registry to reject
overwrites of `candidate-*` and release tags. The dirty-tree check prevents a
commit-looking tag from containing uncommitted or untracked source. Pull and
test the exact digest reported by Buildx, then promote that same manifest—never
rebuild after testing:

```bash
set -Eeuo pipefail

repository=registry.example.edu/cmpm17/remote-desktop
release_tag=${RELEASE_TAG:?export RELEASE_TAG to a new immutable release tag}
course_ca=${UCSC_CA_CERT_PATH:?path to the independently obtained course CA PEM}
course_ca_sha256=${UCSC_CA_CERT_SHA256:?independently verified DER SHA-256}
test -r "$course_ca"
commit=$(git rev-parse --verify HEAD)
build_created=$(git show -s --format=%cI "$commit")
candidate="${repository}:candidate-${commit}"
metadata_file=$(mktemp)

if [[ -n $(git status --porcelain=v1 --untracked-files=all) ]]; then
  git status --short
  echo "refusing to release a dirty or untracked worktree" >&2
  exit 1
fi

BUILDX_GIT_CHECK_DIRTY=1 docker buildx build \
  --pull --platform linux/amd64 \
  --secret "id=ucsc_ca,src=$course_ca" \
  --build-arg "UCSC_CA_CERT_SHA256=$course_ca_sha256" \
  --build-arg "OCI_CREATED=$build_created" \
  --build-arg "OCI_REVISION=$commit" \
  --build-arg "OCI_VERSION=$release_tag" \
  --sbom=true --provenance=mode=max --push \
  --metadata-file "$metadata_file" \
  --tag "$candidate" .

candidate_digest=$(jq -er '
  ."containerimage.digest"
  | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))
' "$metadata_file")
candidate_by_digest="${repository}@${candidate_digest}"
test_tag="ctfd-remote-desktop:tested-${commit:0:12}"

# Pull and tag only the immutable object. The four image acceptance tests use
# the digest reference explicitly, so a concurrently moved tag cannot alter it.
docker pull --platform linux/amd64 "$candidate_by_digest"
candidate_image_id=$(docker image inspect \
  "$candidate_by_digest" --format '{{.Id}}')
docker tag "$candidate_image_id" "$test_tag"
candidate_labels=$(docker image inspect \
  "$candidate_by_digest" --format '{{json .Config.Labels}}')
jq -e --arg created "$build_created" --arg revision "$commit" \
  --arg version "$release_tag" --arg ca_sha256 "$course_ca_sha256" '
    .["org.opencontainers.image.created"] == $created and
    .["org.opencontainers.image.revision"] == $revision and
    .["org.opencontainers.image.version"] == $version and
    .["edu.ucsc.ctfd-remote-desktop.course-ca-sha256"] == $ca_sha256 and
    .["edu.ucsc.ctfd-remote-desktop.contract"] == "3"
  ' <<<"$candidate_labels" >/dev/null
docker run --rm --env EXPECTED_CA_SHA256="$course_ca_sha256" \
  --entrypoint /bin/bash "$candidate_by_digest" -c '
    actual=$(openssl x509
      -in /usr/local/share/ca-certificates/cmpm-sec-01.crt -outform DER |
      sha256sum | awk "{print \$1}")
    test "$actual" = "$EXPECTED_CA_SHA256"
  '
docker run --rm --entrypoint curl "$candidate_by_digest" \
  --fail --silent --show-error --max-time 20 --output /dev/null \
  https://cmpm-sec-01.acad.ucsc.edu/
python3 tests/e2e-ttyd-websocket.py --image "$candidate_by_digest"
bash tests/smoke-connection-toggles.sh "$candidate_by_digest"
bash tests/smoke-tlog.sh "$candidate_by_digest"
bash tests/smoke-runtime-hardening.sh "$candidate_by_digest"

docker buildx imagetools create \
  --tag "${repository}:${release_tag}" \
  "$candidate_by_digest"

promoted_digest=$(docker buildx imagetools inspect \
  "${repository}:${release_tag}" --format '{{json .Manifest}}' \
  | jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))')
test "$promoted_digest" = "$candidate_digest"
printf 'candidate=%s\nrelease=%s@%s\nmetadata=%s\n' \
  "$candidate_by_digest" "$repository" "$promoted_digest" "$metadata_file"
```

### Candidate measurements

Continue in the same Bash shell and record these measurements for the pulled
candidate on a representative runner. They are reported observations, not
hard-coded release thresholds: archive them with the image digest and compare
like-for-like runner hardware and settings over time before deciding what
regression budgets are realistic.

```bash
: "${candidate_by_digest:?run the registry candidate steps first}"
: "${test_tag:?run the registry candidate steps first}"
: "${commit:?run the registry candidate steps first}"
metric_container="rd-candidate-metrics-${commit:0:12}-$$"
metric_caps=(
  --cap-drop ALL
  --cap-add CHOWN
  --cap-add SETUID
  --cap-add SETGID
  --cap-add FOWNER
  --cap-add DAC_OVERRIDE
  --cap-add NET_RAW
  --cap-add NET_BIND_SERVICE
  --cap-add AUDIT_WRITE
  --cap-add SYS_CHROOT
)
metric_cleanup() {
  docker rm -f "$metric_container" >/dev/null 2>&1 || true
}
trap metric_cleanup EXIT

printf 'local_uncompressed_content_size_bytes=%s\n' \
  "$(docker image inspect "$test_tag" --format '{{.Size}}')"

# Sum the compressed layer descriptor sizes for the runnable linux/amd64
# manifest. A candidate with attestations is an OCI index, so select the real
# platform manifest rather than accidentally counting unknown/unknown
# attestation manifests.
candidate_manifest_json=$(docker buildx imagetools inspect \
  --raw "$candidate_by_digest")
if jq -e '.layers | type == "array"' \
  <<<"$candidate_manifest_json" >/dev/null; then
  runnable_manifest_json=$candidate_manifest_json
else
  runnable_manifest_digest=$(jq -er '
    [.manifests[]
      | select(.platform.os == "linux"
        and .platform.architecture == "amd64")][0].digest
  ' <<<"$candidate_manifest_json")
  runnable_manifest_json=$(docker buildx imagetools inspect --raw \
    "${repository}@${runnable_manifest_digest}")
fi
printf 'registry_compressed_layer_bytes=%s\n' \
  "$(jq -er '[.layers[].size] | add' <<<"$runnable_manifest_json")"

metric_started_ns=$(python3 -c 'import time; print(time.monotonic_ns())')
docker run --detach --name "$metric_container" --init \
  --shm-size=512m --pids-limit=4096 "${metric_caps[@]}" \
  --env CTFD_USERNAME=metrics --env VNC_PASSWORD=metric01 \
  "$candidate_by_digest" >/dev/null

metric_deadline=$((SECONDS + 180))
until docker exec "$metric_container" \
  /usr/local/bin/remote-desktop-healthcheck >/dev/null 2>&1; do
  if [[ $(docker inspect --format '{{.State.Running}}' \
    "$metric_container" 2>/dev/null) != true ]]; then
    docker logs "$metric_container" >&2 || true
    exit 1
  fi
  if ((SECONDS >= metric_deadline)); then
    docker logs "$metric_container" >&2 || true
    echo "candidate did not become ready within 180 seconds" >&2
    exit 1
  fi
  sleep 0.25
done
metric_ready_ns=$(python3 -c 'import time; print(time.monotonic_ns())')
python3 -c '
import sys
print(f"cold_ready_seconds={(int(sys.argv[2]) - int(sys.argv[1])) / 1e9:.3f}")
' "$metric_started_ns" "$metric_ready_ns"

# Let post-start activity settle, then report process count, aggregate process
# RSS, cgroup-v2 memory.current and pids.current, and the exact bytes retained
# for the four Nerd Font files.
sleep 10
read -r idle_process_count idle_rss_bytes < <(
  docker top "$metric_container" -eo pid,rss \
    | awk 'NR > 1 { count++; total += $2 } END { printf "%d %.0f\n", count, total * 1024 }'
)
font_bytes=$(docker exec "$metric_container" bash -c '
  find /usr/share/fonts/truetype/jetbrains-mono-nerd \
    -maxdepth 1 -type f -name "*.ttf" -printf "%s\n" \
    | awk "{ total += \$1 } END { printf \"%.0f\", total }"
')
cgroup_memory_current_bytes=$(docker exec "$metric_container" \
  cat /sys/fs/cgroup/memory.current)
cgroup_pids_current=$(docker exec "$metric_container" \
  cat /sys/fs/cgroup/pids.current)
printf '%s\n' \
  "idle_process_count=$idle_process_count" \
  "idle_process_rss_bytes=$idle_rss_bytes" \
  "cgroup_memory_current_bytes=$cgroup_memory_current_bytes" \
  "cgroup_pids_current=$cgroup_pids_current" \
  "font_bytes=$font_bytes"
docker stop --timeout 5 "$metric_container" >/dev/null
metric_cleanup
trap - EXIT
```

Docker's local `.Size` reports the image's uncompressed content size, not the
incremental disk cost when layers are shared. The registry metric sums the
compressed runnable layer descriptors and excludes config and attestation
manifests. `memory.current` includes cgroup-accounted memory that process RSS
does not, so retain both runtime measurements. `idle_process_count` counts
process rows, while `pids.current` counts the tasks/threads charged against the
container's PID limit; do not use the former as a substitute for the latter.

`--pull` cannot move a digest-pinned base, and a cached `apt-get update` layer
does not refresh itself. On the planned refresh cadence, update the Kali base
digest deliberately, perform a clean candidate build, and repeat the complete
acceptance suite before promotion. Normal development builds should retain
their cache.

## KasmVNC experiment

`Dockerfile.kasm` and `configs/kasm/` are an experimental migration spike, not
a deployable alternative for the CTFd plugin. They currently expose KasmVNC's
TLS/basic-auth service on 6901 and do not implement the plugin contract on
6080/5900, ttyd, resolved-username handoff, restart-safe startup, health, or
maximum-lifetime enforcement. Keep production on the primary Dockerfile until
the plugin and its endpoint/authentication model are migrated together and the
same E2E suite passes.

Quarantine does not exempt the spike from repository supply-chain policy: its
Kali base is digest-pinned, the fixed KasmVNC 1.5.0 amd64 package is verified
against its release SHA-256 before installation, and the optional course CA
uses the same independently supplied BuildKit secret plus pinned fingerprint as
the primary image. It never scrapes trust from the live endpoint. The
`edu.ucsc.ctfd-remote-desktop.contract` label remains deliberately absent, so
the current plugin rejects it. `tests/kasm-quarantine-static.sh` fails if any of
those boundaries regress; passing that static check is not deployment
acceptance.

## Production runner integration

The current CTFd plugin has a shared Docker-network setting; it does not have a
network-pool size/allocation setting and does not consume the host telemetry
schema as a readiness contract. Per-session Docker-network isolation remains
deferred. The pool and policy material under `provisioning/network/` is future
infrastructure, not a feature to claim or configure in the current plugin.

For a contract-3 upgrade, apply and validate the updated nginx proxy config
first, deploy the compatible labeled image digest to every Docker context
second, and only then deploy/restart the strict contract-enforcing plugin.
Drain existing sessions when interruption is unacceptable, rescan every
context, and test the real authenticated proxy path before reopening
allocations. The checklist below assumes that ordering.

1. Build and fully test one `linux/amd64` candidate, then configure every Docker
   context with the exact promoted image digest rather than a mutable tag.
2. Give every runner context a private `pub_hostname` that the CTFd reverse
   proxy can route to. Docker currently chooses each published host port from
   40000–59999, but **do not allow that host-port range wholesale**. In Docker's
   forwarding path (`DOCKER-USER` with the iptables backend, or an equivalent
   nftables forward hook), DNAT has already changed the destination to the
   container port. Match that post-DNAT port and enforce this matrix: drop 5900
   from every external source; allow 6080 and 7682 only from the CTFd proxy;
   allow 22 only from explicitly intended SSH client ranges; drop every other
   new inbound session flow. Put these controls in the Docker forwarding path,
   not only the host `INPUT` chain. noVNC reaches VNC over the container's
   loopback interface, so denying externally forwarded 5900 does not break the
   browser desktop.
3. Keep CTFd `auth_request` authorization in front of noVNC and ttyd. ttyd's
   per-session HTTP Basic authentication is an additional upstream check, so
   the proxy integration must preserve the matching per-session credential; it
   is not a reason to expose port 7682 directly.
4. Set the plugin's `rd_network_name` to the one shared Docker network intended
   for current sessions. Treat containers on that network as mutually
   reachable unless a separately tested host firewall says otherwise; do not
   describe this as per-session isolation.
5. If writable-layer quotas are enabled, prepare a dedicated block-backed XFS
   Docker data root and verify `storage_opt` support by following
   `provisioning/storage/README.md`. If a systemd cgroup parent is enabled,
   install and verify the matching slice from `provisioning/compute/README.md`.
6. tlog storage and host telemetry are optional operator integrations, not
   settings the current plugin automatically wires up or accepts as a readiness
   document. Enable them only with the required `/dev/log` mount/environment
   integration and follow their own READMEs and verification checks.

Before enabling allocations, test the exact image digest through the real CTFd
proxy path and run the runner-specific storage, firewall, and cgroup checks that
match the features actually enabled at that site.

## Adding tools

For stuff in Kali repos just add it to the appropriate apt layer in the Dockerfile. For tools that need manual installation create a script in `install/` and add the corresponding `COPY`/`RUN` pair, keep each one as a separate `RUN` so Docker caches them independently

## Plugin compatibility

The CTFd plugin passes the student's display name as `CTFD_USERNAME` so the
container creates a personalized Linux account. It generates a random password
per container and passes it as `VNC_PASSWORD` for VNC, ttyd Basic auth, SSH, and
the Linux account, then builds authenticated proxy URLs for noVNC and ttyd plus
optional direct SSH connection details. The image contract exposes ports 22,
5900, 6080, and 7682 and accepts `CTFD_USERNAME`, `VNC_PASSWORD`, and
`RESOLUTION`. Reserved usernames (root, daemon, sshd, and similar) are replaced
with `user{id}` by the plugin, with a second collision check in the image. The
image reference is configurable in the plugin's admin settings; production
deployments should use the tested registry digest described above.
