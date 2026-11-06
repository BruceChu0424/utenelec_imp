import hashlib,importlib.util,json,re,subprocess,time
from datetime import datetime,timezone
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3];source=json.loads((base/'complete-source-input.json').read_text(encoding='utf-8'))
guard=root/'deploy/updater/release_guard.py';spec=importlib.util.spec_from_file_location('current_golden_version_contract',guard);contract=importlib.util.module_from_spec(spec);spec.loader.exec_module(contract)
status=base/'golden-capture-v2-state.json';started=datetime.now(timezone.utc).isoformat()
def save(state,**values):status.write_text(json.dumps({'state':state,'startedAtUtc':started,'observedAtUtc':datetime.now(timezone.utc).isoformat(),'source':source['aggregateSha256'],**values},indent=2)+'\n',encoding='utf-8')
def run(args):return subprocess.run(args,capture_output=True)
save('waiting_current_pg')
query="""BEGIN READ ONLY;
SELECT jsonb_agg(jsonb_build_object('installedRank',installed_rank,'version',version,'description',description,'type',type,'script',script,'checksum',checksum,'success',success) ORDER BY installed_rank)::text FROM public.flyway_schema_history;
ROLLBACK;"""
for attempt in range(360):
    execution_path=base/'current-pg-execution.json'
    if not execution_path.exists():time.sleep(3);continue
    execution=json.loads(execution_path.read_text(encoding='utf-8-sig'));assert execution['sourceAggregateSha256']==source['aggregateSha256']
    log=(base/'current-pg.log').read_text(encoding='utf-8',errors='replace')
    containers=list(dict.fromkeys(re.findall(r'Container postgres:16-alpine is starting: ([a-f0-9]{64})',log)))
    for container in containers:
        inspected=run(['docker','inspect','--format','{{json .}}',container])
        if inspected.returncode:continue
        facts=json.loads(inspected.stdout)
        if not facts['State']['Running'] or facts['Config']['Image']!='postgres:16-alpine' or facts['Config']['Labels'].get('org.testcontainers')!='true':continue
        environment=dict(value.split('=',1) for value in facts['Config']['Env'] if '=' in value)
        # Never connect to the shared TEMPLATE: that can interfere with clone leases.
        if environment.get('POSTGRES_DB') not in {'uten_imp','application_chain'} or environment.get('POSTGRES_USER')!='fixture_admin':continue
        observed=run(['docker','exec',container,'psql','-X','-v','ON_ERROR_STOP=1','-U','fixture_admin','-d',environment['POSTGRES_DB'],'-Atc',query])
        if observed.returncode:continue
        lines=observed.stdout.decode('utf-8').splitlines()
        if not lines or lines[0]!='BEGIN' or lines[-1]!='ROLLBACK':continue
        payload='\n'.join(lines[1:-1]).strip()
        # SQL jsonb_agg over a migrating but still-empty history is NULL, not completed evidence.
        if not payload:continue
        rows=json.loads(payload)
        if not isinstance(rows,list) or len(rows)!=1013:continue
        canonical_source=root/'server/target-loading-main-fa-final/uten-imp-flyway-checksums.tsv';expected={}
        for line in canonical_source.read_text(encoding='utf-8').splitlines()[1:]:
            version,filename,checksum=line.split('\t');expected[filename]=(contract.parse_flyway_version(version),int(checksum))
        assert len(expected)==1013
        for row in rows:
            assert row['success'] is True and row['type']=='SQL'
            assert expected[row['script']]==(contract.validate_flyway_history_version(row['version'],row['script']),row['checksum'])
            assert row['description']==contract.flyway_history_description_from_filename(row['script'])
        assert [r['version'] for r in rows[:9]]==[f'{number:02}' for number in range(1,10)]
        assert contract.require_integer_flyway_head(contract.flyway_version_from_filename(r['script']) for r in rows)==1074
        assert sum('.' in r['version'] for r in rows)==14
        payload=json.dumps(rows,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8');raw=''.join(f"{r['version']}\t{r['script']}\t{r['checksum']}\n" for r in rows).encode('utf-8')
        (base/'golden-current-installed-history-raw.json').write_bytes(payload);(base/'golden-current-installed-history-raw.tsv').write_bytes(raw)
        receipt={'capturedAtUtc':datetime.now(timezone.utc).isoformat(),'source':source['aggregateSha256'],'mainHead':source['upstreamMainHead'],'observedRunState':execution['state'],'containerId':container,'image':facts['Config']['Image'],'testcontainersLabelVerified':True,'database':environment['POSTGRES_DB'],'databaseOwnership':'Exact current-PG run ordinary fixture only; never shared TEMPLATE/company','query':query,'transaction':'BEGIN READ ONLY/ROLLBACK','migrationCount':1013,'compoundCount':14,'integerHead':1074,'rawFirstNine':[r['version'] for r in rows[:9]],'actualEveryVersionChecksumAndDescriptionMatchesAdmittedFilename':True,'canonicalHistorySha256':hashlib.sha256(payload).hexdigest(),'rawProjectionSha256':hashlib.sha256(raw).hexdigest(),'rawAuditNormalized':False,'companyDbWritten':False,'mainWritten':False}
        (base/'golden-current-installed-history-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');save('captured',receipt=receipt);print(json.dumps(receipt));raise SystemExit(0)
    if execution['state']=='completed':break
    save('waiting_full1013_owned_application_fixture',observedContainers=len(containers));time.sleep(15)
save('not_captured');raise SystemExit('Current PG ended before a full1013 non-template application fixture could be captured')
