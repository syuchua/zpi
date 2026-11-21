#!/bin/sh
# Build once in Colima, load the identical image into Apple Container, and run
# the same guest executables. No user credentials/config are mounted.
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
image=${ZPI_TEST_IMAGE:-zpi-linux-tests:3.24.3}
container system status >/dev/null 2>&1 || container system start --enable-kernel-install --timeout 60
colima status >/dev/null 2>&1 || colima start
zig build test
mkdir -p zig-out/test-images

run_tests() {
    target=$1
    arch=$2
    platform=$3
    out="zig-out/$target"
    tag="$image-$arch"
    zig build test-binaries "-Dtarget=$target" --prefix "$out"
    zig build "-Dtarget=$target" --prefix "$out"
    cp scripts/test-cli.py scripts/test-context-budget.py scripts/test-linux-artifacts.sh "$out/"
    if [ "${ZPI_BUILD_TEST_IMAGE:-1}" = 1 ]; then
        set --
        # A proxy address inside a guest may differ from the host's loopback.
        # Supply it explicitly; do not embed a machine-specific IP in the repo.
        if [ -n "${ZPI_TEST_BUILD_PROXY:-}" ]; then
            set -- --build-arg "http_proxy=$ZPI_TEST_BUILD_PROXY" --build-arg "https_proxy=$ZPI_TEST_BUILD_PROXY"
        fi
        docker --context colima build --platform "$platform" "$@" \
            --file scripts/linux-tests.Containerfile --tag "$tag" scripts
    fi
    docker --context colima image save --output "zig-out/test-images/$arch.tar" "$tag"
    container image load --input "zig-out/test-images/$arch.tar"
    for runtime in apple-container colima; do
        printf 'Testing %s in %s using %s\n' "$target" "$runtime" "$tag"
        set --
        if [ "$runtime" = apple-container ]; then
            if [ "$arch" = amd64 ]; then set -- --rosetta; fi
            set -- container run --rm --arch "$arch" "$@" --volume "$root/$out:/artifacts:ro"
        else
            set -- docker --context colima run --rm --platform "$platform" -v "$root/$out:/artifacts:ro"
        fi
        "$@" "$tag" /bin/sh /artifacts/test-linux-artifacts.sh /artifacts
    done
}
run_tests aarch64-linux-musl arm64 linux/arm64
run_tests x86_64-linux-musl amd64 linux/amd64
