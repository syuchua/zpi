#!/usr/bin/env python3
"""Exercise deterministic runtime packaging and destination safety."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGER = ROOT / 'scripts/package-release.py'


def main():
    with tempfile.TemporaryDirectory(prefix='zpi-package-test-') as temporary:
        root = Path(temporary)
        prefix = root / 'prefix'
        output = root / 'zpi.tar.gz'
        fixture_files = [
            ('bin/zpi', b'fake executable\n'),
            ('include/zpi_plugin.h', b'header\n'),
            ('include/zpi_plugin_runtime.h', b'runtime header\n'),
            ('LICENSE', b'license\n'),
            ('share/zpi/pi-sdk.mjs', b'helper\n'),
            ('share/zpi/ts-host.mjs', b'host\n'),
        ]
        for relative, data in fixture_files:
            path = prefix / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        first = subprocess.run([sys.executable, str(PACKAGER), str(prefix), str(output)],
                               check=True, text=True, capture_output=True)
        original = output.read_bytes()
        for relative, _ in fixture_files:
            os.utime(prefix / relative, (1234, 1234))
            (prefix / relative).chmod(0o600)
        second_output = root / 'second.tar.gz'
        second = subprocess.run([sys.executable, str(PACKAGER), str(prefix), str(second_output)],
                                check=True, text=True, capture_output=True)
        assert original == second_output.read_bytes()
        assert first.stdout.split()[0] == hashlib.sha256(original).hexdigest()
        assert second.stdout.split()[0] == first.stdout.split()[0]
        assert output.stat().st_mode & 0o777 == 0o644
        release_root = 'zpi-0.1.0-linux-x64-gnu'
        release_output = root / 'release.tar.gz'
        subprocess.run([sys.executable, str(PACKAGER), str(prefix), str(release_output), '--root-name', release_root],
                       check=True, text=True, capture_output=True)
        with tarfile.open(output, 'r:gz') as archive:
            names = archive.getnames()
            assert names == [
                'zpi/bin/zpi',
                'zpi/include/zpi_plugin.h',
                'zpi/include/zpi_plugin_runtime.h',
                'zpi/LICENSE',
                'zpi/share/zpi/pi-sdk.mjs',
                'zpi/share/zpi/ts-host.mjs',
            ], names
            assert [member.mode for member in archive.getmembers()] == [0o755, 0o644, 0o644, 0o644, 0o644, 0o644]
            for relative in ('bin/zpi', 'include/zpi_plugin.h', 'include/zpi_plugin_runtime.h',
                             'LICENSE', 'share/zpi/pi-sdk.mjs', 'share/zpi/ts-host.mjs'):
                assert archive.extractfile(f'zpi/{relative}').read() == (prefix / relative).read_bytes()
        with tarfile.open(release_output, 'r:gz') as archive:
            assert [m.name for m in archive.getmembers()] == [f'{release_root}/{name}' for name in (
                'bin/zpi', 'include/zpi_plugin.h', 'include/zpi_plugin_runtime.h', 'LICENSE',
                'share/zpi/pi-sdk.mjs', 'share/zpi/ts-host.mjs')]
        bad_root = subprocess.run([sys.executable, str(PACKAGER), str(prefix), str(root / 'bad-root.tar.gz'),
                                   '--root-name', '../escape'], text=True, capture_output=True)
        assert bad_root.returncode == 2 and not (root / 'bad-root.tar.gz').exists(), bad_root
        refusal = subprocess.run([sys.executable, str(PACKAGER), str(prefix), str(output)],
                                 text=True, capture_output=True)
        assert refusal.returncode == 1 and output.read_bytes() == original, refusal
        executable = prefix / 'bin/zpi'
        executable.unlink()
        missing = root / 'missing.tar.gz'
        for kind in ('missing', 'symlink', 'fifo'):
            if kind == 'symlink':
                executable.symlink_to(prefix / 'include/zpi_plugin.h')
            elif kind == 'fifo':
                os.mkfifo(executable)
            refusal = subprocess.run([sys.executable, str(PACKAGER), str(prefix), str(missing)],
                                     text=True, capture_output=True, timeout=5)
            assert refusal.returncode == 1 and not missing.exists(), refusal
            if kind != 'missing':
                executable.unlink()
        print('Release package fixture passed (stable bytes and modes, no overwrite, invalid inputs rejected)')


if __name__ == '__main__':
    main()
