import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import rehearse_local_import as coordinator
import prepare_workshop_stock_location_policy as workshop_policy
import validate_source_completeness as gate
from validate_loader_csv_contract import validate_modules
from test_validate_source_completeness import Fixture,write_json


def empty_workshop_policy(overlay,code):
    """No workshop references authorize no opening; retain real CSV/SQL shapes."""
    workshop_policy.write_csv(overlay/workshop_policy.FILES[0],workshop_policy.CROSSWALK_COLUMNS,[])
    workshop_policy.write_csv(overlay/workshop_policy.FILES[1],workshop_policy.AUTHORITY_COLUMNS,[])
    workshop_policy.write_csv(overlay/'goods_workshop_stock_location_review.csv',
        ['goods_legacy_id','goods_code','goods_name','original_owning_warehouse','workshop_code',
         'workshop_name','owning_warehouse','resolution','source_file','source_row'],[])
    manifest=overlay/'goods_excel_manifest.json'
    inventory=json.loads(manifest.read_text(encoding='utf-8'))
    inventory['outputs'].extend({'file':name} for name in (
        'goods_workshop_stock_location_review.csv',*workshop_policy.FILES))
    write_json(manifest,inventory)
    authority=Path(__file__).with_name('reviewed_workshop_stock_location.sql')
    shutil.copyfile(authority,code/authority.name)
    validate_modules([(authority.name,authority.read_bytes())],overlay)


class CoordinatorCompletenessTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.base=Path(self.temp.name);self.f=Fixture(self.base)
        for name in ('clean','overlay','hr','masters','code'):(self.base/name).mkdir()
        self.code=self.base/'code'
        for name in ('source_schema_contract.json','source_profile_contract.json'):
            shutil.copy2(self.base/name,self.code/name)
        for name in ('export_legacy.ps1','export_rehearsal_reference_audit.ps1','export_legacy_goods_media.ps1','export_source_completeness_audit.ps1'):
            (self.code/name).write_text('synthetic frozen exporter',encoding='utf-8')
        (self.code/'mapping-version.txt').write_text('bootstrap-v16\n',encoding='ascii')
        (self.code/'migrate.sh').write_text('# synthetic frozen launcher\n',encoding='ascii')
        for path in self.f.raw.glob('*.csv'):shutil.copy2(path,self.base/'clean'/path.name)
        write_json(self.base/'clean'/'clean_master_manifest.json',{'outputs':[{'file':p.name} for p in self.f.raw.glob('*.csv')]})
        write_json(self.base/'overlay'/'goods_excel_manifest.json',{'outputs':[{'file':'goods_owning_warehouse.csv'}]})
        for name,parent in [('warehouse_crosswalk.csv','clean'),('goods_owning_warehouse.csv','overlay'),
            ('goods_excel_attributes.sql','overlay'),('hr_rehearsal.csv','hr'),('hr_managers.csv','hr')]:
            (self.base/parent/name).write_text('id\n',encoding='utf-8')
        empty_workshop_policy(self.base/'overlay',self.code)
        (self.f.reference/'legacy_injection_machines.csv').write_text('id\n',encoding='utf-8')
        self.arguments=[self.f.raw,self.base/'clean',self.base/'overlay',self.base/'hr',self.base/'final',
                        self.base/'excel',self.f.reference,self.base/'people.xls',self.base/'masters']

    def tearDown(self):self.temp.cleanup()

    def prepare(self,audit):
        raw=gate.load(self.f.raw/'export_manifest.json');raw.update(repositoryCommit='b'*40,sourceSnapshotAsOfUtc='2026-07-24T01:28:50Z')
        with patch.object(coordinator,'HERE',self.code),patch.object(coordinator,'verify_frozen_source',return_value='c'*40),\
             patch.object(coordinator,'verify_raw',return_value=raw),patch.object(coordinator,'verify_layers'),\
             patch.object(coordinator,'verify_reference_masters',return_value={'outputs':[]}),\
             patch.object(coordinator,'validate_execution_inputs',return_value={'validated':True}),\
             patch.object(coordinator.validate_source_table_coverage,'validate_source_table_coverage',return_value={'validated':True}):
            return coordinator.prepare_inputs(*self.arguments,completeness_audit=audit)

    def test_missing_fresh_audit_is_rejected_before_creating_output(self):
        with self.assertRaisesRegex(ValueError,'fresh SHA-bound'):self.prepare(None)
        self.assertFalse((self.base/'final').exists())

    def test_drift_in_fresh_audit_blocks_prepare_before_any_copy(self):
        self.f.items.append(dict(self.f.items[0],ItemID='9901',ItemclassID='99'));self.f.write()
        with self.assertRaisesRegex(ValueError,'Unreviewed nonempty'):self.prepare(self.f.audit)
        self.assertFalse((self.base/'final').exists())

    def test_prepare_binds_aux_and_policy_shas_without_counting_archived_csv_as_loader_files(self):
        result=self.prepare(self.f.audit);provenance=result['provenance']
        self.assertEqual(provenance['sourceCompleteness']['proof'],self.f.validate())
        for name in ('source_schema_contract.json','source_profile_contract.json','export_source_completeness_audit.ps1','mapping-version.txt','migrate.sh','reviewed_workshop_stock_location.sql'):
            self.assertEqual(provenance['scripts'][name],gate.digest(self.code/name))
        imported_names={row['file'] for row in result['files']}
        self.assertFalse(imported_names&gate.FILES)
        self.assertEqual(provenance['sourceCompleteness']['directory'],str(self.f.audit.resolve()))
        self.assertNotIn('columns',provenance['sourceCompleteness']['proof'])

    def test_contracts_are_explicit_frozen_tracked_paths_with_windows_sized_git_batches(self):
        calls=[]
        with patch.object(coordinator,'HERE',self.code),patch.object(coordinator,'ROOT',self.base),\
             patch.object(coordinator.subprocess,'run',side_effect=lambda args,**kw:calls.append(args)),\
             patch.object(coordinator.subprocess,'check_output',side_effect=lambda args,**kw:'c'*40 if 'rev-parse' in args else ''):
            coordinator.verify_frozen_source()
        tracked=[arg for args in calls for arg in args[args.index('--')+1:]]
        for name in ('source_schema_contract.json','source_profile_contract.json','export_source_completeness_audit.ps1','mapping-version.txt','migrate.sh'):
            self.assertIn('code/'+name,tracked)
        self.assertTrue(all(len(args[args.index('--')+1:])<=60 for args in calls))

    def test_dirty_reviewed_contract_is_rejected_by_existing_freeze_gate(self):
        with patch.object(coordinator,'HERE',self.code),patch.object(coordinator,'ROOT',self.base),\
             patch.object(coordinator.subprocess,'run'),\
             patch.object(coordinator.subprocess,'check_output',return_value=' M code/source_profile_contract.json\n'):
            with self.assertRaisesRegex(ValueError,'uncommitted bytes'):coordinator.verify_frozen_source()


if __name__=='__main__':unittest.main()
