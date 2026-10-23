"""Independent V912 original receipt-fee identity acceptance; aggregates only."""
import csv
from decimal import Decimal, InvalidOperation
import hashlib
from pathlib import Path
import re
import uuid


SOURCE_FILE = 'm_get.csv'
TARGET_FIELDS = (
    'id', 'legacy_import_run_id', 'legacy_id', 'bill_no', 'bill_date', 'currency_id', 'exchange_rate',
    'amount_original', 'amount_local', 'status', 'remark', 'maker_legacy_id', 'approver_legacy_id',
    'operator_legacy_id', 'maker_name', 'approver_name', 'operator_name', 'operator_id', 'account_id',
    'counterpart_account_id', 'version', 'invoice_no', 'cancel_date', 'source_remark', 'receipt_kind',
    'settlement_authority_version', 'sales_order_id', 'client_id', 'bank_fee', 'other_fee',
    'other_fee_style_legacy_id', 'other_fee_style_id', 'receipt_method_legacy_id', 'receipt_method_id',
)
ZERO_INVARIANTS = (
    'wrong_run_proofs', 'unregistered_proof_routes', 'wrong_file_sha', 'wrong_target_fields',
    'invalid_source_row_hashes', 'missing_or_mismatched_targets', 'changed_original_projections',
    'wrong_or_null_target_run', 'targets_without_exact_proof', 'invalid_original_style_ids',
    'wrong_typed_style_references',
)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _hash(lines):
    return hashlib.sha256(''.join(lines).encode('utf-8')).hexdigest()


def _integer(value, positive, require):
    if value in ('', None) and not positive:
        return 0
    try:
        result = int(value)
    except (ValueError, TypeError):
        require(False, 'Receipt fee source integer identity is invalid')
    require(result > 0 if positive else result >= 0, 'Receipt fee source identity is negative or absent')
    return result


def _nonzero(value, require):
    if value in ('', None):
        return False
    try:
        number = Decimal(value)
    except (InvalidOperation, ValueError, TypeError):
        require(False, 'Receipt fee source numeric shape is invalid')
    require(number.is_finite(), 'Receipt fee source numeric shape is not finite')
    return number != 0


def source_inventory(directory, records, require=_require):
    """Bind every source ID to its original positive style ID or zero, never money."""
    if SOURCE_FILE not in records:
        return None
    path = Path(directory) / SOURCE_FILE
    record = records[SOURCE_FILE]
    require(re.fullmatch('[0-9a-f]{64}', record['sha256']) is not None
            and hashlib.sha256(path.read_bytes()).hexdigest() == record['sha256'],
            'Receipt fee sealed source SHA-256 differs')
    with path.open(encoding='utf-8-sig', newline='') as stream:
        reader = csv.DictReader(stream, delimiter='|')
        require(reader.fieldnames and len(reader.fieldnames) == len(set(reader.fieldnames))
                and {'legacy_id', 'qtfymc', 'qtfy'}.issubset(reader.fieldnames),
                'Receipt fee source CSV shape differs')
        rows = list(reader)
    require(len(rows) == record['rows'] and all(None not in row for row in rows),
            'Receipt fee source CSV row count or shape differs')
    identities, pairs = set(), []
    positive_count = nonzero_count = no_style_nonzero = positive_nonzero = 0
    for row in rows:
        old = _integer(row['legacy_id'], True, require)
        require(old not in identities, 'Receipt fee source identity is duplicated')
        identities.add(old)
        original = _integer(row['qtfymc'], False, require)
        nonzero = _nonzero(row['qtfy'], require)
        pairs.append((old, original))
        positive_count += original > 0
        nonzero_count += nonzero
        no_style_nonzero += original == 0 and nonzero
        positive_nonzero += original > 0 and nonzero
    return {
        'source_file': SOURCE_FILE, 'target_table': 'finance_receipts', 'rows': len(pairs),
        'file_sha256': record['sha256'],
        'source_ids_sha256': _hash(str(old) + '\n' for old, _ in sorted(pairs)),
        'original_style_ids_sha256': _hash(f'{old}:{original}\n' for old, original in sorted(pairs)),
        'positive_original_style_rows': positive_count, 'original_no_style_rows': len(pairs) - positive_count,
        'nonzero_fee_rows': nonzero_count, 'original_no_style_nonzero_fee_rows': no_style_nonzero,
        'positive_original_style_nonzero_fee_rows': positive_nonzero,
    }


def acceptance_sql(run_id, source):
    """One aggregate SELECT embedded in the generic verifier's RR/READ ONLY facts."""
    run_id = str(uuid.UUID(run_id))
    _require(re.fullmatch('[0-9a-f]{64}', source['file_sha256']) is not None, 'Invalid receipt fee source SHA-256')
    fields = 'ARRAY[' + ','.join("'%s'" % name for name in sorted(TARGET_FIELDS)) + ']::text[]'
    family = "(p.source_kind='RECEIPT' OR p.target_table='finance_receipts')"
    route = "(p.source_kind='RECEIPT' AND p.target_table='finance_receipts' AND p.source_file='m_get.csv')"
    return f"""SELECT jsonb_build_object(
 'total_receipt_proofs',(SELECT count(*) FROM public.legacy_finance_import_sources p WHERE {family}),
 'wrong_run_proofs',(SELECT count(*) FROM public.legacy_finance_import_sources p WHERE {family} AND p.run_id IS DISTINCT FROM '{run_id}'::uuid),
 'unregistered_proof_routes',(SELECT count(*) FROM public.legacy_finance_import_sources p WHERE {family} AND {route} IS NOT TRUE),
 'proof_rows',count(*),
 'proof_source_ids_sha256',encode(digest(coalesce(string_agg(p.source_legacy_id::text||chr(10),'' ORDER BY p.source_legacy_id),''),'sha256'),'hex'),
 'wrong_file_sha',count(*) FILTER(WHERE p.source_file_sha256 IS DISTINCT FROM '{source['file_sha256']}'),
 'wrong_target_fields',count(*) FILTER(WHERE p.target_fields IS DISTINCT FROM {fields}),
 'invalid_source_row_hashes',count(*) FILTER(WHERE p.source_row_sha256 IS NULL OR p.source_row_sha256 !~ '^[0-9a-f]{{64}}$'),
 'missing_or_mismatched_targets',count(*) FILTER(WHERE t.id IS NULL OR t.legacy_id IS DISTINCT FROM p.source_legacy_id OR t.legacy_import_run_id IS DISTINCT FROM p.run_id),
 'changed_original_projections',count(*) FILTER(WHERE (CASE WHEN t.id IS NOT NULL THEN p.target_snapshot_sha256=encode(digest(public.fn_legacy_finance_snapshot(to_jsonb(t),p.target_fields)::text,'sha256'),'hex') ELSE false END) IS DISTINCT FROM true),
 'target_rows',(SELECT count(*) FROM public.finance_receipts),
 'wrong_or_null_target_run',(SELECT count(*) FROM public.finance_receipts WHERE legacy_import_run_id IS DISTINCT FROM '{run_id}'::uuid),
 'targets_without_exact_proof',(SELECT count(*) FROM public.finance_receipts x WHERE NOT EXISTS(
    SELECT 1 FROM public.legacy_finance_import_sources q WHERE q.run_id='{run_id}'::uuid AND q.source_kind='RECEIPT' AND q.target_table='finance_receipts' AND q.source_file='m_get.csv' AND q.target_id=x.id AND q.source_legacy_id=x.legacy_id)),
 'target_source_ids_sha256',(SELECT encode(digest(coalesce(string_agg(legacy_id::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM public.finance_receipts),
 'original_style_ids_sha256',(SELECT encode(digest(coalesce(string_agg(legacy_id::text||':'||coalesce(other_fee_style_legacy_id,0)::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM public.finance_receipts),
 'invalid_original_style_ids',(SELECT count(*) FROM public.finance_receipts WHERE other_fee_style_legacy_id<=0),
 'wrong_typed_style_references',(SELECT count(*) FROM public.finance_receipts x LEFT JOIN public.payment_styles s ON s.id=x.other_fee_style_id
    WHERE (x.other_fee_style_legacy_id IS NULL AND x.other_fee_style_id IS NOT NULL)
       OR (x.other_fee_style_legacy_id IS NOT NULL AND x.other_fee_style_id IS NOT NULL AND (s.id IS NULL OR s.legacy_id IS DISTINCT FROM x.other_fee_style_legacy_id OR s.category IS DISTINCT FROM 'EXPENSE'))
       OR (x.other_fee_style_legacy_id IS NOT NULL AND x.other_fee_style_id IS NULL AND EXISTS(SELECT 1 FROM public.payment_styles z WHERE z.legacy_id=x.other_fee_style_legacy_id AND z.category='EXPENSE'))),
 'positive_original_style_rows',(SELECT count(*) FROM public.finance_receipts WHERE other_fee_style_legacy_id>0),
 'valid_expense_style_rows',(SELECT count(*) FROM public.finance_receipts WHERE other_fee_style_legacy_id>0 AND other_fee_style_id IS NOT NULL),
 'pending_original_style_rows',(SELECT count(*) FROM public.finance_receipts WHERE other_fee_style_legacy_id>0 AND other_fee_style_id IS NULL),
 'original_no_style_rows',(SELECT count(*) FROM public.finance_receipts WHERE other_fee_style_legacy_id IS NULL),
 'nonzero_fee_rows',(SELECT count(*) FROM public.finance_receipts WHERE coalesce(other_fee,0)<>0),
 'original_no_style_nonzero_fee_rows',(SELECT count(*) FROM public.finance_receipts WHERE other_fee_style_legacy_id IS NULL AND coalesce(other_fee,0)<>0),
 'positive_original_style_nonzero_fee_rows',(SELECT count(*) FROM public.finance_receipts WHERE other_fee_style_legacy_id>0 AND coalesce(other_fee,0)<>0),
 'pending_nonzero_fee_rows',(SELECT count(*) FROM public.finance_receipts WHERE other_fee_style_legacy_id>0 AND other_fee_style_id IS NULL AND coalesce(other_fee,0)<>0))
 FROM public.legacy_finance_import_sources p LEFT JOIN public.finance_receipts t ON t.id=p.target_id
 WHERE p.run_id='{run_id}'::uuid AND p.source_kind='RECEIPT' AND p.target_table='finance_receipts' AND p.source_file='m_get.csv'"""


def validate(actual, source, require=_require):
    require(isinstance(actual, dict) and isinstance(source, dict), 'Receipt fee proof or sealed source inventory is absent')
    for fact, expected in (
        ('total_receipt_proofs', 'rows'), ('proof_rows', 'rows'), ('target_rows', 'rows'),
        ('proof_source_ids_sha256', 'source_ids_sha256'), ('target_source_ids_sha256', 'source_ids_sha256'),
        ('original_style_ids_sha256', 'original_style_ids_sha256'),
        ('positive_original_style_rows', 'positive_original_style_rows'), ('original_no_style_rows', 'original_no_style_rows'),
        ('nonzero_fee_rows', 'nonzero_fee_rows'), ('original_no_style_nonzero_fee_rows', 'original_no_style_nonzero_fee_rows'),
        ('positive_original_style_nonzero_fee_rows', 'positive_original_style_nonzero_fee_rows'),
    ):
        require(fact in actual and actual[fact] == source[expected], 'Receipt fee source invariant differs: ' + fact)
    for key in ZERO_INVARIANTS:
        require(type(actual.get(key)) is int and actual[key] == 0, 'Receipt fee invariant failed: ' + key)
    for key in ('positive_original_style_rows', 'valid_expense_style_rows', 'pending_original_style_rows',
                'original_no_style_rows', 'nonzero_fee_rows', 'original_no_style_nonzero_fee_rows',
                'positive_original_style_nonzero_fee_rows', 'pending_nonzero_fee_rows'):
        require(type(actual.get(key)) is int and actual[key] >= 0, 'Receipt fee aggregate shape differs: ' + key)
    require(actual['valid_expense_style_rows'] + actual['pending_original_style_rows'] == actual['positive_original_style_rows']
            and actual['pending_nonzero_fee_rows'] <= actual['pending_original_style_rows']
            and actual['pending_nonzero_fee_rows'] <= actual['positive_original_style_nonzero_fee_rows'],
            'Receipt fee valid/pending count conservation differs')
    return {
        'verified': True, 'source_proof_rows': source['rows'],
        **{key: actual[key] for key in ('positive_original_style_rows', 'valid_expense_style_rows',
            'pending_original_style_rows', 'original_no_style_rows', 'nonzero_fee_rows',
            'original_no_style_nonzero_fee_rows', 'pending_nonzero_fee_rows')},
        'source_original_style_ids_verified': True, 'complete_original_projections_unchanged': True,
        'exact_bidirectional_source_target_coverage': True, 'typed_expense_identity_verified': True,
        'pending_is_not_expense_or_posting_authority': True,
    }
