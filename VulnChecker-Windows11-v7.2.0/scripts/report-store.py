"""Local SQLite result index. Preserve source evidence; never infer findings from connectivity."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import tarfile
import zipfile
from datetime import datetime, timezone

STATUSES = {'GOOD': 'GOOD', 'PASS': 'GOOD', '양호': 'GOOD', 'VULNERABLE': 'VULNERABLE',
            'FAIL': 'VULNERABLE', '취약': 'VULNERABLE', 'MANUAL': 'MANUAL', '수동확인': 'MANUAL',
            'N/A': 'N/A', 'NA': 'N/A', 'NOT_APPLICABLE': 'N/A', '해당없음': 'N/A'}
SEVERITIES = {'CRITICAL': 'Critical', '긴급': 'Critical', 'HIGH': 'High', '상': 'High',
              '높음': 'High', 'MEDIUM': 'Medium', '중': 'Medium', '중간': 'Medium',
              'LOW': 'Low', '하': 'Low', '낮음': 'Low', 'INFO': 'Info', 'INFORMATIONAL': 'Info', '정보': 'Info'}
SECRET = re.compile(r'password|passwd|authorization|cookie|api.?key|access.?token|secret|private.?key', re.I)


def clean(value):
    if isinstance(value, (bool, int, float)): return value
    if isinstance(value, dict):
        return {str(k): '[민감정보 마스킹]' if SECRET.search(str(k)) else clean(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean(v) for v in value]
    text = str(value) if value is not None else ''
    text = re.sub(r'(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+', r'\1[마스킹]', text)
    text = re.sub(r'(?im)((?:password|passwd|api[_-]?key|access[_-]?token|secret)\s*[:=]\s*)[^\s,;]+', r'\1[마스킹]', text)
    text = re.sub(r'(?im)((?:Authorization|Cookie|Set-Cookie)\s*:\s*)[^\r\n]+', r'\1[마스킹]', text)
    text = re.sub(r'(?i)([?&](?:token|key|password|secret)=)[^&\s]+', r'\1[마스킹]', text)
    return ''.join(c for c in text if ord(c) >= 32 or c in '\n\t')


def text(value, maximum=20000):
    value = clean(value)
    out = json.dumps(value, ensure_ascii=False, indent=2) if isinstance(value, (dict, list)) else str(value)
    return out[:maximum] + ('\n[긴 증적은 원본 참조]' if len(out) > maximum else '')


def evidence_text(value):
    """Keep evidence readable rather than dumping raw JSON into the client report."""
    labels={'command':'확인 명령','stdout':'확인 결과','stderr':'진단 메시지','output':'확인 결과',
            'actual':'관찰 값','expected':'기준 값','path':'파일 위치','file':'파일','content':'내용','value':'값'}
    def lines(item, depth=0):
        if depth>6: return [text(item,2000)]
        if isinstance(item,dict):
            result=[]
            for key,child in item.items():
                result.append(labels.get(str(key),str(key))+'  '+('\n'.join(lines(child,depth+1))))
            return result
        if isinstance(item,list):return ['• '+ '\n'.join(lines(child,depth+1)) for child in item]
        return [str(item)]
    return text('\n'.join(lines(clean(value))))


def connect(path):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA foreign_keys=ON')
    db.executescript('''
    CREATE TABLE IF NOT EXISTS sources (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, origin TEXT NOT NULL,
      fingerprint TEXT NOT NULL, created TEXT NOT NULL, metadata TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS assets (
      source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      name TEXT NOT NULL, platform TEXT NOT NULL, failed INTEGER NOT NULL, errors TEXT NOT NULL,
      detailed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source_id,name));
    CREATE TABLE IF NOT EXISTS result_counts (
      source_id TEXT NOT NULL, asset TEXT NOT NULL, status TEXT NOT NULL, count INTEGER NOT NULL,
      PRIMARY KEY(source_id,asset,status),
      FOREIGN KEY(source_id,asset) REFERENCES assets(source_id,name) ON DELETE CASCADE);
    CREATE TABLE IF NOT EXISTS checks (
      source_id TEXT NOT NULL, asset TEXT NOT NULL, item_id TEXT NOT NULL, title TEXT NOT NULL,
      status TEXT NOT NULL, severity TEXT NOT NULL, category TEXT NOT NULL,
      description TEXT NOT NULL, impact TEXT NOT NULL, recommendation TEXT NOT NULL,
      evidence TEXT NOT NULL, reference TEXT NOT NULL, origin TEXT NOT NULL,
      PRIMARY KEY(source_id,asset,item_id),
      FOREIGN KEY(source_id,asset) REFERENCES assets(source_id,name) ON DELETE CASCADE);
    CREATE INDEX IF NOT EXISTS idx_checks_status ON checks(source_id,status,severity);
    CREATE INDEX IF NOT EXISTS idx_checks_item ON checks(source_id,item_id);
    CREATE INDEX IF NOT EXISTS idx_sources_kind ON sources(kind,created DESC);
    CREATE TABLE IF NOT EXISTS attachments (
      source_id TEXT NOT NULL, asset TEXT NOT NULL, item_id TEXT NOT NULL,
      path TEXT NOT NULL, caption TEXT NOT NULL, sha256 TEXT NOT NULL,
      PRIMARY KEY(source_id,asset,item_id,path),
      FOREIGN KEY(source_id,asset,item_id) REFERENCES checks(source_id,asset,item_id) ON DELETE CASCADE);
    ''')
    columns={r[1] for r in db.execute('PRAGMA table_info(assets)')}
    for name in ('server_name','instance_id','profile_id'):
        if name not in columns:db.execute(f"ALTER TABLE assets ADD COLUMN {name} TEXT NOT NULL DEFAULT ''")
    db.commit()
    return db


def normalize(record, asset, origin, fallback=''):
    item = str(record.get('item_id') or record.get('id') or fallback)
    if not item:
        raise ValueError('점검 항목 식별자가 없습니다.')
    status = STATUSES.get(str(record.get('final_result', record.get('diagnosis_result', record.get('status', 'MANUAL')))).upper(), 'MANUAL')
    severity = SEVERITIES.get(str(record.get('severity', record.get('importance', record.get('risk', '')))).upper(), 'Unknown')
    return (asset, item, text(record.get('title') or record.get('item_name') or record.get('name') or item, 1000),
            status, severity, text(record.get('category') or record.get('classification') or '미분류', 300),
            text(record.get('description') or record.get('diagnosis_reason') or record.get('reason') or ''),
            text(record.get('impact') or ''), text(record.get('recommendation') or record.get('remediation') or record.get('action_plan') or ''),
            evidence_text(record.get('evidence') or record.get('diagnosis_detail') or record.get('current_status') or record.get('details') or ''),
            text(record.get('reference') or record.get('references') or record.get('criteria') or ''), origin)


def archive_records(folder):
    """Read bounded JSON members without extraction or following archive paths."""
    total = 0
    tar = folder / 'evidence.tar.gz'; zip_path = folder / 'evidence.zip'
    if tar.exists():
        with tarfile.open(tar) as archive:
            for entry in archive:
                if not entry.isfile() or not entry.name.endswith('.json'): continue
                total += entry.size
                if entry.size > 16 * 1024 * 1024 or total > 512 * 1024 * 1024: raise ValueError('증적 JSON 용량 제한 초과')
                yield entry.name, archive.extractfile(entry).read()
    elif zip_path.exists():
        with zipfile.ZipFile(zip_path) as archive:
            for entry in archive.infolist():
                if not entry.filename.endswith('.json'): continue
                total += entry.file_size
                if entry.file_size > 16 * 1024 * 1024 or total > 512 * 1024 * 1024: raise ValueError('증적 JSON 용량 제한 초과')
                yield entry.filename, archive.read(entry)


def insert_check(db, source, row):
    db.execute('INSERT INTO checks VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)', (source,) + row)


def import_infra(db, folder):
    folder = Path(folder).resolve()
    raw = (folder / 'summary.json').read_bytes()
    summary = json.loads(raw.decode('utf-8-sig'))
    if summary.get('preflight'):
        return None  # Successful login is not a vulnerability assessment.
    run = str(summary.get('run_id') or folder.name)
    source = 'infra-' + hashlib.sha256(str(folder).encode()).hexdigest()[:24]
    signature = hashlib.sha256(raw)
    for host in summary.get('hosts', []):
        host = str(host)
        if Path(host).name != host or host in ('.', '..') or '/' in host or '\\' in host: raise ValueError('잘못된 증적 서버 이름')
        for archive in (folder / host / 'evidence.tar.gz', folder / host / 'evidence.zip'):
            if archive.exists(): signature.update(f'{host}/{archive.name}:{archive.stat().st_size}:{archive.stat().st_mtime_ns}'.encode())
    fingerprint = signature.hexdigest()
    old = db.execute('SELECT fingerprint FROM sources WHERE id=?', (source,)).fetchone()
    if old and old[0] == fingerprint: return source
    with db:
        db.execute('DELETE FROM sources WHERE id=?', (source,))
        db.execute('INSERT INTO sources VALUES (?,?,?,?,?,?,?)', (source, 'infra', run, str(folder), fingerprint,
                   run[:8] if re.match(r'\d{8}', run) else datetime.now(timezone.utc).isoformat(), json.dumps(clean(summary), ensure_ascii=False)))
        for host in summary.get('hosts', []):
            info = summary.get('servers', {}).get(host, {})
            failed = bool(info.get('execution_failed') or host in summary.get('failed_hosts', []))
            target=summary.get('targets',{}).get(host,{})
            db.execute('INSERT INTO assets (source_id,name,platform,failed,errors,detailed,server_name,instance_id,profile_id) VALUES (?,?,?,?,?,?,?,?,?)',
                       (source,host,target.get('profile') or '미분류',int(failed),text(info.get('errors',[])),0,target.get('server') or host,target.get('instance','os'),target.get('profile','')))
            imported = Counter(); errors = []; platform = target.get('profile') or '미분류'
            try:
                for member, data in archive_records(folder / host):
                    if Path(member).name == 'execution.json': continue
                    try:
                        record = json.loads(data.decode('utf-8-sig'))
                        if not isinstance(record, dict) or not record.get('item_id'): continue
                        row = normalize(record, host, f'{host}/{member}')
                        insert_check(db, source, row); imported[row[3]] += 1
                        if not target.get('profile'):
                            if str(record['item_id']).startswith('U-'): platform = 'Unix OS'
                            elif str(record['item_id']).startswith('W-'): platform = 'Windows'
                    except (ValueError, UnicodeError, sqlite3.IntegrityError) as exc:
                        errors.append(f'{member}: {exc}')
            except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile) as exc:
                errors.append(str(exc))
            counts = Counter()
            for status, count in info.get('counts', {}).items():
                normalized = STATUSES.get(str(status).upper())
                if normalized: counts[normalized] += max(0, int(count))
            declared = bool(counts)
            if not declared: counts = imported
            detailed = bool(imported) and imported == counts and not errors
            if not detailed:
                errors.append('요약 합계와 검증 가능한 상세 증적이 일치하지 않거나 상세 증적이 없습니다.')
            existing_errors = info.get('errors', [])
            db.execute('UPDATE assets SET platform=?,errors=?,detailed=? WHERE source_id=? AND name=?',
                       (platform, text(list(existing_errors) + errors), int(detailed), source, host))
            for status, count in counts.items():
                db.execute('INSERT INTO result_counts VALUES (?,?,?,?)', (source, host, status, count))
    return source


def mobsf_records(data):
    package = str(data.get('package_name') or data.get('app_name') or '모바일 앱')
    rows = []
    for block in ('code_analysis', 'manifest_analysis', 'certificate_analysis', 'network_security', 'binary_analysis'):
        section = data.get(block, {})
        values = section.get('findings', section.get('manifest_findings', [])) if isinstance(section, dict) else section
        if isinstance(values, dict): values = [dict(value, id=key) for key, value in values.items() if isinstance(value, dict)]
        if not isinstance(values, list): continue
        for index, value in enumerate(values):
            if not isinstance(value, dict): continue
            metadata = value.get('metadata', {}) if isinstance(value.get('metadata'), dict) else {}
            severity = value.get('severity') or metadata.get('severity') or 'Info'
            row = {**value, 'id': value.get('id') or value.get('rule') or f'{block}-{index+1}',
                   'title': value.get('title') or metadata.get('description') or value.get('description') or f'{block} 항목 {index+1}',
                   'severity': severity, 'status': 'VULNERABLE' if str(severity).lower() in ('critical','high','medium','warning','low') else 'MANUAL',
                   'category': block, 'asset': package, 'evidence': value.get('files') or value.get('evidence') or '',
                   'recommendation': value.get('recommendation') or '', 'description': value.get('description') or metadata.get('description') or ''}
            if str(severity).lower() == 'warning': row['severity'] = 'Medium'
            rows.append(row)
    return rows, package


def import_json(db, path, kind):
    path = Path(path).resolve()
    if path.stat().st_size > 64 * 1024 * 1024: raise ValueError('결과 JSON은 64MB 이하로 분할하세요.')
    raw = path.read_bytes(); data = json.loads(raw.decode('utf-8-sig'))
    fingerprint = hashlib.sha256(raw).hexdigest()
    source = kind + '-' + hashlib.sha256((str(path) + kind).encode()).hexdigest()[:24]
    metadata = {}; name = path.stem
    if isinstance(data, dict) and ('code_analysis' in data or 'manifest_analysis' in data):
        if kind != 'mobile': raise ValueError('MobSF 결과는 모바일 앱 보고서로 가져오세요.')
        records, name = mobsf_records(data)
        metadata = {'source_type': 'MobSF static analysis', 'package': data.get('package_name'), 'hash': data.get('md5')}
    elif isinstance(data, dict):
        records = data.get('findings', data.get('checks'))
        metadata = data.get('metadata', {}); name = str(data.get('name') or path.stem)
        if not isinstance(metadata,dict): raise ValueError('metadata는 객체여야 합니다.')
        if data.get('kind') and data['kind'] != kind: raise ValueError('선택한 보고서 종류와 결과 JSON 종류가 다릅니다.')
    elif isinstance(data, list): records = data
    else: raise ValueError('findings 배열을 포함한 JSON이 필요합니다.')
    if not isinstance(records, list): raise ValueError('findings 배열이 없습니다. 접속 상태는 점검 결과로 가져올 수 없습니다.')
    with db:
        db.execute('DELETE FROM sources WHERE id=?', (source,))
        db.execute('INSERT INTO sources VALUES (?,?,?,?,?,?,?)', (source, kind, text(name, 300), str(path), fingerprint,
                   datetime.now(timezone.utc).isoformat(), json.dumps(clean(metadata), ensure_ascii=False)))
        counts = {}; platforms = {}
        for index, record in enumerate(records):
            if not isinstance(record, dict): raise ValueError('점검 항목은 객체여야 합니다.')
            asset = text(record.get('asset') or record.get('host') or record.get('target') or name, 300)
            if asset not in counts:
                counts[asset] = Counter(); platforms[asset] = text(record.get('platform') or '미분류', 100)
                db.execute('INSERT INTO assets (source_id,name,platform,failed,errors,detailed,server_name) VALUES (?,?,?,?,?,?,?)', (source, asset, platforms[asset], 0, '', 1,asset))
            row = normalize(record, asset, f'{path.name}#/findings/{index}', f'F-{index+1:05}')
            insert_check(db, source, row); counts[asset][row[3]] += 1
            for image in record.get('images', [])[:10]:
                if not isinstance(image, dict) or not image.get('path'): raise ValueError('증적 이미지는 path 필드를 포함해야 합니다.')
                image_path=(path.parent / image['path']).resolve()
                if not image_path.is_relative_to(path.parent) or image_path.suffix.lower() not in ('.png','.jpg','.jpeg'):
                    raise ValueError('증적 이미지는 결과 JSON 폴더 내부의 PNG/JPEG 파일이어야 합니다.')
                if not image_path.is_file() or image_path.stat().st_size>10*1024*1024: raise ValueError('증적 이미지가 없거나 10MB를 초과합니다.')
                digest=hashlib.sha256(image_path.read_bytes()).hexdigest()
                db.execute('INSERT INTO attachments VALUES (?,?,?,?,?,?)',(source,asset,row[1],str(image_path),text(image.get('caption') or '증적 화면',1000),digest))
        for asset, values in counts.items():
            for status, count in values.items(): db.execute('INSERT INTO result_counts VALUES (?,?,?,?)', (source, asset, status, count))
    return source


def stats(db, source):
    counts = {row[0]: row[1] for row in db.execute('SELECT status,SUM(count) FROM result_counts WHERE source_id=? GROUP BY status', (source,))}
    assets = db.execute('SELECT COUNT(*),COALESCE(SUM(failed),0),COALESCE(SUM(detailed),0) FROM assets WHERE source_id=?', (source,)).fetchone()
    severity = {row[0]: row[1] for row in db.execute("SELECT severity,COUNT(*) FROM checks WHERE source_id=? AND status='VULNERABLE' GROUP BY severity", (source,))}
    affected = db.execute("SELECT COUNT(DISTINCT asset) FROM result_counts WHERE source_id=? AND status='VULNERABLE' AND count>0", (source,)).fetchone()[0]
    distinct = db.execute("SELECT COUNT(DISTINCT a.platform || '|' || c.item_id) FROM checks c JOIN assets a ON a.source_id=c.source_id AND a.name=c.asset WHERE c.source_id=? AND c.status='VULNERABLE'", (source,)).fetchone()[0]
    physical=db.execute("SELECT COUNT(DISTINCT COALESCE(NULLIF(server_name,''),name)) FROM assets WHERE source_id=?",(source,)).fetchone()[0]
    physical_affected=db.execute("SELECT COUNT(DISTINCT COALESCE(NULLIF(a.server_name,''),a.name)) FROM assets a JOIN result_counts r ON a.source_id=r.source_id AND a.name=r.asset WHERE a.source_id=? AND r.status='VULNERABLE' AND r.count>0",(source,)).fetchone()[0]
    assessed = counts.get('GOOD', 0) + counts.get('VULNERABLE', 0)
    return {'counts': counts, 'assets': assets[0], 'physical_assets':physical,'physical_affected_assets':physical_affected,'failed_assets': assets[1], 'detailed_assets': assets[2],
            'affected_assets': affected, 'distinct_vulnerabilities': distinct, 'severity': severity,
            'total_checks': sum(counts.values()), 'good_rate': round(100 * counts.get('GOOD', 0) / assessed, 1) if assessed else None}


def catalog(db):
    values = []
    for row in db.execute('SELECT id,kind,name,created FROM sources ORDER BY created DESC,name'):
        values.append(dict(row, **stats(db, row['id'])))
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--db', required=True); parser.add_argument('--out')
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('catalog')
    sync = sub.add_parser('sync-infra'); sync.add_argument('--root', required=True)
    ingest = sub.add_parser('import-json'); ingest.add_argument('--file', required=True); ingest.add_argument('--kind', choices=['mobile','web','infra'], required=True)
    preview = sub.add_parser('preview'); preview.add_argument('--source', required=True); preview.add_argument('--offset', type=int, default=0)
    args = parser.parse_args(); db = connect(args.db)
    if args.action == 'sync-infra':
        root = Path(args.root)
        for summary in sorted(root.glob('*/summary.json')): import_infra(db, summary.parent)
        result = catalog(db)
    elif args.action == 'import-json': import_json(db, args.file, args.kind); result = catalog(db)
    elif args.action == 'preview':
        result = {'source_id': args.source, 'offset': max(0,args.offset), 'stats': stats(db, args.source), 'rows': [dict(row) for row in db.execute(
            'SELECT asset,item_id,title,status,severity FROM checks WHERE source_id=? ORDER BY asset,item_id LIMIT 100 OFFSET ?', (args.source, max(0, args.offset)))]}
    else: result = catalog(db)
    payload = json.dumps(result, ensure_ascii=False, indent=2)
    if args.out:
        out = Path(args.out); temporary = out.with_suffix('.tmp'); temporary.write_text(payload, encoding='utf-8'); temporary.replace(out)
    else: print(payload)
    db.close()


if __name__ == '__main__': main()
