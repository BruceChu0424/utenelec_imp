import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import verify_candidate as verifier

REAL_ROOT = Path(__file__).resolve().parents[2]


class CandidateVersionIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'repo'
        self.legacy = self.root / 'server/legacy_migration'
        self.migrations = self.root / 'server/src/main/resources/db/migration'
        self.legacy.mkdir(parents=True);self.migrations.mkdir(parents=True)
        for name in ('migrate.sh', 'export_legacy.ps1', 'verify_candidate.py', 'reconcile_modules.py',
                     'compose_bootstrap.py', 'prepare_source_authority.py', 'prepare_hr_keys.py',
                     'cleanup_hr_keep_admin.sql', 'warehouse_crosswalk.csv', 'migrate_purchase.sql'):
            (self.legacy / name).write_text('# reviewed fixture source\n', encoding='utf-8')
        (self.legacy / 'mapping-version.txt').write_text('bootstrap-v22\n', encoding='ascii')
        shared = self.root / verifier.VERSION_CONTRACT_PATH
        shared.parent.mkdir(parents=True)
        shutil.copyfile(REAL_ROOT / verifier.VERSION_CONTRACT_PATH, shared)
        for name in ('V01__first.sql', 'V990_1__precision.sql', 'V999_1__one.sql',
                     'V999_10__ten.sql', 'V1070__head.sql'):
            (self.migrations / name).write_bytes(b'\xef\xbb\xbfSELECT 1;\r\n')
        self.manifest = Path(self.temporary.name) / 'checksums.tsv'

    def write_manifest(self):
        records = verifier.migration_inventory(self.root)
        text = verifier.CHECKSUM_HEADER + '\n' + ''.join(
            f'{version}\t{name}\t{checksum}\n' for version, name, checksum in records)
        self.manifest.write_text(text, encoding='utf-8', newline='\n')
        return records, text

    def test_compound_inventory_and_original_padded_filename_keep_distinct_identities(self):
        records, _ = self.write_manifest()
        self.assertEqual(['1','990.1','999.1','999.10','1070'], [r[0] for r in records])
        self.assertEqual('V01__first.sql', records[0][1])
        raw = verifier.history_projection(self.root, records)
        self.assertEqual(['01','990.1','999.1','999.10','1070'], [r[0] for r in raw])
        with patch.object(verifier, 'require_reviewed_files', return_value='a'*40) as authority:
            self.assertEqual((5,1070,'bootstrap-v22'), verifier.verify(self.root, self.manifest))
        self.assertIn(self.root / verifier.VERSION_CONTRACT_PATH, authority.call_args.args[1])
        self.assertIn(self.legacy / 'warehouse_crosswalk.csv', authority.call_args.args[1])

    def test_legacy_integer_tsv_and_header_are_byte_identical(self):
        for path in self.migrations.iterdir():path.unlink()
        for name in ('V01__first.sql','V09__ninth.sql','V1070__head.sql'):
            (self.migrations / name).write_bytes(b'SELECT 1;\r\n')
        records, actual = self.write_manifest()
        former = sorted((int(path.name.split('__')[0][1:]), path.name,
                         verifier.flyway_checksum(path.read_bytes())) for path in self.migrations.iterdir())
        expected = '# uten-imp-flyway-checksums-v1\n' + ''.join(f'{v}\t{n}\t{c}\n' for v,n,c in former)
        self.assertEqual(expected.encode('utf-8'), actual.encode('utf-8'))
        self.assertEqual(['1','9','1070'], [r[0] for r in records])

    def test_equivalent_dot_underscore_or_padded_integer_files_are_duplicates(self):
        for name in ('V999.10__alias.sql','V1__alias.sql'):
            with self.subTest(filename=name):
                path=self.migrations/name;path.write_text('SELECT 2;',encoding='utf-8')
                try:
                    with self.assertRaisesRegex(ValueError,'duplicate'):
                        verifier.migration_inventory(self.root)
                finally:path.unlink()

    def test_compound_alias_components_and_unregistered_sql_names_fail_closed(self):
        for name in ('V0999_10__alias.sql','V999_010__alias.sql','V999_10_0__alias.sql','R__repeatable.sql'):
            with self.subTest(filename=name):
                path=self.migrations/name;path.write_text('SELECT 2;',encoding='utf-8')
                try:
                    with self.assertRaises(ValueError):verifier.migration_inventory(self.root)
                finally:path.unlink()

    def test_source_manifest_reorder_omission_extra_version_and_checksum_drift_fail_closed(self):
        _, original = self.write_manifest();lines=original.splitlines()
        altered=[lines[:-1],lines+[lines[-1]],
                 [lines[0],lines[1],lines[3],lines[2],*lines[4:]],
                 [lines[0],lines[1].rsplit('\t',1)[0]+'\t123456789',*lines[2:]]]
        with patch.object(verifier,'require_reviewed_files',return_value='a'*40):
            for changed in altered:
                with self.subTest(lines=changed):
                    self.manifest.write_text('\n'.join(changed)+'\n',encoding='utf-8')
                    with self.assertRaisesRegex(ValueError,'exact reviewed source inventory'):
                        verifier.verify(self.root,self.manifest)

    def test_dirty_and_untracked_shared_authority_cannot_authorize_an_import(self):
        self.write_manifest()
        with patch.object(verifier.subprocess,'run'), \
                patch.object(verifier.subprocess,'check_output',return_value=' M deploy/updater/release_guard.py\n'):
            with self.assertRaisesRegex(ValueError,'uncommitted'):
                verifier.verify(self.root,self.manifest)
        with patch.object(verifier.subprocess,'run',side_effect=subprocess.CalledProcessError(1,['git','ls-files'])):
            with self.assertRaises(subprocess.SubprocessError):verifier.verify(self.root,self.manifest)

    def test_reviewed_git_files_use_bounded_batches_without_dropping_later_paths(self):
        directory=self.root/'reviewed';directory.mkdir()
        paths=[]
        for number in range(1121):
            path=directory/(f'{number:04d}_'+('reviewed_source_'*6)+'.txt');path.write_text('reviewed',encoding='utf-8');paths.append(path)
        def answer(command, **kwargs):return 'a'*40+'\n' if command[3]=='rev-parse' else ''
        with patch.object(verifier.subprocess,'run') as tracked, \
                patch.object(verifier.subprocess,'check_output',side_effect=answer):
            self.assertEqual('a'*40,verifier.require_reviewed_files(self.root,paths))
        batches=[call.args[0] for call in tracked.call_args_list]
        observed=[name for command in batches for name in command[6:]]
        self.assertEqual(sorted(path.relative_to(self.root).as_posix() for path in paths),observed)
        self.assertEqual(1121,len(observed));self.assertGreater(len(batches),1)
        for command in batches:
            self.assertLessEqual(len(command[6:]),60)
            self.assertLess(len(subprocess.list2cmdline(command)),30000)

    def test_shared_version_and_original_history_cases_use_the_same_source_fixture(self):
        fixture=json.loads((REAL_ROOT/'server/src/test/resources/contracts/flyway-version-identity-v1.json').read_text(encoding='utf-8'))
        contract=verifier.version_contract(self.root)
        for sample in fixture['validVersions']:
            self.assertEqual(tuple(sample['parts']),tuple(map(str,contract.parse_flyway_version(sample['text']))))
        for sample in fixture['invalidVersions']:
            with self.assertRaises(ValueError):contract.parse_flyway_version(sample)
        for sample in fixture['validHistoryVersions']:
            self.assertEqual(sample['raw'],contract.flyway_raw_version_from_filename(sample['file']))
            self.assertEqual(contract.parse_flyway_version(sample['canonical']),contract.validate_flyway_history_version(sample['raw'],sample['file']))
        for sample in fixture['invalidHistoryVersions']:
            with self.assertRaises(ValueError):contract.validate_flyway_history_version(sample['raw'],sample['file'])

    def test_real_source_inventory_keeps_every_committed_compound_version(self):
        records=verifier.migration_inventory(REAL_ROOT)
        files=list((REAL_ROOT/'server/src/main/resources/db/migration').glob('V*.sql'))
        self.assertEqual(len(files),len(records))
        versions=[r[0] for r in records]
        self.assertTrue({'990.1',*[f'999.{number}' for number in range(1,14)]}.issubset(versions))
        self.assertLess(versions.index('999.9'),versions.index('999.10'))
        self.assertLess(versions.index('999.10'),versions.index('999.13'))
        self.assertEqual('V01__enable_pgcrypto.sql',records[0][1]);self.assertEqual('1',records[0][0])

    def test_fixed_readonly_query_selectors_work_under_isolated_python_and_unknown_options_emit_nothing(self):
        executable=os.environ.get('UTEN_PYTHON_EXECUTABLE') or sys.executable
        script=Path(verifier.__file__).resolve()
        for selector in ('--history-state-sql','--history-rows-sql'):
            completed=subprocess.run([executable,'-I',str(script),selector],check=True,capture_output=True)
            sql=completed.stdout.decode('utf-8').strip()
            self.assertTrue(sql.startswith('SELECT '));self.assertNotIn(';',sql)
            self.assertIn("string_to_array(version, '.')::numeric[]",sql)
        rejected=subprocess.run([executable,'-I',str(script),'--history-rows-sql;DROP'],capture_output=True)
        self.assertEqual(66,rejected.returncode);self.assertEqual(b'',rejected.stdout)


if __name__=='__main__':unittest.main()
