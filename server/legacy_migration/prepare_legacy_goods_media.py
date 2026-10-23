#!/usr/bin/env python3
"""Scan original legacy images offline and prepare local objects plus controlled SQL.

Never connects to a business database. Only the signature updater has networking;
it never receives the media mount. The scanner gets a read-only mount and no network.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
NAMESPACE = uuid.UUID('a74104af-9e7e-46db-80b1-301bcdf9871e')
COLUMNS = ('GroundGraph', 'ProductGraph1', 'ProductGraph2', 'ProductGraph3',
           'ProductGraph4', 'ProductGraph5', 'ProductGraph6', 'BudgetGraph')


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def record(path: Path) -> dict:
    return {'path': str(path.resolve()), 'sha256': digest(path)}


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def command(args: list[str], log: Path | None = None, timeout: int = 240) -> str:
    result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8',
                            errors='replace', timeout=timeout)
    output = result.stdout + result.stderr
    if log:
        log.write_text(output, encoding='utf-8')
    if result.returncode:
        raise ValueError(f'{args[0]} failed ({result.returncode}); see {log or "command output"}')
    return output


def load_originals(manifest_path: Path, source_manifest_path: Path) -> tuple[dict, list[dict]]:
    manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    source = json.loads(source_manifest_path.read_text(encoding='utf-8-sig'))
    if (manifest.get('format') != 'uten-legacy-goods-original-media-v1'
            or manifest.get('database_updateability') != 'READ_ONLY'
            or manifest.get('read_only_queries') is not True
            or source.get('target') != 'All'
            or manifest['source_export_manifest_sha256'] != digest(source_manifest_path)
            or manifest['source_backup_sha256'] != source['sourceBackupSha256']):
        raise ValueError('Media must match its physically read-only All export')
    files = []
    identities = set()
    for item in manifest['files']:
        name = item['file']
        if Path(name).name != name or '/' in name or '\\' in name or ',' in name:
            raise ValueError('Unsafe original filename')
        path = manifest_path.parent / name
        identity = (item['legacy_goods_id'], item['source_column'])
        if (identity in identities or item['source_table'] != 'B_Goods'
                or item['source_column'] not in COLUMNS or item['content_type'] != 'image/jpeg'
                or path.stat().st_size != item['bytes'] or digest(path) != item['sha256']):
            raise ValueError('Original media identity, size or digest differs')
        identities.add(identity)
        attachment_id = uuid.uuid5(NAMESPACE, f'B_Goods:{identity[0]}:{identity[1]}:{item["sha256"]}')
        # These two originals have been visually reviewed. No general assumption
        # that a legacy GroundGraph column is a product photo is made here.
        reviewed = {(65184, 'ProductGraph1'): '正面', (65184, 'GroundGraph'): '背面'}
        if identity not in reviewed:
            raise ValueError('New legacy media needs a visual category review before publication')
        files.append({**item, 'source_path': str(path.resolve()), 'attachment_id': str(attachment_id),
                      'storage_key': attachment_id.hex + '.jpg', 'category': '产品图片',
                      'original_name': f'{item["goods_code"]}_{reviewed[identity]}_{identity[1]}.jpg'})
    for column in COLUMNS:
        if manifest['inventory'][column] != sum(f['source_column'] == column for f in files):
            raise ValueError('Media column inventory differs')
    return manifest, files


def validate_scan(output: str, files: list[dict]) -> None:
    if (not re.search(r'^\s*Infected files:\s*0\s*$', output, re.M)
            or not re.search(rf'^\s*Scanned files:\s*{len(files)}\s*$', output, re.M)):
        raise ValueError('Scan did not prove every original clean')
    for item in files:
        if output.splitlines().count('/media/' + item['file'] + ': OK') != 1:
            raise ValueError('Missing exact original clean scan result')
    if re.search(r'\b(FOUND|ERROR)\b', output):
        raise ValueError('Scanner reported a threat or error')


def literal(value: str) -> str:
    return "E'" + value.replace('\\', '\\\\').replace("'", "''").replace('\r', '\\r').replace('\n', '\\n') + "'"


def load_sql(files: list[dict], source: dict, target: str, proof: dict) -> str:
    # CSV is independently hash-verified by the coordinator. Embedded approved
    # rows also prevent a replaced CSV from injecting different CLEAN metadata.
    columns = ('attachment_id', 'legacy_goods_id', 'goods_code', 'storage_key', 'original_name',
               'content_type', 'bytes', 'sha256', 'category', 'scan_engine', 'scan_signature',
               'scanned_at', 'promoted_at')
    rows = [{k: item[k] for k in columns} for item in files]
    approved = literal(json.dumps(rows, ensure_ascii=False, separators=(',', ':')))
    proof_json = literal(json.dumps(proof, ensure_ascii=False, separators=(',', ':')))
    return f"""-- Prepared offline: real malware scan + standard LocalDiskStorageService.
-- Caller owns transaction; never disables triggers or changes users/passwords.
CREATE TEMP TABLE legacy_goods_media_stage (
 attachment_id uuid, legacy_goods_id integer, goods_code text, storage_key text, original_name text,
 content_type text, bytes bigint, sha256 text, category text, scan_engine text, scan_signature text,
 scanned_at timestamptz, promoted_at timestamptz
) ON COMMIT DROP;
\\copy legacy_goods_media_stage FROM '/tmp/goods_legacy_media.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE legacy_goods_media_approved ON COMMIT DROP AS
SELECT * FROM jsonb_populate_recordset(NULL::legacy_goods_media_stage,{approved}::jsonb);
DO $$ BEGIN
 IF current_database() IS DISTINCT FROM {literal(target)} THEN
   RAISE EXCEPTION 'Legacy media loader is restricted to its exact rehearsal candidate'; END IF;
 IF NOT EXISTS (SELECT 1 FROM legacy_migration_runs run
   WHERE run.run_id=NULLIF(current_setting('uten.bootstrap_run_id',true),'')::uuid
    AND run.migration_mode='BOOTSTRAP' AND run.status IN ('RUNNING','SUCCESS')
    AND run.reconciliation_summary->>'rawManifestSha256'={literal(source['source_export_manifest_sha256'])}
    AND run.source_backup_sha256={literal(source['source_backup_sha256'])}) THEN
   RAISE EXCEPTION 'Legacy media source differs from the sealed base import run'; END IF;
 IF NOT EXISTS (SELECT 1 FROM users WHERE id=NULLIF(current_setting('uten.rehearsal_actor_user_id',true),'')::uuid
   AND login_account='17665410007' AND is_super_admin AND status='active' AND NOT is_deleted) THEN
   RAISE EXCEPTION 'Legacy media requires the preserved administrator actor'; END IF;
 IF EXISTS ((SELECT * FROM legacy_goods_media_stage EXCEPT ALL SELECT * FROM legacy_goods_media_approved)
   UNION ALL (SELECT * FROM legacy_goods_media_approved EXCEPT ALL SELECT * FROM legacy_goods_media_stage)) THEN
   RAISE EXCEPTION 'Legacy media CSV differs from the scanned approved rows'; END IF;
 IF (SELECT count(*) FROM legacy_goods_media_stage)<>{len(files)} OR EXISTS (
   SELECT 1 FROM legacy_goods_media_stage stage LEFT JOIN goods ON goods.legacy_id=stage.legacy_goods_id
    AND goods.code=stage.goods_code AND NOT goods.is_deleted AND NOT goods.auto_created
   WHERE goods.id IS NULL) OR EXISTS (
   SELECT stage.attachment_id FROM legacy_goods_media_stage stage JOIN goods ON goods.legacy_id=stage.legacy_goods_id
    AND goods.code=stage.goods_code AND NOT goods.is_deleted AND NOT goods.auto_created
   GROUP BY stage.attachment_id HAVING count(*)<>1) THEN
   RAISE EXCEPTION 'Legacy media requires one exact live imported goods identity'; END IF;
 -- A replay only accepts the original frozen metadata. No immutable row is updated.
 IF EXISTS (SELECT 1 FROM legacy_goods_media_stage stage JOIN goods ON goods.legacy_id=stage.legacy_goods_id
   JOIN attachments a ON a.id=stage.attachment_id OR a.storage_key=stage.storage_key
   WHERE ROW(a.id,a.owner_type,a.owner_id,a.storage_key,a.original_name,a.content_type,a.size_bytes,a.sha256,
      a.storage_provider,a.storage_version,a.storage_etag,a.stored_size_bytes,a.storage_encoding,
      a.category,a.lifecycle_state,a.scan_engine,a.scan_signature,a.scanned_at,a.promoted_at)
    IS DISTINCT FROM ROW(stage.attachment_id,'GOODS'::varchar,goods.id,stage.storage_key,stage.original_name,
      stage.content_type,stage.bytes,stage.sha256,'local'::varchar,NULL::varchar,NULL::varchar,stage.bytes,
      'IDENTITY'::varchar,stage.category,'CLEAN'::varchar,stage.scan_engine,stage.scan_signature,stage.scanned_at,stage.promoted_at)) THEN
   RAISE EXCEPTION 'Existing attachment identity differs; never overwrite an original'; END IF;
END $$;
INSERT INTO attachments (id,owner_type,owner_id,storage_key,original_name,content_type,size_bytes,sha256,
 storage_provider,storage_version,storage_etag,stored_size_bytes,storage_encoding,category,lifecycle_state,
 scan_engine,scan_signature,scanned_at,promoted_at,created_by,updated_by)
SELECT stage.attachment_id,'GOODS',goods.id,stage.storage_key,stage.original_name,stage.content_type,stage.bytes,
 stage.sha256,'local',NULL,NULL,stage.bytes,'IDENTITY',stage.category,'CLEAN',stage.scan_engine,
 stage.scan_signature,stage.scanned_at,stage.promoted_at,
 current_setting('uten.rehearsal_actor_user_id')::uuid,current_setting('uten.rehearsal_actor_user_id')::uuid
FROM legacy_goods_media_stage stage JOIN goods ON goods.legacy_id=stage.legacy_goods_id AND goods.code=stage.goods_code
ON CONFLICT DO NOTHING;
DO $$ DECLARE matched integer; affected integer; BEGIN
 SELECT count(*) INTO matched FROM legacy_goods_media_stage stage JOIN attachments a
  ON a.id=stage.attachment_id AND a.lifecycle_state='CLEAN' AND a.sha256=stage.sha256
  JOIN goods ON goods.id=a.owner_id AND goods.legacy_id=stage.legacy_goods_id AND goods.code=stage.goods_code
  WHERE a.owner_type='GOODS' AND a.storage_provider='local' AND a.storage_version IS NULL
   AND a.stored_size_bytes=stage.bytes AND a.size_bytes=stage.bytes AND a.storage_encoding='IDENTITY';
 IF matched<>{len(files)} THEN RAISE EXCEPTION 'Legacy media attachment count or identity differs'; END IF;
 UPDATE legacy_migration_runs SET reconciliation_summary=COALESCE(reconciliation_summary,'{{}}'::jsonb)||
   jsonb_build_object('legacyGoodsMedia',{proof_json}::jsonb)
 WHERE run_id=current_setting('uten.bootstrap_run_id')::uuid AND migration_mode='BOOTSTRAP' AND status IN ('RUNNING','SUCCESS');
 GET DIAGNOSTICS affected=ROW_COUNT;
 IF affected<>1 THEN RAISE EXCEPTION 'Legacy media proof requires its base import run'; END IF;
END $$;
"""


def prepare(args) -> dict:
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source, files = load_originals(args.media_manifest, args.source_export_manifest)
    if not files:
        raise ValueError('No reviewed originals')
    if not re.fullmatch(r'clamav/clamav@sha256:[0-9a-f]{64}', args.clamav_image):
        raise ValueError('Use an explicitly pinned official ClamAV image digest')
    if ',' in str(args.media_manifest.parent.resolve()):
        raise ValueError('Docker mount path cannot contain comma')
    volume_mount = f'type=volume,source={args.clamav_db_volume},target=/var/lib/clamav'
    # No media path is provided to this network-enabled signature updater.
    command(['docker', 'run', '--rm', '--mount', volume_mount, '--entrypoint', 'freshclam',
             args.clamav_image, '--stdout'], output/'signature_update.log')
    common = ['docker', 'run', '--rm', '--network', 'none', '--read-only', '--tmpfs', '/tmp',
              '--mount', volume_mount + ',readonly']
    version = command([*common, '--entrypoint', 'clamscan', args.clamav_image, '--version']).strip()
    signatures = command([*common, '--entrypoint', '/bin/sh', args.clamav_image, '-c',
                          'sha256sum /var/lib/clamav/*.cvd /var/lib/clamav/*.cld'])
    # The shell may have a nonmatching glob for .cld or .cvd. Official freshclam
    # currently supplies both; a missing database fails closed rather than hides it.
    (output/'signature_hashes.log').write_text(signatures, encoding='utf-8')
    mount = 'type=bind,source=' + str(args.media_manifest.parent.resolve()) + ',target=/media,readonly'
    scan_args = [*common, '--mount', mount, '--entrypoint', 'clamscan', args.clamav_image,
                 '--official-db-only=yes', '--fail-if-cvd-older-than=2', '--max-filesize=25M',
                 '--max-scansize=25M', *['/media/' + item['file'] for item in files]]
    scan = command(scan_args, output/'scan.log')
    validate_scan(scan, files)
    scanned = datetime.now(timezone.utc).isoformat()
    for item in files:
        if digest(Path(item['source_path'])) != item['sha256']:
            raise ValueError('Original changed during scan')
    scan_receipt = {'format': 'uten-offline-clamav-scan-v1', 'verdict': 'CLEAN', 'engine': 'clamav',
                    'version': version, 'image': args.clamav_image, 'network': 'none',
                    'originals_mount': 'readonly', 'scanned_at': scanned,
                    'signature_database_hashes': signatures.splitlines(),
                    'log': record(output/'scan.log'), 'signature_update_log': record(output/'signature_update.log'),
                    'files': [{'file': f['file'], 'bytes': f['bytes'], 'sha256': f['sha256']} for f in files]}
    write_json(output/'scan_receipt.json', scan_receipt)
    write_json(output/'storage_plan.json', {'files': files})
    helper_classes = output/'helper-classes'
    helper_classes.mkdir(exist_ok=True)
    dependencies = args.classpath_file.read_text(encoding='utf-8').strip()
    classpath = str(args.server_classes.resolve()) + os.pathsep + dependencies
    helpers = [HERE/'java/LegacyMediaContentValidation.java', HERE/'java/LegacyMediaLocalStore.java']
    command(['javac', '-J-Dfile.encoding=UTF-8', '-proc:none', '-encoding', 'UTF-8', '-cp', classpath, '-d', str(helper_classes),
             *map(str, helpers)], output/'adapter_compile.log')
    command(['java', '-cp', str(helper_classes) + os.pathsep + classpath,
             'com.uten.imp.common.storage.LegacyMediaLocalStore', str(output/'storage_plan.json'),
             str(args.storage_root.resolve()), str(output/'storage_receipt.json')], output/'adapter.log')
    storage = json.loads((output/'storage_receipt.json').read_text(encoding='utf-8'))
    by_id = {item['attachment_id']: item for item in storage['files']}
    if len(by_id) != len(files):
        raise ValueError('Adapter receipt count differs')
    for item in files:
        actual = by_id[item['attachment_id']]
        if any(actual[key] != item[key] for key in ('storage_key', 'sha256', 'bytes')):
            raise ValueError('Adapter identity differs')
        if (actual['storage_provider'] != 'local' or actual['storage_version'] is not None
                or actual['storage_etag'] is not None or actual['stored_size_bytes'] != item['bytes']
                or actual['storage_encoding'] != 'IDENTITY' or actual['application_download_verifier'] != 'PASS'):
            raise ValueError('Adapter storage metadata differs')
        final = args.storage_root/'final'/item['storage_key']
        if final.stat().st_size != item['bytes'] or digest(final) != item['sha256']:
            raise ValueError('Final stored original differs')
        item.update(scan_engine='clamav', scan_signature=version[:255], scanned_at=scanned,
                    promoted_at=actual['promoted_at'])
    csv_columns = ('attachment_id', 'legacy_goods_id', 'goods_code', 'storage_key', 'original_name',
                   'content_type', 'bytes', 'sha256', 'category', 'scan_engine', 'scan_signature',
                   'scanned_at', 'promoted_at')
    with (output/'goods_legacy_media.csv').open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=csv_columns, delimiter='|', extrasaction='ignore')
        writer.writeheader(); writer.writerows(files)
    proof = {'rawManifestSha256': source['source_export_manifest_sha256'], 'originalMedia': record(args.media_manifest),
             'scan': record(output/'scan_receipt.json'), 'storage': record(output/'storage_receipt.json'),
             'count': len(files), 'provider': 'local', 'storageRoot': str(args.storage_root.resolve()),
             'files': [{k: f[k] for k in ('attachment_id','legacy_goods_id','goods_code','source_table','source_column','sha256','bytes','storage_key')} for f in files]}
    (output/'goods_legacy_media.sql').write_text(load_sql(files, source, args.target_database, proof), encoding='utf-8')
    adapter_sources = [HERE.parent/'src/main/java/com/uten/imp/common/storage/LocalDiskStorageService.java',
                       HERE.parent/'src/main/java/com/uten/imp/features/attachment/AttachmentContentInspector.java']
    evidence = [args.media_manifest.parent/f['file'] for f in files]
    evidence += [args.storage_root/'final'/f['storage_key'] for f in files]
    evidence += helpers + adapter_sources + [args.server_classes/'com/uten/imp/common/storage/LocalDiskStorageService.class',
                                             args.server_classes/'com/uten/imp/features/attachment/AttachmentContentInspector.class',
                                             args.server_classes/'com/uten/imp/features/attachment/AttachmentDownloadVerifier.class']
    evidence += sorted(helper_classes.rglob('*.class'))
    outputs = [p for p in output.iterdir() if p.is_file() and p.name != 'goods_legacy_media_manifest.json']
    manifest = {'format': 'uten-legacy-goods-media-import-v1', 'generator_sha256': digest(Path(__file__)),
                'inputs': [record(args.media_manifest), record(args.source_export_manifest)],
                'evidence_sources': [record(p) for p in evidence],
                'outputs': [dict(record(p), file=p.name) for p in sorted(outputs)],
                'summary': {'originals': len(files), 'bytes': sum(f['bytes'] for f in files),
                            'scan': 'CLEAN', 'networkDuringScan': 'none', 'databaseWrites': 0,
                            'targetDatabase': args.target_database, 'storageRoot': str(args.storage_root.resolve()),
                            'provider': 'local', 'version': None}}
    write_json(output/'goods_legacy_media_manifest.json', manifest)
    return manifest['summary']


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('media-manifest', 'source-export-manifest', 'storage-root', 'output-dir',
                 'server-classes', 'classpath-file'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--target-database', required=True)
    parser.add_argument('--clamav-image', required=True)
    parser.add_argument('--clamav-db-volume', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'uten_imp_rehearsal_[0-9]{8}_v[0-9]+', args.target_database):
        raise ValueError('Only an explicit isolated rehearsal candidate is supported')
    print(json.dumps(prepare(args), ensure_ascii=False))


if __name__ == '__main__':
    main()
