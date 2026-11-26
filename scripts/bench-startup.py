#!/usr/bin/env python3
"""Compare fresh-process --version startup for Zpi, pi, and optionally rpi."""
import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run_samples(command, samples, cwd, environment):
    durations = []
    rss_bytes = []
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        for _ in range(samples):
            start = time.perf_counter_ns()
            process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr)
            signal.alarm(30)
            try:
                _, status, usage = os.wait4(process.pid, 0)
            except TimeoutError:
                process.kill()
                raise RuntimeError(f'{command[0]} exceeded the sample deadline') from None
            finally:
                signal.alarm(0)
            process.returncode = os.waitstatus_to_exitcode(status)
            if process.returncode != 0:
                stderr.seek(0)
                raise RuntimeError(f'{command[0]} failed: {stderr.read().decode(errors="replace")}')
            durations.append(time.perf_counter_ns() - start)
            rss_bytes.append(usage.ru_maxrss if platform.system() == 'Darwin' else usage.ru_maxrss * 1024)
    ordered = sorted(durations)
    return {
        'p50_ms': statistics.median(ordered) / 1_000_000,
        'p95_ms': ordered[math.ceil(0.95 * len(ordered)) - 1] / 1_000_000,
        'max_peak_rss_bytes': max(rss_bytes),
        'samples': samples,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zpi', type=Path, required=True)
    parser.add_argument('--pi', default='pi', help='pi executable path or PATH name (default: pi)')
    parser.add_argument('--rpi', help='optional rpi executable path or PATH name')
    parser.add_argument('--samples', type=int, default=20)
    args = parser.parse_args()
    if not 1 <= args.samples <= 100:
        parser.error('--samples must be between 1 and 100')

    zpi = args.zpi.resolve(strict=True)
    pi = Path(shutil.which(args.pi) or args.pi).resolve(strict=True)
    rpi = Path(shutil.which(args.rpi) or args.rpi).resolve(strict=True) if args.rpi else None
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError()))
    node = shutil.which('node')
    path = os.defpath if node is None else os.pathsep.join((os.defpath, str(Path(node).parent)))
    with tempfile.TemporaryDirectory(prefix='zpi-startup-bench-') as home:
        environment = {'PATH': path, 'HOME': home}
        version_commands = {
            'zpi': [str(zpi), '--version'],
            'pi': [str(pi), '--version'],
        }
        if rpi is not None:
            version_commands['rpi'] = [str(rpi), '--version']
        versions = {
            name: subprocess.check_output(command, cwd=home, env=environment,
                                          stdin=subprocess.DEVNULL, timeout=30).decode().strip()
            for name, command in version_commands.items()
        }
        report = {
            'system': platform.system(),
            'release': platform.release(),
            'machine': platform.machine(),
            'python': platform.python_version(),
            'zpi_version': versions['zpi'],
            'pi_version': versions['pi'],
            **({'rpi_version': versions['rpi']} if rpi is not None else {}),
            'zpi_sha256': hashlib.sha256(zpi.read_bytes()).hexdigest(),
            'pi_executable_sha256': hashlib.sha256(pi.read_bytes()).hexdigest(),
            **({'rpi_executable_sha256': hashlib.sha256(rpi.read_bytes()).hexdigest()} if rpi is not None else {}),
            'measurement': 'fresh process --version; elapsed wall time includes Python wait4 harness and process launch',
            'results': {
                name: run_samples(command, args.samples, home, environment)
                for name, command in version_commands.items()
            },
        }
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
