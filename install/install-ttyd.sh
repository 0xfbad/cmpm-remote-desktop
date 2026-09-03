#!/bin/bash
set -euo pipefail

TTYD_VERSION=1.7.7
TTYD_SOURCE_SHA256=039dd995229377caee919898b7bd54484accec3bba49c118e2d5cd6ec51e3650
SOURCE="/tmp/ttyd-${TTYD_VERSION}.tar.gz"
SOURCE_DIR="/tmp/ttyd-${TTYD_VERSION}"

# The release binary has remotely reachable WebSocket parsing crashes. Build
# the pinned release with our protocol-validation patch instead of downloading
# a mutable "latest" binary.
apt-get update
apt-get install -y --no-install-recommends \
  libjson-c-dev \
  libwebsockets-dev \
  libuv1-dev \
  pkg-config \
  patch

curl --proto '=https' --tlsv1.2 -fsSL \
  --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 15 \
  "https://github.com/tsl0922/ttyd/archive/refs/tags/${TTYD_VERSION}.tar.gz" \
  -o "$SOURCE"
echo "$TTYD_SOURCE_SHA256  $SOURCE" | sha256sum -c -
tar -xzf "$SOURCE" -C /tmp
patch --batch --forward --fuzz=0 -d "$SOURCE_DIR" -p1 </tmp/ttyd-zero-frame.patch
cmake -S "$SOURCE_DIR" -B "$SOURCE_DIR/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$SOURCE_DIR/build" --parallel "$(nproc)"
install -m 0755 "$SOURCE_DIR/build/ttyd" /usr/local/bin/ttyd

apt-get clean
rm -rf /var/lib/apt/lists/* "$SOURCE" "$SOURCE_DIR"
echo "installed patched, pinned ttyd ${TTYD_VERSION}"
