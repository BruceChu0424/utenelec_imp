"""Explicit post-import target selection and same-snapshot physical identity."""
import json
import os
import subprocess
import time
import tempfile
import unittest
import uuid
from unittest.mock import patch

from verify_rehearsal_result import ReadOnlyDatabase, VerificationError, parser


class VerifierTargetIdentityTest(unittest.TestCase):
    def test_cli_keeps_defaults_and_accepts_exact_local_target(self):
        required=['--inputs','inputs','--admin-snapshot','admin.json','--run-id',str(uuid.uuid4()),
                  '--database','uten_imp','--manifest-sha256','0'*64,'--frozen-commit','1'*40,'--output','receipt.json']
        defaults=parser().parse_args(required)
        self.assertEqual((defaults.container,defaults.user),('uten-imp-postgres','uten'))
        target=parser().parse_args([*required,'--container','uten-dev-5434','--user','uten_migrator',
                                  '--expected-system-identifier','123456','--expected-database-oid','19699'])
        self.assertEqual((target.container,target.user,target.expected_database_oid),('uten-dev-5434','uten_migrator',19699))

    def test_invalid_or_incomplete_target_identity_is_rejected(self):
        for changes in ({'container':'host;echo secret'},{'user':'postgres;drop'},
                        {'expected_system_identifier':'123'}, {'expected_database_oid':123},
                        {'expected_system_identifier':'123','expected_database_oid':True}):
            with self.subTest(changes=changes),self.assertRaises(VerificationError):
                ReadOnlyDatabase('uten_imp',**changes)

    def test_remote_environment_is_rejected_before_payload_query(self):
        with patch.dict(os.environ,{'DOCKER_HOST':'tcp://remote:2376'}), \
             patch('verify_rehearsal_result.subprocess.run') as query,self.assertRaises(VerificationError):
            ReadOnlyDatabase('uten_imp').query('SELECT 1;')
        query.assert_not_called()

    def test_each_snapshot_checks_identity_and_uses_explicit_transport_role(self):
        db=ReadOnlyDatabase('uten_imp','uten-dev-5434','uten_migrator','123456',19699)
        payload={'database':'uten_imp','system_identifier':'123456','database_oid':19699,'result':{'fact':1}}
        result=lambda x:subprocess.CompletedProcess([],0,(json.dumps(x)+'\n').encode(),b'')
        with patch.object(db,'_pin_transport',return_value=['docker','--context','local','exec','-i','a'*64]), \
             patch('verify_rehearsal_result.subprocess.run',return_value=result(payload)) as query:
            self.assertEqual(db.query('SELECT jsonb_build_object(\'fact\',1);'),{'fact':1})
            self.assertIn('uten_migrator',query.call_args.args[0])
            sql=query.call_args.kwargs['input'].decode()
            self.assertIn('REPEATABLE READ READ ONLY',sql)
            self.assertIn('pg_control_system()',sql)
            self.assertIn("'result',(SELECT jsonb_build_object",sql)
            payload['database_oid']=19700
            query.return_value=result(payload)
            with self.assertRaisesRegex(VerificationError,'explicit target'):
                db.query('SELECT jsonb_build_object(\'fact\',1);')

    def test_legacy_default_adapter_pins_first_physical_identity(self):
        db=ReadOnlyDatabase('uten_imp')
        payload={'database':'uten_imp','system_identifier':'123456','database_oid':19699,'result':True}
        with patch.object(db,'_pin_transport',return_value=['docker','exec','-i','local']), \
             patch('verify_rehearsal_result.subprocess.run') as query:
            query.return_value=subprocess.CompletedProcess([],0,(json.dumps(payload)+'\n').encode(),b'')
            self.assertTrue(db.query('SELECT true;'))
            payload['system_identifier']='654321'
            query.return_value=subprocess.CompletedProcess([],0,(json.dumps(payload)+'\n').encode(),b'')
            with self.assertRaisesRegex(VerificationError,'changed between snapshots'):
                db.query('SELECT true;')


class VerifierTargetIdentityPostgresTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container='uten-verifier-target-'+uuid.uuid4().hex[:12]
        subprocess.run(['docker','run','--detach','--network','none','--name',cls.container,
                        '-e','POSTGRES_PASSWORD=isolated-contract-only','postgres:16-alpine'],check=True,capture_output=True)
        for _ in range(120):
            # Wait for the final server, not the Unix-only initdb phase. The
            # verifier itself retains its original pinned local-socket transport.
            if subprocess.run(['docker','exec',cls.container,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0:break
            time.sleep(.25)
        else:
            subprocess.run(['docker','rm','--force',cls.container],capture_output=True)
            raise RuntimeError('Private PostgreSQL fixture did not start')
        row=subprocess.check_output(['docker','exec',cls.container,'psql','-X','-At','-U','postgres','-c',
              "SELECT (SELECT system_identifier::text FROM pg_control_system())||'|'||(SELECT oid::text FROM pg_database WHERE datname=current_database());"],text=True).strip()
        cls.system,oid=row.split('|');cls.oid=int(oid)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['docker','rm','--force',cls.container],check=True,capture_output=True)

    def test_native_exact_target_reads_both_snapshots_and_remains_readonly(self):
        db=ReadOnlyDatabase('postgres',self.container,'postgres',self.system,self.oid)
        for _ in range(2):
            self.assertEqual(db.query("SELECT jsonb_build_object('is_readonly',current_setting('transaction_read_only'),'role',current_user);"),
                             {'is_readonly':'on','role':'postgres'})
        self.assertEqual(db.actual_identity,(self.system,self.oid))

    def test_native_archive_reader_uses_exact_target_and_preserves_decimal(self):
        from verify_finance_archive import read_target
        from decimal import Decimal
        run='00000000-0000-4000-8000-000000000001'
        sql="""CREATE TABLE legacy_migration_runs(run_id uuid,status text,reconciliation_status text,
export_manifest_sha256 text,checksum_manifest_sha256 text,migration_repository_commit text,reconciliation_summary jsonb);
CREATE TABLE legacy_migration_run_files(run_id uuid,file_name text,sha256 text);
CREATE TABLE finance_reconciliations(legacy_id int);
CREATE TABLE legacy_finance_import_sources(run_id uuid,source_kind text,source_legacy_id int);
CREATE TABLE accounts(legacy_id int);
INSERT INTO legacy_migration_runs VALUES('"""+run+"""','SUCCESS','PASSED','a','a','b',
'{"financeArchiveOnly":{"preciseAmount":12345678.1234}}');"""
        subprocess.run(['docker','exec','-i',self.container,'psql','-X','-q','-v','ON_ERROR_STOP=1','-U','postgres'],
                       input=sql.encode(),check=True,capture_output=True)
        with tempfile.TemporaryDirectory() as folder:
            facts=read_target(self.container,'postgres',run,__import__('pathlib').Path(folder),
                              'postgres',self.system,self.oid)
            self.assertEqual(facts['run']['finance_archive']['preciseAmount'],Decimal('12345678.1234'))
            self.assertEqual(facts['transaction_read_only'],'on')
            with self.assertRaisesRegex(ValueError,'explicit target'):
                read_target(self.container,'postgres',run,__import__('pathlib').Path(folder),'postgres',self.system,self.oid+1)

    def test_native_wrong_oid_is_rejected_even_when_database_name_matches(self):
        db=ReadOnlyDatabase('postgres',self.container,'postgres',self.system,self.oid+1)
        with self.assertRaisesRegex(VerificationError,'explicit target'):
            db.query('SELECT true;')


if __name__=='__main__':unittest.main()
