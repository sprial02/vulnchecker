"""Local customer execution; bundled sources only, no network/bootstrap/install steps."""
import argparse
from datetime import datetime, timezone
import getpass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import uuid
import zipfile

from profiles import CATALOG
from run import analyze
from failure_reasons import write_failures

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def inside(path, root):
    try:
        path.resolve().relative_to(root)
        return True
    except ValueError:
        return False


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package(run_dir, summary):
    write_json(run_dir / 'summary.json', summary)
    write_failures(run_dir / 'failures.csv', summary)
    files = [run_dir / n for n in ('summary.json', 'failures.csv', 'metadata.json', 'source-compatibility.json') if (run_dir / n).is_file()]
    files += sorted(run_dir.glob('*/evidence.tar.gz'))
    manifest = {'schema_version': 1, 'type': 'triguard-offline-result', 'run_id': summary['run_id'],
                'files': [{'path': f.relative_to(run_dir).as_posix(), 'bytes': f.stat().st_size, 'sha256': sha256(f)} for f in files]}
    write_json(run_dir / 'manifest.json', manifest)
    result = run_dir.parent / (run_dir.name + '.zip')
    temporary = result.with_suffix('.zip.tmp')
    with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for path in files + [run_dir / 'manifest.json']:
            archive.write(path, path.relative_to(run_dir).as_posix())
    temporary.replace(result)
    print('\nRETURN THIS RESULT ZIP: ' + str(result), flush=True)
    print('Failed/incomplete targets: ' + str(len(summary['failed_hosts'])), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description='TriGuard local Unix assessment (offline)')
    parser.add_argument('--output', type=Path, default=Path(os.environ.get('TRIGUARD_LAUNCH_DIR', '.')) / 'results')
    parser.add_argument('--target-id', default='', help='server name or IP; default local hostname')
    parser.add_argument('--profile', action='append', choices=[k for k, v in CATALOG.items() if v['Family'] == 'posix'])
    parser.add_argument('--item-timeout', type=int, default=90)
    parser.add_argument('--instance-root', default='')
    parser.add_argument('--db-user', default='')
    parser.add_argument('--db-host', default='localhost')
    parser.add_argument('--db-port', type=int)
    parser.add_argument('--db-name', default='')
    args = parser.parse_args()
    if not 10 <= args.item_timeout <= 3600:
        parser.error('--item-timeout must be 10..3600 seconds')
    if args.profile and sum(CATALOG[k]['Category'] == 'Unix OS' for k in set(args.profile)) > 1:
        parser.error('Select only one Unix OS profile per run')
    if args.instance_root and (not re.fullmatch(r'/[A-Za-z0-9_./-]+', args.instance_root) or not Path(args.instance_root).is_dir()):
        parser.error('--instance-root must be an existing Unix absolute path without spaces')
    if not re.fullmatch(r'[A-Za-z0-9:_.-]+', args.db_host) or (args.db_port is not None and not 1 <= args.db_port <= 65535):
        parser.error('Invalid DB host/port')
    if args.instance_root and (not args.profile or len(args.profile) != 1 or CATALOG[args.profile[0]]['Category'] != 'Web'):
        parser.error('--instance-root requires exactly one Web/WAS --profile')
    requested = args.target_id or socket.gethostname()
    target = requested if ':' not in requested else 'ip6-' + requested.replace(':', '-')
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,180}', target):
        parser.error('Target ID must be a server name or IP (letters, digits, _, ., -)')
    os.umask(0o077)
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
    run_dir = output / run_id
    run_dir.mkdir(mode=0o700)
    provenance = json.loads((ROOT / 'source-compatibility.json').read_text(encoding='utf-8'))
    shutil.copyfile(ROOT / 'source-compatibility.json', run_dir / 'source-compatibility.json')
    addresses = []
    try:
        addresses = subprocess.check_output(['hostname', '-I'], text=True, stderr=subprocess.DEVNULL, timeout=5).split()
    except (OSError, subprocess.SubprocessError):
        pass
    summary = {'run_id': run_id, 'revision': provenance['source_revision'], 'collection_method': 'customer-offline',
               'preflight': False, 'physical_servers': 1, 'hosts': [], 'targets': {}, 'servers': {},
               'failed_hosts': [], 'vulnerable_hosts': [], 'manual_hosts': [], 'ansible_rc': 0,
               'limitations': 'Local collected evidence; unavailable tools, permissions and incomplete results require review. Service process/package checks may cover the entire host.'}
    write_json(run_dir / 'metadata.json', {'schema_version': 1, 'run_id': run_id, 'hostname': socket.gethostname(),
               'target_id': requested, 'addresses': addresses, 'executed_as_uid': os.geteuid(),
               'python': sys.version.split()[0], 'source_revision': provenance['source_revision']})
    discovery = load_script('discover-target')
    wrapper = load_script('linux-execute')
    jobs = []
    preparation_error = ''
    try:
        if args.profile:
            for i, profile_id in enumerate(dict.fromkeys(args.profile)):
                profile = CATALOG[profile_id]
                identifier = 'os' if profile['Category'] == 'Unix OS' else profile_id + '-' + str(i + 1)
                jobs.append({'Id': identifier, 'Profile': profile_id, 'Root': args.instance_root,
                             'Bash': shutil.which('bash') or '/bin/bash', 'Python': sys.executable, 'RunAs': ''})
        else:
            detected = discovery.discover()
            summary['limitations'] += ' / ' + ' / '.join(detected['Notes'])
            jobs = [r for r in detected['Candidates'] if r['Ready'] and CATALOG[r['Profile']]['Category'] != 'DBMS']
            excluded = [r['Profile'] for r in detected['Candidates'] if not r['Ready']]
            if excluded:
                summary['limitations'] += ' / Not executed (configuration required): ' + ', '.join(excluded)
            if not any(r['Id'] == 'os' for r in jobs):
                raise ValueError('Unsupported or undetected OS; select a supported profile after verification.')
        if os.geteuid() != 0:
            raise ValueError('Root privileges required. Re-run from an approved root/sudo session.')
        db_jobs = [j for j in jobs if CATALOG[j['Profile']]['Category'] == 'DBMS']
        if db_jobs and (len(db_jobs) != 1 or len(jobs) != 1 or not args.db_user):
            raise ValueError('DB checks require exactly one --profile and --db-user. The password is prompted securely.')
        if db_jobs:
            job = db_jobs[0]
            job.update(DbUser=args.db_user, DbHost=args.db_host, DbPort=args.db_port or CATALOG[job['Profile']]['DbPort'],
                       DbName=args.db_name, DbPassword=getpass.getpass('DB password (not saved in result): '))
            if not job['DbPassword']:
                raise ValueError('DB password was not supplied.')
    except Exception as exc:
        preparation_error = str(exc)
    if preparation_error:
        jobs = [{'Id': 'os', 'Profile': (args.profile or ['unresolved'])[0]}]
    for job in jobs:
        profile_id = job['Profile']
        alias = target if job['Id'] == 'os' else target + '--' + job['Id']
        summary['hosts'].append(alias)
        summary['targets'][alias] = {'server': target, 'host': addresses[0] if addresses else requested, 'port': '',
                                     'connection': 'local', 'instance': job['Id'], 'profile': profile_id}
        errors = []
        outcome = {'execution_failed': True, 'errors': [], 'counts': {}, 'vulnerable': False, 'manual': False}
        if preparation_error:
            outcome['errors'] = [preparation_error]
        else:
            profile = CATALOG[profile_id]
            workspace = run_dir / 'workspaces' / alias
            workspace.mkdir(parents=True, mode=0o700)
            shutil.copytree(ROOT / 'lib', workspace / 'lib')
            shutil.copytree(ROOT / profile['Folder'], workspace / profile['Folder'])
            config = workspace / 'instance.json'
            write_json(config, job)
            process = None
            redacted = True
            print('Checking ' + alias + ' / ' + profile_id + ' (' + str(profile['Count']) + ' items)', flush=True)
            try:
                process = subprocess.Popen([sys.executable, str(ROOT / 'scripts/linux-execute.py'), str(workspace),
                                            profile_id, str(args.item_timeout), '--instance', str(config)],
                                           stdin=subprocess.DEVNULL, start_new_session=True, env={**os.environ, 'TRIGUARD_PROGRESS': '1'})
                rc = process.wait(timeout=max(600, args.item_timeout * profile['Count'] + 300))
                if rc:
                    errors.append('Local execution wrapper failed (exit ' + str(rc) + ').')
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                errors.append('Overall execution timeout; collected evidence is incomplete.')
            except Exception:
                errors.append('Local execution failed; verify local prerequisites and execution logs.')
            finally:
                try:
                    wrapper.redact(workspace, job, config)
                except Exception:
                    redacted = False
                    errors.append('Evidence masking failed; this target evidence is withheld. Review private local workspace.')
                finally:
                    if config.exists():
                        config.unlink()
                    job.pop('DbPassword', None)
            host_dir = run_dir / alias
            host_dir.mkdir()
            if not redacted:
                outcome['errors'] = errors
                summary['servers'][alias] = outcome
                summary['failed_hosts'].append(alias)
                continue
            with tarfile.open(host_dir / 'evidence.tar.gz', 'w:gz') as tar:
                candidates = [workspace / 'execution.json']
                candidates += list((workspace / 'execution-logs').rglob('*'))
                candidates += list((workspace / profile['Folder']).rglob('*'))
                for file in sorted(candidates):
                    if file.is_file() and not file.is_symlink() and inside(file, workspace) and file.suffix not in ('.sh', '.ps1'):
                        tar.add(file, arcname=file.relative_to(workspace).as_posix(), recursive=False)
            outcome = analyze(host_dir, profile_id)
            outcome['errors'] = errors + outcome['errors']
            outcome['execution_failed'] = bool(outcome['errors'])
        summary['servers'][alias] = outcome
        for condition, key in [('execution_failed', 'failed_hosts'), ('vulnerable', 'vulnerable_hosts'), ('manual', 'manual_hosts')]:
            if outcome[condition]:
                summary[key].append(alias)
    if summary['failed_hosts']:
        summary['ansible_rc'] = 1  # Compatibility field; no Ansible is run by this tool.
    package(run_dir, summary)
    return 2 if summary['failed_hosts'] else 0


if __name__ == '__main__':
    sys.exit(main())
