#!/bin/sh
# Build and package a release archive for an explicit Zig target.
set -eu
if [ "$#" -ne 3 ]; then
    printf '%s\n' 'Usage: sh scripts/build-release-target.sh ARCHIVE_BASENAME OUTPUT_DIRECTORY ZIG_TARGET' >&2
    exit 2
fi
name=$1
out=$2
target=$3
case "$name" in
    -*|*[!A-Za-z0-9._-]*|'') printf '%s\n' 'Archive basename contains unsupported characters.' >&2; exit 2 ;;
esac
case "$name" in
    *.tar.gz) ;;
    *) printf '%s\n' 'Archive basename must end in .tar.gz.' >&2; exit 2 ;;
esac
case "$target" in
    -*|*[!A-Za-z0-9._-]*|'') printf '%s\n' 'Zig target contains unsupported characters.' >&2; exit 2 ;;
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
stage=$(mktemp -d "$out/.zpi-release-target.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cd "$root"
version=$(zig version)
if [ "$version" != 0.17.0 ]; then
    printf 'Release builds require Zig 0.17.0 (found %s).\n' "$version" >&2
    exit 1
fi
zig fmt --check build.zig build.zig.zon src
python3 scripts/test-package-release.py
zig build -Dtarget="$target" -Doptimize=ReleaseSafe -Dcpu=baseline --prefix "$stage/prefix" --summary all
cp LICENSE "$stage/prefix/LICENSE"
root_name=zpi
if [ -n "${ZPI_RELEASE_VERSION:-}" ]; then
    platform=${name%.tar.gz}
    root_name="zpi-$ZPI_RELEASE_VERSION-$platform"
fi
python3 scripts/package-release.py "$stage/prefix" "$stage/$name" --root-name "$root_name" > "$stage/$name.sha256"
mkdir "$stage/unpacked"
tar -xzf "$stage/$name" -C "$stage/unpacked"
binary="$stage/unpacked/$root_name/bin/zpi"
if [ -n "${ZPI_RELEASE_MACOS_MIN:-}" ]; then
    xcrun vtool -show-build "$binary" | awk -v expected="$ZPI_RELEASE_MACOS_MIN" '$1 == "minos" && $2 == expected { found = 1 } END { exit !found }'
fi
if [ "${ZPI_RELEASE_EXECUTE:-0}" = 1 ]; then
    binary_version=$("$binary" --version)
    printf '%s\n' "$binary_version"
    sh "$root/scripts/smoke-release.sh" "$binary" "${ZPI_RELEASE_VERSION:-}" full
elif [ -n "${ZPI_RELEASE_CONTAINER_IMAGE:-}" ]; then
    image=$ZPI_RELEASE_CONTAINER_IMAGE
    platform=${ZPI_RELEASE_CONTAINER_PLATFORM:?Set ZPI_RELEASE_CONTAINER_PLATFORM with the container image}
    case "$image" in
        alpine:*) install='apk add --no-cache python3 ripgrep fd git bash ca-certificates'; runtime_path=/usr/bin:/bin ;;
        quay.io/pypa/manylinux2014_*) install='test "$(getconf GNU_LIBC_VERSION)" = "glibc 2.17"'; runtime_path=/opt/python/cp312-cp312/bin:/opt/_internal/openssl-3.5/bin:/usr/local/bin:/usr/bin:/bin ;;
        *) printf 'Unsupported smoke-test image: %s\\n' "$image" >&2; exit 1 ;;
    esac
    case "$image" in
        quay.io/pypa/manylinux2014_aarch64) platform=linux/arm64 ;;
        quay.io/pypa/manylinux2014_x86_64) platform=linux/amd64 ;;
    esac
    docker_args=--rm
    if [ -n "${ZPI_RELEASE_CONTAINER_PLATFORM:-}" ]; then docker_args="$docker_args --platform $ZPI_RELEASE_CONTAINER_PLATFORM"; fi
    docker run $docker_args \\
        -v "$stage/unpacked:/release:ro" \\
        -v "$root:/source:ro" \\
        -w /source \\
        -e PATH="$runtime_path" \\
        -e ZPI_RELEASE_VERSION="${ZPI_RELEASE_VERSION:-}" \\
        -e ZPI_RELEASE_ROOT="$root_name" \\
        -e ZPI_RELEASE_INSTALL="$install" \\
        "$image" sh -ec 'eval "$ZPI_RELEASE_INSTALL"; exec sh /source/scripts/smoke-release.sh "/release/$ZPI_RELEASE_ROOT/bin/zpi" "$ZPI_RELEASE_VERSION" full'
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
