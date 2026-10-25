"""Exact legacy default-settlement projection, with source-zero provenance.

The old B_Client/B_Provider PStyle DEFAULT(0) has no B_PStyle dictionary row.
Normalize only that sentinel; a nonzero value must resolve to one active UUID.
Do not infer a business method from a name, payment label, or document age.
"""
from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import uuid

FORMAT = 'legacy-default-settlement-source-audit-v1'
METHODS_SQL = """SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',id,'legacy_id',legacy_id,'status',status,'is_deleted',is_deleted)
    ORDER BY id),'[]'::jsonb)::text FROM settlement_methods;"""
FAMILIES = (('client.csv', 'clients', 'client_stage'),
            ('supplier.csv', 'suppliers', 'supplier_stage'))
SNAPSHOT_TABLE = 'bootstrap_default_settlement_source_snapshot'


def render_source_capture(module_name: str) -> str:
    """Append inside each reviewed module, before the composer's cleanup.

    Only these three non-personal columns survive; the original stage must be
    dropped so later owner modules can reuse its name without collisions.
    """
    mapping = {'migrate_client_data.sql': ('clients', 'client_stage'),
               'migrate_supplier_data.sql': ('suppliers', 'supplier_stage')}
    if module_name not in mapping:
        return ''
    target, stage = mapping[module_name]
    return f"""\nCREATE TEMP TABLE IF NOT EXISTS {SNAPSHOT_TABLE} (
    target text NOT NULL CHECK(target IN ('clients','suppliers')),
    legacy_id int NOT NULL,raw_price_style int,
    PRIMARY KEY(target,legacy_id)
) ON COMMIT DROP;
INSERT INTO pg_temp.{SNAPSHOT_TABLE}(target,legacy_id,raw_price_style)
SELECT '{target}',legacy_id,price_style FROM pg_temp.{stage};
"""


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def normalized_price_style(value: str | int | None) -> int | None:
    """A blank/NULL or the proven zero sentinel is no selected default."""
    if value is None or str(value).strip() == '':
        return None
    parsed = int(str(value).strip())
    return parsed if parsed != 0 else None


def inspect(inputs: Path, methods: list[dict], manifest_sha256: str) -> dict:
    active: dict[int, list[str]] = {}
    for method in methods:
        method_id = str(uuid.UUID(method['id']))
        legacy_id = method['legacy_id']
        if (legacy_id is not None and method['status'] == '使用'
                and method['is_deleted'] is False):
            active.setdefault(int(legacy_id), []).append(method_id)
    families, issues = [], []
    for name, target, stage in FAMILIES:
        path = inputs / name
        rows, seen = [], set()
        with path.open(encoding='utf-8-sig', newline='') as source:
            for record in csv.DictReader(source, delimiter='|'):
                legacy_id = int(record['legacy_id'])
                if legacy_id in seen:
                    raise ValueError('Duplicate default-settlement source identity: ' + name)
                seen.add(legacy_id)
                raw = record['price_style']
                projected = normalized_price_style(raw)
                matches = active.get(projected, []) if projected is not None else []
                expected_uuid = matches[0] if len(matches) == 1 else None
                if projected is not None and (projected < 1 or len(matches) != 1):
                    issues.append(dict(file=name, legacy_id=legacy_id, raw_price_style=raw,
                                       active_match_count=len(matches)))
                rows.append(dict(legacy_id=legacy_id, raw_price_style=raw,
                                 normalized_price_style=projected,
                                 expected_method_id=expected_uuid))
        rows.sort(key=lambda record: record['legacy_id'])
        zero_ids = [r['legacy_id'] for r in rows
                    if r['raw_price_style'].strip() and int(r['raw_price_style']) == 0]
        families.append(dict(file=name, target=target, stage=stage,
                             source_sha256=sha(path), rows=rows,
                             source_zero_count=len(zero_ids),
                             source_zero_identity_sha256=hashlib.sha256(canonical(zero_ids)).hexdigest()))
    return dict(format=FORMAT, status='REJECTED' if issues else 'PREFLIGHT_PASSED',
                manifest_sha256=manifest_sha256,
                source_bytes_changed=False,
                rule='SOURCE_NULL_OR_ZERO_TO_NULL__NONZERO_EXACT_UNIQUE_ACTIVE_UUID',
                method_snapshot_sha256=hashlib.sha256(canonical(methods)).hexdigest(),
                methods=methods, families=families, issues=issues)


def preflight(inputs: Path, methods: list[dict], manifest_sha256: str,
              output: Path) -> dict:
    """Write a private identity audit before claiming or changing business data."""
    audit = inspect(inputs, methods, manifest_sha256)
    with output.open('x', encoding='utf-8', newline='\n') as destination:
        json.dump(audit, destination, ensure_ascii=False, indent=2)
        destination.write('\n')
    if audit['issues']:
        raise ValueError('Default settlement preflight rejected nonzero source references; '
                         'see ' + str(output))
    return audit


def literal(value) -> str:
    return 'NULL' if value is None else "'" + str(value).replace("'", "''") + "'"


def render_late_audit(audit: dict, run_id: str, audit_path: Path) -> str:
    """Validate preserved source/UUID projection after all module cleanups."""
    if audit['format'] != FORMAT or audit['status'] != 'PREFLIGHT_PASSED' or audit['issues']:
        raise ValueError('Cannot render rejected default-settlement preflight')
    uuid.UUID(run_id)
    actual = json.loads(audit_path.read_text(encoding='utf-8'))
    if actual != audit:
        raise ValueError('Default settlement source audit changed before compilation')
    result = ['CREATE TEMP TABLE bootstrap_default_settlement_expected ('
              'target text,legacy_id int,source_price_style int,expected_price_style int,'
              'expected_method_id uuid,PRIMARY KEY(target,legacy_id)) ON COMMIT DROP;']
    tuples, compact = [], []
    for family in audit['families']:
        if (family['file'], family['target'], family['stage']) not in FAMILIES:
            raise ValueError('Unexpected default-settlement audit family')
        for row in family['rows']:
            raw = row['raw_price_style']
            source_style = None if raw.strip() == '' else int(raw)
            tuples.append('(' + ','.join(literal(x) for x in (
                family['target'], row['legacy_id'], source_style,
                row['normalized_price_style'], row['expected_method_id'])) + ')')
        compact.append({key: family[key] for key in (
            'file', 'target', 'source_sha256', 'source_zero_count', 'source_zero_identity_sha256')}
                       | {'source_rows': len(family['rows']),
                          'source_empty_count': sum(r['raw_price_style'].strip() == '' for r in family['rows']),
                          'verified_normalized_zero_target_rows': family['source_zero_count']})
    if tuples:
        result.append('INSERT INTO bootstrap_default_settlement_expected VALUES\n'
                      + ',\n'.join(tuples) + ';')
    for family in audit['families']:
        target = family['target']
        result.append(f"""DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM bootstrap_default_settlement_expected expected
        LEFT JOIN pg_temp.{SNAPSHOT_TABLE} source
          ON source.target=expected.target AND source.legacy_id=expected.legacy_id
        LEFT JOIN {target} target ON target.legacy_id=expected.legacy_id
        WHERE expected.target={literal(target)} AND (
            source.legacy_id IS NULL OR target.id IS NULL
            OR source.raw_price_style IS DISTINCT FROM expected.source_price_style
            OR target.price_style IS DISTINCT FROM expected.expected_price_style
            OR target.default_settlement_method_id IS DISTINCT FROM expected.expected_method_id
            OR (expected.expected_price_style IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM settlement_methods method
                WHERE method.id=expected.expected_method_id
                  AND method.legacy_id=expected.expected_price_style
                  AND method.status='使用' AND method.is_deleted=FALSE))
            OR (expected.expected_price_style IS NOT NULL AND 1 <> (
                SELECT count(*) FROM settlement_methods method
                WHERE method.legacy_id=expected.expected_price_style
                  AND method.status='使用' AND method.is_deleted=FALSE)))
    ) OR (SELECT count(*) FROM pg_temp.{SNAPSHOT_TABLE}
          WHERE target={literal(target)}) <> {len(family['rows'])}
      OR (SELECT count(*) FROM {target} target
          JOIN bootstrap_default_settlement_expected expected
            ON expected.target={literal(target)} AND expected.legacy_id=target.legacy_id
         ) <> {len(family['rows'])}
    THEN RAISE EXCEPTION 'Default settlement source/target projection mismatch: {target}'; END IF;
END $$;""")
    evidence = dict(format=FORMAT, rule=audit['rule'], families=compact,
                    manifest_sha256=audit['manifest_sha256'],
                    source_audit_sha256=sha(audit_path),
                    method_snapshot_sha256=audit['method_snapshot_sha256'],
                    source_zero_captured_before_stage_cleanup=True,
                    target_zero_sentinels_normalized=True,
                    nonzero_exact_unique_active_uuid_verified=True)
    result.append(f"""INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size)
VALUES ({literal(run_id)}::uuid,'default-settlement-source-audit.json',
{literal(sha(audit_path))},{audit_path.stat().st_size});
UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary ||
jsonb_build_object('defaultSettlementSourceNormalization',{literal(json.dumps(evidence,ensure_ascii=False))}::jsonb)
WHERE run_id={literal(run_id)}::uuid AND status='RUNNING';""")
    return '\n'.join(result) + '\n'
