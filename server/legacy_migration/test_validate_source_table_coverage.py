import csv
from decimal import Decimal
import json
from pathlib import Path
import tempfile
import unittest

import validate_source_table_coverage as gate


class Fixture:
    def __init__(self,root):
        self.reference=root/'reference';self.reference.mkdir();self.raw=root/'export_manifest.json'
        self.raw_data={'formatVersion':4,'target':'All','sourceBackupSha256':'a'*64,'sourceSnapshotAsOfUtc':'2026-07-24T01:28:50Z'}
        self.raw.write_text(json.dumps(self.raw_data),encoding='utf-8')
        self.rows=[{'schema_name':'dbo','table_name':'B_Goods','actual_rows':'2','disposition':'导入','reason':'source export'},
                   {'schema_name':'dbo','table_name':'EmptyTable','actual_rows':'0','disposition':'来源为空','reason':'exact empty source'},
                   {'schema_name':'dbo','table_name':'Sys_Group','actual_rows':'1','disposition':'旧账号权限丢弃','reason':'old grants never replace new authorization'}]
        self.summary={'database_updateability':'READ_ONLY','source_export_manifest_sha256':gate.digest(self.raw),
                      'source_backup_sha256':'a'*64,'source_snapshot_as_of_utc':'2026-07-24T01:28:50Z',
                      'count_method':'COUNT_BIG(*) per user table','table_count':3,'nonempty_table_count':2,'total_rows':3.0}
        self.write()

    def write(self,counts=False):
        if counts:
            self.summary.update(table_count=len(self.rows),nonempty_table_count=sum(int(r['actual_rows'])>0 for r in self.rows),total_rows=float(sum(int(r['actual_rows']) for r in self.rows)))
        self.write_csv()
        (self.reference/gate.SUMMARY).write_text(json.dumps(self.summary),encoding='utf-8')

    def write_csv(self,fields=None):
        with (self.reference/gate.INVENTORY).open('w',encoding='utf-8-sig',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=fields or ['schema_name','table_name','actual_rows','disposition','reason'])
            writer.writeheader();writer.writerows(self.rows)

    def validate(self,expected=None):return gate.validate_source_table_coverage(self.reference,self.raw,expected)

    def binding(self):return {str(self.reference/name):gate.digest(self.reference/name) for name in (gate.SUMMARY,gate.INVENTORY)}


class SourceCoverageTests(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.f=Fixture(Path(self.temp.name))
    def tearDown(self):self.temp.cleanup()

    def test_current_style_integral_float_summary_counts_are_exact_and_dynamic(self):
        proof=self.f.validate();self.assertEqual(proof['table_count'],3);self.assertEqual(proof['total_rows'],3)
        self.assertEqual(proof['file_sha256'][gate.INVENTORY],gate.digest(self.f.reference/gate.INVENTORY))

    def test_new_empty_table_is_allowed_without_fixed_table_count(self):
        self.f.rows.append({'schema_name':'new_schema','table_name':'FutureEmpty','actual_rows':'0','disposition':'来源为空','reason':'empty now; must reclassify if populated'})
        self.f.write(counts=True);self.assertEqual(self.f.validate()['table_count'],4)

    def test_new_nonempty_unclassified_table_fails_even_with_matching_new_totals(self):
        self.f.rows.append({'schema_name':'dbo','table_name':'FutureBusiness','actual_rows':'7','disposition':'未知待核验','reason':'not reviewed'})
        self.f.write(counts=True)
        with self.assertRaisesRegex(gate.CoverageError,'unclassified'):self.f.validate()

    def test_case_insensitive_duplicate_qualified_identity_fails(self):
        self.f.rows.append(dict(self.f.rows[0],schema_name='DBO',table_name='b_goods'))
        self.f.write(counts=True)
        with self.assertRaisesRegex(gate.CoverageError,'Duplicate'):self.f.validate()

    def test_nonempty_other_schema_cannot_be_mistaken_for_dbo_export(self):
        self.f.rows[0]['schema_name']='other';self.f.write()
        with self.assertRaisesRegex(gate.CoverageError,'schema'):self.f.validate()

    def test_missing_or_duplicate_csv_header_fails(self):
        for header in ['schema_name,table_name,actual_rows,disposition\n','schema_name,table_name,actual_rows,disposition,disposition\n']:
            (self.f.reference/gate.INVENTORY).write_text(header,encoding='utf-8')
            with self.assertRaisesRegex(gate.CoverageError,'columns'):self.f.validate()

    def test_negative_fraction_boolean_or_blank_csv_count_fails(self):
        for value in ['-1','1.1','True','', '+1']:
            self.f.rows[0]['actual_rows']=value;self.f.write()
            with self.subTest(value=value),self.assertRaises(gate.CoverageError):self.f.validate()

    def test_unknown_disposition_and_incorrect_empty_labels_fail(self):
        for index,value in [(0,'NEW_POLICY'),(0,'来源为空'),(1,'导入')]:
            previous=self.f.rows[index]['disposition'];self.f.rows[index]['disposition']=value;self.f.write()
            with self.subTest(value=value),self.assertRaises(gate.CoverageError):self.f.validate()
            self.f.rows[index]['disposition']=previous

    def test_explicit_policy_exclusions_are_classified_not_guessed_as_imports(self):
        for label in ['旧账号权限丢弃','历史配置归档','派生缓存归档','导入及来源对照']:
            self.f.rows[0]['disposition']=label;self.f.write();self.assertTrue(self.f.validate()['validated'])

    def test_missing_reason_or_blank_identity_fails(self):
        for field in ('schema_name','table_name','reason'):
            previous=self.f.rows[0][field];self.f.rows[0][field]='';self.f.write()
            with self.subTest(field=field),self.assertRaises(gate.CoverageError):self.f.validate()
            self.f.rows[0][field]=previous

    def test_summary_totals_must_match_every_csv_row(self):
        for field in ('table_count','nonempty_table_count','total_rows'):
            previous=self.f.summary[field];self.f.summary[field]=99;self.f.write()
            with self.subTest(field=field),self.assertRaisesRegex(gate.CoverageError,'count differs'):self.f.validate()
            self.f.summary[field]=previous

    def test_nonfinite_fraction_or_boolean_summary_counts_fail(self):
        for value in (True,1.5,float('nan'),float('inf'),-1):
            self.f.summary['total_rows']=value;self.f.write()
            with self.subTest(value=value),self.assertRaises(gate.CoverageError):self.f.validate()

    def test_integer_float_and_decimal_count_api(self):
        for value in (3,3.0,Decimal('3.0')):self.assertEqual(gate.exact_integer(value,'total_rows'),3)
        for value in (True,Decimal('NaN'),Decimal('Infinity'),3.1):
            with self.assertRaises(gate.CoverageError):gate.exact_integer(value,'total_rows')

    def test_readonly_manifest_backup_cutoff_and_count_method_are_bound(self):
        changes=[('database_updateability','READ_WRITE'),('source_export_manifest_sha256','b'*64),
                 ('source_backup_sha256','b'*64),('source_snapshot_as_of_utc','2026-07-24T01:28:51Z'),
                 ('source_snapshot_as_of_utc','2026-07-24T01:28:50'),('count_method','estimated rows')]
        for field,value in changes:
            previous=self.f.summary[field];self.f.summary[field]=value;self.f.write()
            with self.subTest(field=field),self.assertRaises(gate.CoverageError):self.f.validate()
            self.f.summary[field]=previous

    def test_utc_equivalent_cutoff_is_allowed(self):
        self.f.summary['source_snapshot_as_of_utc']='2026-07-24T09:28:50+08:00';self.f.write();self.assertTrue(self.f.validate()['validated'])

    def test_apply_file_hash_binding_rejects_tampering_even_when_counts_unchanged(self):
        expected=self.f.validate()['file_sha256'];self.f.rows[0]['reason']='different reviewed text';self.f.write()
        with self.assertRaisesRegex(gate.CoverageError,'file SHA'):self.f.validate(expected)

    def test_bound_apply_revalidates_logical_proof_and_requires_both_files(self):
        expected=self.f.validate();binding=self.f.binding()
        self.assertEqual(gate.validate_bound_source_table_coverage(binding,self.f.raw,expected),expected)
        for bad in ({},dict(expected,total_rows=100)):
            with self.assertRaises(gate.CoverageError):gate.validate_bound_source_table_coverage(binding,self.f.raw,bad)
        binding.pop(str(self.f.reference/gate.INVENTORY))
        with self.assertRaises(gate.CoverageError):gate.validate_bound_source_table_coverage(binding,self.f.raw,expected)

    def test_empty_inventory_and_csv_wrong_row_width_fail(self):
        self.f.rows=[];self.f.write(counts=True)
        with self.assertRaisesRegex(gate.CoverageError,'inventory is empty'):self.f.validate()
        with (self.f.reference/gate.INVENTORY).open('a',encoding='utf-8') as stream:stream.write('dbo,X,1,导入,reason,extra\n')
        with self.assertRaises(gate.CoverageError):self.f.validate()


if __name__=='__main__':unittest.main()
