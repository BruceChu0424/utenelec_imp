"""Mapping and shell bytes are reviewed frozen execution authorities."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import rehearse_local_import as importer


class FrozenExecutionAuthorityTest(unittest.TestCase):
    def fixture(self,root):
        legacy=root/'server/legacy_migration';legacy.mkdir(parents=True)
        migrations=root/'server/src/main/resources/db/migration';migrations.mkdir(parents=True)
        for name in ('mapping-version.txt','migrate.sh','export_legacy.ps1','export_rehearsal_reference_audit.ps1',
                     'export_legacy_goods_media.ps1','warehouse_crosswalk.csv',
                     'source_schema_contract.json','source_profile_contract.json','export_source_completeness_audit.ps1'):
            (legacy/name).write_text('bootstrap-v16\n' if name=='mapping-version.txt' else 'fixture\n',encoding='utf-8')
        for n in range(125): (legacy/f'fixture_{n:03d}.py').write_text('pass\n')
        (migrations/'V1__fixture.sql').write_text('SELECT 1;\n')
        return legacy

    def frozen(self,root,legacy,dirty=None,untracked=None):
        calls=[]
        def tracked(args,**kwargs):
            paths=args[args.index('--')+1:];calls.append(paths)
            if untracked in paths: raise subprocess.CalledProcessError(1,args)
            return subprocess.CompletedProcess(args,0)
        def read(args,**kwargs):
            if 'status' in args:
                paths=args[args.index('--')+1:]
                return ' M '+dirty+'\n' if dirty in paths else ''
            return 'a'*40+'\n'
        with patch.object(importer,'ROOT',root),patch.object(importer,'HERE',legacy), \
             patch.object(importer.subprocess,'run',side_effect=tracked),patch.object(importer.subprocess,'check_output',side_effect=read):
            commit=importer.verify_frozen_source()
        return commit,calls

    def test_clean_tracked_authorities_and_windows_safe_sixty_path_batches(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);legacy=self.fixture(root)
            commit,batches=self.frozen(root,legacy)
            self.assertEqual(commit,'a'*40)
            self.assertTrue(all(0<len(batch)<=60 for batch in batches))
            controlled={name for batch in batches for name in batch}
            self.assertIn('server/legacy_migration/mapping-version.txt',controlled)
            self.assertIn('server/legacy_migration/migrate.sh',controlled)

    def test_dirty_mapping_or_shell_is_rejected(self):
        for name in ('mapping-version.txt','migrate.sh'):
            with self.subTest(name=name),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);legacy=self.fixture(root)
                with self.assertRaisesRegex(ValueError,'uncommitted bytes'):
                    self.frozen(root,legacy,dirty='server/legacy_migration/'+name)

    def test_untracked_mapping_or_shell_is_rejected(self):
        for name in ('mapping-version.txt','migrate.sh'):
            with self.subTest(name=name),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);legacy=self.fixture(root)
                with self.assertRaises(subprocess.CalledProcessError):
                    self.frozen(root,legacy,untracked='server/legacy_migration/'+name)

    def test_prepared_manifest_binds_mapping_and_shell_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);legacy=self.fixture(root)
            paths={name:root/name for name in ('raw','clean','overlay','hr','excel','reference','masters','completeness')}
            for path in paths.values():path.mkdir()
            (paths['raw']/'export_manifest.json').write_text('{}')
            (paths['clean']/'clean_master_manifest.json').write_text('{"outputs":[]}')
            (paths['overlay']/'goods_excel_manifest.json').write_text('{"outputs":[{"file":"goods_owning_warehouse.csv"}]}')
            for folder,name,data in (
                ('clean','warehouse_crosswalk.csv','legacy_id|action\n'),
                ('overlay','goods_owning_warehouse.csv','goods_legacy_id|warehouse_code\n'),
                ('overlay','goods_excel_attributes.sql','SELECT 1;\n'),
                ('hr','hr_rehearsal.csv','emp_code|status\n'),('hr','hr_managers.csv','employee_code\n'),
                ('reference','legacy_injection_machines.csv','legacy_id\n')):
                (paths[folder]/name).write_text(data)
            raw={'files':[],'sourceBackupSha256':'a'*64,'repositoryCommit':'b'*40,'sourceSnapshotAsOfUtc':'2026-07-24T01:28:50Z'}
            audit={'database_updateability':'READ_ONLY','source_export_manifest_sha256':importer.digest(paths['raw']/'export_manifest.json'),
                   'source_backup_sha256':'a'*64}
            (paths['reference']/'source_table_audit_summary.json').write_text(json.dumps(audit))
            with patch.object(importer,'HERE',legacy),patch.object(importer,'verify_frozen_source',return_value='c'*40), \
                 patch.object(importer,'verify_raw',return_value=raw),patch.object(importer,'verify_layers'), \
                 patch.object(importer,'verify_reference_masters',return_value={'outputs':[]}), \
                 patch.object(importer,'validate_execution_inputs',return_value={'valid':True}), \
                 patch.object(importer.validate_source_table_coverage,'validate_source_table_coverage',return_value={'fixture':'tables'}) as table_gate, \
                 patch.object(importer.validate_source_completeness,'validate_source_completeness',return_value={'fixture':'completeness'}) as completeness_gate:
                manifest=importer.prepare_inputs(paths['raw'],paths['clean'],paths['overlay'],paths['hr'],root/'out',
                    paths['excel'],paths['reference'],root/'people.xls',paths['masters'],
                    completeness_audit=paths['completeness'])
            table_gate.assert_called_once_with(paths['reference'],paths['raw']/'export_manifest.json')
            completeness_gate.assert_called_once_with(paths['completeness'],paths['raw']/'export_manifest.json',
                paths['reference'],legacy/'source_schema_contract.json',legacy/'source_profile_contract.json',
                legacy/'export_source_completeness_audit.ps1')
            self.assertEqual(manifest['provenance']['sourceTableCoverage'],{'fixture':'tables'})
            self.assertEqual(manifest['provenance']['sourceCompleteness']['proof'],{'fixture':'completeness'})
            for name in ('mapping-version.txt','migrate.sh','source_schema_contract.json',
                         'source_profile_contract.json','export_source_completeness_audit.ps1'):
                self.assertEqual(manifest['provenance']['scripts'][name],importer.digest(legacy/name))


if __name__=='__main__':unittest.main()
