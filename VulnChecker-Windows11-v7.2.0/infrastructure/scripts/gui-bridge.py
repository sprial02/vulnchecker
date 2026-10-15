"""GUI bridge: credentials on stdin only, isolated Vault and local result export."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import shlex
import tempfile
import yaml
from ansible.parsing.vault import VaultLib, VaultSecret
from profiles import instances
from run import execute_batches

ROOT = Path(__file__).resolve().parents[1]
GUI = ROOT / 'inventory/gui'

def vault(key):
    return VaultLib([('default', VaultSecret(key.encode()))])

def prepare_host_keys(servers, known, selected):
    """OpenSSH pins new server identities during login; no private key registration."""
    for server in servers:
        if server['Connection'] != 'ssh' or (not server.get('Enabled', True) and server['Alias'] not in selected):
            continue
        host, port = server['Host'], int(server['Port'])
        if not re.fullmatch(r'[A-Za-z0-9:_.][A-Za-z0-9:_.-]*', host) or not 1 <= port <= 65535:
            raise ValueError('올바른 서버 주소와 포트를 입력하세요.')

def sync(servers, selected=(), transport_only=False):
    os.umask(0o077)
    GUI.mkdir(parents=True, exist_ok=True)
    (GUI / 'group_vars/all').mkdir(parents=True, exist_ok=True)
    keyfile = GUI / '.vault-password'
    if not keyfile.exists():
        keyfile.write_text(secrets.token_hex(32))
    values = {}
    inventory = {'all': {'children': {'linux': {'hosts': {}}, 'windows': {'hosts': {}}}}}
    known = GUI / 'known_hosts'
    if not known.exists():
        previous = ROOT / 'inventory/known_hosts-test'
        known.write_text(previous.read_text() if previous.exists() else '')
    jobs=[]
    for server in servers:
        if selected and not any(s==server['Alias'] or s.startswith(server['Alias']+'--') for s in selected):continue
        if not server.get('Enabled',True) and not any(s==server['Alias'] or s.startswith(server['Alias']+'--') for s in selected):continue
        if transport_only:
            server=dict(server);server.pop('Profiles',None)
            if server.get('Platform') == 'Auto': server['Platform']='Debian'
        for instance,profile in instances(server):
            job=dict(server);job['ServerAlias']=server['Alias'];job['Alias']=server['Alias'] if instance['Id']=='os' else server['Alias']+'--'+instance['Id'];job['Instance']=instance;job['ProfileSpec']=profile
            jobs.append(job)
    prepare_host_keys(jobs, known, selected)
    aliases = set()
    for server in jobs:
        if not server.get('Enabled', True) and server['Alias'] not in selected:
            continue
        alias, host = server['Alias'], server['Host']
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', alias) or alias in aliases:
            raise ValueError('서버 이름은 중복 없는 영문/숫자/점/밑줄/하이픈이어야 합니다.')
        aliases.add(alias)
        if not re.fullmatch(r'[A-Za-z0-9:_.][A-Za-z0-9:_.-]*', host):
            raise ValueError('올바른 서버 IP 또는 호스트 이름을 입력하세요.')
        connection = server['Connection']
        port, timeout = int(server['Port']), int(server['Timeout'])
        if not 1 <= port <= 65535 or not 10 <= timeout <= 3600:
            raise ValueError('포트 또는 항목 시간 제한 범위가 잘못됐습니다.')
        variables = {'ansible_host': host, 'ansible_user': server['User'], 'ansible_port': port,
                     'ansible_connection': connection, 'kisa_item_timeout': timeout,
                     'ansible_timeout': 15, 'kisa_run_timeout': max(600, timeout * server['ProfileSpec']['Count'] + 300)}
        instance=server['Instance'];profile=server['ProfileSpec']
        variables.update(kisa_server=server['ServerAlias'],kisa_instance_id=instance['Id'],kisa_profile=profile['Id'],
                         kisa_folder=profile['Folder'],kisa_evidence_folder=profile['Folder'].split('/')[0],kisa_prefix=profile['Prefix'],kisa_item_count=profile['Count'])
        variables['kisa_discovery_notes']=server.get('DiscoveryNotes',[])
        variables['kisa_skip_reason']=server.get('SkipReason','')
        variables['kisa_precheck_failure']=server.get('PrecheckFailure',[])
        password_key = 'gui_password_' + alias.replace('-', '_').replace('.', '_')
        # Include a digest-free unique suffix to prevent aliases like a-b/a_b colliding.
        password_key += '_' + str(len(aliases))
        values[password_key] = server.get('Password', '')
        if server.get('Password'):
            variables['ansible_password'] = '{{ ' + password_key + ' }}'
        protected=dict(instance)
        if protected.get('DbPassword'):
            values[password_key+'_db']=protected['DbPassword'];protected['DbPassword']='{{ '+password_key+'_db }}'
        variables['kisa_instance']=protected
        if connection == 'ssh':
            variables.update(ansible_become=server['User'] != 'root', ansible_become_method='sudo',
                             ansible_python_interpreter=instance['Python'], kisa_platform=server['Platform'],
                             ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=' + shlex.quote(str(known)))
            if server.get('KeyFile'):
                keypath = Path(server['KeyFile']).expanduser()
                if not keypath.is_absolute() or not keypath.is_file():
                    raise ValueError('SSH 키는 존재하는 Kali 절대 경로로 입력하세요.')
                variables['ansible_ssh_private_key_file'] = str(keypath)
            elif not server.get('Password'):
                raise ValueError('SSH 암호 또는 키 파일을 등록하세요.')
            else:
                variables['ansible_ssh_common_args'] += ' -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o PasswordAuthentication=yes -o BatchMode=no'
                variables['ansible_ssh_password_mechanism'] = 'sshpass'
            values[password_key + '_sudo'] = server.get('BecomePassword') or server.get('Password', '')
            variables['ansible_become_password'] = '{{ ' + password_key + '_sudo }}'
            if instance['RunAs']:
                variables.update(ansible_become=True,ansible_become_user=instance['RunAs'])
            inventory['all']['children']['linux']['hosts'][alias] = variables
        elif connection in ('winrm', 'psrp'):
            if not server.get('Password'):
                raise ValueError('Windows 접속 암호를 등록하세요.')
            protocol = server['Protocol']
            if protocol not in ('http', 'https'):
                raise ValueError('Windows 연결 방식은 HTTP 또는 HTTPS입니다.')
            if connection == 'winrm':
                variables.update(ansible_winrm_transport='ntlm', ansible_winrm_scheme=protocol,
                                 ansible_winrm_operation_timeout_sec=20, ansible_winrm_read_timeout_sec=30,
                                 ansible_winrm_message_encryption='always', ansible_winrm_server_cert_validation='validate')
            else:
                variables.update(ansible_psrp_auth='ntlm', ansible_psrp_protocol=protocol,
                                 ansible_psrp_connection_timeout=15, ansible_psrp_operation_timeout=20, ansible_psrp_read_timeout=30,
                                 ansible_psrp_message_encryption='always', ansible_psrp_cert_validation='validate')
            inventory['all']['children']['windows']['hosts'][alias] = variables
        else:
            raise ValueError('지원하지 않는 접속 방식입니다.')
    (GUI / 'group_vars/all/vault.yml').write_bytes(vault(keyfile.read_text()).encrypt(yaml.safe_dump(values).encode()))
    (GUI / 'hosts.yml').write_text(yaml.safe_dump(inventory, allow_unicode=True))
    return {j['Alias']:j['ServerAlias'] for j in jobs}

def discover_servers(servers, selected, payload, allow_partial=False):
    sync(servers,selected,transport_only=True)
    with tempfile.TemporaryDirectory(prefix='discovery-',dir=GUI) as directory:
        command=[str(ROOT/'.venv/bin/ansible-playbook'),'-i',str(GUI/'hosts.yml'),
                 'playbooks/discover.yml','--vault-password-file',str(GUI/'.vault-password'),
                 '--forks',str(payload.get('Forks',20)), '-e',json.dumps({'discovery_dir':directory,'infra_batch_size':payload.get('BatchSize',100)})]
        command+=['--limit',','.join(selected) if selected else 'all']
        status_path=Path(directory)/'ansible-status.json'
        inventory=yaml.safe_load((GUI/'hosts.yml').read_text())['all']['children']
        groups=[sorted(inventory[k]['hosts']) for k in ('linux','windows')]
        rc=execute_batches(command,{**os.environ,'ANSIBLE_CONFIG':str(ROOT/'ansible.cfg'),'INFRA_STATUS_PATH':str(status_path)},
                           groups,Path(directory),int(payload.get('BatchSize',100)))
        found={p.stem:json.loads(p.read_text(encoding='utf-8-sig')) for p in Path(directory).glob('*.json') if p!=status_path}
        states=json.loads(status_path.read_text(encoding='utf-8')) if status_path.exists() else {}
        document={'Servers':found,'Failed':rc!=0,'Failures':{s['Alias']:states.get(s['Alias'],{}).get('diagnostics',[]) for s in servers if s['Alias'] not in found}}
        if allow_partial:
            for server in servers:
                if server['Alias'] not in found:
                    server['SkipReason']='자동 감지 실패: 지원 OS를 확인할 수 없어 이 서버의 점검을 건너뜁니다.'
                    server['PrecheckFailure']=document['Failures'].get(server['Alias'],[])
        destination=Path(payload['Output']);destination.mkdir(parents=True,exist_ok=True)
        (destination/'infra-discovery.json').write_text(json.dumps(document,ensure_ascii=False,indent=2),encoding='utf-8')
        if rc and not allow_partial: raise ValueError('자동 감지 접속/작업 실패. 로그와 감지 결과를 확인하세요.')
        return found

def import_previous():
    path, keyfile = ROOT / 'inventory/hosts.yml', ROOT / '.vault-password-test'
    if not path.exists() or not keyfile.exists():
        raise ValueError('이전에 검증한 점검 인벤토리가 없습니다.')
    data = json.loads(subprocess.check_output([str(ROOT / '.venv/bin/ansible-inventory'), '-i', str(path),
                                             '--list', '--vault-password-file', str(keyfile)], text=True, cwd=ROOT))
    servers = []
    for alias, variables in data['_meta']['hostvars'].items():
        def resolved(name):
            value = variables.get(name, '')
            if isinstance(value, str):
                match = re.fullmatch(r'\{\{\s*(\w+)\s*\}\}', value)
                if match:
                    return variables.get(match.group(1), '')
            return value
        connection = variables.get('ansible_connection')
        if connection not in ('ssh', 'winrm', 'psrp'):
            continue
        servers.append({'Alias': alias, 'Host': variables['ansible_host'], 'User': variables['ansible_user'],
                        'Connection': connection, 'Platform': variables.get('kisa_platform', 'Debian'),
                        'Port': variables.get('ansible_port', 22 if connection == 'ssh' else 5986),
                        'Protocol': variables.get('ansible_winrm_scheme', variables.get('ansible_psrp_protocol', 'https')),
                        'Password': resolved('ansible_password'), 'BecomePassword': resolved('ansible_become_password'),
                        'KeyFile': variables.get('ansible_ssh_private_key_file', ''),
                        'Timeout': variables.get('kisa_item_timeout', 90), 'Enabled': True, 'TrustNewHostKey': False})
    return servers

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['import', 'discover', 'preflight', 'run', 'retry'])
    args = parser.parse_args()
    os.chdir(ROOT)
    os.umask(0o077)
    if args.action == 'import':
        print(json.dumps(import_previous()))  # captured privately by the Windows bridge
        return 0
    payload = json.load(sys.stdin)
    selected = payload.get('Hosts', [])
    if args.action == 'discover':
        found=discover_servers(payload['Servers'],selected,payload)
        print('자동 감지 완료: '+str(len(found))+'대. 감지된 점검 대상을 선택하고 구성을 저장하세요.')
        return 0
    if args.action == 'run':
        automatic=[s for s in payload['Servers'] if s.get('Profiles') is None and (s.get('Enabled',True) or s['Alias'] in selected) and (not selected or s['Alias'] in selected)]
        if automatic:
            found=discover_servers(automatic,[s['Alias'] for s in automatic],payload,allow_partial=True)
            for server in automatic:
                data=found.get(server['Alias'])
                if not data:
                    print(server['Alias']+': '+server['SkipReason'],flush=True)
                    continue
                server['Profiles']=[r for r in data['Candidates'] if r['Ready']]
                if not any(r['Id']=='os' for r in server['Profiles']):
                    server.pop('Profiles',None)
                    server['SkipReason']='지원 OS를 확인하지 못했습니다. 점검 구성에서 수동으로 등록하세요.'
                    continue
                if data['Platform']:server['Platform']=data['Platform']
                server['DiscoveryNotes']=list(data['Notes'])
                for row in data['Candidates']:
                    if not row['Ready']:
                        note=row['Profile']+': 자동 실행 제외 · 점검 구성에서 접속 정보와 설치 범위를 등록하세요.'
                        server['DiscoveryNotes'].append(note);print(server['Alias']+' / '+note,flush=True)
                for note in data['Notes']:print(server['Alias']+': '+note,flush=True)
    if args.action == 'retry':
        run_id = payload['RunId']
        if not re.fullmatch(r'\d{8}T\d{6}Z-[a-f0-9]{8}', run_id):
            raise ValueError('재실행할 점검 이력을 선택하세요.')
        previous = json.loads((ROOT / 'runs' / run_id / 'summary.json').read_text())
        if not selected:
            selected = previous['failed_hosts']
    jobs=sync(payload['Servers'], selected,transport_only=args.action=='preflight')
    selected_jobs=[j for j,base in jobs.items() if j in selected or base in selected]
    command = [str(ROOT / '.venv/bin/python'), str(ROOT / 'scripts/run.py'),
               '--inventory', str(GUI / 'hosts.yml'), '--vault-password-file', str(GUI / '.vault-password'),
               '--forks', str(payload.get('Forks', 20)), '--batch-size', str(payload.get('BatchSize', 100))]
    if args.action == 'preflight':
        command.append('--preflight')
    if payload.get('Hosts'):
        if not selected_jobs:raise ValueError('선택한 서버에 실행 가능한 점검 구성이 없습니다.')
        command += ['--hosts', ','.join(selected_jobs)]
    if args.action == 'retry':
        run_id = payload['RunId']
        if not re.fullmatch(r'\d{8}T\d{6}Z-[a-f0-9]{8}', run_id):
            raise ValueError('재실행할 점검 이력을 선택하세요.')
        command += ['--retry-from', str(ROOT / 'runs' / run_id)]
    before = set((ROOT / 'runs').glob('*/summary.json')) if (ROOT / 'runs').exists() else set()
    rc = subprocess.call(command)
    after = set((ROOT / 'runs').glob('*/summary.json')) - before
    destination = Path(payload['Output'])
    destination.mkdir(parents=True, exist_ok=True)
    if after:
        newest = max(after, key=lambda path: path.stat().st_mtime)
        shutil.copytree(newest.parent, destination / newest.parent.name, dirs_exist_ok=True)
    return rc

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('인프라 작업 오류: ' + str(error), file=sys.stderr)
        sys.exit(1)
