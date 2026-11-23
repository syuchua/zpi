#!/bin/sh
# Build, package and smoke-test a release binary.
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
stage=$(mktemp -d "$out/.zpi-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cd "$root"
version=$(zig version)
if [ "$version" != 0.17.0 ]; then
    printf 'Release builds require Zig 0.17.0 (found %s).\n' "$version" >&2
    exit 1
fi
set -- -Doptimize=ReleaseSafe -Dcpu=baseline --prefix "$stage/prefix" --summary all
if [ -n "${ZPI_RELEASE_TARGET:-}" ]; then
    set -- "$@" "-Dtarget=$ZPI_RELEASE_TARGET"
fi
zig fmt --check build.zig build.zig.zon src
python3 scripts/test-package-release.py
zig build "$@"
cp LICENSE "$stage/prefix/LICENSE"
root_name=zpi
if [ -n "${ZPI_RELEASE_VERSION:-}" ]; then root_name=${name%.tar.gz}; fi
python3 scripts/package-release.py "$stage/prefix" "$stage/$name" --root-name "$root_name" > "$stage/$name.sha256"
mkdir "$stage/unpacked"
tar -xzf "$stage/$name" -C "$stage/unpacked"
binary="$stage/unpacked/$root_name/bin/zpi"

if [ -n "${ZPI_RELEASE_MACOS_MIN:-}" ]; then
    xcrun vtool -show-build "$binary" | awk -v expected="$ZPI_RELEASE_MACOS_MIN" '
        $1 == "minos" && $2 == expected { print; found = 1 } END { exit !found }'
    sw_vers -productVersion
fi
if [ -n "${ZPI_RELEASE_CONTAINER_IMAGE:-}" ]; then
    platform=${ZPI_RELEASE_CONTAINER_PLATFORM:?Set the container platform}
    case "$ZPI_RELEASE_CONTAINER_IMAGE" in
        quay.io/pypa/manylinux2014_*) runtime_kind=gnu ;;
        alpine:*) runtime_kind=musl ;;
        *) printf 'Unsupported release runtime image.\n' >&2; exit 1 ;;
    esac
    docker run --rm --platform "$platform" \
        -v "$stage/unpacked:/release:ro" -v "$root:/source:ro" -w /source \
        "$ZPI_RELEASE_CONTAINER_IMAGE" sh -ec '
            case "$1" in
                gnu)
                    getconf GNU_LIBC_VERSION
                    test "$(getconf GNU_LIBC_VERSION)" = "glibc 2.17"
                    export PATH=/opt/python/cp312-cp312/bin:$PATH
                    ;;
                musl) apk add --no-cache python3 ripgrep fd bash ca-certificates openssl ;;
                *) exit 2 ;;
            esac
            exec sh /source/scripts/smoke-release.sh "$2" "$3"
        ' sh "$runtime_kind" "/release/$root_name/bin/zpi" "${ZPI_RELEASE_VERSION:-}"
else
    sh scripts/smoke-release.sh "$binary" "${ZPI_RELEASE_VERSION:-}"
fi

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
