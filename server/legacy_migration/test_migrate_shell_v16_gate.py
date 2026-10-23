"""Stubbed legacy All-entry rejection: no Docker, key, claim or data access."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


def bash_executable():
    if os.name=='nt':
        git=shutil.which('git')
        if git:
            root=Path(git).parent.parent
            for relative in ('bin/bash.exe','usr/bin/bash.exe'):
                if (root/relative).is_file():return str(root/relative)
        return None  # Do not silently invoke Windows' WSL launcher.
    return shutil.which('bash')


class LegacyShellAllGateTest(unittest.TestCase):
    def invoke(self,target,version='bootstrap-v16',confirm=False,bom=False):
        bash=bash_executable()
        if not bash:self.skipTest('Bash is unavailable')
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            script=root/'migrate.sh'
            script.write_bytes(Path(__file__).with_name('migrate.sh').read_bytes())
            if version is not None:
                (root/'mapping-version.txt').write_text(version+'\n',encoding='utf-8-sig' if bom else 'utf-8')
            marker=root/'forbidden-runtime-calls.txt'
            stub=root/'forbidden-runtime.sh'
            stub.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "runtime-called" >> "$STUB_CALL_MARKER"\nexit 71\n',encoding='utf-8')
            stub.chmod(0o755)
            env=os.environ.copy()
            env.update(DOCKER=stub.as_posix(),STUB_CALL_MARKER=marker.as_posix(),PG_DB='synthetic_unreachable',PG_CONTAINER='synthetic_unreachable')
            env.pop('UTEN_CONFIRM_DESTRUCTIVE_MIGRATION',None)
            args=[bash,script.as_posix(),target]+(['--confirm-destructive'] if confirm else [])
            result=subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
            self.assertFalse(marker.exists(),'Legacy rejection must precede every Docker invocation')
            self.assertFalse((root/'data').exists(),'No input/claim directory may be generated')
            return result.returncode,result.stderr.decode('utf-8',errors='replace')

    def test_all_aliases_reject_v16_before_any_runtime_even_without_confirmation(self):
        for target in ('--bootstrap-all','--all','-a'):
            for confirm in (False,True):
                with self.subTest(target=target,confirm=confirm):
                    code,error=self.invoke(target,confirm=confirm)
                    self.assertEqual(code,64);self.assertIn('rehearse_local_import.py',error)

    def test_newer_or_very_large_mapping_versions_fail_closed(self):
        for version in ('bootstrap-v17','bootstrap-v100','bootstrap-v'+'9'*100):
            with self.subTest(version=version[:20]):
                code,error=self.invoke('--all',version,True)
                self.assertEqual(code,64);self.assertIn('rehearse_local_import.py',error)

    def test_utf8_bom_and_windows_newline_authority_are_supported(self):
        code,error=self.invoke('-a','bootstrap-v16',True,bom=True)
        self.assertEqual(code,64);self.assertIn('rehearse_local_import.py',error)

    def test_missing_or_invalid_mapping_rejects_before_runtime(self):
        for version in (None,'','bootstrap-v0','bootstrap-v16\nbootstrap-v15','bootstrap-v16;echo anything'):
            with self.subTest(version=version):
                code,_=self.invoke('--bootstrap-all',version,True)
                self.assertEqual(code,64)

    def test_v15_all_still_uses_original_confirmation_rule(self):
        code,error=self.invoke('--all','bootstrap-v15')
        self.assertEqual(code,65);self.assertNotIn('旧 shell All 入口已关闭',error)

    def test_v16_single_module_confirmation_behavior_is_unchanged(self):
        code,error=self.invoke('--goods','bootstrap-v16')
        self.assertEqual(code,65);self.assertNotIn('旧 shell All 入口已关闭',error)


if __name__=='__main__':unittest.main()
