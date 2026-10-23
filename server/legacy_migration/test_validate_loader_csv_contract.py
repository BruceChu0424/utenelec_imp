"""Static pre-claim contract regressions; no database or SQL execution needed."""
from __future__ import annotations

import csv
import json
from pathlib import Path
import tempfile
import unittest

from validate_loader_csv_contract import CSVContractError, validate_modules


def copy(stage='stage', filename='input.csv', columns=''):
    return (f"\\copy {stage}{columns} FROM '/tmp/{filename}' "
            "WITH (FORMAT csv, DELIMITER '|', HEADER true)\n")


class LoaderCSVContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def csv(self, filename='input.csv', header=('legacy_id', 'amount')):
        with (self.directory / filename).open('w', encoding='utf-8', newline='') as output:
            csv.writer(output, delimiter='|').writerow(header)

    def check(self, sql):
        return validate_modules([('fixture.sql', sql.encode())], self.directory)

    def rejected(self, sql, message):
        with self.assertRaisesRegex(CSVContractError, message) as raised:
            self.check(sql)
        self.assertFalse(raised.exception.report['valid'])
        return raised.exception.report

    def test_basic_contract_is_json_serializable_without_data(self):
        self.csv()
        result = self.check('CREATE TEMP TABLE stage(legacy_id integer, amount numeric(18,4));\n' + copy())
        self.assertEqual((result['module_count'], result['copy_count']), (1, 1))
        self.assertEqual(result['contracts'][0]['header_columns'], 2)
        self.assertNotIn('legacy_id', json.dumps(result))

    def test_original_production_15_vs_17_mismatch_is_rejected(self):
        self.csv(header=tuple(f'field{i}' for i in range(15)))
        sql = 'CREATE TEMP TABLE stage(' + ','.join(f'field{i} text' for i in range(17)) + ');\n'
        self.rejected(sql + copy(), '15 header columns.*expects 17')

    def test_alter_columns_are_counted_only_after_their_statement(self):
        self.csv()
        self.csv('second.csv', ('id', 'amount', 'maker', 'approver'))
        sql = ('CREATE TEMP TABLE stage(id int,amount numeric(18,4));\n' + copy() +
               'ALTER TABLE stage ADD COLUMN maker text, ADD COLUMN approver text;\n' +
               copy(filename='second.csv'))
        self.assertEqual([row['expected_columns'] for row in self.check(sql)['contracts']], [2, 4])

    def test_multi_line_nested_type_defaults_constraints_and_comments(self):
        self.csv(header=('a', 'b', 'c'))
        sql = '''/* outer /* nested */ comment */ CREATE TEMPORARY TABLE stage (
          id integer PRIMARY KEY,
          amount numeric(18, 4) DEFAULT round(1.234, 2), -- comma, ignored
          values_text text[] DEFAULT ARRAY['a,b','c'],
          CONSTRAINT "unique, pair" UNIQUE(id,amount), CHECK (amount IN (1,2))
        ) ON COMMIT DROP;
        ''' + copy()
        self.assertEqual(self.check(sql)['copy_count'], 1)

    def test_quoted_identifiers_and_explicit_columns(self):
        self.csv(header=('amount',))
        sql = ('CREATE TEMP TABLE pg_temp."Stage"("id,first" int,"A""mount" numeric(18,4));\n' +
               copy('pg_temp."Stage"', columns='("A""mount")'))
        result = self.check(sql)['contracts'][0]
        self.assertEqual(result['stage'], 'Stage')
        self.assertTrue(result['explicit_copy_columns'])

    def test_quoted_case_remains_distinct(self):
        self.csv()
        self.rejected('CREATE TEMP TABLE "STAGE"(a int,b int);\n' + copy(), 'no resolvable')

    def test_modules_have_independent_stage_scope(self):
        self.csv()
        self.csv('one.csv', ('id',))
        modules = [('a.sql', 'CREATE TEMP TABLE stage(a int,b int);\n' + copy()),
                   ('b.sql', 'CREATE TEMP TABLE stage(a int);\n' + copy(filename='one.csv'))]
        self.assertEqual(validate_modules(modules, self.directory)['copy_count'], 2)
        modules[1] = ('b.sql', copy())
        with self.assertRaisesRegex(CSVContractError, 'b.sql.*no resolvable'):
            validate_modules(modules, self.directory)

    def test_dollar_bodies_and_literal_decoys_are_opaque(self):
        self.csv()
        sql = """DO $body$ BEGIN
          CREATE TEMP TABLE stage(fake1 int,fake2 int,fake3 int);
          RAISE NOTICE '\\copy x FROM ''/tmp/missing.csv''';
        END $body$;
        CREATE FUNCTION pg_temp.decoy() RETURNS void LANGUAGE plpgsql AS $f$
        BEGIN CREATE TEMP TABLE stage(only_one int); END $f$;
        SELECT 'CREATE TEMP TABLE stage(fake int);';
        -- CREATE TEMP TABLE stage(fake int);
        CREATE TEMP TABLE stage(a int,b int);
        """ + copy()
        self.assertEqual(self.check(sql)['copy_count'], 1)

    def test_procedural_table_definition_cannot_authorize_copy(self):
        self.csv()
        self.rejected('DO $$ BEGIN CREATE TEMP TABLE stage(a int,b int); END $$;\n' + copy(), 'no resolvable')

    def test_multiple_stage_names_in_one_module(self):
        self.csv()
        self.csv('one.csv', ('id',))
        sql = ('CREATE TEMP TABLE stage(a int,b int);\n' + copy() +
               'CREATE TEMP TABLE second(id int);\n' + copy('second', 'one.csv'))
        self.assertEqual(self.check(sql)['copy_count'], 2)

    def test_explicit_subset_uses_list_arity_and_checks_identifiers(self):
        self.csv(header=('one',))
        self.check('CREATE TEMP TABLE stage(a int,b int);\n' + copy(columns='(b)'))
        self.rejected('CREATE TEMP TABLE stage(a int,b int);\n' + copy(columns='(c)'), 'unresolved')
        self.rejected('CREATE TEMP TABLE stage(a int,b int);\n' + copy(columns='(a,a)'), 'unique')

    def test_missing_csv_rejected(self):
        self.rejected('CREATE TEMP TABLE stage(a int,b int);\n' + copy(), 'CSV is missing')

    def test_missing_or_ctas_stage_rejected_even_with_explicit_list(self):
        self.csv()
        self.rejected(copy(columns='(a,b)'), 'no resolvable')
        self.rejected('CREATE TEMP TABLE stage AS SELECT 1 a,2 b;\n' + copy(), 'no resolvable')

    def test_static_like_definition(self):
        self.csv()
        self.check('CREATE TEMP TABLE original(a int,b int);\n'
                   'CREATE TEMP TABLE stage(LIKE original INCLUDING ALL);\n' + copy())

    def test_drop_and_recreate_are_ordered(self):
        self.csv()
        self.csv('one.csv', ('id',))
        sql = ('CREATE TEMP TABLE stage(a int,b int);\n' + copy() +
               'DROP TABLE IF EXISTS stage; CREATE TEMP TABLE stage(a int);\n' + copy(filename='one.csv'))
        self.assertEqual(self.check(sql)['copy_count'], 2)
        self.rejected('CREATE TEMP TABLE stage(a int,b int); DROP TABLE stage;\n' + copy(), 'no resolvable')

    def test_rename_drop_add_column_changes_explicit_identity(self):
        self.csv()
        sql = ('CREATE TEMP TABLE stage(a int,b int,c int); '
               'ALTER TABLE stage RENAME COLUMN a TO z; ALTER TABLE stage DROP COLUMN c;\n')
        self.check(sql + copy(columns='(z,b)'))
        self.rejected(sql + copy(columns='(a,b)'), 'unresolved')

    def test_unknown_shape_mutation_fails_closed(self):
        self.csv()
        self.rejected('CREATE TEMP TABLE stage(a int,b int); '
                      'ALTER TABLE stage INHERIT some_table;\n' + copy(), 'no resolvable')

    def test_program_variables_external_paths_and_extra_suffix_rejected(self):
        self.csv()
        prefix = 'CREATE TEMP TABLE stage(a int,b int);\n'
        for bad in (copy().replace("'/tmp/input.csv'", "PROGRAM 'echo secret'"),
                    copy().replace("'/tmp/input.csv'", ':path'),
                    copy().replace('/tmp/input.csv', '/tmp/../input.csv'),
                    copy().replace('/tmp/input.csv', '/outside/input.csv'),
                    copy().rstrip() + ' unexpected\n'):
            with self.subTest(bad=bad):
                self.rejected(prefix + bad, 'COPY')

    def test_copy_options_require_pipe_header_csv_contract(self):
        self.csv()
        for replacement in ('HEADER false', 'HEADER match', 'HEADER true, NULL \'NULL\''):
            self.rejected('CREATE TEMP TABLE stage(a int,b int);\n' +
                          copy().replace('HEADER true', replacement), 'COPY')

    def test_bom_csv_header_and_quoted_pipe_use_csv_parser(self):
        (self.directory / 'input.csv').write_text('\ufeff"a|b"|amount\n', encoding='utf-8')
        self.check('CREATE TEMP TABLE stage(a int,b int);\n' + copy())

    def test_empty_missing_and_invalid_header_rejected_without_printing_value(self):
        prefix = 'CREATE TEMP TABLE stage(a int,b int);\n'
        for header in ('', 'a|\n', '"secret-unclosed|header\n'):
            (self.directory / 'input.csv').write_text(header, encoding='utf-8')
            report = self.rejected(prefix + copy(), 'header')
            self.assertNotIn('secret-unclosed', json.dumps(report))

    def test_collects_issues_across_modules(self):
        modules = [('missing-a.sql', copy()), ('missing-b.sql', copy())]
        with self.assertRaises(CSVContractError) as raised:
            validate_modules(modules, self.directory)
        self.assertEqual(len(raised.exception.report['issues']), 2)

    def test_unterminated_sql_and_copy_inside_statement_rejected(self):
        self.csv()
        self.rejected('CREATE TEMP TABLE stage(a int,b int)', 'unterminated')
        self.rejected('CREATE TEMP TABLE stage(a int,b int)\n' + copy(), 'complete line')

    def test_safe_include_no_csv_and_large_non_ddl_statement(self):
        sql = '\\i :legacy_key_file\nDO $$ BEGIN RAISE NOTICE \'ignored\'; END $$;\n'
        sql += 'INSERT INTO unrelated VALUES ' + ','.join('(1,2)' for _ in range(10000)) + ';'
        self.assertEqual(self.check(sql)['copy_count'], 0)


if __name__ == '__main__':
    unittest.main()
