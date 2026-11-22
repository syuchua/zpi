#!/bin/sh
# Execute build-installed Linux artifacts and the accompanying Python fixtures.
set -eu
artifacts=${1:?Usage: sh test-linux-artifacts.sh ABSOLUTE_ARTIFACT_DIRECTORY [--allow-search-skips]}
if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != --allow-search-skips ]; }; then
    printf '%s\n' 'The only optional argument is --allow-search-skips.' >&2
    exit 2
fi
case "$artifacts" in
    /*) ;;
    *) printf '%s\n' 'The artifact directory must be absolute.' >&2; exit 2 ;;
esac

if command -v rg >/dev/null && { command -v fd >/dev/null || command -v fdfind >/dev/null; }; then
    rg --version
    if command -v fd >/dev/null; then fd --version; else fdfind --version; fi
elif [ "${2:-}" = --allow-search-skips ]; then
    printf '%s\n' 'Search tests may skip because rg or fd/fdfind is unavailable.'
else
    printf '%s\n' 'Search tests require rg and fd or fdfind; use --allow-search-skips only for explicitly reduced coverage.' >&2
    exit 1
fi

for suite in core cli harness skills tool-selection tui sse http-header http-transport model openai openai-responses anthropic anthropic-edge agent tool session pi-session replacement search web-fetch bg-tasks extension context-budget compaction mcp mcp-tool prompt-template native native-value native-json; do
    "$artifacts/bin/$suite-tests"
done
ZPI_REJECTION_DIR="$artifacts/lib" "$artifacts/bin/native-rejection-tests"
ZPI_NATIVE_FIXTURE="$artifacts/lib/libzpi-native-c-fixture.so" "$artifacts/bin/native-runtime-c-tests"
ZPI_NATIVE_FIXTURE="$artifacts/lib/libzpi-native-zig-fixture.so" "$artifacts/bin/native-runtime-zig-tests"
binary="$artifacts/bin/zpi"
if [ ! -x "$binary" ]; then
    printf 'Missing executable artifact: %s\n' "$binary" >&2
    exit 1
fi
"$binary" --help >/dev/null
"$binary" --version
ZPI_TEST_BINARY="$binary" \
    ZPI_TEST_NATIVE_PLUGINS="$artifacts/lib/libzpi-native-c-fixture.so:$artifacts/lib/libzpi-native-zig-fixture.so" \
    python3 "$artifacts/test-cli.py"
ZPI_TEST_BINARY="$binary" python3 "$artifacts/test-context-budget.py"
