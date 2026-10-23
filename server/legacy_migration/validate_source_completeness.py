"""Offline schema, partition and reviewed-profile gate for a fresh source audit.

Full schema/dictionary/account rows stay in SHA-bound private files. Returned
proof is small: counts, policies and hashes only; never put full rows into the
RUNNING run summary consumed repeatedly by typed finance guards.
"""
from collections import Counter
import argparse
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import unicodedata

FILES={'source_columns.csv','system_item_full.csv','system_item_class_counts.csv','system_part_full.csv','mk_stock_goods_full.csv'}
SCHEMA_FIELDS=['schema_name','table_name','column_id','column_name','data_type','max_length','precision','scale','is_nullable','is_identity','is_computed']
PARTITIONS={1:('goods_categories.csv','IMPORT_GOODS_CATEGORIES'),2:('client_categories.csv','IMPORT_CLIENT_CATEGORIES'),
            3:('supplier_categories.csv','IMPORT_SUPPLIER_CATEGORIES'),5:('legacy_departments.csv','IMPORT_HISTORICAL_DEPARTMENTS'),
            10:(None,'ARCHIVE_ACCOUNT_CATEGORY_EVIDENCE'),12:(None,'ARCHIVE_WORKSHOP_DICTIONARY_MIRROR'),
            18:('mould_categories.csv','IMPORT_MOULD_CATEGORIES')}
AUDIT_HEADERS={
    'source_columns.csv':SCHEMA_FIELDS,
    'system_item_full.csv':['ItemID','ItemclassID','Number','Name','ParentID','Level'],
    'system_item_class_counts.csv':['item_class_id','actual_rows'],
    'system_part_full.csv':['ID','PartNumber','IsOperator','OperatorORGroupId','Visible'],
}
STOCK_IDENTIFIERS={'StockID','GoodsID','Year','ColorID'}


def require(ok,message):
    if not ok:raise ValueError(message)


def digest(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def canonical_sha(value):return hashlib.sha256(json.dumps(value,ensure_ascii=True,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def records(path,delimiter='|',expected_header=None):
    with Path(path).open(encoding='utf-8-sig',newline='') as stream:
        reader=csv.DictReader(stream,delimiter=delimiter,strict=True)
        require(reader.fieldnames and len(reader.fieldnames)==len(set(reader.fieldnames)),'Source audit CSV header is absent or repeated')
        require(expected_header is None or reader.fieldnames==expected_header,'Source audit CSV columns differ')
        result=list(reader)
    require(all(None not in row and all(v is not None for v in row.values()) for row in result),'Source audit CSV row width differs')
    return result


def schema_rows(rows):
    normalized=[];seen=set()
    for row in rows:
        require(set(row)==set(SCHEMA_FIELDS),'Source schema metadata columns differ')
        identity=(row['schema_name'].casefold(),row['table_name'].casefold(),int(row['column_id']))
        require(identity not in seen and identity[2]>0,'Source schema column identity is repeated or invalid');seen.add(identity)
        values=[row['schema_name'],row['table_name'],int(row['column_id']),row['column_name'],row['data_type'].lower(),
                int(row['max_length']),int(row['precision']),int(row['scale'])]
        for field in SCHEMA_FIELDS[8:]:
            require(row[field] in ('True','False','1','0'),'Source schema metadata boolean differs')
            values.append(row[field] in ('True','1'))
        normalized.append(values)
    return sorted(normalized,key=lambda row:(row[0].casefold(),row[1].casefold(),row[2]))


def account_fingerprint(row):
    # No bank account number, amount or name is stored in the public profile.
    return canonical_sha({key:row.get(key,'') for key in ('code','name','status')})


def source_bank_account_ancestor(row,source_styles):
    """Recognize the reviewed source bank root through real source parent IDs.

    Display codes are not relationships. A child reusing 102 is insufficient;
    every ancestor must be ACCOUNT, and exactly one qualifying root may exist.
    """
    if source_styles is None:return False
    styles={int(style['legacy_id']):style for style in source_styles}
    require(len(styles)==len(source_styles),'Duplicate source payment-style identity')
    roots=[style for style in source_styles if int(style.get('parent_legacy') or 0)==0
           and int(style['style_class_id'])==1 and style['code'].strip()=='102'
           and style['name'].strip()=='银行存款']
    require(len(roots)<=1,'Ambiguous source bank-deposit root requires review')
    cursor=int(row.get('style_legacy_id') or 0);seen=set();chain=[]
    while cursor:
        require(cursor not in seen,'Cyclic source account payment-style ancestry')
        require(cursor in styles,'Missing source account payment-style ancestor')
        seen.add(cursor);style=styles[cursor];chain.append(style)
        cursor=int(style.get('parent_legacy') or 0)
    return bool(chain and roots and chain[-1]['legacy_id']==roots[0]['legacy_id']
                and all(int(style['style_class_id'])==1 for style in chain))


def existing_account_projection(row,source_styles=None):
    """Mirror only the frozen, already-reviewed current CASE; never classify an unknown row."""
    name=row['name'];status=row.get('status','')
    if '香' in name:kind='OFFSHORE'
    elif '微' in name or '支付宝' in name:kind='THIRD_PARTY'
    elif '现金' in name:kind='CASH'
    elif name=='支票' and status=='禁用':kind='CHECK'
    elif name=='支票':kind='FOREIGN_CHECK'
    elif name in ('一般账户','一般帐户'):kind='GENERAL'
    elif any(word in name for word in ['农','工商','工行','建设','建行','交通','交行','招商','招行','邮政','信用社','兴业','中行','广发']) or name in ('中国银行','基本户'):kind='BANK'
    elif source_bank_account_ancestor(row,source_styles):kind='BANK'
    else:kind='GENERAL'
    return kind,3 if '香' in name else 1


def validate_reviewed_accounts(rows,profile,source_styles=None):
    approved={int(row['legacy_id']):row for row in profile['reviewed_accounts']}
    require(len(approved)==len(profile['reviewed_accounts']),'Reviewed account identity is repeated')
    actual={int(row['legacy_id']):row for row in rows}
    require(len(actual)==len(rows) and set(actual)==set(approved),'New or removed source account requires reviewed type/currency mapping')
    for identity,row in actual.items():
        expected=approved[identity]
        require(account_fingerprint(row)==expected['code_name_status_sha256'],'Renamed, recoded or status-changed source account requires classification review')
        kind,currency=existing_account_projection(row,source_styles)
        require((kind,currency)==(expected['account_type'],expected['currency_legacy_id']),
                'Reviewed account mapping is not supported by the frozen current type/currency projection')
    return len(actual)


def validate_source_completeness(audit_directory,raw_manifest_path,reference_directory,schema_contract_path,profile_contract_path,audit_generator_path):
    audit=Path(audit_directory);raw_path=Path(raw_manifest_path);reference=Path(reference_directory)
    raw=load(raw_path);manifest=load(audit/'audit-manifest.json');schema_contract=load(schema_contract_path);profile=load(profile_contract_path)
    require(manifest.get('format')=='source-completeness-audit-v1' and manifest.get('updateability')=='READ_ONLY'
            and manifest.get('isolation')=='Serializable','Fresh completeness audit must be physical read-only and serializable')
    require(manifest.get('raw_export_manifest_sha256')==digest(raw_path)
            and manifest.get('source_backup_sha256')==raw['sourceBackupSha256'],'Completeness audit belongs to another raw manifest or backup')
    require(manifest.get('generator_sha256')==digest(audit_generator_path),'Completeness audit generator differs from the frozen reviewed exporter')
    require(isinstance(raw.get('sourceSnapshotAsOfUtc'),str) and manifest.get('source_snapshot_as_of_utc')==raw['sourceSnapshotAsOfUtc'],
            'Completeness audit source cutoff differs from the raw export')
    require(type(manifest.get('backup_file')) is int and manifest['backup_file']>0,'Completeness audit lacks its reviewed backup-set position')
    inventory={row['file']:row for row in manifest['files']}
    require(len(inventory)==len(manifest['files']) and set(inventory)==FILES,'Completeness audit file inventory differs')
    data={};file_shas={}
    for name,item in inventory.items():
        path=audit/name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size==item['bytes'] and digest(path)==item['sha256'],'Completeness audit file bytes or SHA differs')
        require(type(item['rows']) is int and item['rows']>=0 and type(item['bytes']) is int and item['bytes']>=0,'Completeness audit count metadata is invalid')
        data[name]=records(path,expected_header=AUDIT_HEADERS.get(name));require(len(data[name])==item['rows'],'Completeness audit row count differs');file_shas[name]=item['sha256']
    columns=schema_rows(data['source_columns.csv'])
    require(schema_contract.get('format')=='legacy-source-schema-contract-v1' and schema_contract.get('fields')==SCHEMA_FIELDS
            and columns==schema_contract.get('columns'),'Source schema changed; new, removed or changed columns require review')
    table_rows=records(reference/'source_table_disposition_exact.csv',',')
    tables={(r['schema_name'].casefold(),r['table_name'].casefold()):int(r['actual_rows']) for r in table_rows}
    require(len(tables)==len(table_rows) and {(r[0].casefold(),r[1].casefold()) for r in columns}==set(tables),'Completeness schema and whole-table inventory differ')
    for table,file in [('SystemItem','system_item_full.csv'),('SystemPart','system_part_full.csv'),('MK_StockGoods','mk_stock_goods_full.csv')]:
        require(tables.get(('dbo',table.casefold()))==len(data[file]),'Completeness full source rows differ from exact table inventory')
    raw_files={r['file']:r for r in raw['files']}
    def raw_rows(name):
        item=raw_files[name];path=raw_path.parent/name
        require(path.is_file() and digest(path)==item['sha256'] and path.stat().st_size==item['bytes'],'Referenced raw source file differs')
        result=records(path);require(len(result)==item['rows'],'Referenced raw source count differs');return result
    require(profile.get('format')=='legacy-source-profile-contract-v1','Unsupported reviewed source profile contract')
    grouped={}
    item_ids=set()
    for row in data['system_item_full.csv']:
        identity=int(row['ItemID']);require(identity not in item_ids,'SystemItem identity is repeated');item_ids.add(identity)
        grouped.setdefault(int(row['ItemclassID']),[]).append(row)
    permission_ids=[row['ID'] for row in data['system_part_full.csv']]
    require(len(permission_ids)==len(set(permission_ids)),'SystemPart archival identity is repeated')
    claimed={int(r['item_class_id']):int(r['actual_rows']) for r in data['system_item_class_counts.csv']}
    require(len(claimed)==len(data['system_item_class_counts.csv']) and claimed=={k:len(v) for k,v in grouped.items()},'SystemItem full rows and class profiles differ')
    require(set(grouped)<=set(PARTITIONS),'Unreviewed nonempty SystemItem class requires a source disposition')
    partition_counts={}
    for kind,(name,policy) in PARTITIONS.items():
        values=grouped.get(kind,[]);partition_counts[str(kind)]={'rows':len(values),'policy':policy}
        if name:
            exported=raw_rows(name)
            # Historical departments deliberately project no parent. Preserve
            # its full original hierarchy in the SHA-bound archive; do not
            # pretend an omitted parent column was imported.
            def original(row):return (int(row['ItemID']),None if kind==5 else int(row['ParentID'] or '0'),row['Number'] or '',row['Name'] or '')
            def selected(row):return (int(row['legacy_id']),None if kind==5 else int(row.get('parent_legacy') or '0'),row.get('code') or '',row.get('name') or '')
            require(len(values)==len(exported) and sorted(map(original,values))==sorted(map(selected,exported)),
                    'Selected SystemItem source partition is not fully exported')
    accounts=raw_rows('m_acc.csv');account_count=validate_reviewed_accounts(accounts,profile,raw_rows('m_style.csv'))
    require(tables.get(('dbo','m_acc'))==len(accounts),'Reviewed source accounts are not a full-table export')
    categories={int(r['ItemID']) for r in grouped.get(10,[])}
    require(all(not int(r['parent_legacy_id'] or '0') or int(r['parent_legacy_id']) in categories for r in accounts),
            'Original account category reference is not covered by class10 source evidence')
    workshops=records(reference/'legacy_workshops_source.csv',',')
    require(tables.get(('dbo','b_workshop'))==len(workshops),'Reviewed workshop reference is not a full-table export')
    normalize=lambda text:unicodedata.normalize('NFKC',text).strip()
    names=[normalize(r['source_name']) for r in workshops];mirrors=[normalize(r['Name']) for r in grouped.get(12,[])]
    require(len(set(names))==len(names) and Counter(names)==Counter(mirrors),'Class12 source dictionary is not a unique workshop-name mirror; review independently')
    approved_workshops=set(profile['reviewed_workshop_name_sha256'])
    for name in names:
        require(hashlib.sha256(name.encode()).hexdigest() in approved_workshops
                or re.fullmatch(r'注塑[1-9][0-9]*号机|安装[1-9][0-9]*线',name),
                'New ordinary workshop needs an explicit department/source mapping review')
    zero_fields=profile['mk_stock_zero_fact_columns'];year_ceiling=profile['mk_stock_year_ceiling']
    require(type(year_ceiling) is int and len(zero_fields)==len(set(zero_fields)) and zero_fields,'Alternate stock reviewed scope is invalid')
    with (audit/'mk_stock_goods_full.csv').open(encoding='utf-8-sig',newline='') as stream:
        stock_header=next(csv.reader(stream,delimiter='|'))
    require(set(stock_header)==set(zero_fields)|STOCK_IDENTIFIERS and not set(zero_fields)&STOCK_IDENTIFIERS,
            'Alternate stock fact columns are not fully covered by the reviewed zero-scope policy')
    for row in data['mk_stock_goods_full.csv']:
        require(0<int(row['Year'])<=year_ceiling and all(row[name].strip() and Decimal(row[name]).is_finite() and Decimal(row[name])==0 for name in zero_fields),
                'Alternate stock ledger no longer satisfies the reviewed old zero-balance scope')
    return {'format':'source-completeness-proof-v1','validated':True,'audit_manifest_sha256':digest(audit/'audit-manifest.json'),
            'source_backup_sha256':raw['sourceBackupSha256'],'raw_manifest_sha256':digest(raw_path),
            'generator_sha256':digest(audit_generator_path),'source_snapshot_as_of_utc':raw['sourceSnapshotAsOfUtc'],
            'backup_file':manifest['backup_file'],
            'schema_contract_sha256':digest(schema_contract_path),'profile_contract_sha256':digest(profile_contract_path),
            'schema_columns':len(columns),'schema_tables':len(tables),'system_item_rows':len(data['system_item_full.csv']),
            'system_item_partitions':partition_counts,'reviewed_accounts':account_count,
            'system_part_archive_rows':len(data['system_part_full.csv']),'old_authorization_not_imported':True,
            'mk_stock_archive_rows':len(data['mk_stock_goods_full.csv']),'mk_stock_zero_scope_verified':True,
            'workshop_dictionary_namespace_merged':False,'workshops_reference_sha256':digest(reference/'legacy_workshops_source.csv'),
            'audit_file_sha256':file_shas}


def validate_bound_source_completeness(binding,raw_manifest_path,reference_directory,schema_contract_path,profile_contract_path,audit_generator_path):
    require(isinstance(binding,dict) and set(binding)=={'directory','proof'},'Prepared input lacks its frozen source completeness gate')
    proof=validate_source_completeness(binding['directory'],raw_manifest_path,reference_directory,schema_contract_path,profile_contract_path,audit_generator_path)
    require(proof==binding['proof'],'Prepared source completeness proof drift')
    return proof


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('audit','raw-manifest','reference','schema-contract','profile-contract','audit-generator','output'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    require(not args.output.exists(),'Use a new proof output path; existing receipts are never overwritten')
    proof=validate_source_completeness(args.audit,args.raw_manifest,args.reference,args.schema_contract,args.profile_contract,args.audit_generator)
    args.output.write_text(json.dumps(proof,ensure_ascii=True,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'validated':True,'schema_tables':proof['schema_tables'],'schema_columns':proof['schema_columns'],
                      'system_item_rows':proof['system_item_rows'],'reviewed_accounts':proof['reviewed_accounts']}))


if __name__=='__main__':main()
