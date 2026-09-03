#!/usr/bin/env bash
# Non-destructive regression checks for transcript-store provisioning guards.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAKE_STORE=$HERE/make-store.sh
CHECK_STORE=$HERE/check-store.sh

fail() {
  echo "tlog-store-safety-static: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1 pattern=$2
  grep -Eq -- "$pattern" "$file" || fail "$file is missing safety check: $pattern"
}

line_of() {
  local file=$1 pattern=$2
  grep -nEm1 -- "$pattern" "$file" | cut -d: -f1
}

bash -n "$MAKE_STORE" "$CHECK_STORE" "$HERE/install.sh"
[ -x "$MAKE_STORE" ] || fail "make-store.sh is not executable"
[ -x "$CHECK_STORE" ] || fail "check-store.sh is not executable"
if "$MAKE_STORE" --unknown-option >/dev/null 2>&1; then
  fail "make-store.sh accepted an unknown option"
fi
if "$MAKE_STORE" one two three >/dev/null 2>&1; then
  fail "make-store.sh accepted too many positional arguments"
fi

assert_contains "$MAKE_STORE" 'realpath -m'
assert_contains "$MAKE_STORE" 'refusing to use / as the transcript mountpoint'
assert_contains "$MAKE_STORE" 'mountpoint may not be a symlink'
assert_contains "$MAKE_STORE" 'mountpoint is not empty'
assert_contains "$MAKE_STORE" 'findmnt .* -M .*mountpoint'
assert_contains "$MAKE_STORE" 'lsblk .*MOUNTPOINTS'
assert_contains "$MAKE_STORE" 'swapon --show=NAME'
assert_contains "$MAKE_STORE" 'fuser -s .*block_path'
assert_contains "$MAKE_STORE" '/holders/\*'
assert_contains "$MAKE_STORE" 'findmnt .* -S .*block_path'
assert_contains "$MAKE_STORE" 'lsblk -dnro PTTYPE'
assert_contains "$MAKE_STORE" 'partition table or child block devices'
assert_contains "$MAKE_STORE" 'mktemp /etc/\.fstab\.rd-tlog'
assert_contains "$MAKE_STORE" 'mv -f .*fstab_candidate.* /etc/fstab'
assert_contains "$MAKE_STORE" 'umount -- .*mountpoint'
assert_contains "$MAKE_STORE" 'RD_TLOG_STORE=.*check-store\.sh'

force_line=$(line_of "$MAKE_STORE" 'mkfs_args\+=\(-f\)')
# shellcheck disable=SC2016 # literal regex intentionally matches shell source
mkfs_line=$(line_of "$MAKE_STORE" '^mkfs\.xfs "\$\{mkfs_args\[@\]\}" "\$device"')
[ "$force_line" -lt "$mkfs_line" ] || fail "--force is not scoped to the exact-device mkfs call"

verify_line=$(line_of "$MAKE_STORE" 'RD_TLOG_STORE=.*check-store\.sh')
# shellcheck disable=SC2016 # literal regex intentionally matches shell source
fstab_install_line=$(line_of "$MAKE_STORE" '^mv -f -- "\$fstab_candidate" /etc/fstab')
[ "$verify_line" -lt "$fstab_install_line" ] || fail "fstab is installed before live mount verification"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$MAKE_STORE" "$CHECK_STORE" "$HERE/install.sh"
fi

echo "tlog-store-safety-static: PASS"
