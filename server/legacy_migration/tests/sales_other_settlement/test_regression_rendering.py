from pathlib import Path
import contextlib,importlib.util,io,unittest

PATH=Path(__file__).with_name('run_regression.py')
spec=importlib.util.spec_from_file_location('sales_regression',PATH)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class RenderingTest(unittest.TestCase):
    def test_only_reviewed_header_tokens_are_removed(self):
        fixed='INSERT INTO sales_other_shipments ('+m.NEW_COLUMNS+') SELECT '+m.NEW_VALUE+'other_original_fields;'
        expected='INSERT INTO sales_other_shipments ('+m.OLD_COLUMNS+') SELECT s.p_style,\nother_original_fields;'
        self.assertEqual(m.original_header(fixed),expected)

    def test_missing_placement_fails_closed(self):
        with self.assertRaises(ValueError):m.original_header('old uncorrected header')

    def test_duplicate_placement_fails_closed(self):
        with self.assertRaises(ValueError):m.original_header(m.NEW_COLUMNS*2+m.NEW_VALUE)

    def test_original_tail_is_refused(self):
        with self.assertRaises(ValueError):m.assert_removed_tail(m.OLD_TAIL)

    def test_corrected_source_has_no_tail(self):
        m.assert_removed_tail('UPDATE sales_orders SET settlement_method_id=NULL;')

    def test_help_never_loads_fixture_or_docker(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as result:m.main(['--help'])
        self.assertEqual(result.exception.code,0)

    def test_required_arguments_reject_before_payload(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:m.main([])
        self.assertEqual(result.exception.code,2)

    def test_no_fixed_private_path_or_git_freeze(self):
        source=PATH.read_text(encoding='utf-8')
        self.assertNotIn('D:/',source)
        self.assertNotIn('git',' '.join(line for line in source.splitlines() if 'subprocess' in line))


if __name__=='__main__':
    unittest.main()
