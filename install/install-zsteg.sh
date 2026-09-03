#!/usr/bin/env bash
set -euo pipefail

ZSTEG_VERSION=0.2.14
ZSTEG_SHA256=761ee35a8512630606946187ed1a3150c6ab30dd5e32cefe48ebb2b874190f6f
IOSTRUCT_VERSION=0.7.0
IOSTRUCT_SHA256=e93f2ffea3b79a0e1045f0e0bd3f202368d89c53b692878e693cf50603bae49c
PRIME_VERSION=0.1.4
PRIME_SHA256=4d755ebf7c2994a6f3a3fee0d072063be3fff2d4042ebff6cd5eebd4747a225e
RAINBOW_VERSION=3.1.1
RAINBOW_SHA256=039491aa3a89f42efa1d6dec2fc4e62ede96eb6acd95e52f1ad581182b79bc6a
ZPNG_VERSION=0.4.6
ZPNG_SHA256=40f4629f7dac4864662fa5cdfe7b410cc4bc8e72e271d39551f084291e64246e

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

download_gem() {
  local name=$1 version=$2 expected_sha256=$3 path
  path="$tmpdir/$name-$version.gem"
  curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 \
    "https://rubygems.org/downloads/$name-$version.gem" \
    -o "$path"
  printf '%s  %s\n' "$expected_sha256" "$path" | sha256sum --check --status || {
    echo "checksum verification failed for $name $version" >&2
    exit 1
  }
}

# Download every non-default runtime dependency explicitly. Installing with
# --local prevents RubyGems from silently resolving a newer network artifact.
download_gem iostruct "$IOSTRUCT_VERSION" "$IOSTRUCT_SHA256"
download_gem prime "$PRIME_VERSION" "$PRIME_SHA256"
download_gem rainbow "$RAINBOW_VERSION" "$RAINBOW_SHA256"
download_gem zpng "$ZPNG_VERSION" "$ZPNG_SHA256"
download_gem zsteg "$ZSTEG_VERSION" "$ZSTEG_SHA256"

gem install --local --no-document "$tmpdir/iostruct-$IOSTRUCT_VERSION.gem"
gem install --local --no-document "$tmpdir/prime-$PRIME_VERSION.gem"
gem install --local --no-document "$tmpdir/rainbow-$RAINBOW_VERSION.gem"
gem install --local --no-document "$tmpdir/zpng-$ZPNG_VERSION.gem"
gem install --local --no-document "$tmpdir/zsteg-$ZSTEG_VERSION.gem"

gem list --installed --exact zsteg --version "$ZSTEG_VERSION" >/dev/null || {
  echo "installed zsteg version does not match $ZSTEG_VERSION" >&2
  exit 1
}
zsteg --help >/dev/null
