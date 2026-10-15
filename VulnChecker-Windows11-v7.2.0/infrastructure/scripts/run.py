"""CLI for isolated runs, result validation and exact-host selective retries."""
import argparse
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import uuid
import zipfile
from collections import Counter
from prepare_source import prepare, REVISION
from source_compat import adapt
from profiles import CATALOG,expected,default_profile
from failure_reasons import write_failures

ROOT = Path(__file__).resolve().parents[1]
VALID_RESULTS = {'GOOD', 'VULNERABLE', 'MANUAL', 'N/A', 'NA', 'NOT_APPLICABLE'}

def group_hosts(inventory, name, seen=None):
    seen = set() if seen is None else seen
    if name in seen:
        return set()
    seen.add(name)
    group = inventory.get(name, {})
    hosts = set(group.get('hosts', []))
    for child in group.get('children', []):
        hosts |= group_hosts(inventory, child, seen)
    return hosts

def bundles(source, destination):
    files = []
    compatibility=[]
    for name in ['lib', '01.Unix서버', '02.Windows서버','03.웹서버','07.PC','08.DBMS']:
        files.extend(p for p in (source / name).rglob('*') if p.is_file())
    with tarfile.open(destination / 'source.tar.gz', 'w:gz') as tar, zipfile.ZipFile(destination / 'source.zip', 'w', zipfile.ZIP_DEFLATED) as zipout:
        for path in files:
            relative = path.relative_to(source).as_posix()
            data = path.read_bytes()
            if path.suffix == '.sh':
                data = data.replace(b'\r\n', b'\n')
                data,change=adapt(relative,data)
                if change:compatibility.append(change)
            if path.suffix == '.ps1' and not data.startswith(b'\xef\xbb\xbf'):
                data = b'\xef\xbb\xbf' + data
            info = tarfile.TarInfo(relative)
            info.size = len(data)
            info.mode = 0o700 if path.suffix == '.sh' else 0o600
            tar.addfile(info, io.BytesIO(data))
            zipout.writestr(relative, data)
        manifest=json.dumps({'source_revision':REVISION,'adaptations':compatibility},ensure_ascii=False,indent=2).encode('utf-8')
        info=tarfile.TarInfo('source-compatibility.json');info.size=len(manifest);info.mode=0o600
        tar.addfile(info,io.BytesIO(manifest));zipout.writestr('source-compatibility.json',manifest)
    (destination/'source-compatibility.json').write_bytes(manifest)
    return compatibility

def evidence_files(host_dir):
    """Read archive entries without extracting attacker-controlled paths."""
    tarpath, zippath = host_dir / 'evidence.tar.gz', host_dir / 'evidence.zip'
    if tarpath.exists():
        with tarfile.open(tarpath) as archive:
            for entry in archive:
                if entry.isfile() and entry.name.endswith('.json'):
                    if entry.size > 16 * 1024 * 1024:
                        raise ValueError('oversized JSON evidence')
                    yield entry.name, archive.extractfile(entry).read()
    elif zippath.exists():
        with zipfile.ZipFile(zippath) as archive:
            for entry in archive.infolist():
                if entry.filename.endswith('.json'):
                    if entry.file_size > 16 * 1024 * 1024:
                        raise ValueError('oversized JSON evidence')
                    yield entry.filename, archive.read(entry)
    else:
        raise ValueError('no collected evidence')

def analyze(host_dir, platform):
    profile_id={'linux':'unix-debian','windows':'windows'}.get(platform,platform)
    expected_items = expected(profile_id);count=len(expected_items)
    errors, results, executions = [], {}, None
    try:
        for name, raw in evidence_files(host_dir):
            try:
                value = json.loads(raw.decode('utf-8-sig'))
            except (UnicodeError, ValueError) as e:
                errors.append(f'invalid JSON: {name}: {e}')
                continue
            if Path(name).name == 'execution.json':
                executions = value
            elif isinstance(value, dict) and value.get('item_id') in expected_items:
                item = value['item_id']
                if item in results:
                    errors.append(f'duplicate result: {item}')
                results[item] = value
    except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile) as e:
        errors.append(str(e))
    if not isinstance(executions, list):
        errors.append('missing execution manifest')
        executions = []
    recorded = []
    for record in executions:
        if not isinstance(record, dict):
            errors.append('invalid execution record')
            continue
        recorded.append(record.get('item_id'))
        if record.get('rc') != 0:
            detail = {124: '항목 응답 시간 초과', 125: '연속 시간 초과로 남은 항목 건너뜀'}.get(record.get('rc'), '')
            errors.append(f'{record.get("item_id")}: exit {record.get("rc")}' + (' · ' + detail if detail else ''))
    if set(recorded) != expected_items or len(recorded) != count:
        errors.append('incomplete execution manifest')
    for missing in sorted(expected_items - results.keys()):
        errors.append(f'missing JSON: {missing}')
    counts = Counter()
    for item, value in results.items():
        status = value.get('final_result', value.get('diagnosis_result'))
        if status not in VALID_RESULTS:
            errors.append(f'{item}: invalid/failed result {status}')
        counts[str(status)] += 1
    return {'execution_failed': bool(errors), 'errors': errors,
            'counts': dict(counts), 'vulnerable': counts['VULNERABLE'] > 0,
            'manual': counts['MANUAL'] > 0}


def execute_batches(command, environment, groups, run_dir, batch_size):
    """A completely failed Ansible serial batch must not stop subsequent batches/OS."""
    batches = [group[start:start + batch_size] for group in groups for start in range(0, len(group), batch_size)]
    combined = {}
    result = 0
    directory = run_dir / 'batches'
    directory.mkdir()
    for number, hosts in enumerate(batches, 1):
        limit = directory / f'{number:05}.hosts.txt'
        limit.write_text(''.join(h + '\n' for h in hosts), encoding='utf-8')
        status = directory / f'{number:05}.status.json'
        current = list(command)
        current[current.index('--limit') + 1] = '@' + str(limit)
        print(f'배치 {number}/{len(batches)} · {len(hosts)}개 대상 시작', flush=True)
        rc = subprocess.call(current, env={**environment, 'INFRA_STATUS_PATH': str(status)})
        if status.is_file():
            combined.update(json.loads(status.read_text(encoding='utf-8')))
        path = Path(environment['INFRA_STATUS_PATH'])
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(combined, ensure_ascii=False, indent=2), encoding='utf-8')
        temporary.replace(path)
        if rc in (130, -2):
            raise KeyboardInterrupt
        if rc:
            result = rc
            print(f'배치 {number} 실패 대상 기록. 다음 배치를 계속합니다.', flush=True)
    return result

def main():
    parser = argparse.ArgumentParser(description='KISA infrastructure checks / selective retries')
    parser.add_argument('--inventory', default='inventory/hosts.yml')
    parser.add_argument('--hosts', help='comma-separated inventory aliases')
    parser.add_argument('--retry-from', type=Path, help='prior run folder')
    parser.add_argument('--retry-kind', choices=['failed', 'vulnerable', 'manual'], default='failed')
    parser.add_argument('--ask-vault-pass', action='store_true')
    parser.add_argument('--vault-password-file', help='Kali path to a protected Vault password file')
    parser.add_argument('--ask-become-pass', action='store_true')
    parser.add_argument('--ask-pass', action='store_true')
    parser.add_argument('--preflight', action='store_true', help='connection checks only')
    parser.add_argument('--forks', type=int, default=20, help='concurrent Ansible workers (1-100)')
    parser.add_argument('--batch-size', type=int, default=100, help='hosts per platform batch (1-1000)')
    args = parser.parse_args()
    if not 1 <= args.forks <= 100 or not 1 <= args.batch_size <= 1000:
        parser.error('forks must be 1-100 and batch-size must be 1-1000')
    os.chdir(ROOT)
    os.umask(0o077)
    inventory_path = str(Path(args.inventory).resolve())
    inventory_cmd = [str(ROOT / '.venv/bin/ansible-inventory'), '-i', inventory_path, '--list']
    if args.ask_vault_pass:
        inventory_cmd.append('--ask-vault-pass')
    if args.vault_password_file:
        inventory_cmd += ['--vault-password-file', str(Path(args.vault_password_file).resolve())]
    inventory = json.loads(subprocess.check_output(inventory_cmd, text=True))
    linux, windows = group_hosts(inventory, 'linux'), group_hosts(inventory, 'windows')
    if linux & windows:
        parser.error('A host must not belong to both Linux and Windows groups')
    selected = linux | windows
    if args.retry_from:
        previous = json.loads((args.retry_from.resolve() / 'summary.json').read_text(encoding='utf-8'))
        key = {'failed': 'failed_hosts', 'vulnerable': 'vulnerable_hosts', 'manual': 'manual_hosts'}[args.retry_kind]
        retry = set(previous[key])
        if retry - selected:
            parser.error('Retry host missing from inventory: ' + ', '.join(sorted(retry - selected)))
        selected = retry
    if args.hosts:
        requested = set(args.hosts.split(','))
        if requested - selected:
            parser.error('Unknown or non-eligible host: ' + ', '.join(sorted(requested - selected)))
        selected = requested
    if not selected:
        print('재실행 대상이 없습니다.' if args.retry_from else '대상 서버가 없습니다.')
        return 0
    if any(not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', host) for host in selected):
        parser.error('Use safe inventory aliases: letters, numbers, underscore, dot, hyphen')
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
    run_dir = ROOT / 'runs' / run_id
    run_dir.mkdir(parents=True)
    initial = {'run_id': run_id, 'revision': REVISION, 'hosts': sorted(selected),
               'retry_from': str(args.retry_from.resolve()) if args.retry_from else None,
               'preflight': args.preflight, 'forks': args.forks, 'batch_size': args.batch_size}
    hostvars=inventory.get('_meta',{}).get('hostvars',{})
    initial['targets']={h:{'server':hostvars.get(h,{}).get('kisa_server',h),'instance':hostvars.get(h,{}).get('kisa_instance_id','os'),
       'host':hostvars.get(h,{}).get('ansible_host',h),'port':hostvars.get(h,{}).get('ansible_port',22 if h in linux else 5986),
       'connection':hostvars.get(h,{}).get('ansible_connection','ssh' if h in linux else 'winrm'),
       'profile':hostvars.get(h,{}).get('kisa_profile',default_profile('ssh' if h in linux else 'winrm',hostvars.get(h,{}).get('kisa_platform','Debian')))} for h in selected}
    initial['physical_servers']=len({t['server'] for t in initial['targets'].values()})
    notes=sorted({note for h in selected for note in hostvars.get(h,{}).get('kisa_discovery_notes',[])})
    notes.append('설치 경로 지정은 원본의 알려진 설정 파일 경로를 해당 인스턴스로 연결합니다. 프로세스·패키지 등 일부 원본 항목은 호스트 전체를 점검합니다. IIS는 서버 전체 구성 점검입니다.')
    initial['limitations']=' / '.join(notes)
    (run_dir / 'request.json').write_text(json.dumps(initial, indent=2), encoding='utf-8')
    limit_path = run_dir / 'hosts.txt'
    limit_path.write_text(''.join(host + '\n' for host in sorted(selected)), encoding='utf-8')
    if not args.preflight:
        initial['compatibility']=bundles(prepare(), run_dir)
        (run_dir / 'request.json').write_text(json.dumps(initial,indent=2),encoding='utf-8')
    command = [str(ROOT / '.venv/bin/ansible-playbook'), '-i', inventory_path,
               'playbooks/preflight.yml' if args.preflight else 'playbooks/check.yml',
               '--limit', '@' + str(limit_path), '--forks', str(args.forks),
               '-e', json.dumps({'infra_batch_size': args.batch_size})]
    if not args.preflight:
        extra = {'controller_run_dir': str(run_dir), 'controller_bundle_tar': str(run_dir / 'source.tar.gz'),
                 'controller_bundle_zip': str(run_dir / 'source.zip')}
        extra_path = run_dir / 'vars.json'
        extra_path.write_text(json.dumps(extra), encoding='utf-8')
        command += ['-e', '@' + str(extra_path)]
    for enabled, flag in [(args.ask_vault_pass, '--ask-vault-pass'),
                          (args.ask_become_pass, '--ask-become-pass'), (args.ask_pass, '--ask-pass')]:
        if enabled:
            command.append(flag)
    if args.vault_password_file:
        command += ['--vault-password-file', str(Path(args.vault_password_file).resolve())]
    environment = {**os.environ, 'ANSIBLE_CONFIG': str(ROOT / 'ansible.cfg'),
                   'INFRA_STATUS_PATH': str(run_dir / 'ansible-status.json')}
    print('실행 결과:', run_dir, flush=True)
    try:
        rc = execute_batches(command, environment, [sorted(selected & linux), sorted(selected & windows)], run_dir, args.batch_size)
    except KeyboardInterrupt:
        rc = 130
    stats_path = run_dir / 'ansible-status.json'
    stats = json.loads(stats_path.read_text()) if stats_path.exists() else {}
    summary = {**initial, 'ansible_rc': rc, 'servers': {}, 'failed_hosts': [],
               'vulnerable_hosts': [], 'manual_hosts': []}
    for host in sorted(selected):
        state = stats.get(host)
        outcome = {'execution_failed': False, 'counts': {}, 'errors': [], 'vulnerable': False, 'manual': False}
        if not args.preflight and ((state and not (state.get('failures',0) or state.get('unreachable',0))) or any((run_dir / host / f).is_file() for f in ('evidence.zip','evidence.tar.gz'))):
            outcome = analyze(run_dir / host, initial['targets'][host]['profile'])
        outcome['diagnostics'] = list(hostvars.get(host,{}).get('kisa_precheck_failure',[])) + list((state or {}).get('diagnostics',[]))
        if not state or state.get('failures', 0) or state.get('unreachable', 0):
            outcome['execution_failed'] = True
            if outcome['diagnostics']:
                outcome['errors'] = [d['reason']+' / '+d.get('task','')+' / '+d['action'] for d in outcome['diagnostics']] + outcome['errors']
            else:
                outcome['errors'].insert(0,'연결/작업 실패 또는 실행 미완료 · 구체 원인은 확인되지 않았습니다. 연결 상태와 서버 로그를 확인하세요.')
        outcome['ansible'] = state
        summary['servers'][host] = outcome
        for condition, key in [('execution_failed', 'failed_hosts'), ('vulnerable', 'vulnerable_hosts'), ('manual', 'manual_hosts')]:
            if outcome[condition]:
                summary[key].append(host)
    (run_dir / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    write_failures(run_dir / 'failures.csv', summary)
    for key in ['failed_hosts', 'vulnerable_hosts', 'manual_hosts']:
        (run_dir / f'{key}.txt').write_text(''.join(host + '\n' for host in summary[key]), encoding='utf-8')
    print('실행 실패 서버:', ', '.join(summary['failed_hosts']) or '없음')
    for host in summary['failed_hosts']:
        print(host+' 실패 사유: '+ '; '.join(summary['servers'][host]['errors']))
    print('취약 항목 발견 서버:', ', '.join(summary['vulnerable_hosts']) or '없음')
    print('요약:', run_dir / 'summary.json')
    return 1 if summary['failed_hosts'] or rc else 0

if __name__ == '__main__':
    sys.exit(main())
