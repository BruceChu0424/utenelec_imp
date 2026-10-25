#!/usr/bin/env python3
"""Verify one sealed local import using read-only PostgreSQL snapshots.

Expected quantities come from the SHA-bound input manifest and HR/topology
evidence. No account row, password hash, name, key or complete run is emitted.
This is a post-import acceptance check, not a password-login or cutover test.
"""
import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

from verify_receipt_order_references import (source_inventory as receipt_reference_source_inventory,
    acceptance_sql as receipt_reference_acceptance_sql, validate as validate_receipt_reference_acceptance)


from verify_receipt_fee_styles import (source_inventory as receipt_fee_source_inventory,
    acceptance_sql as receipt_fee_acceptance_sql, validate as validate_receipt_fee_acceptance)

from verify_stock_typed_source_hashes import typed_source_hash as stock_typed_source_hash
from verify_stock_movement_checks import (source_inventory as stock_source_inventory,
    acceptance_sql as stock_acceptance_sql, validate as validate_stock_acceptance)

from verify_production_counter_baseline import (source_inventory as production_source_inventory,
    typed_source_facts as production_typed_source_facts, acceptance_sql as production_acceptance_sql,
    validate as validate_production_acceptance)
from verify_finance_master_sources import (source_inventory as finance_master_source_inventory,
    typed_source_facts as finance_master_typed_source_facts,sealed_seed_baseline as finance_sealed_seed_baseline,
    acceptance_sql as finance_master_acceptance_sql,validate as validate_finance_master_acceptance)
from verify_finance_flow_monthly import (source_inventory as finance_flow_source_inventory,
    typed_source_facts as finance_flow_typed_source_facts,acceptance_sql as finance_flow_acceptance_sql,
    validate as validate_finance_flow_acceptance)


class VerificationError(Exception):
    pass


COUNTER_SOURCES = (
    ('PURCHASE_ORDER_ITEM', 'purchase_order_items'),
    ('SALES_ORDER_ITEM', 'sales_order_items'),
    ('SALES_SHIPMENT_ITEM', 'sales_shipment_items'),
)


def counter_source_inventory(directory, records):
    """These three loaders currently declare no exclusions: require every source ID."""
    if not all(table + '.csv' in records for _, table in COUNTER_SOURCES):
        return None
    result = {}
    for kind, table in COUNTER_SOURCES:
        name = table + '.csv'
        with (directory / name).open(encoding='utf-8-sig', newline='') as stream:
            rows = csv.DictReader(stream, delimiter='|')
            ids = [int(row['legacy_id']) for row in rows]
        require(len(ids) == records[name]['rows'] and all(value > 0 for value in ids)
                and len(ids) == len(set(ids)), 'Historical counter source IDs are absent, duplicated or invalid')
        result[kind] = {'rows': len(ids), 'source_file': name, 'target_table': table,
                        'file_sha256': records[name]['sha256'],
                        'source_ids_sha256': hashlib.sha256(''.join(str(value) + '\n' for value in sorted(ids)).encode()).hexdigest()}
    return result


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def sha(value):
    require(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value), 'Invalid SHA-256 identity')
    return value


def child(directory, name):
    require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name), 'Unsafe manifest file name')
    path = directory / name
    require(path.is_file() and path.resolve().parent == directory.resolve(), 'Manifest file is absent or outside its directory')
    return path


def load_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def read_csv(path):
    with path.open(encoding='utf-8-sig', newline='') as stream:
        reader = csv.DictReader(stream, delimiter='|')
        require(reader.fieldnames and len(reader.fieldnames) == len(set(reader.fieldnames)), 'CSV header is absent or duplicated')
        rows = list(reader)
    require(all(None not in row for row in rows), 'CSV row has unexpected columns')
    return rows


def checked_record(directory, record):
    path = child(directory, record['file'])
    require(digest(path) == sha(record['sha256']), 'Sealed input SHA-256 differs')
    require(path.stat().st_size == record['bytes'], 'Sealed input byte count differs')
    return path


def load_inputs(directory, manifest_sha, frozen_commit, finance_seed_baseline=None, finance_seed_baseline_sha256=None):
    """Offline only; verify every executable input and derive acceptance facts."""
    directory = Path(directory)
    manifest_path = child(directory, 'derived_inputs.json')
    require(digest(manifest_path) == sha(manifest_sha), 'Input manifest SHA-256 differs')
    require(re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', frozen_commit), 'Invalid frozen commit identity')
    manifest = load_json(manifest_path)
    require(manifest.get('formatVersion') == 4 and manifest.get('target') == 'All', 'A complete format-4 manifest is required')
    provenance = manifest['provenance']
    require(provenance.get('inputKind') == 'derived-local-rehearsal-v1', 'Input manifest is not a derived local rehearsal')
    require(provenance.get('importerRepositoryCommit') == frozen_commit, 'Manifest frozen commit differs')
    finance_baseline=None
    if provenance.get('financeSeedBaselineSha256') is not None or finance_seed_baseline is not None or finance_seed_baseline_sha256 is not None:
        require(finance_seed_baseline is not None and finance_seed_baseline_sha256 is not None,
                'An explicit root-held finance seed baseline file and SHA are required')
        finance_baseline=finance_sealed_seed_baseline(directory,provenance,finance_seed_baseline,finance_seed_baseline_sha256,require=require)
    records = {}
    audited_files = {'derived_inputs.json': {'sha256': manifest_sha, 'bytes': manifest_path.stat().st_size}}
    if finance_baseline is not None:
        audited_files['finance_seed_baseline.json']={'sha256':finance_baseline['sha256'],'bytes':Path(finance_baseline['path']).stat().st_size}
    for record in manifest['files']:
        name = record['file']
        require(name not in records and name.endswith('.csv'), 'Manifest CSV name is duplicated or invalid')
        require(type(record['rows']) is int and record['rows'] >= 0, 'Invalid manifest row count')
        checked_record(directory, record)
        records[name] = record
        audited_files[name] = {'sha256': record['sha256'], 'bytes': record['bytes']}
    for name, expected_sha in provenance.get('extraInputs', {}).items():
        path = child(directory, name)
        require(digest(path) == sha(expected_sha), 'Sealed supplemental input SHA-256 differs')
        audited_files[name] = {'sha256': expected_sha, 'bytes': path.stat().st_size}
    for name in ('hr_rehearsal.csv', 'goods.csv', 'goods_bom.csv', 'goods_material_identity.csv', 'goods_legacy_media.csv'):
        require(name in records, 'A required verification CSV is absent')
    hr = read_csv(directory / 'hr_rehearsal.csv')
    require(len(hr) == records['hr_rehearsal.csv']['rows'], 'HR CSV row count differs')
    codes = [row['emp_code'] for row in hr]
    require(all(codes) and len(codes) == len(set(codes)) and 'ADMIN' not in codes, 'HR employee codes are missing, duplicated or contain ADMIN')
    statuses = Counter(row['status'] for row in hr)
    require(all(statuses), 'HR contains an empty status')
    statuses['active'] += 1  # The separately preserved ADMIN employee is not in the HR CSV.
    materials = read_csv(directory / 'goods_material_identity.csv')
    require(len(materials) == records['goods_material_identity.csv']['rows'], 'Material identity row count differs')
    require(all(row['status'] == 'PENDING_QUANTITY' for row in materials), 'Material identity CSV must contain pending quantities only')
    media = read_csv(directory / 'goods_legacy_media.csv')
    require(len(media) == records['goods_legacy_media.csv']['rows'], 'Media CSV row count differs')
    media_ids = [str(uuid.UUID(row['attachment_id'])) for row in media]
    require(len(media_ids) == len(set(media_ids)), 'Media identity is duplicated')

    layers = [(Path(path), record) for path, record in provenance.get('auxiliaryLayers', {}).items()
              if record['manifest'] == 'bom_topology_manifest.json']
    require(len(layers) == 1, 'Exactly one SHA-bound BOM topology layer is required')
    topology_dir, layer = layers[0]
    topology_manifest_path = child(topology_dir, layer['manifest'])
    require(digest(topology_manifest_path) == sha(layer['sha256']), 'BOM topology manifest SHA-256 differs')
    topology_manifest = load_json(topology_manifest_path)
    require(topology_manifest.get('valid') is True, 'BOM topology manifest is not valid')
    summaries = [item for item in topology_manifest['outputs'] if item['file'] == 'bom_topology_summary.json']
    require(len(summaries) == 1, 'BOM topology summary binding is absent or duplicated')
    summary_path = checked_record(topology_dir, summaries[0])
    topology = load_json(summary_path)
    require(topology.get('valid') is True and topology.get('source_conservation') is True, 'BOM topology summary is not valid and conserved')
    require(topology.get('cyclic_components') == 0 and topology.get('duplicate_active_parent_component_groups') == 0, 'BOM topology has cycles or duplicate active pairs')
    require(type(topology.get('retained_edges')) is int and topology['retained_edges'] >= 0, 'Invalid retained BOM edge count')
    require(topology.get('source_edges') == records['goods_bom.csv']['rows'], 'BOM summary source count differs')
    require(topology['retained_edges'] + topology['excluded_edges'] == topology['source_edges'], 'BOM source edges are not conserved')
    sha(topology['graph_sha256'])
    for name in ('goods.csv', 'goods_bom.csv'):
        matching = [item for item in topology_manifest['inputs'] if Path(item['path']).name == name]
        require(len(matching) == 1 and matching[0]['sha256'] == records[name]['sha256'], 'BOM topology source SHA-256 differs from the sealed inputs')
    return {
        'manifest_sha256': manifest_sha, 'frozen_commit': frozen_commit,
        'files': audited_files, 'csv_file_count': len(records),
        'employees': len(hr) + 1, 'employee_statuses': dict(sorted(statuses.items())),
        'regular_goods': records['goods.csv']['rows'], 'bom_items': topology['retained_edges'],
        'bom_graph_sha256': topology['graph_sha256'], 'material_identities': len(materials),
        'attachments': len(media), 'attachment_ids': media_ids,
        'topology_manifest_sha256': layer['sha256'], 'topology_summary_sha256': summaries[0]['sha256'],
        'counter_sources': counter_source_inventory(directory, records),
        'receipt_order_sources': receipt_reference_source_inventory(directory, records, provenance.get('extraInputs', {}), require=require),
        'receipt_fee_sources': receipt_fee_source_inventory(directory, records, require=require),
        'stock_movement_sources': stock_source_inventory(directory, records, provenance.get('extraInputs', {}), require=require),
        'production_counter_sources': production_source_inventory(directory, records, require=require),
        'finance_master_sources': finance_master_source_inventory(directory,records,require=require),
        'finance_flow_sources': finance_flow_source_inventory(directory,records,require=require),
        'finance_seed_baseline':finance_baseline,
        'finance_cash_source_policy_provenance':provenance.get('financeCashSourcePolicy'),
    }


class ReadOnlyDatabase:
    def __init__(self, database, container='uten-imp-postgres', user='uten',
                 expected_system_identifier=None, expected_database_oid=None):
        require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,62}', database), 'Invalid PostgreSQL database identifier')
        require(isinstance(container,str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}',container), 'Invalid local container identifier')
        require(isinstance(user,str) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,62}',user), 'Invalid PostgreSQL role identifier')
        require((expected_system_identifier is None)==(expected_database_oid is None), 'Expected cluster and database identities must be supplied together')
        if expected_system_identifier is not None:
            require(isinstance(expected_system_identifier,str) and re.fullmatch(r'[0-9]{1,20}',expected_system_identifier), 'Invalid expected PostgreSQL cluster identifier')
            require(type(expected_database_oid) is int and 0<expected_database_oid<=4294967295, 'Invalid expected PostgreSQL database OID')
        self.database = database
        self.container,self.user=container,user
        self.expected_identity=None if expected_system_identifier is None else (expected_system_identifier,expected_database_oid)
        self.actual_identity=None
        self.transport=None

    def _pin_transport(self):
        if self.transport is not None:return self.transport
        try:
            override=os.environ.get('DOCKER_HOST')
            require(not override or override.startswith(('npipe:','unix:')), 'Remote Docker endpoint refused')
            context=subprocess.check_output(['docker','context','show'],stderr=subprocess.PIPE,text=True,timeout=15).strip()
            require(re.fullmatch(r'[A-Za-z0-9_.-]+',context), 'Invalid Docker context')
            endpoint=json.loads(subprocess.check_output(['docker','context','inspect',context],stderr=subprocess.PIPE,text=True,timeout=15))
            require(len(endpoint)==1 and endpoint[0]['Endpoints']['docker']['Host'].startswith(('npipe:','unix:')), 'Remote Docker context refused')
            prefix=['docker','--context',context]
            identity=subprocess.check_output([*prefix,'inspect','--format','{{.Id}}',self.container],stderr=subprocess.PIPE,text=True,timeout=15).strip()
            require(re.fullmatch(r'[0-9a-f]{64}',identity), 'Local container identity is unavailable')
            self.transport=[*prefix,'exec','-i',identity]
            return self.transport
        except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError):
            raise VerificationError('Local Docker target could not be pinned; no target query was issued') from None

    def query(self, sql):
        require(sql.lstrip().startswith('SELECT '), 'Verifier accepts SELECT statements only')
        transport=self._pin_transport()
        # Identity and original facts are read within the same RR/READ ONLY
        # snapshot. A matching run from another local cluster is insufficient.
        envelope="SELECT jsonb_build_object('database',current_database(),'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),'result',("+sql.strip().rstrip(';')+"));"
        script = "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSET LOCAL search_path=pg_catalog,public;\nSET LOCAL TimeZone='Asia/Shanghai';\nSET LOCAL DateStyle='ISO, YMD';\n" + envelope + '\nCOMMIT;\n'
        result = subprocess.run(
            [*transport, 'psql', '-X', '-q', '-At',
             '-v', 'ON_ERROR_STOP=1', '-U', self.user, '-d', self.database],
            input=script.encode('utf-8'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(result.returncode == 0, 'Read-only PostgreSQL query failed; raw SQL and server output were withheld')
        lines = result.stdout.decode('utf-8').strip().splitlines()
        require(len(lines) == 1, 'Read-only query returned an unexpected number of rows')
        record=json.loads(lines[0])
        require(isinstance(record,dict) and record.get('database')==self.database, 'Read-only query reached a different database')
        identity=(record.get('system_identifier'),record.get('database_oid'))
        require(isinstance(identity[0],str) and re.fullmatch(r'[0-9]{1,20}',identity[0])
                and type(identity[1]) is int and identity[1]>0, 'Read-only physical database identity is unavailable')
        require(self.expected_identity is None or identity==self.expected_identity, 'Read-only physical database differs from the explicit target')
        require(self.actual_identity is None or identity==self.actual_identity, 'Read-only physical database changed between snapshots')
        self.actual_identity=identity
        require('result' in record, 'Read-only query facts are unavailable')
        return record['result']


def run_sql(run_id):
    return "SELECT jsonb_build_object('status',status,'reconciliation_status',reconciliation_status," \
        "'target',target,'mode',migration_mode,'exit_code',exit_code,'rejected_count',rejected_count," \
        "'manifest_sha256',export_manifest_sha256,'checksum_sha256',checksum_manifest_sha256," \
        "'frozen_commit',migration_repository_commit,'automated_checks',reconciliation_summary->'automatedCheckCount'," \
        "'mapping_version',mapping_version," \
        "'actual_schema_version',(SELECT max(version::int) FROM flyway_schema_history WHERE success)," \
        "'target_database',reconciliation_summary->>'targetDatabase'," \
        "'target_system_identifier',reconciliation_summary->>'targetSystemIdentifier'," \
        "'actual_database',current_database(),'actual_system_identifier',(SELECT system_identifier::text FROM pg_control_system())," \
        "'actual_database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database())," \
        "'bom_graph_sha256',reconciliation_summary->'bomTopology'->>'graph_sha256'," \
        "'bom_items',reconciliation_summary->'bomTopology'->'retained_edges'," \
        "'bom_identity_verified',reconciliation_summary->'bomTopology'->'target_edge_identity_verified'," \
        "'bom_exclusions_verified',reconciliation_summary->'bomTopology'->'target_exclusion_identity_verified') " \
        "FROM legacy_migration_runs WHERE run_id='" + run_id + "'::uuid;"


def validate_run(run, expected, database_name, renamed_from=None):
    require(run['status'] == 'SUCCESS' and run['reconciliation_status'] == 'PASSED', 'Import must be SUCCESS with PASSED reconciliation before result verification')
    require(run['target'] == '--bootstrap-all' and run['mode'] == 'BOOTSTRAP' and run['exit_code'] == 0 and run['rejected_count'] == 0, 'Run is not a successful complete bootstrap')
    require(run['manifest_sha256'] == expected['manifest_sha256'] and run['checksum_sha256'] == expected['manifest_sha256'], 'Run input manifest identity differs')
    require(run['frozen_commit'] == expected['frozen_commit'], 'Run frozen commit differs')
    require(type(run['automated_checks']) is int and run['automated_checks'] > 0, 'Run automated check count is absent')
    require(run['bom_graph_sha256'] == expected['bom_graph_sha256'] and run['bom_items'] == expected['bom_items'], 'Run BOM topology proof differs')
    require(run['bom_identity_verified'] is True and run['bom_exclusions_verified'] is True, 'Run lacks exact BOM edge and exclusion proof')
    require(run['actual_database'] == database_name, 'Connected database identity differs from the requested target')
    require(run['target_system_identifier'] and run['target_system_identifier'] == run['actual_system_identifier'], 'Connected PostgreSQL cluster differs from the recorded import target')
    if renamed_from is None:
        require(run['target_database'] == database_name, 'Import database was renamed; an explicit --renamed-from declaration is required')
    else:
        require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,62}', renamed_from), 'Invalid original database identifier')
        require(run['target_database'] == renamed_from and renamed_from != database_name, 'Declared database rename does not match the recorded import target')


def counter_baseline_sql(run_id, sources):
    """Aggregate only: never return historical quantities, source rows or descriptions."""
    branches = []
    routes = []
    for kind, table in COUNTER_SOURCES:
        source = sources[kind]
        name, file_sha = source['source_file'], sha(source['file_sha256'])
        routes.append("(source_kind='%s' AND target_table='%s' AND source_file='%s')" % (kind, table, name))
        branches.append("""SELECT '%s' AS kind,jsonb_build_object(
 'proof_rows',count(*),
 'source_ids_sha256',encode(digest(coalesce(string_agg(p.source_legacy_id::text||chr(10),'' ORDER BY p.source_legacy_id),''),'sha256'),'hex'),
 'wrong_file_sha',count(*) FILTER(WHERE p.source_file_sha256 IS DISTINCT FROM '%s'),
 'wrong_target_fields',count(*) FILTER(WHERE p.target_fields IS DISTINCT FROM public.fn_legacy_quantity_counter_bound_fields('%s')),
 'missing_or_mismatched_targets',count(*) FILTER(WHERE t.id IS NULL OR t.legacy_id IS DISTINCT FROM p.source_legacy_id OR t.legacy_counter_import_run_id IS DISTINCT FROM p.run_id),
 'changed_original_projections',count(*) FILTER(WHERE (CASE WHEN t.id IS NOT NULL THEN p.target_snapshot_sha256=encode(public.digest(public.fn_legacy_finance_snapshot(to_jsonb(t),p.target_fields)::text,'sha256'),'hex') ELSE false END) IS DISTINCT FROM true),
 'target_rows',(SELECT count(*) FROM public.%s WHERE legacy_id IS NOT NULL),
 'wrong_or_null_target_run',(SELECT count(*) FROM public.%s WHERE legacy_id IS NOT NULL AND legacy_counter_import_run_id IS DISTINCT FROM '%s'::uuid),
 'targets_without_exact_proof',(SELECT count(*) FROM public.%s target WHERE target.legacy_id IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM public.legacy_quantity_counter_import_sources proof WHERE proof.run_id='%s'::uuid AND proof.source_kind='%s'
   AND proof.target_table='%s' AND proof.source_file='%s' AND proof.target_id=target.id AND proof.source_legacy_id=target.legacy_id))) AS proof
 FROM public.legacy_quantity_counter_import_sources p LEFT JOIN public.%s t ON t.id=p.target_id
 WHERE p.run_id='%s'::uuid AND p.source_kind='%s' AND p.target_table='%s' AND p.source_file='%s'""" % (
            kind, file_sha, kind, table, table, run_id, table, run_id, kind, table, name,
            table, run_id, kind, table, name))
    return """SELECT jsonb_build_object(
 'total_proofs',(SELECT count(*) FROM public.legacy_quantity_counter_import_sources),
 'wrong_run_proofs',(SELECT count(*) FROM public.legacy_quantity_counter_import_sources WHERE run_id IS DISTINCT FROM '%s'::uuid),
 'unregistered_proof_routes',(SELECT count(*) FROM public.legacy_quantity_counter_import_sources WHERE (%s) IS NOT TRUE),
 'families',(SELECT jsonb_object_agg(kind,proof) FROM (%s) families),
 'historical_review_counts',jsonb_build_object(
   'purchase_order_received_gt_qty_plus_returned',(SELECT count(*) FROM purchase_order_items WHERE legacy_counter_import_run_id='%s'::uuid AND received_qty>qty+returned_qty),
   'purchase_order_returned_gt_received',(SELECT count(*) FROM purchase_order_items WHERE legacy_counter_import_run_id='%s'::uuid AND returned_qty>received_qty),
   'purchase_receipt_returned_gt_qty',(SELECT count(*) FROM purchase_receipt_items WHERE legacy_import_run_id='%s'::uuid AND returned_qty>qty),
   'sales_order_shipped_gt_qty_plus_returned',(SELECT count(*) FROM sales_order_items WHERE legacy_counter_import_run_id='%s'::uuid AND shipped_qty>qty+returned_qty),
   'sales_order_returned_gt_shipped',(SELECT count(*) FROM sales_order_items WHERE legacy_counter_import_run_id='%s'::uuid AND returned_qty>shipped_qty),
   'sales_shipment_returned_gt_qty',(SELECT count(*) FROM sales_shipment_items WHERE legacy_counter_import_run_id='%s'::uuid AND returned_qty>qty)))""" % (
            run_id, ' OR '.join(routes), ' UNION ALL '.join(branches), *([run_id] * 6))


def validate_counter_baseline(actual, sources):
    require(actual and isinstance(sources, dict), 'Historical counter baseline proof or sealed source inventory is absent')
    require(actual['total_proofs'] == sum(item['rows'] for item in sources.values()), 'Historical counter proof total differs from sealed sources')
    require(actual['wrong_run_proofs'] == 0 and actual['unregistered_proof_routes'] == 0, 'Historical counter evidence has a wrong run or unregistered route')
    require(set(actual['families']) == set(sources), 'Historical counter source families differ')
    for kind, source in sources.items():
        proof = actual['families'][kind]
        require(proof['proof_rows'] == source['rows'] and proof['target_rows'] == source['rows'], 'Historical counter proof/target quantity differs')
        require(proof['source_ids_sha256'] == source['source_ids_sha256'], 'Historical counter source identity set differs')
        for key in ('wrong_file_sha', 'wrong_target_fields', 'missing_or_mismatched_targets', 'changed_original_projections', 'wrong_or_null_target_run', 'targets_without_exact_proof'):
            require(proof[key] == 0, 'Historical counter invariant failed: ' + key)
    return {'verified': True, 'source_proof_rows': actual['total_proofs'],
            'family_rows': {kind: source['rows'] for kind, source in sources.items()},
            'original_projections_unchanged': True, 'exact_bidirectional_source_target_coverage': True,
            'historical_review_counts': actual['historical_review_counts'],
            'historical_review_is_finance_approval': False, 'verifier_changed_capacity': False}


def facts_sql(run_id, admin_id, attachment_ids, counter_sources=None, receipt_order_sources=None, receipt_fee_sources=None, stock_movement_sources=None, production_counter_sources=None, finance_master_sources=None, finance_seed_baseline=None, finance_flow_sources=None):
    ids = ','.join("'" + item + "'::uuid" for item in attachment_ids) or 'NULL::uuid'
    return """SELECT jsonb_build_object(
 'run',(%s),
 'user_count',(SELECT count(*) FROM users),
 'admin',(SELECT jsonb_build_object('id',u.id,'login_account',u.login_account,'password_hash',u.password_hash,'status',u.status,
   'super',u.is_super_admin,'deleted',u.is_deleted,'bound_admin',e.code='ADMIN' AND NOT e.is_deleted AND e.status='active')
   FROM users u LEFT JOIN employees e ON e.id=u.employee_id WHERE u.id='%s'::uuid),
 'counts',jsonb_build_object(
   'employees',(SELECT count(*) FROM employees),
   'deleted_employees',(SELECT count(*) FROM employees WHERE is_deleted),
   'employee_statuses',(SELECT coalesce(jsonb_object_agg(status,n),'{}'::jsonb) FROM (SELECT status,count(*) n FROM employees WHERE NOT is_deleted GROUP BY status) s),
   'regular_goods',(SELECT count(*) FROM goods WHERE NOT auto_created),
   'goods',(SELECT count(*) FROM goods),
   'bom_items',(SELECT count(*) FROM goods_bom_items WHERE NOT is_deleted),
   'disabled_bom_components',(SELECT count(*) FROM goods_bom_items b JOIN goods g ON g.id=b.component_goods_id WHERE NOT b.is_deleted AND (g.status<>'使用' OR g.is_deleted)),
   'material_identities',(SELECT count(*) FROM goods_material_identity_evidence),
   'invalid_material_identities',(SELECT count(*) FROM goods_material_identity_evidence i JOIN goods g ON g.id=i.material_goods_id
      WHERE i.is_deleted OR i.status<>'PENDING_QUANTITY' OR i.import_run_id IS DISTINCT FROM '%s'::uuid OR g.is_deleted OR g.status='禁用'),
   'identity_relations_in_active_bom',(SELECT count(*) FROM goods_material_identity_evidence i WHERE EXISTS
      (SELECT 1 FROM goods_bom_items b WHERE NOT b.is_deleted AND b.goods_id=i.product_goods_id AND b.component_goods_id=i.material_goods_id)),
   'attachments',(SELECT count(*) FROM attachments WHERE owner_type='GOODS'),
   'matched_clean_attachments',(SELECT count(*) FROM attachments WHERE id IN (%s) AND owner_type='GOODS' AND lifecycle_state='CLEAN'),
   'schema_version',(SELECT max(version::int) FROM flyway_schema_history WHERE success),
   'failed_migrations',(SELECT count(*) FROM flyway_schema_history WHERE NOT success)),
 'bom_graph_sha256',(SELECT encode(digest(convert_to(coalesce(string_agg(b.legacy_id::text||':'||p.legacy_id::text||':'||c.legacy_id::text||':'||b.qty::text||chr(10),'' ORDER BY b.legacy_id),''),'UTF8'),'sha256'),'hex')
   FROM goods_bom_items b JOIN goods p ON p.id=b.goods_id JOIN goods c ON c.id=b.component_goods_id WHERE NOT b.is_deleted),
 'checks',(SELECT jsonb_build_object('total',count(*),'passed',count(*) FILTER (WHERE passed)) FROM legacy_migration_reconciliation_items WHERE run_id='%s'::uuid),
 'run_files',(SELECT coalesce(jsonb_object_agg(file_name,jsonb_build_object('sha256',sha256,'bytes',byte_size)),'{}'::jsonb) FROM legacy_migration_run_files WHERE run_id='%s'::uuid),
 'quantity_counter_baseline',(%s),
 'receipt_order_references',(%s),
 'receipt_fee_styles',(%s),
 'stock_movement_checks',(%s),
 'production_counter_baseline',(%s),
 'finance_master_sources',(%s),
 'finance_flow_monthly',(%s)
);""" % (run_sql(run_id).rstrip(';'), admin_id, run_id, ids, run_id, run_id,
          counter_baseline_sql(run_id, counter_sources) if counter_sources is not None else 'SELECT null::jsonb',
          receipt_reference_acceptance_sql(run_id, receipt_order_sources) if receipt_order_sources is not None else 'SELECT null::jsonb',
          receipt_fee_acceptance_sql(run_id, receipt_fee_sources) if receipt_fee_sources is not None else 'SELECT null::jsonb',
          stock_acceptance_sql(run_id, stock_movement_sources) if stock_movement_sources is not None else 'SELECT null::jsonb',
          production_acceptance_sql(run_id, production_counter_sources) if production_counter_sources is not None else 'SELECT null::jsonb',
          finance_master_acceptance_sql(run_id,finance_master_sources,finance_seed_baseline) if finance_master_sources is not None else 'SELECT null::jsonb',
          finance_flow_acceptance_sql(run_id,finance_flow_sources) if finance_flow_sources is not None else 'SELECT null::jsonb')


def verify_database(database, expected, original, run_id, expected_schema=None, renamed_from=None, pre_rename_proof=None):
    run_id = str(uuid.UUID(run_id))
    admin_id = str(uuid.UUID(original['id']))
    require(isinstance(original.get('password_hash'), str) and original['password_hash'], 'Protected account snapshot lacks a password hash')
    initial_run = database.query(run_sql(run_id))
    validate_run(initial_run, expected, database.database, renamed_from)  # Fail before any account/business queries.
    mapping = re.fullmatch(r'bootstrap-v([0-9]+)', initial_run.get('mapping_version') or '')
    if mapping is not None and int(mapping[1])>=21:
        v21_receipt_fee=expected.get('receipt_fee_sources')
        require(v21_receipt_fee is not None and v21_receipt_fee.get('cash_source_policy') is not None,'V21 requires the exact reviewed live+archive cash source policy')
        policy=expected.get('finance_cash_source_policy_provenance')
        require(isinstance(policy,dict) and policy.get('format')=='finance-cash-source-archive-policy-v1' and policy.get('sha256')==v21_receipt_fee['cash_source_policy']['policy_sha256'] and policy.get('evidence_files')==v21_receipt_fee['cash_source_policy']['files'],'V21 cash policy and portable evidence are not sealed in this derived manifest')
    announced_schema = initial_run.get('actual_schema_version')
    require(announced_schema is None or (type(announced_schema) is int and announced_schema > 0), 'Invalid actual schema announcement')
    if mapping is not None and int(mapping[1])>=21:
        require(announced_schema is not None and announced_schema>=916,'V21 cash source archive verification requires the actual complete finance schema')
    requires_finance_flow_schema=(expected_schema is not None and expected_schema>=916) or (announced_schema is not None and announced_schema>=916)
    if requires_finance_flow_schema:
        require(mapping is not None and int(mapping[1])>=19,'V916 verification requires bootstrap-v19 finance flow monthly source verification')
    strict_finance_flow=mapping is not None and int(mapping[1])>=19
    finance_flow_sources=expected.get('finance_flow_sources') if strict_finance_flow else None
    if strict_finance_flow:
        require(announced_schema is not None and announced_schema>=916,'bootstrap-v19 verification requires the actual V916 schema')
        require(finance_flow_sources is not None,'Protocol19 requires complete sealed finance flow/account/currency/document sources')
    requires_finance_master_schema=(expected_schema is not None and expected_schema>=914) or (announced_schema is not None and announced_schema>=914)
    if requires_finance_master_schema:
        require(mapping is not None and int(mapping[1])>=18,'V914 verification requires bootstrap-v18 finance master source verification')
    strict_finance_masters=mapping is not None and int(mapping[1])>=18
    finance_master_sources=expected.get('finance_master_sources') if strict_finance_masters else None
    finance_seed_baseline=expected.get('finance_seed_baseline') if strict_finance_masters else None
    if strict_finance_masters:
        require(announced_schema is not None and announced_schema>=914,'bootstrap-v18 verification requires the actual V914 schema')
        require(finance_master_sources is not None and finance_seed_baseline is not None,'Protocol18 requires complete finance masters and the independently captured sealed seed anchor')
    requires_production_schema = (expected_schema is not None and expected_schema >= 913) or (announced_schema is not None and announced_schema >= 913)
    if requires_production_schema:
        require(mapping is not None and int(mapping[1]) >= 17, 'V913 result verification requires bootstrap-v17 or newer mapping')
    strict_production_counters = mapping is not None and int(mapping[1]) >= 17
    if strict_production_counters:
        require(announced_schema is not None and announced_schema >= 913, 'bootstrap-v17 production verification requires the V913 actual target schema')
    production_counter_sources = expected.get('production_counter_sources') if strict_production_counters else None
    require(not strict_production_counters or production_counter_sources is not None, 'V913 production protocol requires complete sealed item/parent/upstream sources')
    requires_fee_schema = (expected_schema is not None and expected_schema >= 912) or (announced_schema is not None and announced_schema >= 912)
    if requires_fee_schema:
        require(mapping is not None and int(mapping[1]) >= 15, 'V912 result verification requires bootstrap-v15 or newer mapping')
        require(announced_schema is None or announced_schema >= 912, 'Receipt fee source verification requires the V912 target schema')
    if expected_schema is not None and expected_schema >= 909:
        require(mapping is not None and int(mapping[1]) >= 15, 'V909 result verification requires bootstrap-v15 or newer mapping')
    if expected_schema is not None and expected_schema >= 908:
        require(mapping is not None and int(mapping[1]) >= 14, 'V908 result verification requires bootstrap-v14 or newer mapping')
    strict_counters = (strict_production_counters or expected_schema is None or expected_schema >= 908) and mapping is not None and int(mapping[1]) >= 14
    counter_sources = expected.get('counter_sources') if strict_counters else None
    require(not strict_counters or counter_sources is not None, 'V908 counter protocol requires all three sealed source inventories')
    strict_receipt_references = (strict_production_counters or expected_schema is None or expected_schema >= 909) and mapping is not None and int(mapping[1]) >= 15
    receipt_order_sources = expected.get('receipt_order_sources') if strict_receipt_references else None
    require(not strict_receipt_references or receipt_order_sources is not None, 'V909 receipt protocol requires both complete sealed source inventories and warehouse decisions')
    strict_receipt_fee_styles = requires_fee_schema and mapping is not None and int(mapping[1]) >= 15
    receipt_fee_sources = expected.get('receipt_fee_sources') if strict_receipt_fee_styles else None
    require(not strict_receipt_fee_styles or receipt_fee_sources is not None, 'V912 receipt fee protocol requires the complete sealed m_get source inventory')
    strict_stock_movements = mapping is not None and int(mapping[1]) >= 16
    stock_movement_sources = expected.get('stock_movement_sources') if strict_stock_movements else None
    require(not strict_stock_movements or stock_movement_sources is not None, 'bootstrap-v16 requires all sealed stock sources and warehouse decisions')
    if strict_stock_movements:
        stock_movement_sources = dict(stock_movement_sources)
        stock_movement_sources['nonposting_source_rows_sha256'] = stock_typed_source_hash(stock_movement_sources)
    if strict_production_counters:
        production_counter_sources = dict(production_counter_sources)
        production_counter_sources['typed_source_facts'] = production_typed_source_facts(production_counter_sources)
    if strict_finance_masters:
        finance_master_sources=dict(finance_master_sources)
        finance_master_sources['typed_source_facts']=finance_master_typed_source_facts(finance_master_sources,finance_seed_baseline)
    if strict_finance_flow:
        finance_flow_sources=dict(finance_flow_sources)
        finance_flow_sources['typed_source_facts']=finance_flow_typed_source_facts(finance_flow_sources)
    facts = database.query(facts_sql(run_id, admin_id, expected['attachment_ids'], counter_sources, receipt_order_sources, receipt_fee_sources, stock_movement_sources, production_counter_sources,finance_master_sources,finance_seed_baseline,finance_flow_sources))
    validate_run(facts['run'], expected, database.database, renamed_from)  # Recheck in the same repeatable-read snapshot as all facts.
    require(initial_run['actual_database_oid'] == facts['run']['actual_database_oid'], 'Database OID changed between read-only snapshots')
    require(initial_run.get('mapping_version') == facts['run'].get('mapping_version'), 'Run mapping version changed between read-only snapshots')
    require(facts['user_count'] == 1, 'Exactly the preserved protected account must exist')
    admin = facts['admin']
    require(admin and admin['id'] == admin_id and admin['password_hash'] == original['password_hash']
            and admin['login_account'] == original['login_account'], 'Protected account identity or password hash differs')
    require(admin['status'] == 'active' and admin['super'] is True and admin['deleted'] is False and admin['bound_admin'] is True, 'Protected account eligibility or ADMIN employee binding differs')
    counts = facts['counts']
    if counts['schema_version']>=916:require(strict_finance_flow,'Actual V916 schema requires the protocol19 finance flow monthly gate')
    if strict_finance_flow:require(counts['schema_version']>=916,'Finance flow monthly verification requires the actual V916 schema')
    if counts['schema_version']>=914:require(strict_finance_masters,'Actual V914 schema requires the protocol18 finance master gate')
    if strict_finance_masters:require(counts['schema_version']>=914,'Finance master source verification requires the actual V914 schema')
    if counts['schema_version'] >= 912:
        require(strict_receipt_fee_styles, 'V912 actual schema requires bootstrap-v15 receipt fee source verification')
    if strict_receipt_fee_styles:
        require(counts['schema_version'] >= 912, 'Receipt fee source verification requires the V912 target schema')
    if announced_schema is not None:
        require(announced_schema == counts['schema_version'] and facts['run'].get('actual_schema_version') == announced_schema,
                'Target schema changed between read-only snapshots')
    if counts['schema_version'] >= 913:
        require(strict_production_counters, 'V913 actual schema requires bootstrap-v17 production baseline verification')
    if strict_production_counters:
        require(counts['schema_version'] >= 913, 'Production historical baseline verification requires the V913 target schema')
    if counts['schema_version'] >= 909:
        require(strict_receipt_references, 'V909 actual schema requires bootstrap-v15 receipt source verification')
    if strict_receipt_references:
        require(counts['schema_version'] >= 909, 'Receipt source verification requires the V909 target schema')
    for key in ('employees', 'employee_statuses', 'regular_goods', 'bom_items', 'material_identities', 'attachments'):
        require(counts[key] == expected[key], 'Target quantity or employee status distribution differs: ' + key)
    for key in ('deleted_employees', 'disabled_bom_components', 'invalid_material_identities', 'identity_relations_in_active_bom', 'failed_migrations'):
        require(counts[key] == 0, 'Target invariant failed: ' + key)
    require(counts['matched_clean_attachments'] == expected['attachments'], 'Sealed media identities are absent or not CLEAN')
    require(facts['bom_graph_sha256'] == expected['bom_graph_sha256'], 'Actual current BOM graph differs from sealed topology')
    if expected_schema is not None:
        require(counts['schema_version'] == expected_schema, 'Target schema version differs')
    checks = facts['checks']
    require(checks['total'] == facts['run']['automated_checks'] and checks['passed'] == checks['total'], 'Persisted structural checks are incomplete or failed')
    for name, record in expected['files'].items():
        require(facts['run_files'].get(name) == record, 'Consumed run file identity differs')
    counter_proof = validate_counter_baseline(facts.get('quantity_counter_baseline'), counter_sources) if strict_counters else None
    receipt_reference_proof = validate_receipt_reference_acceptance(facts.get('receipt_order_references'), receipt_order_sources, require=require) if strict_receipt_references else None
    receipt_fee_proof = validate_receipt_fee_acceptance(facts.get('receipt_fee_styles'), receipt_fee_sources, require=require, run_id=run_id) if strict_receipt_fee_styles else None
    stock_movement_proof = validate_stock_acceptance(facts.get('stock_movement_checks'), stock_movement_sources, require=require) if strict_stock_movements else None
    production_counter_proof = validate_production_acceptance(facts.get('production_counter_baseline'), production_counter_sources, require=require) if strict_production_counters else None
    finance_master_proof=validate_finance_master_acceptance(facts.get('finance_master_sources'),finance_master_sources,finance_seed_baseline,require=require) if strict_finance_masters else None
    finance_flow_proof=validate_finance_flow_acceptance(facts.get('finance_flow_monthly'),finance_flow_sources,require=require) if strict_finance_flow else None
    database_identity = {'system_identifier': facts['run']['actual_system_identifier'],
                         'database_oid': facts['run']['actual_database_oid']}
    if finance_master_proof is not None:
        require(finance_master_proof['origin_database_identity']==database_identity,'Finance master seed proof differs from the actual generic physical database')
    if production_counter_proof is not None and production_counter_proof['context_rows']:
        require(production_counter_proof['origin_database_identity']==database_identity
                and production_counter_proof['recorded_origin_database']==facts['run']['target_database'],
                'Production context differs from the actual imported database or recorded rename origin')
    if renamed_from is not None:
        require(isinstance(pre_rename_proof, dict), 'An explicit rename requires --pre-rename-proof from the first successful pre-rename verification')
        for key, value in {'status': 'PASSED', 'run_id': run_id, 'manifest_sha256': expected['manifest_sha256'],
                           'frozen_commit': expected['frozen_commit'], 'database': renamed_from,
                           'database_name_mode': 'UNCHANGED', 'recorded_import_database': renamed_from,
                           'database_identity': database_identity, 'counts': counts,
                           'bom_graph_sha256': expected['bom_graph_sha256'],
                           'protected_account_uuid_and_password_hash_preserved': True,
                           'protected_account_active_super_and_admin_bound': True}.items():
            require(pre_rename_proof.get(key) == value, 'Pre-rename receipt continuity differs: ' + key)
        if counter_proof is not None:
            require(pre_rename_proof.get('quantity_counter_baseline') == counter_proof, 'Pre-rename historical counter baseline proof differs')
        if receipt_reference_proof is not None:
            require(pre_rename_proof.get('receipt_order_references') == receipt_reference_proof, 'Pre-rename receipt source proof differs')
        if receipt_fee_proof is not None:
            require(pre_rename_proof.get('receipt_fee_styles') == receipt_fee_proof, 'Pre-rename receipt fee source proof differs')
        if stock_movement_proof is not None:
            require(pre_rename_proof.get('stock_movement_checks') == stock_movement_proof, 'Pre-rename stock movement source proof differs')
        if production_counter_proof is not None:
            require(pre_rename_proof.get('production_counter_baseline') == production_counter_proof, 'Pre-rename production historical baseline proof differs')
        if finance_master_proof is not None:
            require(pre_rename_proof.get('finance_master_sources')==finance_master_proof,'Pre-rename finance master proof or seed anchor differs')
        if finance_flow_proof is not None:
            require(pre_rename_proof.get('finance_flow_monthly')==finance_flow_proof,'Pre-rename finance flow monthly source projection differs')
    # Return only an explicit safe projection; never return facts/admin/the entire run.
    report = {'status': 'PASSED', 'run_id': run_id, 'counts': counts, 'structural_checks': checks,
            'verified_input_files': len(expected['files']), 'bom_graph_sha256': facts['bom_graph_sha256'],
            'database_identity_verified': True, 'recorded_import_database': facts['run']['target_database'],
            'database_identity': database_identity, 'claim_database_oid_recorded': False,
            'database_name_mode': 'EXPLICIT_RENAME' if renamed_from else 'UNCHANGED',
            'protected_account_uuid_and_password_hash_preserved': True,
            'protected_account_active_super_and_admin_bound': True, 'actual_password_login_tested': False}
    if counter_proof is not None:
        report['quantity_counter_baseline'] = counter_proof
        report['mapping_version'] = initial_run['mapping_version']
    if receipt_reference_proof is not None:
        report['receipt_order_references'] = receipt_reference_proof
        report['mapping_version'] = initial_run['mapping_version']
    if receipt_fee_proof is not None:
        report['receipt_fee_styles'] = receipt_fee_proof
        if receipt_fee_proof.get('finance_cash_source_archive') is not None:
            report['finance_cash_source_archive']=receipt_fee_proof['finance_cash_source_archive']
        report['mapping_version'] = initial_run['mapping_version']
    if stock_movement_proof is not None:
        report['stock_movement_checks'] = stock_movement_proof
        report['mapping_version'] = initial_run['mapping_version']
    if production_counter_proof is not None:
        report['production_counter_baseline'] = production_counter_proof
        report['mapping_version'] = initial_run['mapping_version']
    if finance_master_proof is not None:
        report['finance_master_sources']=finance_master_proof
        report['mapping_version']=initial_run['mapping_version']
    if finance_flow_proof is not None:
        report['finance_flow_monthly']=finance_flow_proof
        report['mapping_version']=initial_run['mapping_version']
    return report


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('--inputs', type=Path, required=True)
    result.add_argument('--admin-snapshot', type=Path, required=True)
    result.add_argument('--run-id', required=True)
    result.add_argument('--database', required=True)
    result.add_argument('--container',default='uten-imp-postgres')
    result.add_argument('--user',default='uten')
    result.add_argument('--expected-system-identifier')
    result.add_argument('--expected-database-oid',type=int)
    result.add_argument('--manifest-sha256', required=True)
    result.add_argument('--frozen-commit', required=True)
    result.add_argument('--output', type=Path, required=True)
    result.add_argument('--expected-schema', type=int)
    result.add_argument('--finance-seed-baseline',type=Path)
    result.add_argument('--finance-seed-baseline-sha256')
    result.add_argument('--renamed-from', help='Recorded import database name when verifying the same imported database after an explicit rename')
    result.add_argument('--pre-rename-proof', type=Path, help='Successful pre-rename verifier receipt; mandatory with --renamed-from')
    result.add_argument('--offline-only', action='store_true', help='Verify sealed inputs only; do not query a database or claim target acceptance')
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        require(not args.output.exists(), 'Refusing to overwrite an existing verification receipt')
        require(args.expected_schema is None or args.expected_schema > 0, 'Expected schema must be positive')
        require(bool(args.renamed_from) == bool(args.pre_rename_proof), '--renamed-from and --pre-rename-proof must be supplied together')
        require(bool(args.finance_seed_baseline)==bool(args.finance_seed_baseline_sha256),'Finance seed baseline file and root-held SHA must be supplied together')
        expected = load_inputs(args.inputs, args.manifest_sha256, args.frozen_commit,args.finance_seed_baseline,args.finance_seed_baseline_sha256)
        run_id = str(uuid.UUID(args.run_id))
        database = ReadOnlyDatabase(args.database,args.container,args.user,args.expected_system_identifier,args.expected_database_oid)
        if args.offline_only:
            report = {'status': 'INPUTS_VERIFIED_TARGET_NOT_QUERIED', 'run_id': run_id,
                      'expected_counts': {key: expected[key] for key in ('employees', 'employee_statuses', 'regular_goods', 'bom_items', 'material_identities', 'attachments')},
                      'actual_password_login_tested': False}
        else:
            previous = load_json(args.pre_rename_proof) if args.pre_rename_proof else None
            report = verify_database(database, expected, load_json(args.admin_snapshot), run_id, args.expected_schema, args.renamed_from, previous)
            if args.pre_rename_proof:
                report['pre_rename_proof_sha256'] = digest(args.pre_rename_proof)
        report.update(database=args.database, manifest_sha256=args.manifest_sha256,
                      frozen_commit=args.frozen_commit, topology_manifest_sha256=expected['topology_manifest_sha256'],
                      topology_summary_sha256=expected['topology_summary_sha256'],
                      checked_at_utc=datetime.now(timezone.utc).isoformat(), production_acceptance=False)
        with args.output.open('x', encoding='utf-8') as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        print(json.dumps(report, ensure_ascii=False))
        return 0
    except (VerificationError, KeyError, ValueError, OSError, TypeError) as error:
        message = str(error) if isinstance(error, VerificationError) else 'Invalid or unavailable verification input; raw values were withheld'
        print(json.dumps({'status': 'FAILED', 'reason': message}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
