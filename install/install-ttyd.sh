#!/bin/bash
set -euo pipefail

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
amd64) TTYD_ARCH="x86_64" ;;
arm64) TTYD_ARCH="aarch64" ;;
*)
	echo "unsupported arch: $ARCH"
	exit 1
	;;
esac

LATEST=$(curl -fsSL "https://api.github.com/repos/tsl0922/ttyd/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+')
curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${LATEST}/ttyd.${TTYD_ARCH}" -o /usr/local/bin/ttyd
chmod +x /usr/local/bin/ttyd
echo "installed ttyd ${LATEST} (${TTYD_ARCH})"
