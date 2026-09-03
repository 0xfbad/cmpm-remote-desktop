#!/usr/bin/env bash
# Supply-chain and quarantine invariants for the non-production KasmVNC
# experiment. This deliberately does not build or make the image deployable.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCKERFILE=$REPO/Dockerfile.kasm

fail() {
  echo "kasm-quarantine-static: $*" >&2
  exit 1
}

assert_fixed() {
  local value=$1
  grep -Fqx -- "$value" "$DOCKERFILE" || fail "missing exact invariant: $value"
}

assert_contains() {
  local pattern=$1
  grep -Eq -- "$pattern" "$DOCKERFILE" || fail "missing invariant: $pattern"
}

line_of() {
  local pattern=$1
  grep -nEm1 -- "$pattern" "$DOCKERFILE" | cut -d: -f1
}

assert_contains '^# EXPERIMENTAL: this image is not compatible with the current CTFd plugin'
assert_fixed 'FROM kalilinux/kali-rolling@sha256:ed99295a386abde2fb31e01a441b7c2800d9bcf19a20028b77d642c3ef068363'
assert_contains 'KASMVNC_VERSION=1\.5\.0;'
assert_contains 'KASMVNC_SHA256=2bcdb96dd5093ffa6def626db701de8c28564418c1676bc1f13b2f99119b8c26;'
assert_contains 'kasmvncserver_kali-rolling_\$\{KASMVNC_VERSION\}_amd64\.deb'
assert_contains 'dpkg --print-architecture.*amd64'
assert_contains 'sha256sum -c -'

checksum_line=$(line_of 'sha256sum -c -')
install_line=$(line_of 'apt-get install -y /tmp/kasmvnc\.deb')
[ "$checksum_line" -lt "$install_line" ] || fail "KasmVNC package is installed before checksum verification"

assert_contains 'RUN --mount=type=secret,id=ucsc_ca,required=false'
assert_contains 'UCSC_CA_CERT_SHA256 must be a 64-character fingerprint'
assert_contains 'ucsc_ca certificate fingerprint mismatch'
assert_contains 'UCSC_CA_CERT_SHA256 was set but BuildKit secret ucsc_ca is missing'
if grep -Eq 'openssl[[:space:]]+s_client' "$DOCKERFILE"; then
  fail "live TLS certificate scraping returned"
fi

# The current plugin rejects this image because the contract label is absent.
# Adding it would silently turn a static experiment into a deployment candidate.
if grep -Fq 'edu.ucsc.ctfd-remote-desktop.contract' "$DOCKERFILE"; then
  fail "experimental Kasm image must not carry the production contract label"
fi

echo "kasm-quarantine-static: PASS"
