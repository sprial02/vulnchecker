"""Collect completed script results into one readable TXT per assessment run."""
import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile
import zipfile

VALID = {'GOOD': '양호', 'VULNERABLE': '취약', 'MANUAL': '수동 확인',
         'N/A': '해당 없음', 'NA': '해당 없음', 'NOT_APPLICABLE': '해당 없음'}
MAX_MEMBER = 16 * 1024 * 1024
MAX_TARGET = 512 * 1024 * 1024
RUN_ID = re.compile(r'\d{8}T\d{6}Z-[a-f0-9]{8}')
HOST = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,260}')


def decode(data):
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return data.decode('utf-16')
    try:
        return data.decode('utf-8-sig')
    except UnicodeError:
        return data.decode('cp949')


def records(folder):
    """Read result files in memory; never extract archive paths or executable files."""
    result = {}
    total = 0

    def add(name, size, read):
        nonlocal total
        path = PurePosixPath(name.replace('\\', '/'))
        if path.name != 'execution.json' and not (
                'results' in path.parts and path.suffix.lower() in ('.json', '.txt')):
            return
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('잘못된 결과 파일 경로')
        total += size
        if size > MAX_MEMBER or total > MAX_TARGET:
            raise ValueError('결과 파일 읽기 용량 제한 초과')
        key = str(path).casefold()
        if key in result:
            raise ValueError('중복 결과 파일')
        result[key] = read()

    if (folder / 'evidence.tar.gz').is_file():
        with tarfile.open(folder / 'evidence.tar.gz') as archive:
            for member in archive:
                if member.isfile():
                    add(member.name, member.size, lambda m=member: archive.extractfile(m).read())
    elif (folder / 'evidence.zip').is_file():
        with zipfile.ZipFile(folder / 'evidence.zip') as archive:
            for member in archive.infolist():
                if not member.is_dir():
                    add(member.filename, member.file_size, lambda m=member: archive.read(m))
    return result


def readable(value):
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, indent=2)
    return '' if value is None else str(value)


def target_results(folder):
    files = records(folder)
    manifests = [v for k, v in files.items() if PurePosixPath(k).name == 'execution.json']
    if len(manifests) != 1:
        return []
    executed = json.loads(decode(manifests[0]))
    successful = {r.get('item_id') for r in executed if isinstance(r, dict) and type(r.get('rc')) is int and r['rc'] == 0}
    rows = {}
    for name, data in files.items():
        if not name.endswith('.json') or PurePosixPath(name).name == 'execution.json':
            continue
        try:
            record = json.loads(decode(data))
        except (UnicodeError, ValueError):
            continue
        if not isinstance(record, dict):
            continue
        item = record.get('item_id')
        status = record.get('final_result', record.get('diagnosis_result'))
        if not isinstance(item, str) or not isinstance(status, str) or item not in successful or status not in VALID or not re.fullmatch(r'(?:U|W|WEB|D|P)-\d{2}', item):
            continue
        if item in rows:
            raise ValueError('중복 점검 항목: ' + item)
        txt = files.get(str(PurePosixPath(name).with_suffix('.txt')))
        if txt:
            body = decode(txt).strip()
        else:
            lines = [str(record.get('item_name') or item), '판정: ' + VALID[status]]
            for field, label in [('inspection', '점검 내용'), ('command', '점검 명령'),
                                 ('command_result', '점검 결과'), ('guideline', '점검 기준')]:
                value = readable(record.get(field))
                if value:
                    lines.extend([label + ':', value])
            body = '\n'.join(lines)
        rows[item] = body
    return sorted(rows.items())


def export_run(folder, output):
    folder, output = Path(folder), Path(output)
    summary = json.loads((folder / 'summary.json').read_text(encoding='utf-8-sig'))
    run_id = summary.get('run_id', folder.name)
    if not RUN_ID.fullmatch(str(run_id)):
        raise ValueError('잘못된 점검 회차 ID')
    if summary.get('preflight'):
        return {'run_id': run_id, 'status': 'preflight', 'items': 0}
    moment = datetime.strptime(run_id[:16], '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
    local = moment.astimezone(timezone(timedelta(hours=9)))
    destination = output / ('인프라점검결과_' + local.strftime('%Y%m%d_%H%M%S') + '_' + run_id[-8:] + '.txt')
    output.mkdir(parents=True, exist_ok=True)
    count, targets, skipped = 0, 0, []
    # Atomic replacement keeps one file per run when collected results are refreshed.
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8-sig', newline='',
                                     dir=output, suffix='.tmp', delete=False) as stream:
        temporary = Path(stream.name)
        rendered = False
        try:
            stream.write('인프라 점검 결과\r\n점검 시각: ' + local.strftime('%Y-%m-%d %H:%M:%S') + ' (한국시간)\r\n')
            stream.write('점검 회차: ' + run_id + '\r\n\r\n')
            for host in sorted(set(summary.get('hosts', []))):
                if not isinstance(host, str) or not HOST.fullmatch(host):
                    raise ValueError('잘못된 서버 식별자')
                try:
                    rows = target_results(folder / host)
                except (ValueError, OSError, UnicodeError, tarfile.TarError, zipfile.BadZipFile, EOFError):
                    skipped.append(host)
                    continue
                if not rows:
                    skipped.append(host)
                    continue
                target = summary.get('targets', {}).get(host, {})
                stream.write('=' * 72 + '\r\n')
                stream.write('서버: ' + str(target.get('server') or host) + ' / ' + str(target.get('host') or host) + '\r\n')
                stream.write('점검 대상: ' + str(target.get('profile') or host) + ' / ' + str(target.get('instance') or 'os') + '\r\n')
                stream.write('=' * 72 + '\r\n\r\n')
                for item, body in rows:
                    stream.write('[' + item + ']\r\n' + body.replace('\r\n', '\n').replace('\r', '\n').replace('\n', '\r\n') + '\r\n\r\n')
                count += len(rows)
                targets += 1
            stream.write('수록 점검 대상: ' + str(targets) + '개 / 수록 항목: ' + str(count) + '개\r\n')
            rendered = True
        finally:
            stream.close()
            if not rendered or not count:
                temporary.unlink(missing_ok=True)
    if not count:
        return {'run_id': run_id, 'status': 'no_results', 'items': 0, 'skipped_targets': skipped}
    temporary.replace(destination)
    return {'run_id': run_id, 'status': 'exported', 'path': str(destination.resolve()),
            'items': count, 'targets': targets, 'skipped_targets': skipped}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True, help='infra-runs folder')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run-id')
    parser.add_argument('--manifest', type=Path, required=True)
    args = parser.parse_args()
    if args.run_id and not RUN_ID.fullmatch(args.run_id):
        parser.error('invalid run ID')
    folders = [args.root / args.run_id] if args.run_id else sorted(args.root.glob('*'))
    results = []
    for folder in folders:
        if not (folder / 'summary.json').is_file():
            continue
        try:
            result = export_run(folder, args.output)
        except Exception as exc:
            result = {'run_id': folder.name, 'status': 'error', 'error': str(exc)}
        results.append(result)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    print('TXT 저장: ' + str(sum(r['status'] == 'exported' for r in results)) + '개 회차 / ' + str(args.output))
    return 1 if any(r['status'] == 'error' for r in results) else 0


if __name__ == '__main__':
    raise SystemExit(main())
