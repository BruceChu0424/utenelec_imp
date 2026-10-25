import copy,hashlib,json,unittest
import prepare_goods_excel as subject

class CurrentDefaultIntegrityTest(unittest.TestCase):
    def setUp(self):
        self.fields={name:name for name in subject.ALIASES}
        self.row={name:'' for name in self.fields}
        self.row.update(legacy_id='17',code='REAL-GOOD',name='真实货品',unit_legacy_id='1',status='使用',price='12.3')
        self.dictionaries={name:set() for name in ('unit.csv','color.csv','mould.csv','client.csv','supplier.csv')}
        self.dictionaries['unit.csv']={'1'}
    def apply(self):
        return subject.normalize_current_default_references([self.row],self.fields,self.dictionaries,{17:self.original},[],[])
    def test_missing_optional_defaults_are_archived_once_and_only_their_columns_change(self):
        self.row.update(color_legacy_id='94',mould_legacy_id='2364',vend_legacy_id='392')
        self.original=copy.deepcopy(self.row);repairs=self.apply()
        self.assertEqual(len(repairs),3)
        self.assertEqual({k for k in self.original if self.row[k]!=self.original[k]}, {'color_legacy_id','mould_legacy_id','vend_legacy_id'})
        self.assertTrue(all(r['prepared_row']==self.original for r in repairs))
        digest=hashlib.sha256(json.dumps(self.original,sort_keys=True,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()
        self.assertTrue(all(r['prepared_row_sha256']==digest for r in repairs))
        self.assertEqual(self.apply(),[])
    def test_exact_real_master_and_excel_negative_master_anchors_remain(self):
        self.row.update(color_legacy_id='94',mould_legacy_id='-200001',vend_legacy_id='392',vend2_legacy_id='393')
        self.dictionaries.update({'color.csv':{'94'},'mould.csv':{'-200001'},'supplier.csv':{'392','393'}})
        self.original=copy.deepcopy(self.row)
        self.assertEqual(self.apply(),[]);self.assertEqual(self.row,self.original)
    def test_zero_and_empty_optional_defaults_are_already_unset(self):
        self.row.update(color_legacy_id='0',mould_legacy_id='',vend_legacy_id='0')
        self.original=copy.deepcopy(self.row)
        self.assertEqual(self.apply(),[]);self.assertEqual(self.row,self.original)
    def test_missing_nonzero_unit_is_a_failure_not_a_cleared_quantity_basis(self):
        self.row['unit_legacy_id']='999';self.original=copy.deepcopy(self.row)
        with self.assertRaisesRegex(ValueError,'base unit requires source repair'):self.apply()
        self.assertEqual(self.row,self.original)
    def test_history_anchor_not_present_in_real_dictionary_cannot_be_current_default(self):
        self.row['vend_legacy_id']='392';self.original=copy.deepcopy(self.row)
        result=self.apply();self.assertEqual(len(result),1);self.assertEqual(self.row['vend_legacy_id'],'')
        self.assertEqual(result[0]['source_input_row']['vend_legacy_id'],'392')
    def test_nonmatching_excel_code_cannot_suggest_replacement(self):
        self.row['mould_legacy_id']='2364';self.original=copy.deepcopy(self.row)
        rec={'file':'p.xls','row':2,'values':{'产品编号':'OTHER-GOOD','模具编号':'SIMILAR'}}
        result=subject.normalize_current_default_references([self.row],self.fields,self.dictionaries,{17:self.original},[],[rec])
        self.assertEqual(self.row['mould_legacy_id'],'');self.assertEqual(result[0]['exact_excel_identity_records'],[])

if __name__=='__main__':unittest.main()
