"""Offline provenance and optional real PostgreSQL loader contracts.

Set LEGACY_MEDIA_PG_TEST=1 for a private throwaway PostgreSQL container. Never
connects to the developer's business database or changes an existing container.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

import prepare_legacy_goods_media as media


class MediaProofTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.original = self.root/'original.jpg'
        self.original.write_bytes(b'\xff\xd8\xff\xd9')
        self.source = self.root/'export_manifest.json'
        self.source.write_text(json.dumps({'target':'All','sourceBackupSha256':'a'*64}), encoding='utf-8')
        self.item = {'file':'original.jpg','legacy_goods_id':65184,'goods_code':'280245037',
                     'source_table':'B_Goods','source_column':'ProductGraph1','content_type':'image/jpeg',
                     'bytes':4,'sha256':media.digest(self.original)}
        self.manifest = {'format':'uten-legacy-goods-original-media-v1','database_updateability':'READ_ONLY',
                         'read_only_queries':True,'source_export_manifest_sha256':media.digest(self.source),
                         'source_backup_sha256':'a'*64,'inventory':dict.fromkeys(media.COLUMNS,0),
                         'files':[self.item]}
        self.manifest['inventory']['ProductGraph1'] = 1
        self.path = self.root/'media.json'

    def save(self):
        self.path.write_text(json.dumps(self.manifest), encoding='utf-8')

    def test_exact_original_is_stable_and_visually_reviewed(self):
        self.save()
        _, first = media.load_originals(self.path,self.source)
        _, second = media.load_originals(self.path,self.source)
        self.assertEqual(first,second)
        self.assertEqual(first[0]['category'],'产品图片')
        self.assertEqual(len(first[0]['storage_key']),36)

    def test_physical_readonly_and_raw_manifest_binding(self):
        for field,value in [('database_updateability','READ_WRITE'),('source_export_manifest_sha256','b'*64)]:
            with self.subTest(field=field):
                valid = self.manifest[field]; self.manifest[field] = value; self.save()
                with self.assertRaises(ValueError): media.load_originals(self.path,self.source)
                self.manifest[field] = valid

    def test_original_hash_tampering_and_duplicate_identity_fail(self):
        self.save(); self.original.write_bytes(b'wrong')
        with self.assertRaises(ValueError): media.load_originals(self.path,self.source)
        self.original.write_bytes(b'\xff\xd8\xff\xd9')
        self.manifest['files'].append(copy.deepcopy(self.item)); self.save()
        with self.assertRaises(ValueError): media.load_originals(self.path,self.source)

    def test_future_unreviewed_image_does_not_become_product_photo(self):
        self.item['legacy_goods_id'] = 65185; self.save()
        with self.assertRaisesRegex(ValueError,'visual'): media.load_originals(self.path,self.source)

    def test_scanner_requires_each_exact_result_count_and_no_errors(self):
        valid = '/media/original.jpg: OK\nScanned files: 1\nInfected files: 0\n'
        media.validate_scan(valid,[self.item])
        for invalid in [valid.replace('original.jpg','another.jpg'),valid.replace('files: 1','files: 0'),
                        valid.replace('Infected files: 0','Infected files: 1'),valid+'ERROR scanner failure\n']:
            with self.subTest(output=invalid):
                with self.assertRaises(ValueError): media.validate_scan(invalid,[self.item])


@unittest.skipUnless(os.environ.get('LEGACY_MEDIA_PG_TEST')=='1','explicit disposable PG test opt-in')
class MediaLoaderPostgresTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = 'uten-media-contract-' + uuid.uuid4().hex[:12]
        subprocess.run(['docker','run','--detach','--name',cls.container,
                        '-e','POSTGRES_PASSWORD=offline-test-only','postgres:16-alpine'],
                       check=True,capture_output=True)
        for _ in range(120):
            # Only the final server listens on TCP; the initialization server is socket-only.
            ready = subprocess.run(['docker','exec',cls.container,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True)
            if ready.returncode==0: return
            time.sleep(.25)
        raise RuntimeError('Private PostgreSQL test container did not start')

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['docker','rm','--force',cls.container],check=True,capture_output=True)

    def setUp(self):
        self.schema = 'media_' + uuid.uuid4().hex
        self.actor = '00000000-0000-4000-8000-000000000001'
        self.run = '00000000-0000-4000-8000-000000000002'
        self.source = {'source_export_manifest_sha256':'b'*64,'source_backup_sha256':'a'*64}
        self.files = [{'attachment_id':str(uuid.UUID(int=10+i)), 'legacy_goods_id':65184,'goods_code':'280245037',
                       'storage_key':f'{i:032x}.jpg','original_name':f'photo{i}.jpg','content_type':'image/jpeg',
                       'bytes':100+i,'sha256':str(i+1)*64,'category':'产品图片','scan_engine':'clamav',
                       'scan_signature':'ClamAV 1.5.4/28161','scanned_at':'2026-10-22T23:36:26Z',
                       'promoted_at':'2026-10-22T23:36:35Z'} for i in range(2)]
        self.fixture = f"""CREATE SCHEMA {self.schema}; SET search_path={self.schema},public;
CREATE TABLE users(id uuid,login_account text,is_super_admin boolean,status text,is_deleted boolean);
INSERT INTO users VALUES('{self.actor}','17665410007',true,'active',false);
CREATE TABLE legacy_migration_runs(run_id uuid,migration_mode text,status text,reconciliation_summary jsonb,source_backup_sha256 text);
INSERT INTO legacy_migration_runs VALUES('{self.run}','BOOTSTRAP','RUNNING','{{"rawManifestSha256":"{'b'*64}"}}','{'a'*64}');
CREATE TABLE goods(id uuid,legacy_id integer,code text,is_deleted boolean,auto_created boolean);
INSERT INTO goods VALUES('00000000-0000-4000-8000-000000000003',65184,'280245037',false,false);
CREATE TABLE attachments(id uuid PRIMARY KEY,owner_type varchar,owner_id uuid,storage_key varchar UNIQUE,original_name varchar,
 content_type varchar,size_bytes bigint,sha256 varchar,storage_provider varchar,storage_version varchar,storage_etag varchar,
 stored_size_bytes bigint,storage_encoding varchar,category varchar,lifecycle_state varchar,scan_engine varchar,scan_signature varchar,
 scanned_at timestamptz,promoted_at timestamptz,created_by uuid,updated_by uuid);
SET uten.bootstrap_run_id='{self.run}'; SET uten.rehearsal_actor_user_id='{self.actor}';
"""

    def execute(self, body, expect_success=True):
        result = subprocess.run(['docker','exec','-i',self.container,'psql','-X','-U','postgres','-v','ON_ERROR_STOP=1'],
                                input=self.fixture+'\n'+body,text=True,encoding='utf-8',capture_output=True)
        if expect_success:
            self.assertEqual(result.returncode,0,result.stderr)
        else:
            self.assertNotEqual(result.returncode,0,result.stdout)
        return result

    def loader(self, staged=None, target='postgres'):
        sql = media.load_sql(self.files,self.source,target,{'count':2,'source':'fixture'})
        approved = json.dumps(self.files if staged is None else staged,ensure_ascii=False)
        insert = 'INSERT INTO legacy_goods_media_stage SELECT * FROM jsonb_populate_recordset(NULL::legacy_goods_media_stage,'+media.literal(approved)+'::jsonb);'
        return '\n'.join(insert if line.startswith('\\copy ') else line for line in sql.splitlines())

    def test_actual_pg_resolves_current_uuid_and_replays_frozen_identity(self):
        self.execute('BEGIN;\n'+self.loader()+'COMMIT;\nBEGIN;\n'+self.loader()+"""
DO $$ BEGIN
 IF (SELECT count(*) FROM attachments)<>2 OR EXISTS(SELECT 1 FROM attachments
 WHERE owner_id<>'00000000-0000-4000-8000-000000000003' OR storage_version IS NOT NULL OR lifecycle_state<>'CLEAN')
 THEN RAISE EXCEPTION 'attachment contract differs'; END IF; END $$; COMMIT;
""")

    def test_wrong_database_or_raw_manifest_rejected(self):
        result = self.execute('BEGIN;\n'+self.loader(target='wrong_candidate'),False)
        self.assertIn('exact rehearsal candidate',result.stderr)

    def test_unrelated_base_import_manifest_and_actor_rejected(self):
        self.source['source_export_manifest_sha256'] = 'c'*64
        result = self.execute('BEGIN;\n'+self.loader(),False)
        self.assertIn('sealed base import run',result.stderr)

    def test_preserved_superadmin_actor_required(self):
        result = self.execute("UPDATE users SET is_super_admin=false; BEGIN;\n"+self.loader(),False)
        self.assertIn('preserved administrator actor',result.stderr)

    def test_tampered_clean_metadata_rejected_before_any_insert(self):
        changed = copy.deepcopy(self.files); changed[0]['sha256'] = 'f'*64
        result = self.execute('BEGIN;\n'+self.loader(changed),False)
        self.assertIn('scanned approved rows',result.stderr)

    def test_placeholder_goods_and_changed_immutable_identity_rejected(self):
        result = self.execute("UPDATE goods SET auto_created=true; BEGIN;\n"+self.loader(),False)
        self.assertIn('exact live imported goods',result.stderr)

    def test_existing_original_identity_is_never_overwritten(self):
        result = self.execute('BEGIN;\n'+self.loader()+"COMMIT; UPDATE attachments SET sha256=repeat('e',64); BEGIN;\n"+self.loader(),False)
        self.assertIn('never overwrite an original',result.stderr)


@unittest.skipUnless(os.environ.get('LEGACY_MEDIA_ADAPTER_TEST')=='1','explicit compiled standard adapter test opt-in')
class StandardLocalAdapterTest(unittest.TestCase):
    def test_exact_replay_and_changed_final_or_jpeg_fail_closed(self):
        # Reuses only the source plan and built helper classes from the offline
        # preparation. All object writes are inside this test's own temporary root.
        output = Path(os.environ['LEGACY_MEDIA_TEST_OUTPUT'])
        server_classes = Path(os.environ['LEGACY_MEDIA_TEST_SERVER_CLASSES'])
        dependencies = Path(os.environ['LEGACY_MEDIA_TEST_CLASSPATH']).read_text(encoding='utf-8').strip()
        classpath = str(output/'helper-classes')+os.pathsep+str(server_classes)+os.pathsep+dependencies
        original_plan = json.loads((output/'storage_plan.json').read_text(encoding='utf-8'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); plan = root/'plan.json'
            plan.write_text(json.dumps(original_plan), encoding='utf-8')
            args = ['java','-cp',classpath,'com.uten.imp.common.storage.LegacyMediaLocalStore',
                    str(plan),str(root/'storage'),str(root/'receipt.json')]
            for _ in range(2):
                result = subprocess.run(args,capture_output=True,text=True,encoding='utf-8',errors='replace')
                self.assertEqual(result.returncode,0,result.stderr)
            original = original_plan['files'][0]
            target = root/'storage/final'/original['storage_key']
            target.write_bytes(b'tampered')
            result = subprocess.run(args,capture_output=True,text=True,encoding='utf-8',errors='replace')
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(target.read_bytes(),b'tampered')
            self.assertEqual(media.digest(Path(original['source_path'])),original['sha256'])
            invalid = root/'invalid.jpg'; invalid.write_bytes(b'not-a-jpeg')
            original['source_path'] = str(invalid); original['bytes'] = invalid.stat().st_size
            original['sha256'] = media.digest(invalid)
            plan.write_text(json.dumps(original_plan),encoding='utf-8')
            result = subprocess.run(args,capture_output=True,text=True,encoding='utf-8',errors='replace')
            self.assertNotEqual(result.returncode,0)


if __name__=='__main__': unittest.main()
