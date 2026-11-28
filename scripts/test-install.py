#!/usr/bin/env python3
"""Run the Zpi installer with fixture curl and package manager executables."""
import errno
import hashlib
import os
import pty
import select
import shutil
import time
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def make_archive(directory, version, platform='macos-arm64'):
    name = f'zpi-{version}-{platform}'
    package = directory / name
    for relative in ('bin/zpi', 'LICENSE', 'include/zpi_plugin.h', 'include/zpi_plugin_runtime.h', 'share/zpi/pi-sdk.mjs', 'share/zpi/ts-host.mjs'):
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if relative == 'bin/zpi':
            target.write_text(f'#!/bin/sh\nprintf \'zpi {version}\\n\'\n')
            target.chmod(0o755)
        else:
            target.write_text(f'fixture {relative}\n')
    archive = directory / f'{name}.tar.gz'
    subprocess.run(['tar', '-czf', str(archive), '-C', str(directory), name], check=True)
    return archive.name, archive.read_bytes()


def write_executable(path, body):
    path.write_text('#!/bin/sh\n' + body)
    path.chmod(0o755)


def interactive_install(installer, env, response):
    pid, master = pty.fork()
    if pid == 0:
        os.execve('/bin/sh', ['/bin/sh', str(installer)], env)
    output = bytearray()
    answered = False
    deadline = time.monotonic() + 10
    try:
        while True:
            timeout = max(0, deadline - time.monotonic())
            ready, _, _ = select.select([master], [], [], timeout)
            assert ready, bytes(output)
            try:
                chunk = os.read(master, 4096)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            output.extend(chunk)
            if not answered and b'[y/N]' in output:
                os.write(master, response)
                answered = True
    finally:
        os.close(master)
        _, status = os.waitpid(pid, 0)
    assert answered and os.waitstatus_to_exitcode(status) == 0, bytes(output)


def main():
    with tempfile.TemporaryDirectory(prefix='zpi-install-test-') as temp:
        root = Path(temp)
        fixture = root / 'fixture'
        fixture.mkdir()
        name, archive = make_archive(fixture, '9.8.7')
        digest = hashlib.sha256(archive).hexdigest()
        server = root / 'release'
        server.mkdir()
        (server / name).write_bytes(archive)
        (server / f'{name}.sha256').write_text(f'{digest}  {name}\n')
        fakebin = root / 'fakebin'
        fakebin.mkdir()
        write_executable(fakebin / 'curl', '''
url=
output=
while [ "$#" -gt 0 ]; do
    case $1 in
        -q|-fsSL|-sSL|-f) ;;
        --proto|--proto-redir|--retry|--connect-timeout|--max-time) shift ;;
        -o) shift; output=$1 ;;
        -w) shift; [ "$1" = '%{url_effective}' ] || exit 22 ;;
        *) url=$1 ;;
    esac
    shift
done
case $url in
https://github.com/syuchua/zpi/releases/latest) cat "$ZPI_FIXTURE_RELEASE/latest-url" ;;
https://github.com/syuchua/zpi/releases/download/*) file=${url##*/}; [ -f "$ZPI_FIXTURE_RELEASE/$file" ] || exit 22
    cp "$ZPI_FIXTURE_RELEASE/$file" "$output" ;;
*) exit 22 ;;
esac
''')
        (server / 'latest-url').write_text('https://github.com/syuchua/zpi/releases/tag/v9.8.7')
        write_executable(fakebin / 'uname', 'case $1 in -m) echo arm64 ;; -s) echo Darwin ;; *) exit 1 ;; esac\n')
        for utility in ('awk', 'tar', 'mkdir', 'mktemp', 'mv', 'rm', 'chmod', 'ln', 'readlink', 'cp', 'cat', 'rmdir'):
            (fakebin / utility).symlink_to(shutil.which(utility))
        hasher = 'sha256sum' if shutil.which('sha256sum') else 'shasum'
        (fakebin / hasher).symlink_to(shutil.which(hasher))
        # Exercise the Darwin installer on GNU hosts too. GNU mv spells -h as -T.
        if os.uname().sysname == 'Linux':
            (fakebin / 'mv').unlink()
            write_executable(fakebin / 'mv', f'''if [ "$1" = -fh ]; then shift; set -- -fT "$@"; fi
exec {shutil.which('mv')} "$@"
''')
        log = root / 'package.log'
        write_executable(fakebin / 'brew', 'printf "%s\\n" "$*" >> "$ZPI_PACKAGE_LOG"\n')
        env = dict(os.environ)
        home = root / 'home'
        env.update({
            'HOME': str(home),
            'PATH': str(fakebin),
            'ZPI_FIXTURE_RELEASE': str(server),
            'ZPI_PACKAGE_LOG': str(log),
        })
        env.pop('ZPI_VERSION', None)
        installer = ROOT / 'install.sh'
        result = subprocess.run(['/bin/sh', str(installer), '--without-search-tools'], env=env, text=True, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        link = home / '.local/bin/zpi'
        assert link.is_symlink()
        assert subprocess.check_output([str(link), '--version'], text=True).strip() == 'zpi 9.8.7'
        old_target = link.resolve()
        assert not log.exists(), 'skip option must not invoke package managers'

        headless = subprocess.run(['/bin/sh', str(installer)], env=env, text=True, capture_output=True, start_new_session=True, timeout=10)
        assert headless.returncode == 0, headless.stderr
        assert 'ripgrep' in headless.stdout and 'fdfind' in headless.stdout
        assert not log.exists(), 'headless default must skip package managers'

        interactive_install(installer, env, b'\n')
        assert not log.exists(), 'empty confirmation must skip package managers'
        write_executable(fakebin / 'fdfind', 'exit 0\n')
        interactive_install(installer, env, b'y\n')
        assert log.read_text() == 'install ripgrep\n'
        (fakebin / 'fdfind').unlink()
        explicit = subprocess.run(['/bin/sh', '-s', '--', '--with-search-tools'], input=installer.read_text(), env=env, text=True, capture_output=True, start_new_session=True, timeout=10)
        assert explicit.returncode == 0, explicit.stderr
        assert log.read_text().splitlines() == ['install ripgrep', 'install ripgrep fd']

        # Install a second version and ensure the active link changes while the
        # original target remains available for rollback.
        new_name, new_archive = make_archive(fixture, '9.8.8')
        (server / new_name).write_bytes(new_archive)
        (server / f'{new_name}.sha256').write_text(f'{hashlib.sha256(new_archive).hexdigest()}  {new_name}\n')
        env['ZPI_VERSION'] = '9.8.8'
        upgrade = subprocess.run(['/bin/sh', str(installer), '--without-search-tools'], env=env, text=True, capture_output=True, timeout=10)
        assert upgrade.returncode == 0, upgrade.stderr
        assert subprocess.check_output([str(link), '--version'], text=True).strip() == 'zpi 9.8.8'

        assert old_target.is_file(), 'upgrades should preserve the prior installation'
        upgraded_target = link.resolve()

        # A corrupt checksum must leave the working link untouched.
        (server / f'{new_name}.sha256').write_text('0' * 64 + f'  {new_name}\n')
        broken = subprocess.run(['/bin/sh', str(installer), '--without-search-tools'], env=env, text=True, capture_output=True, timeout=10)
        assert broken.returncode != 0
        assert subprocess.check_output([str(link), '--version'], text=True).strip() == 'zpi 9.8.8'
        assert link.resolve() == upgraded_target

        # Streamed bash execution (`curl ... | bash`) works identically to sh.
        if shutil.which('bash'):
            (server / f'{new_name}.sha256').write_text(f'{hashlib.sha256(new_archive).hexdigest()}  {new_name}\n')
            bash_run = subprocess.run([shutil.which('bash'), '-s', '--', '--without-search-tools'], input=installer.read_text(), env=env, text=True, capture_output=True, timeout=10)
            assert bash_run.returncode == 0, bash_run.stderr
            assert subprocess.check_output([str(link), '--version'], text=True).strip() == 'zpi 9.8.8'

        # Must refuse to replace a regular non-symlink file at ~/.local/bin/zpi.
        regular_home = root / 'regular-home'
        regular_link = regular_home / '.local/bin/zpi'
        regular_link.parent.mkdir(parents=True)
        regular_link.write_text('user binary\n')
        regular_env = dict(env, HOME=str(regular_home))
        refused = subprocess.run(['/bin/sh', str(installer), '--without-search-tools'], env=regular_env, text=True, capture_output=True, timeout=10)
        assert refused.returncode != 0 and 'non-symlink' in refused.stderr, refused.stderr
        assert regular_link.read_text() == 'user binary\n'

        # Exercise Linux x64-gnu and arm64-musl platform detection.
        for arch_raw, platform, has_gnu in (('x86_64', 'linux-x64-gnu', True), ('aarch64', 'linux-arm64-musl', False)):
            linux_bin = root / f'fakebin-{platform}'
            linux_bin.mkdir()
            for entry in fakebin.iterdir():
                if entry.name in ('uname', 'mv'):
                    continue
                (linux_bin / entry.name).symlink_to(entry)
            write_executable(linux_bin / 'uname', f'case $1 in -m) echo {arch_raw} ;; -s) echo Linux ;; *) exit 1 ;; esac\n')
            # Map Linux `mv -fT` to `mv -fh` when running this fixture on macOS.
            if os.uname().sysname == 'Darwin':
                write_executable(linux_bin / 'mv', f'if [ "$1" = -fT ]; then shift; set -- -fh "$@"; fi\nexec {shutil.which("mv")} "$@"\n')
            else:
                (linux_bin / 'mv').symlink_to(shutil.which('mv'))
            if has_gnu:
                write_executable(linux_bin / 'getconf', 'echo "glibc 2.39"\n')
            else:
                write_executable(linux_bin / 'getconf', 'exit 1\n')
                write_executable(linux_bin / 'ldd', 'echo "musl libc (aarch64)" >&2\nexit 1\n')
            pname, parchive = make_archive(fixture, '9.8.9', platform=platform)
            (server / pname).write_bytes(parchive)
            (server / f'{pname}.sha256').write_text(f'{hashlib.sha256(parchive).hexdigest()}  {pname}\n')
            lhome = root / f'home-{platform}'
            lenv = dict(env, HOME=str(lhome), PATH=str(linux_bin), ZPI_VERSION='9.8.9')
            lres = subprocess.run(['/bin/sh', str(installer), '--without-search-tools'], env=lenv, text=True, capture_output=True, timeout=10)
            assert lres.returncode == 0, (platform, lres.stderr)
            assert platform in lres.stdout, lres.stdout
            assert subprocess.check_output([str(lhome / '.local/bin/zpi'), '--version'], text=True).strip() == 'zpi 9.8.9'

        print('Installer fixture passed: macOS/Linux detection, bash/sh streaming, upgrades, non-symlink refusal, checksum failure, and search-tool opt-in')


if __name__ == '__main__':
    main()
