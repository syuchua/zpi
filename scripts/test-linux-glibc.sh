#!/bin/sh
# Cross-build GNU/Linux arm64 artifacts on macOS and run them in Colima's VM.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
zig_exe=$(command -v zig)
printf 'Zig version: %s\n' "$(zig version)"
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$zig_exe"
else
    sha256sum "$zig_exe"
fi
colima status >/dev/null 2>&1 || colima start

target=aarch64-linux-gnu.2.39
out="$root/zig-out/$target"
zig build test-binaries "-Dtarget=$target" --prefix "$out"
zig build "-Dtarget=$target" --prefix "$out"
cp scripts/test-cli.py scripts/test-rpc.py scripts/test-context-budget.py scripts/test-linux-artifacts.sh "$out/"
colima ssh -- sh -s -- "$out" <<'GUEST'
set -eu
out=$1
guest=$(mktemp -d /tmp/zpi-linux-gnu.XXXXXX)
trap 'rm -rf "$guest"' EXIT
cp -R "$out/bin" "$out/lib" "$out/share" "$guest/"
cp "$out/test-cli.py" "$out/test-rpc.py" "$out/test-context-budget.py" "$out/test-linux-artifacts.sh" "$guest/"
printf 'Architecture: %s\n' "$(uname -m)"
getconf GNU_LIBC_VERSION
ldd "$guest/bin/zpi"
cd "$guest"
env -i PATH=/usr/local/bin:/usr/bin:/bin sh "$guest/test-linux-artifacts.sh" "$guest" --allow-search-skips
sha256sum "$guest/test-cli.py" "$guest/test-rpc.py" "$guest/test-context-budget.py"
GUEST
shasum -a 256 scripts/test-cli.py scripts/test-context-budget.py \
    "$out/test-cli.py" "$out/test-context-budget.py"
