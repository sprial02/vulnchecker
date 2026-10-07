"""Read-only tool discovery. No package installation, imports of tools or scans."""
import base64
import importlib.util
import json
import os
import pathlib
import pwd
import shutil
import subprocess
import sys

options = json.loads(base64.b64decode(sys.argv[1])) if len(sys.argv) > 1 else {}
home = pathlib.Path.home()
names = ['nmap', 'ffuf', 'sqlmap', 'nikto', 'nuclei', 'gobuster', 'feroxbuster',
         'jadx', 'apktool', 'frida', 'objection', 'opencode']
commands = {}
for name in names:
    candidates = [shutil.which(name), str(home / '.local/bin' / name),
                  str(home / 'tools/mobile-venv/bin' / name),
                  '/home/vulnchecker/tools/mobile-venv/bin/' + name]
    if name == 'opencode':
        candidates += [options.get('opencodePath'), str(home / '.opencode/bin/opencode'),
                       str(home / 'tools/opencode/node_modules/.bin/opencode'),
                       '/home/vulnchecker/tools/opencode/node_modules/.bin/opencode']
    commands[name] = next((p for p in candidates if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)

repos = [options.get('hexstrikePath'), str(home / 'tools/hexstrike-ai'),
         str(home / 'hexstrike-ai'), '/opt/hexstrike-ai', '/home/vulnchecker/tools/hexstrike-ai']
repo = next((p for p in repos if p and os.path.isfile(os.path.join(p, 'hexstrike_server.py'))
             and os.path.isfile(os.path.join(p, 'hexstrike_mcp.py'))), None)
hex_info = {'path': repo, 'python': None, 'dependencies': None, 'commit': None}
if repo:
    python_candidates = [options.get('hexstrikePython')]
    python_candidates += [os.path.join(repo, p, 'bin/python') for p in ['.venv', 'hexstrike-env', 'venv']]
    python_candidates += [str(home / 'hexstrike-env/bin/python'), shutil.which('python3')]
    dependency_check = "import importlib.util, json; print(json.dumps(all(importlib.util.find_spec(m) is not None for m in ['flask','requests','mcp'])))"
    for python in python_candidates:
        if not python or not os.path.isfile(python):
            continue
        try:
            result = subprocess.run([python, '-c', dependency_check], capture_output=True, text=True, timeout=15)
            if result.returncode == 0 and result.stdout.strip() == 'true':
                hex_info.update(python=python, dependencies=True)
                break
        except (OSError, subprocess.TimeoutExpired):
            pass
    if hex_info['dependencies'] is None:
        hex_info['dependencies'] = False
    try:
        result = subprocess.run(['git', '-C', repo, 'rev-parse', 'HEAD'], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            hex_info['commit'] = result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass

print(json.dumps({'user': pwd.getpwuid(os.getuid()).pw_name, 'home': str(home),
                  'kernel': os.uname().release, 'commands': commands, 'hexstrike': hex_info}, ensure_ascii=True))
