#!/bin/sh
# Build and test in the existing arm64 Ubuntu Colima VM with a pinned Zig archive.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
archive=${1:?Usage: sh scripts/test-linux-native-glibc.sh ZIG_AARCH64_LINUX_ARCHIVE}
case "$archive" in
    /*) ;;
    *) printf '%s\n' 'The Zig archive path must be absolute.' >&2; exit 2 ;;
esac
if [ "$#" -ne 1 ]; then
    printf '%s\n' 'Provide exactly one Zig archive path.' >&2
    exit 2
fi
expected=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c
mkdir -p "$root/zig-out"
staging=$(mktemp -d "$root/zig-out/linux-native-glibc.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/compiler" "$staging/source"
# Extract on the host so the Ubuntu VM does not need xz-utils.
tar -xf "$archive" --strip-components=1 -C "$staging/compiler"
cd "$root"
cp -R build.zig build.zig.zon README.md .gitignore src scripts include docs "$staging/source/"
colima status >/dev/null 2>&1 || colima start

colima ssh -- sh -s -- "$staging" <<'GUEST'
set -eu
if [ "$(uname -m)" != aarch64 ]; then
    printf '%s\n' 'This runner requires an arm64 Colima VM.' >&2
    exit 2
fi
guest=$(mktemp -d /tmp/zpi-linux-native-glibc.XXXXXX)
trap 'rm -rf "$guest"' EXIT
cp -R "$1/." "$guest/"
cd "$guest/source"
export PATH="$guest/compiler:$PATH"
export ZIG_GLOBAL_CACHE_DIR="$guest/cache"
export PATH="$PATH:/usr/local/sbin:/usr/sbin"
uname -sm
getconf GNU_LIBC_VERSION
printf 'Zig version: '; zig version
zig fmt --check build.zig src
zig build install test-binaries -j2 --summary all
cp scripts/test-cli.py scripts/test-rpc.py scripts/test-context-budget.py zig-out/
ldd zig-out/bin/zpi
sh scripts/test-linux-artifacts.sh "$PWD/zig-out" --allow-search-skips
sha256sum src/pi_session.zig zig-out/test-cli.py zig-out/test-rpc.py zig-out/test-context-budget.py
GUEST
