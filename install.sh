#!/bin/sh
# Parse the complete script before running it when streamed into sh.
{
set -eu

usage() {
    printf '%s\n' 'Usage: install.sh [--with-search-tools | --without-search-tools]' \
        'Set ZPI_VERSION to select a release. The default is the latest stable release.'
}

fail() {
    printf 'zpi installer: %s\n' "$1" >&2
    exit 1
}

search_tools=ask
case $# in
    0) ;;
    1) case $1 in
        --with-search-tools) search_tools=install ;;
        --without-search-tools) search_tools=skip ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac ;;
    *) usage >&2; exit 2 ;;
esac

case $(uname -m) in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
    *) fail 'Supported CPU architectures are x86-64 and ARM64.' ;;
esac
os=$(uname -s)
case $os in
    Darwin) platform=macos-$arch ;;
    Linux)
        if getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
            libc=gnu
        else
            ldd_version=$(ldd --version 2>&1 || :)
            case $ldd_version in
                *musl*) libc=musl ;;
                *GLIBC*|*'GNU libc'*) libc=gnu ;;
                *) fail 'Could not identify the Linux C library. Select an archive manually.' ;;
            esac
        fi
        platform=linux-$arch-$libc
        ;;
    *) fail 'Supported operating systems are macOS and Linux.' ;;
esac

for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required utility missing: $tool."
done
if command -v sha256sum >/dev/null 2>&1; then
    hash_archive() { sha256sum < "$1"; }
elif command -v shasum >/dev/null 2>&1; then
    hash_archive() { shasum -a 256 < "$1"; }
else
    fail 'Install sha256sum or shasum to verify the release archive.'
fi

repo_url=https://github.com/syuchua/zpi
get_https() {
    curl -q --proto '=https' --proto-redir '=https' -fsSL --retry 3 \
        --connect-timeout 15 --max-time 300 "$@"
}
version=${ZPI_VERSION:-}
if [ -z "$version" ]; then
    latest_url=$repo_url/releases/latest
    release_url=$(get_https -o /dev/null -w '%{url_effective}' "$latest_url")
    case $release_url in
        "$repo_url"/releases/tag/v*) version=${release_url##*/} ;;
        *) fail 'Could not resolve the latest GitHub release.' ;;
    esac
fi
version=${version#v}
printf '%s\n' "$version" | awk 'NR != 1 || $0 !~ /^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$/ { bad = 1 } END { exit (NR != 1 || bad) }' ||
    fail 'Expected ZPI_VERSION in the form vMAJOR.MINOR.PATCH.'

umask 077
local_root=${HOME:?HOME must be set}/.local
opt_dir=$local_root/opt/zpi
bin_dir=$local_root/bin
link=$bin_dir/zpi
if [ -e "$link" ] && [ ! -L "$link" ]; then
    fail "Refusing to replace a non-symlink at $link."
fi
mkdir -p "$opt_dir" "$bin_dir"
release=zpi-$version-$platform
archive=$release.tar.gz
base_url=$repo_url/releases/download/v$version
tmp=$(mktemp -d "$opt_dir/.install.XXXXXX")
link_stage=
trap 'rm -rf "${tmp:?}"; if [ -n "$link_stage" ]; then rm -rf "$link_stage"; fi' EXIT
trap 'exit 1' HUP INT TERM
get_https "$base_url/$archive" -o "$tmp/$archive"
get_https "$base_url/$archive.sha256" -o "$tmp/$archive.sha256"
expected=$(awk -v archive="$archive" 'NR != 1 || NF != 2 || $2 != archive || length($1) != 64 || $1 ~ /[^0-9a-f]/ { bad = 1 } { digest = $1 } END { if (NR != 1 || bad) exit 1; print digest }' "$tmp/$archive.sha256") ||
    fail 'The release checksum file has an unexpected format.'
actual=$(hash_archive "$tmp/$archive")
[ "${actual%% *}" = "$expected" ] || fail 'Release archive checksum mismatch.'

# Extract only known archive members into regular files we create ourselves.
package=$tmp/runtime
mkdir -p "$package/bin" "$package/include" "$package/share/zpi"
for member in bin/zpi LICENSE include/zpi_plugin.h include/zpi_plugin_runtime.h share/zpi/pi-sdk.mjs share/zpi/ts-host.mjs; do
    tar -xOzf "$tmp/$archive" "$release/$member" > "$package/$member" ||
        fail 'Release archive has an unexpected layout.'
    [ -s "$package/$member" ] || fail 'Release archive contains an empty runtime file.'
done
chmod 700 "$package/bin/zpi"
[ "$("$package/bin/zpi" --version)" = "zpi $version" ] || fail 'Release binary version mismatch.'

# Keep installations separate from the staging area so upgrades preserve the
# working version until the new tree is ready and the symlink has been switched.
destination=$(mktemp -d "$opt_dir/$version-$platform.XXXXXX")
install_committed=0
trap 'rm -rf "${tmp:?}"; if [ -n "$link_stage" ]; then rm -rf "$link_stage"; fi; if [ "$install_committed" = 0 ] && [ "$(readlink "$link" 2>/dev/null || :)" != "$destination/runtime/bin/zpi" ]; then rm -rf "$destination"; fi' EXIT
if ! mv "$package" "$destination/runtime"; then
    rmdir "$destination"
    fail 'Could not move the validated release into place.'
fi
link_stage=$(mktemp -d "$bin_dir/.zpi-link.XXXXXX")
ln -s "$destination/runtime/bin/zpi" "$link_stage/zpi"
if [ -e "$link" ] && [ ! -L "$link" ]; then
    fail "Refusing to replace a non-symlink at $link."
fi
case $os in
    Darwin) mv -fh "$link_stage/zpi" "$link" ;;
    Linux) mv -fT "$link_stage/zpi" "$link" ;;
esac
install_committed=1

printf 'Installed Zpi %s for %s at %s\n' "$version" "$platform" "$link"
case :$PATH: in
    *:"$bin_dir":*) ;;
    *) printf 'Add %s to PATH to run zpi.\n' "$bin_dir" ;;
esac

need_rg=0
need_fd=0
command -v rg >/dev/null 2>&1 || need_rg=1
command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1 || need_fd=1
if [ "$need_rg$need_fd" = 00 ]; then exit 0; fi
[ "$need_rg" = 0 ] || printf '%s\n' 'Optional dependency missing: rg (ripgrep), used by grep.'
[ "$need_fd" = 0 ] || printf '%s\n' 'Optional dependency missing: fd or fdfind, used by find.'

case $os in
    Darwin) candidates=brew ;;
    Linux) candidates='apt-get dnf pacman apk' ;;
esac
manager=
for candidate in $candidates; do
    if command -v "$candidate" >/dev/null 2>&1; then
        manager=$candidate
        break
    fi
done
[ "$search_tools" != skip ] || exit 0
[ -n "$manager" ] || { printf '%s\n' 'Install the missing tools with your system package manager.'; exit 0; }

confirm_install() (
    { exec 3<> /dev/tty; } 2>/dev/null || exit 1
    printf 'Install the missing search tools using %s? [y/N] ' "$manager" >&3
    IFS= read -r answer <&3 || exit 1
    case $answer in y|Y|yes|YES) exit 0 ;; *) exit 1 ;; esac
)
if [ "$search_tools" = ask ] && ! confirm_install; then exit 0; fi

set --
[ "$need_rg" = 0 ] || set -- "$@" ripgrep
if [ "$need_fd" = 1 ]; then
    case $manager in
        apt-get|dnf) set -- "$@" fd-find ;;
        *) set -- "$@" fd ;;
    esac
fi
run_system() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}
install_extras() {
    case $manager in
        brew) brew install "$@" ;;
        apt-get) run_system apt-get install -y "$@" ;;
        dnf) run_system dnf install -y "$@" ;;
        pacman) run_system pacman -S --needed --noconfirm "$@" ;;
        apk) run_system apk add "$@" ;;
    esac
}
if ! install_extras "$@"; then
    printf '%s\n' 'Zpi is installed. The package manager could not install the optional search tools.' >&2
fi
}
