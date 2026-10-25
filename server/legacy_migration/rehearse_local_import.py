#!/usr/bin/env python3
"""Windows-native local rehearsal of the reviewed legacy SQL loaders.

Never rewrites an export manifest. Raw export, cleaned dictionaries, HR roster,
and Excel overlay retain separate hashes. The derived inventory is explicitly
labelled and is used only for target reconciliation. All business loaders run
in one transaction with the existing claim, fresh-target and final guards.
This entry point cannot target the ordinary database or a remote server.
"""
from __future__ import annotations

import argparse
import contextlib
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

import compose_bootstrap
import scoped_bootstrap
import prepare_hr_keys
import prepare_source_authority
import validate_source_table_coverage
import validate_source_completeness
import reconcile_modules
import verify_candidate
import validate_loader_csv_contract
import default_settlement_source_policy
import finance_cash_source_policy as cash_policy
import prepare_workshop_stock_location_policy as workshop_locations
from verify_finance_master_sources import load_seed_baseline, sealed_seed_baseline, BASELINE_FILE

PGOPTIONS = '-c client_encoding=UTF8 -c jit=off -c DateStyle=ISO,YMD -c TimeZone=Asia/Shanghai'

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
IDENTIFIER = re.compile(r'[a-z_][a-z0-9_]{0,62}')
MODULES = (
    'migrate_hr_rehearsal.sql','migrate_legacy_injection_machines.sql',
    'migrate_reference_evidence.sql','migrate_goods.sql','migrate_mould.sql',
    'migrate_client.sql','migrate_supplier.sql','migrate_color.sql','migrate_unit.sql',
    'migrate_currency.sql','migrate_warehouse.sql','migrate_mould_data.sql',
    'migrate_client_data.sql','migrate_supplier_data.sql','migrate_goods_data.sql',
    'goods_excel_attributes.sql','goods_legacy_semantics.sql','goods_legacy_media.sql',
    'migrate_goods_owning_warehouse.sql','migrate_goods_bom.sql','goods_bom_topology.sql',
    'goods_material_identity.sql','migrate_purchase.sql','migrate_stock_docs.sql',
    'migrate_sales.sql','migrate_subcontract.sql','migrate_production.sql',
    'migrate_finance.sql','migrate_goods_owner.sql','migrate_client_owner.sql',
    'migrate_sales_owner.sql','migrate_rehearsal_code_sequences.sql',
    'migrate_rehearsal_stock_movement_summary.sql')
AUXILIARY_SQL = frozenset(('goods_excel_attributes.sql','goods_legacy_semantics.sql',
    'goods_material_identity.sql','goods_bom_topology.sql','goods_legacy_media.sql'))


def executable_modules(directory: Path, scope: str="full"):
    for name in MODULES:
        if scope==scoped_bootstrap.SCOPE and name=="migrate_finance.sql":continue
        path=directory/name if name in AUXILIARY_SQL else HERE/name
        if not path.is_file():
            raise ValueError('Required executable migration layer is missing: '+name)
        content=path.read_bytes()
        if name=='migrate_finance.sql' and int(read_mapping_version().split('-v')[1])>=21:
            content=cash_policy.render_sql(directory).encode('utf-8')+content
        if scope==scoped_bootstrap.SCOPE and name=='migrate_production.sql':
            content=scoped_bootstrap.production(content)
        if name=='migrate_stock_docs.sql':
            content=compose_bootstrap.reviewed_loader_content(content,name)
            content+=b'\n'+(HERE/'migrate_rehearsal_stock_checks.sql').read_bytes()
            content+=b'\n'+(HERE/'migrate_rehearsal_stock_movement_checks.sql').read_bytes()
        # Capture only source identity/default before compose drops each stage.
        # Keep full stage names free for later owner and business modules.
        content+=default_settlement_source_policy.render_source_capture(name).encode('utf-8')
        yield name,content


def validate_execution_inputs(directory: Path, scope: str="full"):
    # Static COPY contracts are checked before a claim or any business write.
    # A CSV can be internally valid yet belong to a different loader revision.
    return validate_loader_csv_contract.validate_modules(list(executable_modules(directory,scope)),directory)


def digest(path: Path) -> str:
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def read_mapping_version() -> str:
    version = (HERE / 'mapping-version.txt').read_text(encoding='utf-8-sig').strip()
    if not re.fullmatch(r'bootstrap-v[1-9][0-9]*', version):
        raise ValueError('Invalid frozen bootstrap mapping version')
    return version


def literal(value) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def verify_frozen_source() -> str:
    local_manifest=os.environ.get('UTEN_LOCAL_IMPORT_SOURCE_MANIFEST')
    local_digest=os.environ.get('UTEN_LOCAL_IMPORT_SOURCE_SHA256')
    if local_manifest or local_digest:
        from local_source_freeze import verify
        return verify(ROOT,local_manifest or '',local_digest)['gitParent']
    controlled=[*HERE.glob('*.py'),*HERE.glob('migrate_*.sql'),HERE/'mapping-version.txt',HERE/'migrate.sh',HERE/'export_legacy.ps1',
                HERE/'export_rehearsal_reference_audit.ps1',HERE/'warehouse_crosswalk.csv',
                HERE/'export_legacy_goods_media.ps1',HERE/'source_schema_contract.json',
                HERE/'source_profile_contract.json',HERE/'export_source_completeness_audit.ps1',
                HERE/'personnel_source_archive.py',
                *(HERE/'java').glob('*.java'),
                *(ROOT/'server/src/main/resources/db/migration').glob('V*__*.sql')]
    paths=[path.relative_to(ROOT).as_posix() for path in controlled]
    # Native Windows has a 32K command line ceiling; do not repeat the old
    # verify_candidate.py failure by passing 800+ resource paths in one call.
    for start in range(0,len(paths),60):
        batch=paths[start:start+60]
        subprocess.run(['git','-C',str(ROOT),'ls-files','--error-unmatch','--',*batch],
                       check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        dirty=subprocess.check_output(['git','-C',str(ROOT),'status','--porcelain=v1','--',*batch],text=True)
        if dirty.strip():
            raise ValueError('Importer or Flyway source has uncommitted bytes; use the frozen rehearsal worktree')
    return subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip()


def csv_record(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise ValueError('Input must be a regular file: ' + path.name)
    with path.open(encoding='utf-8-sig', newline='') as source:
        reader = csv.reader(source, delimiter='|')
        header = next(reader)
        if not header or len(header) != len(set(header)):
            raise ValueError('Invalid CSV header: ' + path.name)
        count = 0
        for count, row in enumerate(reader, 1):
            if len(row) != len(header):
                raise ValueError('CSV width differs: ' + path.name + ':' + str(count))
    return dict(file=path.name, rows=count, bytes=path.stat().st_size, sha256=digest(path))


def verify_reference_masters(masters: Path, clean: Path, excel: Path) -> dict:
    manifest=json.loads((masters/'reference_masters_manifest.json').read_text(encoding='utf-8-sig'))
    if manifest['script_sha256']!=digest(HERE/'prepare_excel_reference_masters.py'):
        raise ValueError('Reference-master generator drift')
    for record in manifest['source_inputs']:
        path=Path(record['path']).resolve()
        if path.parent!=clean.resolve() or digest(path)!=record['sha256']:
            raise ValueError('Reference-master parent drift: '+path.name)
    for record in manifest['excel_inputs']:
        path=Path(record['path']).resolve()
        if path.parent!=excel.resolve() or digest(path)!=record['sha256']:
            raise ValueError('Reference-master Excel drift: '+path.name)
    for record in manifest['outputs']:
        if Path(record['file']).name!=record['file'] or digest(masters/record['file'])!=record['sha256']:
            raise ValueError('Reference-master output drift')
    return manifest


def verify_auxiliary(directory: Path, manifest_name: str, generator: str, required_inputs: tuple[Path,...]=()) -> dict:
    manifest=json.loads((directory/manifest_name).read_text(encoding='utf-8-sig'))
    if manifest['generator_sha256']!=digest(HERE/generator):
        raise ValueError('Auxiliary generator drift: '+generator)
    for record in [*manifest['inputs'],*manifest.get('evidence_sources',[])]:
        if digest(Path(record['path']))!=record['sha256']:
            raise ValueError('Auxiliary source drift: '+Path(record['path']).name)
    declared={Path(record['path']).resolve():record['sha256'] for record in manifest['inputs']}
    for expected in required_inputs:
        if declared.get(expected.resolve())!=digest(expected):
            raise ValueError('Auxiliary layer is not anchored to this run: '+expected.name)
    for record in manifest['outputs']:
        if Path(record['file']).name!=record['file'] or digest(directory/record['file'])!=record['sha256']:
            raise ValueError('Auxiliary output drift: '+record['file'])
    return manifest


def verify_layers(raw: Path, clean: Path, overlay: Path, hr: Path, excel: Path | None = None, hr_xls: Path | None = None, masters: Path | None = None) -> None:
    """Check each transformation's actual parent and output bytes, before sealing."""
    master = json.loads((clean / 'clean_master_manifest.json').read_text(encoding='utf-8'))
    if (master['raw_manifest_sha256'] != digest(raw / 'export_manifest.json')
            or master['preprocessor_sha256'] != digest(HERE / 'prepare_clean_master_data.py')
            or master['crosswalk_sha256'] != digest(HERE / 'warehouse_crosswalk.csv')):
        raise ValueError('Clean master parent or transformation differs')
    for record in master['inputs']:
        if digest(raw / record['file']) != record['sha256']:
            raise ValueError('Clean master source drift: ' + record['file'])
    raw_names={r['file'] for r in json.loads((raw/'export_manifest.json').read_text(encoding='utf-8-sig'))['files']}
    if {r['file'] for r in master['inputs']}!=raw_names:
        raise ValueError('Clean master input inventory differs from the raw export')
    for record in master['outputs']:
        if digest(clean / record['file']) != record['sha256']:
            raise ValueError('Clean master output drift: ' + record['file'])
    goods = json.loads((overlay / 'goods_excel_manifest.json').read_text(encoding='utf-8'))
    master_names=set()
    if masters is not None:
        master_names={r['file'] for r in verify_reference_masters(masters,clean,excel)['outputs']}
    for record in goods['generators']:
        if digest(HERE / record['file']) != record['sha256']:
            raise ValueError('Excel generator drift: ' + record['file'])
    if excel is not None:
        for record in [*master['excel_inputs'],*goods['workbooks']]:
            if digest(excel / record['file']) != record['sha256']:
                raise ValueError('Original Excel input drift: ' + record['file'])
    for record in goods['sourceInputs']:
        path = Path(record['path']).resolve()
        valid_parent=(path.parent==clean.resolve() or
                      (masters is not None and path.parent==masters.resolve() and path.name in master_names))
        if not valid_parent or digest(path) != record['sha256']:
            raise ValueError('Excel overlay parent drift: ' + path.name)
    for record in goods['outputs']:
        if digest(overlay / record['file']) != record['sha256']:
            raise ValueError('Excel overlay output drift: ' + record['file'])
    hr_manifest = json.loads((hr / 'hr_rehearsal_manifest.json').read_text(encoding='utf-8'))
    for name, sha in hr_manifest.items():
        if digest(hr / name) != sha:
            raise ValueError('HR prepared input drift: ' + name)
    hr_report = json.loads((hr / 'hr_rehearsal_report.json').read_text(encoding='utf-8'))
    if hr_report['input_sha256']['legacy_workers'] != digest(raw / 'hr_workers.csv'):
        raise ValueError('HR legacy source differs from this export')
    if hr_xls is not None and hr_report['input_sha256']['xls']!=digest(hr_xls):
        raise ValueError('Original personnel workbook changed')


def verify_raw(directory: Path) -> dict:
    manifest = json.loads((directory / 'export_manifest.json').read_text(encoding='utf-8-sig'))
    if (manifest.get('formatVersion') != 4 or manifest.get('target') != 'All'
            or manifest.get('consistency') != 'serializable-read-transaction'
            or manifest.get('offlineBackupRequired') is not True):
        raise ValueError('A complete serializable offline export is required')
    if manifest['exportScriptSha256'] != digest(HERE / 'export_legacy.ps1'):
        raise ValueError('Raw export was produced by different exporter bytes')
    if manifest['checksumManifestSha256'] != digest(directory / 'export_manifest.sha256'):
        raise ValueError('Raw manifest and checksum sidecar differ')
    expected = set(re.findall(r"Join-Path\s+\$dataDir\s+'([A-Za-z0-9][A-Za-z0-9_.-]*[.]csv)'",
                             (HERE / 'export_legacy.ps1').read_text(encoding='utf-8-sig')))
    records = manifest['files']
    if len(records) != len(expected) or {r['file'] for r in records} != expected:
        raise ValueError('Raw export CSV inventory differs from the exporter')
    sidecar = {}
    for line in (directory / 'export_manifest.sha256').read_text(encoding='ascii').splitlines():
        match = re.fullmatch(r'([0-9a-f]{64}) \*([A-Za-z0-9][A-Za-z0-9_.-]*[.]csv)', line)
        if not match or match[2] in sidecar:
            raise ValueError('Invalid or repeated raw checksum record')
        sidecar[match[2]] = match[1]
    if sidecar != {r['file']: r['sha256'] for r in records}:
        raise ValueError('Raw checksum inventory differs')
    for record in records:
        if csv_record(directory / record['file']) != record:
            raise ValueError('Raw input drift: ' + record['file'])
    for name in ('production_daily_reports.csv', 'production_daily_report_items.csv',
                 'subcontract_application_m.csv', 'subcontract_application_i.csv',
                 'subcontract_ask_m.csv', 'subcontract_ask_i.csv', 'm_bank.csv'):
        if next(r['rows'] for r in records if r['file'] == name):
            raise ValueError('Nonempty source needs an implemented loader: ' + name)
    return manifest


class Database:
    def __init__(self, container: str, name: str, user: str):
        if container != 'uten-imp-postgres' or not IDENTIFIER.fullmatch(name) or 'rehearsal' not in name:
            raise ValueError('Only a named rehearsal database in the local development container is allowed')
        self.container, self.name, self.user = container, name, user

    def verify_local(self):
        endpoint = subprocess.check_output(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'], text=True).strip()
        for effective in (endpoint,os.environ.get('DOCKER_HOST',endpoint)):
            if not (effective.startswith('npipe:') or effective.startswith('unix:')):
                raise ValueError('Remote Docker endpoints are not permitted for a local reset')

    def sql(self, text: str, *, output=None) -> str:
        args = ['docker', 'exec', '-i', '-e', 'PGOPTIONS=' + PGOPTIONS, self.container,
                'psql', '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
                '-v', 'VERBOSITY=sqlstate', '-v', 'SHOW_CONTEXT=never',
                '-U', self.user, '-d', self.name]
        if output is not None:
            result = subprocess.run(args, input=text.encode(), stdout=output, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError('Import transaction failed; see the private SQL log')
            return ''
        result = subprocess.run(args, input=text.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            # Never echo a statement, PII, hash or a decrypted value in diagnostics.
            raise RuntimeError('Database command failed (private diagnostic omitted)')
        return result.stdout.decode('utf-8').strip()


class IsolatedCanonicalDatabase(Database):
    def __init__(self,container,name,user,expected_system_identifier,expected_database_oid):
        if container!=scoped_bootstrap.CONTAINER or name!='uten_imp':
            raise ValueError('Only the explicitly approved isolated canonical target is allowed')
        self.container,self.name,self.user=container,name,user
        self.expected_system_identifier,self.expected_database_oid=expected_system_identifier,expected_database_oid
    def verify_local(self):
        scoped_bootstrap.verify_transport(self)


def output_sql(function, *args) -> str:
    stream = io.StringIO()
    with contextlib.redirect_stdout(stream):
        function(*args)
    return stream.getvalue()


def source_authority(manifest_path: Path) -> str:
    masters, references = prepare_source_authority.collect(manifest_path)
    text = '''CREATE TEMP TABLE bootstrap_source_master_ids (
target_table text NOT NULL, legacy_id integer NOT NULL, source_file text NOT NULL,
source_row_id text NOT NULL, source_row_number integer NOT NULL,
PRIMARY KEY(target_table,legacy_id)) ON COMMIT DROP;
CREATE TEMP TABLE bootstrap_legacy_reference_evidence (
target_table text NOT NULL, legacy_id integer NOT NULL, source_file text NOT NULL,
source_row_id text NOT NULL, source_column text NOT NULL, source_row_number integer NOT NULL,
reference_count bigint NOT NULL, PRIMARY KEY(target_table,legacy_id)) ON COMMIT DROP;
'''
    return (text + output_sql(prepare_source_authority.insert_rows, 'bootstrap_source_master_ids', masters)
            + output_sql(prepare_source_authority.insert_rows, 'bootstrap_legacy_reference_evidence', references))


def reconcile_sql(manifest_path: Path, run_id: str) -> str:
    original = sys.argv
    try:
        sys.argv = [str(HERE / 'reconcile_modules.py'), str(manifest_path), run_id]
        return output_sql(reconcile_modules.main)
    finally:
        sys.argv = original


def prepare_inputs(raw: Path, clean: Path, overlay: Path, hr: Path, output: Path, excel: Path, reference: Path, hr_xls: Path, masters: Path, semantics: Path | None=None, injection: Path | None=None, topology: Path | None=None, source_backup: Path | None=None, media: Path | None=None, completeness_audit: Path | None=None, finance_seed_baseline: Path | None=None, finance_seed_baseline_sha256: str | None=None, scope: str="full", finance_cash_source_policy: Path | None=None, workshop_stock_location_policy: Path | None=None) -> dict:
    importer_commit=verify_frozen_source()
    raw_manifest = verify_raw(raw)
    if source_backup is not None and digest(source_backup)!=raw_manifest['sourceBackupSha256']:
        raise ValueError('The selected backup file differs from the raw export; restore and re-export the new backup')
    verify_layers(raw, clean, overlay, hr, excel,hr_xls,masters)
    auxiliary=[]
    if semantics is not None:
        verify_auxiliary(semantics,'goods_semantics_manifest.json','audit_legacy_goods_semantics.py',
                         (raw/'export_manifest.json',raw/'goods.csv',overlay/'goods.csv',
                          overlay/'goods_excel_manifest.json',masters/'mould.csv',masters/'reference_masters_manifest.json'))
        auxiliary.append((semantics,('goods_note_semantics.csv','mould_location_semantics.csv','goods_mould_semantics.csv','goods_legacy_semantics.sql')))
    if injection is not None:
        verify_auxiliary(injection,'injection_material_manifest.json','prepare_injection_material_bom.py',
                         (overlay/'goods.csv',overlay/'goods_excel_attributes.csv',clean/'goods_bom.csv',clean/'unit.csv',
                          raw/'goods.csv',clean/'production_plan_costs.csv',clean/'goods_categories.csv'))
        auxiliary.append((injection,('goods_material_identity.csv','goods_material_identity.sql')))
    if topology is not None:
        graph=verify_auxiliary(topology,'bom_topology_manifest.json','validate_legacy_bom_topology.py',
                               (overlay/'goods.csv',clean/'goods_bom.csv'))
        if graph.get('valid') is not True:
            raise ValueError('The bound operational BOM graph was not validated')
        auxiliary.append((topology,('goods_bom_topology.sql',)))
    if media is not None:
        verify_auxiliary(media,'goods_legacy_media_manifest.json','prepare_legacy_goods_media.py',
                         (raw/'export_manifest.json',))
        auxiliary.append((media,('goods_legacy_media.csv','goods_legacy_media.sql')))
    if output.exists():
        raise ValueError('Use a new empty final-input directory')
    overlay_names={r['file'] for r in json.loads((overlay/'goods_excel_manifest.json').read_text(encoding='utf-8'))['outputs']}
    clean_names={r['file'] for r in json.loads((clean/'clean_master_manifest.json').read_text(encoding='utf-8'))['outputs']}
    master_names={r['file'] for r in verify_reference_masters(masters,clean,excel)['outputs']}
    undeclared={p.name for p in overlay.glob('*.csv')}-overlay_names
    if undeclared:
        raise ValueError('Undeclared CSVs in the goods overlay: '+','.join(sorted(undeclared)))
    source_coverage=validate_source_table_coverage.validate_source_table_coverage(reference,raw/'export_manifest.json')
    if completeness_audit is None:
        raise ValueError('A fresh SHA-bound source completeness audit is required before preparing inputs')
    source_completeness=validate_source_completeness.validate_source_completeness(
        completeness_audit,raw/'export_manifest.json',reference,
        HERE/'source_schema_contract.json',HERE/'source_profile_contract.json',HERE/'export_source_completeness_audit.ps1')
    mapping=read_mapping_version()
    finance_baseline=None
    if int(mapping.split('-v')[1])>=18 or finance_seed_baseline is not None or finance_seed_baseline_sha256 is not None:
        if finance_seed_baseline is None or finance_seed_baseline_sha256 is None:
            raise ValueError('Protocol18 prepare requires an explicit actual finance seed baseline and root-held SHA')
        finance_baseline=load_seed_baseline(finance_seed_baseline,finance_seed_baseline_sha256)
    output.mkdir(parents=True)
    if finance_baseline is not None:
        # Independent JSON evidence does not change the raw/derived CSV inventory.
        shutil.copy2(finance_seed_baseline,output/BASELINE_FILE)
        if digest(output/BASELINE_FILE)!=finance_baseline['sha256']:
            raise ValueError('Finance seed baseline changed during preparation')
    for record in raw_manifest['files']:
        name = record['file']
        source = overlay / name if name in overlay_names else masters/name if name in master_names else clean / name
        if name not in overlay_names and name not in clean_names and name not in master_names:
            raise ValueError('Undeclared cleaned source: '+name)
        if not source.is_file():
            raise ValueError('Derived source missing: ' + name)
        shutil.copy2(source, output / name)
    for directory, patterns in ((clean, ('warehouse_crosswalk.csv',)),
                                (overlay, ('goods_owning_warehouse.csv', 'goods_excel_attributes.sql',
                                           'goods_workshop_stock_location_review.csv')),
                                (hr, ('hr_rehearsal.csv', 'hr_managers.csv')),
                                (reference, ('legacy_injection_machines.csv',)),*auxiliary):
        for pattern in patterns:
            for path in directory.glob(pattern):
                if (output / path.name).exists():
                    raise ValueError('Two prepared inputs claim one file: ' + path.name)
                shutil.copy2(path, output / path.name)
    workshop_policy_provenance=None
    if workshop_stock_location_policy is not None:
        policy=workshop_locations.validate_package(workshop_stock_location_policy)
        if digest(overlay/'goods_workshop_stock_location_review.csv')!=policy['source_review_sha256']:
            raise ValueError('Reviewed workshop stock policy belongs to a different exact Excel/legacy review')
        for name in workshop_locations.FILES:
            shutil.copyfile(workshop_stock_location_policy/name,output/name)
        workshop_policy_provenance={'directory':str(workshop_stock_location_policy.resolve()),
            'manifest_sha256':digest(workshop_stock_location_policy/'LOCATION_POLICY_MANIFEST.json')}
    else:
        for name in workshop_locations.FILES:shutil.copyfile(overlay/name,output/name)
    required_files={'warehouse_crosswalk.csv','goods_owning_warehouse.csv','goods_excel_attributes.sql',
                    'goods_workshop_stock_location_review.csv','workshop_stock_location_crosswalk.csv','workshop_stock_location_authority.csv',
                    'hr_rehearsal.csv','hr_managers.csv','legacy_injection_machines.csv'}
    if semantics is not None:
        required_files.update(('goods_note_semantics.csv','mould_location_semantics.csv','goods_mould_semantics.csv','goods_legacy_semantics.sql'))
    if injection is not None:
        required_files.update(('goods_material_identity.csv','goods_material_identity.sql'))
    if topology is not None:
        required_files.add('goods_bom_topology.sql')
    if media is not None:
        required_files.update(('goods_legacy_media.csv','goods_legacy_media.sql'))
    if any(not (output/name).is_file() for name in required_files):
        raise ValueError('The prepared import is missing a required executable layer input')
    cash_policy_provenance=None
    if scope=='full' and int(read_mapping_version().split('-v')[1])>=21:
        if finance_cash_source_policy is None:
            raise ValueError('V21 full prepare requires an explicit reviewed --finance-cash-source-policy package')
        cash_policy_provenance=cash_policy.copy_package(finance_cash_source_policy,output,raw/'export_manifest.json')
    loader_contracts=validate_execution_inputs(output,scope)
    scripts = {p.name: digest(p) for p in HERE.glob('*.py')}
    scripts.update({p.name: digest(p) for p in HERE.glob('migrate_*.sql')})
    scripts['reviewed_workshop_stock_location.sql']=digest(HERE/'reviewed_workshop_stock_location.sql')
    scripts.update({name:digest(HERE/name) for name in ('export_legacy.ps1','export_rehearsal_reference_audit.ps1','mapping-version.txt','migrate.sh')})
    scripts['export_legacy_goods_media.ps1']=digest(HERE/'export_legacy_goods_media.ps1')
    for name in ('source_schema_contract.json','source_profile_contract.json'):
        scripts[name]=digest(HERE/name)
    scripts['export_source_completeness_audit.ps1']=digest(HERE/'export_source_completeness_audit.ps1')
    scripts.update({str(path.relative_to(HERE).as_posix()):digest(path) for path in (HERE/'java').glob('*.java')})
    provenance = {'executionScope':scope,'inputKind': 'derived-local-rehearsal-v1', 'rawManifestSha256': digest(raw / 'export_manifest.json'),
                  'importerRepositoryCommit':importer_commit,
                  'rawDirectory': str(raw.resolve()), 'rawSourceBackupSha256': raw_manifest['sourceBackupSha256'],
                  'loaderCsvContracts':loader_contracts,
                  'sourceBackupPath':str(source_backup.resolve()) if source_backup is not None else None,
                  'rawRepositoryCommit': raw_manifest['repositoryCommit'], 'scripts': scripts,
                  'preparedDirectories': {key:str(value.resolve()) for key,value in
                                          dict(clean=clean,overlay=overlay,hr=hr,excel=excel,hr_xls=hr_xls,masters=masters).items()},
                  'referenceAudit': {str(path.resolve()):digest(path) for path in sorted(reference.iterdir()) if path.is_file()},
                  'sourceTableCoverage':source_coverage,
                  'sourceCompleteness':{'directory':str(completeness_audit.resolve()),'proof':source_completeness},
                  'auxiliaryLayers':{str(directory.resolve()):{'manifest':name,'generator':generator,'sha256':digest(directory/name)}
                                     for directory,name,generator in
                                     [(semantics,'goods_semantics_manifest.json','audit_legacy_goods_semantics.py'),
                                      (injection,'injection_material_manifest.json','prepare_injection_material_bom.py'),
                                      (topology,'bom_topology_manifest.json','validate_legacy_bom_topology.py'),
                                      (media,'goods_legacy_media_manifest.json','prepare_legacy_goods_media.py')]
                                     if directory is not None},
                  'extraInputs': {name: digest(output / name) for name in
                                  ('warehouse_crosswalk.csv','goods_owning_warehouse.csv','goods_excel_attributes.sql',
                                   'goods_workshop_stock_location_review.csv','workshop_stock_location_crosswalk.csv','workshop_stock_location_authority.csv',
                                   'goods_legacy_semantics.sql','goods_material_identity.sql','goods_bom_topology.sql',
                                   'goods_legacy_media.sql',*cash_policy.PACKAGE_FILES) if (output/name).is_file()},
                  'layers': {str(directory): {p.name: digest(p) for p in sorted(directory.glob('*.json'))}
                             for directory in (clean, masters, overlay, hr)}}
    if cash_policy_provenance is not None:
        provenance['financeCashSourcePolicy']=cash_policy_provenance
    if workshop_policy_provenance is not None:
        provenance['workshopStockLocationPolicy']=workshop_policy_provenance
    if os.environ.get('UTEN_LOCAL_IMPORT_SOURCE_MANIFEST'):
        from local_source_freeze import verify
        provenance['localSourceFreeze']=verify(ROOT,os.environ['UTEN_LOCAL_IMPORT_SOURCE_MANIFEST'],os.environ.get('UTEN_LOCAL_IMPORT_SOURCE_SHA256'))
    if finance_baseline is not None:
        provenance.update(financeSeedBaselineFile=BASELINE_FILE,
                          financeSeedBaselineSha256=finance_baseline['sha256'])
    manifest = {'formatVersion': 4, 'target': 'All',
                'sourceSnapshotAsOfUtc': raw_manifest['sourceSnapshotAsOfUtc'],
                'files': [csv_record(p) for p in sorted(output.glob('*.csv'))
                          if p.name not in ('warehouse_crosswalk.csv', 'goods_owning_warehouse.csv',
                                            'goods_workshop_stock_location_review.csv',*workshop_locations.FILES)],
                'provenance': provenance}
    (output / 'derived_inputs.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    return manifest


def apply(db: Database, directory: Path, env: Path, log: Path, confirmation: str, approval: str, scope: str="full"):
    if confirmation != 'RESET_' + db.name:
        raise ValueError('Explicit exact rehearsal target confirmation is required')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]{2,127}',approval):
        raise ValueError('An explicit local rehearsal approval reference is required')
    db.verify_local()
    manifest_path = directory / 'derived_inputs.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest['provenance']['inputKind'] != 'derived-local-rehearsal-v1':
        raise ValueError('Input is not an explicitly derived rehearsal inventory')
    finance_baseline=None
    if int(read_mapping_version().split('-v')[1])>=18:
        finance_baseline=sealed_seed_baseline(directory,manifest['provenance'])
    if scope=='full' and int(read_mapping_version().split('-v')[1])>=21:
        policy=manifest['provenance'].get('financeCashSourcePolicy',{})
        if policy.get('format')!=cash_policy.FORMAT or policy.get('file')!=cash_policy.POLICY_FILE or digest(directory/cash_policy.POLICY_FILE)!=policy.get('sha256'):
            raise ValueError('V21 requires its exact prepared finance cash source policy')
        actual_policy=cash_policy.load_policy(directory,{record['file']:record for record in manifest['files']})
        if actual_policy['files']!=policy.get('evidence_files') or actual_policy['policy']['raw_manifest_sha256']!=manifest['provenance']['rawManifestSha256'] or actual_policy['policy']['source_backup_sha256']!=manifest['provenance']['rawSourceBackupSha256']:
            raise ValueError('Prepared cash source policy/evidence/raw source binding differs')
    backup_path=manifest['provenance'].get('sourceBackupPath')
    if not backup_path or digest(Path(backup_path))!=manifest['provenance']['rawSourceBackupSha256']:
        raise ValueError('The actual selected backup changed or is unavailable; do not reuse an old export')
    for name in ('goods_legacy_semantics.sql','goods_material_identity.sql','goods_bom_topology.sql',
                 'goods_note_semantics.csv','mould_location_semantics.csv','goods_mould_semantics.csv','goods_material_identity.csv',
                 'goods_legacy_media.csv','goods_legacy_media.sql'):
        if not (directory/name).is_file():
            raise ValueError('The full rehearsal requires every executable semantic/material/topology layer: '+name)
    if verify_frozen_source()!=manifest['provenance']['importerRepositoryCommit']:
        raise ValueError('Prepared importer commit changed')
    local_freeze=manifest['provenance'].get('localSourceFreeze')
    if local_freeze is not None or os.environ.get('UTEN_LOCAL_IMPORT_SOURCE_MANIFEST'):
        from local_source_freeze import verify
        actual=verify(ROOT,os.environ.get('UTEN_LOCAL_IMPORT_SOURCE_MANIFEST',''),os.environ.get('UTEN_LOCAL_IMPORT_SOURCE_SHA256'))
        if actual!=local_freeze:
            raise ValueError('Prepared and executing local source freezes differ')
    raw = Path(manifest['provenance']['rawDirectory'])
    raw_manifest = verify_raw(raw)
    if digest(raw / 'export_manifest.json') != manifest['provenance']['rawManifestSha256']:
        raise ValueError('Raw parent manifest drift')
    parents=manifest['provenance']['preparedDirectories']
    verify_layers(raw,Path(parents['clean']),Path(parents['overlay']),Path(parents['hr']),Path(parents['excel']),Path(parents['hr_xls']),Path(parents['masters']))
    for name, sha in manifest['provenance']['scripts'].items():
        if digest(HERE / name) != sha:
            raise ValueError('Prepared transformation/loader drift: ' + name)
    for record in manifest['files']:
        if csv_record(directory / record['file']) != record:
            raise ValueError('Prepared input drift: ' + record['file'])
    for name, sha in manifest['provenance']['extraInputs'].items():
        if digest(directory / name) != sha:
            raise ValueError('Prepared extra input drift: ' + name)
    if manifest['provenance'].get('workshopStockLocationPolicy'):
        policy=manifest['provenance']['workshopStockLocationPolicy'];directory_path=Path(policy['directory'])
        if digest(directory_path/'LOCATION_POLICY_MANIFEST.json')!=policy['manifest_sha256']:
            raise ValueError('Reviewed workshop location authority package drift')
        workshop_locations.validate_package(directory_path)
    for name, sha in manifest['provenance']['referenceAudit'].items():
        if digest(Path(name))!=sha:
            raise ValueError('Supplemental source audit drift: ' + Path(name).name)
    validate_source_table_coverage.validate_bound_source_table_coverage(
        manifest['provenance']['referenceAudit'],raw/'export_manifest.json',manifest['provenance'].get('sourceTableCoverage'))
    completeness=manifest['provenance'].get('sourceCompleteness')
    validate_source_completeness.validate_bound_source_completeness(
        completeness,raw/'export_manifest.json',
        next(Path(name).parent for name in manifest['provenance']['referenceAudit']
             if Path(name).name==validate_source_table_coverage.INVENTORY),
        HERE/'source_schema_contract.json',HERE/'source_profile_contract.json',HERE/'export_source_completeness_audit.ps1')
    for name, record in manifest['provenance'].get('auxiliaryLayers',{}).items():
        directory_path=Path(name)
        if digest(directory_path/record['manifest'])!=record['sha256']:
            raise ValueError('Auxiliary manifest changed')
        if record['manifest']=='goods_semantics_manifest.json':
            required=(raw/'export_manifest.json',raw/'goods.csv',Path(parents['overlay'])/'goods.csv',
                      Path(parents['overlay'])/'goods_excel_manifest.json',Path(parents['masters'])/'mould.csv',
                      Path(parents['masters'])/'reference_masters_manifest.json')
        elif record['manifest']=='injection_material_manifest.json':
            required=(Path(parents['overlay'])/'goods.csv',Path(parents['overlay'])/'goods_excel_attributes.csv',
                      Path(parents['clean'])/'goods_bom.csv',Path(parents['clean'])/'unit.csv',
                      raw/'goods.csv',Path(parents['clean'])/'production_plan_costs.csv',Path(parents['clean'])/'goods_categories.csv')
        elif record['manifest']=='bom_topology_manifest.json':
            required=(Path(parents['overlay'])/'goods.csv',Path(parents['clean'])/'goods_bom.csv')
        elif record['manifest']=='goods_legacy_media_manifest.json':
            required=(raw/'export_manifest.json',)
        else:
            raise ValueError('Unrecognized auxiliary layer kind')
        checked=verify_auxiliary(directory_path,record['manifest'],record['generator'],required)
        if record['manifest']=='bom_topology_manifest.json' and checked.get('valid') is not True:
            raise ValueError('Prepared BOM graph validation is invalid')
    if manifest["provenance"].get("executionScope","full")!=scope:raise ValueError("Prepared scope differs from execution")
    validate_execution_inputs(directory,scope)
    migration_records = sorted((int(p.name.split('__')[0][1:]), p.name,
                                verify_candidate.flyway_checksum(p.read_bytes()))
                               for p in (ROOT / 'server/src/main/resources/db/migration').glob('V*__*.sql'))
    actual = db.sql('SELECT version::int,script,checksum FROM flyway_schema_history ORDER BY version::int;')
    if actual.splitlines() != ['|'.join(map(str, row)) for row in migration_records]:
        raise ValueError('Rehearsal Flyway history differs from the frozen loader source')
    identity = db.sql('SELECT system_identifier::text FROM pg_control_system();')
    if finance_baseline is not None:
        database_oid=db.sql('SELECT oid::bigint FROM pg_database WHERE datname=current_database();')
        if (identity!=finance_baseline['database_identity']['system_identifier']
                or str(database_oid)!=str(finance_baseline['database_identity']['database_oid'])
                or finance_baseline['data']['database']!=db.name):
            raise ValueError('Actual finance seed baseline belongs to a different cluster or physical candidate')
    candidate = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    mapping = read_mapping_version()
    manifest_sha = digest(manifest_path)
    backup_sha = manifest['provenance']['rawSourceBackupSha256']
    run_id = str(uuid.uuid4())
    actor=db.sql("SELECT id::text FROM users WHERE login_account='17665410007' AND is_super_admin AND status='active' AND NOT is_deleted;")
    if not re.fullmatch(r'[0-9a-f-]{36}',actor):
        raise ValueError('Exactly the preserved enabled administrator is required as rehearsal actor')
    log.parent.mkdir(parents=True,exist_ok=True)
    # Fail before claiming or loading business rows, rather than discovering an
    # invalid default after production/finance's expensive full-source loops.
    # Source identities live in a private file, not the hot RUNNING JSON.
    settlement_audit_path=log.parent/'default-settlement-source-audit.json'
    settlement_audit=default_settlement_source_policy.preflight(
        directory,json.loads(db.sql(default_settlement_source_policy.METHODS_SQL)),
        manifest_sha,settlement_audit_path)
    crypto = prepare_hr_keys.render(prepare_hr_keys.read_crypto(env, dict(os.environ)))
    settings = ("SET LOCAL jit=off;\nSET LOCAL uten.bootstrap_defer_owner_custody='on';\nSET LOCAL app.legacy_import='on';\nSET LOCAL standard_conforming_strings=on;\n"
                +f"SET LOCAL app.actor_id={literal(actor)};\nSET LOCAL app.actor_account='ops:legacy_rehearsal';\n"
                + ''.join(f'SET LOCAL uten.{key}={literal(value)};\n' for key, value in {
                    'bootstrap_run_id': run_id, 'bootstrap_mapping_version': mapping,
                    'bootstrap_repository_commit': candidate, 'bootstrap_manifest_sha': manifest_sha,
                    'rehearsal_actor_user_id':actor,
                    'legacy_unassigned_warehouse_code': ''}.items()))
    summary = dict(executionScope=scope,fullBootstrap=(scope=="full"),targetDatabase=db.name, targetSystemIdentifier=identity,
                   targetApprovalReference=approval,
                   importAtomicity='single-transaction-v1', inputKind='derived-local-rehearsal-v1',
                   rawManifestSha256=manifest['provenance']['rawManifestSha256'],
                   sourceSnapshotAsOfUtc=manifest['sourceSnapshotAsOfUtc'], productionAcceptance=False)
    if finance_baseline is not None:
        summary['financeSeedBaselineSha256']=finance_baseline['sha256']
    if local_freeze is not None:
        summary['localSourceFreeze']=local_freeze
    claim = ('BEGIN;\n' + settings + (HERE / 'migrate_claim_guard.sql').read_text(encoding='utf-8')
             + (HERE / 'migrate_bootstrap_target_guard.sql').read_text(encoding='utf-8')
             + f'''INSERT INTO legacy_migration_runs(run_id,target,status,migration_mode,
export_manifest_sha256,checksum_manifest_sha256,source_backup_sha256,export_approval_reference,
migration_repository_commit,migration_script_sha256,mapping_version,reconciliation_summary)
VALUES ({literal(run_id)}::uuid,'--bootstrap-all','RUNNING','BOOTSTRAP',
{literal(manifest_sha)},{literal(manifest_sha)},{literal(backup_sha)},{literal(raw_manifest['approvalReference'])},
{literal(candidate)},{literal(digest(Path(__file__)))},{literal(mapping)},{literal(json.dumps(summary))}::jsonb);
COMMIT;\n''')
    db.sql(claim)
    key_path = '/tmp/uten-rehearsal-' + run_id + '.key'
    remote_directory = '/tmp/uten-rehearsal-' + run_id
    try:
        (log.parent / 'run_id.txt').write_text(run_id, encoding='ascii')
        subprocess.run(['docker', 'exec', '-i', db.container, 'sh', '-c', 'umask 077; cat > "$1"', 'sh', key_path],
                       input=crypto, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['docker', 'cp', str(directory), db.container + ':' + remote_directory], check=True,
                       stdout=subprocess.DEVNULL)
        sql = 'BEGIN;\n' + settings + f"\\set run_id {run_id}\n\\set legacy_key_file {key_path}\n"
        sql += (HERE / 'migrate_execution_guard.sql').read_text(encoding='utf-8')
        sql += (HERE / 'migrate_bootstrap_target_guard.sql').read_text(encoding='utf-8')
        sql += source_authority(manifest_path)
        audit_files = [*directory.glob('*.csv'),*directory.glob('*.sql'), manifest_path, *HERE.glob('migrate_*.sql'), Path(__file__)]
        if finance_baseline is not None:audit_files.append(directory/BASELINE_FILE)
        if scope=='full' and int(read_mapping_version().split('-v')[1])>=21:
            audit_files.extend(directory/name for name in cash_policy.PACKAGE_FILES)
        for path in audit_files:
            sql += f'''INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size)
VALUES ({literal(run_id)}::uuid,{literal(path.name)},{literal(digest(path))},{path.stat().st_size})
ON CONFLICT(run_id,file_name) DO NOTHING;\n'''
        # One JSON binder seals all five private full-source evidence files.
        # They are archived evidence, not loader CSVs; keep their rows out of
        # consumed-CSV reconciliation and the hot RUNNING summary.
        completeness_manifest=Path(completeness['directory'])/'audit-manifest.json'
        sql+=f'''INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size)
VALUES ({literal(run_id)}::uuid,'source-completeness-audit-manifest.json',
{literal(digest(completeness_manifest))},{completeness_manifest.stat().st_size});\n'''
        for name,content in executable_modules(directory,scope):
            sql += '\n' + compose_bootstrap.compose(content, name).decode('utf-8')
            if name in ('migrate_mould_data.sql','migrate_client_data.sql','migrate_supplier_data.sql','migrate_goods_data.sql'):
                # Planner statistics from an empty target otherwise remain stale
                # while guarded master domains grow. Keep every normal guard.
                sql += '\nANALYZE master_code_reservation_members;\nANALYZE master_code_reservations;\n'
            sql += scoped_bootstrap.analyze_targets_sql(name)
            sql += 'SELECT '+literal(name)+',clock_timestamp() AS module_finished_at;\n'
        # Bind compact source-zero evidence only after all V626 hot loops, and
        # recheck both families against their preserved minimal source/UUIDs.
        sql+='\n'+default_settlement_source_policy.render_late_audit(
            settlement_audit,run_id,settlement_audit_path)
        # The small operator/doc-actor source archive is built from sealed files
        # only after every V626/V913 registration has finished. It never creates
        # a login/employee, guesses an actor UUID, or adds a loader COPY.
        from personnel_source_archive import render_personnel_source_archive_sql
        sql += '\n'+render_personnel_source_archive_sql(inputs=directory,run_id=run_id,
            manifest_sha256=manifest_sha,frozen_commit=candidate,mapping_version=mapping)+'\n'
        sql+='\nSELECT pg_temp.flush_bootstrap_owner_custody_pending();\n'
        counts = {r['file']: r['rows'] for r in manifest['files']}
        if scope==scoped_bootstrap.SCOPE:
            sql += scoped_bootstrap.finish_sql(directory,manifest,run_id,finance_baseline,approval)
        else:
            for label, name in zip(('material_categories','mould_categories','client_categories','supplier_categories',
                                     'colors','units','currencies','warehouses','moulds','clients','suppliers','goods'),
                                    ('goods_categories.csv','mould_categories.csv','client_categories.csv',
                                     'supplier_categories.csv','color.csv','unit.csv','currency.csv','warehouse.csv',
                                     'mould.csv','client.csv','supplier.csv','goods.csv')):
                sql += f'\\set expected_{label} {counts[name]}\n'
            sql += f'\\set expected_csv_files {len(counts)}\n'
            sql += compose_bootstrap.compose((HERE / 'migrate_reconciliation.sql').read_bytes(), 'migrate_reconciliation.sql').decode()
            sql += reconcile_sql(manifest_path, run_id)
            # Emit only controlled metric names and aggregate counts before a
            # rejection. SQLSTATE-only logging otherwise hides which of the
            # full gates failed and wastes a complete retry for diagnosis.
            sql += f'''SELECT 'STRUCTURAL_RECONCILIATION_FAILED_METRIC',source_entity,target_entity,metric,
    expected_value,actual_value,passed
    FROM legacy_migration_reconciliation_items
    WHERE run_id={literal(run_id)}::uuid AND NOT passed
    ORDER BY source_entity,target_entity,metric;
    SELECT 'STRUCTURAL_RECONCILIATION_COUNT',count(*)
    FROM legacy_migration_reconciliation_items WHERE run_id={literal(run_id)}::uuid;\n'''
            sql += f'''DO $$ BEGIN
    IF (SELECT count(*) FROM legacy_migration_reconciliation_items WHERE run_id={literal(run_id)}::uuid)<>23
    OR EXISTS(SELECT 1 FROM legacy_migration_reconciliation_items WHERE run_id={literal(run_id)}::uuid AND NOT passed)
    THEN RAISE EXCEPTION 'Rehearsal structural reconciliation failed'; END IF;
    END; $$;
    UPDATE legacy_migration_runs SET status='SUCCESS',reconciliation_status='PASSED',exit_code=0,
    finished_at=now(),reconciliation_summary=reconciliation_summary || '{{"automatedCheckCount":23,"productionAcceptance":false}}'::jsonb
    WHERE run_id={literal(run_id)}::uuid;\n'''
            # This SUCCESS is still private to the single uncommitted transaction.
            # V916 completion must see the final status when deferred constraints
            # resolve. A failed check rolls back this marker and every business row;
            # only audit/report writes follow the strict finalization boundary.
            sql += compose_bootstrap.compose((HERE / 'migrate_finalize_checks.sql').read_bytes(), 'migrate_finalize_checks.sql').decode()
            sql += compose_bootstrap.compose((HERE / 'migrate_audit_summary.sql').read_bytes(), 'migrate_audit_summary.sql').decode()
        sql += 'COMMIT;\n'
        # Each attempt owns its CSV namespace, including concurrent imports to
        # other local databases. Only already-validated static COPY paths move.
        sql=re.sub(r"(?m)^(\\copy[^\n]+FROM )'/tmp/([A-Za-z0-9][A-Za-z0-9_.-]*[.]csv)'",
                   lambda m:m[1]+literal(remote_directory+'/'+m[2]),sql)
        compiled = log.parent / 'compiled-bootstrap.sql'
        compiled.write_text(sql, encoding='utf-8',newline='\n')
        if verify_frozen_source()!=candidate:
            raise ValueError('Frozen importer changed during SQL assembly')
        db.sql(f'''INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size)
VALUES ({literal(run_id)}::uuid,'compiled-bootstrap.sql',{literal(digest(compiled))},{compiled.stat().st_size});''')
        with log.open('wb') as stream:
            db.sql("\\set scoped_execution_template_sha256 "+digest(compiled)+"\n"+sql, output=stream)
        print(('SCOPED_IMPORT_COMMITTED' if scope==scoped_bootstrap.SCOPE else 'REHEARSAL_IMPORT_SUCCESS')+' run_id='+run_id)
    except BaseException:
        db.sql(f"UPDATE legacy_migration_runs SET status='FAILED',exit_code=1,finished_at=now() WHERE run_id={literal(run_id)}::uuid AND status='RUNNING';")
        raise
    finally:
        subprocess.run(['docker','exec',db.container,'rm','-f',key_path], stdout=subprocess.DEVNULL)
        for path in directory.iterdir():
            if path.is_file():
                subprocess.run(['docker','exec',db.container,'rm','-f',remote_directory+'/'+path.name],
                               stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run(['docker','exec',db.container,'rmdir',remote_directory],
                       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prepare = sub.add_parser('prepare')
    for name in ('raw','clean','overlay','hr','output','excel','reference','hr-xls','masters','semantics','injection','topology','source-backup','media','completeness-audit'):
        prepare.add_argument('--' + name, type=Path, required=True)
    prepare.add_argument('--scope',choices=('full',scoped_bootstrap.SCOPE),default='full')
    prepare.add_argument('--finance-cash-source-policy',type=Path)
    prepare.add_argument('--workshop-stock-location-policy',type=Path)
    prepare.add_argument('--finance-seed-baseline',type=Path,required=True)
    prepare.add_argument('--finance-seed-baseline-sha256',required=True)
    execute = sub.add_parser('apply')
    execute.add_argument('--input', type=Path, required=True)
    execute.add_argument('--database', required=True)
    execute.add_argument('--scope',choices=('full',scoped_bootstrap.SCOPE),default='full')
    execute.add_argument('--expected-system-identifier',required=True)
    execute.add_argument('--expected-database-oid',type=int,required=True)
    execute.add_argument('--container', default=scoped_bootstrap.CONTAINER)
    execute.add_argument('--user', default='uten_migrator')
    execute.add_argument('--env-file', type=Path, required=True)
    execute.add_argument('--log', type=Path, required=True)
    execute.add_argument('--confirm', required=True)
    execute.add_argument('--approval-reference', required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        result = prepare_inputs(args.raw,args.clean,args.overlay,args.hr,args.output,args.excel,args.reference,args.hr_xls,args.masters,args.semantics,args.injection,args.topology,args.source_backup,args.media,args.completeness_audit,args.finance_seed_baseline,args.finance_seed_baseline_sha256,args.scope,args.finance_cash_source_policy,args.workshop_stock_location_policy)
        print(json.dumps({'preparedCsvFiles':len(result['files']), 'output':str(args.output)}))
    else:
        apply(IsolatedCanonicalDatabase(args.container,args.database,args.user,args.expected_system_identifier,args.expected_database_oid),args.input,args.env_file,args.log,args.confirm,args.approval_reference,args.scope)


if __name__ == '__main__':
    main()
