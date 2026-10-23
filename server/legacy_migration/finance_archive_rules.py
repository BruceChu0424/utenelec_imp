"""Pure source-disposition rules; typed CSV values must come from PostgreSQL.

No database, file, amount/date normalization, account creation, or target writes.
This helper does not infer anything from bill_id, bill_no, or a legacy ID range.
"""
from __future__ import annotations
from copy import deepcopy
from decimal import Decimal
import re

SUPPORTED_FAMILIES=frozenset((20,21,22,23,27))
SOURCE_FIELDS=frozenset(('legacy_id','bill_no','check_no','remark','company','in_total','out_total',
                         'bill_date','out_date','acc_id','source','b_style','bill_id'))
INTEGER_FIELDS=frozenset(('legacy_id','acc_id','b_style','bill_id'))
MONEY_FIELDS=frozenset(('in_total','out_total'))
SOURCE_FILE='m_allcheck.csv'

def _integer(value,*,positive=False):
    if type(value) is not int or (positive and value<=0):
        raise ValueError('source identity must be an exact integer in its required domain')
    return value

def archive_reasons(source,source_account_ids):
    """Classify from ORIGINAL account population, never missing target state."""
    reasons=[]
    if source.get('acc_id') not in source_account_ids: reasons.append('MISSING_ORIGINAL_ACCOUNT')
    if source.get('b_style') not in SUPPORTED_FAMILIES: reasons.append('UNSUPPORTED_ORIGINAL_DOCUMENT_FAMILY')
    return tuple(reasons)

def validate_typed_source(source):
    if not isinstance(source,dict) or set(source)!=SOURCE_FIELDS:
        raise ValueError('source must contain the complete V626 typed stage row')
    _integer(source['legacy_id'],positive=True)
    for field,value in source.items():
        if value is None:continue
        if field in INTEGER_FIELDS:_integer(value)
        elif field in MONEY_FIELDS:
            if type(value) is not int and not isinstance(value,Decimal):
                raise ValueError('money must be parsed exactly, never through binary float')
            if isinstance(value,Decimal) and not value.is_finite():raise ValueError('nonfinite source money')
        elif not isinstance(value,str):raise ValueError('typed text/date value must be string or NULL')

def expected_archive(rows,source_account_ids,source_file_sha256):
    """rows are {typed_source, source_row_sha256, source_row_number} from PG.

    The SHA is digest(to_jsonb(actual_stage_row.*)::text), computed by the same
    PG type representation and session timezone as the import. Never calculate
    a replacement hash by converting Decimal to float or by normalizing text.
    """
    account_ids=frozenset(_integer(x,positive=True) for x in source_account_ids)
    if not re.fullmatch('[0-9a-f]{64}',source_file_sha256):raise ValueError('source file SHA missing')
    seen=set();result=[]
    for row in rows:
        source=row['typed_source'];validate_typed_source(source)
        legacy=source['legacy_id']
        if legacy in seen:raise ValueError('duplicate original account flow identity')
        seen.add(legacy)
        reasons=archive_reasons(source,account_ids)
        if not reasons:continue
        row_sha=row['source_row_sha256'];row_number=row['source_row_number']
        if not isinstance(row_sha,str) or not re.fullmatch('[0-9a-f]{64}',row_sha):raise ValueError('typed source row SHA missing')
        _integer(row_number,positive=True)
        result.append({'source_file':SOURCE_FILE,'source_legacy_id':legacy,
                       'source_file_sha256':source_file_sha256,'source_row_sha256':row_sha,
                       'source_row_number':row_number,'legacy_account_id':source['acc_id'],
                       'legacy_bstyle':source['b_style'],'reason_codes':list(reasons),
                       'disposition':'ARCHIVE_ONLY','typed_source':deepcopy(source)})
    return sorted(result,key=lambda row:row['source_legacy_id'])

def verify_archive_and_coverage(expected,saved,source_ids,target_ids,proof_ids,source_account_ids,target_account_ids):
    """Compare expected source disposition with saved summary and active rows.

    Caller decodes both source and summary JSON with parse_float=Decimal and
    supplies only ACCOUNT_FLOW proof IDs from legacy_finance_import_sources.
    Counts alone cannot pass: all three identity sets must match exactly.
    """
    def unique_map(rows):
        result={}
        for row in rows:
            legacy=_integer(row['source_legacy_id'],positive=True)
            if legacy in result:raise ValueError('duplicate archive identity')
            validate_typed_source(row['typed_source'])
            result[legacy]=row
        return result
    expected_by_id=unique_map(expected);saved_by_id=unique_map(saved)
    if expected_by_id!=saved_by_id:raise ValueError('saved archive differs from the sealed typed source, reasons or hashes')
    def identities(values):
        values=list(values);result={_integer(v,positive=True) for v in values}
        if len(result)!=len(values):raise ValueError('duplicate active identity')
        return result
    source=identities(source_ids);target=identities(target_ids);proof=identities(proof_ids)
    archive=set(expected_by_id)
    if not archive<=source or target!=source-archive or proof!=source-archive:
        raise ValueError('finance source/active target/source-proof/archive coverage differs')
    if target&archive or proof&archive:raise ValueError('archive-only row entered an active finance target or proof')
    if identities(source_account_ids)!=identities(target_account_ids):raise ValueError('unproved or missing active account identity')
    return {'source_count':len(source),'active_count':len(target),'archive_only_count':len(archive),
            'source_equals_active_plus_archive':len(source)==len(target)+len(archive),
            'exact_typed_source_and_hashes':True,'no_archive_in_active_target_or_proof':True,
            'no_unproved_account_identity':True}
