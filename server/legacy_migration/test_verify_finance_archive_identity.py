from copy import deepcopy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import verify_finance_archive as verifier

class FinanceArchiveIdentityTest(unittest.TestCase):
    def test_cli_accepts_only_local_context_and_expected_target_names(self):
        with patch('rehearse_local_import.subprocess.check_output',return_value='npipe:////./pipe/docker_engine\n') as docker,patch.dict(os.environ,{},clear=True):
            verifier.verify_local_cli_target('uten-imp-postgres','uten_imp',False)
            verifier.verify_local_cli_target('uten-imp-postgres','uten_imp_rehearsal_20261022_v2',False)
            verifier.verify_local_cli_target('uten-imp-postgres',None,True)
            self.assertEqual(docker.call_count,3)
        for container,database in [('other-container','uten_imp'),('uten-imp-postgres','company_production'),('uten-imp-postgres','uten_imp_rehearsal'),('uten-imp-postgres','postgres')]:
            with self.subTest(container=container,database=database),self.assertRaises(ValueError):verifier.verify_local_cli_target(container,database,False)
    def test_remote_context_and_environment_are_rejected_even_in_source_only(self):
        for endpoint,environment in [('tcp://remote:2375',{}),('npipe:////./pipe/docker_engine',{'DOCKER_HOST':'ssh://remote'})]:
            for source_only in (True,False):
                with self.subTest(endpoint=endpoint,source_only=source_only),patch('rehearse_local_import.subprocess.check_output',return_value=endpoint),patch.dict(os.environ,environment,clear=True),self.assertRaises(ValueError):
                    verifier.verify_local_cli_target('uten-imp-postgres',None if source_only else 'uten_imp',source_only)
    def test_run_is_bound_to_full_manifest_commit_and_actual_database_identity(self):
        manifest={'manifest_sha256':'a'*64,'importer_repository_commit':'b'*40}
        facts={'database':'uten_imp_rehearsal_20261022_v2','system_identifier':'1234567890123456789','database_oid':16384,
               'run':{'export_manifest_sha256':'a'*64,'checksum_manifest_sha256':'a'*64,'migration_repository_commit':'b'*40}}
        projected=verifier.verify_run_identity(facts,manifest)
        self.assertEqual(projected['database_oid'],16384)
        self.assertEqual(projected['system_identifier'],facts['system_identifier'])
        # Internal target reader remains usable by an isolated fixture, while
        # the public CLI guard above rejects this container/database pair.
        run_id='00000000-0000-4000-8000-000000000001'
        read_facts=deepcopy(facts)
        read_facts.update({'database':'postgres','transaction_read_only':'on'})
        read_facts['run'].update({'run_id':run_id,'status':'SUCCESS','reconciliation_status':'PASSED'})
        with tempfile.TemporaryDirectory() as folder,patch.object(verifier,'checked',return_value=json.dumps(read_facts).encode()) as checked:
            read_back=verifier.read_target('isolated-fixture','postgres',run_id,Path(folder))
            sql=checked.call_args.args[1].decode()
            self.assertIn('BEGIN READ ONLY;',sql)
            self.assertIn('FROM pg_control_system()',sql)
            self.assertIn("'database_oid'",sql)
            self.assertIn("'export_manifest_sha256'",sql)
            self.assertIn("'checksum_manifest_sha256'",sql)
            self.assertIn("'migration_repository_commit'",sql)
            self.assertEqual(read_back['database_oid'],16384)
        for key,value in [('export_manifest_sha256','c'*64),('checksum_manifest_sha256','c'*64),('migration_repository_commit','c'*40)]:
            bad=deepcopy(facts);bad['run'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):verifier.verify_run_identity(bad,manifest)
        for key,value in [('system_identifier',None),('database_oid',None),('database_oid',True)]:
            bad=deepcopy(facts);bad[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):verifier.verify_run_identity(bad,manifest)

if __name__=='__main__':unittest.main()
