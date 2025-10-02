FROM alpine AS builder

RUN apk add --no-cache nix git
RUN cat >> /etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes
substituters = https://cache.nixos.org/
EOF

WORKDIR /workspace
COPY . .

RUN nix build --out-link /nix-result --print-build-logs

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y sudo curl git bash zsh wget gnupg2 && \
    wget -q -O - https://archive.kali.org/archive-key.asc | apt-key add - && \
    echo "deb http://http.kali.org/kali kali-rolling main contrib non-free" > /etc/apt/sources.list.d/kali.list && \
    echo "deb-src http://http.kali.org/kali kali-rolling main contrib non-free" >> /etc/apt/sources.list.d/kali.list && \
    apt-get update && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /nix /nix

COPY --chmod=755 <<'EOF' /docker-entrypoint.sh
#!/bin/sh -e

NIX_PROFILES_DIR=/nix/var/nix/profiles
NIX_PROFILE=${NIX_PROFILES_DIR}/security-env

# properly link the nix profile
ln -sfn /nix-result "$NIX_PROFILE"

export PATH="$NIX_PROFILE/bin:$PATH"
export XDG_DATA_DIRS="$NIX_PROFILE/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

if [ -n "$1" ]; then
    exec "$@"
else
    exec "$NIX_PROFILE/bin/desktop-service"
fi
EOF

COPY --from=builder /nix-result /nix-result

EXPOSE 5900 6080

ENTRYPOINT ["/docker-entrypoint.sh"]
