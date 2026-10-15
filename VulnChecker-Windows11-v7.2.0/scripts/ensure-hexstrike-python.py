"""Provision isolated HexStrike environments without altering system Python or upstream."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import urllib.request
import uuid
import zipfile


def load_policy():
    return json.loads(Path(__file__).with_name('hexstrike-python.json').read_text())


def check_imports(python, imports):
    source = 'import importlib; [importlib.import_module(m) for m in ' + repr(imports) + ']'
    result = subprocess.run([str(python), '-c', source], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Runtime import check failed')


def ensure_uv(root, policy):
    if platform.machine() not in ('x86_64', 'AMD64'):
        raise RuntimeError('The bundled runtime download supports Linux x86_64 only')
    destination = root / 'uv' / policy['uvVersion'] / 'uv'
    if destination.is_file():
        result = subprocess.run([str(destination), '--version'], capture_output=True, text=True, timeout=15)
        if result.returncode == 0 and result.stdout.split()[:2] == ['uv', policy['uvVersion']]:
            return destination
    print('Downloading verified uv runtime manager', flush=True)
    with urllib.request.urlopen(policy['uvWheel'], timeout=120) as response:
        wheel = response.read()
    if hashlib.sha256(wheel).hexdigest() != policy['uvSha256']:
        raise RuntimeError('uv wheel SHA256 mismatch; downloaded code will not be executed')
    with zipfile.ZipFile(io.BytesIO(wheel)) as archive:
        candidates = [name for name in archive.namelist() if name.endswith('.data/scripts/uv')]
        if len(candidates) != 1:
            raise RuntimeError('Unexpected uv wheel layout')
        binary = archive.read(candidates[0])
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name('uv.' + uuid.uuid4().hex + '.tmp')
    temporary.write_bytes(binary)
    temporary.chmod(0o700)
    temporary.replace(destination)
    return destination


def managed_environment(root):
    env = dict(os.environ)
    env.update(UV_PYTHON_INSTALL_DIR=str(root / 'python'), UV_CACHE_DIR=str(root / 'cache'),
               UV_PYTHON_INSTALL_BIN='0', UV_NO_CONFIG='1', UV_MANAGED_PYTHON='1')
    return env


def ready(target, imports, version):
    python = target / 'bin/python'
    marker = target / 'vulnchecker-runtime.json'
    if not python.is_file() or not marker.is_file():
        return False
    try:
        data = json.loads(marker.read_text())
        if data.get('policy') != version:
            return False
        minor = tuple(int(part) for part in data['python'].split('.')[:2])
        check = 'import pathlib,sys; assert sys.version_info[:2] == ' + repr(minor) + '; assert pathlib.Path(sys.base_prefix).is_relative_to(pathlib.Path(' + repr(data['managedPython']) + '))'
        subprocess.run([str(python), '-c', check], check=True, capture_output=True, timeout=15)
        check_imports(python, imports)
        return True
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError):
        return False


def provision(repo, component, policy, root=None):
    root = root or Path.home() / '.local/share/vulnchecker-python'
    target = repo if component == 'mobile' else repo / ('.venv-core' if component == 'core' else '.venv-binary')
    imports = policy[component + 'Imports']
    requirements = policy[component + 'Requirements']
    fingerprint = hashlib.sha256(json.dumps([policy['python'], requirements, imports]).encode()).hexdigest()
    if ready(target, imports, fingerprint):
        print(f'Reusing isolated {component} environment: {target}', flush=True)
        return target / 'bin/python'
    root.mkdir(parents=True, exist_ok=True)
    uv = ensure_uv(root, policy)
    env = managed_environment(root)
    subprocess.run([str(uv), 'python', 'install', policy['python'], '--no-bin', '--no-config'], env=env, check=True)
    if target.exists():
        # Keep an unsuccessful/older environment recoverable. A new venv must
        # be created at its final path because entry-point shebangs are absolute.
        backup = target.with_name(target.name + '.before-repair-' + uuid.uuid4().hex)
        target.rename(backup)
        print(f'Preserved previous {component} environment: {backup}', flush=True)
    subprocess.run([str(uv), 'venv', '--python', policy['python'], '--managed-python',
                    '--no-config', str(target)], env=env, check=True)
    requirement_file = root / ('requirements-' + component + '-' + fingerprint + '.txt')
    requirement_file.write_text('\n'.join(requirements) + '\n')
    python = target / 'bin/python'
    # Native dependencies require compatible wheels. Pure Python packages
    # such as pyperclip may publish only source archives.
    subprocess.run([str(uv), 'pip', 'install', '--python', str(python), '--only-binary', ','.join(policy['onlyBinary']),
                    '-r', str(requirement_file)], env=env, check=True)
    subprocess.run([str(uv), 'pip', 'check', '--python', str(python)], env=env, check=True)
    check_imports(python, imports)
    actual = subprocess.check_output([str(python), '-c', 'import sys; print(sys.version.split()[0])'], text=True).strip()
    (target / 'vulnchecker-runtime.json').write_text(json.dumps({
        'component': component, 'policy': fingerprint, 'python': actual,
        'requirements': requirements, 'managedPython': str(root / 'python')}, indent=2))
    print(f'Isolated {component} Python {actual} ready: {python}', flush=True)
    return python


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', required=True, type=Path)
    parser.add_argument('--component', choices=['core', 'binary', 'mobile'], default='core')
    args = parser.parse_args()
    policy = load_policy()
    provision(args.repository, args.component, policy)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'Isolated Python setup failed: {exc}', file=sys.stderr)
        raise SystemExit(1)
