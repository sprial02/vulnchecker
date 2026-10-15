"""Validate and atomically import customer result ZIPs; never execute their contents."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import zipfile

MAX_TOTAL = 20 * 1024 ** 3
MAX_MEMBER = 8 * 1024 ** 3


def safe_name(name):
    path = PurePosixPath(name)
    if '\\' in name or ':' in name or path.is_absolute() or '..' in path.parts or not path.parts or str(path) != name:
        raise ValueError('잘못된 압축 내부 경로')
    return path


def allowed(name):
    path = safe_name(name)
    if name in ('summary.json', 'metadata.json', 'failures.csv', 'source-compatibility.json'):
        return True
    return (len(path.parts) == 2 and re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,260}', path.parts[0]) is not None
            and path.parts[1] in ('evidence.zip', 'evidence.tar.gz'))


def read_json(archive, name, limit):
    if archive.getinfo(name).file_size > limit:
        raise ValueError('메타데이터 용량 제한 초과: ' + name)
    with archive.open(name) as stream:
        return json.loads(stream.read(limit + 1).decode('utf-8-sig'))


def check_summary(summary, manifest):
    run_id = summary.get('run_id', '')
    if not re.fullmatch(r'\d{8}T\d{6}Z-[a-f0-9]{8}', run_id) or run_id != manifest['run_id']:
        raise ValueError('잘못된 실행 ID')
    if summary.get('collection_method') != 'customer-offline' or summary.get('preflight') is not False:
        raise ValueError('고객 자체 점검 결과 형식이 아닙니다.')
    hosts = summary.get('hosts')
    if not isinstance(hosts, list) or not hosts or len(hosts) > 20000 or len(hosts) != len(set(hosts)):
        raise ValueError('잘못된 점검 대상 목록')
    if not isinstance(summary.get('servers'), dict) or set(summary['servers']) != set(hosts):
        raise ValueError('점검 대상과 서버 결과가 일치하지 않습니다.')
    if not isinstance(summary.get('targets'), dict) or set(summary['targets']) != set(hosts):
        raise ValueError('점검 대상의 식별 정보가 없습니다.')
    for key in ('failed_hosts', 'vulnerable_hosts', 'manual_hosts'):
        if not isinstance(summary.get(key), list) or not set(summary[key]) <= set(hosts):
            raise ValueError('잘못된 결과 대상 목록: ' + key)
    paths = {f['path'] for f in manifest['files']}
    for host in hosts:
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,260}', host):
            raise ValueError('잘못된 대상 이름')
        outcome = summary['servers'][host]
        target = summary['targets'][host]
        if not isinstance(outcome, dict) or not isinstance(target, dict) or target.get('connection') != 'local':
            raise ValueError('잘못된 로컬 점검 결과')
        if not isinstance(outcome.get('execution_failed'), bool) or outcome['execution_failed'] != (host in summary['failed_hosts']):
            raise ValueError('실패 목록과 상세 결과가 일치하지 않습니다.')
        if not isinstance(outcome.get('counts'), dict) or any(type(v) is not int or v < 0 for v in outcome['counts'].values()):
            raise ValueError('잘못된 판정 합계')
        if not isinstance(outcome.get('errors'), list) or any(not isinstance(v, str) for v in outcome['errors']):
            raise ValueError('잘못된 실패 사유')
        if not outcome['execution_failed'] and not any(host + '/' + name in paths for name in ('evidence.zip', 'evidence.tar.gz')):
            raise ValueError('완료로 표시된 대상의 증적이 없습니다.')
    for path in paths:
        if '/' in path and path.split('/')[0] not in hosts:
            raise ValueError('목록 밖 서버의 증적이 포함되어 있습니다.')


def verify_existing(folder, manifest):
    existing = folder / 'manifest.json'
    if not existing.is_file() or json.loads(existing.read_text(encoding='utf-8-sig')) != manifest:
        raise ValueError('같은 실행 ID의 다른 자료가 이미 있습니다. 기존 자료를 덮어쓰지 않았습니다.')
    for entry in manifest['files']:
        file = folder / entry['path']
        value = hashlib.sha256()
        with file.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                value.update(chunk)
        if file.stat().st_size != entry['bytes'] or value.hexdigest() != entry['sha256']:
            raise ValueError('기존 보관본이 변경되어 중복 가져오기를 중단했습니다.')


def import_result(path, root):
    root = Path(root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.importing-', dir=root))
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            names = [i.filename for i in infos]
            if len(infos) > 40010 or len(names) != len({n.casefold() for n in names}):
                raise ValueError('중복 파일 또는 파일 개수 제한 초과')
            for info in infos:
                safe_name(info.filename)
                if info.is_dir() or (info.external_attr >> 16) & 0o170000 == 0o120000 or info.flag_bits & 1:
                    raise ValueError('디렉터리·링크·암호화된 ZIP 항목은 허용하지 않습니다.')
                if info.file_size > MAX_MEMBER:
                    raise ValueError('단일 파일 용량 제한 초과')
            manifest = read_json(archive, 'manifest.json', 4 * 1024 ** 2)
            if manifest.get('schema_version') != 1 or manifest.get('type') != 'triguard-offline-result' or not isinstance(manifest.get('files'), list):
                raise ValueError('지원하지 않는 결과 묶음 형식')
            entries = manifest['files']
            expected = {e['path'] for e in entries}
            if len(expected) != len(entries) or set(names) != expected | {'manifest.json'}:
                raise ValueError('파일 목록과 무결성 목록이 일치하지 않습니다.')
            if not {'summary.json', 'metadata.json', 'failures.csv', 'source-compatibility.json'} <= expected:
                raise ValueError('필수 결과 파일이 없습니다.')
            total = 0
            for entry in entries:
                if not allowed(entry['path']) or type(entry['bytes']) is not int or entry['bytes'] < 0 or not re.fullmatch(r'[a-f0-9]{64}', entry['sha256']):
                    raise ValueError('잘못된 파일 무결성 정보')
                if archive.getinfo(entry['path']).file_size != entry['bytes']:
                    raise ValueError('파일 크기 불일치')
                total += entry['bytes']
            if total > MAX_TOTAL or total + 100 * 1024 ** 2 > shutil.disk_usage(root).free:
                raise ValueError('총 용량 제한(20GiB) 또는 사용 가능한 저장 공간 초과')
            summary = read_json(archive, 'summary.json', 16 * 1024 ** 2)
            check_summary(summary, manifest)
            for entry in entries:
                destination = stage / entry['path']
                destination.parent.mkdir(parents=True, exist_ok=True)
                value = hashlib.sha256()
                size = 0
                with archive.open(entry['path']) as src, destination.open('xb') as dst:
                    for chunk in iter(lambda: src.read(1024 * 1024), b''):
                        size += len(chunk)
                        if size > entry['bytes']:
                            raise ValueError('파일의 실제 용량이 선언된 용량을 초과합니다.')
                        value.update(chunk)
                        dst.write(chunk)
                if size != entry['bytes'] or value.hexdigest() != entry['sha256']:
                    raise ValueError('파일 SHA256 불일치: ' + entry['path'])
            (stage / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
        destination = root / summary['run_id']
        if destination.exists():
            verify_existing(destination, manifest)
            return {'file': str(path), 'run_id': summary['run_id'], 'status': 'already_imported'}
        stage.rename(destination)
        return {'file': str(path), 'run_id': summary['run_id'], 'status': 'imported', 'failed_targets': len(summary['failed_hosts'])}
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--file', required=True, action='append', type=Path)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    results = []
    for path in args.file:
        try:
            result = import_result(path, args.root)
        except Exception as exc:
            result = {'file': str(path), 'status': 'failed', 'error': str(exc)}
        results.append(result)
        print(json.dumps(result, ensure_ascii=False))
    if args.out:
        args.out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    return 1 if any(r['status'] == 'failed' for r in results) else 0


if __name__ == '__main__':
    raise SystemExit(main())
