import importlib.util
import json
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('configure_ai', pathlib.Path(__file__).resolve().parents[1] / 'scripts/configure-ai.py')
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)


class AiConfigTest(unittest.TestCase):
    def test_merge_switch_remove_and_invalid_input(self):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / 'opencode.json'
            keys = pathlib.Path(root) / 'keys'
            original = {'mcp': {'hexstrike': {'enabled': True}}, 'permission': 'ask', 'provider': {'other': {'name': 'keep'}}}
            path.write_text(json.dumps(original), encoding='utf-8')
            data = {'model': 'ibm-ica/gemini-3.1-pro-preview', 'ibmKey': 'fixture-ibm-secret', 'deepseekKey': 'fixture-ds-secret'}
            ai.configure(path, keys, data)
            config = json.loads(path.read_text())
            self.assertEqual(config['mcp'], original['mcp'])
            self.assertEqual(config['provider']['other'], original['provider']['other'])
            self.assertEqual(set(config['provider']['ibm-ica']['models']), set(ai.ICA_MODELS))
            self.assertIn('deepseek-v4-flash', config['provider']['deepseek']['models'])
            self.assertIn('deepseek-v4-flash', config['provider']['deepseek']['whitelist'])
            self.assertEqual(config['model'], data['model'])
            self.assertEqual(config['small_model'], data['model'])
            self.assertEqual((keys / 'ibm-ica.key').read_text(), data['ibmKey'])
            for file in pathlib.Path(root).glob('opencode*'):
                self.assertNotIn(data['ibmKey'], file.read_text())
                self.assertNotIn(data['deepseekKey'], file.read_text())
            backups = len(list(path.parent.glob('*.backup-*')))
            ai.configure(path, keys, data)
            self.assertEqual(len(list(path.parent.glob('*.backup-*'))), backups)
            before = path.read_bytes()
            with self.assertRaises(ValueError):
                ai.configure(path, keys, {**data, 'model': 'unknown'})
            self.assertEqual(path.read_bytes(), before)
            with self.assertRaises(ValueError):
                ai.configure(path, keys, {**data, 'ibmKey': ''})
            data.update(model='deepseek/deepseek-v4-flash', ibmKey='')
            ai.configure(path, keys, data)
            config = json.loads(path.read_text())
            self.assertEqual(config['model'], data['model'])
            self.assertNotIn('ibm-ica', config['provider'])
            self.assertFalse((keys / 'ibm-ica.key').exists())


if __name__ == '__main__':
    unittest.main()
