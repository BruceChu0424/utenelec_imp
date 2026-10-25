"""Independent V909 receipt source-ID acceptance; aggregate output only."""
import csv
import hashlib
from pathlib import Path
import re
import uuid


ROUTES = (
    ('PURCHASE_ITEM', 'purchase_receipt_items', 'purchase_receipt_items.csv',
     'purchase_receipts', 'purchase_receipts.csv', 'purchase_order_items', 'purchase_order_items.csv'),
    ('SUBCONTRACT_ITEM', 'subcontract_receipt_items', 'subcontract_in_i.csv',
     'subcontract_receipts', 'subcontract_in_m.csv', 'subcontract_order_items', 'subcontract_order_i.csv'),
)
COMMON_FIELDS = ('id', 'legacy_import_run_id', 'legacy_id', 'bill_no', 'bill_date', 'receipt_id',
                 'order_item_id', 'order_item_legacy_id', 'goods_id', 'color_id', 'unit_id', 'unit_rate',
                 'qty', 'price', 'amount_original', 'amount_local', 'returned_qty', 'weight',
                 'source_doc_no', 'order_no', 'replacement_intent', 'goods_snapshot_source')
EXTRA_FIELDS = {
    'PURCHASE_ITEM': ('gift_qty', 'sales_order_no', 'production_plan_no'),
    'SUBCONTRACT_ITEM': ('check_qty', 'order_qty', 'girth_qty', 'step_legacy_id', 'return_amount', 'return_no'),
}


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _hash(lines):
    return hashlib.sha256(''.join(lines).encode('utf-8')).hexdigest()


def _positive(value, require):
    try:
        result = int(value)
    except (TypeError, ValueError):
        require(False, 'Receipt reference source identity is invalid')
    require(result > 0, 'Receipt reference source identity is not positive')
    return result


def _optional(value, require):
    if value in ('', None):
        return 0
    try:
        result = int(value)
    except (TypeError, ValueError):
        require(False, 'Receipt original optional order identity is invalid')
    require(result >= 0, 'Receipt original optional order identity is negative')
    return result


def source_inventory(directory, records, supplemental=None, require=_require):
    """The PR DROP decision is independent of target counts or run summaries."""
    directory = Path(directory)
    supplemental = supplemental or {}
    needed = {name for route in ROUTES for name in (route[2], route[4], route[6])}
    if not needed.issubset(records) or 'warehouse_crosswalk.csv' not in set(records) | set(supplemental):
        return None  # Old schema/mapping consumers do not need V909 columns.

    def read(name, columns):
        with (directory / name).open(encoding='utf-8-sig', newline='') as stream:
            reader = csv.DictReader(stream, delimiter='|')
            require(reader.fieldnames and len(reader.fieldnames) == len(set(reader.fieldnames))
                    and set(columns).issubset(reader.fieldnames), 'Receipt reference source CSV shape differs')
            rows = list(reader)
        if name in records:
            require(len(rows) == records[name]['rows'], 'Receipt reference source CSV row count differs')
        else:
            require(re.fullmatch('[0-9a-f]{64}', supplemental[name]) is not None
                    and hashlib.sha256((directory / name).read_bytes()).hexdigest() == supplemental[name],
                    'Receipt reference supplemental source SHA-256 differs')
        require(all(None not in row for row in rows),
                'Receipt reference source CSV row count or shape differs')
        return rows

    crosswalk = read('warehouse_crosswalk.csv', ('legacy_id', 'action'))
    require(all(row['action'] and (row['legacy_id'] not in ('', None) or row['action'] == 'TARGET') for row in crosswalk),
            'Receipt warehouse crosswalk has an invalid original source identity')
    historical_routes = [row for row in crosswalk if row['legacy_id'] not in ('', None)]
    warehouse_ids = [_positive(row['legacy_id'], require) for row in historical_routes]
    require(len(warehouse_ids) == len(set(warehouse_ids)), 'Receipt warehouse source identity is duplicated')
    drops = {old for old, row in zip(warehouse_ids, historical_routes) if row['action'] == 'DROP'}
    result = {}
    for kind, table, source_file, header_table, header_file, upstream_table, upstream_file in ROUTES:
        headers = read(header_file, ('legacy_id', 'warehouse_legacy_id'))
        header_ids = [_positive(row['legacy_id'], require) for row in headers]
        require(len(header_ids) == len(set(header_ids)), 'Receipt source header identity is duplicated')
        all_headers = set(header_ids)
        kept_headers = {old for old, row in zip(header_ids, headers)
                        if _optional(row['warehouse_legacy_id'], require) not in drops}
        require(kind == 'PURCHASE_ITEM' or kept_headers == all_headers,
                'Subcontract source headers on DROP warehouses require a reviewed decision')
        upstream = read(upstream_file, ('legacy_id',))
        upstream_ids = [_positive(row['legacy_id'], require) for row in upstream]
        require(len(upstream_ids) == len(set(upstream_ids)), 'Receipt upstream source identity is duplicated')
        upstream_set = set(upstream_ids)
        source_rows = read(source_file, ('legacy_id', 'bill_legacy_id', 'order_item_legacy_id'))
        source_ids, included, parents, gaps = set(), [], [], []
        excluded = 0
        for row in source_rows:
            old = _positive(row['legacy_id'], require)
            require(old not in source_ids, 'Receipt source item identity is duplicated')
            source_ids.add(old)
            parent = _positive(row['bill_legacy_id'], require)
            require(parent in all_headers, 'Receipt source item has no original source header')
            if parent not in kept_headers:
                excluded += 1
                continue
            order = _optional(row['order_item_legacy_id'], require)
            included.append((old, order))
            parents.append((old, parent))
            if order and order not in upstream_set:
                gaps.append((old, order))
        result[kind] = {
            'rows': len(included), 'excluded_source_rows': excluded,
            'source_file': source_file, 'file_sha256': records[source_file]['sha256'], 'target_table': table,
            'header_file': header_file, 'header_table': header_table, 'header_rows': len(kept_headers),
            'header_source_ids_sha256': _hash(str(old) + '\n' for old in sorted(kept_headers)),
            'upstream_file': upstream_file, 'upstream_table': upstream_table, 'upstream_rows': len(upstream_ids),
            'upstream_source_ids_sha256': _hash(str(old) + '\n' for old in sorted(upstream_ids)),
            'source_ids_sha256': _hash(str(old) + '\n' for old, _ in sorted(included)),
            'original_order_ids_sha256': _hash(f'{old}:{order}\n' for old, order in sorted(included)),
            'receipt_parent_ids_sha256': _hash(f'{old}:{parent}\n' for old, parent in sorted(parents)),
            'pending_rows': len(gaps), 'pending_distinct_order_ids': len({order for _, order in gaps}),
            'pending_source_ids_sha256': _hash(str(old) + '\n' for old, _ in sorted(gaps)),
        }
    return result


def acceptance_sql(run_id, sources):
    """One SELECT inside the caller's read-only repeatable-read fact snapshot."""
    run_id = str(uuid.UUID(run_id))
    branches, routes = [], []
    for kind, table, source_file, header_table, _, upstream_table, _ in ROUTES:
        source = sources[kind]
        _require(re.fullmatch('[0-9a-f]{64}', source['file_sha256']) is not None, 'Invalid receipt source SHA-256')
        fields = 'ARRAY[' + ','.join("'%s'" % field for field in sorted(COMMON_FIELDS + EXTRA_FIELDS[kind])) + ']::text[]'
        # V627 records field order using the database collation. Normalize only
        # order: exact array equality still rejects duplicate, NULL or extra keys.
        canonical_fields = '(ARRAY(SELECT field FROM unnest(p.target_fields) AS proof_fields(field) ORDER BY field COLLATE "C"))'
        routes.append(f"(p.source_kind='{kind}' AND p.target_table='{table}' AND p.source_file='{source_file}')")
        branches.append(f"""SELECT '{kind}' AS kind,jsonb_build_object(
 'proof_rows',count(*),
 'proof_source_ids_sha256',encode(digest(coalesce(string_agg(p.source_legacy_id::text||chr(10),'' ORDER BY p.source_legacy_id),''),'sha256'),'hex'),
 'wrong_file_sha',count(*) FILTER(WHERE p.source_file_sha256 IS DISTINCT FROM '{source['file_sha256']}'),
 'wrong_target_fields',count(*) FILTER(WHERE {canonical_fields} IS DISTINCT FROM {fields}),
 'invalid_source_row_hashes',count(*) FILTER(WHERE p.source_row_sha256 IS NULL OR p.source_row_sha256 !~ '^[0-9a-f]{{64}}$'),
 'missing_or_mismatched_targets',count(*) FILTER(WHERE t.id IS NULL OR t.legacy_id IS DISTINCT FROM p.source_legacy_id OR t.legacy_import_run_id IS DISTINCT FROM p.run_id),
 'changed_original_projections',count(*) FILTER(WHERE (CASE WHEN t.id IS NOT NULL THEN p.target_snapshot_sha256=encode(digest(public.fn_legacy_finance_snapshot(to_jsonb(t),p.target_fields)::text,'sha256'),'hex') ELSE false END) IS DISTINCT FROM true),
 'target_rows',(SELECT count(*) FROM public.{table}),
 'wrong_or_null_target_run',(SELECT count(*) FROM public.{table} WHERE legacy_import_run_id IS DISTINCT FROM '{run_id}'::uuid),
 'targets_without_exact_proof',(SELECT count(*) FROM public.{table} x WHERE NOT EXISTS(
   SELECT 1 FROM public.legacy_procurement_receipt_import_sources q WHERE q.run_id='{run_id}'::uuid AND q.source_kind='{kind}' AND q.target_table='{table}' AND q.source_file='{source_file}' AND q.target_id=x.id AND q.source_legacy_id=x.legacy_id)),
 'target_source_ids_sha256',(SELECT encode(digest(coalesce(string_agg(legacy_id::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM public.{table}),
 'original_order_ids_sha256',(SELECT encode(digest(coalesce(string_agg(legacy_id::text||':'||coalesce(order_item_legacy_id,0)::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM public.{table}),
 'receipt_parent_ids_sha256',(SELECT encode(digest(coalesce(string_agg(x.legacy_id::text||':'||coalesce(h.legacy_id,0)::text||chr(10),'' ORDER BY x.legacy_id),''),'sha256'),'hex') FROM public.{table} x LEFT JOIN public.{header_table} h ON h.id=x.receipt_id),
 'invalid_original_order_ids',(SELECT count(*) FROM public.{table} WHERE order_item_legacy_id<=0),
 'wrong_real_upstream_links',(SELECT count(*) FROM public.{table} x LEFT JOIN public.{upstream_table} u ON u.id=x.order_item_id
   WHERE (x.order_item_legacy_id IS NULL AND x.order_item_id IS NOT NULL)
      OR (x.order_item_legacy_id IS NOT NULL AND x.order_item_id IS NOT NULL AND (u.id IS NULL OR u.legacy_id IS DISTINCT FROM x.order_item_legacy_id))
      OR (x.order_item_legacy_id IS NOT NULL AND x.order_item_id IS NULL AND EXISTS(SELECT 1 FROM public.{upstream_table} z WHERE z.legacy_id=x.order_item_legacy_id))),
 'pending_rows',(SELECT count(*) FROM public.{table} WHERE order_item_legacy_id>0 AND order_item_id IS NULL),
 'pending_distinct_order_ids',(SELECT count(DISTINCT order_item_legacy_id) FROM public.{table} WHERE order_item_legacy_id>0 AND order_item_id IS NULL),
 'pending_source_ids_sha256',(SELECT encode(digest(coalesce(string_agg(legacy_id::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM public.{table} WHERE order_item_legacy_id>0 AND order_item_id IS NULL),
 'header_rows',(SELECT count(*) FROM public.{header_table}),
 'header_source_ids_sha256',(SELECT encode(digest(coalesce(string_agg(legacy_id::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM public.{header_table}),
 'upstream_rows',(SELECT count(*) FROM public.{upstream_table}),
 'upstream_source_ids_sha256',(SELECT encode(digest(coalesce(string_agg(legacy_id::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM public.{upstream_table})) AS facts
 FROM public.legacy_procurement_receipt_import_sources p LEFT JOIN public.{table} t ON t.id=p.target_id
 WHERE p.run_id='{run_id}'::uuid AND p.source_kind='{kind}' AND p.target_table='{table}' AND p.source_file='{source_file}'""")
    item_filter = "(p.source_kind IN ('PURCHASE_ITEM','SUBCONTRACT_ITEM') OR p.target_table IN ('purchase_receipt_items','subcontract_receipt_items'))"
    return f"""SELECT jsonb_build_object(
 'total_item_proofs',(SELECT count(*) FROM public.legacy_procurement_receipt_import_sources p WHERE {item_filter}),
 'wrong_run_item_proofs',(SELECT count(*) FROM public.legacy_procurement_receipt_import_sources p WHERE {item_filter} AND p.run_id IS DISTINCT FROM '{run_id}'::uuid),
 'unregistered_item_proof_routes',(SELECT count(*) FROM public.legacy_procurement_receipt_import_sources p WHERE {item_filter} AND ({' OR '.join(routes)}) IS NOT TRUE),
 'families',(SELECT jsonb_object_agg(kind,facts) FROM ({' UNION ALL '.join(branches)}) families))"""


def validate(actual, sources, require=_require):
    require(actual and isinstance(sources, dict), 'Receipt original-order proof or sealed source inventory is absent')
    require(actual['total_item_proofs'] == sum(source['rows'] for source in sources.values()), 'Receipt original-order proof total differs')
    require(actual['wrong_run_item_proofs'] == 0 and actual['unregistered_item_proof_routes'] == 0,
            'Receipt original-order proof run or source route differs')
    require(set(actual['families']) == set(sources), 'Receipt original-order source families differ')
    for kind, source in sources.items():
        facts = actual['families'][kind]
        for fact_key, expected_key in (
            ('proof_rows', 'rows'), ('target_rows', 'rows'), ('proof_source_ids_sha256', 'source_ids_sha256'),
            ('target_source_ids_sha256', 'source_ids_sha256'), ('original_order_ids_sha256', 'original_order_ids_sha256'),
            ('receipt_parent_ids_sha256', 'receipt_parent_ids_sha256'), ('header_rows', 'header_rows'),
            ('header_source_ids_sha256', 'header_source_ids_sha256'), ('upstream_rows', 'upstream_rows'),
            ('upstream_source_ids_sha256', 'upstream_source_ids_sha256'), ('pending_rows', 'pending_rows'),
            ('pending_distinct_order_ids', 'pending_distinct_order_ids'), ('pending_source_ids_sha256', 'pending_source_ids_sha256')):
            require(facts[fact_key] == source[expected_key], 'Receipt original-order invariant differs: ' + fact_key)
        for key in ('wrong_file_sha', 'wrong_target_fields', 'invalid_source_row_hashes', 'missing_or_mismatched_targets',
                    'changed_original_projections', 'wrong_or_null_target_run', 'targets_without_exact_proof',
                    'invalid_original_order_ids', 'wrong_real_upstream_links'):
            require(facts[key] == 0, 'Receipt original-order invariant failed: ' + key)
    return {'verified': True, 'source_proof_rows': actual['total_item_proofs'],
            'family_rows': {kind: source['rows'] for kind, source in sources.items()},
            'excluded_source_rows': {kind: source['excluded_source_rows'] for kind, source in sources.items()},
            'pending_rows': {kind: source['pending_rows'] for kind, source in sources.items()},
            'pending_distinct_order_ids': {kind: source['pending_distinct_order_ids'] for kind, source in sources.items()},
            'source_original_order_ids_verified': True, 'complete_original_projections_unchanged': True,
            'exact_bidirectional_source_target_coverage': True, 'real_upstream_links_verified': True,
            'unresolved_upstream_is_not_new_capacity': True}
