#!/usr/bin/env python3
"""Fail-closed, offline table-disposition coverage for one exact sealed source.

This checks table inventory, not source column coverage or business approval of
an archived table. No database is opened and no source evidence is rewritten.
"""
from collections import Counter
import csv
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import re

SUMMARY = 'source_table_audit_summary.json'
INVENTORY = 'source_table_disposition_exact.csv'
FIELDS = {'schema_name','table_name','actual_rows','disposition','reason'}
KNOWN = {'来源为空','旧账号权限丢弃','派生缓存归档','历史配置归档','导入及来源对照','导入','未知待核验'}


class CoverageError(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise CoverageError(reason)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'),parse_float=Decimal,
                      parse_constant=lambda _: (_ for _ in ()).throw(CoverageError('Non-finite audit summary number')))


def exact_integer(value, field):
    require(not isinstance(value,bool) and isinstance(value,(int,float,Decimal)), 'Audit summary count must be a numeric integer: '+field)
    require(not isinstance(value,Decimal) or value.is_finite() and value==value.to_integral_value(), 'Audit summary count is not finite and integral: '+field)
    require(not isinstance(value,float) or math.isfinite(value) and value.is_integer(), 'Audit summary count is not finite and integral: '+field)
    require(value>=0,'Audit summary count is negative: '+field)
    return int(value)


def utc(value):
    require(isinstance(value,str) and bool(value),'Source snapshot cutoff is absent')
    try:
        parsed=datetime.fromisoformat(value.replace('Z','+00:00'))
    except ValueError:
        raise CoverageError('Invalid source snapshot cutoff') from None
    require(parsed.tzinfo is not None,'Source snapshot cutoff must include a timezone')
    return parsed.astimezone(timezone.utc).isoformat().replace('+00:00','Z')


def validate_source_table_coverage(reference, raw_manifest_path, expected_file_sha256=None):
    reference=Path(reference);raw_manifest_path=Path(raw_manifest_path)
    paths={name:reference/name for name in (SUMMARY,INVENTORY)}
    for name,path in paths.items():
        require(path.is_file() and not path.is_symlink(),'Required source coverage evidence is absent or not regular: '+name)
    hashes={name:digest(path) for name,path in paths.items()}
    if expected_file_sha256 is not None:
        require(set(expected_file_sha256)==set(paths),'Bound coverage evidence inventory differs')
        require(hashes==expected_file_sha256,'Bound source coverage file SHA differs')
    summary=load(paths[SUMMARY]);raw=load(raw_manifest_path)
    raw_sha=digest(raw_manifest_path)
    require(raw.get('formatVersion')==4 and raw.get('target')=='All','Coverage needs the full format-4 raw source manifest')
    require(re.fullmatch(r'[0-9a-f]{64}',raw.get('sourceBackupSha256','')),'Raw source backup identity is invalid')
    require(summary.get('database_updateability')=='READ_ONLY','Source coverage audit was not captured read-only')
    require(summary.get('source_export_manifest_sha256')==raw_sha,'Source coverage audit belongs to a different raw manifest')
    require(summary.get('source_backup_sha256')==raw['sourceBackupSha256'],'Source coverage audit belongs to a different backup')
    require(utc(summary.get('source_snapshot_as_of_utc'))==utc(raw.get('sourceSnapshotAsOfUtc')),'Source coverage snapshot cutoff differs')
    require(summary.get('count_method')=='COUNT_BIG(*) per user table','Source table counts must be exact COUNT_BIG results')
    count=0;nonempty=0;total=0;seen=set();dispositions=Counter()
    try:
        with paths[INVENTORY].open(encoding='utf-8-sig',newline='') as stream:
            reader=csv.DictReader(stream,strict=True)
            require(reader.fieldnames is not None and len(reader.fieldnames)==len(FIELDS)
                    and set(reader.fieldnames)==FIELDS,'Source coverage CSV columns are missing, extra or duplicated')
            for row in reader:
                require(None not in row and all(value is not None for value in row.values()),'Source coverage CSV row width differs')
                for name in ('schema_name','table_name','disposition','reason'):
                    require(isinstance(row[name],str) and row[name].strip() and row[name]==row[name].strip()
                            and not any(ord(ch)<32 for ch in row[name]),'Source coverage metadata field is empty or malformed: '+name)
                identity=(row['schema_name'].casefold(),row['table_name'].casefold())
                require(identity not in seen,'Duplicate qualified source table in coverage inventory')
                seen.add(identity)
                require(re.fullmatch(r'[0-9]+',row['actual_rows']) is not None,'Source table row count must be an exact nonnegative integer')
                number=int(row['actual_rows']);disposition=row['disposition']
                require(disposition in KNOWN,'Unknown source table disposition')
                if number:
                    # Existing source SELECTs target the reviewed dbo namespace.
                    # A different nonempty schema needs a qualified source rule.
                    require(identity[0]=='dbo','Nonempty source schema has no reviewed qualified exporter rule')
                    require(disposition not in ('来源为空','未知待核验'),'Nonempty source table is unclassified or incorrectly declared empty')
                else:
                    require(disposition=='来源为空','Zero-row source table disposition must state empty')
                count+=1;nonempty+=number>0;total+=number;dispositions[disposition]+=1
    except csv.Error:
        raise CoverageError('Malformed source coverage CSV') from None
    require(count>0,'Source table inventory is empty')
    for field,value in (('table_count',count),('nonempty_table_count',nonempty),('total_rows',total)):
        require(exact_integer(summary.get(field),field)==value,'Source coverage CSV/summary count differs: '+field)
    return {'format':'source-table-coverage-v1','validated':True,'source_manifest_sha256':raw_sha,
            'source_backup_sha256':raw['sourceBackupSha256'],'source_snapshot_as_of_utc':utc(raw['sourceSnapshotAsOfUtc']),
            'table_count':count,'nonempty_table_count':nonempty,'total_rows':total,
            'nonempty_unknown_tables':0,'disposition_table_counts':dict(sorted(dispositions.items())),
            'file_sha256':hashes}


def validate_bound_source_table_coverage(reference_hashes, raw_manifest_path, expected_coverage):
    """Revalidate the same logical gate at apply, after all bound reference SHAs."""
    selected={}
    for value,sha in reference_hashes.items():
        path=Path(value)
        if path.name in (SUMMARY,INVENTORY):
            require(path.name not in selected,'Repeated bound source coverage evidence name')
            selected[path.name]=(path,sha)
    require(set(selected)=={SUMMARY,INVENTORY},'Both source coverage files must be bound to this prepared input')
    parents={path.resolve().parent for path,_ in selected.values()}
    require(len(parents)==1,'Bound source coverage files must share one audit directory')
    result=validate_source_table_coverage(next(iter(parents)),raw_manifest_path,
                                        {name:value[1] for name,value in selected.items()})
    require(result==expected_coverage,'Prepared source table coverage proof differs')
    return result
