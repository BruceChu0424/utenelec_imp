"""Synthetic, file-only tests. No real run, source directory or DB is used."""
from pathlib import Path
from copy import deepcopy
import csv
import hashlib
import json
import re
import tempfile
import unittest
import uuid
from unittest.mock import patch
import personnel_source_archive as builder
import verify_personnel_source_archive as verifier


RUN = '00000000-0000-0000-0000-000000000018'
COMMIT = 'e' * 40
MAPPING = 'bootstrap-v18'


class ArchiveFixture:
    def __init__(self, path):
        self.path = path
        self.rows = {
            'legacy_operators_ref.csv': (['legacy_id', 'name'], [
                ['1', '账号甲'], ['2', "O'Brien\\账号|换行\n$personnel_source_archive$; DROP TABLE users; --"], ['3', '']]),
            'subcontract_order_m.csv': (['legacy_id', 'status', 'maker_legacy', 'approver_legacy'],
                                      [['101', '1', '1', '0'], ['102', '0', '2', '1']]),
            'subcontract_swaste_m.csv': (['legacy_id', 'status', 'maker_legacy', 'approver_legacy'],
                                       [['201', '1', '2', '1']]),
        }
        for name in builder.SOURCE_FILES:
            if name not in self.rows:
                self.rows[name] = (['legacy_id', 'status', 'maker_legacy', 'approver_legacy'], [['301', '1', '1', '2']])
        self.rewrite()

    def rewrite(self):
        entries = []
        for name, (fields, rows) in self.rows.items():
            with (self.path/name).open('w', encoding='utf-8', newline='') as stream:
                writer = csv.writer(stream, delimiter='|'); writer.writerow(fields); writer.writerows(rows)
            data = (self.path/name).read_bytes()
            entries.append(dict(file=name, rows=len(rows), bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
        self.manifest = dict(formatVersion=4, target='All', sourceSnapshotAsOfUtc='2026-10-23T11:59:16Z', files=entries,
            provenance=dict(importerRepositoryCommit=COMMIT, rawManifestSha256='a'*64, rawSourceBackupSha256='b'*64,
                scripts={'personnel_source_archive.py':hashlib.sha256(Path(builder.__file__).read_bytes()).hexdigest()}))
        self.save_manifest()

    def save_manifest(self):
        path = self.path/'derived_inputs.json'
        path.write_text(json.dumps(self.manifest, ensure_ascii=False), encoding='utf-8')
        self.manifest_sha = hashlib.sha256(path.read_bytes()).hexdigest()

    @property
    def args(self):
        return dict(inputs=self.path, run_id=RUN, manifest_sha256=self.manifest_sha, frozen_commit=COMMIT, mapping_version=MAPPING)

    def actual(self):
        archive = builder.build_personnel_source_archive(**self.args)
        anchors = []
        for kind, file in [('SUBCONTRACT_ORDER','subcontract_order_m.csv'),('SUBCONTRACT_WASTE','subcontract_swaste_m.csv')]:
            for old, status, maker, approver in self.rows[file][1]:
                identity = str(uuid.UUID(int=int(old)+(10000 if kind.endswith('WASTE') else 0)))
                approved = kind == 'SUBCONTRACT_ORDER' and status == '1'
                anchors.append(dict(kind=kind, legacyDocId=int(old), targetDocumentId=identity, status=int(status),
                    legacyImportRunId=RUN if approved else None, sourceProofRunId=RUN if approved else None,
                    sourceProofTargetId=identity if approved else None, sourceProofLegacyId=int(old) if approved else None))
        lookup = {(a['kind'],a['legacyDocId']):a['targetDocumentId'] for a in anchors}
        for ref in archive['unmaterializedHeaderActors']:
            ref['targetDocumentId'] = lookup[(ref['kind'],ref['legacyDocId'])]
        run = dict(runId=RUN, status='SUCCESS', reconciliationStatus='PASSED', manifestSha256=self.manifest_sha,
            frozenCommit=COMMIT, mappingVersion=MAPPING, backupSha256='b'*64, rawManifestSha256='a'*64,
            sourceSnapshotAsOfUtc='2026-10-23T11:59:16Z')
        return archive, anchors, run


class PersonnelSourceArchiveTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='synthetic-personnel-archive-')
        self.addCleanup(self.temp.cleanup)
        self.fixture = ArchiveFixture(Path(self.temp.name))

    def check(self, archive=None, anchors=None, run=None):
        a, t, r = self.fixture.actual()
        return verifier.verify_personnel_source_archive(**self.fixture.args,
            actual_archive=a if archive is None else archive,
            target_documents=t if anchors is None else anchors, run_metadata=r if run is None else run)

    def test_complete_dictionary_includes_unreferenced_and_empty_name_accounts(self):
        a = builder.build_personnel_source_archive(**self.fixture.args)
        self.assertEqual(a['operatorCount'], 3)
        self.assertEqual(a['unmaterializedHeaderActorCount'], 5)
        self.assertEqual(a['operators'][-1], {'sourceOperatorLegacyId':3, 'sourceDisplayName':''})
        self.assertTrue(all(row['targetDocumentId'] is None for row in a['unmaterializedHeaderActors']))
        self.assertTrue(self.check()['verified'])

    def test_independent_verifier_does_not_call_builder(self):
        archive, anchors, run = self.fixture.actual()
        with patch.object(builder, 'build_personnel_source_archive', side_effect=RuntimeError('builder forbidden')):
            result = verifier.verify_personnel_source_archive(**self.fixture.args, actual_archive=archive,
                        target_documents=anchors, run_metadata=run)
        self.assertTrue(result['verified'])

    def test_future_more_accounts_and_documents_are_not_capped_at_current_sample(self):
        self.fixture.rows['legacy_operators_ref.csv'][1].extend([[str(i), '新增账号'+str(i)] for i in range(4, 145)])
        self.fixture.rows['subcontract_swaste_m.csv'][1].append(['202', '0', '144', '0'])
        self.fixture.rewrite()
        self.assertEqual(self.check()['operatorDictionaryCount'], 144)
        self.assertEqual(self.check()['headerActorReferenceCount'], 6)

    def test_array_order_is_not_identity_but_duplicate_ids_are_rejected(self):
        archive, anchors, run = self.fixture.actual()
        archive['operators'].reverse(); archive['sourceFiles'].reverse(); archive['unmaterializedHeaderActors'].reverse()
        self.assertTrue(self.check(archive, anchors, run)['verified'])
        archive['operators'].append(deepcopy(archive['operators'][0]))
        with self.assertRaises(ValueError): self.check(archive, anchors, run)

    def test_mutated_or_omitted_dictionary_name_is_rejected(self):
        original, anchors, run = self.fixture.actual()
        for mutation in ('rename', 'omit', 'extra', 'wrong_identity', 'name_type'):
            with self.subTest(mutation=mutation):
                archive=deepcopy(original)
                if mutation=='rename': archive['operators'][0]['sourceDisplayName']='当时审批人（错误推断）'
                elif mutation=='omit': archive['operators'].pop()
                elif mutation=='extra': archive['operators'].append(dict(sourceOperatorLegacyId=99,sourceDisplayName='额外'))
                elif mutation=='wrong_identity': archive['operators'][0]['sourceOperatorLegacyId']=9
                else: archive['operators'][0]['sourceDisplayName']=None
                with self.assertRaises(ValueError): self.check(archive, anchors, run)

    def test_source_only_references_cannot_drop_change_or_repeat_actor_ids(self):
        original, anchors, run = self.fixture.actual()
        for mutation in ('omit','duplicate','wrong_actor','wrong_name','wrong_field','wrong_document','uuid_missing','uuid_wrong','extra_key'):
            with self.subTest(mutation=mutation):
                archive=deepcopy(original); ref=archive['unmaterializedHeaderActors'][0]
                if mutation=='omit': archive['unmaterializedHeaderActors'].pop()
                elif mutation=='duplicate': archive['unmaterializedHeaderActors'].append(deepcopy(ref))
                elif mutation=='wrong_actor': ref['actorLegacyId']=2
                elif mutation=='wrong_name': ref['sourceDisplayName']='同号员工姓名不可用'
                elif mutation=='wrong_field': ref['sourceField']='worker_legacy'
                elif mutation=='wrong_document': ref['legacyDocId']=201
                elif mutation=='uuid_missing': ref['targetDocumentId']=None
                elif mutation=='uuid_wrong': ref['targetDocumentId']=str(uuid.UUID(int=99999))
                else: ref['employeeId']=str(uuid.UUID(int=1))
                with self.assertRaises(ValueError): self.check(archive, anchors, run)

    def test_real_target_anchor_and_current_order_proof_are_mandatory(self):
        archive, original, run = self.fixture.actual()
        for mutation in ('none', 'missing', 'duplicate', 'wrong_uuid', 'wrong_run', 'wrong_proof_run', 'wrong_proof_id', 'wrong_legacy', 'wrong_status'):
            with self.subTest(mutation=mutation):
                anchors=deepcopy(original)
                if mutation=='none':
                    with self.assertRaises(ValueError): verifier.verify_personnel_source_archive(**self.fixture.args,
                        actual_archive=archive, run_metadata=run)
                    continue
                if mutation=='missing': anchors=[]
                elif mutation=='duplicate': anchors.append(deepcopy(anchors[0]))
                elif mutation=='wrong_uuid': anchors[0]['targetDocumentId']=str(uuid.UUID(int=9999))
                elif mutation=='wrong_run': anchors[0]['legacyImportRunId']=str(uuid.UUID(int=9999))
                elif mutation=='wrong_proof_run': anchors[0]['sourceProofRunId']=None
                elif mutation=='wrong_proof_id': anchors[0]['sourceProofTargetId']=str(uuid.UUID(int=9999))
                elif mutation=='wrong_legacy': anchors[0]['sourceProofLegacyId']=201
                else: anchors[0]['status']=0
                with self.assertRaises(ValueError): self.check(archive, anchors, run)

    def test_status_mf_freeze_mapping_backup_and_metadata_cannot_be_spoofed(self):
        archive, anchors, original = self.fixture.actual()
        for field,value in [('status','RUNNING'),('reconciliationStatus','NOT_RUN'),('runId',str(uuid.UUID(int=99))),
            ('manifestSha256','c'*64),('frozenCommit','c'*40),('mappingVersion','bootstrap-v17'),
            ('backupSha256','c'*64),('rawManifestSha256','c'*64),('sourceSnapshotAsOfUtc','2026-01-01T00:00:00Z')]:
            with self.subTest(field=field):
                run=deepcopy(original);run[field]=value
                with self.assertRaises(ValueError): self.check(archive, anchors, run)

    def test_semantic_labels_and_typed_counts_cannot_claim_approval_identity(self):
        archive, anchors, run=self.fixture.actual()
        for field,value in [('namesAreHistoricalApprovalIdentity',True),('employeeOrUserAccountsCreated',True),
            ('operatorCount',True),('unmaterializedHeaderActorCount',5.0),('displayNameMeaning','实际审批身份'),
            ('archiveDoesNotPopulateBusinessNameColumns',False)]:
            with self.subTest(field=field):
                altered=deepcopy(archive);altered[field]=value
                with self.assertRaises(ValueError): self.check(altered,anchors,run)

    def test_all_seven_file_hashes_and_metadata_are_strict(self):
        original,anchors,run=self.fixture.actual()
        for mutation in ('missing','duplicate','sha','bytes','row_bool','extra'):
            with self.subTest(mutation=mutation):
                archive=deepcopy(original)
                if mutation=='missing': archive['sourceFiles'].pop()
                elif mutation=='duplicate': archive['sourceFiles'].append(deepcopy(archive['sourceFiles'][0]))
                elif mutation=='sha': archive['sourceFiles'][0]['sha256']='c'*64
                elif mutation=='bytes': archive['sourceFiles'][0]['bytes']+=1
                elif mutation=='row_bool': archive['sourceFiles'][-1]['rows']=True
                else: archive['sourceFiles'][0]['extra']='not source'
                with self.assertRaises(ValueError): self.check(archive,anchors,run)

    def test_manifest_and_frozen_generator_must_match_before_sql_is_rendered(self):
        for change in ('mf', 'commit', 'mapping', 'run', 'generator'):
            with self.subTest(change=change):
                args=dict(self.fixture.args)
                if change=='mf': args['manifest_sha256']='c'*64
                elif change=='commit': args['frozen_commit']='c'*40
                elif change=='mapping': args['mapping_version']='bootstrap-v17'
                elif change=='run': args['run_id']="not-a-uuid';DELETE FROM users;--"
                else:
                    self.fixture.manifest['provenance']['scripts']['personnel_source_archive.py']='c'*64
                    self.fixture.save_manifest();args=dict(self.fixture.args)
                with self.assertRaises(ValueError): builder.render_personnel_source_archive_sql(**args)

    def test_csv_corruption_duplicate_ids_and_unknown_operator_fail_closed(self):
        for change in ('hash','operator_duplicate','header_duplicate','unknown_actor','negative_actor','missing_source'):
            with self.subTest(change=change):
                with tempfile.TemporaryDirectory(prefix='synthetic-personnel-negative-') as temp:
                    fixture=ArchiveFixture(Path(temp))
                    if change=='hash': (fixture.path/'sales_orders.csv').write_text('changed',encoding='utf-8')
                    elif change=='operator_duplicate': fixture.rows['legacy_operators_ref.csv'][1].append(['1','another']);fixture.rewrite()
                    elif change=='header_duplicate': fixture.rows['subcontract_order_m.csv'][1].append(['101','1','1','0']);fixture.rewrite()
                    elif change=='unknown_actor': fixture.rows['subcontract_swaste_m.csv'][1][0][2]='999';fixture.rewrite()
                    elif change=='negative_actor': fixture.rows['subcontract_swaste_m.csv'][1][0][2]='-1';fixture.rewrite()
                    else:
                        fixture.manifest['files']=[x for x in fixture.manifest['files'] if x['file']!='sales_returns.csv'];fixture.save_manifest()
                    with self.assertRaises(ValueError): builder.build_personnel_source_archive(**fixture.args)

    def test_render_is_late_summary_only_and_source_text_is_hex_encoded(self):
        sql=builder.render_personnel_source_archive_sql(**self.fixture.args)
        self.assertNotIn("O'Brien",sql)
        self.assertNotIn('DROP TABLE users',sql)
        payload=re.search(r"decode\('([0-9a-f]+)','hex'\)",sql)[1]
        parsed=json.loads(bytes.fromhex(payload).decode('utf-8'))
        self.assertEqual(parsed['operators'][1]['sourceDisplayName'],self.fixture.rows['legacy_operators_ref.csv'][1][1][1])
        self.assertEqual(re.findall(r'(?i)UPDATE\s+public\.(\w+)',sql),['legacy_migration_runs'])
        self.assertIn("status='RUNNING'",sql)
        self.assertIn('fn_require_legacy_subcontract_bootstrap',sql)
        self.assertIn('legacy_subcontract_order_import_sources',sql)
        self.assertIn('document.xmin',sql)
        self.assertIn('targetDocumentId',sql)
        self.assertNotRegex(sql,r'(?i)\b(CREATE|ALTER|COPY|INSERT|DELETE)\b')

    def test_independent_query_uses_one_readonly_snapshot_without_business_writes(self):
        sql=verifier.render_personnel_source_archive_verification_sql(RUN)
        self.assertIn('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY',sql)
        self.assertTrue(sql.rstrip().endswith('ROLLBACK;'))
        self.assertNotRegex(sql,r'(?i)\b(CREATE|ALTER|COPY|INSERT|UPDATE|DELETE)\b')
        self.assertIn('sourceProofTargetId',sql)


if __name__ == '__main__':
    unittest.main()
