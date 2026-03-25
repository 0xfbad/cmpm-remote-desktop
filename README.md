# CMPM 17 Remote Desktop

Browser-accessible Kali Linux desktop for the CMPM 17 security course, students connect via noVNC and get a full XFCE environment with pre-installed security tools and it's built to be spawned per-student by the CTFd challenge plugin

## Quick start

```bash
docker build -t ctfd-remote-desktop .
docker run -d -p 6080:6080 -e VNC_PASSWORD=testpass ctfd-remote-desktop
```

Then open `http://localhost:6080/vnc.html?autoconnect=true&password=testpass` in a browser, or omit the password param to get a VNC auth prompt

## How it works

Single-stage container on `kalilinux/kali-rolling` where Xvnc provides a headless X server, websockify bridges VNC to a WebSocket, and noVNC serves the browser client on port 6080. The XFCE session runs under an unprivileged account with passwordless sudo, the account name comes from the `CTFD_USERNAME` env var which gets sanitized down to a valid linux username (lowercased, non-alphanumeric chars replaced with underscores, truncated to 32 chars) so each student sees their own name in the terminal prompt and home directory

The startup script (`configs/startup.sh`) handles first-run setup, it creates the user account, sets dumpcap capabilities for packet capture, configures VNC authentication from the `VNC_PASSWORD` env var (or generates a random password if none is set), starts the VNC stack, and launches the desktop session. User home gets initialized from `/etc/skel/` which has the shell config, alacritty config, and MIME defaults baked in

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CTFD_USERNAME` | `user` | CTFd display name, sanitized to lowercase alphanumeric with underscores and used as the linux account name |
| `VNC_PASSWORD` | random 8 chars | VNC auth password, written to a passwd file and used by Xvnc's VncAuth |
| `RESOLUTION` | `1920x1080` | VNC display resolution |

## Ports

| Port | Service |
|---|---|
| 5900 | Raw VNC (TigerVNC) |
| 6080 | noVNC web client |

## File structure

```
Dockerfile
configs/
  startup.sh              entrypoint, user setup, vnc + xfce launch
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
assets/
  SlugSec-Community-Banner.png
```

## Dockerfile layers

Ordered by change frequency so rebuilds stay fast

1. **Desktop + VNC stack** -- kali-desktop-xfce, tigervnc, novnc, websockify, zsh, locales
2. **Security tools** -- ~80 apt packages covering reversing, exploitation, networking, debugging, Python libs, build tools, editors, terminal utilities
3. **Kali metapackages** -- kali-tools-web, kali-tools-forensics, kali-tools-crypto-stego, plus alacritty
4. **Manual installs** -- pwndbg, bata24-gef, rappel, helix, zellij, JetBrainsMono Nerd Font, each as a separate `RUN` for caching
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

## Adding tools

For stuff in Kali repos just add it to the appropriate apt layer in the Dockerfile. For tools that need manual installation create a script in `install/` and add the corresponding `COPY`/`RUN` pair, keep each one as a separate `RUN` so Docker caches them independently

## Plugin compatibility

The CTFd plugin passes the student's display name as `CTFD_USERNAME` so the container creates a personalized linux account, generates a random password per container and passes it as `VNC_PASSWORD`, then builds a direct URL with the password embedded as a query param so students auto-connect with no dialog. The plugin expects containers exposing ports 5900 and 6080, accepting `CTFD_USERNAME`, `VNC_PASSWORD`, and `RESOLUTION` env vars, and serving noVNC at `/vnc.html`, the plugin expects the image tagged as `ctfd-remote-desktop:latest` by default, which is configurable in the plugin's admin settings
