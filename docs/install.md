# Install Zpi

Use an existing source tree to build Zpi with Zig **0.17.0**, or install an archive built for your OS, CPU architecture and C library. The build script can produce local development archives.

Install `rg` and `fd` (or `fdfind`) separately if you use the corresponding search tools. To run existing pi TypeScript extensions, provide Node and your own pi SDK (**1.5.2** or **1.6.0**) installation. The default installation includes the Zpi extension host scripts and native ABI headers. [TypeScript extension setup](spec/typescript-extension-host.md)

## Install a release archive

GitHub release archives cover Linux x64, Linux arm64, macOS x64 and macOS arm64. Each `.tar.gz` has a matching `.sha256` file. The binaries target baseline CPU features. The Linux archives are built and tested on Ubuntu 24.04 with glibc 2.39. Verify the checksum before extraction.

You can also build a local archive for the machine running Zig. Choose a filename that identifies its OS, architecture and, on Linux, libc. The script requires Python 3 and a filesystem that supports hard links. It runs the core offline CLI suite from the unpacked archive before creating the output files.

```sh
sh scripts/build-release.sh zpi-macos-arm64.tar.gz zig-out/release-archives
```

Run the following from the directory containing an archive you trust and its checksum. The subshell stops before extraction if verification fails or the selected prefix already exists.

```sh
(
    set -eu
    archive=zpi-macos-arm64.tar.gz
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c "$archive.sha256"
    else
        shasum -a 256 -c "$archive.sha256"
    fi
    zpi_prefix="$HOME/.local/opt/zpi/local-1"
    mkdir -p "$(dirname "$zpi_prefix")"
    mkdir "$zpi_prefix"
    tar -xzf "$archive" -C "$zpi_prefix" --strip-components=1
    "$zpi_prefix/bin/zpi" --version
    "$zpi_prefix/bin/zpi" --help
)
```

The archive contains `bin/zpi`, `LICENSE`, native plugin headers, and the `share/zpi` TypeScript host scripts. It does not install Zig, Node, the pi SDK, `rg`, or `fd`/`fdfind`. Linux builds link to the target C library. For glibc and musl, choose a build compatible with the target loader and libc baseline; a macOS cross-build is not evidence of native execution or a general Linux ABI guarantee.

## Build from source

From the root of the source tree, choose a new directory dedicated to this build. `local-1` is an example directory name. Use a different name for each revision you install.

```sh
zpi_prefix="$HOME/.local/opt/zpi/local-1"
zig version
zig build -Doptimize=ReleaseSafe --prefix "$zpi_prefix"
"$zpi_prefix/bin/zpi" --version
"$zpi_prefix/bin/zpi" --help
```

## Verify the installed CLI

The offline CLI test uses a temporary workspace and local fake provider. Run it from the source tree with Python 3:

```sh
ZPI_TEST_BINARY="$zpi_prefix/bin/zpi" python3 scripts/test-cli.py
```

For an archive install, set `zpi_prefix` to the directory where you extracted it. `python3 scripts/test-package-release.py` separately checks deterministic archive creation from fixed inputs.

Add the selected build's `bin` directory to `PATH` in your shell startup file, before other Zpi installation paths. Keep `bin/zpi` and `share/zpi` in the same prefix so Zpi can find the TypeScript host. A working models configuration and credentials are needed for live requests. [Build and run](../README.md#build-and-run)

```sh
export PATH="$HOME/.local/opt/zpi/local-1/bin:$PATH"
```

## Upgrade or roll back

Verify the new archive checksum and install it under a new prefix, or build a new source revision into a fresh prefix. Run the version, help, and offline CLI checks against that path before changing `PATH`. Back up persistent sessions and configuration before opening them with a new build. Wait for active sessions to close before copying their files. Older versions can reject session record versions they do not support. To roll back, point your shell back at the previous prefix and restore the session backup if the older binary cannot open data written by the newer one.

## Uninstall

Remove the selected prefix from your shell startup file, then delete the dedicated install directory you created for that build. Start a new shell to pick up the updated `PATH`. This removes the executable, host scripts, and ABI headers in that prefix. Configuration and sessions live separately, by default under `~/.zpi/agent`. See the README for the flags and environment variables that can redirect them. [Build and run](../README.md#build-and-run)
