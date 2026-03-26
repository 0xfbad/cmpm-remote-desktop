FROM kalilinux/kali-rolling
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# layer 1 - desktop and vnc stack
RUN apt-get update && apt-get install -y --no-install-recommends \
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
    && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8

# layer 2 - security tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        ghidra \
        radare2 \
        rizin-cutter \
        imhex \
        binwalk \
        afl++ \
        exploitdb \
        nasm \
        nmap \
        netcat-openbsd \
        tcpdump \
        wireshark \
        termshark \
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
        tmux \
        screen \
        fzf \
        eza \
        zoxide \
        zsh-syntax-highlighting \
        tealdeer \
        ranger \
        htop \
        btop \
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
        nftables \
        psmisc \
        rsync \
        file \
        man-db \
        firefox-esr \
        chromium \
        xdg-utils \
        feh \
        lolcat \
        mpv \
        nyancat \
        wordlists \
        fonts-jetbrains-mono \
        fonts-hack \
        libedit-dev \
        libimage-exiftool-perl \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/lib/python3/dist-packages/Cryptodome /usr/lib/python3/dist-packages/Crypto

# layer 3 - kali metapackages (web, forensics, stego)
RUN apt-get update && apt-get install -y --no-install-recommends \
        kali-tools-web \
        kali-tools-forensics \
        kali-tools-crypto-stego \
        alacritty \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# layer 4 - manual installs (each its own RUN for caching)

COPY install/install-pwndbg.sh /tmp/
RUN bash /tmp/install-pwndbg.sh && rm /tmp/install-pwndbg.sh

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

# layer 5 - configs (changes often, near end)

# ucsc ssl cert
RUN openssl s_client -connect cmpm-sec-01.acad.ucsc.edu:443 -showcerts </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > /usr/local/share/ca-certificates/cmpm-sec-01.pem \
    && update-ca-certificates

# firefox - policies, autoconfig, and override kali default bookmarks
COPY configs/firefox/policies.json /usr/lib/firefox-esr/distribution/policies.json
COPY configs/firefox/policies.json /usr/share/firefox-esr/distribution/policies.json
COPY configs/firefox/distribution.ini /usr/lib/firefox-esr/distribution/distribution.ini
COPY configs/firefox/autoconfig.js /usr/lib/firefox-esr/defaults/pref/autoconfig.js
COPY configs/firefox/firefox.cfg /usr/lib/firefox-esr/firefox.cfg
COPY configs/firefox/distribution.ini /usr/share/firefox-esr/distribution/distribution.ini

# xfce system-wide defaults
COPY configs/xfce4/ /etc/xdg/xfce4/

# wallpaper
COPY assets/SlugSec-Community-Banner.png /usr/share/backgrounds/SlugSec-Community-Banner.png

# shell config and mime defaults into skel so useradd -m copies them
RUN mkdir -p /etc/skel/.config
COPY configs/zshrc /tmp/custom-zshrc
RUN { cat /etc/zsh/newuser.zshrc.recommended 2>/dev/null; cat /tmp/custom-zshrc; } > /etc/skel/.zshrc \
    && rm /tmp/custom-zshrc
COPY configs/mimeapps.list /etc/skel/.config/mimeapps.list
RUN mkdir -p /etc/skel/.config/alacritty
COPY configs/alacritty.toml /etc/skel/.config/alacritty/alacritty.toml

# novnc reconnect patch - revert pr 1672 if needed
RUN sed -i "s/if (UI.getSetting('reconnect', false) === true && !UI.inhibitReconnect) {/else if (UI.getSetting('reconnect', false) === true \&\& !UI.inhibitReconnect) {/" \
    /usr/share/novnc/app/ui.js 2>/dev/null || true

# entrypoint
COPY --chmod=755 configs/startup.sh /startup.sh

EXPOSE 5900 6080

ENTRYPOINT ["/startup.sh"]
