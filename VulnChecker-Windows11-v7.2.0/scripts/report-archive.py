"""Portable, versioned assessment datasets. Standard library only; no rescanning."""
import argparse
import csv
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
from datetime import datetime, timezone
import zipfile

spec = importlib.util.spec_from_file_location('archive_store', Path(__file__).with_name('report-store.py'))
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)
TABLES = ('sources', 'assets', 'result_counts', 'checks', 'attachments')


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def safe_csv(value):
    value = str(value) if value is not None else ''
    return "'" + value if value.lstrip().startswith(('=', '+', '-', '@')) else value


def snapshot(db, source, destination):
    """Copy only selected rows into a NEW database, never deleted customer pages."""
    selected = store.connect(destination)
    try:
        with selected:
            for table in TABLES:
                key = 'id' if table == 'sources' else 'source_id'
                cursor = db.execute(f'SELECT * FROM {table} WHERE {key}=?', (source,))
                columns = [c[0] for c in cursor.description]
                names = ','.join(columns)
                selected.executemany(f'INSERT INTO {table} ({names}) VALUES ({",".join("?" for _ in columns)})', cursor)
        return selected
    except Exception:
        selected.close()
        raise


def build(db, source, library):
    info = db.execute('SELECT * FROM sources WHERE id=?', (source,)).fetchone()
    if info is None:
        raise ValueError('선택한 결과가 없습니다.')
    # IDs are also used as directory names. Refuse path traversal from imported databases.
    if any(not c.isalnum() and c not in '-_' for c in source) or not source:
        raise ValueError('잘못된 결과 식별자')
    signature = hashlib.sha256(info['fingerprint'].encode())
    for attachment in db.execute('SELECT asset,item_id,path,sha256 FROM attachments WHERE source_id=? ORDER BY asset,item_id,path', (source,)):
        signature.update(json.dumps(list(attachment), ensure_ascii=False).encode())
    version = signature.hexdigest()[:24]
    parent = Path(library).resolve() / source
    target = parent / version
    if (target / 'manifest.json').is_file():
        return target
    parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.building-', dir=parent))
    missing = []
    try:
        selected = snapshot(db, source, stage / 'results.sqlite3')
        try:
            origin = Path(info['origin']).resolve()
            root = origin if origin.is_dir() else origin.parent

            def copy_file(path, relative, expected=None):
                path = Path(path)
                # Junctions/symlinks must not pull unrelated files into the delivery.
                if not path.resolve().is_relative_to(root):
                    raise ValueError('증적이 원본 폴더 밖을 참조합니다.')
                if not path.is_file():
                    missing.append(relative.as_posix())
                    return
                dest = stage / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dest)
                if expected and digest(dest) != expected:
                    raise ValueError('색인 이후 증적 이미지가 변경되었습니다. 결과를 다시 동기화하세요.')

            if origin.is_dir():
                summary_path = origin / 'summary.json'
                if not summary_path.is_file():
                    missing.append('raw/summary.json')
                else:
                    raw_summary = summary_path.read_bytes()
                    summary = json.loads(raw_summary.decode('utf-8-sig'))
                    signature = hashlib.sha256(raw_summary)
                    for host in summary.get('hosts', []):
                        if not isinstance(host, str) or Path(host).name != host or host in ('.', '..') or '/' in host or '\\' in host:
                            raise ValueError('잘못된 증적 서버 이름')
                        for name in ('evidence.tar.gz', 'evidence.zip'):
                            path = origin / host / name
                            if path.exists():
                                signature.update(f'{host}/{name}:{path.stat().st_size}:{path.stat().st_mtime_ns}'.encode())
                    if signature.hexdigest() != info['fingerprint']:
                        raise ValueError('색인 이후 원본이 변경되었습니다. 결과를 다시 동기화하세요.')
                    copy_file(summary_path, Path('raw/summary.json'))
                    for name in ('source-compatibility.json', 'failures.csv'):
                        if (origin / name).is_file():
                            copy_file(origin / name, Path('raw') / name)
                    for host in summary.get('hosts', []):
                        if not isinstance(host, str) or Path(host).name != host or host in ('.', '..') or '/' in host or '\\' in host:
                            raise ValueError('잘못된 증적 서버 이름')
                        found = False
                        for name in ('evidence.tar.gz', 'evidence.zip', 'execution.json'):
                            path = origin / host / name
                            if path.is_file():
                                copy_file(path, Path('raw') / host / name)
                                found |= name.startswith('evidence.')
                        if not found:
                            missing.append(f'raw/{host}/evidence')
                relative_origin = 'raw/summary.json'
            else:
                if origin.is_file() and digest(origin) != info['fingerprint']:
                    raise ValueError('색인 이후 원본 JSON이 변경되었습니다. 결과를 다시 가져오세요.')
                copy_file(origin, Path('raw') / origin.name)
                relative_origin = 'raw/' + origin.name
            for row in list(selected.execute('SELECT * FROM attachments')):
                path = Path(row['path']).resolve()
                relative = Path('raw') / path.relative_to(root)
                copy_file(path, relative, row['sha256'])
                selected.execute('UPDATE attachments SET path=? WHERE source_id=? AND asset=? AND item_id=? AND path=?',
                                 (relative.as_posix(), source, row['asset'], row['item_id'], row['path']))
            selected.execute('UPDATE sources SET origin=? WHERE id=?', (relative_origin, source))
            selected.commit()
            query = '''SELECT s.name AS run_name,s.kind,s.created,a.server_name,a.instance_id,a.profile_id,
                       c.* FROM checks c JOIN assets a ON a.source_id=c.source_id AND a.name=c.asset
                       JOIN sources s ON s.id=c.source_id ORDER BY c.asset,c.item_id'''
            cursor = selected.execute(query)
            columns = [c[0] for c in cursor.description]
            with (stage / 'checks.csv').open('w', encoding='utf-8-sig', newline='') as csvfile, (stage / 'checks.jsonl').open('w', encoding='utf-8') as jsonfile:
                writer = csv.writer(csvfile)
                writer.writerow(columns)
                for row in cursor:
                    record = dict(row)
                    writer.writerow([safe_csv(record[c]) for c in columns])
                    jsonfile.write(json.dumps(record, ensure_ascii=False) + '\n')
            with (stage / 'assets.csv').open('w', encoding='utf-8-sig', newline='') as stream:
                cursor = selected.execute('SELECT * FROM assets ORDER BY name')
                writer = csv.writer(stream)
                writer.writerow([c[0] for c in cursor.description])
                for row in cursor:
                    writer.writerow([safe_csv(v) for v in row])
            statistics = store.stats(selected, source)
            write_json(stage / 'assessment.json', {'schema_version': 1, 'source_id': source, 'kind': info['kind'],
                       'name': info['name'], 'created': info['created'], 'metadata': json.loads(info['metadata']), 'stats': statistics})
            rows = []
            for row in selected.execute('''SELECT a.name,a.server_name,a.instance_id,a.profile_id,a.failed,a.detailed,
                    COALESCE(SUM(CASE WHEN r.status='VULNERABLE' THEN r.count ELSE 0 END),0) AS vulnerable
                    FROM assets a LEFT JOIN result_counts r ON a.source_id=r.source_id AND a.name=r.asset GROUP BY a.name ORDER BY a.name'''):
                rows.append('<tr>' + ''.join('<td>' + html.escape(str(row[c])) + '</td>' for c in row.keys()) + '</tr>')
            page = '<!doctype html><meta charset="utf-8"><title>점검 RAW 데이터</title><style>body{font:15px sans-serif;margin:32px}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:8px}th{background:#eee}</style>'
            page += '<h1>' + html.escape(info['name']) + '</h1><p>서버 ' + str(statistics['physical_assets']) + '대 / 점검 대상 ' + str(statistics['assets']) + '개 / 결과 ' + str(statistics['total_checks']) + '건</p>'
            page += '<p>원본 누락 ' + str(len(missing)) + '개 · 상세 검증 완료 대상 ' + str(statistics['detailed_assets']) + '개. failed=1은 수행 실패, detailed=0은 상세 불완전입니다.</p>'
            page += '<p><a href="checks.csv">전체 결과 CSV</a> · <a href="assets.csv">자산 목록</a> · <a href="assessment.json">집계 및 수행 제약</a> · <a href="raw/">원본 증적</a></p>'
            page += '<table><tr><th>점검 대상</th><th>물리 서버</th><th>인스턴스</th><th>프로필</th><th>failed</th><th>detailed</th><th>취약 건수</th></tr>' + ''.join(rows) + '</table>'
            (stage / 'index.html').write_text(page, encoding='utf-8')
            (stage / 'README.txt').write_text('이 폴더 전체를 복사하여 보관하거나 전달하세요. index.html을 열면 현황을 볼 수 있습니다.\n'
                'checks.csv: Excel 조회용(수식 시작 문자는 보호 처리). checks.jsonl: 가공용 정규화 결과. assets.csv: 자산 및 미완전 상태.\n'
                'results.sqlite3: 선택 회차만 포함한 DB. origin/attachments 경로는 이 폴더 기준 상대 경로.\n'
                'raw/: 수집된 원본 바이트 보존. 정규화 결과는 표시 길이 제한과 민감정보 마스킹이 적용될 수 있으므로 재분석에는 원본을 사용하세요.\n'
                '원본에는 계정/설정/개인정보가 포함될 수 있습니다. 고객 전달 전 해당 회차와 민감정보를 검토하세요.\n'
                '접속 설정, Vault, API 키 파일, vars.json, 런타임 전체는 수집하지 않습니다. 원본 증적 자체의 무해성을 보장하지 않습니다.\n'
                'manifest.json: 파일별 크기와 SHA256, 누락 목록. 해시는 변경 확인용이며 전자서명이나 수집 이전의 진위 보증이 아닙니다.\n', encoding='utf-8')
        finally:
            selected.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            selected.close()
        files = [{'path': p.relative_to(stage).as_posix(), 'bytes': p.stat().st_size, 'sha256': digest(p)}
                 for p in sorted(stage.rglob('*')) if p.is_file()]
        write_json(stage / 'manifest.json', {'schema_version': 1, 'source_id': source, 'fingerprint': info['fingerprint'],
                   'packaged_at': datetime.now(timezone.utc).isoformat(), 'missing': missing,
                   'bytes': sum(f['bytes'] for f in files), 'files': files})
        stage.rename(target)
        return target
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def verify(folder):
    folder = Path(folder).resolve()
    manifest = json.loads((folder / 'manifest.json').read_text(encoding='utf-8'))
    for entry in manifest['files']:
        path = (folder / entry['path']).resolve()
        if not path.is_relative_to(folder) or not path.is_file() or path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
            raise ValueError('증적 파일 무결성 확인 실패: ' + entry['path'])
    return manifest


def sync(db, library):
    folders = [build(db, row[0], library) for row in db.execute('SELECT id FROM sources ORDER BY id')]
    library_index(library)
    return folders


def library_index(library):
    library = Path(library)
    library.mkdir(parents=True, exist_ok=True)
    rows = []
    for manifest_path in sorted(library.glob('*/*/manifest.json')):
        folder = manifest_path.parent
        assessment = json.loads((folder / 'assessment.json').read_text(encoding='utf-8'))
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        stats = assessment['stats']
        link = folder.relative_to(library).as_posix() + '/index.html'
        cells = [assessment['name'], assessment['kind'], assessment['created'], stats['physical_assets'],
                 stats['total_checks'], len(manifest['missing']), round(manifest['bytes'] / 1000000, 2)]
        rows.append('<tr><td><a href="' + html.escape(link, quote=True) + '">열기</a></td>' +
                    ''.join('<td>' + html.escape(str(v)) + '</td>' for v in cells) + '</tr>')
    page = '<!doctype html><meta charset="utf-8"><title>RAW 통합 보관함</title><style>body{font:15px sans-serif;margin:32px}td,th{padding:8px;border:1px solid #ccc}table{border-collapse:collapse}</style><h1>RAW 통합 보관함</h1><p>회차와 보관 버전별 현황입니다. 고객에게는 선택 회차 ZIP 또는 개별 버전 폴더를 전달하세요.</p><table><tr><th>자료</th><th>회차명</th><th>종류</th><th>시점</th><th>서버 수</th><th>결과 수</th><th>누락 원본</th><th>MB</th></tr>' + ''.join(rows) + '</table>'
    temporary = library / 'index.html.tmp'
    temporary.write_text(page, encoding='utf-8')
    temporary.replace(library / 'index.html')


def export(db, source, library, output):
    folder = build(db, source, library)
    manifest = verify(folder)
    library_index(library)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    target = output / (source + '-' + folder.name + '.zip')
    temporary = output / (target.name + '.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            # Copy only manifest entries; an unrelated file added later is not delivered.
            for entry in manifest['files']:
                archive.write(folder / entry['path'], entry['path'])
            archive.write(folder / 'manifest.json', 'manifest.json')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--db', required=True)
    parser.add_argument('--library', required=True)
    parser.add_argument('--source')
    parser.add_argument('--output')
    args = parser.parse_args()
    db = store.connect(args.db)
    try:
        db.execute('BEGIN')
        if args.source:
            if not args.output:
                parser.error('--source requires --output')
            print(export(db, args.source, args.library, args.output))
        else:
            print(json.dumps([str(p) for p in sync(db, args.library)], ensure_ascii=False))
    finally:
        db.close()


if __name__ == '__main__':
    main()
