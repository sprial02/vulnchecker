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
import yaml
from ansible.parsing.vault import VaultLib, VaultSecret

ROOT = Path(__file__).resolve().parents[1]
GUI = ROOT / 'inventory/gui'

def vault(key):
    return VaultLib([('default', VaultSecret(key.encode()))])

def sync(servers, selected=()):
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
    aliases = set()
    for server in servers:
        if not server.get('Enabled', True) and server['Alias'] not in selected:
            continue
        alias, host = server['Alias'], server['Host']
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', alias) or alias in aliases:
            raise ValueError('서버 이름은 중복 없는 영문/숫자/점/밑줄/하이픈이어야 합니다.')
        aliases.add(alias)
        if not re.fullmatch(r'[A-Za-z0-9:_.-]+', host):
            raise ValueError('올바른 서버 IP 또는 호스트 이름을 입력하세요.')
        connection = server['Connection']
        port, timeout = int(server['Port']), int(server['Timeout'])
        if not 1 <= port <= 65535 or not 10 <= timeout <= 3600:
            raise ValueError('포트 또는 항목 시간 제한 범위가 잘못됐습니다.')
        variables = {'ansible_host': host, 'ansible_user': server['User'], 'ansible_port': port,
                     'ansible_connection': connection, 'kisa_item_timeout': timeout,
                     'kisa_run_timeout': max(7200, timeout * 67 + 600)}
        password_key = 'gui_password_' + alias.replace('-', '_').replace('.', '_')
        # Include a digest-free unique suffix to prevent aliases like a-b/a_b colliding.
        password_key += '_' + str(len(aliases))
        values[password_key] = server.get('Password', '')
        if server.get('Password'):
            variables['ansible_password'] = '{{ ' + password_key + ' }}'
        if connection == 'ssh':
            variables.update(ansible_become=server['User'] != 'root', ansible_become_method='sudo',
                             ansible_python_interpreter='/usr/bin/python3', kisa_platform=server['Platform'],
                             ansible_ssh_common_args='-o UserKnownHostsFile=' + str(known))
            if server.get('KeyFile'):
                keypath = Path(server['KeyFile']).expanduser()
                if not keypath.is_absolute() or not keypath.is_file():
                    raise ValueError('SSH 키는 존재하는 Kali 절대 경로로 입력하세요.')
                variables['ansible_ssh_private_key_file'] = str(keypath)
            elif not server.get('Password'):
                raise ValueError('SSH 암호 또는 키 파일을 등록하세요.')
            values[password_key + '_sudo'] = server.get('BecomePassword') or server.get('Password', '')
            variables['ansible_become_password'] = '{{ ' + password_key + '_sudo }}'
            lookup = host if port == 22 else f'[{host}]:{port}'
            existing = subprocess.run(['ssh-keygen', '-F', lookup, '-f', str(known)], capture_output=True, text=True)
            if existing.returncode and server.get('TrustNewHostKey'):
                scan = subprocess.run(['ssh-keyscan', '-p', str(port), '-T', '5', '-t', 'ed25519,rsa', host],
                                      capture_output=True, text=True)
                if not scan.stdout.strip():
                    raise ValueError('SSH 호스트 키를 조회하지 못했습니다.')
                with known.open('a') as output:
                    output.write(scan.stdout)
            elif existing.returncode:
                raise ValueError('SSH 키가 미등록입니다. 최초 SSH 키 등록을 선택한 뒤 접속 확인하세요.')
            inventory['all']['children']['linux']['hosts'][alias] = variables
        elif connection in ('winrm', 'psrp'):
            if not server.get('Password'):
                raise ValueError('Windows 접속 암호를 등록하세요.')
            protocol = server['Protocol']
            if protocol not in ('http', 'https'):
                raise ValueError('Windows 연결 방식은 HTTP 또는 HTTPS입니다.')
            if connection == 'winrm':
                variables.update(ansible_winrm_transport='ntlm', ansible_winrm_scheme=protocol,
                                 ansible_winrm_message_encryption='always', ansible_winrm_server_cert_validation='validate')
            else:
                variables.update(ansible_psrp_auth='ntlm', ansible_psrp_protocol=protocol,
                                 ansible_psrp_message_encryption='always', ansible_psrp_cert_validation='validate')
            inventory['all']['children']['windows']['hosts'][alias] = variables
        else:
            raise ValueError('지원하지 않는 접속 방식입니다.')
    (GUI / 'group_vars/all/vault.yml').write_bytes(vault(keyfile.read_text()).encrypt(yaml.safe_dump(values).encode()))
    (GUI / 'hosts.yml').write_text(yaml.safe_dump(inventory, allow_unicode=True))

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
    parser.add_argument('action', choices=['import', 'preflight', 'run', 'retry'])
    args = parser.parse_args()
    os.chdir(ROOT)
    os.umask(0o077)
    if args.action == 'import':
        print(json.dumps(import_previous()))  # captured privately by the Windows bridge
        return 0
    payload = json.load(sys.stdin)
    selected = payload.get('Hosts', [])
    if args.action == 'retry':
        run_id = payload['RunId']
        if not re.fullmatch(r'\d{8}T\d{6}Z-[a-f0-9]{8}', run_id):
            raise ValueError('재실행할 점검 이력을 선택하세요.')
        previous = json.loads((ROOT / 'runs' / run_id / 'summary.json').read_text())
        if not selected:
            selected = previous['failed_hosts']
    sync(payload['Servers'], selected)
    command = [str(ROOT / '.venv/bin/python'), str(ROOT / 'scripts/run.py'),
               '--inventory', str(GUI / 'hosts.yml'), '--vault-password-file', str(GUI / '.vault-password')]
    if args.action == 'preflight':
        command.append('--preflight')
    if payload.get('Hosts'):
        command += ['--hosts', ','.join(payload['Hosts'])]
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
