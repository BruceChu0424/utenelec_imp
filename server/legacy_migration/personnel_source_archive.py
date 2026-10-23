"""Archive legacy account display names as run metadata, never user accounts.

The returned SQL belongs after every source-proof registration and before the
bootstrap run is marked SUCCESS. No target business row or actor UUID changes.
"""
from pathlib import Path
import argparse
import csv
import hashlib
import io
import json
import re
import uuid


FORMAT = 'legacy-personnel-source-archive-v1'
NAME_MEANING = '备份时源账号显示名；不代表单据当时实际审批身份'
SOURCE_FILES = (
    'legacy_operators_ref.csv', 'sales_orders.csv', 'sales_other_shipments.csv',
    'sales_returns.csv', 'sales_shipments.csv', 'subcontract_order_m.csv',
    'subcontract_swaste_m.csv',
)
HEADER_ACTORS = (
    ('SUBCONTRACT_ORDER', 'subcontract_order_m.csv', ('maker_legacy', 'approver_legacy')),
    ('SUBCONTRACT_WASTE', 'subcontract_swaste_m.csv', ('maker_legacy', 'approver_legacy')),
)


def _hash(data):
    return hashlib.sha256(data).hexdigest()


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _positive_id(value, label, nullable=False):
    if nullable and value in ('', '0', None):
        return None
    _require(isinstance(value, str) and re.fullmatch(r'[0-9]+', value) is not None,
             'Invalid integer source identity: ' + label)
    result = int(value)
    _require(0 < result <= 2147483647, 'Source identity out of range: ' + label)
    return result


def inspect_personnel_archive_sources(inputs, manifest):
    """Source-only projection; safe before final run/freeze identities exist."""
    inputs = Path(inputs).resolve()
    declared = {}
    for entry in manifest.get('files', []):
        name = entry.get('file')
        _require(name not in declared, 'Duplicate manifest file')
        declared[name] = entry
    loaded, file_metadata = {}, []
    for name in SOURCE_FILES:
        _require(name in declared, 'Personnel source file is not manifest-bound: ' + name)
        path = inputs/name
        _require(path.resolve().parent == inputs, 'Personnel source escaped the sealed input directory')
        data = path.read_bytes()
        entry = declared[name]
        _require(_hash(data) == entry.get('sha256'), 'Personnel CSV SHA mismatch: ' + name)
        _require(len(data) == entry.get('bytes'), 'Personnel CSV byte-size mismatch: ' + name)
        reader = csv.DictReader(io.StringIO(data.decode('utf-8-sig'), newline=''), delimiter='|')
        fields = reader.fieldnames
        _require(fields is not None and len(fields) == len(set(fields)), 'Invalid personnel CSV header: ' + name)
        required = {'legacy_id', 'name'} if name == 'legacy_operators_ref.csv' else {'legacy_id', 'maker_legacy', 'approver_legacy', 'status'}
        _require(required <= set(fields), 'Missing personnel source columns: ' + name)
        if name == 'legacy_operators_ref.csv':
            _require(set(fields) == required, 'Operator reference must contain only ID and display name')
        rows = list(reader)
        _require(type(entry.get('rows')) is int and len(rows) == entry['rows'], 'Personnel CSV row-count mismatch: ' + name)
        seen = set()
        for row in rows:
            _require(None not in row and all(value is not None for value in row.values()), 'Malformed personnel CSV row: ' + name)
            source_id = _positive_id(row['legacy_id'], name)
            _require(source_id not in seen, 'Duplicate personnel source row: ' + name)
            seen.add(source_id)
        loaded[name] = rows
        file_metadata.append(dict(file=name, sha256=entry['sha256'], bytes=len(data), rows=len(rows)))
    operators = {}
    for row in loaded['legacy_operators_ref.csv']:
        source_id = _positive_id(row['legacy_id'], 'Sys_Operator')
        operators[source_id] = row['name']
    references = []
    for kind, name, fields in HEADER_ACTORS:
        for row in loaded[name]:
            document = _positive_id(row['legacy_id'], name)
            for field in fields:
                actor = _positive_id(row[field], name + '.' + field, nullable=True)
                if actor is None:
                    continue
                _require(actor in operators, 'Unresolved source operator: ' + name + '.' + field)
                references.append(dict(kind=kind, legacyDocId=document, sourceFile=name,
                    sourceField=field, actorLegacyId=actor, sourceDisplayName=operators[actor], targetDocumentId=None))
    return dict(sourceFiles=file_metadata,
        operators=[dict(sourceOperatorLegacyId=key, sourceDisplayName=operators[key]) for key in sorted(operators)],
        unmaterializedHeaderActors=sorted(references, key=lambda row:(row['kind'], row['legacyDocId'], row['sourceField'])))


def build_personnel_source_archive(inputs, run_id, manifest_sha256, frozen_commit, mapping_version):
    inputs = Path(inputs).resolve()
    run_id = str(uuid.UUID(str(run_id)))
    _require(re.fullmatch('[0-9a-f]{64}', manifest_sha256 or '') is not None, 'Invalid final manifest SHA')
    _require(re.fullmatch('[0-9a-f]{40,64}', frozen_commit or '') is not None, 'Invalid frozen commit')
    protocol = re.fullmatch(r'bootstrap-v([1-9][0-9]*)', mapping_version or '')
    _require(protocol is not None and int(protocol[1]) >= 18, 'Personnel archive requires bootstrap-v18 or newer')
    manifest_data = (inputs/'derived_inputs.json').read_bytes()
    _require(_hash(manifest_data) == manifest_sha256, 'Final manifest SHA mismatch')
    manifest = json.loads(manifest_data.decode('utf-8-sig'))
    provenance = manifest.get('provenance', {})
    _require(manifest.get('target') == 'All', 'Personnel archive requires the full sealed packet')
    _require(provenance.get('importerRepositoryCommit') == frozen_commit, 'Frozen source commit mismatch')
    raw_sha, backup_sha = provenance.get('rawManifestSha256'), provenance.get('rawSourceBackupSha256')
    _require(all(re.fullmatch('[0-9a-f]{64}', value or '') for value in (raw_sha, backup_sha)), 'Missing raw manifest or backup SHA')
    cutoff = manifest.get('sourceSnapshotAsOfUtc')
    _require(isinstance(cutoff, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z', cutoff), 'Missing source backup cutoff')
    generator_sha = _hash(Path(__file__).read_bytes())
    _require(provenance.get('scripts', {}).get(Path(__file__).name) == generator_sha,
             'Archive generator differs from the frozen packet')
    projection = inspect_personnel_archive_sources(inputs, manifest)
    return dict(format=FORMAT, displayNameMeaning=NAME_MEANING, runId=run_id,
        derivedManifestSha256=manifest_sha256, rawManifestSha256=raw_sha, sourceBackupSha256=backup_sha,
        sourceSnapshotAsOfUtc=cutoff, frozenCommit=frozen_commit, mappingVersion=mapping_version,
        generatorSha256=generator_sha, operators=projection['operators'], sourceFiles=projection['sourceFiles'],
        unmaterializedHeaderActors=projection['unmaterializedHeaderActors'], operatorCount=len(projection['operators']),
        unmaterializedHeaderActorCount=len(projection['unmaterializedHeaderActors']),
        namesAreHistoricalApprovalIdentity=False, employeeOrUserAccountsCreated=False,
        archiveDoesNotPopulateBusinessNameColumns=True)


def render_personnel_source_archive_sql(inputs, run_id, manifest_sha256, frozen_commit, mapping_version):
    archive = build_personnel_source_archive(inputs, run_id, manifest_sha256, frozen_commit, mapping_version)
    payload = json.dumps(archive, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8').hex()
    # Hex transports arbitrary account display text without SQL-literal escaping,
    # client backslash settings, or interpolation of source text into SQL syntax.
    return """-- Late metadata flush only: source-account display names at backup time.
DO $personnel_source_archive$
DECLARE
    archive jsonb := convert_from(decode('%s','hex'),'UTF8')::jsonb;
    run_row public.legacy_migration_runs%%ROWTYPE;
    source_reference jsonb;
    resolved_references jsonb := '[]'::jsonb;
    document_id uuid;
    document_run uuid;
    document_status smallint;
    matched integer;
    created_here boolean;
    updated integer;
BEGIN
    PERFORM public.fn_require_legacy_subcontract_bootstrap((archive->>'runId')::uuid);
    SELECT * INTO STRICT run_row FROM public.legacy_migration_runs
      WHERE run_id=(archive->>'runId')::uuid FOR UPDATE;
    IF run_row.status IS DISTINCT FROM 'RUNNING' OR run_row.finished_at IS NOT NULL
       OR run_row.mapping_version IS DISTINCT FROM archive->>'mappingVersion'
       OR run_row.migration_repository_commit IS DISTINCT FROM archive->>'frozenCommit'
       OR run_row.export_manifest_sha256::text IS DISTINCT FROM archive->>'derivedManifestSha256'
       OR run_row.source_backup_sha256::text IS DISTINCT FROM archive->>'sourceBackupSha256'
       OR run_row.reconciliation_summary->>'rawManifestSha256' IS DISTINCT FROM archive->>'rawManifestSha256'
       OR run_row.reconciliation_summary->>'sourceSnapshotAsOfUtc' IS DISTINCT FROM archive->>'sourceSnapshotAsOfUtc' THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='personnel source archive run lineage mismatch';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(archive->'sourceFiles') source_file
        LEFT JOIN public.legacy_migration_run_files registered
          ON registered.run_id=run_row.run_id AND registered.file_name=source_file->>'file'
        WHERE registered.sha256::text IS DISTINCT FROM source_file->>'sha256'
           OR registered.byte_size IS DISTINCT FROM (source_file->>'bytes')::bigint
    ) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='personnel source archive file lineage mismatch';
    END IF;
    FOR source_reference IN SELECT value FROM jsonb_array_elements(archive->'unmaterializedHeaderActors') LOOP
        IF source_reference->>'kind'='SUBCONTRACT_ORDER' THEN
            SELECT count(*),min(document.id::text)::uuid,min(document.legacy_import_run_id::text)::uuid,
                   min(document.status),bool_and(document.xmin::text::bigint=(txid_current() %% 4294967296))
              INTO matched,document_id,document_run,document_status,created_here
              FROM public.subcontract_orders document
             WHERE document.legacy_id=(source_reference->>'legacyDocId')::integer;
            IF matched<>1 OR NOT COALESCE(created_here,false)
               OR (document_run IS NOT NULL AND document_run<>run_row.run_id)
               OR (document_status=1 AND (document_run IS DISTINCT FROM run_row.run_id OR NOT EXISTS (
                    SELECT 1 FROM public.legacy_subcontract_order_import_sources proof
                    WHERE proof.run_id=run_row.run_id AND proof.order_id=document_id
                      AND proof.source_legacy_id=(source_reference->>'legacyDocId')::integer))) THEN
                RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='personnel source archive order target is not the unique current-run header';
            END IF;
        ELSIF source_reference->>'kind'='SUBCONTRACT_WASTE' THEN
            SELECT count(*),min(document.id::text)::uuid,
                   bool_and(document.xmin::text::bigint=(txid_current() %% 4294967296))
              INTO matched,document_id,created_here
              FROM public.subcontract_wastes document
             WHERE document.legacy_id=(source_reference->>'legacyDocId')::integer;
            IF matched<>1 OR NOT COALESCE(created_here,false) THEN
                RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='personnel source archive waste target is not the unique newly imported header';
            END IF;
        ELSE
            RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='personnel source archive target namespace is unsupported';
        END IF;
        resolved_references:=resolved_references||jsonb_build_array(source_reference||jsonb_build_object('targetDocumentId',document_id));
    END LOOP;
    archive:=jsonb_set(archive,'{unmaterializedHeaderActors}',resolved_references,true);
    IF run_row.reconciliation_summary ? 'personnelSourceArchive'
       AND run_row.reconciliation_summary->'personnelSourceArchive' IS DISTINCT FROM archive THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='personnel source archive already contains different evidence';
    END IF;
    UPDATE public.legacy_migration_runs
       SET reconciliation_summary=jsonb_set(reconciliation_summary,'{personnelSourceArchive}',archive,true)
     WHERE run_id=run_row.run_id AND status='RUNNING' AND finished_at IS NULL;
    GET DIAGNOSTICS updated = ROW_COUNT;
    IF updated<>1 THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='personnel source archive requires exactly one running run';
    END IF;
END;
$personnel_source_archive$;
""" % payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--frozen-commit', required=True)
    parser.add_argument('--mapping-version', required=True)
    parser.add_argument('--output-json', type=Path)
    parser.add_argument('--output-sql', type=Path)
    args = parser.parse_args()
    values = dict(inputs=args.inputs, run_id=args.run_id, manifest_sha256=args.manifest_sha256,
                  frozen_commit=args.frozen_commit, mapping_version=args.mapping_version)
    archive = build_personnel_source_archive(**values)
    if args.output_json:
        with args.output_json.open('x', encoding='utf-8') as stream:
            stream.write(json.dumps(archive, ensure_ascii=False, indent=2)+'\n')
    if args.output_sql:
        with args.output_sql.open('x', encoding='utf-8') as stream:
            stream.write(render_personnel_source_archive_sql(**values))
    print(json.dumps(dict(status='FILES_PREPARED_NOT_EXECUTED', operators=archive['operatorCount'],
                         unmaterializedHeaderActors=archive['unmaterializedHeaderActorCount'])))


if __name__ == '__main__':
    main()
