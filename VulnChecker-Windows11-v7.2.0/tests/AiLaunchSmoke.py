import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('launcher', Path(__file__).resolve().parents[1] / 'scripts/launch-opencode.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class LauncherTest(unittest.TestCase):
    def test_environment_and_model_overrides(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / 'secret.key'
            key.write_text('fixture-secret', encoding='utf-8')
            config = root / 'opencode.json'
            config.write_text(json.dumps({'model': 'ibm-ica/claude-sonnet-5', 'provider': {'ibm-ica': {'options': {'apiKey': '{file:' + key.as_posix() + '}'}}}}))
            inherited = {'OPENCODE_CONFIG_CONTENT': json.dumps({'provider': {'other': {}}, 'model': 'other/old'})}
            env, args = launcher.prepare(config, ['--continue'], inherited)
            self.assertEqual(env['IBM_ICA_API_KEY'], 'fixture-secret')
            self.assertEqual(args, ['--model', 'ibm-ica/claude-sonnet-5', '--continue'])
            self.assertNotIn('fixture-secret', env['OPENCODE_CONFIG_CONTENT'])
            self.assertNotIn('fixture-secret', str(args))
            overlay = json.loads(env['OPENCODE_CONFIG_CONTENT'])
            self.assertEqual(overlay['provider']['ibm-ica']['options']['apiKey'], '{env:IBM_ICA_API_KEY}')
            self.assertIn('other', overlay['provider'])
            self.assertNotIn('IBM_ICA_API_KEY', inherited)
            _, args = launcher.prepare(config, ['--model', 'deepseek/deepseek-flash'], {})
            self.assertEqual(args, ['--model', 'deepseek/deepseek-flash'])
            key.write_text('')
            with self.assertRaises(ValueError):
                launcher.prepare(config, [], {})


if __name__ == '__main__':
    unittest.main()
