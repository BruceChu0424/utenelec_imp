"""No Docker, source CSV, application database or protected material is read."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

PATH=Path(__file__).with_name('run_adversarial.py')
spec=importlib.util.spec_from_file_location('production_counter_test_harness',PATH)
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)

NATIVE="""INSERT INTO production_plan_items (
 legacy_id,qty,remark)
SELECT s.legacy_id, COALESCE(s.qty,0), '--; source literal'
FROM item_stage s JOIN plan_stage p ON p.legacy_id = s.plan_legacy_id;"""
WRAPPED=NATIVE.replace('legacy_id,qty,remark)', 'id, legacy_production_import_run_id,legacy_id,qty,remark)',1).replace(
 'SELECT s.legacy_id,','SELECT COALESCE(source_proof.target_id,gen_random_uuid()), source_proof.run_id,\n s.legacy_id,',1).replace(
 's.plan_legacy_id;','s.plan_legacy_id\nLEFT JOIN production_counter_source_stage source_proof ON source_proof.legacy_id=s.legacy_id;',1)


def compact(sql):return ''.join(sql.split())


class RenderingTest(unittest.TestCase):
    def test_native_business_mapping_is_kept(self):
        self.assertEqual(h.business_insert(NATIVE),NATIVE)

    def test_current_wrapper_removes_only_provenance(self):
        actual=h.business_insert(WRAPPED)
        self.assertEqual(compact(actual),compact(NATIVE))
        self.assertIn("'--; source literal'",actual)
        self.assertNotIn('source_proof.',actual)

    def test_unknown_wrapper_alias_fails_instead_of_guessing(self):
        with self.assertRaisesRegex(ValueError,'wrapper changed'):
            h.business_insert(WRAPPED.replace('source_proof','new_proof_alias'))

    def test_proof_is_added_exactly_once_for_integrated_loader(self):
        actual=h.original_insert(WRAPPED,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
        self.assertEqual(actual.count('legacy_production_import_run_id'),1)
        self.assertEqual(actual.count('SELECT (SELECT target_id FROM fixture_proof)'),1)
        self.assertIn('COALESCE(s.qty,0)',actual)

    def test_no_proof_path_really_uses_native_insert(self):
        self.assertEqual(compact(h.original_insert(WRAPPED,'unused',proof=False)),compact(NATIVE))

    def test_comment_semicolon_is_not_statement_end(self):
        sql=NATIVE.replace('SELECT s.legacy_id,','-- explanatory comment; not a terminator\nSELECT s.legacy_id,')
        self.assertEqual(h.insert_block(sql+'\nSELECT 99;','production_plan_items'),sql)

    def test_nested_comment_and_quoted_semicolons_are_not_terminators(self):
        sql=NATIVE.replace('SELECT s.legacy_id,',"/* outer; /* inner; */ finished; */\nSELECT s.legacy_id,")
        self.assertEqual(h.insert_block(sql+'SELECT 99;','production_plan_items'),sql)

    def test_dollar_quoted_literal_is_not_truncated(self):
        sql=NATIVE.replace("'--; source literal'",'$note$semicolon; and -- comment text$note$')
        self.assertEqual(h.insert_block(sql+'SELECT 99;','production_plan_items'),sql)

    def test_unclosed_statement_rejects(self):
        with self.assertRaises(ValueError):h.insert_block(NATIVE[:-1],'production_plan_items')

    def test_help_has_no_database_or_docker_action(self):
        with patch.object(h,'OwnedPg',side_effect=AssertionError('DB fixture must not start')), \
             patch.object(h,'local_docker_guard',side_effect=AssertionError('Docker must not run')), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as result:h.main(['--help'])
        self.assertEqual(result.exception.code,0)

    def test_baseline_and_output_are_explicit_before_any_fixture_can_start(self):
        with patch.object(h,'OwnedPg',side_effect=AssertionError('DB fixture must not start')), \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:h.main([])
        self.assertEqual(result.exception.code,2)

    def test_entry_has_no_private_drive_or_frozen_commit_dependency(self):
        source=PATH.read_text(encoding='utf-8')
        for private in ('D:/','C:/Users/','runtime-v907','FREEZE=',"'git','-C'"):
            self.assertNotIn(private,source)


if __name__=='__main__':unittest.main()
