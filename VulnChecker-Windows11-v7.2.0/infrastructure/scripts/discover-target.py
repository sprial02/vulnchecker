"""Read-only, bounded discovery. Observed services are candidates, never verdicts."""
import glob
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess


def os_profile(system, release, exists=lambda p: Path(p).exists()):
    if system in ('AIX', 'HP-UX', 'SunOS'):
        return {'AIX': 'unix-aix', 'HP-UX': 'unix-hpux', 'SunOS': 'unix-solaris'}[system]
    if system != 'Linux': return None
    names = set((release.get('ID', '') + ' ' + release.get('ID_LIKE', '')).lower().split())
    if names & {'debian', 'ubuntu', 'kali'}: return 'unix-debian'
    if names & {'rhel', 'fedora', 'centos', 'rocky', 'almalinux'}: return 'unix-redhat'
    if not names and exists('/etc/debian_version'): return 'unix-debian'
    if not names and exists('/etc/redhat-release'): return 'unix-redhat'
    return None


def discover():
    release = {}
    try:
        for line in Path('/etc/os-release').read_text().splitlines():
            if '=' in line:
                k, v = line.split('=', 1); release[k] = v.strip('"\'')
    except OSError: pass
    system = platform.system(); profile = os_profile(system, release)
    rows = []; notes = []
    def add(identifier, profile, root='', evidence='', ready=True):
        rows.append(dict(Id=identifier, Profile=profile, Root=root, Evidence=evidence,
                         Ready=ready, RunAs='', Bash=shutil.which('bash') or '/bin/bash',
                         Python=shutil.which('python3') or '/usr/bin/python3',
                         DbHost='localhost', DbPort={'mysql':3306,'postgresql':5432,'oracle':1521,'mssql':1433}.get(profile,3306),
                         DbUser='', DbPassword='', DbName=''))
    if profile: add('os', profile, evidence=system+' '+release.get('PRETTY_NAME',''))
    else: notes.append('지원 OS를 판별하지 못했습니다. 수동 점검 구성을 확인하세요: '+system)
    # Use process names only: command-line arguments may contain application secrets.
    try:
        names = subprocess.check_output(['ps','-e','-o','comm='], text=True, timeout=15).lower()
    except (OSError, subprocess.SubprocessError): names = ''
    configs = {
        'apache':['/etc/apache2/apache2.conf','/etc/httpd/conf/httpd.conf','/usr/local/apache2/conf/httpd.conf'],
        'nginx':['/etc/nginx/nginx.conf','/usr/local/nginx/conf/nginx.conf'],
        'tomcat':['/etc/tomcat*/server.xml','/var/lib/tomcat*/conf/server.xml','/opt/tomcat*/conf/server.xml','/usr/share/tomcat*/conf/server.xml']}
    for service, patterns in configs.items():
        found = sorted({str(Path(p)) for pattern in patterns for p in glob.glob(pattern) if Path(p).is_file()})
        roots = set()
        for p in found:
            parent = Path(p).parent
            # /etc/apache2 and /etc/tomcat* are configuration roots, not install roots.
            # Keep the upstream default path search in those cases.
            root = str(parent.parent) if parent.name == 'conf' and not str(parent).startswith('/etc/') else ''
            if root in roots: continue
            roots.add(root); add(service+'-'+str(len(roots)),service,root,evidence=p)
        if not found and any(re.search(r'(^|\n)'+n+r'(\n|$)',names) for n in {'apache':['apache2','httpd'],'nginx':['nginx'],'tomcat':['tomcat']}[service]):
            add(service+'-1',service,evidence='프로세스 이름; 설치 범위 확인 필요',ready=False)
    for service, proc, executable in [('mysql',r'mysqld|mariadbd','mysql'),('postgresql',r'postgres','psql'),('oracle',r'ora_[a-z0-9_]+','sqlplus'),('mssql',r'sqlservr','sqlcmd')]:
        if re.search(r'(^|\n)('+proc+r')(\n|$)',names):
            add(service+'-1',service,evidence='실행 프로세스; DB 접속 정보 입력 필요',ready=False)
            if not shutil.which(executable): notes.append(service+': 대상의 '+executable+' 클라이언트 경로 확인 필요')
    for name in ('wildfly','jboss','weblogic','jetty','httpd2','db2sysc','mongod','redis-server'):
        if re.search(r'(^|\n)'+re.escape(name)+r'(\n|$)',names): notes.append(name+': 원본 KISA 저장소에 해당 제품 점검 프로필이 없습니다.')
    notes.append('표준 경로·프로세스 기반 후보 탐지입니다. 별도 경로, 컨테이너, 중지 서비스는 수동 등록이 필요할 수 있습니다.')
    return dict(System=system, Platform={'unix-debian':'Debian','unix-redhat':'RedHat','unix-aix':'AIX','unix-hpux':'HP-UX','unix-solaris':'Solaris'}.get(profile,''), Candidates=rows, Notes=notes)


if __name__ == '__main__': print(json.dumps(discover(),ensure_ascii=False))
