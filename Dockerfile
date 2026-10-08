# syntax=docker/dockerfile:1.23.0@sha256:2780b5c3bab67f1f76c781860de469442999ed1a0d7992a5efdf2cffc0e3d769
# check=error=true
FROM node:22.20.0-bookworm-slim@sha256:b21fe589dfbe5cc39365d0544b9be3f1f33f55f3c86c87a76ff65a02f8f5848e AS ttyd-client
ADD --checksum=sha256:039dd995229377caee919898b7bd54484accec3bba49c118e2d5cd6ec51e3650 \
    https://github.com/tsl0922/ttyd/archive/refs/tags/1.7.7.tar.gz /tmp/ttyd.tar.gz
ADD --checksum=sha256:fed258a3f5ab5e1fe42a3cea0843b902d54dd58a982cfa75a9b43a51707d99e2 \
    https://registry.npmjs.org/@yarnpkg/cli-dist/-/cli-dist-3.6.3.tgz /tmp/yarn.tgz
RUN apt-get update && apt-get install -y --no-install-recommends patch \
    && rm -rf /var/lib/apt/lists/* \
    && tar -xzf /tmp/ttyd.tar.gz -C /tmp \
    && mkdir /tmp/yarn && tar -xzf /tmp/yarn.tgz -C /tmp/yarn
COPY install/ttyd-reconnect.patch /tmp/
WORKDIR /tmp/ttyd-1.7.7/html
RUN patch --batch --forward --fuzz=0 -d .. -p1 </tmp/ttyd-reconnect.patch \
    && node /tmp/yarn/package/bin/yarn.js install --immutable \
    && node /tmp/yarn/package/bin/yarn.js exec tsc --noEmit \
    && node /tmp/yarn/package/bin/yarn.js exec eslint \
        src/components/terminal/xterm/index.ts src/components/terminal/index.tsx \
    && node /tmp/yarn/package/bin/yarn.js build

FROM kalilinux/kali-rolling@sha256:ed99295a386abde2fb31e01a441b7c2800d9bcf19a20028b77d642c3ef068363
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH

RUN if [[ $TARGETARCH != amd64 ]]; then \
        echo "this image currently supports only linux/amd64" >&2; \
        exit 1; \
    fi \
    && apt-get update --error-on=any \
    && apt-get full-upgrade -y \
    && apt-get install -y \
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

RUN apt-get update && apt-get install -y \
        kali-tools-web \
        kali-tools-forensics \
        kali-tools-crypto-stego \
        alacritty \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

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

COPY --from=ttyd-client /tmp/ttyd-1.7.7/src/html.h /tmp/ttyd-html.h
COPY install/install-ttyd.sh install/ttyd-zero-frame.patch /tmp/
RUN bash /tmp/install-ttyd.sh \
    && rm /tmp/install-ttyd.sh /tmp/ttyd-zero-frame.patch /tmp/ttyd-html.h \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

COPY install/install-zsteg.sh /tmp/
RUN bash /tmp/install-zsteg.sh && rm /tmp/install-zsteg.sh

RUN apt-get update && apt-get install -y tlog \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*_key* /etc/machine-id /var/lib/dbus/machine-id

COPY install/install-ublock-origin.sh /tmp/
RUN bash /tmp/install-ublock-origin.sh && rm /tmp/install-ublock-origin.sh

COPY configs/firefox/policies.json /usr/lib/firefox-esr/distribution/policies.json
COPY configs/firefox/policies.json /usr/share/firefox-esr/distribution/policies.json
COPY configs/firefox/distribution.ini /usr/lib/firefox-esr/distribution/distribution.ini
COPY configs/firefox/autoconfig.js /usr/lib/firefox-esr/defaults/pref/autoconfig.js
COPY configs/firefox/firefox.cfg /usr/lib/firefox-esr/firefox.cfg
COPY configs/firefox/distribution.ini /usr/share/firefox-esr/distribution/distribution.ini

# if adding a course ca, get it from an independent source
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

COPY configs/xfce4/ /etc/xdg/xfce4/

COPY assets/SlugSec-Community-Banner.png /usr/share/backgrounds/SlugSec-Community-Banner.png

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
COPY --chmod=0755 configs/session-init/collector /usr/local/bin/remote-desktop-command-collector
COPY configs/session-init/hooks.zsh /usr/local/lib/remote-desktop-commands.zsh
COPY configs/session-init/hooks.bash /usr/local/lib/remote-desktop-commands.bash
COPY configs/mimeapps.list /etc/skel/.config/mimeapps.list
COPY configs/alacritty.toml /etc/skel/.config/alacritty/alacritty.toml
RUN { cat /etc/zsh/newuser.zshrc.recommended 2>/dev/null; cat /tmp/custom-zshrc; \
        printf '\n. /usr/local/lib/remote-desktop-commands.zsh\n'; } > /etc/skel/.zshrc \
    && printf '\n. /usr/local/lib/remote-desktop-commands.bash\n' >> /etc/bash.bashrc \
    && rm /tmp/custom-zshrc \
    && zsh -c 'autoload -Uz compinit && compinit -d /etc/skel/.cache/zcompdump'

# retain the reconnect behavior from before upstream change 1672
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

# /run/tlog must stay absent or only the first terminal records
COPY configs/tlog/tlog-rec-session.conf /etc/tlog/tlog-rec-session.conf
COPY --chmod=755 configs/setup-recording.sh /usr/local/lib/setup-recording.sh

COPY --chmod=755 configs/startup.sh /startup.sh
COPY --chmod=755 configs/healthcheck.sh /usr/local/bin/remote-desktop-healthcheck

# cap_net_admin is unavailable at runtime, nmap still needs cap_net_raw for --privileged
RUN dumpcap_path="$(command -v dumpcap)" \
    && setcap cap_net_raw=ep "$dumpcap_path" \
    && getcap "$dumpcap_path" | grep -Fqx "$dumpcap_path cap_net_raw=ep" \
    && setcap cap_net_raw,cap_net_bind_service=ep /usr/lib/nmap/nmap \
    && getcap /usr/lib/nmap/nmap \
       | grep -Fqx '/usr/lib/nmap/nmap cap_net_bind_service,cap_net_raw=ep' \
    && test ! -s /etc/machine-id \
    && ! compgen -G '/etc/ssh/ssh_host_*_key*' >/dev/null

COPY configs/tealdeer/config.toml /etc/skel/.config/tealdeer/config.toml
COPY install/prepare-caches.sh /tmp/prepare-caches.sh
# installers remove apt lists, prepare runtime caches after all installers
RUN bash /tmp/prepare-caches.sh && rm /tmp/prepare-caches.sh

ARG OCI_REVISION=""
# weekly rebuilds can change packages without changing the source revision
ARG OCI_CREATED=""
LABEL org.opencontainers.image.revision="$OCI_REVISION" \
      org.opencontainers.image.created="$OCI_CREATED" \
      edu.ucsc.ctfd-remote-desktop.contract="3"

EXPOSE 22 5900 6080 7682

HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --start-interval=5s --retries=3 \
    CMD ["/usr/local/bin/remote-desktop-healthcheck"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/startup.sh"]
