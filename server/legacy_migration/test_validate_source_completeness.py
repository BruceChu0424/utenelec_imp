import copy
import csv
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import validate_source_completeness as gate


def write_json(path,value):
    path.write_bytes((json.dumps(value,ensure_ascii=True,indent=2)+'\n').encode())


def write_csv(path,header,rows,delimiter='|'):
    with path.open('w',encoding='utf-8',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=header,delimiter=delimiter,lineterminator='\n')
        writer.writeheader();writer.writerows(rows)


class Fixture:
    def __init__(self,base):
        self.audit=base/'audit';self.raw=base/'raw';self.reference=base/'reference'
        for path in (self.audit,self.raw,self.reference):path.mkdir()
        self.schema_path=base/'source_schema_contract.json';self.profile_path=base/'source_profile_contract.json'
        self.generator_path=base/'export_source_completeness_audit.ps1';self.generator_path.write_text('synthetic frozen exporter',encoding='utf-8')
        self.items=[]
        for kind in gate.PARTITIONS:
            self.items.append(dict(ItemID=str(kind*100+1),ItemclassID=str(kind),Number='C'+str(kind),
                Name='注塑车间' if kind==12 else 'Synthetic'+str(kind),ParentID='41' if kind==5 else '0',Level='1'))
        self.parts=[dict(ID='1',PartNumber='OLD_PERMISSION',IsOperator='True',OperatorORGroupId='2',Visible='True')]
        self.stock=[dict(StockID='1',GoodsID='2',Year='2012',ColorID='0',QTY='0',Total='0',APrice='0')]
        self.accounts=[dict(legacy_id='1',code='ACC1',name='现金A',status='使用',parent_legacy_id='1001',balance_current='100')]
        self.workshops=[dict(legacy_id='90',source_name='注塑车间')]
        self.columns=[dict(schema_name='dbo',table_name=table,column_id='1',column_name='ID',data_type='int',
            max_length='4',precision='10',scale='0',is_nullable='False',is_identity='False',is_computed='False')
            for table in ('SystemItem','SystemPart','MK_StockGoods','B_WorkShop','M_Acc')]
        self.exported={}
        for kind,(name,_) in gate.PARTITIONS.items():
            if name:
                self.exported[name]=[dict(legacy_id=row['ItemID'],code=row['Number'],name=row['Name'],
                    **({} if kind==5 else {'parent_legacy':row['ParentID']})) for row in self.items if int(row['ItemclassID'])==kind]
        self.raw_doc={'sourceBackupSha256':'a'*64,'sourceSnapshotAsOfUtc':'2026-07-24T01:28:50Z','files':[]}
        self.manifest={'format':'source-completeness-audit-v1','updateability':'READ_ONLY','isolation':'Serializable',
            'source_backup_sha256':'a'*64,'backup_file':2,'files':[],
            'generator_sha256':gate.digest(self.generator_path),'source_snapshot_as_of_utc':'2026-07-24T01:28:50Z'}
        self.schema={'format':'legacy-source-schema-contract-v1','fields':gate.SCHEMA_FIELDS,'columns':gate.schema_rows(self.columns)}
        self.profile={'format':'legacy-source-profile-contract-v1','reviewed_accounts':[
            dict(legacy_id=1,code_name_status_sha256=gate.account_fingerprint(self.accounts[0]),account_type='CASH',currency_legacy_id=1)],
            'reviewed_workshop_name_sha256':[hashlib.sha256('注塑车间'.encode()).hexdigest()],
            'mk_stock_year_ceiling':2012,'mk_stock_zero_fact_columns':['APrice','QTY','Total']}
        self.write()

    def write(self):
        for name,rows in self.exported.items():
            header=['legacy_id','name','code'] if name=='legacy_departments.csv' else ['legacy_id','parent_legacy','code','name']
            write_csv(self.raw/name,header,rows)
        write_csv(self.raw/'m_acc.csv',list(self.accounts[0]) if self.accounts else ['legacy_id','code','name','status','parent_legacy_id','balance_current'],self.accounts)
        write_csv(self.raw/'m_style.csv',['legacy_id','style_class_id','code','name','parent_legacy'],[])
        self.raw_doc['files']=[dict(file=p.name,bytes=p.stat().st_size,sha256=gate.digest(p),rows=len(gate.records(p))) for p in sorted(self.raw.glob('*.csv'))]
        write_json(self.raw/'export_manifest.json',self.raw_doc)
        groups={}
        for row in self.items:groups[int(row['ItemclassID'])]=groups.get(int(row['ItemclassID']),0)+1
        data={'source_columns.csv':self.columns,'system_item_full.csv':self.items,
              'system_item_class_counts.csv':[dict(item_class_id=str(k),actual_rows=str(v)) for k,v in sorted(groups.items())],
              'system_part_full.csv':self.parts,'mk_stock_goods_full.csv':self.stock}
        for name,rows in data.items():
            write_csv(self.audit/name,gate.AUDIT_HEADERS.get(name,list(self.stock[0]) if self.stock else ['StockID','GoodsID','Year','ColorID','APrice','QTY','Total']),rows)
        self.manifest['raw_export_manifest_sha256']=gate.digest(self.raw/'export_manifest.json')
        self.manifest['files']=[dict(file=p.name,bytes=p.stat().st_size,sha256=gate.digest(p),rows=len(data[p.name])) for p in sorted(self.audit.glob('*.csv'))]
        write_json(self.audit/'audit-manifest.json',self.manifest)
        counts={'systemitem':len(self.items),'systempart':len(self.parts),'mk_stockgoods':len(self.stock),'b_workshop':len(self.workshops),'m_acc':len(self.accounts)}
        tables=sorted({(r['schema_name'],r['table_name']) for r in self.columns})
        write_csv(self.reference/'source_table_disposition_exact.csv',['schema_name','table_name','actual_rows','disposition','reason'],[
            dict(schema_name=s,table_name=t,actual_rows=str(counts.get(t.casefold(),0)),disposition='导入',reason='synthetic') for s,t in tables],',')
        write_csv(self.reference/'legacy_workshops_source.csv',['legacy_id','source_name'],self.workshops,',')
        write_json(self.schema_path,self.schema);write_json(self.profile_path,self.profile)

    def validate(self):
        return gate.validate_source_completeness(self.audit,self.raw/'export_manifest.json',self.reference,self.schema_path,self.profile_path,self.generator_path)


class CompletenessGateTest(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.f=Fixture(Path(self.temp.name))
    def tearDown(self):self.temp.cleanup()

    def test_complete_source_has_small_counts_and_hashes_without_private_row_values(self):
        proof=self.f.validate();encoded=json.dumps(proof)
        self.assertEqual(proof['schema_tables'],5);self.assertEqual(proof['system_item_rows'],7)
        self.assertEqual(proof['system_item_partitions']['10']['policy'],'ARCHIVE_ACCOUNT_CATEGORY_EVIDENCE')
        self.assertEqual(proof['system_item_partitions']['12']['policy'],'ARCHIVE_WORKSHOP_DICTIONARY_MIRROR')
        self.assertTrue(proof['old_authorization_not_imported']);self.assertFalse(proof['workshop_dictionary_namespace_merged'])
        for private in ['Synthetic','现金A','OLD_PERMISSION','code_name_status_sha256']:
            self.assertNotIn(private,encoded)
        self.assertLess(len(encoded),4000)

    def test_new_removed_type_and_flag_schema_changes_are_blocked_even_with_resealed_evidence(self):
        original=copy.deepcopy(self.f.columns)
        changes=[lambda rows:rows.append(dict(rows[0],column_id='2',column_name='NewValue')),
                 lambda rows:rows.pop(),lambda rows:rows[0].update(data_type='bigint',max_length='8'),
                 lambda rows:rows[0].update(is_nullable='True'),lambda rows:rows[0].update(is_identity='True')]
        for change in changes:
            self.f.columns=copy.deepcopy(original);change(self.f.columns);self.f.write()
            with self.subTest(change=change),self.assertRaisesRegex(ValueError,'schema changed'):self.f.validate()

    def test_schema_duplicate_ordinal_cannot_hide_as_another_column(self):
        self.f.columns.append(dict(self.f.columns[0],column_name='Duplicate'));self.f.write()
        with self.assertRaisesRegex(ValueError,'repeated'):self.f.validate()

    def test_new_nonempty_system_item_partition_cannot_be_silently_unselected(self):
        self.f.items.append(dict(self.f.items[0],ItemID='9901',ItemclassID='99'));self.f.write()
        with self.assertRaisesRegex(ValueError,'Unreviewed nonempty SystemItem'):self.f.validate()

    def test_a_dropped_selected_partition_row_is_detected(self):
        self.f.exported['goods_categories.csv']=[];self.f.write()
        with self.assertRaisesRegex(ValueError,'not fully exported'):self.f.validate()

    def test_a_changed_selected_partition_parent_is_detected(self):
        self.f.exported['client_categories.csv'][0]['parent_legacy']='919';self.f.write()
        with self.assertRaisesRegex(ValueError,'not fully exported'):self.f.validate()

    def test_historical_department_without_projected_parent_keeps_full_original_in_archive(self):
        self.assertNotIn('parent_legacy',self.f.exported['legacy_departments.csv'][0])
        self.assertEqual(self.f.validate()['system_item_partitions']['5']['rows'],1)

    def test_class12_same_name_does_not_require_equal_workshop_ids(self):
        self.assertNotEqual(self.f.items[5]['ItemID'],self.f.workshops[0]['legacy_id'])
        self.assertFalse(self.f.validate()['workshop_dictionary_namespace_merged'])

    def test_class12_new_or_ambiguous_mirror_is_blocked(self):
        self.f.items[5]['Name']='Different';self.f.write()
        with self.assertRaisesRegex(ValueError,'workshop-name mirror'):self.f.validate()

    def test_new_machine_and_line_counts_are_dynamic(self):
        for i,name in enumerate(['注塑19号机','安装58线']):
            self.f.workshops.append(dict(legacy_id=str(91+i),source_name=name))
            self.f.items.append(dict(self.f.items[5],ItemID=str(1291+i),Name=name))
        self.f.write();self.assertEqual(self.f.validate()['system_item_partitions']['12']['rows'],3)

    def test_a_new_ordinary_workshop_requires_mapping_review(self):
        self.f.workshops.append(dict(legacy_id='99',source_name='New Factory'))
        self.f.items.append(dict(self.f.items[5],ItemID='1299',Name='New Factory'));self.f.write()
        with self.assertRaisesRegex(ValueError,'New ordinary workshop'):self.f.validate()

    def test_more_zero_scope_archived_stock_rows_are_allowed_without_fixed_row_count(self):
        self.f.stock.append(dict(self.f.stock[0],GoodsID='55',Year='2011'));self.f.write()
        self.assertEqual(self.f.validate()['mk_stock_archive_rows'],2)

    def test_new_stock_quantity_amount_price_and_year_require_review(self):
        for field,value in [('QTY','1'),('Total','0.01'),('APrice','2'),('Year','2013'),('QTY','NaN'),('QTY','')]:
            old=self.f.stock[0][field];self.f.stock[0][field]=value;self.f.write()
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'zero-balance scope'):self.f.validate()
            self.f.stock[0][field]=old

    def test_uncovered_stock_fact_column_is_rejected_instead_of_ignored(self):
        self.f.stock[0]['FutureMovement']='3';self.f.write()
        with self.assertRaisesRegex(ValueError,'fact columns'):self.f.validate()

    def test_new_source_account_has_no_default_currency_or_general_type(self):
        self.f.accounts.append(dict(self.f.accounts[0],legacy_id='2',name='USD Account'));self.f.write()
        with self.assertRaisesRegex(ValueError,'requires reviewed type/currency'):self.f.validate()

    def test_renamed_recoded_or_status_changed_account_requires_review(self):
        for field in ['name','code','status']:
            old=self.f.accounts[0][field];self.f.accounts[0][field]='Changed';self.f.write()
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'classification review'):self.f.validate()
            self.f.accounts[0][field]=old

    def test_financial_amount_growth_does_not_require_a_fixed_source_row_or_balance(self):
        self.f.accounts[0]['balance_current']='9000000000';self.f.write()
        self.assertEqual(self.f.validate()['reviewed_accounts'],1)

    def test_unsupported_currency_cannot_be_added_only_to_the_reviewed_profile(self):
        self.f.profile['reviewed_accounts'][0]['currency_legacy_id']=77;self.f.write()
        with self.assertRaisesRegex(ValueError,'not supported'):self.f.validate()

    def test_cheque_projection_matches_exact_legacy_case_semantics(self):
        self.assertEqual(gate.existing_account_projection(dict(name='支票',status='禁用')),('CHECK',1))
        self.assertEqual(gate.existing_account_projection(dict(name='支票',status='使用')),('FOREIGN_CHECK',1))
        self.assertEqual(gate.existing_account_projection(dict(name='支票新名称',status='使用')),('GENERAL',1))

    def test_account_parent_must_resolve_to_its_original_namespace(self):
        self.f.accounts[0]['parent_legacy_id']='1201';self.f.write()
        with self.assertRaisesRegex(ValueError,'class10'):self.f.validate()

    def test_duplicate_system_item_and_archived_permission_identities_are_blocked(self):
        for collection in [self.f.items,self.f.parts]:
            collection.append(dict(collection[0]));self.f.write()
            with self.assertRaisesRegex(ValueError,'identity is repeated'):self.f.validate()
            collection.pop()

    def test_archive_permission_row_growth_is_preserved_without_importing_grants(self):
        self.f.parts.append(dict(self.f.parts[0],ID='2',PartNumber='FUTURE_OLD_GRANT'));self.f.write()
        proof=self.f.validate();self.assertEqual(proof['system_part_archive_rows'],2);self.assertTrue(proof['old_authorization_not_imported'])

    def test_wrong_backup_raw_manifest_or_physical_readonly_claim_is_rejected(self):
        for field,value in [('source_backup_sha256','b'*64),('raw_export_manifest_sha256','b'*64),('updateability','READ_WRITE'),('isolation','ReadCommitted')]:
            self.f.write();m=gate.load(self.f.audit/'audit-manifest.json');m[field]=value;write_json(self.f.audit/'audit-manifest.json',m)
            with self.subTest(field=field),self.assertRaises(ValueError):self.f.validate()

    def test_evidence_hash_count_and_exact_inventory_are_mandatory(self):
        for mutation in ['hash','count','extra','bool']:
            self.f.write();m=gate.load(self.f.audit/'audit-manifest.json')
            if mutation=='hash':m['files'][0]['sha256']='b'*64
            if mutation=='count':m['files'][0]['rows']+=1
            if mutation=='extra':m['files'].append(dict(m['files'][0],file='new.csv'))
            if mutation=='bool':m['files'][0]['rows']=True
            write_json(self.f.audit/'audit-manifest.json',m)
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):self.f.validate()

    def test_unfrozen_audit_generator_is_rejected(self):
        self.f.generator_path.write_text('modified exporter',encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'generator differs'):self.f.validate()

    def test_wrong_or_absent_source_cutoff_is_rejected(self):
        for cutoff in [None,'2026-07-25T01:28:50Z']:
            self.f.manifest['source_snapshot_as_of_utc']=cutoff;self.f.write()
            with self.subTest(cutoff=cutoff),self.assertRaisesRegex(ValueError,'cutoff differs'):self.f.validate()

    def test_full_table_inventory_and_complete_schema_must_match(self):
        path=self.f.reference/'source_table_disposition_exact.csv'
        rows=gate.records(path,',');rows[0]['actual_rows']='999';write_csv(path,list(rows[0]),rows,',')
        # Select the full-source table independently of sort position.
        rows=gate.records(path,',')
        next(r for r in rows if r['table_name']=='SystemItem')['actual_rows']='999'
        write_csv(path,list(rows[0]),rows,',')
        with self.assertRaisesRegex(ValueError,'full source rows'):self.f.validate()

    def test_partial_account_or_workshop_export_cannot_hide_new_source_rows(self):
        path=self.f.reference/'source_table_disposition_exact.csv'
        for table in ['M_Acc','B_WorkShop']:
            self.f.write();rows=gate.records(path,',')
            next(r for r in rows if r['table_name']==table)['actual_rows']='999'
            write_csv(path,list(rows[0]),rows,',')
            with self.subTest(table=table),self.assertRaisesRegex(ValueError,'full-table export'):self.f.validate()

    def test_bound_apply_proof_rejects_changed_evidence_and_missing_binding(self):
        args=(self.f.raw/'export_manifest.json',self.f.reference,self.f.schema_path,self.f.profile_path,self.f.generator_path)
        binding={'directory':str(self.f.audit),'proof':self.f.validate()}
        self.assertEqual(gate.validate_bound_source_completeness(binding,*args),binding['proof'])
        self.f.accounts[0]['balance_current']='999';self.f.write()
        with self.assertRaisesRegex(ValueError,'proof drift'):gate.validate_bound_source_completeness(binding,*args)
        with self.assertRaisesRegex(ValueError,'lacks its frozen'):gate.validate_bound_source_completeness(None,*args)


if __name__=='__main__':unittest.main()
