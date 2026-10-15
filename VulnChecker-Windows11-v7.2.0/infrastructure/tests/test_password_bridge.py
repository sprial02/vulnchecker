import importlib.util
import json
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch
import yaml

path=Path(__file__).resolve().parents[1]/'scripts/gui-bridge.py'
sys.path.insert(0,str(path.parent))
spec=importlib.util.spec_from_file_location('bridge',path);bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)

class PasswordBridge(unittest.TestCase):
    def test_windows_http_keeps_ntlm_message_encryption(self):
        for connection in ('winrm','psrp'):
            with tempfile.TemporaryDirectory() as tmp:
                row={'Alias':'fixture','Host':'192.0.2.10','Port':5985,'Connection':connection,'User':'audit','Password':'TEST_ONLY_PASSWORD','Timeout':90,'Platform':'Windows','Enabled':True,'Protocol':'http'}
                with patch.object(bridge,'GUI',Path(tmp)/'gui'):
                    bridge.sync([row])
                variables=yaml.safe_load((Path(tmp)/'gui/hosts.yml').read_text())['all']['children']['windows']['hosts']['fixture']
                self.assertEqual(variables['ansible_'+connection+'_message_encryption'],'always')
                self.assertEqual(variables['ansible_winrm_scheme' if connection=='winrm' else 'ansible_psrp_protocol'],'http')
                self.assertEqual(variables['ansible_winrm_server_cert_validation' if connection=='winrm' else 'ansible_psrp_cert_validation'],'validate')
    def test_partial_discovery_retains_healthy_and_marks_failed_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            gui=Path(tmp)/'gui';gui.mkdir()
            servers=[{'Alias':name,'Host':'192.0.2.1','Connection':'ssh'} for name in ('bad','healthy')]
            def sync_fixture(*args,**kwargs):
                (gui/'hosts.yml').write_text(yaml.safe_dump({'all':{'children':{'linux':{'hosts':{'bad':{},'healthy':{}}},'windows':{'hosts':{}}}}}))
            def execute(command,env,groups,directory,size):
                (directory/'healthy.json').write_text(json.dumps({'Platform':'Debian','Candidates':[],'Notes':[]}))
                Path(env['INFRA_STATUS_PATH']).write_text(json.dumps({'bad':{'diagnostics':[{'code':'TIMEOUT','task':'discover','reason':'timeout','action':'check network'}]}}))
                return 2
            with patch.object(bridge,'GUI',gui),patch.object(bridge,'sync',side_effect=sync_fixture),patch.object(bridge,'execute_batches',side_effect=execute):
                found=bridge.discover_servers(servers,[],{'Output':str(Path(tmp)/'out')},allow_partial=True)
            self.assertIn('healthy',found)
            self.assertNotIn('bad',found)
            self.assertTrue(servers[0]['SkipReason'])
            self.assertEqual(servers[0]['PrecheckFailure'][0]['code'],'TIMEOUT')
            self.assertNotIn('SkipReason',servers[1])

    def test_password_first_contact_uses_no_login_key_or_probe(self):
        with tempfile.TemporaryDirectory(prefix='vc password ') as tmp:
            gui=Path(tmp)/'gui'
            row={'Alias':'fixture','Host':'192.0.2.1','Port':22,'Connection':'ssh','User':'audit','Password':'TEST_ONLY_PASSWORD','BecomePassword':'','KeyFile':'','Timeout':90,'Platform':'Debian','Enabled':True,'TrustNewHostKey':False}
            with patch.object(bridge,'GUI',gui),patch.object(bridge.subprocess,'run') as network:
                bridge.sync([row]);network.assert_not_called()
            values=yaml.safe_load((gui/'hosts.yml').read_text())['all']['children']['linux']['hosts']['fixture']
            args=shlex.split(values['ansible_ssh_common_args'])
            self.assertIn('StrictHostKeyChecking=accept-new',args);self.assertIn('PubkeyAuthentication=no',args)
            self.assertIn('UserKnownHostsFile='+str(gui/'known_hosts'),args)
            self.assertNotIn('ansible_ssh_private_key_file',values);self.assertEqual(values['ansible_ssh_password_mechanism'],'sshpass')
            self.assertIn('ansible_password',values);self.assertNotIn('TEST_ONLY_PASSWORD',(gui/'hosts.yml').read_text())
            secret=bridge.vault((gui/'.vault-password').read_text()).decrypt((gui/'group_vars/all/vault.yml').read_bytes())
            self.assertIn(b'TEST_ONLY_PASSWORD',secret)
            self.assertNotIn('StrictHostKeyChecking=no',values['ansible_ssh_common_args'])
    def test_explicit_key_remains_supported(self):
        with tempfile.TemporaryDirectory() as tmp:
            key=Path(tmp)/'private-key';key.write_text('TEST FIXTURE')
            row={'Alias':'fixture','Host':'192.0.2.1','Port':2222,'Connection':'ssh','User':'root','Password':'','KeyFile':str(key),'Timeout':90,'Platform':'Debian','Enabled':True}
            with patch.object(bridge,'GUI',Path(tmp)/'gui'):bridge.sync([row])
            values=yaml.safe_load((Path(tmp)/'gui/hosts.yml').read_text())['all']['children']['linux']['hosts']['fixture']
            self.assertEqual(values['ansible_ssh_private_key_file'],str(key));self.assertNotIn('PubkeyAuthentication=no',values['ansible_ssh_common_args'])

if __name__=='__main__':unittest.main(verbosity=2)
