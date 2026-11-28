#!/bin/sh
# Build and execute the current project in an aarch64 Linux guest using native Zig.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
stage=${ZPI_LINUX_ZIG_STAGE:-/tmp/zpi-linux-zig-0.17.0}
archive="$stage/zig.tar.xz"
expected=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
if [ ! -f "$archive" ] || ! printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c >/dev/null 2>&1; then
    mkdir -p "$stage"
    curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 1800 \
        https://ziglang.org/download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz -o "$archive"
fi
printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c
mkdir -p zig-out
staging=$(mktemp -d "$root/zig-out/linux-native.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/toolchain" "$staging/source"
cp "$archive" "$staging/toolchain/zig.tar.xz"
cp -R build.zig build.zig.zon README.md .gitignore src scripts include docs "$staging/source/"
colima status >/dev/null 2>&1 || colima start
image=${ZPI_LINUX_NATIVE_IMAGE:-zpi-linux-native:0.17.0}
docker --context colima build --platform linux/arm64 \
    --file scripts/linux-native-tests.Containerfile --tag "$image" "$staging/toolchain"

docker --context colima run --rm --platform linux/arm64 --network none \
    --volume "$staging/source:/source:ro" \
    --entrypoint /bin/sh "$image" -c '
set -eu
mkdir /workspace
cp -R /source/. /workspace/
cd /workspace
printf "Zig version: "; zig version
printf "Guest: "; uname -sm
printf "Compiler: "; cc --version | head -n 1
zig fmt --check build.zig src
python3 -m py_compile scripts/test-cli.py scripts/test-rpc.py scripts/test-context-budget.py
zig build install test-binaries --summary all
cp scripts/test-cli.py scripts/test-rpc.py scripts/test-context-budget.py zig-out/
sh scripts/test-linux-artifacts.sh "$PWD/zig-out"
sha256sum zig-out/test-cli.py zig-out/test-rpc.py zig-out/test-context-budget.py
'
