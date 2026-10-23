"""Independent file-to-target personnel metadata verification; no database I/O.

The caller obtains archive, run_metadata and target_documents in one real
REPEATABLE READ READ ONLY snapshot. No builder functions are imported here.
"""
from pathlib import Path
import argparse
import csv
import hashlib
import io
import json
import re
import uuid


def _check(condition, reason):
    if not condition:
        raise ValueError(reason)


def _strict_equal(actual, expected, label):
    _check(type(actual) is type(expected), 'Personnel archive type mismatch: ' + label)
    if isinstance(expected, dict):
        _check(set(actual) == set(expected), 'Personnel archive key mismatch: ' + label)
        for key, value in expected.items():
            _strict_equal(actual[key], value, label + '.' + str(key))
    elif isinstance(expected, list):
        _check(len(actual) == len(expected), 'Personnel archive list length mismatch: ' + label)
        for index, value in enumerate(expected):
            _strict_equal(actual[index], value, label + '[' + str(index) + ']')
    else:
        _check(actual == expected, 'Personnel archive mismatch: ' + label)


def _source_number(value, nullable=False):
    if nullable and value in ('', '0', None):
        return None
    _check(isinstance(value, str) and bool(value) and set(value) <= set('0123456789'), 'Invalid source personnel integer')
    result = int(value)
    _check(0 < result <= 2147483647, 'Source personnel integer out of range')
    return result


def _source_expectation(inputs, run_id, manifest_sha256, frozen_commit, mapping_version):
    inputs = Path(inputs).resolve()
    run_id = str(uuid.UUID(str(run_id)))
    raw = (inputs/'derived_inputs.json').read_bytes()
    _strict_equal(hashlib.sha256(raw).hexdigest(), manifest_sha256, 'sealed manifest SHA')
    manifest = json.loads(raw.decode('utf-8-sig'))
    _strict_equal(manifest.get('target'), 'All', 'full import target')
    provenance = manifest.get('provenance', {})
    _strict_equal(provenance.get('importerRepositoryCommit'), frozen_commit, 'frozen importer commit')
    _check(re.fullmatch(r'bootstrap-v([1-9][0-9]*)', mapping_version or '') is not None and
           int(mapping_version.removeprefix('bootstrap-v')) >= 18, 'Personnel archive protocol is older than v18')
    generator_sha = provenance.get('scripts', {}).get('personnel_source_archive.py')
    _check(re.fullmatch('[0-9a-f]{64}', generator_sha or '') is not None, 'Missing frozen personnel archive generator')
    source_files = ['legacy_operators_ref.csv', 'sales_orders.csv', 'sales_other_shipments.csv',
                    'sales_returns.csv', 'sales_shipments.csv', 'subcontract_order_m.csv', 'subcontract_swaste_m.csv']
    declared = {}
    for item in manifest.get('files', []):
        _check(item.get('file') not in declared, 'Repeated file declaration')
        declared[item['file']] = item
    parsed, files = {}, {}
    for name in source_files:
        _check(name in declared, 'Missing bound personnel CSV')
        path = inputs/name
        _check(path.resolve().parent == inputs, 'Personnel CSV is outside the packet')
        data = path.read_bytes()
        item = declared[name]
        _strict_equal(hashlib.sha256(data).hexdigest(), item.get('sha256'), 'source CSV SHA ' + name)
        _strict_equal(len(data), item.get('bytes'), 'source CSV size ' + name)
        reader = csv.DictReader(io.StringIO(data.decode('utf-8-sig'), newline=''), delimiter='|')
        headings = reader.fieldnames or []
        _check(len(headings) == len(set(headings)), 'Repeated source CSV heading')
        need = {'legacy_id', 'name'} if name == 'legacy_operators_ref.csv' else {'legacy_id', 'maker_legacy', 'approver_legacy', 'status'}
        _check(need <= set(headings), 'Missing source actor columns')
        _check(name != 'legacy_operators_ref.csv' or set(headings) == need, 'Operator dictionary includes unrelated fields')
        rows = list(reader)
        _strict_equal(len(rows), item.get('rows'), 'source CSV rows ' + name)
        unique_ids = set()
        for row in rows:
            _check(None not in row and all(v is not None for v in row.values()), 'Malformed source CSV record')
            identity = _source_number(row['legacy_id'])
            _check(identity not in unique_ids, 'Repeated source document identity')
            unique_ids.add(identity)
        parsed[name] = rows
        files[name] = dict(file=name, sha256=item['sha256'], bytes=len(data), rows=len(rows))
    operators = {_source_number(row['legacy_id']): row['name'] for row in parsed['legacy_operators_ref.csv']}
    actors, header_status = {}, {}
    for kind, file in [('SUBCONTRACT_ORDER', 'subcontract_order_m.csv'), ('SUBCONTRACT_WASTE', 'subcontract_swaste_m.csv')]:
        for row in parsed[file]:
            old_id = _source_number(row['legacy_id'])
            header_status[(kind, old_id)] = int(row.get('status') or 0)
            for field in ('maker_legacy', 'approver_legacy'):
                actor = _source_number(row[field], nullable=True)
                if actor is None:
                    continue
                _check(actor in operators, 'Source header references an absent source operator')
                actors[(kind, old_id, field)] = dict(kind=kind, legacyDocId=old_id, sourceFile=file,
                    sourceField=field, actorLegacyId=actor, sourceDisplayName=operators[actor])
    metadata = dict(format='legacy-personnel-source-archive-v1',
        displayNameMeaning='备份时源账号显示名；不代表单据当时实际审批身份', runId=run_id,
        derivedManifestSha256=manifest_sha256, rawManifestSha256=provenance.get('rawManifestSha256'),
        sourceBackupSha256=provenance.get('rawSourceBackupSha256'), sourceSnapshotAsOfUtc=manifest.get('sourceSnapshotAsOfUtc'),
        frozenCommit=frozen_commit, mappingVersion=mapping_version, generatorSha256=generator_sha,
        operatorCount=len(operators), unmaterializedHeaderActorCount=len(actors),
        namesAreHistoricalApprovalIdentity=False, employeeOrUserAccountsCreated=False,
        archiveDoesNotPopulateBusinessNameColumns=True)
    return metadata, files, operators, actors, header_status


def verify_personnel_source_archive(inputs, run_id, manifest_sha256, frozen_commit, mapping_version,
                                    actual_archive, *, target_documents=None, run_metadata=None):
    metadata, files, operators, actors, header_status = _source_expectation(
        inputs, run_id, manifest_sha256, frozen_commit, mapping_version)
    _check(isinstance(actual_archive, dict), 'Missing target personnelSourceArchive object')
    _strict_equal(set(actual_archive), set(metadata) | {'sourceFiles', 'operators', 'unmaterializedHeaderActors'}, 'archive keys')
    for key, value in metadata.items():
        _strict_equal(actual_archive[key], value, key)
    _check(isinstance(run_metadata, dict), 'Independent actual run metadata is required')
    expected_run = dict(runId=metadata['runId'], status='SUCCESS', reconciliationStatus='PASSED',
        manifestSha256=manifest_sha256, frozenCommit=frozen_commit, mappingVersion=mapping_version,
        backupSha256=metadata['sourceBackupSha256'], rawManifestSha256=metadata['rawManifestSha256'],
        sourceSnapshotAsOfUtc=metadata['sourceSnapshotAsOfUtc'])
    for key, value in expected_run.items():
        _strict_equal(run_metadata.get(key), value, 'actual run ' + key)
    _check(isinstance(actual_archive['sourceFiles'], list), 'Invalid source file archive')
    actual_files = {}
    for item in actual_archive['sourceFiles']:
        _check(isinstance(item, dict) and item.get('file') not in actual_files, 'Duplicate archived source file')
        actual_files[item.get('file')] = item
    _strict_equal(actual_files, files, 'complete source-file set and hashes')
    _check(isinstance(actual_archive['operators'], list), 'Invalid operator dictionary')
    actual_operators = {}
    for row in actual_archive['operators']:
        _check(isinstance(row, dict) and set(row) == {'sourceOperatorLegacyId', 'sourceDisplayName'}, 'Invalid dictionary record shape')
        identity = row['sourceOperatorLegacyId']
        _check(type(identity) is int and identity not in actual_operators, 'Invalid or duplicate dictionary identity')
        _check(type(row['sourceDisplayName']) is str, 'Invalid archived display-name type')
        actual_operators[identity] = row['sourceDisplayName']
    _strict_equal(actual_operators, operators, 'full source operator dictionary')
    _check(isinstance(target_documents, list), 'Independently read actual target document anchors are required')
    anchors = {}
    for document in target_documents:
        _check(isinstance(document, dict), 'Invalid actual target anchor')
        key = document.get('kind'), document.get('legacyDocId')
        _check(key[0] in {'SUBCONTRACT_ORDER', 'SUBCONTRACT_WASTE'} and type(key[1]) is int and key[1] > 0
               and key not in anchors, 'Ambiguous actual document legacy identity')
        target_id = document.get('targetDocumentId')
        _check(type(target_id) is str and str(uuid.UUID(target_id)) == target_id, 'Invalid actual document UUID')
        anchors[key] = document
    actual_refs = {}
    _check(isinstance(actual_archive['unmaterializedHeaderActors'], list), 'Invalid unmaterialized actor archive')
    for row in actual_archive['unmaterializedHeaderActors']:
        expected_keys = {'kind', 'legacyDocId', 'sourceFile', 'sourceField', 'actorLegacyId', 'sourceDisplayName', 'targetDocumentId'}
        _check(isinstance(row, dict) and set(row) == expected_keys, 'Invalid archived header actor shape')
        _check(type(row['legacyDocId']) is int and type(row['actorLegacyId']) is int, 'Invalid archived actor identity type')
        key = row['kind'], row['legacyDocId'], row['sourceField']
        _check(key in actors and key not in actual_refs, 'Unknown or duplicate archived source actor')
        header_key = key[:2]
        _check(header_key in anchors, 'Archived actor target document is missing')
        document = anchors[header_key]
        _strict_equal(document.get('status'), header_status[header_key], 'actual header status')
        _strict_equal(row, {**actors[key], 'targetDocumentId':document['targetDocumentId']}, 'full source actor plus actual target UUID')
        if key[0] == 'SUBCONTRACT_ORDER':
            _check(document.get('legacyImportRunId') in (None, metadata['runId']), 'Order belongs to another source run')
            if header_status[header_key] == 1:
                for field, expected in [('legacyImportRunId', metadata['runId']), ('sourceProofRunId', metadata['runId']),
                    ('sourceProofTargetId', document['targetDocumentId']), ('sourceProofLegacyId', key[1])]:
                    _strict_equal(document.get(field), expected, 'actual order proof ' + field)
        actual_refs[key] = row
    _strict_equal(set(actual_refs), set(actors), 'complete unmaterialized header actor set')
    return dict(verified=True, evidenceMode='SOURCE_FILES_AND_SUPPLIED_READONLY_TARGET_SNAPSHOT',
        runId=metadata['runId'], manifestSha256=manifest_sha256, frozenCommit=frozen_commit,
        operatorDictionaryCount=len(operators), headerActorReferenceCount=len(actors),
        anchoredTargetDocumentCount=len({key[:2] for key in actors}), sourceFileCount=len(files),
        archivedDisplayNamesAreBackupSourceMetadata=True, createsEmployeeOrUserAccounts=False,
        archiveDoesNotPopulateBusinessNameColumns=True)


def render_personnel_source_archive_verification_sql(run_id):
    run_id = str(uuid.UUID(str(run_id)))
    return """BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='120s';
SELECT jsonb_build_object(
  'archive',run.reconciliation_summary->'personnelSourceArchive',
  'run_metadata',jsonb_build_object('runId',run.run_id,'status',run.status,
    'reconciliationStatus',run.reconciliation_status,'manifestSha256',run.export_manifest_sha256,
    'frozenCommit',run.migration_repository_commit,'mappingVersion',run.mapping_version,
    'backupSha256',run.source_backup_sha256,'rawManifestSha256',run.reconciliation_summary->>'rawManifestSha256',
    'sourceSnapshotAsOfUtc',run.reconciliation_summary->>'sourceSnapshotAsOfUtc'),
  'target_documents',COALESCE((SELECT jsonb_agg(anchor) FROM (
    SELECT jsonb_build_object('kind','SUBCONTRACT_ORDER','legacyDocId',document.legacy_id,
      'targetDocumentId',document.id,'status',document.status,'legacyImportRunId',document.legacy_import_run_id,
      'sourceProofRunId',proof.run_id,'sourceProofTargetId',proof.order_id,'sourceProofLegacyId',proof.source_legacy_id) anchor
    FROM public.subcontract_orders document
    LEFT JOIN public.legacy_subcontract_order_import_sources proof
      ON proof.run_id=document.legacy_import_run_id AND proof.order_id=document.id AND proof.source_legacy_id=document.legacy_id
    WHERE document.legacy_id IS NOT NULL
    UNION ALL
    SELECT jsonb_build_object('kind','SUBCONTRACT_WASTE','legacyDocId',document.legacy_id,
      'targetDocumentId',document.id,'status',document.status,'legacyImportRunId',NULL,
      'sourceProofRunId',NULL,'sourceProofTargetId',NULL,'sourceProofLegacyId',NULL)
    FROM public.subcontract_wastes document WHERE document.legacy_id IS NOT NULL
  ) source_anchors),'[]'::jsonb))
FROM public.legacy_migration_runs run WHERE run.run_id='%s'::uuid;
ROLLBACK;
""" % run_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--frozen-commit', required=True)
    parser.add_argument('--mapping-version', required=True)
    parser.add_argument('--actual-snapshot-json', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--emit-readonly-sql', type=Path)
    args = parser.parse_args()
    if args.emit_readonly_sql:
        with args.emit_readonly_sql.open('x', encoding='utf-8') as stream:
            stream.write(render_personnel_source_archive_verification_sql(args.run_id))
    if args.actual_snapshot_json:
        actual = json.loads(args.actual_snapshot_json.read_text(encoding='utf-8-sig'))
        result = verify_personnel_source_archive(args.inputs, args.run_id, args.manifest_sha256,
            args.frozen_commit, args.mapping_version, actual['archive'],
            target_documents=actual['target_documents'], run_metadata=actual['run_metadata'])
        if args.output:
            with args.output.open('x', encoding='utf-8') as stream:
                stream.write(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
        print(json.dumps(result))
    else:
        print(json.dumps(dict(status='READONLY_SQL_PREPARED_NOT_EXECUTED')))


if __name__ == '__main__':
    main()
