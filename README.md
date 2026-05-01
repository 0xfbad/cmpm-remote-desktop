# CMPM 17 Remote Desktop

Browser-accessible Kali Linux desktop for the CMPM 17 security course, students connect via noVNC and get a full XFCE environment with pre-installed security tools and it's built to be spawned per-student by the CTFd challenge plugin

## Quick start

```bash
docker build -t ctfd-remote-desktop .
docker builder prune --keep-storage=5G -f
docker run --rm -p 6080:6080 -p 7682:7682 -p 2222:22 -e CTFD_USERNAME=testuser -e VNC_PASSWORD=testpass ctfd-remote-desktop
```

The prune step trims the build cache after each build. The image is ~15GB so cache grows fast without it

- Desktop: `http://localhost:6080/vnc.html?autoconnect=true&password=testpass`
- Terminal: `http://localhost:7682`
- SSH: `ssh testuser@localhost -p 2222` (password: testpass)

## How it works

Single-stage container on `kalilinux/kali-rolling` with four access methods: Xvnc provides a headless X server proxied through noVNC for browser-based desktop, ttyd serves a browser-based terminal, and sshd provides direct SSH access. The XFCE session runs under an unprivileged account with passwordless sudo, the account name comes from the `CTFD_USERNAME` env var which gets sanitized down to a valid linux username (lowercased, non-alphanumeric chars replaced with underscores, truncated to 32 chars) so each student sees their own name in the terminal prompt and home directory

The startup script (`configs/startup.sh`) handles first-run setup, it creates the user account, sets the user password from `VNC_PASSWORD` (one credential for VNC, SSH, and display), sets dumpcap capabilities for packet capture, starts the VNC stack (Xvnc + websockify), sshd, and ttyd, then launches the desktop session. SSH is locked down with `PermitRootLogin no` and `AllowUsers` restricted to the session user. User home gets initialized from `/etc/skel/` which has the shell config, alacritty config, and MIME defaults baked in

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CTFD_USERNAME` | `user` | CTFd display name, sanitized to lowercase alphanumeric with underscores and used as the linux account name |
| `VNC_PASSWORD` | random 8 chars | Shared password for VNC auth, SSH login, and the linux user account |
| `RESOLUTION` | `1920x1080` | VNC display resolution |
| `SHELL_LOGGING` | unset | Set to `1` to enable session logging |
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
  install-pwndbg.sh       latest .deb from github releases
  install-bata24-gef.sh   gef.py + pip deps + wrapper script
  install-rappel.sh       build from source
  install-helix.sh        binary from github releases
  install-zellij.sh       binary from github releases
  install-nerd-font.sh    JetBrainsMono Nerd Font from github releases
  install-ttyd.sh         ttyd web terminal binary from github releases
assets/
  SlugSec-Community-Banner.png
```

## Dockerfile layers

Ordered by change frequency so rebuilds stay fast

1. **Desktop + VNC stack** -- kali-desktop-xfce, tigervnc, novnc, websockify, zsh, locales
2. **Security tools** -- ~80 apt packages covering reversing, exploitation, networking, debugging, Python libs, build tools, editors, terminal utilities
3. **Kali metapackages** -- kali-tools-web, kali-tools-forensics, kali-tools-crypto-stego, plus alacritty
4. **Manual installs** -- pwndbg, bata24-gef, rappel, helix, zellij, JetBrainsMono Nerd Font, ttyd, each as a separate `RUN` for caching
5. **Configs** -- SSL cert, Firefox policies, XFCE defaults, wallpaper, shell/terminal config, noVNC patch, entrypoint

Layers 1-3 rarely change and stay cached, layer 4 fetches latest releases at build time, layer 5 rebuilds in seconds when you tweak a config

## What's installed

Full package list is in the Dockerfile, highlights below

**Reversing** -- ghidra, radare2, rizin-cutter, imhex, binwalk, pwndbg, bata24-gef

**Exploitation** -- afl++, exploitdb, nasm, ropper, rappel, checksec, python3-pwntools

**Network** -- nmap, wireshark, termshark, tcpdump, socat, burpsuite, netcat

**Forensics/Stego** -- steghide, exiftool, foremost, autopsy, sqlmap, nikto, dirb

**Python** -- pwntools, scapy, flask, requests, pycryptodome (importable as both `Cryptodome` and `Crypto`)

**Editors** -- vim, neovim, helix, emacs-nox, nano, gedit, mousepad

**Terminal** -- alacritty with JetBrainsMono Nerd Font, zsh with Kali's defaults plus eza/zoxide/fzf, zellij, tmux

**Browsers** -- firefox-esr with course bookmarks and UCSC cert pre-loaded, chromium

## Shell config

The zshrc is Kali's stock `newuser.zshrc.recommended` with our stuff appended at the end, so you get the full Kali experience (two-line prompt, syntax highlighting, completion) plus some extras

- `ls`/`ll`/`la`/`l` aliased to eza with nerd font icons
- `cd` replaced by zoxide so it does fuzzy directory matching
- fzf keybindings, ctrl+r for history search
- Navigation aliases like `..`, `...`, `....` and directory stack shortcuts `1` through `9`
- `cp` and `mv` aliased with `-i` so you don't accidentally clobber files

## Firefox

Enterprise policies set the homepage to the challenge server, add toolbar bookmarks for Challenges, SlugSec, and CyberChef, import the UCSC SSL certificate, and clean up the new tab page. Kali's default OffSec bookmarks get replaced by a stripped `distribution.ini`. There's also an autoconfig layer (`firefox.cfg`) that uses `lockPref` to force settings that the policy engine doesn't reliably apply, things like the sandbox warning, devtools tab visibility, and Firefox View

### Autologin

With `CTFD_URL` and `CTFD_COOKIE_VALUE` set (the CTFd plugin sets them per-user), startup.sh stages the cookie at `/tmp/ctfd_auth.json` and rewrites the homepage in policies.json to point at the same URL. Firefox's autoconfig reads the file on launch, calls `Services.cookies.add`, and deletes the staging file. Errors go to `/tmp/ctfd_inject.log`

## Adding tools

For stuff in Kali repos just add it to the appropriate apt layer in the Dockerfile. For tools that need manual installation create a script in `install/` and add the corresponding `COPY`/`RUN` pair, keep each one as a separate `RUN` so Docker caches them independently

## Plugin compatibility

The CTFd plugin passes the student's display name as `CTFD_USERNAME` so the container creates a personalized linux account, generates a random password per container and passes it as `VNC_PASSWORD` (used for VNC, SSH, and the linux account), then builds URLs for noVNC, ttyd, and SSH. The plugin expects containers exposing ports 22, 5900, 6080, and 7682, accepting `CTFD_USERNAME`, `VNC_PASSWORD`, and `RESOLUTION` env vars. Reserved usernames (root, daemon, sshd, etc) are caught by the plugin and replaced with `user{id}`. The image is expected as `ctfd-remote-desktop:latest` by default, configurable in the plugin's admin settings
