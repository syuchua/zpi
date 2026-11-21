#!/bin/sh
# Build, package and smoke-test one host architecture.
set -eu
if [ "$#" -ne 2 ]; then
    printf '%s\n' 'Usage: sh scripts/build-release.sh ARCHIVE_BASENAME OUTPUT_DIRECTORY' >&2
    exit 2
fi
name=$1
out=$2
case "$name" in
    -*|*[!A-Za-z0-9._-]*|'') printf '%s\n' 'Archive basename contains unsupported characters.' >&2; exit 2 ;;
esac
case "$name" in
    *.tar.gz) ;;
    *) printf '%s\n' 'Archive basename must end in .tar.gz.' >&2; exit 2 ;;
esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)
for dest in "$out/$name" "$out/$name.sha256"; do
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        printf '%s\n' 'Refusing to overwrite an existing release archive or checksum.' >&2
        exit 1
    fi
done
# Stage on the destination filesystem so publication also works on other volumes.
stage=$(mktemp -d "$out/.zpi-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cd "$root"
version=$(zig version)
if [ "$version" != 0.17.0 ]; then
    printf 'Release builds require Zig 0.17.0 (found %s).\n' "$version" >&2
    exit 1
fi
zig fmt --check build.zig build.zig.zon src/*.zig src/cli/*.zig
python3 scripts/test-package-release.py
zig build -Doptimize=ReleaseSafe --prefix "$stage/prefix" --summary all
cp LICENSE "$stage/prefix/LICENSE"
python3 scripts/package-release.py "$stage/prefix" "$stage/$name" > "$stage/$name.sha256"
mkdir "$stage/unpacked" "$stage/smoke-home"
tar -xzf "$stage/$name" -C "$stage/unpacked"
binary="$stage/unpacked/zpi/bin/zpi"
"$binary" --version
"$binary" --help >/dev/null
# The runtime smoke uses only localhost and an isolated configuration.
env -i PATH="$PATH" HOME="$stage/smoke-home" ZPI_TEST_BINARY="$binary" python3 scripts/test-cli.py

python3 - "$stage/$name" "$out/$name" <<'PY'
import os
import sys

source, destination = sys.argv[1:]
os.link(source, destination)
try:
    os.link(source + '.sha256', destination + '.sha256')
except OSError:
    os.unlink(destination)
    raise
PY
printf '%s  %s\n' "$(awk 'NR == 1 { print $1 }' "$out/$name.sha256")" "$name"
printf '%s\n' "Archive: $out/$name"
printf '%s\n' "Checksum: $out/$name.sha256"
