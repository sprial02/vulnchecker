import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('target_runtime',ROOT/'plugins/filter/target_runtime.py')
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)


class TargetRuntimeTests(unittest.TestCase):
    def probe(self,body,prefix='',suffix=''):
        return prefix+'\n'+runtime.BEGIN+'\n'+body+'\n'+runtime.END+'\n'+suffix

    def test_python36_and_pam_banner_report_both_causes(self):
        value=runtime.parse_target_runtime(self.probe('PYTHON|/usr/bin/python3|3.6.8',prefix='PAM hook: sshd'))
        self.assertFalse(value['ready'])
        self.assertEqual(value['python'],'')
        self.assertEqual(len(value['errors']),2)
        self.assertIn('3.6.8',value['errors'][0])

    def test_existing_compatible_python_selected_without_install(self):
        value=runtime.parse_target_runtime(self.probe('PYTHON|/usr/bin/python3|3.6.8\nPYTHON|/usr/bin/python3.9|3.9.20'))
        self.assertTrue(value['ready'])
        self.assertEqual(value['python'],'/usr/bin/python3.9')

    def test_pinned_supported_interpreter_retained(self):
        value=runtime.parse_target_runtime(self.probe('PYTHON|/opt/audit/bin/python3|3.11.9\nPYTHON|/usr/bin/python3.13|3.13.2'))
        self.assertEqual(value['python'],'/opt/audit/bin/python3')

    def test_stderr_warning_not_in_stdout_has_no_false_failure(self):
        value=runtime.parse_target_runtime(self.probe('PYTHON|/usr/bin/python3|3.9.20'))
        self.assertFalse(value['stdout_polluted'])
        self.assertTrue(value['ready'])

    def test_invalid_and_duplicate_markers_rejected(self):
        for text in ('connection closed',self.probe('')+runtime.END):
            with self.assertRaises(ValueError):runtime.parse_target_runtime(text)


if __name__=='__main__':unittest.main()
