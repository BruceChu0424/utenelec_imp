import csv
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from rehearse_local_import import Database, csv_record, digest, verify_layers,prepare_inputs,read_mapping_version


class LocalRehearsalSafetyTest(unittest.TestCase):
    def test_mapping_version_is_read_from_the_frozen_single_authority(self):
        with tempfile.TemporaryDirectory() as root:
            authority = Path(root) / 'mapping-version.txt'
            with patch('rehearse_local_import.HERE', Path(root)):
                for version in ('bootstrap-v14', 'bootstrap-v15', 'bootstrap-v100'):
                    authority.write_text(version + '\n', encoding='utf-8-sig')
                    self.assertEqual(version, read_mapping_version())
                for invalid in ('', 'bootstrap-v0', 'bootstrap-v15;SELECT 1', 'bootstrap-v15\nbootstrap-v14'):
                    authority.write_text(invalid, encoding='utf-8')
                    with self.assertRaises(ValueError):
                        read_mapping_version()

    def test_normal_and_remote_targets_are_rejected(self):
        for container,name in [('company-postgres','uten_imp_rehearsal'),
                               ('uten-imp-postgres','uten_imp'),
                               ('uten-imp-postgres','uten_imp_rehearsal;drop')]:
            with self.subTest(container=container,name=name), self.assertRaises(ValueError):
                Database(container,name,'uten')

    def test_remote_docker_context_is_rejected_even_with_local_container_name(self):
        db=Database('uten-imp-postgres','uten_imp_rehearsal_test','uten')
        with patch('rehearse_local_import.subprocess.check_output',return_value='ssh://company\n'), \
             patch.dict('os.environ',{},clear=True), self.assertRaises(ValueError):
            db.verify_local()

    def test_remote_docker_host_override_is_rejected(self):
        db=Database('uten-imp-postgres','uten_imp_rehearsal_test','uten')
        with patch('rehearse_local_import.subprocess.check_output',return_value='npipe:////./pipe/local\n'), \
             patch.dict('os.environ',{'DOCKER_HOST':'tcp://company:2376'},clear=True), self.assertRaises(ValueError):
            db.verify_local()

    def test_remote_context_cannot_hide_behind_local_host_variable(self):
        db=Database('uten-imp-postgres','uten_imp_rehearsal_test','uten')
        with patch('rehearse_local_import.subprocess.check_output',return_value='ssh://company\n'), \
             patch.dict('os.environ',{'DOCKER_CONTEXT':'company','DOCKER_HOST':'npipe:////./pipe/local'},clear=True), \
             self.assertRaises(ValueError):
            db.verify_local()

    def test_csv_integrity_includes_quoted_newlines_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'goods.csv'
            with path.open('w',encoding='utf-8',newline='') as stream:
                writer=csv.writer(stream,delimiter='|',lineterminator='\n')
                writer.writerow(['id','name'])
                writer.writerow(['1','two\nlines|quoted'])
            self.assertEqual(1,csv_record(path)['rows'])
            before=digest(path)
            path.write_bytes(path.read_bytes()+b'2|third\n')
            self.assertNotEqual(before,digest(path))
            self.assertEqual(2,csv_record(path)['rows'])

    def test_malformed_csv_cannot_be_sealed_as_prepared_input(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'bad.csv'
            path.write_text('id|name\n1|a|shifted\n',encoding='utf-8')
            with self.assertRaises(ValueError):
                csv_record(path)

    def test_clean_layer_from_another_raw_export_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            raw=Path(root)/'raw'; clean=Path(root)/'clean'
            raw.mkdir();clean.mkdir()
            (raw/'export_manifest.json').write_text('{}',encoding='utf-8')
            (clean/'clean_master_manifest.json').write_text(json.dumps({
                'raw_manifest_sha256':'0'*64,'preprocessor_sha256':'0'*64,
                'crosswalk_sha256':'0'*64}),encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'parent or transformation'):
                verify_layers(raw,clean,Path(root)/'overlay',Path(root)/'hr')

    def test_undeclared_overlay_cannot_replace_fresh_transaction_csv(self):
        with tempfile.TemporaryDirectory() as root:
            base=Path(root); clean=base/'clean'; overlay=base/'overlay'
            clean.mkdir();overlay.mkdir()
            (clean/'clean_master_manifest.json').write_text(json.dumps({'outputs':[{'file':'purchase_orders.csv'}]}))
            (overlay/'goods_excel_manifest.json').write_text(json.dumps({'outputs':[{'file':'goods.csv'}]}))
            (overlay/'purchase_orders.csv').write_text('legacy_id\n123\n')
            with patch('rehearse_local_import.verify_frozen_source',return_value='a'*40), \
                 patch('rehearse_local_import.verify_raw',return_value={'files':[]}), \
                 patch('rehearse_local_import.verify_layers'), \
                 patch('rehearse_local_import.verify_reference_masters',return_value={'outputs':[]}), \
                 self.assertRaisesRegex(ValueError,'Undeclared CSVs'):
                prepare_inputs(base/'raw',clean,overlay,base/'hr',base/'final',base/'excel',
                               base/'reference',base/'people.xls',base/'masters')
            self.assertFalse((base/'final'/'purchase_orders.csv').exists())


if __name__=='__main__':
    unittest.main()
