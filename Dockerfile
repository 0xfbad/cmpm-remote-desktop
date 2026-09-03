# syntax=docker/dockerfile:1.23.0@sha256:2780b5c3bab67f1f76c781860de469442999ed1a0d7992a5efdf2cffc0e3d769
# check=error=true
FROM kalilinux/kali-rolling@sha256:ed99295a386abde2fb31e01a441b7c2800d9bcf19a20028b77d642c3ef068363
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH

# layer 1 - desktop and vnc stack
RUN if [[ $TARGETARCH != amd64 ]]; then \
        echo "this image currently supports only linux/amd64" >&2; \
        exit 1; \
    fi \
    && apt-get update && apt-get install -y \
        kali-desktop-xfce \
        xfce4-terminal \
        dbus-x11 \
        tigervnc-standalone-server \
        tigervnc-tools \
        novnc \
        websockify \
        sudo \
        curl \
        wget \
        git \
        zsh \
        locales \
        openssl \
        procps \
        x11-utils \
    && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && echo 'LANG=en_US.UTF-8' > /etc/default/locale \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# layer 2 - security tools
RUN apt-get update && apt-get install -y \
        ghidra \
        radare2 \
        rizin-cutter \
        imhex \
        binwalk \
        stegseek \
        afl++ \
        exploitdb \
        nasm \
        nmap \
        netcat-openbsd \
        tcpdump \
        wireshark \
        socat \
        burpsuite \
        gdb \
        strace \
        ltrace \
        checksec \
        python3-full \
        python3-pip \
        python3-venv \
        python3-pwntools \
        python3-scapy \
        python3-flask \
        python3-requests \
        python3-pycryptodome \
        ropper \
        ipython3 \
        gcc \
        g++ \
        make \
        cmake \
        qemu-system-x86 \
        vim \
        neovim \
        emacs-nox \
        nano \
        gedit \
        ed \
        hexedit \
        tmux \
        screen \
        fzf \
        eza \
        zoxide \
        ripgrep \
        sd \
        zsh-syntax-highlighting \
        tealdeer \
        ranger \
        htop \
        tree \
        jq \
        less \
        lsof \
        whois \
        traceroute \
        fastfetch \
        zip \
        unzip \
        gzip \
        tar \
        bzip2 \
        rar \
        openssh-client \
        openssh-server \
        nftables \
        psmisc \
        rsync \
        magic-wormhole \
        file \
        man-db \
        firefox-esr \
        chromium \
        xdg-utils \
        feh \
        lolcat \
        mpv \
        audacity \
        nyancat \
        wordlists \
        fonts-hack \
        libedit-dev \
        libimage-exiftool-perl \
        xxd \
        iputils-ping \
        libcap2-bin \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && if [[ ! -e /usr/lib/python3/dist-packages/Crypto && ! -L /usr/lib/python3/dist-packages/Crypto ]]; then \
        ln -s /usr/lib/python3/dist-packages/Cryptodome /usr/lib/python3/dist-packages/Crypto; \
    fi \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

# layer 3 - kali metapackages (web, forensics, stego)
RUN apt-get update && apt-get install -y \
        kali-tools-web \
        kali-tools-forensics \
        kali-tools-crypto-stego \
        alacritty \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

# layer 4 - manual installs (each its own RUN for caching)

COPY install/install-pwndbg.sh /tmp/
RUN bash /tmp/install-pwndbg.sh \
    && rm /tmp/install-pwndbg.sh \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

COPY install/install-bata24-gef.sh /tmp/
RUN bash /tmp/install-bata24-gef.sh && rm /tmp/install-bata24-gef.sh

COPY install/install-rappel.sh /tmp/
RUN bash /tmp/install-rappel.sh && rm /tmp/install-rappel.sh

COPY install/install-helix.sh /tmp/
RUN bash /tmp/install-helix.sh && rm /tmp/install-helix.sh

COPY install/install-zellij.sh /tmp/
RUN bash /tmp/install-zellij.sh && rm /tmp/install-zellij.sh

COPY install/install-nerd-font.sh /tmp/
RUN bash /tmp/install-nerd-font.sh && rm /tmp/install-nerd-font.sh

COPY install/install-ttyd.sh install/ttyd-zero-frame.patch /tmp/
RUN bash /tmp/install-ttyd.sh \
    && rm /tmp/install-ttyd.sh /tmp/ttyd-zero-frame.patch \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

COPY install/install-zsteg.sh /tmp/
RUN bash /tmp/install-zsteg.sh && rm /tmp/install-zsteg.sh

# session recorder (own layer so adding it doesn't invalidate the big apt layers)
RUN apt-get update && apt-get install -y tlog \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

# layer 5 - configs (changes often, near end)

# firefox - policies, autoconfig, and override kali default bookmarks
COPY configs/firefox/policies.json /usr/lib/firefox-esr/distribution/policies.json
COPY configs/firefox/policies.json /usr/share/firefox-esr/distribution/policies.json
COPY configs/firefox/distribution.ini /usr/lib/firefox-esr/distribution/distribution.ini
COPY configs/firefox/autoconfig.js /usr/lib/firefox-esr/defaults/pref/autoconfig.js
COPY configs/firefox/firefox.cfg /usr/lib/firefox-esr/firefox.cfg
COPY configs/firefox/distribution.ini /usr/share/firefox-esr/distribution/distribution.ini

# Optional private course CA. Never learn trust from the live TLS endpoint:
# operators must provide an independently obtained PEM as a BuildKit secret
# and pin its DER SHA-256 fingerprint. With neither input, private-CA policy is
# disabled and the browser relies on its normal public trust store.
ARG UCSC_CA_CERT_SHA256=""
RUN --mount=type=secret,id=ucsc_ca,required=false \
    set -Eeuo pipefail; \
    secret=/run/secrets/ucsc_ca; \
    if [[ -e "$secret" ]]; then \
        [[ "$UCSC_CA_CERT_SHA256" =~ ^[[:xdigit:]]{64}$ ]] \
            || { echo "UCSC_CA_CERT_SHA256 must be a 64-character fingerprint when ucsc_ca is supplied" >&2; exit 1; }; \
        actual="$(openssl x509 -in "$secret" -outform DER | sha256sum | awk '{print $1}')"; \
        [[ "$actual" == "${UCSC_CA_CERT_SHA256,,}" ]] \
            || { echo "ucsc_ca certificate fingerprint mismatch" >&2; exit 1; }; \
        openssl x509 -in "$secret" -outform PEM -out /usr/local/share/ca-certificates/cmpm-sec-01.crt; \
        update-ca-certificates; \
    else \
        [[ -z "$UCSC_CA_CERT_SHA256" ]] \
            || { echo "UCSC_CA_CERT_SHA256 was set but BuildKit secret ucsc_ca is missing" >&2; exit 1; }; \
        for policy in /usr/lib/firefox-esr/distribution/policies.json /usr/share/firefox-esr/distribution/policies.json; do \
            jq '.policies.Certificates.Install = []' "$policy" > "$policy.tmp"; \
            mv "$policy.tmp" "$policy"; \
        done; \
    fi

# xfce system-wide defaults
COPY configs/xfce4/ /etc/xdg/xfce4/

# wallpaper
COPY assets/SlugSec-Community-Banner.png /usr/share/backgrounds/SlugSec-Community-Banner.png

# shell config and mime defaults into skel so useradd -m copies them
RUN set -Eeuo pipefail; \
    mkdir -p /etc/skel/.config/alacritty /etc/skel/.config/autostart /etc/skel/.cache \
    && for desktop in \
        blueman.desktop \
        nm-applet.desktop \
        print-applet.desktop \
        xfce4-power-manager.desktop \
        xfce4-screensaver.desktop \
        xiccd.desktop; do \
        cp "/etc/xdg/autostart/$desktop" "/etc/skel/.config/autostart/$desktop"; \
        if grep -q '^Hidden=' "/etc/skel/.config/autostart/$desktop"; then \
            sed -i 's/^Hidden=.*/Hidden=true/' "/etc/skel/.config/autostart/$desktop"; \
        else \
            printf '\nHidden=true\n' >>"/etc/skel/.config/autostart/$desktop"; \
        fi; \
    done
COPY configs/zshrc /tmp/custom-zshrc
COPY configs/mimeapps.list /etc/skel/.config/mimeapps.list
COPY configs/alacritty.toml /etc/skel/.config/alacritty/alacritty.toml
RUN { cat /etc/zsh/newuser.zshrc.recommended 2>/dev/null; cat /tmp/custom-zshrc; } > /etc/skel/.zshrc \
    && rm /tmp/custom-zshrc \
    && zsh -c 'autoload -Uz compinit && compinit -d /etc/skel/.cache/zcompdump'

# noVNC reconnect patch - revert PR 1672 when the packaged source still needs
# it, accept an already-patched package, and fail on an unexpected source shape
RUN target=/usr/share/novnc/app/ui.js \
    && old="if (UI.getSetting('reconnect', false) === true && !UI.inhibitReconnect) {" \
    && new="else if (UI.getSetting('reconnect', false) === true && !UI.inhibitReconnect) {" \
    && if grep -Fq "$new" "$target"; then \
        :; \
    elif grep -Fq "$old" "$target"; then \
        sed -i "s/if (UI.getSetting('reconnect', false) === true && !UI.inhibitReconnect) {/else if (UI.getSetting('reconnect', false) === true \&\& !UI.inhibitReconnect) {/" "$target"; \
        grep -Fq "$new" "$target"; \
    else \
        echo "noVNC reconnect patch no longer matches $target" >&2; \
        exit 1; \
    fi

# session recording. no tlog group repair and no /run/tlog tmpfiles needed:
# writer=syslog uses no file paths, and /run/tlog must stay absent (its
# audit-sid lockfile would limit recording to the first terminal) - don't "fix"
COPY configs/tlog/tlog-rec-session.conf /etc/tlog/tlog-rec-session.conf
COPY --chmod=755 configs/setup-recording.sh /usr/local/lib/setup-recording.sh

# entrypoint
COPY --chmod=755 configs/startup.sh /startup.sh
COPY --chmod=755 configs/healthcheck.sh /usr/local/bin/remote-desktop-healthcheck

RUN dumpcap_path="$(command -v dumpcap)" \
    && setcap cap_net_raw=ep "$dumpcap_path" \
    && getcap "$dumpcap_path" | grep -Fqx "$dumpcap_path cap_net_raw=ep" \
    && test ! -s /etc/machine-id \
    && ! compgen -G '/etc/ssh/ssh_host_*_key*' >/dev/null

ARG OCI_CREATED=""
ARG OCI_REVISION=""
ARG OCI_VERSION="development"
LABEL org.opencontainers.image.title="CMPM 17 Remote Desktop" \
      org.opencontainers.image.description="Per-student Kali XFCE desktop for the CTFd remote desktop plugin" \
      org.opencontainers.image.source="https://git.ucsc.edu/intro-hacking-competitions/remote-desktop" \
      org.opencontainers.image.authors="CMPM 17 course staff" \
      org.opencontainers.image.vendor="University of California, Santa Cruz" \
      org.opencontainers.image.created="$OCI_CREATED" \
      org.opencontainers.image.revision="$OCI_REVISION" \
      org.opencontainers.image.version="$OCI_VERSION" \
      org.opencontainers.image.base.name="docker.io/kalilinux/kali-rolling" \
      org.opencontainers.image.base.digest="sha256:ed99295a386abde2fb31e01a441b7c2800d9bcf19a20028b77d642c3ef068363" \
      edu.ucsc.ctfd-remote-desktop.course-ca-sha256="$UCSC_CA_CERT_SHA256" \
      edu.ucsc.ctfd-remote-desktop.contract="3"

EXPOSE 22 5900 6080 7682

HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --start-interval=5s --retries=3 \
    CMD ["/usr/local/bin/remote-desktop-healthcheck"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/startup.sh"]
