"""Isolated provisioning and routing tests; no real downloads or scans."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


installer = load('installer', ROOT / 'scripts/ensure-hexstrike-python.py')
routing = load('routing', ROOT / 'scripts/hexstrike-python-routing.py')
POLICY = installer.load_policy()


class RuntimeTests(unittest.TestCase):
    def test_core_policy_excludes_optional_dependencies(self):
        core = '\n'.join(POLICY['coreRequirements']).lower()
        self.assertNotIn('angr', core)
        self.assertNotIn('pwntools', core)
        self.assertIn('mitmproxy', core)
        self.assertEqual(POLICY['python'], '3.11')

    def exercise(self, component, fail=False):
        with tempfile.TemporaryDirectory(prefix='vc-python-test-') as folder:
            repo = Path(folder) / 'repo'; repo.mkdir()
            original = repo / '.venv'; original.mkdir()
            (original / 'keep.txt').write_text('old environment')
            core = repo / '.venv-core'; core.mkdir()
            (core / 'existing.txt').write_text('preserve core')
            commands = []

            def run(args, **kwargs):
                commands.append((args, kwargs))
                if fail and args[1:3] == ['pip', 'install']:
                    raise subprocess.CalledProcessError(1, args)
                if args[1] == 'venv':
                    target = Path(args[-1]); (target / 'bin').mkdir(parents=True)
                    (target / 'bin/python').write_text('mock')
                return subprocess.CompletedProcess(args, 0, stdout='')

            with patch.object(installer, 'ensure_uv', return_value=Path('/mock/uv')), \
                 patch.object(installer.subprocess, 'run', side_effect=run), \
                 patch.object(installer.subprocess, 'check_output', return_value='3.11.17\n'), \
                 patch.object(installer, 'check_imports'):
                if fail:
                    with self.assertRaises(subprocess.CalledProcessError):
                        installer.provision(repo, component, POLICY, Path(folder) / 'manager')
                else:
                    python = installer.provision(repo, component, POLICY, Path(folder) / 'manager')
                    self.assertEqual(python.parent.parent.name, '.venv-' + component)
                self.assertEqual((original / 'keep.txt').read_text(), 'old environment')
                if component == 'binary':
                    self.assertEqual((core / 'existing.txt').read_text(), 'preserve core')
            creation = next(args for args, kwargs in commands if args[1] == 'venv')
            self.assertIn('--managed-python', creation)
            self.assertEqual(creation[creation.index('--python') + 1], '3.11')
            install_args, install_kwargs = next(item for item in commands if item[0][1:3] == ['pip', 'install'])
            self.assertIn('pyvex', install_args[install_args.index('--only-binary') + 1])
            self.assertEqual(install_kwargs['env']['UV_PYTHON_INSTALL_BIN'], '0')
            requirements = Path(install_args[-1]).read_text()
            self.assertEqual('angr' in requirements, component == 'binary')

    def test_core_preserves_old_environment_and_uses_managed_python(self):
        self.exercise('core')

    def test_optional_environment_does_not_modify_core(self):
        self.exercise('binary')

    def test_optional_failure_leaves_core_untouched(self):
        self.exercise('binary', fail=True)

    def test_valid_environment_reused_without_download(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(installer, 'ready', return_value=True), \
             patch.object(installer, 'ensure_uv', side_effect=AssertionError('unexpected download')):
            installer.provision(Path(folder), 'core', POLICY)

    def test_corrupt_uv_archive_is_rejected(self):
        import io
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(installer.urllib.request, 'urlopen', return_value=io.BytesIO(b'corrupt')):
            with self.assertRaisesRegex(RuntimeError, 'SHA256 mismatch'):
                installer.ensure_uv(Path(folder), POLICY)

    def test_binary_commands_use_only_optional_python(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            command = 'python3 /tmp/angr_analysis.py --test'
            with self.assertRaisesRegex(RuntimeError, 'BinaryAnalysisTools'):
                routing.route_binary_python(command, repo)
            target = repo / '.venv-binary/bin'; target.mkdir(parents=True)
            (target / 'python').write_text('mock')
            self.assertIn('.venv-binary/bin/python', routing.route_binary_python(command, repo))
            self.assertIn('.venv-binary/bin/python', routing.route_binary_python('python3 /tmp/pwntools_exploit.py', repo))
            other = 'python3 /tmp/unrelated.py'
            self.assertEqual(routing.route_binary_python(other, repo), other)


unittest.main()
