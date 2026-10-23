from copy import deepcopy
from decimal import Decimal
import unittest
from finance_archive_rules import expected_archive,verify_archive_and_coverage

def row(identity=5,account=4,family=0):
    return {'typed_source':{'legacy_id':identity,'bill_no':'原号"|\n','check_no':'','remark':None,
            'company':'中文','in_total':Decimal('12345678901234.5678'),'out_total':Decimal('0.0000'),
            'bill_date':'2001-01-01T00:00:00+08:00','out_date':None,'acc_id':account,'source':'',
            'b_style':family,'bill_id':999999},'source_row_number':2,'source_row_sha256':'b'*64}

class FinanceArchiveRulesTest(unittest.TestCase):
    def test_keeps_full_typed_values_and_both_reasons(self):
        original=row();result=expected_archive([original],{51},'a'*64)
        self.assertEqual(result[0]['typed_source'],original['typed_source'])
        self.assertIsNone(result[0]['typed_source']['remark'])
        self.assertEqual(result[0]['typed_source']['check_no'],'')
        self.assertIsInstance(result[0]['typed_source']['in_total'],Decimal)
        self.assertEqual(result[0]['reason_codes'],['MISSING_ORIGINAL_ACCOUNT','UNSUPPORTED_ORIGINAL_DOCUMENT_FAMILY'])
    def test_supplemented_real_account_and_valid_family_restore_normal_path(self):
        self.assertEqual(expected_archive([row(account=4,family=20)],{4},'a'*64),[])
    def test_missing_upstream_document_is_not_an_archive_reason(self):
        self.assertEqual(expected_archive([row(account=51,family=20)],{51},'a'*64),[])
    def test_unknown_family_with_existing_account_archives_only_for_family(self):
        result=expected_archive([row(account=51)],{51},'a'*64)
        self.assertEqual(result[0]['reason_codes'],['UNSUPPORTED_ORIGINAL_DOCUMENT_FAMILY'])
    def test_no_fixed_legacy_id_or_old_date_whitelist(self):
        result=expected_archive([row(identity=999999,family=23)],{51},'a'*64)
        self.assertEqual(result[0]['source_legacy_id'],999999)
    def test_duplicates_and_float_are_rejected(self):
        with self.assertRaises(ValueError):expected_archive([row(),row()],{51},'a'*64)
        bad=row();bad['typed_source']['in_total']=.1
        with self.assertRaises(ValueError):expected_archive([bad],{51},'a'*64)
    def test_complete_coverage_and_hashes_pass(self):
        expected=expected_archive([row()],{51},'a'*64)
        result=verify_archive_and_coverage(expected,deepcopy(expected),[5,99],[99],[99],[51],[51])
        self.assertTrue(result['source_equals_active_plus_archive'])
    def test_any_source_value_or_reason_or_hash_tampering_fails(self):
        expected=expected_archive([row()],{51},'a'*64)
        for field,value in [('source_row_sha256','c'*64),('reason_codes',[]),('typed_source',{**expected[0]['typed_source'],'check_no':None})]:
            saved=deepcopy(expected);saved[0][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):verify_archive_and_coverage(expected,saved,[5,99],[99],[99],[51],[51])
    def test_archive_in_active_proof_or_fake_account_fails(self):
        expected=expected_archive([row()],{51},'a'*64)
        with self.assertRaises(ValueError):verify_archive_and_coverage(expected,expected,[5,99],[99],[5,99],[51],[51])
        with self.assertRaises(ValueError):verify_archive_and_coverage(expected,expected,[5,99],[99],[99],[51],[4,51])

if __name__=='__main__':unittest.main()
