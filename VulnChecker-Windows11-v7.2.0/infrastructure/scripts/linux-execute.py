"""Run each original check in a separate process, preserving its output and rc."""
import argparse
import json
from pathlib import Path
import subprocess
import os
import signal
import sys
import re
from profiles import CATALOG

def instance_env(config):
    env={**os.environ,'LC_ALL':'C.UTF-8'}
    if config.get('Root'):
        env['TRIGUARD_INSTANCE_ROOT']=config['Root'];env['ORACLE_HOME']=config['Root'];env['PGDATA']=config['Root'];env['PATH']=config['Root']+'/bin:'+env.get('PATH','')
    if config.get('DbUser'):
        host=str(config.get('DbHost','localhost'));port=str(config['DbPort']);user=config['DbUser'];password=config['DbPassword'];name=config.get('DbName','')
        env.update(DB_HOST=host,DB_PORT=port,DB_USER=user,DB_PASSWORD=password,DB_ADMIN_USER=user,DB_ADMIN_PASS=password,
          DBMS_HOST=host,DBMS_PORT=port,DBMS_USER=user,DBMS_PASSWORD=password,DBMS_DATABASE=name,DBMS_SID=name or 'ORCL',
          MYSQL_PWD=password,PGHOST=host,PGPORT=port,PGUSER=user,PGPASSWORD=password,PGDATABASE=name or 'postgres',
          ORACLE_HOST=host,ORACLE_PORT=port,ORACLE_USER=user,ORACLE_PASSWORD=password,ORACLE_SID=name or 'ORCL')
    return env

def scoped_web_script(text,profile,root):
    if not root:return text
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+',root):raise ValueError('Invalid instance root')
    replacements={
      'tomcat':{'/etc/tomcat*':root+'/conf','/var/lib/tomcat*/conf':root+'/conf','/usr/share/tomcat*/conf':root+'/conf',
       '/var/lib/tomcat*/webapps':root+'/webapps','/usr/share/tomcat*/webapps':root+'/webapps','/opt/tomcat/webapps':root+'/webapps',
       '/usr/share/tomcat*/logs':root+'/logs','/var/log/tomcat*':root+'/logs','/opt/tomcat/logs':root+'/logs'},
      'nginx':{'/etc/nginx':root+'/conf','/usr/local/nginx/conf':root+'/conf','/usr/local/nginx/logs':root+'/logs','/var/log/nginx':root+'/logs','/usr/share/nginx/html':root+'/html','/var/www/html':root+'/html','/var/www':root+'/html'},
      'apache':{'/etc/apache2/apache2.conf':root+'/conf/httpd.conf','/etc/apache2':root+'/conf','/etc/httpd/conf/httpd.conf':root+'/conf/httpd.conf','/etc/httpd/conf.d':root+'/conf/extra','/usr/local/apache2/conf/httpd.conf':root+'/conf/httpd.conf','/usr/local/apache2/htdocs':root+'/htdocs','/etc/httpd/logs':root+'/logs','/var/log/apache2':root+'/logs','/var/log/httpd':root+'/logs','/var/www/html':root+'/htdocs','/var/www':root+'/htdocs','/srv/www':root+'/htdocs'}}.get(profile,{})
    # Use one regex pass: replacements must not recursively rewrite their own roots.
    if replacements:
        expression='|'.join(re.escape(k) for k in sorted(replacements,key=len,reverse=True))
        text=re.sub(expression,lambda m:replacements[m.group()],text)
    return text

def redact(root,config,instance):
    password=config.get('DbPassword','')
    if password:
        def clean(value,key=''):
            if key in ('item_id','final_result','diagnosis_result','rc','importance','severity'):return value
            if isinstance(value,str):return value.replace(password,'[REDACTED]')
            if isinstance(value,list):return [clean(v) for v in value]
            if isinstance(value,dict):return {k:clean(v,k) for k,v in value.items()}
            return value
        for file in root.rglob('*'):
            if file.is_symlink():continue
            try:file.resolve().relative_to(root.resolve())
            except ValueError:continue
            if file.is_file() and file.suffix in ('.json','.txt','.log') and file!=instance:
                if file.name in ('execution.json','source-compatibility.json'):continue
                data=file.read_bytes()
                if file.suffix=='.json':
                    try:
                        value=json.loads(data.decode('utf-8-sig'))
                        file.write_text(json.dumps(clean(value),ensure_ascii=False),encoding='utf-8');continue
                    except (UnicodeError,ValueError):pass
                for pattern in {password.encode(),json.dumps(password,ensure_ascii=False)[1:-1].encode(),json.dumps(password,ensure_ascii=True)[1:-1].encode()}:
                    data=data.replace(pattern,b'[REDACTED]')
                file.write_bytes(data)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('root', type=Path)
    p.add_argument('platform')
    p.add_argument('timeout', type=int)
    p.add_argument('--instance',type=Path)
    p.add_argument('--redact-only',action='store_true')
    a = p.parse_args()
    os.umask(0o077)
    config=json.loads(a.instance.read_text(encoding='utf-8')) if a.instance else {}
    if a.redact_only:
        redact(a.root,config,a.instance);return
    profile_id=config.get('Profile') or {'Debian':'unix-debian','RedHat':'unix-redhat'}.get(a.platform,a.platform)
    profile=CATALOG[profile_id]
    if profile['Family']!='posix':raise ValueError('POSIX profile required')
    folder = a.root / profile['Folder']
    logs = a.root / 'execution-logs'
    logs.mkdir(exist_ok=True)
    records = []
    consecutive_timeouts = 0
    environment=instance_env(config)
    if config.get('Root') and not Path(config['Root']).is_dir():raise ValueError('선택한 설치 경로가 대상 서버에 없습니다.')
    client={'mysql':'mysql','postgresql':'psql','oracle':'sqlplus','mssql':'sqlcmd'}.get(profile_id)
    import shutil
    missing_client=client and not shutil.which(client,path=environment.get('PATH'))
    for n in range(1, profile['Count']+1):
        item = f"{profile['Prefix']}-{n:02d}"
        if consecutive_timeouts >= 3:
            records.append({'item_id': item, 'rc': 125, 'reason': 'Skipped after 3 consecutive item timeouts'})
            (a.root / 'execution.json').write_text(json.dumps(records), encoding='utf-8')
            continue
        if os.environ.get('TRIGUARD_PROGRESS'):
            print(f'[{n}/{profile["Count"]}] {item} (limit {a.timeout}s)', flush=True)
        script = folder / f"{profile['Prefix']}{n:02d}_check.sh"
        if config.get('Root') and profile['Category']=='Web':script.write_text(scoped_web_script(script.read_text(encoding='utf-8'),profile_id,config['Root']),encoding='utf-8')
        with (logs / f'{item}.log').open('wb') as out:
            try:
                if missing_client:raise OSError('대상 서버에 DB 점검 클라이언트가 없습니다: '+client)
                process = subprocess.Popen([config.get('Bash','/bin/bash'), str(script)], cwd=folder,
                                        stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                        start_new_session=True, env=environment)
                rc = process.wait(timeout=a.timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                rc = 124
            except OSError as e:
                out.write(str(e).encode())
                rc = 127
        if os.environ.get('TRIGUARD_PROGRESS'):
            print(f'{item}: exit {rc}', flush=True)
        records.append({'item_id': item, 'rc': rc})
        consecutive_timeouts = consecutive_timeouts + 1 if rc == 124 else 0
        (a.root / 'execution.json').write_text(json.dumps(records), encoding='utf-8')
        redact(a.root,config,a.instance)
    redact(a.root,config,a.instance)

if __name__ == '__main__':
    main()
