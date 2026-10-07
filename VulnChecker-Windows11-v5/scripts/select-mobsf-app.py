"""Select the installed target for MobSF static analysis; keep all device splits."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid
import requests

package = sys.argv[1]
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+', package):
    raise ValueError('Invalid selected package')
paths = subprocess.run(['/usr/bin/adb', '-s', 'host.docker.internal:5555',
    'shell', 'pm', 'path', package], check=True, capture_output=True, text=True, timeout=20).stdout
paths = [line[8:].strip() for line in paths.splitlines() if line.startswith('package:')]
base = next((path for path in paths if path.endswith('/base.apk')), None)
if not base:
    raise ValueError('Selected installed base APK is missing')
folder = Path('/tmp/vulnchecker/selected') / package / uuid.uuid4().hex
folder.mkdir(parents=True, exist_ok=True)
apk = folder / 'base.apk'
subprocess.run(['/usr/bin/adb', '-s', 'host.docker.internal:5555', 'pull', base, str(apk)],
               check=True, capture_output=True, timeout=60)
key = os.environ.get('MOBSF_API_KEY')
if os.environ.get('MOBSF_API_KEY_FILE'):
    key = Path(os.environ['MOBSF_API_KEY_FILE']).read_text().strip()
if not key:
    key = hashlib.sha256(Path('/home/mobsf/.MobSF/secret').read_bytes().strip()).hexdigest()
headers = {'Authorization': key}
with apk.open('rb') as file:
    upload = requests.post('http://127.0.0.1:8000/api/v1/upload', headers=headers,
        files={'file': (package + '.apk', file, 'application/vnd.android.package-archive')}, timeout=60)
upload.raise_for_status()
data = upload.json()
response = requests.post('http://127.0.0.1:8000/api/v1/scan', headers=headers,
    data={name: data[name] for name in ('hash', 'file_name', 'scan_type')}, timeout=300)
response.raise_for_status()
report = response.json()
if report.get('package_name') != package:
    raise ValueError('MobSF static report package differs from selected target')
print(json.dumps({'package': package, 'hash': data['hash'], 'splits': len(paths),
                  'report_path': '/static_analyzer/' + data['hash'] + '/'}))
