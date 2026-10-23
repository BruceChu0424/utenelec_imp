"""Capture a fresh local rehearsal's finance seeds before any source import.

Only the explicit local development PostgreSQL container is queried, in one
read-only snapshot. No .env, employee details or account credentials are read.
The resulting private JSON must be sealed into this run's derived inputs.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


SQL = """
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_build_object(
 'database',current_database(),
 'database_identity',jsonb_build_object(
   'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
   'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database())),
 'schema_version',(SELECT max(version::int) FROM flyway_schema_history WHERE success),
 'successful_migration_count',(SELECT count(*) FROM flyway_schema_history WHERE success),
 'failed_migration_count',(SELECT count(*) FROM flyway_schema_history WHERE NOT success),
 'applied_sql',(SELECT jsonb_agg(jsonb_build_object('script',script,'checksum',checksum) ORDER BY installed_rank) FROM flyway_schema_history WHERE success AND type='SQL'),
 'business_counts',jsonb_build_object(
   'goods',(SELECT count(*) FROM goods),
   'users',(SELECT count(*) FROM users),
   'accounts',(SELECT count(*) FROM accounts),
   'source_legacy_styles',(SELECT count(*) FROM payment_styles WHERE legacy_id IS NOT NULL),
   'finance_receipts',(SELECT count(*) FROM finance_receipts),
   'finance_payments',(SELECT count(*) FROM finance_payments),
   'finance_other_incomes',(SELECT count(*) FROM finance_other_incomes),
   'finance_expenses',(SELECT count(*) FROM finance_expenses),
   'finance_bank_transfers',(SELECT count(*) FROM finance_bank_transfers),
   'finance_reconciliations',(SELECT count(*) FROM finance_reconciliations),
   'finance_check_register',(SELECT count(*) FROM finance_check_register),
   'ar_ap_ledger',(SELECT count(*) FROM ar_ap_ledger),
   'gl_entries',(SELECT count(*) FROM gl_entries)),
 'payment_styles',(SELECT coalesce(jsonb_agg(to_jsonb(s)-ARRAY['created_at','updated_at','created_by','updated_by'] ORDER BY s.id),'[]'::jsonb) FROM payment_styles s),
 'posting_roles',(SELECT coalesce(jsonb_agg(to_jsonb(r)-ARRAY['created_at','updated_at','created_by','updated_by'] ORDER BY r.role_key),'[]'::jsonb) FROM system_posting_style_roles r),
 'master_code_reservations',(SELECT coalesce(jsonb_agg(to_jsonb(r)-'reserved_at' ORDER BY master_domain,normalized_code),'[]'::jsonb) FROM master_code_reservations r WHERE master_domain IN ('PAYMENT_STYLE','ACCOUNT')),
 'master_code_reservation_members',(SELECT coalesce(jsonb_agg(to_jsonb(r)-'acquired_at' ORDER BY master_domain,normalized_code,entity_id),'[]'::jsonb) FROM master_code_reservation_members r WHERE master_domain IN ('PAYMENT_STYLE','ACCOUNT')),
 'master_code_sequences',(SELECT jsonb_agg(to_jsonb(s) ORDER BY prefix) FROM master_code_sequences s WHERE prefix IN ('SK','ZH'))
);
COMMIT;
"""


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')).hexdigest()


def validate_snapshot(snapshot, database, expected_schema, migrations):
    """Check actual metadata and native Flyway checksums, never relabel a schema."""
    if not re.fullmatch(r'uten_imp_rehearsal_[0-9]{8}_v[0-9]+', database):
        raise ValueError('An explicit fresh local rehearsal database is required')
    if snapshot['database'] != database or snapshot['schema_version'] != expected_schema or snapshot['failed_migration_count'] != 0:
        raise ValueError('Actual database/schema identity differs')
    if not all(str(snapshot['database_identity'][key]).isdigit() for key in ('system_identifier','database_oid')):
        raise ValueError('Actual physical database identity is missing')
    if any(value != 0 for key, value in snapshot['business_counts'].items() if key != 'users') or snapshot['business_counts']['users'] not in (0, 1):
        raise ValueError('Seed baseline requires a fresh database before source/business import')
    if any(style.get('legacy_source_import_run_id') is not None for style in snapshot['payment_styles']):
        raise ValueError('Source finance rows cannot become a seed baseline')
    scripts = {item['script']:item['checksum'] for item in snapshot['applied_sql']}
    if len(scripts) != len(snapshot['applied_sql']) or scripts != migrations or snapshot['successful_migration_count'] != len(migrations):
        raise ValueError('Actual successful Flyway scripts/checksums differ from the complete supplied source')
    styles = snapshot['payment_styles']; roles = snapshot['posting_roles']
    if len({s['id'] for s in styles}) != len(styles) or len({r['role_key'] for r in roles}) != len(roles):
        raise ValueError('Seed identity inventory is ambiguous')
    ids = {s['id'] for s in styles}
    if any(r['style_id'] is not None and r['style_id'] not in ids for r in roles):
        raise ValueError('Configured system role lacks a captured seed UUID')
    return snapshot


def capture(repository, database, expected_schema, output):
    if not re.fullmatch(r'uten_imp_rehearsal_[0-9]{8}_v[0-9]+', database):
        raise ValueError('Only an explicit rehearsal candidate can be read')
    if output.exists() or output.is_symlink():
        raise ValueError('Choose a new output file; earlier evidence must remain intact')
    scripts = repository / 'server/legacy_migration'
    sys.path.insert(0, str(scripts))
    from verify_stock_typed_source_hashes import verify_local_docker
    from verify_candidate import flyway_checksum
    verify_local_docker()
    context = subprocess.check_output(['docker','context','show'], encoding='utf-8', stderr=subprocess.PIPE, timeout=15).strip()
    files = sorted((repository/'server/src/main/resources/db/migration').glob('V*__*.sql'))
    if not files or any(p.is_symlink() or not p.is_file() for p in files):
        raise ValueError('Complete regular Flyway SQL source is required')
    contents = {p:p.read_bytes() for p in files}
    actual = subprocess.run(['docker','--context',context,'exec','-i','uten-imp-postgres',
        'psql','-X','-q','-A','-t','-U','uten','-d',database,'-v','ON_ERROR_STOP=1'],
        input=SQL, encoding='utf-8', capture_output=True, timeout=120)
    if actual.returncode:
        raise ValueError('Read-only finance seed capture failed; server diagnostics withheld')
    if any(p.read_bytes()!=content for p,content in contents.items()):
        raise ValueError('Flyway source changed during seed capture')
    migration_checksums = {p.name:flyway_checksum(content) for p,content in contents.items()}
    snapshot = validate_snapshot(json.loads(actual.stdout), database, expected_schema, migration_checksums)
    inventory = [{'file':p.name,'sha256':hashlib.sha256(contents[p]).hexdigest()} for p in files]
    snapshot.update(format='finance-seed-baseline-v1', status='CAPTURED_READONLY',
        captured_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        applied_sql_sha256=canonical_hash(inventory), migration_sources=inventory)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(snapshot, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    return {'status':snapshot['status'],'schema_version':expected_schema,
        'successful_migration_count':snapshot['successful_migration_count'],
        'seed_styles':len(snapshot['payment_styles']),'posting_roles':len(snapshot['posting_roles']),
        'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'output':str(output)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository-root', type=Path, required=True)
    parser.add_argument('--database', required=True)
    parser.add_argument('--expected-schema', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(capture(args.repository_root.resolve(), args.database, args.expected_schema, args.output.resolve())))
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        print('Finance seed capture failed; no existing evidence overwritten and raw diagnostics withheld',file=sys.stderr)
        raise SystemExit(1)
