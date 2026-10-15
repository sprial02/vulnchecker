"""Build single-file Unix/Windows launchers from the clean pinned KISA source."""
import argparse
import base64
import hashlib
import html
import io
import json
from pathlib import Path
import shutil
import subprocess
import textwrap
import zipfile

from prepare_source import prepare, REVISION
from source_compat import adapt
from profiles import CATALOG

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT.parent


def source_files(source, family):
    files = {}
    changes = []
    folders = ['lib'] + [p['Folder'] for p in CATALOG.values() if p['Family'] == family]
    for folder in folders:
        for path in sorted((source / folder).rglob('*')):
            if not path.is_file() or path.suffix not in ('.sh', '.ps1'):
                continue
            if path.is_symlink():
                raise ValueError('Source symlinks are not allowed')
            if folder == 'lib' and ((family == 'posix' and path.suffix != '.sh') or (family == 'windows' and path.suffix != '.ps1')):
                continue
            relative = path.relative_to(source).as_posix()
            data = path.read_bytes().replace(b'\r\n', b'\n')
            if path.suffix == '.sh':
                data, change = adapt(relative, data)
                if change:
                    changes.append(change)
            elif not data.startswith(b'\xef\xbb\xbf'):
                data = b'\xef\xbb\xbf' + data
            files[relative] = data
    for profile in CATALOG.values():
        if profile['Family'] != family:
            continue
        suffix = '.sh' if family == 'posix' else '.ps1'
        for n in range(1, profile['Count'] + 1):
            name = f"{profile['Folder']}/{profile['Prefix']}{n:02}_check{suffix}"
            if name not in files:
                raise ValueError('Missing required check: ' + name)
    files['profiles.json'] = (ROOT / 'profiles.json').read_bytes()
    files['LICENSE.upstream.txt'] = (source / 'LICENSE').read_bytes()
    files['AGPL-3.0.txt'] = (ROOT / 'licenses/AGPL-3.0.txt').read_bytes()
    files['source-compatibility.json'] = json.dumps({'source_revision': REVISION, 'adaptations': changes}, ensure_ascii=False, indent=2).encode()
    files['SOURCE-NOTICE.txt'] = (f'KISA-CIIP-2026: https://github.com/rebugui/KISA-CIIP-2026\nPinned revision: {REVISION}\n'
        'Copyright (c) 2026 Yang Uhyeok. Upstream and integrated launcher source distributed under AGPL-3.0-or-later.\n'
        'All effective source is embedded in the launcher. --extract-only / -ExtractOnly extracts source without assessment.\n'
        'Compatibility adaptations are listed with before/after hashes in source-compatibility.json.\n').encode()
    scripts = ['offline-unix.py', 'linux-execute.py', 'profiles.py', 'discover-target.py', 'run.py',
               'prepare_source.py', 'source_compat.py', 'failure_reasons.py'] if family == 'posix' else ['windows-execute.ps1']
    for name in scripts:
        files['scripts/' + name] = (ROOT / 'scripts' / name).read_bytes()
    return files


def zipped(files):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100600 << 16
            archive.writestr(info, data)
    return stream.getvalue()


def unix_launcher(payload):
    digest = hashlib.sha256(payload).hexdigest()
    bootstrap = '''#!/usr/bin/env bash
# TriGuard local Unix assessment. Effective source and AGPL license: --extract-only DIR.
set -eu
export PYTHONIOENCODING=utf-8
if ! command -v python3 >/dev/null 2>&1; then
  echo 'Python 3.8+ is required. Ask the server administrator to prepare it; no installation is attempted.' >&2
  exit 3
fi
exec python3 - "$0" "$@" <<'TRIGUARD_BOOTSTRAP'
import base64, hashlib, io, os, pathlib, subprocess, sys, tempfile, zipfile
if sys.version_info < (3, 8):
    sys.exit('Python 3.8+ is required.')
os.umask(0o077)
launcher = pathlib.Path(sys.argv[1]).resolve()
encoded = launcher.read_bytes().split(b'\\n__TRIGUARD_PAYLOAD__\\n', 1)[1]
data = base64.b64decode(encoded, validate=False)
if hashlib.sha256(data).hexdigest() != '__SHA__':
    sys.exit('Embedded source integrity check failed.')
args = sys.argv[2:]
extract = bool(args and args[0] == '--extract-only')
if extract and len(args) != 2:
    sys.exit('Usage: bash Unix-Infrastructure.sh --extract-only NEW_DIRECTORY')
def unpack(destination):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for entry in archive.infolist():
            path = destination / entry.filename
            try:
                path.resolve().relative_to(destination.resolve())
            except ValueError:
                sys.exit('Invalid embedded source path.')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(archive.read(entry))
if extract:
    destination = pathlib.Path(args[1]).expanduser().resolve()
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    unpack(destination)
    print('Source and license extracted: ' + str(destination))
else:
    with tempfile.TemporaryDirectory(prefix='triguard-offline-') as folder:
        destination = pathlib.Path(folder)
        unpack(destination)
        env = dict(os.environ, TRIGUARD_LAUNCH_DIR=str(launcher.parent))
        result = subprocess.call([sys.executable, str(destination / 'scripts/offline-unix.py')] + args, env=env)
        sys.exit(result)
TRIGUARD_BOOTSTRAP
exit 3
__TRIGUARD_PAYLOAD__
'''
    return bootstrap.replace('__SHA__', digest).encode() + (textwrap.fill(base64.b64encode(payload).decode(), 100) + '\n').encode()


def render_guide(markdown):
    # Only the project's static guide is rendered; embedded commands are HTML-escaped.
    pieces = []
    in_code = False
    for line in markdown.splitlines():
        if line.startswith('```'):
            pieces.append('</code></pre>' if in_code else '<pre><code>')
            in_code = not in_code
        elif in_code:
            pieces.append(html.escape(line) + '\n')
        elif line.startswith('# '):
            pieces.append('<h1>' + html.escape(line[2:]) + '</h1>')
        elif line.startswith('## '):
            pieces.append('<h2>' + html.escape(line[3:]) + '</h2>')
        elif line.startswith('- '):
            pieces.append('<p class="item">• ' + html.escape(line[2:]) + '</p>')
        elif line:
            pieces.append('<p>' + html.escape(line) + '</p>')
    return '<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>인프라 자체 점검 실행 안내</title><style>body{font:16px/1.75 "Malgun Gothic",sans-serif;color:#172b44;background:#f1f5f9;margin:0}main{max-width:960px;margin:28px auto;background:white;padding:40px;border-radius:12px}h1{font-size:28px}h2{margin-top:36px;border-top:1px solid #d8e0ea;padding-top:24px}pre{background:#14263c;color:#e5f1ff;padding:18px;white-space:pre-wrap;overflow-wrap:anywhere;border-radius:8px}.item{margin:6px 0}@media print{body{background:white}main{margin:0;padding:10px}pre{color:black;background:#eee}}</style><main>' + '\n'.join(pieces) + '</main></html>'


def build(source, output):
    output.mkdir(parents=True, exist_ok=True)
    unix_files = source_files(source, 'posix')
    windows_files = source_files(source, 'windows')
    (output / 'Unix-Infrastructure.sh').write_bytes(unix_launcher(zipped(unix_files)))
    windows = (ROOT / 'scripts/offline-windows.ps1').read_text(encoding='utf-8-sig')
    windows_data = zipped(windows_files)
    windows = windows.replace('__PAYLOAD_BASE64__', base64.b64encode(windows_data).decode()).replace('__PAYLOAD_SHA256__', hashlib.sha256(windows_data).hexdigest())
    (output / 'Windows-Infrastructure.ps1').write_text(windows, encoding='utf-8-sig')
    guide = (APP / 'docs/CUSTOMER-OFFLINE.ko.md').read_text(encoding='utf-8')
    (output / 'README.ko.txt').write_text(guide, encoding='utf-8-sig')
    (output / 'README.ko.html').write_text(render_guide(guide), encoding='utf-8')
    (output / 'AGPL-3.0.txt').write_bytes(unix_files['AGPL-3.0.txt'])
    (output / 'LICENSE.upstream.txt').write_bytes(unix_files['LICENSE.upstream.txt'])
    all_source = {'unix/' + k: v for k, v in unix_files.items()}
    all_source.update({'windows/' + k: v for k, v in windows_files.items()})
    for name in ('build-offline.py', 'offline-windows.ps1', 'offline-unix.py', 'profiles.py', 'prepare_source.py',
                 'source_compat.py', 'linux-execute.py', 'windows-execute.ps1', 'run.py', 'failure_reasons.py', 'discover-target.py'):
        all_source['integration/infrastructure/scripts/' + name] = (ROOT / 'scripts' / name).read_bytes()
    all_source['integration/infrastructure/profiles.json'] = (ROOT / 'profiles.json').read_bytes()
    all_source['integration/infrastructure/licenses/AGPL-3.0.txt'] = unix_files['AGPL-3.0.txt']
    all_source['integration/docs/CUSTOMER-OFFLINE.ko.md'] = guide.encode()
    for relative in set(unix_files) | set(windows_files):
        if relative.startswith(('lib/', '01.', '02.', '03.', '07.', '08.')) and (source / relative).is_file():
            all_source['upstream/' + relative] = (source / relative).read_bytes()
    if (source / 'LICENSE').is_file():
        all_source['upstream/LICENSE'] = (source / 'LICENSE').read_bytes()
    all_source['BUILD-NOTES.txt'] = ('''Effective sources are in unix/ and windows/. Original used upstream sources are in upstream/.
Integration and generator sources are in integration/ using their project-relative layout.
Requires Python 3.8+ to rebuild from this snapshot (no network/git is needed for this rebuild).
From the extracted source ZIP root, run:
python -c "import sys,runpy; from pathlib import Path; sys.path.insert(0,'integration/infrastructure/scripts'); d=runpy.run_path('integration/infrastructure/scripts/build-offline.py'); d['build'](Path('upstream'),Path('rebuilt-kit'))"
The normal build-offline.py CLI additionally verifies the clean Git checkout against the pinned revision.
Original revision: ''' + REVISION + '\n').encode()
    (output / 'Corresponding-Source.zip').write_bytes(zipped(all_source))
    names = ['Unix-Infrastructure.sh', 'Windows-Infrastructure.ps1', 'README.ko.txt', 'README.ko.html',
             'AGPL-3.0.txt', 'LICENSE.upstream.txt', 'Corresponding-Source.zip']
    checksums = ''.join(hashlib.sha256((output / n).read_bytes()).hexdigest() + '  ' + n + '\n' for n in names)
    (output / 'SHA256SUMS.txt').write_text(checksums, encoding='ascii')
    names.append('SHA256SUMS.txt')
    target = output / 'TriGuard-Infrastructure-Offline.zip'
    temporary = target.with_suffix('.zip.tmp')
    with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for name in names:
            archive.write(output / name, name)
    temporary.replace(target)
    print(target)
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path)
    parser.add_argument('--output', type=Path, default=APP / 'offline-kit')
    args = parser.parse_args()
    source = args.source.resolve() if args.source else prepare()
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip()
    if actual != REVISION or dirty:
        parser.error('Source must be the clean pinned revision: ' + REVISION)
    build(source, args.output.resolve())


if __name__ == '__main__':
    main()
