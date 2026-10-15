"""Regression for U-64 zero-match/pipefail using fake apt, never a customer host."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from source_compat import adapt,U64_PATH
import run

MINIMAL='''#!/bin/bash
set -euo pipefail
kernel_version=QA
package_updates=0
security_updates=0
local_check() {
    local update_list=$(apt list --upgradable 2>/dev/null | grep -v "^Listing")
    if [ -n "$update_list" ]; then
        package_updates=$(echo "$update_list" | wc -l)
        security_updates=$(echo "$update_list" | grep -i "security" | wc -l)
    fi
    raw_output=$(echo "=== Kernel Version ===" && uname -r && echo -e "\\n=== Upgradable Packages ===" && apt list --upgradable 2>/dev/null | head -20)
    echo "complete:$package_updates:$security_updates"
}
local_check
'''

class CompatibilityTests(unittest.TestCase):
    def test_unknown_source_rejected_and_other_files_untouched(self):
        with self.assertRaises(ValueError):adapt(U64_PATH,b'# altered source')
        self.assertEqual(adapt('lib/common.sh',b'original'),(b'original',None))
    def test_bundle_records_changes_without_modifying_vendor(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source=root/'vendor';path=source/U64_PATH;path.parent.mkdir(parents=True);path.write_text(MINIMAL,encoding='utf-8');before=path.read_bytes()
            out=root/'run';out.mkdir();changes=run.bundles(source,out)
            self.assertEqual(path.read_bytes(),before);self.assertEqual(len(changes),1)
            with tarfile.open(out/'source.tar.gz') as t:
                self.assertIn(b'awk',t.extractfile(U64_PATH).read())
                audit=json.load(t.extractfile('source-compatibility.json'))
            self.assertNotEqual(audit['adaptations'][0]['original_sha256'],audit['adaptations'][0]['effective_sha256'])
    @unittest.skipUnless(os.name=='posix','Bash regression runs in Kali')
    def test_empty_nonsecurity_and_security_lists(self):
        self.assertNotEqual(self.execute(MINIMAL,'pkg/stable 1.2 amd64 [upgradable from: 1.1]\n').returncode,0)
        fixed,_=adapt(U64_PATH,MINIMAL.encode())
        for content,expected in [('', 'complete:0:0'),('pkg/stable 1.2 amd64\n','complete:1:0'),('pkg/security 1.2 amd64\n','complete:1:1')]:
            result=self.execute(fixed.decode(),content);self.assertEqual(result.returncode,0,result.stderr);self.assertIn(expected,result.stdout)
    @unittest.skipUnless(os.name=='posix','Bash regression runs in Kali')
    def test_long_output_and_actual_apt_failure(self):
        fixed,_=adapt(U64_PATH,MINIMAL.encode())
        result=self.execute(fixed.decode(),'pkg/security 1.2 amd64\n'*12000);self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('complete:12000:12000',result.stdout)
        result=self.execute(fixed.decode(),'unavailable',100);self.assertNotEqual(result.returncode,0);self.assertIn('apt 조회 실패',result.stderr)
    @unittest.skipUnless(os.name=='posix' and os.environ.get('U64_TEST_SOURCE'),'Pinned upstream integration source required')
    def test_full_pinned_script_no_match_reproduction_and_fix(self):
        original=Path(os.environ['U64_TEST_SOURCE']).read_text()
        self.assertNotEqual(self.execute(original,'pkg/stable 1.2 amd64\n',full=True).returncode,0)
        fixed,_=adapt(U64_PATH,original.encode())
        for content in ('pkg/stable 1.2 amd64\n','', 'pkg/security 1.2 amd64\n'):
            result=self.execute(fixed.decode(),content,full=True);self.assertEqual(result.returncode,0,result.stderr);self.assertIn('saved:U-64:',result.stdout)
    def execute(self,script,apt_text,apt_rc=0,full=False):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'01.Unix서버/Debian';folder.mkdir(parents=True);lib=root/'lib';lib.mkdir();bin=root/'bin';bin.mkdir()
            (root/'apt-data').write_text('Listing...\n'+apt_text)
            apt=bin/'apt';apt.write_text('#!/usr/bin/env python3\nimport os,sys\nsys.stdout.write(open(os.environ["APT_FIXTURE"]).read());sys.exit(int(os.environ["APT_FIXTURE_RC"]))\n');apt.chmod(0o700)
            for name in ('command_validator.sh','timeout_handler.sh','output_mode.sh','metadata_parser.sh'):(lib/name).write_text('')
            (lib/'common.sh').write_text('show_diagnosis_start() { :; }\nshow_diagnosis_complete() { :; }\ncheck_disk_space() { :; }\n')
            (lib/'result_manager.sh').write_text('save_dual_result() { printf "saved:%s:%s\\n" "$1" "$4"; }\nverify_result_saved() { :; }\n')
            path=folder/'U64_check.sh';path.write_text(script)
            return subprocess.run(['/bin/bash',str(path)],cwd=folder,env={**os.environ,'PATH':str(bin)+':'+os.environ['PATH'],'APT_FIXTURE':str(root/'apt-data'),'APT_FIXTURE_RC':str(apt_rc)},capture_output=True,text=True,timeout=20)

if __name__=='__main__':unittest.main(verbosity=2)
