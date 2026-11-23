#!/usr/bin/env python3
"""Write a reproducible Zpi runtime archive from an install prefix."""
import argparse
import gzip
import hashlib
import os
import stat
import tarfile
import tempfile
from pathlib import Path


FILES = {
    'bin/zpi': 0o755,
    'include/zpi_plugin.h': 0o644,
    'include/zpi_plugin_runtime.h': 0o644,
    'LICENSE': 0o644,
    'share/zpi/pi-sdk.mjs': 0o644,
    'share/zpi/ts-host.mjs': 0o644,
}


def package(prefix, output, root_name='zpi'):
    # Publish the complete archive without replacing a previous build.
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.zpi-package-') as staging:
        with gzip.GzipFile(filename='', fileobj=staging, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name, mode in FILES.items():
                    # Nonblocking open lets us reject a FIFO without waiting for a writer.
                    fd = os.open(prefix / name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
                    with os.fdopen(fd, 'rb') as source:
                        metadata = os.fstat(source.fileno())
                        if not stat.S_ISREG(metadata.st_mode):
                            raise ValueError(f'Expected a regular installed file: {name}')
                        entry = tarfile.TarInfo(f'{root_name}/{name}')
                        entry.size = metadata.st_size
                        entry.mode = mode
                        archive.addfile(entry, source)
        staging.flush()
        os.fchmod(staging.fileno(), 0o644)
        staging.seek(0)
        digest = hashlib.sha256()
        while chunk := staging.read(64 * 1024):
            digest.update(chunk)
        os.link(staging.name, output)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix', type=Path, help='Prefix populated by zig build install')
    parser.add_argument('output', type=Path, help='New .tar.gz archive in an existing directory')
    parser.add_argument('--root-name', default='zpi', help='Top-level archive directory')
    args = parser.parse_args()
    if not args.output.name.endswith('.tar.gz') or any(c.isspace() or c == '\\' for c in args.output.name):
        parser.error('Use a .tar.gz filename without whitespace or backslashes')
    if not args.root_name or args.root_name in ('.', '..') or any(c in args.root_name for c in '/\\') or any(c.isspace() for c in args.root_name):
        parser.error('Root name must be one safe path component without whitespace')
    try:
        checksum = package(args.prefix, args.output, args.root_name)
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f'zpi package: {error}\n')
    print(f'{checksum}  {args.output.name}')


if __name__ == '__main__':
    main()
