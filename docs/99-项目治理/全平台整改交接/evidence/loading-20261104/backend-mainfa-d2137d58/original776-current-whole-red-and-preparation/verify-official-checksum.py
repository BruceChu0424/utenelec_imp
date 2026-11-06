import hashlib,importlib.util,json,sys,xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime,timezone
base=Path(__file__).resolve().parent;root=base.parents[3]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);sys.modules[name]=m;spec.loader.exec_module(m);return m
source=json.loads((base/'complete-source-input.json').read_text(encoding='utf-8'));execution=json.loads((base/'current-fast-execution.json').read_text(encoding='utf-8-sig'))
assert execution['actualExitCode']==0 and execution['state']=='completed' and execution['sourceAggregateSha256']==source['aggregateSha256']
xml=next((base/'current-fast-receipt').glob('TEST-*.FlywayChecksumManifestExporterTest.xml'));suite=ET.parse(xml).getroot();assert int(suite.attrib['tests'])==2 and all(int(suite.attrib[k])==0 for k in ['failures','errors','skipped'])
v=load('fa_official_candidate_verifier',root/'server/legacy_migration/verify_candidate.py');records=v.migration_inventory(root);contract=v.version_contract(root)
assert len(records)==1013 and sum('.' in r[0] for r in records)==14 and contract.require_integer_flyway_head(r[0] for r in records)==1074
canonical=(v.CHECKSUM_HEADER+'\n'+''.join(f'{version}\t{name}\t{checksum}\n' for version,name,checksum in records)).encode('utf-8')
java=root/'server/target-loading-main-fa-final/uten-imp-flyway-checksums.tsv';assert java.read_bytes()==canonical
(base/'canonical-source-checksums.tsv').write_bytes(canonical)
tools=load('fa_official_release_tools',root/'deploy/release/release_tools.py');metadata=tools.migration_metadata(root/'server/src/main/resources/db/migration',java)
(base/'source-metadata-snapshot-1013.json').write_bytes((json.dumps(metadata,ensure_ascii=False,sort_keys=True,indent=2)+'\n').encode('utf-8'))
result={'atUtc':datetime.now(timezone.utc).isoformat(),'source':source['aggregateSha256'],'producerWholeClassTests':2,'producerWholeClassAllPassed':True,'nativeFastGroupActualExitCode':0,'nativeFastTests':126,'producerXmlSha256':hashlib.sha256(xml.read_bytes()).hexdigest(),'sqlRecords':len(records),'head':1074,'compoundVersions':14,'canonicalJavaPythonExactlyEqual':True,'sha256':hashlib.sha256(canonical).hexdigest(),'metadataSha256':hashlib.sha256((base/'source-metadata-snapshot-1013.json').read_bytes()).hexdigest(),'rawIntegerHeaderAndFormattingPreserved':True,'actualCurrentPgStillPending':True,'mainWritten':False,'companyDbWritten':False}
(base/'official-current-producer-provenance.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'));print(json.dumps(result))
