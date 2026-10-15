"""Allowlisted KISA check families and separately identified service instances."""
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
catalog_path=Path(__file__).with_name('profiles.json')
if not catalog_path.exists():catalog_path=ROOT/'profiles.json'
CATALOG={p['Id']:p for p in json.loads(catalog_path.read_text(encoding='utf-8-sig'))}

def default_profile(connection,platform='Debian'):
    if connection!='ssh':return 'windows'
    return {'Auto':'unix-debian','Debian':'unix-debian','RedHat':'unix-redhat','AIX':'unix-aix','HP-UX':'unix-hpux','Solaris':'unix-solaris'}[platform]

def instances(server):
    rows=server.get('Profiles')
    if rows is None:rows=[{'Id':'os','Profile':default_profile(server['Connection'],server.get('Platform','Debian'))}]
    if not rows:raise ValueError(server['Alias']+': 점검 구성을 하나 이상 등록하세요.')
    ids=set();seen={}
    for raw in rows:
        row=dict(raw);identifier=str(row.get('Id',''))
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}',identifier) or identifier in ids:raise ValueError('점검 인스턴스 ID가 없거나 중복입니다.')
        ids.add(identifier);profile=CATALOG.get(row.get('Profile'))
        if not profile:raise ValueError('지원하지 않는 점검 프로필입니다.')
        if (server['Connection']=='ssh')!=(profile['Family']=='posix'):raise ValueError(profile['Label']+': Bash/SSH 또는 Windows 원격 접속 방식을 확인하세요.')
        if profile['Category']=='Unix OS' and server.get('Platform')!='Auto' and profile['Id']!=default_profile('ssh',server.get('Platform','Debian')):raise ValueError('서버 OS와 Unix 점검 프로필이 다릅니다.')
        if identifier=='os' and profile['Category'] not in ('Unix OS','Windows OS','PC'):raise ValueError('os ID는 운영체제 점검에만 사용할 수 있습니다.')
        row.setdefault('Root','');row.setdefault('RunAs','');row.setdefault('Bash','/bin/bash');row.setdefault('Python','/usr/bin/python3')
        for key in ('Root','Bash','Python'):
            value=row[key]
            if profile['Family']=='posix' and value and not re.fullmatch(r'/[A-Za-z0-9_./-]+',value):raise ValueError(key+': 공백 없는 Unix 절대 경로를 입력하세요.')
        if row['RunAs'] and not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]*',row['RunAs']):raise ValueError('실행 계정이 올바르지 않습니다.')
        if profile['Category']=='DBMS':
            row.setdefault('DbHost','localhost');row.setdefault('DbPort',profile['DbPort']);row.setdefault('DbName','');row.setdefault('DbUser','');row.setdefault('DbPassword','')
            if not re.fullmatch(r'[A-Za-z0-9:_.-]+',row['DbHost']) or not 1<=int(row['DbPort'])<=65535:raise ValueError('DB 주소와 포트를 확인하세요.')
            if not row['DbUser'] or not row['DbPassword']:raise ValueError(profile['Label']+': DB 점검 계정과 암호를 등록하세요.')
        # Repeated middleware profiles require a distinct configuration root.
        scope=row['Root'] if profile['Category']=='Web' else (row.get('DbHost'),row.get('DbPort'),row.get('DbName')) if profile['Category']=='DBMS' else 'os'
        key=(profile['Id'],str(scope))
        if key in seen:raise ValueError(profile['Label']+': 같은 점검 범위를 중복 등록할 수 없습니다.')
        seen[key]=identifier
        if profile['Id']=='iis' and row['Root']:raise ValueError('IIS 원본은 서버 전체 IIS 구성 점검입니다. 개별 사이트 경로는 지원하지 않습니다.')
        yield row,profile

def expected(profile_id):
    p=CATALOG[profile_id];return {f"{p['Prefix']}-{n:02d}" for n in range(1,p['Count']+1)}
