"""Run in Linux with base64 bootstrap source as argv[1]; no real apt installs."""
import base64
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SOURCE = base64.b64decode(sys.argv.pop(1)).decode('utf-8-sig').replace('\r\n', '\n')


class BootstrapTests(unittest.TestCase):
    def run_bootstrap(self, packages):
        with tempfile.TemporaryDirectory(prefix='vc-kali-test-') as folder:
            root = pathlib.Path(folder)
            bootstrap = root / 'bootstrap.sh'
            bootstrap.write_text(SOURCE)
            trace = root / 'apt.log'
            stubs = {
                'apt-get': 'echo "$*" >> "$TRACE"\n[[ "$*" != *bad-tool* ]]',
                'dpkg-query': 'case "${@: -1}" in good-tool|bad-tool) exit 1;; *) printf installed;; esac',
                'id': 'exit 0',
                'getent': 'echo "testuser:x:1000:1000::/fake/home:/bin/bash"',
                'runuser': 'exit 0',
            }
            for name, body in stubs.items():
                path = root / name
                path.write_text('#!/bin/bash\n' + body + '\n')
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], TRACE=str(trace))
            result = subprocess.run(['bash', str(bootstrap), 'full', 'a' * 40, 'latest',
                                     'testuser', '/fake/repo', '/fake/python', '/fake/opencode',
                                     'yes', *packages], env=env, text=True, capture_output=True, timeout=20)
            return result, trace.read_text()

    def test_one_failed_package_does_not_block_other_packages(self):
        result, trace = self.run_bootstrap(['bad-tool', 'good-tool'])
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn('install -y good-tool', trace)
        self.assertIn('KALI PACKAGES FAILED: bad-tool', result.stderr)

    def test_installed_packages_skipped_and_requests_deduplicated(self):
        result, trace = self.run_bootstrap(['good-tool', 'good-tool'])
        self.assertEqual(result.returncode, 0, result.stderr)
        installs = [line for line in trace.splitlines() if 'install -y' in line]
        self.assertEqual(len(installs), 1)
        self.assertEqual(installs[0].count('good-tool'), 1)
        self.assertNotIn('python3', installs[0])


unittest.main()
