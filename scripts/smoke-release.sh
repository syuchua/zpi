#!/bin/sh
set -eu
binary=$1
expected_version=${2:-}
smoke_mode=${3:-full}
source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$("$binary" --version)
printf '%s\n' "$version"
if [ -n "$expected_version" ] && [ "$version" != "zpi $expected_version" ]; then
    printf 'Expected zpi %s, got %s.\n' "$expected_version" "$version" >&2
    exit 1
fi
"$binary" --help >/dev/null
if [ "$smoke_mode" = full ]; then
    smoke_home=$(mktemp -d "${TMPDIR:-/tmp}/zpi-release-smoke.XXXXXX")
    trap 'rm -rf "$smoke_home"' EXIT
    env -i PATH="$PATH" HOME="$smoke_home" ZPI_TEST_BINARY="$binary" python3 "$source_root/scripts/test-cli.py"
elif [ "$smoke_mode" != runtime ]; then
    printf 'Unknown smoke mode: %s\\n' "$smoke_mode" >&2
    exit 2
fi
