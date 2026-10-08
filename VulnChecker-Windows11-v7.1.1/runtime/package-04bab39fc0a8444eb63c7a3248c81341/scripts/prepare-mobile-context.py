"""Prepare original APKs and a scoped Android bridge for the selected app."""
import base64
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

spec = json.loads(base64.b64decode(sys.argv[1]))
package = spec['package']
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+', package):
    raise ValueError('Invalid selected package')
if spec['serial'] != 'emulator-5554':
    raise ValueError('Only the managed analysis device is supported')
work = Path(spec['work'])
if work.name != package or work.parent.name != 'mobile':
    raise ValueError('Target folder must be scoped to the selected mobile package')
source = Path(spec['source'])
manifest = json.loads((source / 'manifest.json').read_text(encoding='utf-8-sig'))
if manifest['Package'] != package:
    raise ValueError('APK package differs from selected target')
work.mkdir(parents=True, exist_ok=True)
apks = work / 'apks'
apks.mkdir(exist_ok=True)
if apks.resolve().parent != work.resolve():
    raise ValueError('APK folder must stay inside the target workspace')
entries = []
for item in manifest['Items']:
    name = item['Path'].replace('\\', '/').rsplit('/', 1)[-1]
    file = source / name
    digest = hashlib.sha256(file.read_bytes()).hexdigest()
    if digest.lower() != item['SHA256'].lower():
        raise ValueError('APK hash mismatch')
    destination = apks / name
    shutil.copy2(file, destination)
    item = dict(item, Path=str(destination))
    entries.append(item)
manifest['Items'] = entries
# Include only the current selected set when a package is upgraded.
for previous in apks.glob('*.apk'):
    if previous.name not in {Path(item['Path']).name for item in entries}:
        previous.unlink()
(apks / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
adb = Path(spec['adb'])
if not adb.is_file():
    raise ValueError('Windows ADB is not reachable from Kali')
bridge = work / 'adb-target'
bridge.write_text('#!/bin/sh\nexec ' + shlex.quote(str(adb)) + ' -s emulator-5554 "$@"\n', encoding='utf-8')
bridge.chmod(0o700)
check = subprocess.run([str(bridge), 'shell', 'pm', 'path', package],
                       check=True, capture_output=True, text=True, timeout=20)
if 'package:' not in check.stdout:
    raise ValueError('Selected app is not installed on the analysis device')
spec['apk_folder'] = str(apks)
(work / 'target.json').write_text(json.dumps(spec, ensure_ascii=False, indent=2), encoding='utf-8')
note = f'''# 선택한 모바일 펜테스트 대상

패키지: {package}
버전: {spec['version']}
분석 기기: emulator-5554 (루팅 분석 에뮬레이터)
현재 통신 분석 모드: {spec['route']}

원본 base/split APK 전체와 서명·SHA256 기록: ./apks/manifest.json
앱 연결 확인: ./adb-target shell pm path {package}
기기 연결 확인: ./adb-target shell id

HexStrike MCP의 명령 실행 기능에서 위 adb-target을 사용하면 Windows의
선택된 분석 기기에 접근한다. APK 정적 점검은 jadx/apktool 등을 사용한다.
루팅 우회 주입과 앱 실행은 VulnChecker 모바일 메뉴에서 수행한다.
ADB/HexStrike를 준비하는 것만으로 Frida 주입을 대신하지 않는다.

API 점검은 Burp의 대상 앱 요청/응답을 내보내거나 MobSF 결과를 이 폴더에
저장한 뒤 실제 endpoint, 인증 조건, 점검 범위를 지정한다.
API 주소·로그인 토큰·실제 결제 작업은 APK에서 추정하여 자동 실행하지 않는다.
이 파일을 읽고 사용자가 정한 범위로 APK/앱/API 점검을 진행한다.
'''
(work / 'MOBILE_TARGET.md').write_text(note, encoding='utf-8')
print(json.dumps({'connected': True, 'package': package, 'apks': len(entries), 'work': str(work)}))
