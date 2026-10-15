"""Profile selection, OS mapping, private credentials and instance isolation."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import subprocess
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from profiles import CATALOG, instances, expected

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

discovery=module('discovery','discover-target.py')
wrapper=module('wrapper','linux-execute.py')

class ProfileTests(unittest.TestCase):
    def test_all_625_allowlisted_items(self):
        self.assertEqual(sum(len(expected(p)) for p in CATALOG),625)
        self.assertEqual(len(CATALOG),15)

    def test_os_mapping_and_unknown_not_debian(self):
        self.assertEqual(discovery.os_profile('Linux',{'ID':'kali','ID_LIKE':'debian'}),'unix-debian')
        self.assertEqual(discovery.os_profile('Linux',{'ID':'rocky'}),'unix-redhat')
        for system,profile in [('AIX','unix-aix'),('HP-UX','unix-hpux'),('SunOS','unix-solaris')]:self.assertEqual(discovery.os_profile(system,{}),profile)
        self.assertIsNone(discovery.os_profile('Linux',{'ID':'arch'},lambda p:True))
        self.assertIsNone(discovery.os_profile('Darwin',{}))

    def test_same_host_distinct_profiles_and_credentials(self):
        server=dict(Alias='one',Connection='ssh',Platform='Debian',Profiles=[
            dict(Id='os',Profile='unix-debian'),dict(Id='was-prod',Profile='tomcat',Root='/opt/was-prod'),
            dict(Id='db-prod',Profile='mysql',DbHost='localhost',DbPort=3307,DbUser='audit',DbPassword='private')])
        self.assertEqual([p['Prefix'] for r,p in instances(server)],['U','WEB','D'])
        server['Profiles'][2]['DbPassword']=''
        with self.assertRaisesRegex(ValueError,'암호'):list(instances(server))
        server['Profiles']=[dict(Id='os',Profile='tomcat')]
        with self.assertRaises(ValueError):list(instances(server))

    def test_duplicate_scope_and_windows_bash_are_rejected(self):
        with self.assertRaises(ValueError):list(instances(dict(Alias='a',Connection='ssh',Platform='Debian',Profiles=[dict(Id='x',Profile='tomcat'),dict(Id='y',Profile='tomcat')])))
        with self.assertRaises(ValueError):list(instances(dict(Alias='a',Connection='winrm',Profiles=[dict(Id='db',Profile='mssql')])))

    def test_endpoint_environment_and_single_pass_paths(self):
        env=wrapper.instance_env(dict(DbUser='audit',DbPassword='private',DbHost='db.example',DbPort=5433,DbName='prod'))
        self.assertEqual((env['PGHOST'],env['PGPORT'],env['PGDATABASE']),('db.example','5433','prod'))
        text=wrapper.scoped_web_script('/etc/tomcat*/server.xml /opt/tomcat/webapps','tomcat','/opt/tomcat/production')
        self.assertEqual(text,'/opt/tomcat/production/conf/server.xml /opt/tomcat/production/webapps')

    def test_discovery_does_not_select_db_without_credentials(self):
        with patch.object(discovery.platform,'system',return_value='Linux'),patch.object(discovery.subprocess,'check_output',return_value='mysqld\npostgres\n'),patch.object(discovery.glob,'glob',return_value=[]):
            data=discovery.discover()
        db=[r for r in data['Candidates'] if r['Profile'] in ('mysql','postgresql')]
        self.assertEqual(len(db),2);self.assertTrue(all(not r['Ready'] and not r['DbPassword'] for r in db))

    def test_collected_secret_redaction(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);private=root/'instance.json';private.write_text('{"DbPassword":"private"}')
            log=root/'item.log';log.write_text('password private')
            wrapper.redact(root,{'DbPassword':'private'},private)
            self.assertEqual(log.read_text(),'password [REDACTED]');self.assertIn('private',private.read_text())
            result=root/'result.json';result.write_text(json.dumps({'item_id':'D-01','final_result':'GOOD','evidence':'password=1'}))
            manifest=root/'execution.json';manifest.write_text('[{"item_id":"D-01","rc":0}]')
            wrapper.redact(root,{'DbPassword':'1'},private)
            self.assertEqual(json.loads(result.read_text())['item_id'],'D-01')
            self.assertEqual(json.loads(result.read_text())['evidence'],'password=[REDACTED]')
            self.assertIn('D-01',manifest.read_text())

    @unittest.skipUnless(os.name=='posix','Bash wrapper requires POSIX')
    def test_selected_profile_only_and_db_endpoint_isolation(self):
        for profile in ('unix-debian','tomcat','mysql'):
            with self.subTest(profile=profile),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);spec=CATALOG[profile];scripts=root/spec['Folder'];scripts.mkdir(parents=True)
                config=dict(Id='fixture',Profile=profile,Root='',Bash='/bin/bash')
                if profile=='mysql':
                    (root/'bin').mkdir();client=root/'bin/mysql';client.write_text('#!/bin/sh\nexit 0\n');client.chmod(0o700)
                    config.update(Root=str(root),DbHost='db.example',DbPort=3307,DbUser='audit',DbPassword='private',DbName='prod')
                for n in range(1,spec['Count']+1):
                    script=scripts/f"{spec['Prefix']}{n:02d}_check.sh"
                    script.write_text('printf "%s" "$DB_HOST:$DB_PORT:$DB_USER:$DB_PASSWORD"\n' if profile=='mysql' else 'echo selected\n')
                private=root/'instance.json';private.write_text(json.dumps(config))
                result=subprocess.run([sys.executable,str(ROOT/'scripts/linux-execute.py'),str(root),'Debian','3','--instance',str(private)],capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                records=json.loads((root/'execution.json').read_text())
                self.assertEqual({r['item_id'] for r in records},expected(profile));self.assertTrue(all(r['rc']==0 for r in records))
                if profile=='mysql':self.assertEqual((root/'execution-logs/D-01.log').read_text(),'db.example:3307:audit:[REDACTED]')

    @unittest.skipUnless(os.name=='posix' and (ROOT/'.venv/bin/ansible-playbook').exists(),'Kali integration requires Ansible')
    def test_read_only_discovery_playbook_local_fixture(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);inventory=root/'inventory.yml'
            inventory.write_text('all:\n  children:\n    linux:\n      hosts:\n        fixture:\n          ansible_connection: local\n          ansible_become: false\n          ansible_python_interpreter: /usr/bin/python3\n')
            result=subprocess.run([str(ROOT/'.venv/bin/ansible-playbook'),'-i',str(inventory),'playbooks/discover.yml','-e',json.dumps({'discovery_dir':str(root)})],cwd=ROOT,env={**os.environ,'ANSIBLE_CONFIG':str(ROOT/'ansible.cfg')},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            data=json.loads((root/'fixture.json').read_text());self.assertEqual(data['Platform'],'Debian');self.assertTrue(any(r['Id']=='os' for r in data['Candidates']))


if __name__=='__main__':unittest.main()
