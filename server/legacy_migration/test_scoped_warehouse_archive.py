"""Regression for scoped completion retaining the full warehouse exclusion rows.

Pure generation checks: python -m unittest discover -s server/legacy_migration
  -p test_scoped_warehouse_archive.py
Opt into the owned network-none PostgreSQL case with
UTEN_RUN_SCOPED_ARCHIVE_DB_TESTS=1. Optional cached image override:
UTEN_SCOPED_ARCHIVE_PG_IMAGE=postgres:16.15. No existing database is contacted.
"""
from contextlib import redirect_stdout
from decimal import Decimal
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

import compose_bootstrap
import reconcile_modules
import scoped_bootstrap


RUN = '00000000-0000-4000-8000-000000000099'


def rendered_scope():
    manifest = {'files': [{'file': name, 'rows': 0}
                         for name in reconcile_modules.document_queries()]}
    return scoped_bootstrap.finish_sql(
        Path('.'), manifest, RUN,
        {'data': {'payment_styles': [], 'posting_roles': []}}, 'SYNTHETIC_SCOPE')


def archive_projection(sql):
    """Extract the actual generated JSON value using the shipped SQL lexer."""
    tokens = list(compose_bootstrap.tokens(sql))
    matches = [i for i, token in enumerate(tokens)
               if token.kind == 'STRING' and token.value == "'warehouseExclusions'"]
    if len(matches) != 1:
        raise AssertionError('One persisted warehouse archive is required')
    index = matches[0]
    if tokens[index + 1].value != ',' or tokens[index + 2].value != '(':
        raise AssertionError('Archive must contain a SQL row projection')
    begin = index + 2
    depth = 0
    for token in tokens[begin:]:
        if token.kind == 'SYMBOL':
            depth += token.value == '('
            depth -= token.value == ')'
        if depth == 0:
            return sql[tokens[begin].offset:token.offset + 1]
    raise AssertionError('Unterminated archive row projection')


class ScopedWarehouseArchiveGenerationTest(unittest.TestCase):
    def test_scope_uses_the_formal_full_row_archive_not_just_counts(self):
        scoped = rendered_scope()
        manifest = {'files': [{'file': name, 'rows': 0}
                             for name in reconcile_modules.document_queries()]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.json'
            path.write_text(json.dumps(manifest), encoding='utf-8')
            output = io.StringIO()
            with patch.object(sys, 'argv', ['reconcile_modules.py', str(path), RUN]), redirect_stdout(output):
                reconcile_modules.main()
        projection = archive_projection(scoped)
        normalized = lambda value: [(t.kind, t.value) for t in compose_bootstrap.tokens(value)]
        self.assertEqual(normalized(projection), normalized(archive_projection(output.getvalue())))
        # The projection belongs to the same actual completion UPDATE, not a
        # comment, diagnostic SELECT or full-bootstrap finalization branch.
        before = scoped[:scoped.index("'warehouseExclusions'")]
        self.assertIn('UPDATE legacy_migration_runs SET status=', before)
        self.assertIn("reconciliation_status='WAIVED'", before)
        self.assertNotIn('bootstrap_automated_checks', scoped)


@unittest.skipUnless(os.environ.get('UTEN_RUN_SCOPED_ARCHIVE_DB_TESTS') == '1',
                     'set UTEN_RUN_SCOPED_ARCHIVE_DB_TESTS=1 for owned PostgreSQL')
class ScopedWarehouseArchivePostgresTest(unittest.TestCase):
    def test_generated_archive_preserves_rows_negative_decimal_null_and_scope(self):
        context = subprocess.check_output(['docker', 'context', 'show'], text=True).strip()
        self.assertRegex(context, r'^[A-Za-z0-9_.-]+$')
        endpoint = subprocess.check_output(
            ['docker', 'context', 'inspect', context, '--format', '{{.Endpoints.docker.Host}}'],
            text=True).strip()
        for value in (endpoint, os.environ.get('DOCKER_HOST', endpoint)):
            self.assertTrue(value.startswith(('npipe:', 'unix:')), 'Local Docker is required')
        env = os.environ.copy()
        env['DOCKER_CONTEXT'] = context
        env.pop('DOCKER_HOST', None)
        prefix = ['docker', '--context', context]
        container = None

        def docker(args, data=None, check=True):
            result = subprocess.run(prefix + args, input=data, capture_output=True, env=env, timeout=60)
            if check:
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            return result

        try:
            image = os.environ.get('UTEN_SCOPED_ARCHIVE_PG_IMAGE', 'postgres:16-alpine')
            container = docker(['run', '-d', '--rm', '--pull=never', '--init', '--network=none',
                                '--name', 'uten-scoped-archive-test-' + uuid.uuid4().hex[:12],
                                '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', image]).stdout.decode().strip()
            self.assertRegex(container, r'^[0-9a-f]{64}$')
            for _ in range(100):
                if docker(['exec', container, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'], check=False).returncode == 0:
                    break
                time.sleep(.15)
            else:
                self.fail('Owned PostgreSQL did not become ready')
            projection = archive_projection(rendered_scope())
            sql = """BEGIN;
CREATE TEMP TABLE legacy_migration_runs(status text,reconciliation_status text,reconciliation_summary jsonb);
INSERT INTO legacy_migration_runs VALUES('SUCCESS','WAIVED','{"existingEvidence":true}');
CREATE TEMP TABLE bootstrap_warehouse_exclusions(source_file text,source_row_id text,legacy_warehouse_id int,
 reason text,goods_legacy_id int,qty numeric,amount numeric);
INSERT INTO bootstrap_warehouse_exclusions VALUES
 ('stock_draw_i.csv','11',132,'UNASSIGNED_OWNING_WAREHOUSE',7,-0.0001,123456789.1234),
 ('stock_check_m.csv','9',130,'DROPPED_WAREHOUSE_DOCUMENT',NULL,NULL,NULL),
 ('purchase_receipt_items.csv','12',130,'DROPPED_WAREHOUSE_DOCUMENT',8,0.0000,-0.0100);
UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary||jsonb_build_object('warehouseExclusions',
""" + projection + """);
SELECT jsonb_build_object('status',status,'reconciliation',reconciliation_status,'summary',reconciliation_summary)
FROM legacy_migration_runs;
ROLLBACK;
"""
            result = docker(['exec', '-i', container, 'psql', '-XqAt', '-U', 'postgres',
                             '-v', 'ON_ERROR_STOP=1'], sql.encode('utf-8'))
            value = json.loads(result.stdout, parse_float=Decimal)
            self.assertEqual(value['status'], 'SUCCESS')
            self.assertEqual(value['reconciliation'], 'WAIVED')
            self.assertIs(value['summary']['existingEvidence'], True)
            rows = value['summary']['warehouseExclusions']
            fields = {'source_file', 'source_row_id', 'legacy_warehouse_id', 'reason',
                      'goods_legacy_id', 'qty', 'amount'}
            self.assertEqual([row['source_file'] for row in rows],
                             ['purchase_receipt_items.csv', 'stock_check_m.csv', 'stock_draw_i.csv'])
            self.assertTrue(all(set(row) == fields for row in rows))
            self.assertEqual(rows[0]['qty'], Decimal('0.0000'))
            self.assertEqual(rows[0]['amount'], Decimal('-0.0100'))
            self.assertIsNone(rows[1]['goods_legacy_id'])
            self.assertIsNone(rows[1]['qty'])
            self.assertIsNone(rows[1]['amount'])
            self.assertEqual(rows[2]['qty'], Decimal('-0.0001'))
            self.assertEqual(rows[2]['amount'], Decimal('123456789.1234'))
        finally:
            if container and re.fullmatch(r'[0-9a-f]{64}', container):
                docker(['rm', '-f', container], check=False)


if __name__ == '__main__':
    unittest.main()
