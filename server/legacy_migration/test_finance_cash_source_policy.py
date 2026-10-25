"""Portable synthetic source-policy regressions; no app DB or private source needed."""
from pathlib import Path
from copy import deepcopy
import csv,hashlib,json,tempfile,unittest
from datetime import datetime,timedelta,timezone
import finance_cash_source_policy as policy

class CashSourcePolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='uten-cash-policy-test-')
        self.root=Path(self.temp.name).resolve()
        self.assertEqual(self.root.parent,Path(tempfile.gettempdir()).resolve())
        self.inputs=self.root/'source';self.inputs.mkdir();self.raw=self.root/'raw';self.raw.mkdir();self.package=self.root/'package'
        self.cutoff='2026-10-23T11:59:16Z'
        def header(old,status=1,fee='0',amount='10',bill=None):
            return dict(legacy_id=str(old),status=str(status),status2=str(status),cancel='False',approver_id='7' if status==1 else '',approver_name='fixture approval' if status==1 else '',
              bill_no=bill or 'FIX-'+str(old),bill_date='2026-01-01',qtfy=fee,qtfymc='0',total=amount,mtotal=amount)
        self.data={'m_get.csv':[header(1),header(2,-1,'2.12','0','TEST-R2'),header(3,-1,'454.26','0','TEST-R3')],
          'm_paid.csv':[header(1),header(2,-1,'0','2000072.25','TEST-P2')],
          'm_dpaid.csv':[header(1)],'m_oget.csv':[header(1)],
          'm_allcheck.csv':[dict(legacy_id='1',b_style='20',bill_id='1'),dict(legacy_id='2',b_style='21',bill_id='1')],
          'm_in.csv':[dict(legacy_id='1',b_style='20',bill_legacy_id='1')],
          'm_out.csv':[dict(legacy_id='1',b_style='21',bill_legacy_id='1')]}
        for name,data in self.data.items():self.write_csv(self.inputs/name,data);(self.raw/name).write_bytes((self.inputs/name).read_bytes())
        policy.save(self.raw/'export_manifest.json',dict(sourceSnapshotAsOfUtc=self.cutoff,sourceBackupSha256='a'*64))
        semantics=dict(physical_read_only=True,isolation='Serializable',source_business_writes=False,
          facts=dict(dictionary=[dict(ID=-1,YesOrNo='否'),dict(ID=0,YesOrNo='否'),dict(ID=1,YesOrNo='是')],
            columns=[dict(table_name=table,column_name=column,is_nullable=False,default_sql='((-1))') for table in ('M_Get','M_Paid') for column in ('Status','Status2')],
            negative_header_cash_AR_AP_links=[],three_bill_lifecycles=[]))
        decisions=[]
        for name,old in [('m_get.csv',2),('m_get.csv',3),('m_paid.csv',2)]:
            row=next(x for x in self.data[name] if int(x['legacy_id'])==old)
            event=dict(LogsID=100+len(decisions),source_beijing_time='2026-01-01T10:00:00.000',EContext='增加了fixture'+row['bill_no'])
            semantics['facts']['three_bill_lifecycles'].append(event)
            semantics['facts']['negative_header_cash_AR_AP_links'].append(dict(table_name=policy.FAMILIES[name][3],header_id=old,Status=-1,Status2=-1,exact_cash_rows=0,exact_AR_rows=0,exact_allocation_rows=0))
            # Exact JSON numeric lexemes, no float conversion of synthetic money.
            typed='{"legacy_id":'+str(old)+',"status":-1,"status2":-1,"cancel":false,"approver_id":null,"approver_name":null,"bill_no":'+json.dumps(row['bill_no'])+',"qtfy":'+row['qtfy']+',"total":'+row['total']+',"mtotal":'+row['mtotal']+'}'
            decisions.append(dict(source_file=name,source_kind=policy.FAMILIES[name][0],legacy_id=old,source_row_number=self.data[name].index(row)+2,bill_no=row['bill_no'],
              disposition='ARCHIVE_ONLY_UNAPPROVED_HISTORICAL_SOURCE',reason_codes=sorted(policy.REASONS),source_file_sha256=policy.sha(self.inputs/name),raw_source_file_sha256=policy.sha(self.raw/name),
              source_backup_sha256='a'*64,source_manifest_sha256=policy.sha(self.raw/'export_manifest.json'),source_status=-1,source_status2=-1,source_approver_present=False,source_cancel=False,
              exact_source_cash_rows=0,exact_source_AR_AP_rows=0,exact_source_allocation_rows=0,source_amounts_or_approval_changed=False,target_money_document_created=False,target_GL_voucher_created=False,current_workflow_claim_created=False,all_original_source_bytes_retained=True,
              typed_full_row_jsonb_text=typed,typed_full_row_pg_sha256=hashlib.sha256(typed.encode()).hexdigest(),source_creation_and_last_available_activity=event,
              source_activity_age_days_at_cutoff=295))
        self.sem=self.root/'semantics.json';policy.save(self.sem,semantics)
        for row in decisions:row['source_semantics_sha256']=policy.sha(self.sem)
        review=dict(format='exact-reviewed-legacy-finance-source-dispositions-v1',status='EXACT_THREE_SOURCE_ROWS_REVIEWED_ARCHIVE_ONLY',unknown_or_changed_unapproved_source_policy='EARLY_HARD_FAIL_AND_REVIEW',target_accessed=False,not_execution_authority=True,source_cutoff_utc=self.cutoff,source_timezone='Asia/Shanghai',source_semantics_sha256=policy.sha(self.sem),rows=decisions)
        self.review=self.root/'review.json';policy.save(self.review,review)
        self.native=self.root/'native.json';policy.save(self.native,dict(status='TYPED_COMPLETE_SOURCE_ROW_FINGERPRINTS_VERIFIED',application_target_accessed=False,business_data_written=False,source_semantics_sha256=policy.sha(self.sem),decision_sha256=policy.sha(self.review)))
        policy.prepare_package(self.review,self.sem,self.native,self.raw,self.inputs,self.package)
        for name in self.data:(self.package/name).write_bytes((self.inputs/name).read_bytes())
    def tearDown(self):
        self.assertEqual(self.root.parent,Path(tempfile.gettempdir()).resolve());self.assertTrue(self.root.name.startswith('uten-cash-policy-test-'));self.temp.cleanup()
    def write_csv(self,path,data):
        with path.open('w',encoding='utf-8',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(data[0]),delimiter='|');writer.writeheader();writer.writerows(data)
    def test_nonzero_fees_and_large_unapproved_amount_remain_complete_archives(self):
        data=policy.load_policy(self.package)
        self.assertEqual(data['inventory']['m_get.csv']['active_ids'],[1]);self.assertEqual(data['inventory']['m_get.csv']['archive_ids'],[2,3])
        self.assertEqual(data['inventory']['m_paid.csv']['active_ids'],[1]);self.assertEqual(data['inventory']['m_paid.csv']['archive_ids'],[2])
        typed=[row['typed_full_row_jsonb_text'] for row in data['reviewed']]
        self.assertTrue(any('2.12' in x for x in typed));self.assertTrue(any('454.26' in x for x in typed));self.assertTrue(any('2000072.25' in x for x in typed))
    def test_unknown_or_mixed_nonposted_source_requires_review_before_target(self):
        for status,status2 in [('-1','-1'),('1','-1'),('','1')]:
            data=deepcopy(self.data['m_get.csv']);data[0]['status']=status;data[0]['status2']=status2
            self.write_csv(self.package/'m_get.csv',data)
            package=policy.load(self.package/policy.POLICY_FILE);package['source_files']['m_get.csv']['sha256']=policy.sha(self.package/'m_get.csv');policy.save(self.package/policy.POLICY_FILE,package)
            with self.assertRaisesRegex(ValueError,'Unknown or changed nonposted'):policy.load_policy(self.package)
    def test_portable_evidence_tamper_is_rejected(self):
        (self.package/policy.SEMANTICS_FILE).write_bytes(b'{}')
        with self.assertRaisesRegex(ValueError,'evidence changed'):policy.load_policy(self.package)
    def test_complete_typed_row_fingerprint_is_required(self):
        review=policy.load(self.package/policy.REVIEW_FILE);review['rows'][0]['typed_full_row_jsonb_text']+=' '
        policy.save(self.package/policy.REVIEW_FILE,review)
        package=policy.load(self.package/policy.POLICY_FILE);package['reviewed_dispositions']['sha256']=policy.sha(self.package/policy.REVIEW_FILE)
        native=policy.load(self.package/policy.NATIVE_FILE);native['decision_sha256']=package['reviewed_dispositions']['sha256'];policy.save(self.package/policy.NATIVE_FILE,native)
        package['typed_source_native']['sha256']=policy.sha(self.package/policy.NATIVE_FILE);policy.save(self.package/policy.POLICY_FILE,package)
        with self.assertRaisesRegex(ValueError,'fingerprint differs'):policy.load_policy(self.package)
    def test_duplicate_or_missing_review_identity_is_rejected(self):
        good=policy.load(self.review);semantics=policy.load(self.sem);native=policy.load(self.native)
        for reviewed in [good['rows']+[deepcopy(good['rows'][0])],good['rows'][:-1]]:
            bad=deepcopy(good);bad['rows']=reviewed
            with self.assertRaises(ValueError):policy.checked_review(bad,semantics,native)
    def test_fake_source_dictionary_or_approval_cannot_be_an_archive(self):
        review=policy.load(self.review);semantics=policy.load(self.sem);native=policy.load(self.native)
        bad=deepcopy(semantics);bad['facts']['dictionary'][0]['YesOrNo']='冲销'
        with self.assertRaisesRegex(ValueError,'dictionary'):policy.checked_review(review,bad,native)
        bad=deepcopy(review);text=bad['rows'][0]['typed_full_row_jsonb_text'].replace('"approver_id":null','"approver_id":7')
        bad['rows'][0]['typed_full_row_jsonb_text']=text;bad['rows'][0]['typed_full_row_pg_sha256']=hashlib.sha256(text.encode()).hexdigest()
        with self.assertRaisesRegex(ValueError,'contradicts'):policy.checked_review(bad,semantics,native)
    def test_posted_requires_positive_exact_integer_approval_identity(self):
        good=self.data['m_get.csv'][0]
        self.assertTrue(policy.posted(good))
        for identity in ('-1','nonsense','0','',None,'1.0'):
            row={**good,'approver_id':identity}
            self.assertFalse(policy.posted(row))

if __name__=='__main__':unittest.main()
